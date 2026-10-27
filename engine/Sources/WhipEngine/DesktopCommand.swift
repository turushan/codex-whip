import CryptoKit
import Foundation

/// `codex-whip desktop`: the explicit-thread, focus-free Desktop capacity retry prototype.
///
/// doctor only reads the selected conversation. watch is an opt-in foreground worker with a
/// separate journal; it never installs a login item or changes the app's settings or state.
/// Desktop quota recovery remains unsupported.
public enum DesktopCommand {
    static let usage = """
        usage: codex-whip desktop --thread CONVERSATION_ID {doctor,watch} [--state-dir DIR] [--once]

          doctor   Read Desktop state without sending messages
          watch    Watch future failures in this one conversation
                     --state-dir DIR   A separate private prototype journal directory
                     --once            Run one scheduled watcher step and exit
        """

    public static func diagnostic(_ backend: DesktopRPC, _ id: String) throws -> JSON {
        try backend.withLease(id) { _, view in
            var turn = view.turn
            var matched = true
            do {
                turn = try backend.matchedTurn(view, backend.storedTurns(id))
            } catch let error as RPCError where error.isRequest {
                matched = false
            }
            return [
                "connected": true, "backend": "desktop-ipc", "selected_conversations": 1,
                "runtime": view.thread["status"]?["type"] ?? .null,
                "ready_for_direct_input": .bool(watchable(view.thread)),
                "capacity_failure": .bool(isCapacity(turn)),
                "latest_turn_status": turn?["status"] ?? .null,
                "saved_turn_matches": .bool(matched),
                "completion_timestamp_verified": .bool(matched && turn?["completedAt"].map { !$0.isNull } == true),
                "blocked_reason": JSON(view.blockedReason),
                "quota_recovery_supported": false,
                "message_sent": false,
            ]
        }
    }

    /// Returns whether the last step finished without a held or failed check.
    public static func watch(directory: URL, codexHome: URL, threadID: String, once: Bool = false,
                             makeBackend: ((URL, RPCClient, [String], @escaping () -> Bool) throws -> RPCClient)? = nil,
                             makeMetadata: ((URL, @escaping () -> Bool) throws -> RPCClient)? = nil) throws -> Bool {
        if Paths.resolve(directory.path) == Paths.resolve(Paths.defaultStateDirectory.path) {
            throw WhipError("The Desktop prototype requires a separate state directory.")
        }
        let statePath = directory.appendingPathComponent("state.json")
        let manager = FileManager.default
        if manager.fileExists(atPath: statePath.path) {
            let original = try FileStore.readJSON(statePath)
            guard original.object != nil, original["control_backend"] == "desktop-ipc",
                  original["threads"] == .array([.string(threadID)]) else {
                throw WhipError("This directory belongs to another watcher.")
            }
        } else if let contents = try? manager.contentsOfDirectory(atPath: directory.path), !contents.isEmpty {
            throw WhipError("Choose an empty directory for a new Desktop journal.")
        }
        try FileStore.makePrivateDirectory(directory)
        let lock = open(directory.appendingPathComponent("worker.lock").path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw FileStore.posixError() }
        defer { close(lock) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw WhipError("This Desktop watcher is already running.") }
        let existing = manager.fileExists(atPath: statePath.path)
        let state = existing ? try RetryState.read(statePath) : RetryState(threads: [threadID])
        guard state.threads == [threadID], !existing || state.controlBackend == "desktop-ipc" else {
            throw WhipError("This journal belongs to another Desktop scope.")
        }
        state.controlBackend = "desktop-ipc"
        try state.write(statePath)
        if !manager.fileExists(atPath: directory.appendingPathComponent("settings.json").path) {
            var defaults = Settings.defaults
            defaults.soundEnabled = false
            try Settings.save(defaults.json, directory: directory)
        }
        let stopping = StopFlag()
        var sources: [DispatchSourceSignal] = []
        var previous: [Int32: sig_t?] = [:]
        for number in [SIGINT, SIGTERM] {
            previous[number] = signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global(qos: .userInitiated))
            source.setEventHandler { stopping.set() }
            source.resume()
            sources.append(source)
        }
        defer {
            sources.forEach { $0.cancel() }
            for (number, handler) in previous { signal(number, handler ?? SIG_DFL) }
        }
        let history = try History(directory: directory)
        defer { history.close() }
        let audio = RetrySound()
        defer { audio.close() }
        let logURL = directory.appendingPathComponent("worker.log")
        if !manager.fileExists(atPath: logURL.path) {
            manager.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        chmod(logURL.path, 0o600)
        let log = EventLog(directory: directory)
        var stepHeld = false
        let report: RetryEngine.Emit = { event, fields in
            if event == "thread_unavailable" { stepHeld = true }
            _ = try? history.record(event, fields)
            log.write(event, fields)
            audio.report(event)
        }
        let shouldStop: () -> Bool = { stopping.isSet }
        let engine = try RetryEngine(state: state, save: { try $0.write(statePath) }, emit: report,
                                     threads: [threadID], shouldStop: shouldStop)
        var scheduler = ScanScheduler()
        var reconnectAfter: Double = 0
        var metadata: RPCClient?
        var backend: RPCClient?
        func closeConnections() {
            (backend as? DesktopRPC)?.close()
            (metadata as? WebSocketRPC)?.close()
            backend = nil
            metadata = nil
        }
        defer { closeConnections() }
        while !stopping.isSet {
            let settings = try Settings.read(directory: directory)
            try engine.applySettings(settings)
            audio.configure(settings.soundEnabled)
            if monotonic() < reconnectAfter {
                if once { break }
                usleep(500_000)
                continue
            }
            let discovery = scheduler.due(monotonic(), interval: settings.scanSeconds)
            if discovery || engine.maintenanceDue(Date().timeIntervalSince1970) {
                do {
                    if metadata == nil {
                        let socket = try resolveSocket(codexHome)
                        let opened = try makeMetadata?(socket, shouldStop) ?? WebSocketRPC(path: socket, shouldStop: shouldStop)
                        metadata = opened
                        let ipcPath = codexHome.appendingPathComponent("ipc/ipc.sock")
                        backend = try makeBackend?(ipcPath, opened, [threadID], shouldStop)
                            ?? DesktopRPC(socketPath: ipcPath, metadata: opened, threadIDs: [threadID], shouldStop: shouldStop)
                    }
                    try reconcileHistory(state, history, now: Date().timeIntervalSince1970)
                    stepHeld = false
                    try engine.step(backend!, now: Date().timeIntervalSince1970, discover: discovery)
                    state.lastError = stepHeld ? "Desktop's saved turn cannot be verified; retries remain on hold." : nil
                    if discovery { state.lastScanAt = Date().timeIntervalSince1970 }
                } catch let error as RPCError where error.kind == .cancelled {
                    break
                } catch {
                    state.lastError = "Desktop checking is unavailable; retries remain on hold."
                    try? engine.resetObservations()
                    closeConnections()
                    reconnectAfter = monotonic() + min(30, Double(settings.scanSeconds))
                }
                try state.write(statePath)
                if discovery { scheduler.finished(monotonic()) }
            }
            if once { break }
            usleep(500_000)
        }
        return state.lastError == nil
    }

    static func main(_ arguments: [String], codexHome: URL, stdout: (String) -> Void, stderr: (String) -> Void) -> Int32 {
        var thread: String?
        var command: String?
        var stateDirectory: String?
        var once = false
        var index = 0
        func next() -> String? {
            index += 1
            return index < arguments.count ? arguments[index] : nil
        }
        while index < arguments.count {
            let item = arguments[index]
            switch item {
            case "-h", "--help":
                stdout(usage)
                return 0
            case "--thread": thread = next()
            case "--state-dir": stateDirectory = next()
            case "--once": once = true
            case "doctor", "watch":
                guard command == nil else {
                    stderr(usage)
                    stderr("codex-whip desktop: error: unrecognized arguments: \(item)")
                    return 2
                }
                command = item
            default:
                if item.hasPrefix("--thread=") { thread = String(item.dropFirst(9)) }
                else if item.hasPrefix("--state-dir=") { stateDirectory = String(item.dropFirst(12)) }
                else {
                    stderr(usage)
                    stderr("codex-whip desktop: error: unrecognized arguments: \(item)")
                    return 2
                }
            }
            index += 1
        }
        guard let command, let thread, !thread.trimmingCharacters(in: pythonWhitespace).isEmpty, thread.count <= 512,
              command == "watch" || (stateDirectory == nil && !once) else {
            stderr(usage)
            stderr("codex-whip desktop: error: provide one conversation ID and doctor or watch.")
            return 2
        }
        do {
            if command == "doctor" {
                let metadata = try WebSocketRPC(path: resolveSocket(codexHome))
                defer { metadata.close() }
                let backend = try DesktopRPC(socketPath: codexHome.appendingPathComponent("ipc/ipc.sock"),
                                             metadata: metadata, threadIDs: [thread])
                defer { backend.close() }
                stdout(try diagnostic(backend, thread).serialized(.pretty))
                return 0
            }
            let scope = SHA256.hash(data: Data(thread.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16)
            let directory = stateDirectory.map { Paths.resolve($0) }
                ?? Paths.home.appendingPathComponent("Library/Application Support/Codex Whip Desktop Prototype/\(scope)")
            stderr("Watching one selected Desktop conversation. Quota recovery stays on hold. Stop with Ctrl-C.")
            return try watch(directory: directory, codexHome: codexHome, threadID: thread, once: once) ? 0 : 1
        } catch {
            stderr("Desktop prototype unavailable. Check the app, selected conversation, and local daemon.")
            return 1
        }
    }
}
