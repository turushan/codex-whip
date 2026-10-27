import Foundation
import Testing
@testable import WhipEngine

// Port of tests/test_desktop_runner.py.
//
// The Python suite patches time.time, time.monotonic, signal.signal, History, RetrySound,
// log_emitter, default_state_directory and resolve_socket. DesktopCommand.watch only offers
// makeBackend/makeMetadata factories, so:
// - resolve_socket: a placeholder file at codex/app-server-control/app-server-control.sock
//   satisfies the real resolveSocket.
// - signal.signal: the SIGINT/SIGTERM dispositions are read with sigaction before and after.
// - time.time: assertions that depended on the patched clock are made relative to the real
//   clock and marked NEEDS SEAM where an exact value was asserted.
// - History, RetrySound, default_state_directory and `metadata.close` have no seam; see the
//   NEEDS SEAM notes on the affected assertions and tests.
// The suite is serialized because watch changes process-wide signal dispositions.

private func signalDisposition(_ number: Int32) -> Int {
    var action = sigaction()
    sigaction(number, nil, &action)
    return unsafeBitCast(action.__sigaction_u.__sa_handler, to: Int.self)
}

private struct FileEntry: Equatable {
    let mode: mode_t
    let contents: Data?
}

/// tests/test_desktop_runner.py `DesktopRunnerTests.setUp`.
private final class RunnerHarness {
    let root: URL
    let directory: URL
    let home: URL
    let peer: DesktopPeerStub
    let metadata = MetadataPeerStub()
    var backends: [DesktopRPC] = []
    var factoryError: Error?
    var backendError: Error?
    let originalSignals: [Int]

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("desktop-runner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        directory = root.appendingPathComponent("prototype")
        home = root.appendingPathComponent("codex")
        // Stands in for the patched resolve_socket; the metadata factory never connects to it.
        let control = home.appendingPathComponent("app-server-control")
        try FileManager.default.createDirectory(at: control, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: control.appendingPathComponent("app-server-control.sock").path, contents: nil)
        peer = try DesktopPeerStub()
        originalSignals = [signalDisposition(SIGINT), signalDisposition(SIGTERM)]
    }

    deinit {
        peer.stop()
        try? FileManager.default.removeItem(at: root)
    }

    func metadataFactory(_ path: URL, _ shouldStop: @escaping () -> Bool) throws -> RPCClient {
        if let factoryError { throw factoryError }
        metadata.shouldStop = shouldStop
        return metadata
    }

    func backendFactory(_ socketPath: URL, _ metadata: RPCClient, _ threads: [String],
                        _ shouldStop: @escaping () -> Bool) throws -> DesktopRPC {
        if let backendError { throw backendError }
        let backend = try DesktopRPC(socketPath: socketPath, metadata: metadata, threadIDs: threads,
                                     shouldStop: shouldStop, makeIPC: peer.factory)
        backends.append(backend)
        return backend
    }

    func watch(directory: URL? = nil, once: Bool = true) throws -> Bool {
        var hooks = DesktopCommand.Hooks()
        hooks.makeBackend = { [unowned self] in try self.backendFactory($0, $1, $2, $3) }
        hooks.makeMetadata = { [unowned self] in try self.metadataFactory($0, $1) }
        return try DesktopCommand.watch(directory: directory ?? self.directory, codexHome: home, threadID: "thread",
                                        once: once, hooks: hooks)
    }

    @discardableResult
    func markJournal(_ changes: [String: JSON] = [:]) throws -> JSON {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        var state: JSON = ["version": 1, "enabled_at": 1000, "threads": ["thread"],
                           "pending": [:], "handled": [:], "paused": [:], "last_error": nil,
                           "control_backend": "desktop-ipc"]
        for (key, value) in changes { state[key] = value }
        try FileStore.writeJSON(state, to: directory.appendingPathComponent("state.json"))
        return state
    }

    func state() throws -> JSON {
        try JSON.parse(Data(contentsOf: directory.appendingPathComponent("state.json")))
    }

    var signalsRestored: Bool { [signalDisposition(SIGINT), signalDisposition(SIGTERM)] == originalSignals }

    /// tests/test_desktop_runner.py `assert_resources_closed`.
    /// NEEDS SEAM: History and RetrySound are constructed inside DesktopCommand.watch, so their
    /// close() calls cannot be observed; inject `makeHistory` and `makeSound` factories.
    /// DesktopRPC is final, so `backend.close.assert_called_once()` is approximated by its
    /// cleared anchors.
    func resourcesClosed() -> Bool {
        signalsRestored && backends.allSatisfy { $0.anchors.isEmpty } && peer.cleanConnections()
    }

    static func snapshot(_ directory: URL) -> [String: FileEntry]? {
        let manager = FileManager.default
        guard manager.fileExists(atPath: directory.path) else { return nil }
        var result: [String: FileEntry] = [:]
        var paths = [""]
        if let enumerator = manager.enumerator(atPath: directory.path) {
            while let item = enumerator.nextObject() as? String { paths.append(item) }
        }
        for relative in paths {
            let url = relative.isEmpty ? directory : directory.appendingPathComponent(relative)
            var info = stat()
            stat(url.path, &info)
            let isFile = info.st_mode & S_IFMT == S_IFREG
            result[relative.isEmpty ? "." : relative] = FileEntry(mode: info.st_mode & 0o7777,
                                                                  contents: isFile ? try? Data(contentsOf: url) : nil)
        }
        return result
    }

    static func mode(_ url: URL) -> mode_t {
        var info = stat()
        stat(url.path, &info)
        return info.st_mode & 0o7777
    }
}

@Suite(.serialized) struct DesktopRunnerTests {
    // test_doctor_reads_only_and_reports_no_identifiers_or_contents
    @Test func doctorReadsOnlyAndReportsNoIdentifiersOrContents() throws {
        let h = try RunnerHarness()
        let backend = try h.backendFactory(URL(fileURLWithPath: "unused.sock"), h.metadata, ["thread"], { false })
        let result = try DesktopCommand.diagnostic(backend, "thread")
        backend.close()
        #expect(result["connected"] == true)
        #expect(result["capacity_failure"] == true)
        #expect(result["saved_turn_matches"] == true)
        #expect(result["completion_timestamp_verified"] == true)
        #expect(result["message_sent"] == false)
        #expect(result["quota_recovery_supported"] == false)
        #expect(!FileManager.default.fileExists(atPath: h.directory.path))
        #expect(h.peer.starts.isEmpty)
        #expect(h.metadata.calls.allSatisfy { $0.method == "thread/turns/list" })
        let output = try result.serialized()
        #expect(!output.contains("private"))
        #expect(!output.contains("failed-turn"))
        #expect(!output.contains("owner"))
        #expect(h.resourcesClosed())
    }

    // test_doctor_distinguishes_unverified_persisted_time_without_deriving_it
    @Test func doctorDistinguishesUnverifiedPersistedTimeWithoutDerivingIt() throws {
        let h = try RunnerHarness()
        h.metadata.turns[0]["completedAt"] = nil
        var backend = try h.backendFactory(URL(fileURLWithPath: "unused.sock"), h.metadata, ["thread"], { false })
        var result = try DesktopCommand.diagnostic(backend, "thread")
        backend.close()
        #expect(result["saved_turn_matches"] == true)
        #expect(result["completion_timestamp_verified"] == false)
        #expect(result["message_sent"] == false)
        h.metadata.error = RPCError.request("private metadata details")
        backend = try h.backendFactory(URL(fileURLWithPath: "unused.sock"), h.metadata, ["thread"], { false })
        result = try DesktopCommand.diagnostic(backend, "thread")
        backend.close()
        #expect(result["saved_turn_matches"] == false)
        #expect(result["completion_timestamp_verified"] == false)
        #expect(!(try result.serialized()).contains("private"))
    }

    // test_new_once_watcher_is_private_silent_and_uses_a_separate_journal
    @Test func newOnceWatcherIsPrivateSilentAndUsesASeparateJournal() throws {
        let h = try RunnerHarness()
        let before = Date().timeIntervalSince1970
        #expect(try h.watch())
        let after = Date().timeIntervalSince1970
        let state = try h.state()
        #expect(state["control_backend"] == "desktop-ipc")
        #expect(state["threads"] == ["thread"])
        // NEEDS SEAM: time.time. Python asserts enabled_at == 1200 from a patched clock; watch
        // reads Date() directly, so this checks the real activation time instead.
        let enabled = try #require(state["enabled_at"]?.number)
        #expect(enabled >= before.rounded(.down) && enabled <= after.rounded(.up))
        #expect(state["pending"] == [:])
        var expected = Settings.defaults
        expected.soundEnabled = false
        #expect(try Settings.read(directory: h.directory) == expected)
        // NEEDS SEAM: RetrySound. Python asserts audio.configurations == [False]; inject a sound
        // factory into DesktopCommand.watch to observe configure().
        #expect(h.peer.starts.isEmpty)
        // NEEDS SEAM: default_state_directory. Python asserts the patched production directory
        // stays absent; Paths.defaultStateDirectory is the real ~/Library path and is not checked.
        #expect(RunnerHarness.mode(h.directory) == 0o700)
        for name in ["state.json", "settings.json", "worker.log"] {
            #expect(RunnerHarness.mode(h.directory.appendingPathComponent(name)) == 0o600, "\(name)")
        }
        // NEEDS SEAM: metadata.close. Python asserts metadata.close() was called once; watch only
        // closes `metadata as? WebSocketRPC` (DesktopCommand.swift closeConnections), and RPCClient
        // has no close(), so a factory-made metadata client is never closed.
        #expect(h.resourcesClosed())
    }

    // test_production_directory_and_alias_are_rejected_without_file_changes
    // NEEDS SEAM: core.default_state_directory. DesktopCommand.watch compares against
    // Paths.defaultStateDirectory (~/Library/Application Support/Codex Whip), which tests must
    // not touch. Inject the production directory (for example a `productionDirectory: URL`
    // parameter) to port this test.
    @Test(.disabled("NEEDS SEAM: Paths.defaultStateDirectory cannot be redirected to a temporary directory"))
    func productionDirectoryAndAliasAreRejectedWithoutFileChanges() {}

    // test_unmarked_custom_and_other_scope_journals_are_rejected_without_changes
    @Test func unmarkedCustomAndOtherScopeJournalsAreRejectedWithoutChanges() throws {
        let h = try RunnerHarness()
        let cases: [JSON] = [
            ["version": 1, "threads": ["thread"], "enabled_at": 1000],
            ["version": 1, "threads": ["other"], "control_backend": "desktop-ipc"],
            ["version": 1, "threads": ["thread"], "control_backend": "cli"],
        ]
        for (index, state) in cases.enumerated() {
            let directory = h.root.appendingPathComponent("foreign-\(index)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o755])
            try Data(state.serialized().utf8).write(to: directory.appendingPathComponent("state.json"))
            try Data("foreign settings".utf8).write(to: directory.appendingPathComponent("settings.json"))
            let before = RunnerHarness.snapshot(directory)
            #expect(throws: WhipError.self, "case \(index)") { _ = try h.watch(directory: directory) }
            #expect(RunnerHarness.snapshot(directory) == before, "case \(index)")
        }
        #expect(h.metadata.calls.isEmpty)
        // Python asserts signal.signal was never called; the dispositions are compared instead.
        #expect(h.signalsRestored)
    }

    // test_nonempty_unmarked_directory_is_rejected_without_changes
    @Test func nonemptyUnmarkedDirectoryIsRejectedWithoutChanges() throws {
        let h = try RunnerHarness()
        try FileManager.default.createDirectory(at: h.directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o755])
        try Data("existing settings".utf8).write(to: h.directory.appendingPathComponent("settings.json"))
        let before = RunnerHarness.snapshot(h.directory)
        #expect(throws: WhipError.self) { _ = try h.watch() }
        #expect(RunnerHarness.snapshot(h.directory) == before)
        #expect(h.signalsRestored)
    }

    // test_malformed_non_object_journal_is_rejected_without_file_changes
    @Test func malformedNonObjectJournalIsRejectedWithoutFileChanges() throws {
        let h = try RunnerHarness()
        try FileManager.default.createDirectory(at: h.directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o755])
        let values: [JSON] = [[], nil, "foreign data"]
        for value in values {
            try Data(value.serialized().utf8).write(to: h.directory.appendingPathComponent("state.json"))
            let before = RunnerHarness.snapshot(h.directory)
            #expect(throws: WhipError.self, "value \(value)") { _ = try h.watch() }
            #expect(RunnerHarness.snapshot(h.directory) == before, "value \(value)")
        }
        #expect(h.signalsRestored)
    }

    // test_marked_pending_journal_and_exact_scope_survive_restart
    @Test func markedPendingJournalAndExactScopeSurviveRestart() throws {
        let h = try RunnerHarness()
        try h.markJournal(["handled": ["earlier": ["turn_id": "old", "outcome": "cancelled"]],
                           "paused": ["other-paused": true]])
        // Python runs at clock 1100 and then 1200. With the real clock the second run follows
        // within seconds, still well before the 180 second retry is due.
        #expect(try h.watch())
        let before = try h.state()
        #expect(before[backendPath: ["pending", "thread"]] != nil)
        #expect(try h.watch())
        let after = try h.state()
        for name in ["enabled_at", "threads", "pending", "handled", "paused", "control_backend"] {
            #expect(after[name] == before[name], "\(name)")
        }
        #expect(h.peer.starts.isEmpty)
        #expect(h.resourcesClosed())
    }

    // test_legacy_settings_keep_custom_intervals_message_and_sound_off
    @Test func legacySettingsKeepCustomIntervalsMessageAndSoundOff() throws {
        let h = try RunnerHarness()
        try h.markJournal()
        let message = "My exact message 👩🏽‍💻.\nContinue."
        let custom: JSON = ["retry_seconds": 777, "scan_seconds": 123, "message": .string(message)]
        let path = h.directory.appendingPathComponent("settings.json")
        let document = Data(try custom.serialized(JSON.Format(sortKeys: false)).utf8)
        try document.write(to: path)
        #expect(try h.watch())
        #expect(try Data(contentsOf: path) == document)
        #expect(try Settings.read(directory: h.directory)
                == Settings(retrySeconds: 777, scanSeconds: 123, message: message, soundEnabled: false))
        // NEEDS SEAM: time.time. Python asserts due_at == 1877 (clock 1100 + 777) and then runs
        // at clock 1877. Here the wait is checked relative to its real start, and the elapsed
        // 777 seconds are simulated by moving the saved wait back in the journal.
        let statePath = h.directory.appendingPathComponent("state.json")
        var state = try h.state()
        let started = try #require(state[backendPath: ["pending", "thread", "wait_started_at"]]?.number)
        #expect(state[backendPath: ["pending", "thread", "due_at"]]?.number == started + 777)
        state[backendPath: ["pending", "thread", "wait_started_at"]] = .double(started - 777)
        state[backendPath: ["pending", "thread", "due_at"]] = .double(started)
        try FileStore.writeJSON(state, to: statePath)
        #expect(try h.watch())
        let start = try #require(h.peer.starts.first)
        #expect(start.params[backendPath: ["turnStart", "request", "input"]]?.array?.first?["text"] == .string(message))
        // NEEDS SEAM: RetrySound. Python asserts every audio.configurations == [False].
        #expect(h.resourcesClosed())
    }

    // test_connection_or_owner_protocol_failure_holds_and_returns_false
    @Test func connectionOrOwnerProtocolFailureHoldsAndReturnsFalse() throws {
        let h = try RunnerHarness()
        for kind in ["connection", "owner"] {
            if kind == "connection" {
                h.factoryError = BackendTestError("private network detail")
            } else {
                h.factoryError = nil
                h.peer.ownerError = "unsupported-version"
            }
            #expect(try h.watch() == false, "\(kind)")
            let lastError = try h.state()["last_error"]?.string ?? ""
            #expect(lastError.contains("on hold"), "\(kind)")
            #expect(!lastError.contains("private"), "\(kind)")
            #expect(h.peer.starts.isEmpty, "\(kind)")
            #expect(h.resourcesClosed(), "\(kind)")
        }
    }

    // test_unavailable_persisted_metadata_holds_and_returns_false
    @Test func unavailablePersistedMetadataHoldsAndReturnsFalse() throws {
        let h = try RunnerHarness()
        try h.markJournal()
        h.metadata.error = RPCError.request("private saved summary details")
        #expect(try h.watch() == false)
        #expect(h.peer.starts.isEmpty)
        #expect(try h.state()["pending"] == [:])
        #expect(h.resourcesClosed())
    }

    // test_invalid_saved_settings_restore_handlers_and_close_resources
    @Test func invalidSavedSettingsRestoreHandlersAndCloseResources() throws {
        let h = try RunnerHarness()
        try h.markJournal()
        try Data(#"{"invalid":true}"#.utf8).write(to: h.directory.appendingPathComponent("settings.json"))
        #expect(throws: SettingsError.self) { _ = try h.watch() }
        #expect(h.peer.connections.isEmpty)
        #expect(h.resourcesClosed())
    }

    // test_resource_initialization_failure_restores_signals_and_closes_earlier_resources
    // NEEDS SEAM: core.History and runner.RetrySound. DesktopCommand.watch constructs
    // `History(directory:)` and `RetrySound()` directly; inject `makeHistory: (URL) throws -> History`
    // and `makeSound: () throws -> RetrySound` factories to make each one fail.
    @Test(.disabled("NEEDS SEAM: History and RetrySound construction cannot be made to fail"))
    func resourceInitializationFailureRestoresSignalsAndClosesEarlierResources() {}

    // test_signal_stop_exits_foreground_loop_and_closes_connections
    // NEEDS SEAM: runner.time.sleep and signal.signal. A non-once watch loops on usleep and stops
    // only on a real SIGINT/SIGTERM; delivering one to the shared test process is unsafe. Inject a
    // `sleep: (Double) -> Void` hook (or the StopFlag) into DesktopCommand.watch.
    @Test(.disabled("NEEDS SEAM: the foreground loop can only be stopped by a real process signal"))
    func signalStopExitsForegroundLoopAndClosesConnections() {}

    // test_main_doctor_is_read_only_and_closes_backend_and_metadata
    // NEEDS SEAM: core.WebSocketRPC and runner.DesktopRPC. DesktopCommand.main builds both
    // directly; add `makeMetadata`/`makeBackend` parameters to main (as watch has) to port this.
    @Test(.disabled("NEEDS SEAM: DesktopCommand.main has no metadata or backend factory"))
    func mainDoctorIsReadOnlyAndClosesBackendAndMetadata() {}
}
