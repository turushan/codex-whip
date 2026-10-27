import Foundation

/// The home folder, launchd and clock the service code uses. `live` is this user's real Mac;
/// tests use a temporary home and a recording launchctl, so they never touch real login jobs.
public struct ServiceEnvironment {
    public var home: URL
    public var variables: [String: String]
    public var launchctl: ([String]) -> (status: Int32, error: String)
    public var monotonic: () -> Double
    public var sleep: (Double) -> Void
    public var executable: () -> URL

    public init(home: URL, variables: [String: String] = [:],
                launchctl: @escaping ([String]) -> (status: Int32, error: String) = Service.runLaunchctl,
                monotonic: @escaping () -> Double = WhipEngine.monotonic,
                sleep: @escaping (Double) -> Void = { usleep(useconds_t($0 * 1_000_000)) },
                executable: @escaping () -> URL = Paths.currentExecutable) {
        self.home = home
        self.variables = variables
        self.launchctl = launchctl
        self.monotonic = monotonic
        self.sleep = sleep
        self.executable = executable
    }

    public static var live: ServiceEnvironment {
        ServiceEnvironment(home: Paths.home, variables: ProcessInfo.processInfo.environment)
    }

    public var defaultStateDirectory: URL {
        home.appendingPathComponent("Library/Application Support/Codex Whip", isDirectory: true)
    }
    public var defaultCodexHome: URL {
        if let value = variables["CODEX_HOME"], !value.isEmpty { return URL(fileURLWithPath: Paths.expandTilde(value)) }
        return home.appendingPathComponent(".codex", isDirectory: true)
    }
    public var agentPath: URL { home.appendingPathComponent("Library/LaunchAgents/\(Paths.label).plist") }
    public var commandLink: URL { home.appendingPathComponent(".local/bin/codex-whip") }
}

/// Preparing state for the app, the read-only dashboard, and the optional CLI launch job.
public enum Service {
    public static func initialState(threads: [String] = []) -> RetryState {
        RetryState(threads: threads)
    }

    /// Reads the CLI launch job's effective paths without changing it.
    public static func cliJobPaths(_ url: URL, env: ServiceEnvironment = .live) throws -> (stateDirectory: URL, codexHome: URL) {
        do {
            let data = try Data(contentsOf: url)
            guard let job = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let arguments = job["ProgramArguments"] as? [String], !arguments.isEmpty,
                  arguments.allSatisfy({ !$0.isEmpty }) else {
                throw WhipError("Invalid launch arguments or environment")
            }
            let environment: [String: String]
            if let value = job["EnvironmentVariables"] {
                guard let strings = value as? [String: String] else { throw WhipError("Invalid launch arguments or environment") }
                environment = strings
            } else {
                environment = [:]
            }
            func argument(_ name: String, _ fallback: String) throws -> URL {
                var value = fallback
                for (index, item) in arguments.enumerated() {
                    if item == name {
                        guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else {
                            throw WhipError("Missing value for \(name)")
                        }
                        value = arguments[index + 1]
                    } else if item.hasPrefix(name + "=") {
                        value = String(item.dropFirst(name.count + 1))
                    }
                }
                guard !value.isEmpty else { throw WhipError("Empty value for \(name)") }
                let expanded = Paths.expandTilde(value)
                if expanded.hasPrefix("/") { return Paths.resolve(expanded) }
                let working = Paths.expandTilde(job["WorkingDirectory"] as? String ?? "")
                guard working.hasPrefix("/") else {
                    throw WhipError("Relative paths require a recorded absolute WorkingDirectory")
                }
                return Paths.resolve(expanded, relativeTo: working)
            }
            return (try argument("--state-dir", env.defaultStateDirectory.path),
                    try argument("--codex-home", environment["CODEX_HOME"] ?? env.home.appendingPathComponent(".codex").path))
        } catch {
            throw WhipError("Cannot safely read the existing CLI launch job. Keep that service, or stop it explicitly "
                + "before setting up the app. Its launch file and saved state were left intact.")
        }
    }

    /// Prepares the native worker's state, taking over from a CLI job that uses the same directory.
    public static func prepareState(directory given: URL, codexHome: URL? = nil, env: ServiceEnvironment = .live) throws {
        let directory = Paths.resolve(given.path)
        if directory == Paths.resolve(env.defaultStateDirectory.path) {
            if FileManager.default.fileExists(atPath: directory.path) { _ = try Settings.read(directory: directory) }
            if FileManager.default.fileExists(atPath: env.agentPath.path) {
                let job = try cliJobPaths(env.agentPath, env: env)
                let target = Paths.resolve((codexHome ?? env.defaultCodexHome).path)
                guard job.stateDirectory == directory, job.codexHome == target else {
                    throw WhipError("The existing CLI job uses a different state directory or Codex home. Keep that "
                        + "service, or stop it explicitly before setting up the app separately. "
                        + "Its launch file and saved state were left intact.")
                }
                try stopService(env: env)
                let limit = env.monotonic() + 15
                while workerRunning(directory) {
                    guard env.monotonic() < limit else { throw WhipError("The previous CLI worker is still stopping. Try again shortly.") }
                    env.sleep(0.1)
                }
            } else if serviceRunning(env: env) {
                throw WhipError("A CLI job is running, but its launch file is unavailable, so its configuration is "
                    + "unknown. Keep that service, or stop it explicitly before setting up the app.")
            }
        }
        try FileStore.makePrivateDirectory(directory)
        let statePath = directory.appendingPathComponent("state.json")
        if FileManager.default.fileExists(atPath: statePath.path) {
            guard try FileStore.readJSON(statePath)["version"] == 1 else { throw StateError("Unsupported retry-state version") }
        } else {
            try initialState().write(statePath)
        }
    }

    /// The app's local dashboard, read without contacting Codex or changing state.
    public static func dashboard(directory: URL) throws -> JSON {
        let statePath = directory.appendingPathComponent("state.json")
        let state = FileManager.default.fileExists(atPath: statePath.path) ? try FileStore.readJSON(statePath) : [:]
        return ["state": state, "history": try History.report(directory: directory), "running": .bool(workerRunning(directory))]
    }

    // MARK: launchd

    public static func runLaunchctl(_ arguments: [String]) -> (status: Int32, error: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let errors = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors
        do { try process.run() } catch { return (-1, describe(error)) }
        let data = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static var domain: String { "gui/\(getuid())" }

    public static func serviceRunning(env: ServiceEnvironment = .live) -> Bool {
        env.launchctl(["print", "\(domain)/\(Paths.label)"]).status == 0
    }

    public static func stopService(env: ServiceEnvironment = .live) throws {
        let result = env.launchctl(["bootout", "\(domain)/\(Paths.label)"])
        if result.status != 0 && serviceRunning(env: env) {
            throw WhipError(result.error.isEmpty ? "Could not stop launch agent" : result.error)
        }
        try? FileManager.default.removeItem(at: env.agentPath)
        let limit = env.monotonic() + 15
        while serviceRunning(env: env) {
            guard env.monotonic() < limit else { throw WhipError("Login job removed, but worker is still stopping. Check status shortly.") }
            env.sleep(0.1)
        }
    }

    static func isSymlink(_ url: URL) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path) || isSymlink(url)
    }

    public static func checkCommandTarget(_ script: URL, env: ServiceEnvironment = .live) throws -> URL {
        let command = env.commandLink
        if exists(command) && !(isSymlink(command) && Paths.resolve(command.path) == script) {
            throw WhipError("Refusing to replace an existing command: \(command.path)")
        }
        return command
    }

    /// Installs ~/.local/bin/codex-whip and a user LaunchAgent that starts at login.
    public static func startService(directory: URL, codexHome: URL, threads: [String], preserveState: Bool,
                                    env: ServiceEnvironment = .live, output: (String) -> Void) throws {
        if workerRunning(directory) {
            output("Already enabled. Use codex-whip status; native app workers are managed from the app menu.")
            return
        }
        let script = env.executable()
        if serviceRunning(env: env) {
            output("Already enabled. Use codex-whip status or stop.")
            return
        }
        _ = try checkCommandTarget(script, env: env)
        try prepareState(directory: directory, codexHome: codexHome, env: env)
        let statePath = directory.appendingPathComponent("state.json")
        let state: RetryState
        if preserveState && FileManager.default.fileExists(atPath: statePath.path) {
            state = try RetryState.read(statePath)
            if !threads.isEmpty { state.threads = threads }
        } else {
            state = initialState(threads: threads)
        }
        try state.write(statePath)
        // Keep executables outside this user's usual PATH untouched.
        let command = env.commandLink
        try FileManager.default.createDirectory(at: command.deletingLastPathComponent(), withIntermediateDirectories: true)
        if isSymlink(command) && Paths.resolve(command.path) == script {
            // Already linked to this executable.
        } else if exists(command) {
            throw WhipError("Refusing to replace an existing command: \(command.path)")
        } else {
            try FileManager.default.createSymbolicLink(at: command, withDestinationURL: script)
        }
        for name in ["worker.log", "launchd.log"] {
            let url = directory.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            chmod(url.path, 0o600)
        }
        let launchLog = directory.appendingPathComponent("launchd.log").path
        let agent: [String: Any] = [
            "Label": Paths.label,
            "ProgramArguments": [script.path, "--state-dir", directory.path, "--codex-home", codexHome.path, "_run"],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "ThrottleInterval": 30,
            "StandardOutPath": launchLog,
            "StandardErrorPath": launchLog,
            "Umask": 0o077,
            "ProcessType": "Background",
        ]
        let plist = env.agentPath
        try FileManager.default.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: agent, format: .xml, options: 0).write(to: plist)
        chmod(plist.path, 0o600)
        let result = env.launchctl(["bootstrap", domain, plist.path])
        if result.status != 0 {
            try? FileManager.default.removeItem(at: plist)
            throw WhipError(result.error.isEmpty ? "Could not start launch agent" : result.error)
        }
        let preferences = try Settings.read(directory: directory)
        output("Enabled: retry capacity failures every \(durationLabel(preferences.retrySeconds)); "
            + "check quota every \(durationLabel(preferences.scanSeconds)) in the same session and model.")
        output("Watching future failures in " + (threads.isEmpty ? "loaded terminal sessions." : threads.joined(separator: ", ")))
        output("Status: \(command.path) status\nStop:   \(command.path) stop")
    }

    /// A read-only connection check that sends nothing and makes no model request.
    public static func doctor(codexHome: URL, output: (String) -> Void) throws {
        let rpc = try WebSocketRPC(path: resolveSocket(codexHome))
        defer { rpc.close() }
        let ids = try loadedThreads(rpc)
        var count = 0, skipped = 0
        for id in ids {
            let thread: JSON
            do {
                thread = try rpc.call("thread/read", ["threadId": .string(id), "includeTurns": false]).required("thread", "thread/read")
            } catch let error as RPCError where error.isRequest {
                skipped += 1
                continue
            }
            if !(thread["parentThreadId"]?.isTruthy ?? false) && (thread["canAcceptDirectInput"]?.isTruthy ?? false) { count += 1 }
        }
        output("Connected to Codex. \(ids.count) loaded sessions, \(count) accept direct input.")
        if skipped > 0 { output("Skipped \(skipped) sessions that became unavailable.") }
        output("Read-only check passed. No message sent and no model request made.")
    }

    // MARK: Text reports

    /// Prints what the watcher is doing from the saved journal, which it only reads.
    public static func status(directory: URL, now: Double = Date().timeIntervalSince1970,
                              serviceRunning: () -> Bool = { Service.serviceRunning() },
                              activity: ((String) -> Void) throws -> Void = { try printActivity(directory: Paths.defaultStateDirectory, output: $0) },
                              output: (String) -> Void) throws {
        let path = directory.appendingPathComponent("state.json")
        let enabled = workerRunning(directory) || serviceRunning()
        guard FileManager.default.fileExists(atPath: path.path) else {
            output("Not installed. Run codex-whip start.")
            return
        }
        let state = try FileStore.readJSON(path)
        output(enabled ? "Enabled" : "Stopped")
        let sessions = state["sessions"]
        if !enabled {
            output("Watching: 0 terminal sessions (stopped)")
        } else if let sessions, sessions.object != nil {
            var details = ["\(sessions["active"]?.int ?? 0) active", "\(sessions["idle"]?.int ?? 0) idle"]
            if let errored = sessions["errored"]?.int, errored > 0 { details.append("\(errored) errored") }
            if let other = sessions["other"]?.int, other > 0 { details.append("\(other) other") }
            output("Watching: \(sessions["total"]?.int ?? 0) terminal sessions (\(details.joined(separator: ", ")))")
            if let unavailable = sessions["unavailable"]?.int, unavailable > 0 { output("Unavailable during scan: \(unavailable)") }
        } else {
            output("Watching: waiting for the first session count")
        }
        let preferences = try Settings.read(directory: directory)
        output("Checks: every \(durationLabel(preferences.scanSeconds)). "
            + "Capacity retries: every \(durationLabel(preferences.retrySeconds)).")
        let threads = (state["threads"]?.array ?? []).compactMap(\.string)
        output("Scope: " + (threads.isEmpty ? "loaded terminal sessions" : threads.joined(separator: ", ")))
        let saved = state["pending"]?.object ?? [:]
        let pending = enabled ? saved : [:]
        let quotas = pending.values.filter { $0["kind"] == "quota" }.count
        output("Pending capacity retries: \(pending.count - quotas)")
        output("Waiting for quota: \(quotas)")
        if let scanned = state["last_scan_at"]?.number {
            output("Last scan: \(Int(now - scanned)) seconds ago")
        } else {
            output("Waiting for first scan")
        }
        if let error = state["last_error"]?.string, !error.isEmpty { output("Connection: \(error)") }
        for (id, item) in saved.sorted(by: { $0.key < $1.key }) {
            let delay = max(0, Int((item["due_at"]?.number ?? now) - now))
            let model = item["model"]?.string ?? ""
            if item["kind"] == "quota" {
                let reason = ["unknown": "quota status unavailable", "account_changed": "account changed"][item["quota_status"]?.string ?? ""]
                    ?? "waiting for included usage"
                output("Quota wait: \(id) · \(model) · \(reason) · check in \(delay)s")
            } else {
                output("Waiting: \(id) · \(model) · retry in \(delay)s")
            }
        }
        for (id, item) in (state["handled"]?.object ?? [:]).sorted(by: { $0.key < $1.key }) where item["outcome"] == "uncertain" {
            output("Uncertain send: \(id). Check this session manually; it will not be sent twice.")
        }
        try withoutActuallyEscaping(output) { try activity($0) }
    }

    public static func printActivity(directory: URL, hours: Int = 24, limit: Int = 5,
                                     now: Double = Date().timeIntervalSince1970, output: (String) -> Void) throws {
        printActivity(report: try History.report(directory: directory, hours: hours, limit: limit, now: now),
                      hours: hours, now: now, output: output)
    }

    public static func printActivity(report: JSON, hours: Int = 24, now: Double = Date().timeIntervalSince1970,
                                     output: (String) -> Void) {
        func count(_ name: String) -> Int { report[name]?.int ?? 0 }
        output("\nLast \(hours) hours:")
        guard report["available"] == true else {
            output("History will be available after the next watcher startup.")
            return
        }
        output("Capacity errors found: \(count("capacity")) · Retries sent: \(count("retries"))")
        output("Successful: \(count("successful")) · Failed: \(count("failed")) "
            + "(\(count("failed_capacity")) capacity, \(count("failed_other")) other) "
            + "· \(count("interrupted")) interrupted")
        output("Awaiting recovery: \(count("awaiting")) · Uncertain sends: \(count("uncertain"))")
        output("Quota limits found: \(count("quota")) · Quota retries sent: \(count("quota_retries"))")
        output("Quota successful: \(count("quota_successful")) · Failed: \(count("quota_failed")) "
            + "· \(count("quota_interrupted")) interrupted · Awaiting: \(count("quota_awaiting")) "
            + "· Uncertain: \(count("quota_uncertain"))")
        output("Success: 2 minutes of continuously observed healthy activity, or immediate completion.")
        if let since = report["recorded_since"]?.number, since > now - Double(hours) * 3600 {
            output("Recording since: " + localTime(since, "yyyy-MM-dd HH:mm:ss zzz"))
        }
        let recent = report["recent"]?.array ?? []
        if !recent.isEmpty { output("Recent activity:") }
        for event in recent.reversed() {
            let name = event["event"]?.string ?? ""
            var label = ["capacity": "capacity error found", "retry": "retry sent", "quota": "quota limit found",
                         "uncertain": "send uncertain"][name] ?? "None"
            if name == "retry_result" {
                let status = event["status"]?.string ?? ""
                label = "retry " + (status == "completed" ? "successful" : status)
                if event["capacity"]?.isTruthy ?? false { label += " (capacity)" }
            }
            if event["kind"] == "quota" && name != "quota" { label = "quota " + label }
            let thread = event["thread_id"]?.string ?? ""
            // Session IDs begin with a timestamp, so their endings tell neighbors apart.
            output("  \(localTime(event["ts"]?.number ?? 0, "MM-dd HH:mm:ss")) · \(thread.suffix(8)) · \(label)")
        }
    }

    static func localTime(_ seconds: Double, _ format: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter.string(from: Date(timeIntervalSince1970: seconds))
    }
}
