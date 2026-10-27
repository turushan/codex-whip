import Foundation

/// The `codex-whip` command: the CLI service, read-only checks, and the app's internal commands.
public enum Command {
    static let usage = """
        usage: codex-whip [--state-dir STATE_DIR] [--codex-home CODEX_HOME] COMMAND ...

        Retry capacity failures and resume quota-blocked loaded Codex terminal sessions.

        commands:
          start       Enable future capacity retries and start at login
                        --thread UUID       Watch only this session (repeatable)
                        --preserve-state    Keep saved activation time, pending timers, and session scope
          stop        Disable retries and remove the login job
          status      Show pending retries and connection health
          doctor      Check Codex connection without submitting a turn
          logs        Show the last 30 log lines
          report      Show capacity and retry activity (--hours 1-48, default 24)
          settings    Read settings and defaults as JSON
          configure   Save validated settings from JSON on stdin
          prepare     Prepare saved state for the native app (internal)
          dashboard   Read the native app dashboard as JSON (internal)
          version     Print the engine version
        """

    struct UsageError: Error { let message: String }

    /// Runs the command and returns its exit status: 0, 1 for a failure, 2 for invalid usage.
    public static func main(_ arguments: [String], stdout: (String) -> Void = { print($0) },
                            stderr: (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) },
                            stdin: () -> Data = { FileHandle.standardInput.readDataToEndOfFile() }) -> Int32 {
        var stateDirectory = Paths.defaultStateDirectory.path
        var codexHome = Paths.defaultCodexHome.path
        var rest = arguments[...]
        func value(_ name: String, _ item: String) throws -> String {
            if item.hasPrefix(name + "=") { return String(item.dropFirst(name.count + 1)) }
            rest.removeFirst()
            guard let next = rest.first, !next.hasPrefix("-") || next == "-" else {
                throw UsageError(message: "argument \(name): expected one argument")
            }
            return next
        }
        do {
            while let item = rest.first, item.hasPrefix("-") {
                if item == "-h" || item == "--help" {
                    stdout(usage)
                    return 0
                } else if item == "--state-dir" || item.hasPrefix("--state-dir=") {
                    stateDirectory = try value("--state-dir", item)
                } else if item == "--codex-home" || item.hasPrefix("--codex-home=") {
                    codexHome = try value("--codex-home", item)
                } else {
                    throw UsageError(message: "unrecognized arguments: \(item)")
                }
                rest.removeFirst()
            }
            guard let command = rest.popFirst() else { throw UsageError(message: "the following arguments are required: command") }
            let options = Array(rest)
            let directory = Paths.resolve(stateDirectory)
            let home = Paths.resolve(codexHome)
            let known = ["start", "stop", "status", "doctor", "logs", "report", "prepare", "dashboard", "settings",
                         "configure", "_run", "version"]
            guard known.contains(command) else {
                throw UsageError(message: "argument command: invalid choice: '\(command)'")
            }
            var threads: [String] = []
            var preserve = false
            var hours = 24
            var index = 0
            while index < options.count {
                let option = options[index]
                switch (command, option) {
                case (_, "-h"), (_, "--help"):
                    stdout(usage)
                    return 0
                case ("start", "--thread"):
                    guard index + 1 < options.count else { throw UsageError(message: "argument --thread: expected one argument") }
                    threads.append(options[index + 1])
                    index += 1
                case ("start", _) where option.hasPrefix("--thread="):
                    threads.append(String(option.dropFirst("--thread=".count)))
                case ("start", "--preserve-state"):
                    preserve = true
                case ("report", _) where option == "--hours" || option.hasPrefix("--hours="):
                    let text: String
                    if option == "--hours" {
                        guard index + 1 < options.count else { throw UsageError(message: "argument --hours: expected one argument") }
                        text = options[index + 1]
                        index += 1
                    } else {
                        text = String(option.dropFirst("--hours=".count))
                    }
                    guard let number = Int(text), (1...48).contains(number) else {
                        throw UsageError(message: "argument --hours: invalid choice: '\(text)' (choose from 1-48)")
                    }
                    hours = number
                default:
                    throw UsageError(message: "unrecognized arguments: \(options[index...].joined(separator: " "))")
                }
                index += 1
            }
            switch command {
            case "start":
                try Service.doctor(codexHome: home, output: stdout)
                try Service.startService(directory: directory, codexHome: home, threads: threads, preserveState: preserve, output: stdout)
            case "stop":
                try Service.stopService()
                stdout("Stopped. Automatic retries and start at login are disabled.")
            case "status":
                try Service.status(directory: directory, activity: { try Service.printActivity(directory: directory, output: $0) },
                                   output: stdout)
            case "doctor":
                try Service.doctor(codexHome: home, output: stdout)
            case "report":
                try Service.printActivity(directory: directory, hours: hours, limit: 100, output: stdout)
            case "prepare":
                try Service.prepareState(directory: directory, codexHome: home)
            case "dashboard":
                stdout(try Service.dashboard(directory: directory).serialized())
            case "settings":
                stdout(try Settings.envelope(directory: directory).serialized())
            case "configure":
                let payload = stdin()
                guard payload.count <= 65536 else { throw SettingsError("Settings JSON exceeds the allowed size.") }
                let value: JSON
                do { value = try JSON.parse(payload) } catch { throw SettingsError("Settings JSON is invalid: \(error)") }
                try Settings.save(value, directory: directory)
                stdout(try Settings.envelope(directory: directory).serialized())
            case "logs":
                let path = directory.appendingPathComponent("worker.log")
                if let text = try? String(contentsOf: path, encoding: .utf8) {
                    var lines = text.components(separatedBy: "\n")
                    if lines.last == "" { lines.removeLast() }
                    stdout(lines.suffix(30).joined(separator: "\n"))
                } else {
                    stdout("No log yet.")
                }
            case "version":
                stdout(engineVersion)
            default:
                try runWorker(directory: directory, codexHome: home)
            }
            return 0
        } catch let error as UsageError {
            stderr("usage: codex-whip [--state-dir STATE_DIR] [--codex-home CODEX_HOME] COMMAND ...")
            stderr("codex-whip: error: \(error.message)")
            return 2
        } catch {
            stderr("codex-whip: \(describe(error))")
            return 1
        }
    }
}
