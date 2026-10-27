import Foundation

/// Paths, process checks and small formatting helpers shared by the worker and the command.
public enum Paths {
    public static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    public static var defaultStateDirectory: URL {
        home.appendingPathComponent("Library/Application Support/Codex Whip", isDirectory: true)
    }
    public static var defaultCodexHome: URL {
        if let value = ProcessInfo.processInfo.environment["CODEX_HOME"], !value.isEmpty {
            return URL(fileURLWithPath: expandTilde(value))
        }
        return home.appendingPathComponent(".codex", isDirectory: true)
    }
    public static let label = "com.turushan.codex-whip"
    public static var agentPath: URL { home.appendingPathComponent("Library/LaunchAgents/\(label).plist") }

    public static func expandTilde(_ path: String) -> String { (path as NSString).expandingTildeInPath }

    /// Like Python's Path.resolve(): absolute, with symbolic links resolved as far as the path exists.
    public static func resolve(_ path: String, relativeTo base: String = FileManager.default.currentDirectoryPath) -> URL {
        var text = expandTilde(path)
        if !text.hasPrefix("/") { text = (base as NSString).appendingPathComponent(text) }
        text = (text as NSString).standardizingPath
        return URL(fileURLWithPath: resolveExisting(text))
    }

    private static func resolveExisting(_ path: String) -> String {
        if let real = realpath(path, nil) {
            defer { free(real) }
            return String(cString: real)
        }
        let parent = (path as NSString).deletingLastPathComponent
        if parent == path || parent.isEmpty { return path }
        return (resolveExisting(parent) as NSString).appendingPathComponent((path as NSString).lastPathComponent)
    }

    /// The bundled crack: in the app's resources, or in the resource bundle a source build puts
    /// beside the command. A missing file only means no sound.
    public static func soundFile(executable: URL = currentExecutable()) -> URL? {
        let folder = executable.deletingLastPathComponent()
        let app = folder.appendingPathComponent("../Resources/Whip.wav").standardized
        if FileManager.default.fileExists(atPath: app.path) { return app }
        return Bundle(url: folder.appendingPathComponent("CodexWhip_WhipEngine.bundle"))?
            .url(forResource: "whip", withExtension: "wav")
    }

    /// The running executable with symbolic links resolved, used for the CLI command and launch job.
    public static func currentExecutable() -> URL {
        var size: UInt32 = 0
        _NSGetExecutablePath(nil, &size)
        var buffer = [CChar](repeating: 0, count: Int(size) + 1)
        if _NSGetExecutablePath(&buffer, &size) == 0 {
            return resolve(String(cString: buffer))
        }
        return resolve(CommandLine.arguments[0])
    }
}

/// Signal zero checks existence without sending a signal to the process.
func processAlive(_ pid: pid_t) -> Bool {
    if kill(pid, 0) == 0 { return true }
    return errno == EPERM
}

/// Probes the worker's advisory lock without creating or changing any files.
public func workerRunning(_ directory: URL) -> Bool {
    let descriptor = open(directory.appendingPathComponent("worker.lock").path, O_RDONLY | O_CLOEXEC)
    guard descriptor >= 0 else { return false }
    defer { close(descriptor) }
    if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
        flock(descriptor, LOCK_UN)
        return false
    }
    return errno == EWOULDBLOCK
}

public func durationLabel(_ seconds: Int) -> String {
    if seconds % 60 == 0 {
        let minutes = seconds / 60
        return "\(minutes) minute" + (minutes != 1 ? "s" : "")
    }
    return "\(seconds) seconds"
}

/// The plain text of an error, without a type name, for logs, state and the menu.
public func describe(_ error: Error) -> String {
    switch error {
    case let error as RPCError: return error.description
    case let error as SettingsError: return error.description
    case let error as StateError: return error.description
    case let error as HistoryError: return error.description
    case let error as WhipError: return error.description
    case let error as JSONError: return error.description
    case let error as POSIXError: return String(cString: strerror(error.code.rawValue))
    default: return error.localizedDescription
    }
}

public struct WhipError: Error, CustomStringConvertible, LocalizedError {
    public let description: String
    public init(_ description: String) { self.description = description }
    public var errorDescription: String? { description }
}

/// The worker's diagnostic log: one JSON line per event, rotated at one MiB with two backups.
final class EventLog {
    private let url: URL
    private let maxBytes = 1024 * 1024
    private let backups = 2

    init(directory: URL) {
        url = directory.appendingPathComponent("worker.log")
    }

    func write(_ event: String, _ fields: [String: JSON]) {
        var value = fields
        value["event"] = .string(event)
        value["time"] = .string(EventLog.timestamp())
        guard let line = try? value.json.serialized(.ascii) else { return }
        let data = Data((line + "\n").utf8)
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        if size > 0 && size + data.count >= maxBytes { rotate() }
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        data.withUnsafeBytes { _ = Darwin.write(descriptor, $0.baseAddress!, $0.count) }
    }

    private func rotate() {
        let manager = FileManager.default
        for index in stride(from: backups, to: 0, by: -1) {
            let source = index == 1 ? url : URL(fileURLWithPath: "\(url.path).\(index - 1)")
            let target = URL(fileURLWithPath: "\(url.path).\(index)")
            try? manager.removeItem(at: target)
            if manager.fileExists(atPath: source.path) { try? manager.moveItem(at: source, to: target) }
        }
    }

    static func timestamp(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return formatter.string(from: date)
    }
}

extension Dictionary where Key == String, Value == JSON {
    var json: JSON { .object(self) }
}

/// Queues short whip sounds without holding up retries or replaying old events.
///
/// The worker feeds only its live report stream; reconstructed history never reaches it.
/// Disabling cancels queued sounds, and a playing half-second clip finishes at the system volume.
public final class RetrySound {
    private let player: (URL) -> Void
    private let file: URL?
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.turushan.codex-whip.sound", qos: .utility)
    private var enabled = false
    private var closed = false
    private var generation = 0

    public init(file: URL? = Paths.soundFile(), player: @escaping (URL) -> Void = RetrySound.play) {
        self.file = file
        self.player = player
    }

    /// The player command: afplay follows the current output device and volume, and never takes focus.
    public static func playCommand(_ file: URL) -> (executable: String, arguments: [String], timeout: Double) {
        ("/usr/bin/afplay", ["-v", "0.4", file.path], 2)
    }

    public static func play(_ file: URL) {
        let command = playCommand(file)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return }
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        if done.wait(timeout: .now() + command.timeout) == .timedOut { process.terminate() }
    }

    public func configure(_ value: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if value != enabled {
            enabled = value
            generation += 1
        }
    }

    public func report(_ event: String) {
        guard event == "retry" else { return }
        lock.lock()
        guard !closed, enabled, let file else { lock.unlock(); return }
        let ticket = generation
        lock.unlock()
        queue.async { [self] in
            lock.lock()
            let current = !closed && enabled && ticket == generation
            lock.unlock()
            if current { player(file) }
        }
    }

    public func close() {
        lock.lock()
        closed = true
        generation += 1
        lock.unlock()
    }

    /// Waits until queued sounds have been handled; used by tests.
    public func drain() {
        queue.sync {}
    }
}
