// Ported from tests/test_install.py: installation checks using temporary directories and a mocked
// login service. ServiceEnvironment points the home, launch agent and command link into a
// temporary directory, and RecordingLaunchd (AppHelperTests.swift) answers every launchctl call,
// so nothing reaches the real ~/Library or launchd.
//
// Python patched time.time to 20000. RetryState stamps enabled_at from the wall clock and has no
// clock seam, so enabled_at is checked to fall inside the start call instead.

import Foundation
import Testing
@testable import WhipEngine

private struct InstallSandbox {
    let root: URL
    let home: URL
    let directory: URL
    let codexHome: URL
    let plist: URL
    let command: URL
    let script: URL
    let launchd = RecordingLaunchd(running: false)

    init() throws {
        root = try HelperProcess.temporaryDirectory("ckg-install-")
        home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        directory = home.appendingPathComponent("Library/Application Support/Codex Whip")
        codexHome = home.appendingPathComponent(".codex")
        plist = home.appendingPathComponent("Library/LaunchAgents/com.turushan.codex-whip.plist")
        command = home.appendingPathComponent(".local/bin/codex-whip")
        // Stands in for codex_whip.py: the executable the command link and launch job point at.
        let built = root.appendingPathComponent("build/codex-whip")
        try FileManager.default.createDirectory(at: built.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("test executable".utf8).write(to: built)
        script = Paths.resolve(built.path)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    var env: ServiceEnvironment {
        let script = script
        return ServiceEnvironment(home: home, variables: [:], launchctl: launchd.launchctl,
                                  monotonic: { 0 }, sleep: { _ in }, executable: { script })
    }

    func start(preserveState: Bool = false, threads: [String] = []) throws {
        try Service.startService(directory: directory, codexHome: codexHome, threads: threads,
                                 preserveState: preserveState, env: env, output: { _ in })
    }

    func state() throws -> JSON { try FileStore.readJSON(directory.appendingPathComponent("state.json")) }

    static let existing: JSON = [
        "version": 1,
        "enabled_at": 10000,
        "threads": ["selected-session"],
        "pending": ["selected-session": ["turn_id": "failure", "due_at": 20500,
                                         "model": "selected-model", "effort": "xhigh"]],
        "handled": ["earlier-session": ["turn_id": "earlier-failure", "outcome": "submitted",
                                        "retry_turn_id": "earlier-retry"]],
        "paused": ["paused-session": true],
        "last_error": nil,
    ]

    @discardableResult
    func existingState() throws -> JSON {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(try Self.existing.serialized().utf8).write(to: directory.appendingPathComponent("state.json"))
        try Data("existing-history-must-stay".utf8).write(to: directory.appendingPathComponent("history.sqlite3"))
        return Self.existing
    }

    /// launchctl calls other than `print`, which Python answered through the patched service_running.
    var runnerCalls: [[String]] { launchd.calls.filter { $0.first != "print" } }
}

/// Python-style number equality: integers and doubles with the same value compare equal.
private func numeric(_ value: JSON) -> JSON {
    switch value {
    case .int(let number): return .double(Double(number))
    case .array(let items): return .array(items.map(numeric))
    case .object(let fields): return .object(fields.mapValues(numeric))
    default: return value
    }
}

@Suite struct InstallTests {
    // test_fresh_start_installs_command_and_login_job
    @Test func freshStartInstallsCommandAndLoginJob() throws {
        let sandbox = try InstallSandbox()
        defer { sandbox.remove() }
        let before = Date().timeIntervalSince1970
        try sandbox.start(threads: ["one-session"])
        let after = Date().timeIntervalSince1970
        let state = try sandbox.state()
        let enabledAt = try #require(state["enabled_at"]?.number)
        #expect(enabledAt >= before && enabledAt <= after)
        #expect(state["threads"] == ["one-session"])
        #expect(state["pending"] == [:])
        #expect(state["handled"] == [:])
        #expect(state["paused"] == [:])
        #expect(Service.isSymlink(sandbox.command))
        #expect(Paths.resolve(sandbox.command.path) == sandbox.script)
        let agent = try #require(try PropertyListSerialization.propertyList(
            from: Data(contentsOf: sandbox.plist), format: nil) as? [String: Any])
        #expect(agent["Label"] as? String == "com.turushan.codex-whip")
        #expect(agent["RunAtLoad"] as? Bool == true)
        let program = try #require(agent["ProgramArguments"] as? [String])
        #expect(program.contains(sandbox.script.path))
        #expect(program.contains(sandbox.directory.path))
        #expect(program.contains(sandbox.codexHome.path))
        #expect(program.last == "_run")
        #expect(sandbox.runnerCalls.count == 1, "\(sandbox.launchd.calls)")
        #expect(sandbox.runnerCalls.first?.first == "bootstrap")
    }

    // test_preserved_start_keeps_timers_journal_scope_and_history
    @Test func preservedStartKeepsTimersJournalScopeAndHistory() throws {
        let sandbox = try InstallSandbox()
        defer { sandbox.remove() }
        let original = try sandbox.existingState()
        try sandbox.start(preserveState: true)
        let state = try sandbox.state()
        for key in ["enabled_at", "threads", "pending", "handled", "paused"] {
            // Python compares 10000 and 10000.0 as equal; the saved state writes numbers as doubles.
            #expect(state[key].map(numeric) == original[key].map(numeric), "\(key)")
        }
        #expect(try Data(contentsOf: sandbox.directory.appendingPathComponent("history.sqlite3"))
                == Data("existing-history-must-stay".utf8))
        #expect(FileManager.default.fileExists(atPath: sandbox.plist.path))
    }

    // test_fresh_restart_resets_retry_scope_but_retains_history
    @Test func freshRestartResetsRetryScopeButRetainsHistory() throws {
        let sandbox = try InstallSandbox()
        defer { sandbox.remove() }
        try sandbox.existingState()
        let before = Date().timeIntervalSince1970
        try sandbox.start(preserveState: false, threads: ["new-session"])
        let after = Date().timeIntervalSince1970
        let state = try sandbox.state()
        let enabledAt = try #require(state["enabled_at"]?.number)
        #expect(enabledAt >= before && enabledAt <= after)
        #expect(state["threads"] == ["new-session"])
        #expect(state["pending"] == [:])
        #expect(state["handled"] == [:])
        #expect(state["paused"] == [:])
        #expect(try Data(contentsOf: sandbox.directory.appendingPathComponent("history.sqlite3"))
                == Data("existing-history-must-stay".utf8))
    }

    // test_preserve_flag_without_previous_state_installs_fresh
    @Test func preserveFlagWithoutPreviousStateInstallsFresh() throws {
        let sandbox = try InstallSandbox()
        defer { sandbox.remove() }
        let before = Date().timeIntervalSince1970
        try sandbox.start(preserveState: true)
        let after = Date().timeIntervalSince1970
        let state = try sandbox.state()
        let enabledAt = try #require(state["enabled_at"]?.number)
        #expect(enabledAt >= before && enabledAt <= after)
        #expect(state["pending"] == [:])
    }

    // test_existing_matching_command_is_kept_on_reinstall
    @Test func existingMatchingCommandIsKeptOnReinstall() throws {
        let sandbox = try InstallSandbox()
        defer { sandbox.remove() }
        try FileManager.default.createDirectory(at: sandbox.command.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: sandbox.command, withDestinationURL: sandbox.script)
        try sandbox.start()
        #expect(Paths.resolve(sandbox.command.path) == sandbox.script)
        #expect(FileManager.default.fileExists(atPath: sandbox.plist.path))
    }

    // test_different_existing_command_is_never_replaced_or_started
    @Test func differentExistingCommandIsNeverReplacedOrStarted() throws {
        let sandbox = try InstallSandbox()
        defer { sandbox.remove() }
        try FileManager.default.createDirectory(at: sandbox.command.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("user's existing command".utf8).write(to: sandbox.command)
        do {
            try sandbox.start()
            Issue.record("startService replaced an existing command")
        } catch let error as WhipError {
            #expect(error.description.contains("Refusing to replace an existing command"), "\(error)")
        }
        #expect(try String(contentsOf: sandbox.command, encoding: .utf8) == "user's existing command")
        #expect(!FileManager.default.fileExists(atPath: sandbox.plist.path))
        #expect(sandbox.runnerCalls.isEmpty, "\(sandbox.launchd.calls)")
    }
}
