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

/// What the worker loop needs from the engine, so tests can observe its scheduling.
public protocol WorkerEngine: AnyObject {
    func applySettings(_ value: Settings) throws
    func maintenanceDue(_ now: Double) -> Bool
    func step(_ rpc: RPCClient, now: Double, discover: Bool) throws
    func resetObservations(_ id: String?) throws
}

extension RetryEngine: WorkerEngine {}

/// The worker's clocks, connection and collaborators. `live` is the real process; tests replace parts.
public struct WorkerHooks {
    public var now: () -> Double = { Date().timeIntervalSince1970 }
    public var monotonic: () -> Double = WhipEngine.monotonic
    public var sleep: (Double) -> Void = { usleep(useconds_t($0 * 1_000_000)) }
    public var readSettings: (URL) throws -> Settings = { try Settings.read(directory: $0) }
    public var socket: (URL) throws -> URL = resolveSocket
    public var connect: (URL, @escaping () -> Bool) throws -> RPCClient = { try WebSocketRPC(path: $0, shouldStop: $1) }
    public var makeEngine: (RetryState, @escaping (RetryState) throws -> Void, @escaping RetryEngine.Emit, [String],
                            @escaping () -> Bool) throws -> WorkerEngine = {
        try RetryEngine(state: $0, save: $1, emit: $2, threads: $3, shouldStop: $4)
    }
    public var sound = RetrySound()
    /// Every reported event, after history and the log; for tests.
    public var observe: RetryEngine.Emit = { _, _ in }
    /// An extra stop condition, checked with the signal flag and the parent app.
    public var stopRequested: () -> Bool = { false }
    public var handleSignals = true

    public init() {}
    public static var live: WorkerHooks { WorkerHooks() }
}

/// Runs the watcher until a signal, a lost parent app, or a cancelled request stops it.
public func runWorker(directory: URL, codexHome: URL, hooks: WorkerHooks = .live) throws {
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
        stopping.isSet || hooks.stopRequested()
            || (parentPID != nil && (getppid() != initialParent || !processAlive(parentPID!)))
    }
    var sources: [DispatchSourceSignal] = []
    for number in hooks.handleSignals ? [SIGTERM, SIGINT] : [] {
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
    let sound = hooks.sound
    let report: RetryEngine.Emit = { event, fields in
        do {
            try history.record(event, fields)
        } catch {
            log.write("history_error", ["message": .string(describe(error))])
        }
        log.write(event, fields)
        // Optional feedback must never change a retry's outcome.
        sound.report(event)
        hooks.observe(event, fields)
    }
    let save: (RetryState) throws -> Void = { try $0.write(statePath) }
    let engine = try hooks.makeEngine(state, save, report, state.threads, shouldStop)
    var rpc: RPCClient?
    var lastError: String?
    var settingsError: String?
    var reconnectAfter: Double = 0
    var applied: Settings?
    var scheduler = ScanScheduler()
    report("started", ["threads": state.threads.isEmpty ? "loaded terminal sessions" : .array(state.threads.map(JSON.string))])
    defer {
        sound.close()
        (rpc as? WebSocketRPC)?.close()
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("worker.pid"))
        report("stopped", [:])
        history.close()
    }
    while !shouldStop() {
        let current: Settings
        do {
            current = try hooks.readSettings(directory)
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
            try? engine.resetObservations(nil)
            state.lastError = error.description
            if error.description != settingsError { report("settings_error", ["message": .string(error.description)]) }
            settingsError = error.description
            try save(state)
            if !shouldStop() { hooks.sleep(1) }
            continue
        }
        let clock = hooks.monotonic()
        if rpc == nil && clock < reconnectAfter {
            hooks.sleep(1)
            continue
        }
        let discoveryDue = scheduler.due(clock, interval: current.scanSeconds)
        if !discoveryDue && !engine.maintenanceDue(hooks.now()) {
            hooks.sleep(1)
            continue
        }
        do {
            try reconcileHistory(state, history, now: hooks.now())
            if rpc == nil { rpc = try hooks.connect(hooks.socket(codexHome), shouldStop) }
            try engine.step(rpc!, now: hooks.now(), discover: discoveryDue)
            if lastError != nil { report("reconnected", [:]) }
            lastError = nil
            reconnectAfter = 0
            if discoveryDue { state.lastScanAt = hooks.now() }
            state.lastError = nil
        } catch let error as RPCError where error.kind == .cancelled {
            try? engine.resetObservations(nil)
            break
        } catch {
            try? engine.resetObservations(nil)
            if shouldStop() { break }
            let message = describe(error)
            state.lastError = message
            if message != lastError { report("connection_error", ["message": .string(message)]) }
            lastError = message
            (rpc as? WebSocketRPC)?.close()
            rpc = nil
            reconnectAfter = hooks.monotonic() + min(30, Double(current.scanSeconds))
        }
        try save(state)
        if discoveryDue { scheduler.finished(hooks.monotonic()) }
        if !shouldStop() { hooks.sleep(1) }
    }
}
