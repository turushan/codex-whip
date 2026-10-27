import Foundation
import Testing
@testable import WhipEngine

// Ports of the worker-loop tests in tests/test_quota.py (WorkerDeadlineTests),
// tests/test_settings.py (WorkerSettingsTests) and tests/test_sound.py (WorkerSoundTests).
// The loop runs with a simulated clock: every sleep advances it one second, and the
// test stops the worker at a chosen time, as the Python tests did through SIGTERM.

private final class SimulatedClock {
    var now: Double
    var stopAt: Double
    var onTick: ((Double) -> Void)?
    var stopped = false

    init(_ start: Double, stopAt: Double) {
        now = start
        self.stopAt = stopAt
    }

    func hooks(directory: URL, connect: @escaping (URL, @escaping () -> Bool) throws -> RPCClient) -> WorkerHooks {
        var hooks = WorkerHooks()
        hooks.now = { [unowned self] in now }
        hooks.monotonic = { [unowned self] in now }
        hooks.sleep = { [unowned self] _ in
            now += 1
            onTick?(now)
            if now >= stopAt { stopped = true }
        }
        hooks.stopRequested = { [unowned self] in stopped }
        hooks.handleSignals = false
        hooks.socket = { _ in directory.appendingPathComponent("unused.sock") }
        hooks.connect = connect
        hooks.sound = RetrySound(file: nil)
        return hooks
    }
}

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("whip-worker-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func writeState(_ value: JSON, to directory: URL) throws {
    try Data(value.serialized().utf8).write(to: directory.appendingPathComponent("state.json"))
}

private func savedState(_ directory: URL) throws -> RetryState {
    try RetryState.read(directory.appendingPathComponent("state.json"))
}

private func userThread(_ id: String = "user-session") -> JSON {
    ["id": .string(id), "model": "keep-this-model", "reasoningEffort": "xhigh", "status": ["type": "idle"],
     "source": "vscode", "originator": "codex-tui", "parentThreadId": nil, "threadSource": "user",
     "canAcceptDirectInput": true]
}

private func failedTurn(_ id: String, info: String, completedAt: Double = 1100) -> JSON {
    ["id": .string(id), "status": "failed", "completedAt": .double(completedAt),
     "error": ["codexErrorInfo": .string(info), "message": .string(info == "serverOverloaded" ? capacityMessage : "Usage limit reached")]]
}

/// The FakeRPC of the Python tests: loaded sessions with one latest turn each.
private final class SessionRPC: RPCClient {
    var threads: [String: JSON] = [:]
    var turns: [String: JSON] = [:]
    var loaded: [String] = []
    var calls: [String] = []
    var beforeCall: ((String) -> Void)?
    var quota: JSON = ["accountId": "private-account-A", "ordinaryUsageAllowed": false]

    func call(_ method: String, _ params: JSON) throws -> JSON {
        calls.append(method)
        beforeCall?(method)
        let id = params["threadId"]?.string ?? ""
        switch method {
        case "account/rateLimits/read": return quota
        case "thread/loaded/list": return ["data": .array(loaded.map(JSON.string)), "nextCursor": nil]
        case "thread/read": return ["thread": threads[id] ?? nil]
        case "thread/turns/list": return ["data": turns[id].map { [$0] } ?? [], "nextCursor": nil]
        case "turn/start": return ["turn": ["id": "retry-turn", "status": "inProgress"]]
        default: throw RPCError.transport("Unexpected RPC: \(method)")
        }
    }

    func count(_ method: String) -> Int { calls.filter { $0 == method }.count }
}

/// A recording engine, for the tests that only check the loop's scheduling.
private final class RecordingEngine: WorkerEngine {
    var scans: [Double] = []
    var applied: [Int] = []
    var resets = 0
    let clock: SimulatedClock

    init(clock: SimulatedClock) { self.clock = clock }

    func applySettings(_ value: Settings) throws { applied.append(value.scanSeconds) }
    func maintenanceDue(_ now: Double) -> Bool { false }
    func step(_ rpc: RPCClient, now: Double, discover: Bool) throws { scans.append(clock.now) }
    func resetObservations(_ id: String?) throws { resets += 1 }
}

private let settings180 = Settings(retrySeconds: 180, scanSeconds: 300, message: Settings.defaultMessage, soundEnabled: false)

@Suite struct WorkerDeadlineTests {
    // test_due_retry_connection_failures_use_backoff_instead_of_reconnecting_each_second
    @Test func dueRetryConnectionFailuresUseBackoffInsteadOfReconnectingEachSecond() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeState(["version": 1, "enabled_at": 1000, "pending": ["user-session": [
            "turn_id": "capacity-failure", "model": "keep-this-model", "effort": "xhigh",
            "detected_at": 1000, "wait_started_at": 1000, "due_at": 1180]]], to: directory)
        let clock = SimulatedClock(1200, stopAt: 1262)
        var connections: [Double] = []
        var hooks = clock.hooks(directory: directory) { _, _ in
            connections.append(clock.now)
            throw RPCError.transport("temporary local transport failure")
        }
        hooks.readSettings = { _ in settings180 }
        try runWorker(directory: directory, codexHome: directory.appendingPathComponent("missing-codex"), hooks: hooks)
        #expect(connections == [1200, 1230, 1260])
        #expect(try savedState(directory).pending["user-session"]?.turnID == "capacity-failure")
    }

    // test_capacity_deadline_runs_before_next_five_minute_discovery_without_extra_quota_poll
    @Test func capacityDeadlineRunsBeforeNextFiveMinuteDiscoveryWithoutExtraQuotaPoll() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeState(["version": 1, "enabled_at": 1000], to: directory)
        let rpc = SessionRPC()
        rpc.loaded = ["user-session", "capacity-session"]
        rpc.threads = ["user-session": userThread(), "capacity-session": userThread("capacity-session")]
        rpc.turns = ["user-session": failedTurn("quota-failure", info: "usageLimitExceeded"),
                     "capacity-session": failedTurn("capacity-error", info: "serverOverloaded")]
        let clock = SimulatedClock(1100, stopAt: 1282)
        var sends: [Double] = []
        rpc.beforeCall = { if $0 == "turn/start" { sends.append(clock.now) } }
        var hooks = clock.hooks(directory: directory) { _, _ in rpc }
        hooks.readSettings = { _ in settings180 }
        try runWorker(directory: directory, codexHome: directory.appendingPathComponent("missing-codex"), hooks: hooks)
        #expect(sends == [1280])
        #expect(rpc.count("account/rateLimits/read") == 1)
        let saved = try savedState(directory)
        #expect(saved.lastScanAt == 1100)
        #expect(saved.sessions?["total"] == 2)
        #expect(saved.pending["user-session"]?.dueAt == 1400)
    }
}

@Suite struct WorkerSettingsTests {
    // test_invalid_live_settings_pause_scans_until_repaired_without_losing_retry_state
    // The saved retry carries its model and effort, as every real journal does.
    @Test func invalidLiveSettingsPauseScansUntilRepairedWithoutLosingRetryState() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pending: JSON = ["session": ["turn_id": "failure", "model": "keep-this-model", "effort": "xhigh",
                                         "due_at": 1400, "detected_at": 1100]]
        try writeState(["version": 1, "enabled_at": 1000, "pending": pending, "handled": [:], "paused": [:]], to: directory)
        let clock = SimulatedClock(100, stopAt: 130)
        let engine = RecordingEngine(clock: clock)
        var events: [String] = []
        var hooks = clock.hooks(directory: directory) { _, _ in SessionRPC() }
        hooks.makeEngine = { _, _, _, _, _ in engine }
        hooks.observe = { event, _ in events.append(event) }
        hooks.readSettings = { _ in
            if (105..<125).contains(clock.now) { throw SettingsError("Invalid settings.json: malformed preferences") }
            return Settings(retrySeconds: 180, scanSeconds: 15, message: Settings.defaultMessage, soundEnabled: false)
        }
        try runWorker(directory: directory, codexHome: directory.appendingPathComponent("codex"), hooks: hooks)
        #expect(engine.scans == [100, 125])
        let saved = try savedState(directory)
        #expect(saved.pending == (try RetryState(json: ["version": 1, "enabled_at": 1000, "pending": pending])).pending)
        #expect(saved.enabledAt == 1000)
        #expect(saved.lastError == nil)
        #expect(events.filter { $0 == "settings_error" }.count == 1)
        #expect(engine.resets >= 20)
    }

    // test_live_changes_are_polled_each_second_without_exceeding_scan_cadence
    @Test func liveChangesArePolledEachSecondWithoutExceedingScanCadence() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeState(["version": 1, "enabled_at": 1], to: directory)
        let clock = SimulatedClock(100, stopAt: 140)
        let engine = RecordingEngine(clock: clock)
        var reads = 0
        var hooks = clock.hooks(directory: directory) { _, _ in SessionRPC() }
        hooks.makeEngine = { _, _, _, _, _ in engine }
        hooks.readSettings = { _ in
            reads += 1
            let scan = clock.now < 105 || clock.now == 125 ? 15 : 60
            return Settings(retrySeconds: 180, scanSeconds: scan, message: Settings.defaultMessage, soundEnabled: false)
        }
        try runWorker(directory: directory, codexHome: directory.appendingPathComponent("codex"), hooks: hooks)
        #expect(engine.scans == [100, 125])
        #expect(reads >= 40)
        #expect(engine.applied == [15, 60, 15, 60])
    }
}

@Suite struct WorkerSoundTests {
    // test_saved_sound_toggle_is_live_and_only_new_submissions_sound
    @Test func savedSoundToggleIsLiveAndOnlyNewSubmissionsSound() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeState(["version": 1, "enabled_at": 1000, "handled": ["old": [
            "turn_id": "old", "outcome": "submitted", "at": 1000, "retry_turn_id": "old-retry"]]], to: directory)
        let rpc = SessionRPC()
        rpc.loaded = ["user-session"]
        rpc.threads = ["user-session": userThread()]
        rpc.turns = ["user-session": failedTurn("capacity-failure", info: "serverOverloaded")]
        var settings = Settings.defaults
        settings.retrySeconds = 60
        settings.soundEnabled = false
        try Settings.save(settings.json, directory: directory)
        let file = directory.appendingPathComponent("whip.wav")
        let played = NSMutableArray()
        let clock = SimulatedClock(1100, stopAt: 1162)
        clock.onTick = { now in
            if now == 1130 {
                settings.soundEnabled = true
                _ = try? Settings.save(settings.json, directory: directory)
            }
        }
        var hooks = clock.hooks(directory: directory) { _, _ in rpc }
        let sound = RetrySound(file: file) { played.add($0) }
        hooks.sound = sound
        try runWorker(directory: directory, codexHome: directory.appendingPathComponent("codex"), hooks: hooks)
        sound.drain()
        #expect(rpc.count("turn/start") == 1)
        #expect(played as? [URL] == [file])
    }
}
