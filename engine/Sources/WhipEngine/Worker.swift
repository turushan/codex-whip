import Foundation

/// A flag set from signal handlers and read by the worker loop.
final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }
}

public func resolveSocket(_ codexHome: URL) throws -> URL {
    let path = codexHome.appendingPathComponent("app-server-control/app-server-control.sock")
    guard FileManager.default.fileExists(atPath: path.path) else {
        // The native app recognizes this opening and shows plain words instead of the path.
        throw RPCError.transport("Codex daemon socket is unavailable: \(path.path). Open Codex first.")
    }
    return path
}

/// The native app opts into parent monitoring; malformed values use CLI mode.
func configuredParentPID() -> pid_t? {
    guard let text = ProcessInfo.processInfo.environment["CODEX_WHIP_PARENT_PID"],
          let value = Int32(text), value > 0 else { return nil }
    return value
}

/// Runs the watcher until a signal, a lost parent app, or a cancelled request stops it.
public func runWorker(directory: URL, codexHome: URL) throws {
    umask(0o077)
    let lock = open(directory.appendingPathComponent("worker.lock").path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
    guard lock >= 0 else { throw FileStore.posixError() }
    guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
        close(lock)
        throw WhipError("Codex Whip is already running")
    }
    defer { close(lock) }
    let statePath = directory.appendingPathComponent("state.json")
    let state = try RetryState.read(statePath)
    let stopping = StopFlag()
    let parentPID = configuredParentPID()
    let initialParent = parentPID != nil ? getppid() : nil
    let shouldStop: () -> Bool = {
        stopping.isSet || (parentPID != nil && (getppid() != initialParent || !processAlive(parentPID!)))
    }
    var sources: [DispatchSourceSignal] = []
    for number in [SIGTERM, SIGINT] {
        signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: number, queue: .global(qos: .userInitiated))
        source.setEventHandler { stopping.set() }
        source.resume()
        sources.append(source)
    }
    defer { sources.forEach { $0.cancel() } }
    try String(getpid()).write(to: directory.appendingPathComponent("worker.pid"), atomically: false, encoding: .utf8)
    let log = EventLog(directory: directory)
    let history = try History(directory: directory)
    let sound = RetrySound()
    let report: RetryEngine.Emit = { event, fields in
        do {
            try history.record(event, fields)
        } catch {
            log.write("history_error", ["message": .string(describe(error))])
        }
        log.write(event, fields)
        // Optional feedback must never change a retry's outcome.
        sound.report(event)
    }
    let save: (RetryState) throws -> Void = { try $0.write(statePath) }
    let engine = try RetryEngine(state: state, save: save, emit: report, threads: state.threads, shouldStop: shouldStop)
    var rpc: WebSocketRPC?
    var lastError: String?
    var settingsError: String?
    var reconnectAfter: Double = 0
    var applied: Settings?
    var scheduler = ScanScheduler()
    report("started", ["threads": state.threads.isEmpty ? "loaded terminal sessions" : .array(state.threads.map(JSON.string))])
    defer {
        sound.close()
        rpc?.close()
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("worker.pid"))
        report("stopped", [:])
        history.close()
    }
    while !shouldStop() {
        let current: Settings
        do {
            current = try Settings.read(directory: directory)
            if current != applied {
                try engine.applySettings(current)
                sound.configure(current.soundEnabled)
                applied = current
                report("settings_changed", ["retry_seconds": .int(current.retrySeconds),
                                            "scan_seconds": .int(current.scanSeconds)])
            }
            if settingsError != nil {
                settingsError = nil
                state.lastError = lastError
                try save(state)
            }
        } catch let error as SettingsError {
            try? engine.resetObservations()
            state.lastError = error.description
            if error.description != settingsError { report("settings_error", ["message": .string(error.description)]) }
            settingsError = error.description
            try save(state)
            if !shouldStop() { sleep(1) }
            continue
        }
        let clock = monotonic()
        if rpc == nil && clock < reconnectAfter {
            sleep(1)
            continue
        }
        let discoveryDue = scheduler.due(clock, interval: current.scanSeconds)
        if !discoveryDue && !engine.maintenanceDue(Date().timeIntervalSince1970) {
            sleep(1)
            continue
        }
        do {
            try reconcileHistory(state, history, now: Date().timeIntervalSince1970)
            if rpc == nil { rpc = try WebSocketRPC(path: resolveSocket(codexHome), shouldStop: shouldStop) }
            try engine.step(rpc!, now: Date().timeIntervalSince1970, discover: discoveryDue)
            if lastError != nil { report("reconnected", [:]) }
            lastError = nil
            reconnectAfter = 0
            if discoveryDue { state.lastScanAt = Date().timeIntervalSince1970 }
            state.lastError = nil
        } catch let error as RPCError where error.kind == .cancelled {
            try? engine.resetObservations()
            break
        } catch {
            try? engine.resetObservations()
            if shouldStop() { break }
            let message = describe(error)
            state.lastError = message
            if message != lastError { report("connection_error", ["message": .string(message)]) }
            lastError = message
            rpc?.close()
            rpc = nil
            reconnectAfter = monotonic() + min(30, Double(current.scanSeconds))
        }
        try save(state)
        if discoveryDue { scheduler.finished(monotonic()) }
        if !shouldStop() { sleep(1) }
    }
}
