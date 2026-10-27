import Foundation
import Testing
@testable import WhipEngine

// Port of tests/test_settings.py. Preference validation and live scheduling against isolated
// state and fake RPCs.

private func preferences(_ changes: [String: JSON] = [:]) -> JSON {
    var value = Settings.defaults.json.object!
    value.merge(changes) { _, new in new }
    return .object(value)
}

private func permissions(_ url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes[.posixPermissions] as! NSNumber).intValue & 0o777
}

/// A fresh temporary parent; the state directory inside it does not exist yet.
private final class TemporaryState {
    let root: URL
    let directory: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("settings-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        directory = root.appendingPathComponent("state", isDirectory: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    var exists: Bool { FileManager.default.fileExists(atPath: directory.path) }

    func makeDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    }

    func file(_ name: String) -> URL { directory.appendingPathComponent(name) }

    /// Runs `codex-whip --state-dir <directory> <name>` with the payload on stdin.
    /// Settings and configure never connect to Codex, so no network stub is needed.
    func command(_ name: String, _ payload: String = "") -> (status: Int32, output: String, error: String) {
        var output = "", error = ""
        let status = Command.main(["--state-dir", directory.path, name],
                                  stdout: { output += $0 + "\n" },
                                  stderr: { error += $0 + "\n" },
                                  stdin: { Data(payload.utf8) })
        return (status, output, error)
    }
}

@Suite struct SettingsTests {
    // test_settings_returns_defaults_without_creating_files
    @Test func settingsReturnsDefaultsWithoutCreatingFiles() throws {
        let t = try TemporaryState()
        let (status, output, error) = t.command("settings")
        #expect(status == 0, "\(error)")
        #expect(try JSON.parse(output) == ["settings": Settings.defaults.json, "defaults": Settings.defaults.json])
        #expect(!t.exists)
        #expect(Settings.defaults.json["retry_seconds"] == 180)
        #expect(Settings.defaults.json["scan_seconds"] == 300)
        #expect(Settings.defaults.json["sound_enabled"] == true)
    }

    // test_legacy_preferences_keep_custom_values_and_default_sound_off
    @Test func legacyPreferencesKeepCustomValuesAndDefaultSoundOff() throws {
        let t = try TemporaryState()
        try t.makeDirectory()
        let legacy: JSON = ["retry_seconds": 777, "scan_seconds": 123, "message": "Keep my custom message."]
        let path = t.file("settings.json")
        try Data(try legacy.serialized().utf8).write(to: path)
        let original = try Data(contentsOf: path)
        var expected = legacy
        expected["sound_enabled"] = false
        #expect(try Settings.read(directory: t.directory).json == expected)
        #expect(try Data(contentsOf: path) == original)
        var changed = try Settings.read(directory: t.directory).json
        changed["sound_enabled"] = true
        try Settings.save(changed, directory: t.directory)
        expected["sound_enabled"] = true
        #expect(try Settings.read(directory: t.directory).json == expected)
    }

    // test_configure_persists_private_settings_without_touching_state_or_history
    @Test func configurePersistsPrivateSettingsWithoutTouchingStateOrHistory() throws {
        let t = try TemporaryState()
        try t.makeDirectory()
        try Data("existing retry state".utf8).write(to: t.file("state.json"))
        try Data("existing history".utf8).write(to: t.file("history.sqlite3"))
        let value = preferences(["retry_seconds": 600, "scan_seconds": 15,
                                 "message": "Keep this exact model.\nContinue unfinished work."])
        let (status, output, error) = t.command("configure", try value.serialized())
        #expect(status == 0, "\(error)")
        #expect(try JSON.parse(output) == ["settings": value, "defaults": Settings.defaults.json])
        #expect(try Settings.read(directory: t.directory).json == value)
        #expect(try Data(contentsOf: t.file("state.json")) == Data("existing retry state".utf8))
        #expect(try Data(contentsOf: t.file("history.sqlite3")) == Data("existing history".utf8))
        #expect(try permissions(t.file("settings.json")) == 0o600)
        #expect(try permissions(t.directory) == 0o700)
    }

    // test_reset_to_defaults_preserves_other_files
    @Test func resetToDefaultsPreservesOtherFiles() throws {
        let t = try TemporaryState()
        try Settings.save(preferences(["retry_seconds": 600, "message": "Custom continuation"]), directory: t.directory)
        try Data("saved activation and timers".utf8).write(to: t.file("state.json"))
        let (result, _, error) = t.command("configure", try Settings.defaults.json.serialized())
        #expect(result == 0, "\(error)")
        #expect(try Settings.read(directory: t.directory) == Settings.defaults)
        #expect(try Data(contentsOf: t.file("state.json")) == Data("saved activation and timers".utf8))
    }

    // test_invalid_values_do_not_overwrite_existing_valid_preferences
    @Test func invalidValuesDoNotOverwriteExistingValidPreferences() throws {
        let t = try TemporaryState()
        try Settings.save(preferences(["message": "Existing continuation"]), directory: t.directory)
        let before = try Data(contentsOf: t.file("settings.json"))
        // json.dumps writes NaN and Infinity as bare constants, which JSON cannot carry as values here.
        func nonfinite(_ name: String, _ constant: String) throws -> String {
            try preferences([name: "__NONFINITE__"]).serialized()
                .replacingOccurrences(of: "\"__NONFINITE__\"", with: constant)
        }
        var invalid: [String] = try [
            preferences(["retry_seconds": true]), preferences(["retry_seconds": 300.0]),
            preferences(["retry_seconds": 59]), preferences(["retry_seconds": 86401]),
            preferences(["scan_seconds": false]), preferences(["scan_seconds": 14]),
            preferences(["scan_seconds": 3601]),
        ].map { try $0.serialized() }
        invalid.append(try nonfinite("scan_seconds", "NaN"))
        invalid.append(try nonfinite("retry_seconds", "Infinity"))
        var more: [JSON] = [
            preferences(["message": " \n\t"]), preferences(["message": .string(String(repeating: "x", count: 4001))]),
            preferences(["message": false]),
        ]
        for value: JSON in [0, 1, nil, "true", [], [:]] { more.append(preferences(["sound_enabled": value])) }
        var extra = preferences()
        extra["extra"] = "unknown"
        more += [extra, ["retry_seconds": 300], [], nil]
        invalid += try more.map { try $0.serialized() }
        for payload in invalid {
            let (status, output, error) = t.command("configure", payload)
            #expect(status == 1, "\(payload)")
            #expect(output == "", "\(payload)")
            #expect(!error.isEmpty, "\(payload)")
            #expect(try Data(contentsOf: t.file("settings.json")) == before, "\(payload)")
        }
    }

    // test_range_boundaries_are_accepted
    @Test(arguments: [(60, 15), (86400, 3600)])
    func rangeBoundariesAreAccepted(retry: Int, scan: Int) throws {
        let value = preferences(["retry_seconds": .int(retry), "scan_seconds": .int(scan),
                                 "message": .string(String(repeating: "x", count: 4000))])
        #expect(try Settings.validate(value).json == value)
    }

    // test_malformed_settings_surface_error_and_are_not_silently_reset
    @Test func malformedSettingsSurfaceErrorAndAreNotSilentlyReset() throws {
        let t = try TemporaryState()
        try t.makeDirectory()
        let path = t.file("settings.json")
        try Data("{broken preferences".utf8).write(to: path)
        let (status, output, error) = t.command("settings")
        #expect(status == 1)
        #expect(output == "")
        #expect(error.contains("settings.json"))
        #expect(try Data(contentsOf: path) == Data("{broken preferences".utf8))
    }

    // test_invalid_json_and_multiple_objects_do_not_create_settings
    @Test func invalidJSONAndMultipleObjectsDoNotCreateSettings() throws {
        for payload in ["{", try preferences().serialized() + "\n{}"] {
            let t = try TemporaryState()
            let (status, output, _) = t.command("configure", payload)
            #expect(status == 1, "\(payload)")
            #expect(output == "", "\(payload)")
            #expect(!t.exists, "\(payload)")
        }
    }

    // test_scheduler_recomputes_from_last_scan_when_cadence_changes
    @Test func schedulerRecomputesFromLastScanWhenCadenceChanges() {
        var scheduler = ScanScheduler()
        #expect(scheduler.due(100, interval: 60))
        scheduler.finished(100)
        #expect(!scheduler.due(114.9, interval: 15))
        #expect(scheduler.due(115, interval: 15))
        #expect(!scheduler.due(120, interval: 60))
        #expect(scheduler.due(120, interval: 15))
        scheduler.finished(120)
        #expect(!scheduler.due(134.9, interval: 15))
        #expect(scheduler.due(135, interval: 15))
    }
}

// MARK: - Engine settings

private struct UnexpectedSettingsRPC: Error { let method: String }

/// The FakeRPC from tests/test_core.py: one idle terminal session with a capacity failure.
private final class SettingsFakeRPC: RPCClient {
    static func userThread() -> JSON {
        ["id": "user-session", "model": "keep-this-model", "reasoningEffort": "xhigh", "status": ["type": "idle"],
         "source": "vscode", "originator": "codex-tui", "parentThreadId": nil, "threadSource": "user",
         "canAcceptDirectInput": true]
    }

    static func capacityTurn(_ id: String = "capacity-failure", _ changes: [String: JSON] = [:]) -> JSON {
        var value: [String: JSON] = [
            "id": .string(id), "status": "failed",
            "error": ["codexErrorInfo": "serverOverloaded", "message": .string(capacityMessage)], "completedAt": 1100,
        ]
        value.merge(changes) { _, new in new }
        return .object(value)
    }

    var threads: [String: JSON] = ["user-session": userThread()]
    var turns: [String: JSON] = ["user-session": capacityTurn()]
    var loaded = ["user-session"]
    var calls: [(method: String, params: JSON)] = []

    func call(_ method: String, _ params: JSON) throws -> JSON {
        calls.append((method, params))
        if method == "thread/loaded/list" { return ["data": .array(loaded.map(JSON.string)), "nextCursor": nil] }
        let threadID = params["threadId"]?.string ?? ""
        switch method {
        case "thread/read": return ["thread": threads[threadID] ?? nil]
        case "thread/turns/list":
            if let turn = turns[threadID], turn != .null { return ["data": [turn], "nextCursor": nil] }
            return ["data": [], "nextCursor": nil]
        case "turn/start": return ["turn": ["id": "retry-turn", "status": "inProgress"]]
        default: throw UnexpectedSettingsRPC(method: method)
        }
    }

    func sends() -> [JSON] { calls.filter { $0.method == "turn/start" }.map(\.params) }
}

private final class EngineSettingsFixture {
    let rpc = SettingsFakeRPC()
    var events: [(event: String, fields: [String: JSON])] = []
    var saved: [JSON] = []
    let state = RetryState(enabledAt: 1000)
    var engine: RetryEngine!

    init() throws { engine = try newEngine() }

    func newEngine() throws -> RetryEngine {
        try RetryEngine(state: state, save: { [unowned self] in self.saved.append($0.json) },
                        emit: { [unowned self] in self.events.append(($0, $1)) },
                        interval: 300, scanInterval: 60)
    }

    func apply(_ changes: [String: JSON]) throws {
        try engine.applySettings(Settings.validate(preferences(changes)))
    }

    func activeRetry() {
        var attempt = Attempt(turnID: "original", at: 1000, outcome: "submitted")
        attempt.retryTurnID = "retry"
        state.handled["user-session"] = attempt
        rpc.threads["user-session"]?["status"] = ["type": "active", "activeFlags": []]
        rpc.turns["user-session"] = SettingsFakeRPC.capacityTurn("retry", ["status": "inProgress", "error": nil])
    }
}

@Suite struct EngineSettingsTests {
    // test_custom_message_changes_only_turn_start_input
    @Test func customMessageChangesOnlyTurnStartInput() throws {
        let f = try EngineSettingsFixture()
        let text = "Use this model. Keep going with the unfinished changes."
        try f.apply(["retry_seconds": 60, "message": .string(text)])
        try f.engine.step(f.rpc, now: 1100)
        try f.engine.step(f.rpc, now: 1160)
        #expect(f.rpc.sends() == [["threadId": "user-session", "input": [["type": "text", "text": .string(text)]]]])
        #expect(!f.rpc.calls.contains { $0.method == "thread/resume" })
        #expect(f.state.enabledAt == 1000)
    }

    // test_longer_and_shorter_waits_keep_the_original_wait_start
    @Test func longerAndShorterWaitsKeepTheOriginalWaitStart() throws {
        let f = try EngineSettingsFixture()
        try f.engine.step(f.rpc, now: 1100)
        try f.apply(["retry_seconds": 600])
        #expect(f.state.pending["user-session"]?.dueAt == 1700)
        try f.engine.step(f.rpc, now: 1400)
        #expect(f.rpc.sends().isEmpty)
        try f.apply(["retry_seconds": 60])
        #expect(f.state.pending["user-session"]?.dueAt == 1160)
        #expect(f.state.pending["user-session"]?.waitStartedAt == 1100)
        try f.engine.step(f.rpc, now: 1401)
        #expect(f.rpc.sends().count == 1)
    }

    // test_legacy_pending_timer_is_anchored_once_across_changes_and_restart
    @Test func legacyPendingTimerIsAnchoredOnceAcrossChangesAndRestart() throws {
        let f = try EngineSettingsFixture()
        f.state.pending["user-session"] = try Pending(json: ["turn_id": "failure", "due_at": 1400, "detected_at": 1100,
                                                             "model": "chosen", "effort": "xhigh"])
        try f.apply(["retry_seconds": 600])
        #expect(f.state.pending["user-session"]?.dueAt == 1700)
        f.engine = try f.newEngine()
        try f.apply(["retry_seconds": 1200])
        #expect(f.state.pending["user-session"]?.dueAt == 2300)
        #expect(f.state.pending["user-session"]?.waitStartedAt == 1100)
    }

    // test_discovery_cadence_change_resets_health_but_tracking_stays_frequent
    @Test func discoveryCadenceChangeResetsHealthButTrackingStaysFrequent() throws {
        let f = try EngineSettingsFixture()
        f.activeRetry()
        try f.engine.step(f.rpc, now: 1100)
        try f.engine.step(f.rpc, now: 1160)
        try f.apply(["scan_seconds": 120])
        #expect(f.state.handled["user-session"]?.healthySince == nil)
        try f.engine.step(f.rpc, now: 1280)
        #expect(!f.events.contains { $0.event == "retry_result" })
        for now: Double in [1310, 1340, 1370, 1400] {
            try f.engine.step(f.rpc, now: now)
        }
        let result = try #require(f.events.first { $0.event == "retry_result" }?.fields)
        #expect(result["status"] == "successful")
        #expect(result["occurred_at"]?.number == 1400)
    }

    // test_long_gap_resets_health_even_with_long_discovery_cadence
    @Test func longGapResetsHealthEvenWithLongDiscoveryCadence() throws {
        let f = try EngineSettingsFixture()
        f.activeRetry()
        try f.apply(["scan_seconds": 120])
        try f.engine.step(f.rpc, now: 1100)
        try f.engine.step(f.rpc, now: 1191)
        #expect(f.state.handled["user-session"]?.healthySince == 1191)
        #expect(!f.events.contains { $0.event == "retry_result" })
    }

    // test_settings_preserve_journal_and_activation
    @Test func settingsPreserveJournalAndActivation() throws {
        let f = try EngineSettingsFixture()
        var entry = Attempt(turnID: "older", outcome: "submitted")
        entry.retryTurnID = "older-retry"
        entry.resultStatus = "successful"
        f.state.handled["other-session"] = entry
        try f.apply(["retry_seconds": 600, "scan_seconds": 15, "message": "New continuation"])
        #expect(f.state.handled["other-session"] == entry)
        #expect(f.state.enabledAt == 1000)
    }
}

@Suite struct WorkerSettingsTests {
    // test_invalid_live_settings_pause_scans_until_repaired_without_losing_retry_state
    // NEEDS SEAM: runWorker(directory:codexHome:) calls Settings.read, constructs RetryEngine, History and
    // WebSocketRPC itself, and uses the real clock, monotonic(), sleep(1) and signal sources. Inject a settings
    // reader, an engine (or step observer), an RPCClient factory, a clock, a sleep function and a stop trigger.
    @Test(.disabled("NEEDS SEAM: runWorker has no injectable settings reader, engine, connection factory, clock, or sleep"))
    func invalidLiveSettingsPauseScansUntilRepairedWithoutLosingRetryState() {}

    // test_live_changes_are_polled_each_second_without_exceeding_scan_cadence
    // NEEDS SEAM: same seams as above; the test also counts Settings.read calls and applySettings arguments.
    @Test(.disabled("NEEDS SEAM: runWorker has no injectable settings reader, engine, connection factory, clock, or sleep"))
    func liveChangesArePolledEachSecondWithoutExceedingScanCadence() {}
}
