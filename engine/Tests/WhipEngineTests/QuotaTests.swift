import Foundation
import Testing
@testable import WhipEngine

// Port of tests/test_quota.py. Quota recovery and deadline checks use only local protocol stubs.

private enum QuotaFixtures {
    static func userThread(_ id: String = "user-session", _ changes: [String: JSON] = [:]) -> JSON {
        var value: [String: JSON] = [
            "id": .string(id), "model": "keep-this-model", "reasoningEffort": "xhigh",
            "status": ["type": "idle"], "source": "vscode", "originator": "codex-tui",
            "parentThreadId": nil, "threadSource": "user", "canAcceptDirectInput": true,
        ]
        value.merge(changes) { _, new in new }
        return .object(value)
    }

    static func capacityTurn(_ id: String = "capacity-failure", _ completedAt: JSON = 1100,
                             _ changes: [String: JSON] = [:]) -> JSON {
        var value: [String: JSON] = [
            "id": .string(id), "status": "failed",
            "error": ["codexErrorInfo": "serverOverloaded", "message": .string(capacityMessage)],
            "completedAt": completedAt,
        ]
        value.merge(changes) { _, new in new }
        return .object(value)
    }

    static func quotaTurn(_ id: String = "quota-failure", _ completedAt: JSON = 1100) -> JSON {
        capacityTurn(id, completedAt, ["error": ["codexErrorInfo": "usageLimitExceeded", "message": "Usage limit reached"]])
    }
}

private struct UnexpectedQuotaRPC: Error { let method: String }

/// FakeRPC and QuotaRPC from the Python tests, in one stub.
private final class QuotaRPC: RPCClient {
    var threads: [String: JSON] = ["user-session": QuotaFixtures.userThread()]
    var turns: [String: JSON] = ["user-session": QuotaFixtures.quotaTurn()]
    var loaded = ["user-session"]
    var calls: [(method: String, params: JSON)] = []
    var beforeCall: ((String, JSON) -> Void)?
    var sendError: Error?
    var quota: JSON = ["accountId": "private-account-A", "ordinaryUsageAllowed": false,
                       "rateLimits": ["primary": ["usedPercent": 100, "resetsAt": 9999999999]]]
    var quotaError: Error?

    func call(_ method: String, _ params: JSON) throws -> JSON {
        calls.append((method, params))
        beforeCall?(method, params)
        if method == "account/rateLimits/read" {
            if let quotaError { throw quotaError }
            return quota
        }
        if method == "thread/loaded/list" {
            return ["data": .array(loaded.map(JSON.string)), "nextCursor": nil]
        }
        let threadID = params["threadId"]?.string ?? ""
        switch method {
        case "thread/read":
            return ["thread": threads[threadID] ?? nil]
        case "thread/turns/list":
            if let turn = turns[threadID], turn != .null { return ["data": [turn], "nextCursor": nil] }
            return ["data": [], "nextCursor": nil]
        case "turn/start":
            if let sendError { throw sendError }
            return ["turn": ["id": "retry-turn", "status": "inProgress"]]
        default:
            throw UnexpectedQuotaRPC(method: method)
        }
    }

    func sends() -> [JSON] { calls.filter { $0.method == "turn/start" }.map(\.params) }
    func reads() -> [JSON] { calls.filter { $0.method == "account/rateLimits/read" }.map(\.params) }
}

/// The Python setUp: a quota RPC, recorded events and saves, and an engine at 180/300 seconds.
private final class QuotaFixture {
    let rpc = QuotaRPC()
    var events: [(event: String, fields: [String: JSON])] = []
    var saved: [JSON] = []
    let state = RetryState(enabledAt: 1000)
    var engine: RetryEngine!

    init() throws {
        engine = try newEngine()
    }

    func newEngine() throws -> RetryEngine {
        try RetryEngine(state: state, save: { [unowned self] in self.saved.append($0.json) },
                        emit: { [unowned self] in self.events.append(($0, $1)) },
                        interval: 180, scanInterval: 300)
    }

    func arm() throws {
        try engine.step(rpc, now: 1100)
    }

    var pending: Pending? { state.pending["user-session"] }

    func serializedEvents() throws -> String {
        try JSON.array(events.map { .array([.string($0.event), .object($0.fields)]) }).serialized()
    }
}

@Suite struct QuotaRecoveryTests {
    // test_exact_quota_code_is_required_and_other_errors_never_arm
    @Test func exactQuotaCodeIsRequiredAndOtherErrorsNeverArm() throws {
        let f = try QuotaFixture()
        #expect(isQuota(QuotaFixtures.quotaTurn()))
        let codes: [JSON] = [nil, "other", "rateLimitExceeded", "contextWindowExceeded", "sessionBudgetExceeded",
                             "unauthorized", "cyberPolicy", ["usageLimitExceeded": [:]], ["usageLimitExceeded"]]
        for code in codes {
            var turn = QuotaFixtures.quotaTurn()
            turn["error"] = ["codexErrorInfo": code, "message": "Usage limit reached"]
            #expect(!isQuota(turn), "code \(code)")
            f.rpc.turns["user-session"] = turn
            try f.engine.step(f.rpc, now: 1100)
            #expect(f.state.pending.isEmpty, "code \(code)")
            #expect(f.rpc.reads().isEmpty, "code \(code)")
        }
        var turn = QuotaFixtures.quotaTurn()
        turn["status"] = "completed"
        #expect(!isQuota(turn))
    }

    // test_five_minute_checks_notice_early_permission_without_waiting_for_reset_timestamp
    @Test func fiveMinuteChecksNoticeEarlyPermissionWithoutWaitingForResetTimestamp() throws {
        let f = try QuotaFixture()
        try f.arm()
        #expect(f.pending?.dueAt == 1400)
        f.rpc.quota["ordinaryUsageAllowed"] = true
        try f.engine.step(f.rpc, now: 1399)
        #expect(f.rpc.reads().count == 1)
        #expect(f.rpc.sends().isEmpty)
        try f.engine.step(f.rpc, now: 1400)
        #expect(f.rpc.sends() == [["threadId": "user-session",
                                   "input": [["type": "text", "text": .string(Settings.defaultMessage)]]]])
        #expect(f.rpc.reads().allSatisfy { $0 == ["excludeResetCreditDetails": true] })
        let forbidden = ["thread/resume", "account/rateLimitResetCredit/consume", "account/login/start"]
        #expect(!f.rpc.calls.contains { forbidden.contains($0.method) })
        #expect(f.state.handled["user-session"]?.kind == "quota")
    }

    // test_false_permission_keeps_waiting_then_regular_renewal_allows_one_attempt
    @Test func falsePermissionKeepsWaitingThenRegularRenewalAllowsOneAttempt() throws {
        let f = try QuotaFixture()
        try f.arm()
        try f.engine.step(f.rpc, now: 1400)
        #expect(f.rpc.sends().isEmpty)
        #expect(f.pending?.dueAt == 1700)
        f.rpc.quota["ordinaryUsageAllowed"] = true
        try f.engine.step(f.rpc, now: 1700)
        try f.engine.step(f.rpc, now: 2000)
        #expect(f.rpc.sends().count == 1)
    }

    // test_true_at_first_binding_still_waits_for_a_later_fresh_check
    @Test func trueAtFirstBindingStillWaitsForALaterFreshCheck() throws {
        let f = try QuotaFixture()
        f.rpc.quota["ordinaryUsageAllowed"] = true
        try f.arm()
        #expect(f.rpc.sends().isEmpty)
        try f.engine.step(f.rpc, now: 1400)
        #expect(f.rpc.sends().count == 1)
    }

    // test_unknown_permission_never_uses_percentages_or_elapsed_reset_times
    @Test func unknownPermissionNeverUsesPercentagesOrElapsedResetTimes() throws {
        var last: QuotaFixture?
        for permission: JSON in [nil, "true", 1, [:], []] {
            let f = try QuotaFixture()
            f.rpc.quota["ordinaryUsageAllowed"] = permission
            f.rpc.quota["rateLimits"] = ["primary": ["usedPercent": 0, "resetsAt": 100]]
            try f.arm()
            try f.engine.step(f.rpc, now: 1400)
            #expect(f.rpc.sends().isEmpty, "permission \(permission)")
            #expect(f.pending?.quotaStatus == "unknown", "permission \(permission)")
            last = f
        }
        let f = try #require(last)
        f.rpc.quota = []
        try f.engine.step(f.rpc, now: 1700)
        #expect(f.rpc.sends().isEmpty)
    }

    // test_missing_account_requires_binding_then_a_subsequent_matching_read
    @Test func missingAccountRequiresBindingThenASubsequentMatchingRead() throws {
        let f = try QuotaFixture()
        f.rpc.quota["accountId"] = JSON.null
        f.rpc.quota["ordinaryUsageAllowed"] = true
        try f.arm()
        try f.engine.step(f.rpc, now: 1400)
        #expect(f.pending?.accountBinding == nil)
        #expect(f.pending?.json["account_binding"] == nil)
        f.rpc.quota["accountId"] = "private-account-A"
        try f.engine.step(f.rpc, now: 1700)
        #expect(f.rpc.sends().isEmpty)
        try f.engine.step(f.rpc, now: 2000)
        #expect(f.rpc.sends().count == 1)
    }

    // test_changed_account_is_held_until_original_account_returns
    @Test func changedAccountIsHeldUntilOriginalAccountReturns() throws {
        let f = try QuotaFixture()
        try f.arm()
        f.rpc.quota["accountId"] = "private-account-B"
        f.rpc.quota["ordinaryUsageAllowed"] = true
        try f.engine.step(f.rpc, now: 1400)
        #expect(f.rpc.sends().isEmpty)
        #expect(f.pending?.quotaStatus == "account_changed")
        #expect(f.pending?.dueAt == 1700)
        f.rpc.quota["accountId"] = "private-account-A"
        try f.engine.step(f.rpc, now: 1700)
        #expect(f.rpc.sends().count == 1)
    }

    // test_account_switch_after_batch_poll_is_caught_before_submission
    @Test func accountSwitchAfterBatchPollIsCaughtBeforeSubmission() throws {
        let f = try QuotaFixture()
        try f.arm()
        f.rpc.quota["ordinaryUsageAllowed"] = true
        var reads = 0
        f.rpc.beforeCall = { [unowned rpc = f.rpc] method, _ in
            if method == "thread/read" {
                reads += 1
                if reads == 2 { rpc.quota["accountId"] = "private-account-B" }
            }
        }
        try f.engine.step(f.rpc, now: 1400)
        #expect(f.rpc.sends().isEmpty)
        #expect(f.pending?.quotaStatus == "account_changed")
    }

    // test_permission_revoked_during_preflight_does_not_send
    @Test func permissionRevokedDuringPreflightDoesNotSend() throws {
        let f = try QuotaFixture()
        try f.arm()
        f.rpc.quota["ordinaryUsageAllowed"] = true
        var quotaReads = 0
        f.rpc.beforeCall = { [unowned rpc = f.rpc] method, _ in
            if method == "account/rateLimits/read" {
                quotaReads += 1
                if quotaReads == 2 { rpc.quota["ordinaryUsageAllowed"] = false }
            }
        }
        try f.engine.step(f.rpc, now: 1400)
        #expect(f.rpc.sends().isEmpty)
    }

    // test_session_changes_while_fresh_quota_is_read_are_rechecked
    @Test(arguments: ["busy", "model", "effort", "newer"])
    func sessionChangesWhileFreshQuotaIsReadAreRechecked(change: String) throws {
        let f = try QuotaFixture()
        try f.arm()
        f.rpc.quota["ordinaryUsageAllowed"] = true
        var quotaReads = 0
        f.rpc.beforeCall = { [unowned rpc = f.rpc] method, _ in
            guard method == "account/rateLimits/read" else { return }
            quotaReads += 1
            guard quotaReads == 2 else { return }
            switch change {
            case "busy": rpc.threads["user-session"]?["status"] = ["type": "active"]
            case "model": rpc.threads["user-session"]?["model"] = "different-user-model"
            case "effort": rpc.threads["user-session"]?["reasoningEffort"] = "low"
            default: rpc.turns["user-session"] = QuotaFixtures.quotaTurn("newer-user-turn", 1400)
            }
        }
        try f.engine.step(f.rpc, now: 1400)
        #expect(f.rpc.sends().isEmpty)
        #expect(f.state.pending.isEmpty)
    }

    // test_rpc_rejection_is_unknown_and_does_not_reuse_old_permission
    @Test func rpcRejectionIsUnknownAndDoesNotReuseOldPermission() throws {
        let f = try QuotaFixture()
        try f.arm()
        f.rpc.quotaError = RPCError.request("unsupported endpoint, private-account-A")
        try f.engine.step(f.rpc, now: 1400)
        #expect(f.rpc.sends().isEmpty)
        #expect(f.pending?.quotaStatus == "unknown")
        #expect(try !f.serializedEvents().contains("private-account-A"))
    }

    // test_transport_error_defers_quota_check_and_reconnect_requires_fresh_permission
    @Test func transportErrorDefersQuotaCheckAndReconnectRequiresFreshPermission() throws {
        let f = try QuotaFixture()
        try f.arm()
        f.rpc.quotaError = RPCError.transport("private-account-A transport error")
        let error = #expect(throws: RPCError.self) { try f.engine.step(f.rpc, now: 1400) }
        #expect(error?.kind == .transport)
        #expect(error?.description.contains("quota status could not be read") == true)
        #expect(f.pending?.dueAt == 1700)
        f.rpc.quotaError = nil
        f.rpc.quota["ordinaryUsageAllowed"] = true
        try f.engine.step(f.rpc, now: 1699)
        #expect(f.rpc.sends().isEmpty)
        try f.engine.step(f.rpc, now: 1700)
        #expect(f.rpc.sends().count == 1)
    }

    // test_restart_keeps_account_binding_but_reads_fresh_permission
    @Test func restartKeepsAccountBindingButReadsFreshPermission() throws {
        let f = try QuotaFixture()
        try f.arm()
        let binding = f.pending?.accountBinding
        #expect(binding != nil)
        f.engine = try f.newEngine()
        #expect(f.pending?.accountBinding == binding)
        f.rpc.quota["ordinaryUsageAllowed"] = true
        try f.engine.step(f.rpc, now: 1400)
        #expect(f.rpc.sends().count == 1)
    }

    // test_uncertain_delivery_is_latched_durably_across_restart
    @Test func uncertainDeliveryIsLatchedDurablyAcrossRestart() throws {
        let f = try QuotaFixture()
        try f.arm()
        f.rpc.quota["ordinaryUsageAllowed"] = true
        f.rpc.sendError = RPCError.transport("send acceptance unknown")
        #expect(throws: RPCError.self) { try f.engine.step(f.rpc, now: 1400) }
        #expect(f.saved.last?["handled"]?["user-session"]?["outcome"] == "uncertain")
        #expect(f.events.last?.event == "uncertain")
        #expect(f.events.last?.fields["kind"] == "quota")
        f.engine = try f.newEngine()
        f.rpc.sendError = nil
        try f.engine.step(f.rpc, now: 1700)
        #expect(f.rpc.sends().count == 1)
    }

    // test_account_identity_and_binding_never_enter_events_or_reconciled_history
    // Python inspected a mock History's record calls. Swift's reconcileHistory takes the concrete
    // History, so this port records into a real temporary database and inspects what it stored.
    @Test func accountIdentityAndBindingNeverEnterEventsOrReconciledHistory() throws {
        let f = try QuotaFixture()
        try f.arm()
        #expect(f.pending?.accountBinding != nil)
        #expect(f.pending?.accountBinding != "private-account-A")
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("quota-history-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = try History(directory: directory, clock: { 1101 })
        try reconcileHistory(f.state, history, now: 1101)
        history.close()
        let report = try History.report(directory: directory, hours: 24, limit: 100, now: 1101)
        let recent = report["recent"]?.array ?? []
        #expect(recent.count == 1)
        #expect(recent.first?["event"] == "quota")
        #expect(recent.first?["kind"] == "quota")
        #expect(report["quota"] == 1)
        var serialized = try f.serializedEvents()
        let stored = try Data(contentsOf: directory.appendingPathComponent(History.databaseName))
        serialized += String(decoding: stored, as: UTF8.self) + (try report.serialized())
        #expect(!serialized.contains("private-account"))
        #expect(!serialized.contains("account_binding"))
        #expect(!serialized.contains("ordinaryUsageAllowed"))
    }

    // test_historical_unloaded_and_nonterminal_sessions_do_not_poll
    @Test(arguments: ["historical", "unloaded", "subagent", "paused", "active"])
    func historicalUnloadedAndNonterminalSessionsDoNotPoll(change: String) throws {
        let f = try QuotaFixture()
        switch change {
        case "historical": f.rpc.turns["user-session"]?["completedAt"] = 999
        case "unloaded": f.rpc.loaded = []
        case "subagent": f.rpc.threads["user-session"]?["parentThreadId"] = "parent"
        case "paused": f.state.paused["user-session"] = true
        default: f.rpc.threads["user-session"]?["status"] = ["type": "active"]
        }
        try f.arm()
        #expect(f.rpc.reads().isEmpty)
        #expect(f.rpc.sends().isEmpty)
    }

    // test_settings_changes_keep_quota_checks_separate_from_capacity_retry_interval
    @Test func settingsChangesKeepQuotaChecksSeparateFromCapacityRetryInterval() throws {
        let f = try QuotaFixture()
        try f.arm()
        var settings = Settings.defaults
        settings.retrySeconds = 900
        settings.scanSeconds = 300
        try f.engine.applySettings(settings)
        #expect(f.pending?.dueAt == 1400)
        settings.retrySeconds = 180
        settings.scanSeconds = 60
        try f.engine.applySettings(settings)
        #expect(f.pending?.dueAt == 1160)
        #expect(f.pending?.accountBinding != nil)
    }

    // test_quota_retry_result_retains_origin_when_it_encounters_capacity
    @Test func quotaRetryResultRetainsOriginWhenItEncountersCapacity() throws {
        let f = try QuotaFixture()
        try f.arm()
        f.rpc.quota["ordinaryUsageAllowed"] = true
        try f.engine.step(f.rpc, now: 1400)
        f.rpc.turns["user-session"] = QuotaFixtures.capacityTurn("retry-turn", 1405)
        try f.engine.step(f.rpc, now: 1430, discover: false)
        let result = try #require(f.events.first { $0.event == "retry_result" }?.fields)
        #expect(result["kind"] == "quota")
        #expect(result["status"] == "failed")
        #expect(result["capacity"] == true)
        #expect(f.pending?.resolvedKind == "capacity")
        #expect(f.pending?.dueAt == 1610)
    }

    // test_maintenance_preserves_discovery_counts_and_does_not_discover_new_failures
    @Test func maintenancePreservesDiscoveryCountsAndDoesNotDiscoverNewFailures() throws {
        let f = try QuotaFixture()
        f.rpc.turns["user-session"] = QuotaFixtures.capacityTurn()
        try f.arm()
        let oldCounts = f.state.sessions
        #expect(oldCounts != nil)
        f.rpc.loaded.append("new-session")
        f.rpc.threads["new-session"] = QuotaFixtures.userThread("new-session")
        f.rpc.turns["new-session"] = QuotaFixtures.quotaTurn("new-quota")
        #expect(!f.engine.maintenanceDue(1279))
        #expect(f.engine.maintenanceDue(1280))
        try f.engine.step(f.rpc, now: 1280, discover: false)
        #expect(f.rpc.sends().count == 1)
        #expect(f.state.sessions == oldCounts)
        #expect(f.state.pending["new-session"] == nil)
        #expect(f.rpc.reads().isEmpty)
        #expect(!f.engine.maintenanceDue(1309))
        #expect(f.engine.maintenanceDue(1310))
    }

    // test_submitted_retry_is_observed_every_thirty_seconds_and_recovers_after_two_minutes
    @Test func submittedRetryIsObservedEveryThirtySecondsAndRecoversAfterTwoMinutes() throws {
        let f = try QuotaFixture()
        try f.arm()
        f.rpc.quota["ordinaryUsageAllowed"] = true
        try f.engine.step(f.rpc, now: 1400)
        f.rpc.turns["user-session"] = QuotaFixtures.capacityTurn("retry-turn", 1100, ["status": "inProgress", "error": nil])
        f.rpc.threads["user-session"]?["status"] = ["type": "active", "activeFlags": []]
        for now: Double in [1430, 1460, 1490, 1520] {
            #expect(f.engine.maintenanceDue(now), "now \(now)")
            try f.engine.step(f.rpc, now: now, discover: false)
        }
        #expect(f.state.handled["user-session"]?.resultStatus == nil)
        try f.engine.step(f.rpc, now: 1550, discover: false)
        #expect(f.state.handled["user-session"]?.resultStatus == "successful")
        #expect(!f.engine.maintenanceDue(1700))
    }
}

// The worker-loop deadline tests are in WorkerLoopTests.swift.
