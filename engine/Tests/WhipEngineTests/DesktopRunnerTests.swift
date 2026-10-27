import Foundation
import Testing
@testable import WhipEngine

// Port of tests/test_desktop_runner.py.
//
// The Python suite patches time.time, time.monotonic, signal.signal, History, RetrySound,
// log_emitter, default_state_directory and resolve_socket. Here DesktopCommand.Hooks supplies:
// - env: ServiceEnvironment(home:) under the temporary root, so `defaultStateDirectory`
//   (the production directory) is a temporary path.
// - now/monotonic: the fixed clock (1200 by default) and monotonic 100.
// - makeMetadata/makeBackend: the fake peers; makeHistory/makeSound: recorded instances.
// - resolve_socket: a placeholder file at codex/app-server-control/app-server-control.sock
//   satisfies the real resolveSocket.
// - signal.signal: the SIGINT/SIGTERM dispositions are read with sigaction before and after.
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

/// Wraps the final DesktopRPC to count close() like Python's `mock.Mock(wraps=backend.close)`.
private final class CountingBackend: RPCClient {
    let inner: DesktopRPC
    var closeCount = 0
    init(_ inner: DesktopRPC) { self.inner = inner }
    func call(_ method: String, _ params: JSON) throws -> JSON { try inner.call(method, params) }
    func close() {
        closeCount += 1
        inner.close()
    }
}

/// A real RetrySound with a recording player. RetrySound is final and keeps its enabled and
/// closed flags private, so close() is observed by probing: after close, an enabled retry
/// report never reaches the player.
private final class RecordedSound {
    let sound: RetrySound
    private let lock = NSLock()
    private var played = 0

    init(file: URL) {
        var box: RecordedSound?
        sound = RetrySound(file: file, player: { _ in box?.recordPlay() })
        box = self
    }

    private func recordPlay() { lock.withLock { played += 1 } }
    var plays: Int { lock.withLock { played } }

    var closed: Bool {
        let before = plays
        sound.configure(true)
        sound.report("retry")
        sound.drain()
        return plays == before
    }
}

/// tests/test_desktop_runner.py `DesktopRunnerTests.setUp`.
private final class RunnerHarness {
    let root: URL
    let directory: URL
    let home: URL
    let production: URL
    let env: ServiceEnvironment
    let peer: DesktopPeerStub
    let metadata = MetadataPeerStub()
    var backends: [CountingBackend] = []
    var directBackends: [DesktopRPC] = []
    var histories: [History] = []
    var sounds: [RecordedSound] = []
    var historyError: Error?
    var factoryError: Error?
    var backendError: Error?
    var clock: Double = 1200
    let originalSignals: [Int]
    let soundFile: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("desktop-runner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        directory = root.appendingPathComponent("prototype")
        home = root.appendingPathComponent("codex")
        env = ServiceEnvironment(home: root.appendingPathComponent("user-home"))
        production = env.defaultStateDirectory
        // Stands in for the patched resolve_socket; the metadata factory never connects to it.
        let control = home.appendingPathComponent("app-server-control")
        try FileManager.default.createDirectory(at: control, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: control.appendingPathComponent("app-server-control.sock").path, contents: nil)
        soundFile = root.appendingPathComponent("whip.wav")
        FileManager.default.createFile(atPath: soundFile.path, contents: Data("synthetic".utf8))
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

    func desktopRPC(_ socketPath: URL, _ metadata: RPCClient, _ threads: [String],
                    _ shouldStop: @escaping () -> Bool) throws -> DesktopRPC {
        if let backendError { throw backendError }
        return try DesktopRPC(socketPath: socketPath, metadata: metadata, threadIDs: threads,
                              shouldStop: shouldStop, makeIPC: peer.factory)
    }

    /// A DesktopRPC used directly (diagnostic and main doctor need the concrete type).
    func backendFactory(_ socketPath: URL, _ metadata: RPCClient, _ threads: [String],
                        _ shouldStop: @escaping () -> Bool) throws -> DesktopRPC {
        let backend = try desktopRPC(socketPath, metadata, threads, shouldStop)
        directBackends.append(backend)
        return backend
    }

    func hooks() -> DesktopCommand.Hooks {
        var hooks = DesktopCommand.Hooks()
        hooks.env = env
        hooks.makeMetadata = { [unowned self] in try self.metadataFactory($0, $1) }
        hooks.makeBackend = { [unowned self] in
            let backend = CountingBackend(try self.desktopRPC($0, $1, $2, $3))
            self.backends.append(backend)
            return backend
        }
        hooks.makeHistory = { [unowned self] directory in
            if let historyError = self.historyError { throw historyError }
            let history = try History(directory: directory)
            self.histories.append(history)
            return history
        }
        hooks.makeSound = { [unowned self] in
            let sound = RecordedSound(file: self.soundFile)
            self.sounds.append(sound)
            return sound.sound
        }
        hooks.now = { [unowned self] in self.clock }
        hooks.monotonic = { 100 }
        hooks.sleep = { _ in }
        return hooks
    }

    func watch(directory: URL? = nil, once: Bool = true, hooks given: DesktopCommand.Hooks? = nil) throws -> Bool {
        try DesktopCommand.watch(directory: directory ?? self.directory, codexHome: home, threadID: "thread",
                                 once: once, hooks: given ?? hooks())
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
    /// History is final and keeps its connection private, so `history.closed` cannot be read;
    /// it is the one resource this helper does not check.
    func resourcesClosed(sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(signalsRestored, "signal handlers restored", sourceLocation: sourceLocation)
        #expect(sounds.allSatisfy { $0.closed }, "sounds closed", sourceLocation: sourceLocation)
        #expect(backends.allSatisfy { $0.closeCount == 1 }, "backend closed once", sourceLocation: sourceLocation)
        #expect(peer.cleanConnections(), "connections closed and unfollowed", sourceLocation: sourceLocation)
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
        h.resourcesClosed()
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
        #expect(try h.watch())
        let state = try h.state()
        #expect(state["control_backend"] == "desktop-ipc")
        #expect(state["threads"] == ["thread"])
        #expect(state["enabled_at"]?.number == 1200)
        #expect(state["pending"] == [:])
        var expected = Settings.defaults
        expected.soundEnabled = false
        #expect(try Settings.read(directory: h.directory) == expected)
        // RetrySound keeps its configuration private. Python asserts configurations == [False];
        // the sound is checked to be silent: no retry was played.
        #expect(h.sounds.count == 1)
        #expect(h.sounds.allSatisfy { $0.plays == 0 })
        #expect(h.peer.starts.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: h.production.path))
        #expect(RunnerHarness.mode(h.directory) == 0o700)
        for name in ["state.json", "settings.json", "worker.log"] {
            #expect(RunnerHarness.mode(h.directory.appendingPathComponent(name)) == 0o600, "\(name)")
        }
        #expect(h.metadata.closeCount == 1)
        h.resourcesClosed()
    }

    // test_production_directory_and_alias_are_rejected_without_file_changes
    @Test func productionDirectoryAndAliasAreRejectedWithoutFileChanges() throws {
        let h = try RunnerHarness()
        try FileManager.default.createDirectory(at: h.production, withIntermediateDirectories: true)
        try Data("production settings stay untouched".utf8).write(to: h.production.appendingPathComponent("settings.json"))
        let before = RunnerHarness.snapshot(h.production)
        let alias = h.root.appendingPathComponent("production-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: h.production)
        for directory in [h.production, alias] {
            #expect(throws: WhipError.self, "\(directory.lastPathComponent)") { _ = try h.watch(directory: directory) }
            #expect(RunnerHarness.snapshot(h.production) == before)
        }
        #expect(h.metadata.calls.isEmpty)
        // Python asserts signal.signal was never called; the dispositions are compared instead.
        #expect(h.signalsRestored)
    }

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
        h.clock = 1100
        #expect(try h.watch())
        let before = try h.state()
        #expect(before[backendPath: ["pending", "thread"]] != nil)
        h.clock = 1200
        #expect(try h.watch())
        let after = try h.state()
        for name in ["enabled_at", "threads", "pending", "handled", "paused", "control_backend"] {
            #expect(after[name] == before[name], "\(name)")
        }
        #expect(h.peer.starts.isEmpty)
        h.resourcesClosed()
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
        h.clock = 1100
        #expect(try h.watch())
        #expect(try Data(contentsOf: path) == document)
        #expect(try Settings.read(directory: h.directory)
                == Settings(retrySeconds: 777, scanSeconds: 123, message: message, soundEnabled: false))
        #expect(try h.state()[backendPath: ["pending", "thread", "due_at"]]?.number == 1877)
        h.clock = 1877
        #expect(try h.watch())
        let start = try #require(h.peer.starts.first)
        #expect(start.params[backendPath: ["turnStart", "request", "input"]]?.array?.first?["text"] == .string(message))
        // Python asserts every audio.configurations == [False]; with the live retry above, a
        // silent player shows each sound stayed off.
        #expect(h.sounds.count == 2)
        #expect(h.sounds.allSatisfy { $0.plays == 0 })
        h.resourcesClosed()
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
            h.resourcesClosed()
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
        h.resourcesClosed()
    }

    // test_invalid_saved_settings_restore_handlers_and_close_resources
    @Test func invalidSavedSettingsRestoreHandlersAndCloseResources() throws {
        let h = try RunnerHarness()
        try h.markJournal()
        try Data(#"{"invalid":true}"#.utf8).write(to: h.directory.appendingPathComponent("settings.json"))
        #expect(throws: SettingsError.self) { _ = try h.watch() }
        #expect(h.peer.connections.isEmpty)
        h.resourcesClosed()
    }

    // test_resource_initialization_failure_restores_signals_and_closes_earlier_resources
    // Only the History case ports. Hooks.makeSound is `() -> RetrySound` and RetrySound's
    // initializer cannot throw, so Python's RetrySound RuntimeError case has no Swift
    // counterpart.
    @Test func resourceInitializationFailureRestoresSignalsAndClosesEarlierResources() throws {
        let h = try RunnerHarness()
        h.historyError = BackendTestError("Resource unavailable")
        #expect(throws: BackendTestError.self) { _ = try h.watch() }
        #expect(h.sounds.isEmpty)
        h.resourcesClosed()
    }

    // test_signal_stop_exits_foreground_loop_and_closes_connections
    // Python's patched sleep invokes the installed SIGTERM handler. Delivering a real signal to
    // the shared test process is unsafe, so sleep sets the stop condition that the signal
    // flag feeds, and signal handling is turned off.
    @Test func signalStopExitsForegroundLoopAndClosesConnections() throws {
        let h = try RunnerHarness()
        var stopped = false
        var hooks = h.hooks()
        hooks.handleSignals = false
        hooks.stopRequested = { stopped }
        hooks.sleep = { _ in stopped = true }
        #expect(try h.watch(once: false, hooks: hooks))
        #expect(h.metadata.shouldStop())
        h.resourcesClosed()
    }

    // test_main_doctor_is_read_only_and_closes_backend_and_metadata
    @Test func mainDoctorIsReadOnlyAndClosesBackendAndMetadata() throws {
        let h = try RunnerHarness()
        var hooks = h.hooks()
        // The doctor needs the concrete DesktopRPC, so this backend is not wrapped and its close
        // is observed through cleared anchors and closed connections.
        hooks.makeBackend = { [unowned h] in try h.backendFactory($0, $1, $2, $3) }
        var output = ""
        var errors = ""
        let status = DesktopCommand.main(["--thread", "thread", "doctor"], codexHome: h.home, hooks: hooks,
                                         stdout: { output += $0 }, stderr: { errors += $0 })
        #expect(status == 0, "\(errors)")
        let result = try JSON.parse(output)
        #expect(result["message_sent"] == false)
        #expect(h.peer.starts.isEmpty)
        #expect(h.metadata.closeCount == 1)
        #expect(h.directBackends.count == 1)
        #expect(h.directBackends.allSatisfy { $0.anchors.isEmpty })
        h.resourcesClosed()
    }
}
