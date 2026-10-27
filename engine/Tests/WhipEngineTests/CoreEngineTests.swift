// Port of tests/test_core.py: classification, RetryEngine scenarios, reporting, recovery
// observation and history reconciliation. Never contacts a real Codex session.
// The transport and doctor checks live in TransportTests.swift.

import Foundation
import Testing
@testable import WhipEngine

// MARK: - Fixtures shared with TransportTests.swift

struct CoreFakeFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

func coreUserThread(_ id: String = "user-session", _ changes: [String: JSON] = [:]) -> JSON {
    var value: [String: JSON] = [
        "id": .string(id),
        "model": "keep-this-model",
        "reasoningEffort": "xhigh",
        "status": ["type": "idle"],
        "source": "vscode",
        "originator": "codex-tui",
        "parentThreadId": nil,
        "threadSource": "user",
        "canAcceptDirectInput": true,
    ]
    value.merge(changes) { _, new in new }
    return .object(value)
}

func coreCapacityTurn(_ id: String = "capacity-failure", completedAt: JSON = 1100,
                      _ changes: [String: JSON] = [:]) -> JSON {
    var value: [String: JSON] = [
        "id": .string(id),
        "status": "failed",
        "error": ["codexErrorInfo": "serverOverloaded", "message": .string(capacityMessage)],
        "completedAt": completedAt,
    ]
    value.merge(changes) { _, new in new }
    return .object(value)
}

func coreCapacityTurn(_ changes: [String: JSON]) -> JSON {
    coreCapacityTurn("capacity-failure", changes)
}

/// The Python FakeRPC: a scripted terminal daemon that records every call.
final class CoreFakeRPC: RPCClient {
    var threads: [String: JSON] = ["user-session": coreUserThread()]
    var turns: [String: JSON] = ["user-session": coreCapacityTurn()]
    var loaded = ["user-session"]
    var calls: [(method: String, params: JSON)] = []
    var beforeCall: ((String, JSON) throws -> Void)?
    var sendError: Error?
    var pages: [String?: JSON]?
    /// Stands in for Python tests that replaced `rpc.call` with a wrapper. A non-nil result
    /// answers the call without recording it, as the wrapper did.
    var override: ((String, JSON) -> JSON?)?

    func call(_ method: String, _ params: JSON) throws -> JSON {
        if let override, let value = override(method, params) { return value }
        calls.append((method, params))
        try beforeCall?(method, params)
        if method == "thread/loaded/list" {
            if let pages {
                guard let page = pages[params["cursor"]?.string] else { throw CoreFakeFailure("Unknown page") }
                return page
            }
            return ["data": .array(loaded.map(JSON.string)), "nextCursor": nil]
        }
        guard let id = params["threadId"]?.string else { throw CoreFakeFailure("No threadId for \(method)") }
        switch method {
        case "thread/read":
            guard let thread = threads[id] else { throw CoreFakeFailure("KeyError: \(id)") }
            return ["thread": thread]
        case "thread/turns/list":
            let turn = turns[id]
            return ["data": .array(turn.map { [$0] } ?? []), "nextCursor": nil]
        case "turn/start":
            if let sendError { throw sendError }
            return ["turn": ["id": "retry-turn", "status": "inProgress"]]
        default:
            throw CoreFakeFailure("Unexpected RPC: \(method)")
        }
    }

    func sends() -> [JSON] { calls.filter { $0.method == "turn/start" }.map(\.params) }
}

final class CoreFlag {
    var value = false
}

/// RetryEngineTests.setUp and RecoverySuccessTests.setUp: the RPC, state, saves and events.
final class CoreEngineFixture {
    var rpc = CoreFakeRPC()
    let state: RetryState
    var saved: [JSON] = []
    var events: [(event: String, fields: [String: JSON])] = []
    var engine: RetryEngine!

    init(state: RetryState = RetryState(enabledAt: 1000)) throws {
        self.state = state
        engine = try newEngine()
    }

    func newEngine(threads: [String] = [], shouldStop: @escaping () -> Bool = { false }) throws -> RetryEngine {
        try RetryEngine(state: state, save: { [unowned self] in self.saved.append($0.json) },
                        emit: { [unowned self] event, fields in self.events.append((event, fields)) },
                        interval: 300, threads: threads, shouldStop: shouldStop, scanInterval: 60)
    }

    func arm() throws { try engine.step(rpc, now: 1100) }
    func step(_ now: Double) throws { try engine.step(rpc, now: now) }

    func results() -> [[String: JSON]] { events.filter { $0.event == "retry_result" }.map(\.fields) }
}

// MARK: - RetryEngineTests

@Suite struct CoreRetryEngineTests {
    // test_waits_five_minutes_before_continuing_same_session
    @Test func waitsFiveMinutesBeforeContinuingSameSession() throws {
        let f = try CoreEngineFixture()
        try f.arm()
        try f.step(1399)
        #expect(f.rpc.sends() == [])
        try f.step(1400)
        #expect(f.rpc.sends() == [[
            "threadId": "user-session",
            "input": [["type": "text", "text": "Keep using the selected model. Continue the unfinished work."]],
        ]])
        // No resume, approval, sandbox, tier, model or reasoning override is sent.
        #expect(!f.rpc.calls.contains { $0.method == "thread/resume" })
    }

    // test_does_not_retry_historical_failures
    @Test func doesNotRetryHistoricalFailures() throws {
        let f = try CoreEngineFixture()
        for completedAt: JSON in [999, nil, "1100"] {
            f.rpc.turns["user-session"] = coreCapacityTurn(completedAt: completedAt)
            try f.step(1100)
            try f.step(10000)
            #expect(f.rpc.sends() == [], "completedAt \(completedAt)")
            #expect(f.state.pending.isEmpty, "completedAt \(completedAt)")
        }
    }

    // test_recovery_interruption_and_other_errors_cancel_pending_retry
    @Test func recoveryInterruptionAndOtherErrorsCancelPendingRetry() throws {
        let replacements: [JSON?] = [
            coreCapacityTurn("finished", ["status": "completed", "error": nil]),
            coreCapacityTurn("cancelled", ["status": "interrupted"]),
            coreCapacityTurn("still-working", ["status": "inProgress"]),
            coreCapacityTurn("bad-auth", ["error": ["codexErrorInfo": "unauthorized", "message": "Sign in"]]),
            nil,
        ]
        for replacement in replacements {
            let f = try CoreEngineFixture()
            try f.arm()
            f.rpc.turns["user-session"] = replacement
            try f.step(1400)
            #expect(f.rpc.sends() == [], "replacement \(String(describing: replacement))")
            #expect(f.state.pending.isEmpty, "replacement \(String(describing: replacement))")
        }
    }

    // test_busy_session_is_not_steered
    @Test func busySessionIsNotSteered() throws {
        let f = try CoreEngineFixture()
        try f.arm()
        f.rpc.threads["user-session"]?["status"] = ["type": "active", "activeFlags": []]
        try f.step(1400)
        #expect(f.rpc.sends() == [])
        #expect(f.state.pending.isEmpty)
    }

    // test_model_or_reasoning_change_cancels_and_never_rearms_old_failure
    @Test func modelOrReasoningChangeCancelsAndNeverRearmsOldFailure() throws {
        for (key, value) in [("model", "new-user-choice"), ("reasoningEffort", "low")] {
            let f = try CoreEngineFixture()
            try f.arm()
            f.rpc.threads["user-session"]?[key] = .string(value)
            try f.step(1400)
            try f.step(1800)
            #expect(f.rpc.sends() == [], "key \(key)")
            #expect(f.state.pending.isEmpty, "key \(key)")
        }
    }

    // test_newer_capacity_failure_gets_its_own_full_wait
    @Test func newerCapacityFailureGetsItsOwnFullWait() throws {
        let f = try CoreEngineFixture()
        try f.arm()
        f.rpc.turns["user-session"] = coreCapacityTurn("new-user-turn", completedAt: 1300)
        try f.step(1400)
        #expect(f.rpc.sends() == [])
        try f.step(1699)
        #expect(f.rpc.sends() == [])
        try f.step(1700)
        #expect(f.rpc.sends().count == 1)
    }

    // test_final_recheck_catches_new_work_before_sending
    @Test func finalRecheckCatchesNewWorkBeforeSending() throws {
        let f = try CoreEngineFixture()
        try f.arm()
        var reads = 0
        f.rpc.beforeCall = { [unowned f] method, _ in
            if method == "thread/turns/list" {
                reads += 1
                if reads == 2 {
                    f.rpc.turns["user-session"] = coreCapacityTurn("user-started", ["status": "inProgress"])
                }
            }
        }
        try f.step(1400)
        #expect(f.rpc.sends() == [])
        #expect(f.state.pending.isEmpty)
    }

    // test_final_recheck_catches_busy_or_changed_model
    @Test func finalRecheckCatchesBusyOrChangedModel() throws {
        let changes: [(String, JSON)] = [("status", ["type": "active"]), ("model", "another-model")]
        for (key, value) in changes {
            let f = try CoreEngineFixture()
            try f.arm()
            var reads = 0
            f.rpc.beforeCall = { [unowned f] method, _ in
                if method == "thread/read" {
                    reads += 1
                    if reads == 2 { f.rpc.threads["user-session"]?[key] = value }
                }
            }
            try f.step(1400)
            #expect(f.rpc.sends() == [], "key \(key)")
        }
    }

    // test_final_runtime_status_read_catches_activity_after_turn_read
    @Test func finalRuntimeStatusReadCatchesActivityAfterTurnRead() throws {
        let f = try CoreEngineFixture()
        try f.arm()
        var reads = 0
        f.rpc.beforeCall = { [unowned f] method, _ in
            if method == "thread/read" {
                reads += 1
                if reads == 3 { f.rpc.threads["user-session"]?["status"] = ["type": "active"] }
            }
        }
        try f.step(1400)
        #expect(reads == 3)
        #expect(f.rpc.sends() == [])
    }

    // test_stop_request_during_final_read_prevents_submission
    @Test func stopRequestDuringFinalReadPreventsSubmission() throws {
        let f = try CoreEngineFixture()
        let stopping = CoreFlag()
        f.engine = try f.newEngine(shouldStop: { stopping.value })
        try f.arm()
        var reads = 0
        f.rpc.beforeCall = { method, _ in
            if method == "thread/read" {
                reads += 1
                if reads == 3 { stopping.value = true }
            }
        }
        try f.step(1400)
        #expect(stopping.value)
        #expect(f.rpc.sends() == [])
        #expect(f.state.handled.isEmpty)
    }

    // test_stop_request_during_journal_save_prevents_submission
    @Test func stopRequestDuringJournalSavePreventsSubmission() throws {
        let f = try CoreEngineFixture()
        let stopping = CoreFlag()
        f.engine = try RetryEngine(
            state: f.state,
            save: { [unowned f] value in
                f.saved.append(value.json)
                if value.handled["user-session"]?.outcome == "uncertain" { stopping.value = true }
            },
            emit: { [unowned f] event, fields in f.events.append((event, fields)) },
            interval: 300, shouldStop: { stopping.value }, scanInterval: 60)
        try f.arm()
        try f.step(1400)
        #expect(stopping.value)
        #expect(f.rpc.sends() == [])
        #expect(f.saved.last?["handled"]?["user-session"]?["outcome"] == "uncertain")
    }

    // test_one_unavailable_thread_does_not_starve_another
    @Test func oneUnavailableThreadDoesNotStarveAnother() throws {
        let f = try CoreEngineFixture()
        f.rpc.loaded = ["a-unavailable", "user-session"]
        f.rpc.beforeCall = { method, params in
            if method == "thread/read" && params["threadId"] == "a-unavailable" {
                throw RPCError.request("Thread unavailable")
            }
        }
        try f.arm()
        try f.step(1400)
        #expect(f.rpc.sends().count == 1)
        #expect(f.events.contains { $0.event == "thread_unavailable" })
    }

    // test_unavailable_final_read_defers_retry_until_verified
    @Test func unavailableFinalReadDefersRetryUntilVerified() throws {
        let f = try CoreEngineFixture()
        try f.arm()
        var reads = 0
        f.rpc.beforeCall = { method, _ in
            if method == "thread/read" {
                reads += 1
                if reads == 2 { throw RPCError.request("Thread temporarily unavailable") }
            }
        }
        try f.step(1400)
        #expect(f.rpc.sends() == [])
        f.rpc.beforeCall = nil
        try f.step(1410)
        #expect(f.rpc.sends().count == 1)
    }

    // test_restart_preserves_pending_wait
    @Test func restartPreservesPendingWait() throws {
        let f = try CoreEngineFixture()
        try f.arm()
        f.engine = try f.newEngine()
        try f.step(1399)
        #expect(f.rpc.sends() == [])
        try f.step(1400)
        #expect(f.rpc.sends().count == 1)
    }

    // test_sent_failure_cannot_be_sent_twice_after_restart
    @Test func sentFailureCannotBeSentTwiceAfterRestart() throws {
        let f = try CoreEngineFixture()
        try f.arm()
        try f.step(1400)
        f.engine = try f.newEngine()
        try f.step(1800)
        #expect(f.rpc.sends().count == 1)
        #expect(f.state.handled["user-session"]?.outcome == "submitted")
    }

    // test_disconnect_during_send_is_journaled_before_send_and_never_resent
    @Test func disconnectDuringSendIsJournaledBeforeSendAndNeverResent() throws {
        let f = try CoreEngineFixture()
        try f.arm()
        f.rpc.sendError = RPCError.transport("connection closed after sending")
        #expect(throws: RPCError.self) { try f.step(1400) }
        #expect(f.saved.last?["handled"]?["user-session"]?["outcome"] == "uncertain")
        #expect(f.saved.last?["pending"] == [:])
        f.engine = try f.newEngine()
        f.rpc.sendError = nil
        try f.step(1800)
        #expect(f.rpc.sends().count == 1)
    }

    // test_repeated_capacity_failures_continue_until_success
    @Test func repeatedCapacityFailuresContinueUntilSuccess() throws {
        let f = try CoreEngineFixture()
        try f.arm()
        try f.step(1400)
        f.rpc.turns["user-session"] = coreCapacityTurn("retry-turn", completedAt: 1410)
        try f.step(1410)
        try f.step(1709)
        #expect(f.rpc.sends().count == 1)
        try f.step(1710)
        #expect(f.rpc.sends().count == 2)
        f.rpc.turns["user-session"] = coreCapacityTurn("done", ["status": "completed", "error": nil])
        try f.step(2000)
        try f.step(10000)
        #expect(f.rpc.sends().count == 2)
        #expect(f.state.pending.isEmpty)
    }

    // test_unloaded_session_is_cancelled_and_not_rearmed_when_reopened
    @Test func unloadedSessionIsCancelledAndNotRearmedWhenReopened() throws {
        let f = try CoreEngineFixture()
        try f.arm()
        f.rpc.loaded = []
        try f.step(1400)
        f.rpc.loaded = ["user-session"]
        try f.step(1500)
        try f.step(1900)
        #expect(f.rpc.sends() == [])
    }

    // test_paused_session_is_not_retried
    @Test func pausedSessionIsNotRetried() throws {
        let f = try CoreEngineFixture()
        try f.arm()
        f.state.paused["user-session"] = true
        try f.step(1400)
        #expect(f.rpc.sends() == [])
        #expect(f.state.pending.isEmpty)
    }

    // test_explicit_thread_scope_does_not_touch_other_sessions
    @Test func explicitThreadScopeDoesNotTouchOtherSessions() throws {
        let f = try CoreEngineFixture()
        f.engine = try f.newEngine(threads: ["another-session"])
        try f.step(1100)
        #expect(f.rpc.calls.map(\.method) == ["thread/loaded/list"])
        #expect(f.rpc.sends() == [])
    }

    // test_only_loaded_top_level_user_sessions_with_known_model_are_eligible
    @Test func onlyLoadedTopLevelUserSessionsWithKnownModelAreEligible() throws {
        let variants: [[String: JSON]] = [
            ["parentThreadId": "parent"],
            ["ephemeral": true],
            ["threadSource": "subAgent"],
            ["source": ["subAgent": ["thread_spawn": [:]]]],
            ["source": "exec"],
            ["source": "unknown"],
            ["source": "vscode", "originator": nil],
            ["source": "appServer", "originator": "codex-desktop"],
            ["canAcceptDirectInput": false],
            ["canAcceptDirectInput": nil],
            ["model": nil],
            ["status": ["type": "notLoaded"]],
        ]
        for changes in variants {
            let f = try CoreEngineFixture()
            for (key, value) in changes { f.rpc.threads["user-session"]?[key] = value }
            try f.arm()
            try f.step(1400)
            #expect(f.rpc.sends() == [], "changes \(changes)")
            #expect(f.state.pending.isEmpty, "changes \(changes)")
            #expect(!f.rpc.calls.contains { $0.method == "thread/turns/list" }, "changes \(changes)")
        }
    }

    // test_terminal_sessions_are_identified_by_source_or_tui_originator
    @Test func terminalSessionsAreIdentifiedBySourceOrTuiOriginator() throws {
        let cases: [(String, JSON)] = [("cli", nil), ("vscode", "codex-tui"), ("appServer", "codex-tui")]
        for (source, originator) in cases {
            let f = try CoreEngineFixture()
            f.rpc.threads["user-session"]?["source"] = .string(source)
            f.rpc.threads["user-session"]?["originator"] = originator
            try f.arm()
            try f.step(1400)
            #expect(f.rpc.sends().count == 1, "source \(source) originator \(originator)")
        }
    }

    // test_real_capacity_error_runtime_is_retried_after_full_wait
    @Test func realCapacityErrorRuntimeIsRetriedAfterFullWait() throws {
        let f = try CoreEngineFixture()
        f.rpc.threads["user-session"]?["status"] = ["type": "systemError"]
        try f.arm()
        #expect(f.state.pending["user-session"] != nil)
        #expect(f.state.sessions?["errored"] == 1)
        try f.step(1399)
        #expect(f.rpc.sends() == [])
        try f.step(1400)
        #expect(f.rpc.sends().count == 1)
    }

    // test_unrelated_system_error_never_triggers_retry
    @Test func unrelatedSystemErrorNeverTriggersRetry() throws {
        let f = try CoreEngineFixture()
        f.rpc.threads["user-session"]?["status"] = ["type": "systemError"]
        f.rpc.turns["user-session"] = coreCapacityTurn(["error": ["codexErrorInfo": "unauthorized"]])
        try f.arm()
        try f.step(1400)
        #expect(f.rpc.sends() == [])
        #expect(f.state.pending.isEmpty)
    }

    // test_loaded_session_pagination_is_followed
    @Test func loadedSessionPaginationIsFollowed() throws {
        let f = try CoreEngineFixture()
        f.rpc.pages = [
            nil: ["data": [], "nextCursor": "second"],
            "second": ["data": ["user-session"], "nextCursor": nil],
        ]
        try f.arm()
        try f.step(1400)
        #expect(f.rpc.sends().count == 1)
        let cursors = f.rpc.calls.filter { $0.method == "thread/loaded/list" }.map { $0.params["cursor"] }
        #expect(cursors == [.null, "second", .null, "second"])
    }
}

// MARK: - ReportingTests

@Suite struct CoreReportingTests {
    private func engine(_ state: RetryState, _ events: CoreEvents) throws -> RetryEngine {
        try RetryEngine(state: state, save: { _ in }, emit: { event, fields in events.items.append((event, fields)) },
                        interval: 300, threads: state.threads, scanInterval: 60)
    }

    private func submitted(at: Double? = nil) -> RetryState {
        let state = RetryState(enabledAt: 1000)
        var attempt = Attempt(turnID: "original", at: at, outcome: "submitted")
        attempt.retryTurnID = "retry-turn"
        state.handled["user-session"] = attempt
        return state
    }

    // test_session_counts_include_active_and_idle_but_exclude_unwatched_threads
    @Test func sessionCountsIncludeActiveAndIdleButExcludeUnwatchedThreads() throws {
        let rpc = CoreFakeRPC()
        rpc.loaded = ["idle", "active", "child", "paused", "ide"]
        rpc.threads = [
            "idle": coreUserThread("idle"),
            "active": coreUserThread("active", ["status": ["type": "active"]]),
            "child": coreUserThread("child", ["parentThreadId": "parent"]),
            "paused": coreUserThread("paused"),
            "ide": coreUserThread("ide", ["originator": "ide-client"]),
        ]
        rpc.turns = [:]
        let state = RetryState(enabledAt: 1000)
        state.paused = ["paused": true]
        try engine(state, CoreEvents()).step(rpc, now: 1100)
        #expect(state.sessions == ["total": 2, "active": 1, "idle": 1, "errored": 0, "other": 0, "unavailable": 0])
        #expect(rpc.sends() == [])
    }

    // test_session_counts_respect_explicit_scope
    @Test func sessionCountsRespectExplicitScope() throws {
        let rpc = CoreFakeRPC()
        rpc.loaded.append("another")
        rpc.threads["another"] = coreUserThread("another")
        let state = RetryState(enabledAt: 1000, threads: ["another"])
        try engine(state, CoreEvents()).step(rpc, now: 1100)
        #expect(state.sessions?["total"] == 1)
        #expect(!rpc.calls.contains { $0.params["threadId"] == "user-session" })
    }

    // test_completed_retry_is_observed_once_and_send_acceptance_is_not_success
    @Test func completedRetryIsObservedOnceAndSendAcceptanceIsNotSuccess() throws {
        let rpc = CoreFakeRPC(), events = CoreEvents()
        let state = submitted()
        let engine = try engine(state, events)
        rpc.turns["user-session"] = coreCapacityTurn("retry-turn", ["status": "inProgress", "error": nil])
        rpc.threads["user-session"]?["status"] = ["type": "active"]
        try engine.step(rpc, now: 1100)
        #expect(!events.items.contains { $0.event == "retry_result" })
        rpc.turns["user-session"] = coreCapacityTurn("retry-turn", ["status": "completed", "error": nil])
        rpc.threads["user-session"]?["status"] = ["type": "idle"]
        try engine.step(rpc, now: 1160)
        try engine.step(rpc, now: 1220)
        #expect(events.results() == [["thread_id": "user-session", "turn_id": "retry-turn",
                                      "status": "successful", "capacity": false, "occurred_at": 1100.0,
                                      "kind": "capacity"]])
    }

    // test_failed_retry_records_capacity_separately_from_other_errors
    @Test func failedRetryRecordsCapacitySeparatelyFromOtherErrors() throws {
        let cases: [(JSON, Bool)] = [(["codexErrorInfo": "serverOverloaded"], true),
                                     (["codexErrorInfo": "unauthorized"], false)]
        for (error, expected) in cases {
            let rpc = CoreFakeRPC(), events = CoreEvents()
            let state = submitted()
            rpc.turns["user-session"] = coreCapacityTurn("retry-turn", ["error": error])
            try engine(state, events).step(rpc, now: 1100)
            let result = try #require(events.results().first, "error \(error)")
            #expect(result["capacity"] == .bool(expected), "error \(error)")
            #expect(result["status"] == "failed", "error \(error)")
        }
    }

    // test_new_user_turn_is_not_mistaken_for_retry_success
    @Test func newUserTurnIsNotMistakenForRetrySuccess() throws {
        let rpc = CoreFakeRPC(), events = CoreEvents()
        let state = submitted()
        rpc.turns["user-session"] = coreCapacityTurn("new-user-turn", ["status": "completed", "error": nil])
        try engine(state, events).step(rpc, now: 1100)
        #expect(!events.items.contains { $0.event == "retry_result" })
        #expect(state.handled["user-session"]?.resultStatus == nil)
    }

    // test_retry_outcome_is_found_after_a_new_user_turn_starts
    @Test func retryOutcomeIsFoundAfterANewUserTurnStarts() throws {
        let rpc = CoreFakeRPC(), events = CoreEvents()
        let state = submitted()
        let newer = coreCapacityTurn("new-user-turn", ["status": "inProgress", "error": nil])
        let completed = coreCapacityTurn("retry-turn", ["status": "completed", "error": nil])
        rpc.threads["user-session"]?["status"] = ["type": "active"]
        rpc.override = { method, params in
            method == "thread/turns/list" && params["limit"] == 20 ? ["data": [newer, completed]] : nil
        }
        try engine(state, events).step(rpc, now: 1160)
        let result = try #require(events.results().first)
        #expect(result["turn_id"] == "retry-turn")
        #expect(result["status"] == "successful")
    }

    // test_finished_retry_is_recorded_after_terminal_session_unloads
    @Test func finishedRetryIsRecordedAfterTerminalSessionUnloads() throws {
        let rpc = CoreFakeRPC(), events = CoreEvents()
        rpc.loaded = []
        rpc.turns["user-session"] = coreCapacityTurn("retry-turn", ["status": "completed", "error": nil])
        let state = submitted(at: 1100)
        try engine(state, events).step(rpc, now: 1160)
        let result = try #require(events.results().first)
        #expect(result["status"] == "successful")
        #expect(state.sessions?["total"] == 0)
        #expect(rpc.sends() == [])
        #expect(!rpc.calls.contains { $0.method == "thread/resume" })
    }

    // test_status_uses_saved_counts_and_reports_stopped_as_zero
    @Test func statusUsesSavedCountsAndReportsStoppedAsZero() throws {
        let state: JSON = ["sessions": ["total": 9, "active": 3, "idle": 6], "pending": [:], "last_scan_at": 1000]
        for (enabled, expected) in [(true, "Watching: 9 terminal sessions (3 active, 6 idle)"),
                                    (false, "Watching: 0 terminal sessions (stopped)")] {
            let directory = try coreTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            try Data(try state.serialized().utf8).write(to: directory.appendingPathComponent("state.json"))
            var lines: [String] = []
            // serviceRunning and activity stand in for the patched service_running and print_activity.
            try Service.status(directory: directory, serviceRunning: { enabled }, activity: { _ in },
                               output: { lines.append($0) })
            let output = lines.joined(separator: "\n")
            #expect(output.contains(expected), "enabled \(enabled)")
            #expect(output.contains("Checks: every 5 minutes. Capacity retries: every 3 minutes."), "enabled \(enabled)")
        }
    }

    // test_history_reconciles_crash_between_state_save_and_event_write
    @Test func historyReconcilesCrashBetweenStateSaveAndEventWrite() throws {
        let directory = try coreTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = try History(directory: directory, clock: { 1500 })
        defer { history.close() }
        let state = RetryState(enabledAt: 1000)
        // Python's pending entry has no model; the Swift Pending requires one, and reconciliation ignores it.
        state.pending["waiting-session"] = Pending(turnID: "capacity-1", model: "", effort: nil, detectedAt: 1200,
                                                   waitStartedAt: nil, dueAt: 1500)
        var attempt = Attempt(turnID: "capacity-2", at: 1400, outcome: "submitted")
        attempt.capacityAt = 1100
        attempt.retryTurnID = "retry-2"
        state.handled["sent-session"] = attempt
        try reconcileHistory(state, history, now: 1500)
        try reconcileHistory(state, history, now: 1500)
        let report = try History.report(directory: directory, now: 1500)
        #expect(report["capacity"] == 2)
        #expect(report["retries"] == 1)
        #expect(report["awaiting"] == 1)
        let retry = try #require(report["recent"]?.array?.first { $0["event"] == "retry" })
        #expect(retry["ts"]?.number == 1400)
    }

    private func report(_ fields: [String: JSON]) -> JSON {
        var value: [String: JSON] = [:]
        for name in History.quotaCounters { value[name] = 0 }
        value.merge(fields) { _, new in new }
        return .object(value)
    }

    // test_cli_report_describes_recovery_success_and_awaiting_recovery
    @Test func cliReportDescribesRecoverySuccessAndAwaitingRecovery() throws {
        let report = report([
            "available": true, "capacity": 4, "retries": 3, "successful": 2,
            "failed": 0, "failed_capacity": 0, "failed_other": 0, "interrupted": 0,
            "awaiting": 1, "uncertain": 0, "recorded_since": nil,
            "recent": [["event": "retry_result", "status": "completed", "ts": 1200,
                        "thread_id": "session", "capacity": false]],
        ])
        var lines: [String] = []
        Service.printActivity(report: report, output: { lines.append($0) })
        let output = lines.joined(separator: "\n")
        #expect(output.contains("Successful: 2"))
        #expect(output.contains("Awaiting recovery: 1"))
        #expect(output.contains("2 minutes of continuously observed healthy activity"))
        #expect(output.contains("retry successful"))
    }

    // test_cli_report_names_sessions_by_the_end_of_their_ids
    @Test func cliReportNamesSessionsByTheEndOfTheirIds() throws {
        // Neighboring sessions share a timestamp prefix; only the ending tells them apart.
        let report = report([
            "available": true, "capacity": 2, "retries": 0, "successful": 0,
            "failed": 0, "failed_capacity": 0, "failed_other": 0, "interrupted": 0,
            "awaiting": 0, "uncertain": 0, "recorded_since": nil,
            "recent": .array(["7f3a", "c2d9"].map { suffix in
                ["event": "capacity", "ts": 1200, "capacity": true,
                 "thread_id": .string("019a2b3c-4d5e-7f00-8a1b-00000000\(suffix)")]
            }),
        ])
        var lines: [String] = []
        Service.printActivity(report: report, output: { lines.append($0) })
        let output = lines.joined(separator: "\n")
        #expect(output.contains(" · 00007f3a · capacity error found"))
        #expect(output.contains(" · 0000c2d9 · capacity error found"))
        #expect(!output.contains("019a2b3c"))
    }
}

final class CoreEvents {
    var items: [(event: String, fields: [String: JSON])] = []
    func results() -> [[String: JSON]] { items.filter { $0.event == "retry_result" }.map(\.fields) }
}

func coreTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("cw-core-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

// MARK: - RecoverySuccessTests

@Suite struct CoreRecoverySuccessTests {
    private func fixture() throws -> CoreEngineFixture {
        let state = RetryState(enabledAt: 1000)
        var attempt = Attempt(turnID: "original", at: 1000, outcome: "submitted")
        attempt.retryTurnID = "retry-turn"
        state.handled["user-session"] = attempt
        let f = try CoreEngineFixture(state: state)
        f.rpc.threads["user-session"]?["status"] = ["type": "active", "activeFlags": []]
        f.rpc.turns["user-session"] = coreCapacityTurn("retry-turn", ["status": "inProgress", "error": nil])
        return f
    }

    // test_success_requires_observed_healthy_activity_spanning_120_seconds
    @Test func successRequiresObservedHealthyActivitySpanning120Seconds() throws {
        let f = try fixture()
        try f.step(1100)
        try f.step(1160)
        try f.step(1219)
        #expect(f.results().isEmpty)
        #expect(f.saved.last?["handled"]?["user-session"]?["healthy_since"]?.number == 1100)
        #expect(f.saved.last?["handled"]?["user-session"]?["healthy_last_seen"]?.number == 1219)
        try f.step(1220)
        #expect(f.results() == [[
            "thread_id": "user-session", "turn_id": "retry-turn", "status": "successful",
            "capacity": false, "occurred_at": 1220.0, "kind": "capacity",
        ]])
        #expect(f.state.handled["user-session"]?.resultStatus == "successful")
        #expect(f.state.handled["user-session"]?.healthySince == nil)
    }

    // test_active_snapshot_without_latest_turn_uses_first_recent_retry_for_success
    @Test func activeSnapshotWithoutLatestTurnUsesFirstRecentRetryForSuccess() throws {
        let f = try fixture()
        let (thread, latest) = try snapshot(f.rpc, "user-session")
        #expect(thread["status"] == ["type": "active", "activeFlags": []])
        #expect(latest == nil)
        f.rpc.calls.removeAll()
        for now in [1100.0, 1160, 1220] { try f.step(now) }
        let queries = f.rpc.calls.filter { $0.method == "thread/turns/list" }.map { $0.params["limit"] }
        #expect(queries == [20, 20, 20])
        #expect(f.results().first?["status"] == "successful")
    }

    // test_success_latches_and_ends_outcome_polling_after_restart
    @Test func successLatchesAndEndsOutcomePollingAfterRestart() throws {
        let f = try fixture()
        for now in [1100.0, 1160, 1220] { try f.step(now) }
        f.rpc.calls.removeAll()
        f.engine = try f.newEngine()
        try f.step(1280)
        #expect(f.results().count == 1)
        #expect(!f.rpc.calls.contains { $0.method == "thread/turns/list" })
    }

    // test_timer_and_send_acceptance_without_positive_work_are_insufficient
    @Test func timerAndSendAcceptanceWithoutPositiveWorkAreInsufficient() throws {
        for runtime in ["idle", "systemError", "notLoaded"] {
            let f = try fixture()
            f.rpc.threads["user-session"]?["status"] = ["type": .string(runtime), "activeFlags": []]
            for now in [1100.0, 1160, 1220, 1280] { try f.step(now) }
            #expect(f.results().isEmpty, "runtime \(runtime)")
            #expect(f.state.handled["user-session"]?.healthySince == nil, "runtime \(runtime)")
        }
    }

    // test_waiting_flags_and_unknown_flags_reset_the_full_window
    @Test func waitingFlagsAndUnknownFlagsResetTheFullWindow() throws {
        let flagSets: [JSON] = [["waitingOnApproval"], ["waitingOnUserInput"], ["unknown"], nil]
        for flags in flagSets {
            let f = try fixture()
            try f.step(1100)
            f.rpc.threads["user-session"]?["status"] = ["type": "active", "activeFlags": flags]
            try f.step(1160)
            #expect(f.state.handled["user-session"]?.healthySince == nil, "flags \(flags)")
            f.rpc.threads["user-session"]?["status"] = ["type": "active", "activeFlags": []]
            try f.step(1220)
            try f.step(1280)
            #expect(f.results().isEmpty, "flags \(flags)")
            try f.step(1340)
            #expect(f.results().first?["occurred_at"]?.number == 1340, "flags \(flags)")
        }
    }

    // test_in_progress_turn_error_is_not_healthy_activity
    @Test func inProgressTurnErrorIsNotHealthyActivity() throws {
        let f = try fixture()
        try f.step(1100)
        f.rpc.turns["user-session"]?["error"] = ["message": "Stream unavailable"]
        try f.step(1160)
        #expect(f.state.handled["user-session"]?.healthySince == nil)
        #expect(f.results().isEmpty)
    }

    // test_paused_unloaded_and_unavailable_observations_reset_continuity
    @Test func pausedUnloadedAndUnavailableObservationsResetContinuity() throws {
        for condition in ["paused", "unloaded", "unavailable"] {
            let f = try fixture()
            try f.step(1100)
            switch condition {
            case "paused": f.state.paused["user-session"] = true
            case "unloaded": f.rpc.loaded = []
            default:
                f.rpc.beforeCall = { method, _ in
                    if method == "thread/read" { throw RPCError.request("Thread unavailable") }
                }
            }
            try f.step(1160)
            #expect(f.state.handled["user-session"]?.healthySince == nil, "condition \(condition)")
            f.state.paused.removeAll()
            f.rpc.loaded = ["user-session"]
            f.rpc.beforeCall = nil
            try f.step(1220)
            try f.step(1280)
            #expect(f.results().isEmpty, "condition \(condition)")
            try f.step(1340)
            #expect(f.results().first?["occurred_at"]?.number == 1340, "condition \(condition)")
        }
    }

    // test_reconnect_does_not_count_offline_time
    @Test func reconnectDoesNotCountOfflineTime() throws {
        let f = try fixture()
        try f.step(1100)
        try f.step(1160)
        f.rpc.beforeCall = { method, _ in
            if method == "thread/loaded/list" { throw RPCError.transport("Socket disconnected") }
        }
        #expect(throws: RPCError.self) { try f.step(1190) }
        #expect(f.state.handled["user-session"]?.healthySince == nil)
        f.rpc.beforeCall = nil
        try f.step(1200)
        try f.step(1260)
        #expect(f.results().isEmpty)
        try f.step(1320)
        #expect(f.results().first?["occurred_at"]?.number == 1320)
    }

    // test_long_observation_gap_starts_a_new_window
    @Test func longObservationGapStartsANewWindow() throws {
        let f = try fixture()
        try f.step(1100)
        try f.step(1191)
        #expect(f.state.handled["user-session"]?.healthySince == 1191)
        try f.step(1251)
        #expect(f.results().isEmpty)
        try f.step(1311)
        #expect(f.results().first?["occurred_at"]?.number == 1311)
    }

    // test_restart_discards_persisted_active_observation_time
    @Test func restartDiscardsPersistedActiveObservationTime() throws {
        let f = try fixture()
        try f.step(1100)
        try f.step(1160)
        #expect(f.saved.last?["handled"]?["user-session"]?["healthy_since"] != nil)
        f.engine = try f.newEngine()
        #expect(f.state.handled["user-session"]?.healthySince == nil)
        #expect(f.state.handled["user-session"]?.at == 1000)
        try f.step(1190)
        try f.step(1250)
        #expect(f.results().isEmpty)
        try f.step(1310)
        #expect(f.results().first?["occurred_at"]?.number == 1310)
    }

    // test_missing_retry_turn_or_newer_user_activity_does_not_imply_success
    @Test func missingRetryTurnOrNewerUserActivityDoesNotImplySuccess() throws {
        for missing in [true, false] {
            let f = try fixture()
            try f.step(1100)
            let ownTurn = try #require(f.rpc.turns["user-session"])
            let newer = coreCapacityTurn("user-turn", ["status": "inProgress", "error": nil])
            f.rpc.override = { method, params in
                guard method == "thread/turns/list" && params["limit"] == 20 else { return nil }
                return ["data": missing ? [newer] : [newer, ownTurn]]
            }
            try f.step(1160)
            try f.step(1220)
            #expect(f.results().isEmpty, "missing \(missing)")
            #expect(f.state.handled["user-session"]?.healthySince == nil, "missing \(missing)")
        }
    }

    // test_failure_or_interruption_before_success_keeps_actual_outcome
    @Test func failureOrInterruptionBeforeSuccessKeepsActualOutcome() throws {
        let cases: [(String, JSON)] = [("failed", ["codexErrorInfo": "serverOverloaded"]),
                                       ("failed", ["codexErrorInfo": "unauthorized"]),
                                       ("interrupted", nil)]
        for (status, error) in cases {
            let f = try fixture()
            try f.step(1100)
            try f.step(1160)
            f.rpc.threads["user-session"]?["status"] = ["type": "idle"]
            f.rpc.turns["user-session"] = coreCapacityTurn("retry-turn", completedAt: 1219,
                                                           ["status": .string(status), "error": error])
            try f.step(1219)
            #expect(f.results().first?["status"] == .string(status), "status \(status) error \(error)")
        }
    }

    // test_capacity_failure_after_success_arms_new_retry_without_rewriting_success
    @Test func capacityFailureAfterSuccessArmsNewRetryWithoutRewritingSuccess() throws {
        let f = try fixture()
        for now in [1100.0, 1160, 1220] { try f.step(now) }
        f.rpc.threads["user-session"]?["status"] = ["type": "systemError"]
        f.rpc.turns["user-session"] = coreCapacityTurn("retry-turn", completedAt: 1300)
        try f.step(1300)
        #expect(f.results().count == 1)
        #expect(f.results().first?["status"] == "successful")
        #expect(f.state.pending["user-session"]?.turnID == "retry-turn")
        #expect(f.state.pending["user-session"]?.dueAt == 1600)
    }

    // test_success_is_crash_reconciled_from_durable_result_latch
    // The Swift Emit closure cannot throw, so the Python "RuntimeError before history write" cannot be
    // raised. The port drops the retry_result event instead (the lost history write) and checks, at the
    // moment of emitting, that the result latch is already durable on disk.
    @Test func successIsCrashReconciledFromDurableResultLatch() throws {
        let f = try fixture()
        let directory = try coreTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("state.json")
        var latchedAtEmit: JSON?
        f.engine = try RetryEngine(
            state: f.state, save: { try $0.write(path) },
            emit: { event, _ in
                if event == "retry_result" {
                    latchedAtEmit = (try? FileStore.readJSON(path))?["handled"]?["user-session"]?["result_status"]
                }
            },
            interval: 300, scanInterval: 60)
        try f.step(1100)
        try f.step(1160)
        try f.step(1220)
        #expect(latchedAtEmit == "successful")
        let saved = try FileStore.readJSON(path)
        #expect(saved["handled"]?["user-session"]?["result_status"] == "successful")
        #expect(saved["handled"]?["user-session"]?["result_at"]?.number == 1220)
        let history = try History(directory: directory, clock: { 1300 })
        defer { history.close() }
        let reloaded = try RetryState(json: saved)
        try reconcileHistory(reloaded, history, now: 1300)
        try reconcileHistory(reloaded, history, now: 1300)
        let report = try History.report(directory: directory, now: 1300)
        #expect(report["successful"] == 1)
        #expect(report["awaiting"] == 0)
    }
}

// MARK: - CapacityClassificationTests

@Suite struct CoreCapacityClassificationTests {
    // test_structured_capacity_code_is_authoritative
    @Test func structuredCapacityCodeIsAuthoritative() {
        #expect(isCapacity(coreCapacityTurn(["error": [
            "codexErrorInfo": "serverOverloaded", "message": "Localized overload explanation",
        ]])))
    }

    // test_exact_text_fallback_accepts_optional_final_period
    @Test func exactTextFallbackAcceptsOptionalFinalPeriod() {
        for code: JSON in [nil, "other"] {
            for suffix in ["", "."] {
                #expect(isCapacity(coreCapacityTurn(["error": [
                    "codexErrorInfo": code, "message": .string(capacityMessage + suffix),
                ]])), "code \(code) suffix \(suffix)")
            }
        }
    }

    // test_noncapacity_codes_win_over_matching_text
    @Test func noncapacityCodesWinOverMatchingText() {
        let codes: [JSON] = ["usageLimitExceeded", "rateLimitExceeded", "unauthorized", "cyberPolicy",
                             "misalignmentPolicyViolation", ["httpConnectionFailed": ["httpStatusCode": 503]]]
        for code in codes {
            #expect(!isCapacity(coreCapacityTurn(["error": [
                "codexErrorInfo": code, "message": .string(capacityMessage),
            ]])), "code \(code)")
        }
    }

    // test_other_messages_and_nonfailed_turns_are_not_capacity
    @Test func otherMessagesAndNonfailedTurnsAreNotCapacity() {
        let turns: [JSON?] = [
            nil, [:], coreCapacityTurn(["status": "inProgress"]), coreCapacityTurn(["status": "interrupted"]),
            coreCapacityTurn(["error": nil]), coreCapacityTurn(["error": ["message": "capacity"]]),
            coreCapacityTurn(["error": ["message": .string("Log says: " + capacityMessage)]]),
        ]
        for turn in turns {
            #expect(!isCapacity(turn), "turn \(String(describing: turn))")
        }
    }
}
