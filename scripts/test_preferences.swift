// Standalone storage QA; no AppKit, worker, daemon, or model requests.
// swiftc native/Preferences.swift scripts/test_preferences.swift -o build/prefs-store-qa
// build/prefs-store-qa [directory-for-Python-cross-check-fixtures]
import Foundation
import Darwin

private struct TestFailure: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

@main
private struct PreferencesTests {
    static let defaults = RetrySettings(retrySeconds: 300, scanSeconds: 60, message: "Keep the selected model. Continue.")
    static var checks = 0

    static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        checks += 1
        guard try condition() else { throw TestFailure(message) }
    }

    static func rejects(_ message: String, _ operation: () throws -> Void) throws {
        checks += 1
        do { try operation() }
        catch {
            guard !error.localizedDescription.isEmpty else { throw TestFailure("\(message): missing actionable error") }
            return
        }
        throw TestFailure("\(message): unexpectedly succeeded")
    }

    static func metadata(_ url: URL) throws -> stat {
        var result = stat()
        guard lstat(url.path, &result) == 0 else { throw TestFailure("Cannot inspect \(url.path)") }
        return result
    }

    static func json(_ settings: RetrySettings) throws -> Data { try JSONEncoder().encode(settings) }

    static func bundle(at url: URL, defaults: Any?) throws -> Bundle {
        let contents = url.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        var info: [String: Any] = ["CFBundleIdentifier": "com.aktay.codex-whip.preferences-test.\(UUID().uuidString)",
                                   "CFBundlePackageType": "BNDL", "CFBundleName": "Preferences QA"]
        if let defaults { info["WhipDefaultSettings"] = defaults }
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        guard let bundle = Bundle(url: url) else { throw TestFailure("Could not open test bundle") }
        return bundle
    }

    static func run(in root: URL, fixtures: URL) throws {
        let fm = FileManager.default
        let directory = root.appendingPathComponent("missing/state", isDirectory: true)
        let store = try PreferencesStore(directory: directory, defaults: defaults)
        try check(try store.read() == defaults, "Missing preferences must return defaults")
        try check(!fm.fileExists(atPath: root.appendingPathComponent("missing").path), "Reading defaults must not create directories")
        try rejects("Invalid injected defaults") {
            _ = try PreferencesStore(directory: directory, defaults: RetrySettings(retrySeconds: 59, scanSeconds: 60, message: "x"))
        }

        let info: [String: Any] = ["retry_seconds": 300, "scan_seconds": 60, "message": defaults.message]
        let validBundle = try bundle(at: root.appendingPathComponent("Valid.bundle"), defaults: info)
        try check(try PreferencesStore.bundledDefaults(in: validBundle) == defaults, "Bundle defaults must match their canonical values")
        let missingBundle = try bundle(at: root.appendingPathComponent("Missing.bundle"), defaults: nil)
        try rejects("Missing bundle defaults") { _ = try PreferencesStore.bundledDefaults(in: missingBundle) }
        for (index, value) in [
            ["retry_seconds": 300.0, "scan_seconds": 60, "message": "x"],
            ["retry_seconds": true, "scan_seconds": 60, "message": "x"],
            ["retry_seconds": 300, "scan_seconds": 60, "message": "x", "extra": 1]
        ].enumerated() {
            let invalidBundle = try bundle(at: root.appendingPathComponent("Invalid\(index).bundle"), defaults: value)
            try rejects("Invalid bundle defaults \(index)") { _ = try PreferencesStore.bundledDefaults(in: invalidBundle) }
        }

        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        let sentinels = ["state.json": Data("pending timers and send journal".utf8),
                         "history.sqlite3": Data("history bytes".utf8), "worker.lock": Data("worker lock bytes".utf8)]
        for (name, data) in sentinels { try data.write(to: directory.appendingPathComponent(name)) }
        let custom = RetrySettings(retrySeconds: 123, scanSeconds: 37, message: "Continue 👩🏽‍💻 using the chosen model.\nKeep working.")
        try store.write(custom)
        let path = directory.appendingPathComponent("settings.json")
        try check(try store.read() == custom, "Custom intervals and message must round trip")
        let legacyData = Data(#"{"retry_seconds":777,"scan_seconds":123,"message":"My saved continuation."}"#.utf8)
        try legacyData.write(to: path)
        let legacy = try store.read()
        try check(legacy == RetrySettings(retrySeconds: 777, scanSeconds: 123, message: "My saved continuation."), "Existing preferences must keep their exact values and default sound off")
        try check(try Data(contentsOf: path) == legacyData, "Reading old preferences must not rewrite them")
        let audible = try store.update { $0.soundEnabled = true }
        try check(audible.retrySeconds == legacy.retrySeconds && audible.scanSeconds == legacy.scanSeconds && audible.message == legacy.message, "Enabling sound must preserve all existing preferences")
        try check(try store.read().soundEnabled, "Sound on must persist as a JSON Boolean")
        try store.update { $0.soundEnabled = false }
        try check(try !store.read().soundEnabled, "Sound off must persist")
        try store.write(custom)
        try check(try metadata(path).st_mode & 0o777 == 0o600, "Preferences must be mode 0600")
        try check(try metadata(directory).st_mode & 0o777 == 0o700, "State directory must be mode 0700")
        for (name, data) in sentinels {
            try check(try Data(contentsOf: directory.appendingPathComponent(name)) == data, "Saving must preserve \(name)")
        }

        let external = RetrySettings(retrySeconds: 900, scanSeconds: 121, message: "External CLI edit — keep this message")
        try json(external).write(to: path, options: .atomic)
        let updated = try store.update { $0.retrySeconds = 600 }
        try check(updated == RetrySettings(retrySeconds: 600, scanSeconds: 121, message: external.message), "An update must reread CLI edits and preserve other fields")
        try check(try store.read() == updated, "Read must observe the latest write")

        // An already-open reader sees a complete old document after atomic replacement.
        let oldData = try Data(contentsOf: path)
        let oldMetadata = try metadata(path)
        let reader = open(path.path, O_RDONLY | O_CLOEXEC)
        guard reader >= 0 else { throw TestFailure("Cannot open atomicity reader") }
        defer { close(reader) }
        try store.update { $0.scanSeconds = 45 }
        var bytes = [UInt8](repeating: 0, count: oldData.count + 1)
        let count = Darwin.read(reader, &bytes, bytes.count)
        try check(count == oldData.count && Data(bytes.prefix(count)) == oldData, "Atomic save must preserve the complete document for existing readers")
        try check(try metadata(path).st_ino != oldMetadata.st_ino, "A save must replace the file rather than truncate it")
        try check(try metadata(path).st_mode & 0o777 == 0o600, "Replacement preferences must remain private")

        let concurrent = RetrySettings(retrySeconds: 720, scanSeconds: 180, message: "Newer external edit")
        try rejects("A concurrent external edit must be preserved") {
            try store.update {
                $0.retrySeconds = 3600
                try! json(concurrent).write(to: path, options: .atomic)
            }
        }
        try check(try store.read() == concurrent, "A detected concurrent edit must not be overwritten")

        let invalidDocuments = [
            "{", "[]", "null", "{}",
            #"{"retry_seconds":300,"scan_seconds":60,"message":"x","extra":1}"#,
            #"{"retry_seconds":true,"scan_seconds":60,"message":"x"}"#,
            #"{"retry_seconds":300.0,"scan_seconds":60,"message":"x"}"#,
            #"{"retry_seconds":3e2,"scan_seconds":60,"message":"x"}"#,
            #"{"retry_seconds":9223372036854775808,"scan_seconds":60,"message":"x"}"#,
            #"{"retry_seconds":"300","scan_seconds":60,"message":"x"}"#,
            #"{"retry_seconds":59,"scan_seconds":60,"message":"x"}"#,
            #"{"retry_seconds":86401,"scan_seconds":60,"message":"x"}"#,
            #"{"retry_seconds":300,"scan_seconds":14,"message":"x"}"#,
            #"{"retry_seconds":300,"scan_seconds":3601,"message":"x"}"#,
            #"{"retry_seconds":300,"scan_seconds":true,"message":"x"}"#,
            #"{"retry_seconds":300,"scan_seconds":60.0,"message":"x"}"#,
            #"{"retry_seconds":300,"scan_seconds":60,"message":5}"#,
            #"{"retry_seconds":300,"scan_seconds":60,"message":null}"#,
            #"{"retry_seconds":300,"scan_seconds":60,"message":"x","sound_enabled":1}"#,
            #"{"retry_seconds":300,"scan_seconds":60,"message":"x","sound_enabled":0}"#,
            #"{"retry_seconds":300,"scan_seconds":60,"message":"x","sound_enabled":null}"#,
            #"{"retry_seconds":300,"scan_seconds":60,"message":"x","sound_enabled":"true"}"#,
            #"{"retry_seconds":300,"scan_seconds":60,"message":" \n\t\u001c\u0085\u00a0\u3000"}"#
        ]
        for (index, document) in invalidDocuments.enumerated() {
            let data = Data(document.utf8)
            try data.write(to: path)
            try rejects("Invalid document \(index) read") { _ = try store.read() }
            try rejects("Invalid document \(index) update") { _ = try store.update { $0.retrySeconds = 600 } }
            try rejects("Invalid document \(index) overwrite") { try store.write(defaults) }
            try check(try Data(contentsOf: path) == data, "Invalid document \(index) must remain untouched")
        }
        try json(custom).write(to: path)
        for message in ["", "\t\n\u{1C}\u{1D}\u{1E}\u{1F}\u{85}\u{A0}\u{3000}", String(repeating: "😀", count: 4001), String(repeating: "e\u{301}", count: 2001)] {
            let before = try Data(contentsOf: path)
            try rejects("Invalid message must not save") { try store.update { $0.message = message } }
            try check(try Data(contentsOf: path) == before, "Rejected messages must not change preferences")
        }
        try fm.createDirectory(at: fixtures, withIntermediateDirectories: true)
        for (name, settings) in [
            ("custom", custom),
            ("sound-on", RetrySettings(retrySeconds: 777, scanSeconds: 123, message: "Same custom message", soundEnabled: true)),
            ("minimum", RetrySettings(retrySeconds: 60, scanSeconds: 15, message: String(repeating: "😀", count: 4000))),
            ("maximum", RetrySettings(retrySeconds: 86400, scanSeconds: 3600, message: String(repeating: "e\u{301}", count: 2000)))
        ] {
            try store.write(settings)
            try check(try store.read() == settings, "Valid Unicode code point and interval boundaries must save")
            try Data(contentsOf: path).write(to: fixtures.appendingPathComponent("\(name).json"))
        }

        try fm.removeItem(at: path)
        let victim = root.appendingPathComponent("victim.json")
        let victimData = try json(custom)
        try victimData.write(to: victim)
        try fm.createSymbolicLink(at: path, withDestinationURL: victim)
        try rejects("A symbolic-link settings file must not read") { _ = try store.read() }
        try rejects("A symbolic-link settings file must not save") { try store.write(defaults) }
        try check(try Data(contentsOf: victim) == victimData, "A symbolic-link victim must remain untouched")
        try check(try metadata(path).st_mode & S_IFMT == S_IFLNK, "Rejected symbolic links must remain untouched")
        try fm.removeItem(at: path)
        try fm.createDirectory(at: path, withIntermediateDirectories: false)
        try rejects("A directory settings target must not read") { _ = try store.read() }
        try rejects("A directory settings target must not save") { try store.write(defaults) }
        try fm.removeItem(at: path)
        guard mkfifo(path.path, 0o600) == 0 else { throw TestFailure("Cannot create test FIFO") }
        try rejects("A FIFO target must fail without blocking") { _ = try store.read() }
        try rejects("A FIFO target must not save") { try store.write(defaults) }
        try fm.removeItem(at: path)

        let linkedDirectory = root.appendingPathComponent("linked-state")
        try fm.createSymbolicLink(at: linkedDirectory, withDestinationURL: directory)
        let linkedStore = try PreferencesStore(directory: linkedDirectory, defaults: defaults)
        try rejects("A symbolic-link state directory must not read") { _ = try linkedStore.read() }
        try rejects("A symbolic-link state directory must not save") { try linkedStore.write(custom) }
        let blockedDirectory = try PreferencesStore(directory: victim.appendingPathComponent("state"), defaults: defaults)
        try rejects("A non-directory ancestor must not read") { _ = try blockedDirectory.read() }
        try rejects("A non-directory ancestor must not save") { try blockedDirectory.write(custom) }
        try check(try Data(contentsOf: victim) == victimData, "Invalid paths must not alter existing files")

        try store.write(custom)
        let savedBeforeMove = try Data(contentsOf: path)
        let moved = root.appendingPathComponent("moved-state")
        try rejects("A state directory replaced during saving must not receive the stale edit") {
            try store.update {
                $0.message = "stale"
                try! fm.moveItem(at: directory, to: moved)
                try! fm.createDirectory(at: directory, withIntermediateDirectories: true)
                try! json(external).write(to: path)
            }
        }
        try check(try store.read() == external, "A new state directory must retain its own settings")
        try check(try Data(contentsOf: moved.appendingPathComponent("settings.json")) == savedBeforeMove, "The moved directory must retain its settings")
        for candidate in [directory, moved] {
            try check(try fm.contentsOfDirectory(atPath: candidate.path).allSatisfy { !$0.hasPrefix(".settings-") }, "Temporary settings files must be cleaned up")
        }
        for (name, data) in sentinels {
            try check(try Data(contentsOf: moved.appendingPathComponent(name)) == data, "All storage tests must preserve \(name)")
        }

        let started = ProcessInfo.processInfo.systemUptime
        for _ in 0..<1000 { _ = try store.read() }
        let meanMilliseconds = (ProcessInfo.processInfo.systemUptime - started) * 1000 / 1000
        print(String(format: "Mean direct read: %.4f ms (1000 reads)", meanMilliseconds))
    }

    static func main() {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("codex-whip-preferences-qa-\(UUID().uuidString)", isDirectory: true)
        let fixtures = CommandLine.arguments.dropFirst().first.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? fm.temporaryDirectory.appendingPathComponent("codex-whip-preferences-fixtures-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            defer { try? fm.removeItem(at: root) }
            try run(in: root, fixtures: fixtures)
            print("PASS: \(checks) preference storage checks")
            print("Python cross-check fixtures: \(fixtures.path)")
        } catch {
            fputs("FAIL: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
