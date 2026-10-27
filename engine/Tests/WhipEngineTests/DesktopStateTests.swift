// Port of tests/test_desktop_state.py.
// Desktop state parsing uses synthetic snapshots and no live conversations.

import Foundation
import Testing
@testable import WhipEngine

private struct StateFixture {
    var envelope: JSON
    var settings: JSON

    init() {
        let turn: JSON = [
            "turnId": "failed-turn", "status": "failed",
            "error": ["codexErrorInfo": "serverOverloaded", "message": .string(capacityMessage + ".")],
            "turnStartedAtMs": 1780000000000, "durationMs": 1000,
            "params": ["input": [["type": "text", "text": "private prompt"]]],
            "items": [["type": "agentMessage", "text": "private response"]],
        ]
        let state: JSON = [
            "id": "thread", "sessionId": "thread", "hostId": "local",
            "threadSource": "user", "parentThreadId": .null, "ephemeral": false,
            "mode": "default", "resumeState": "resumed", "threadRuntimeStatus": ["type": "systemError"],
            "latestModel": "model", "latestReasoningEffort": "high",
            "latestCollaborationMode": ["mode": "default", "settings": ["model": "model"]],
            "latestThreadSettings": ["model": "model", "effort": "high", "serviceTier": .null],
            "currentPermissions": ["approvalPolicy": "on-request", "sandboxPolicy": ["type": "workspaceWrite"]],
            "requests": [], "externalRequests": [], "unconfirmedTurnSubmissions": [], "turns": [],
            "turnHistory": ["kind": "canonical", "history": [
                "isComplete": true, "entitiesByKey": ["turn:failed-turn": turn],
                "islands": [["id": "latest", "entries": [["key": "entry", "value": "turn:failed-turn"]],
                             "olderBoundary": ["status": "exhausted"], "newerBoundary": ["status": "exhausted"]]],
            ]],
        ]
        envelope = ["type": "broadcast", "method": "thread-stream-state-changed", "version": 11,
                    "sourceClientId": "owner", "targetClientIds": ["client"], "params": [
                        "hostId": "local", "conversationId": "thread", "change": [
                            "type": "snapshot", "revision": 7, "conversationState": state]]]
        settings = ["settings": ["model": "model", "reasoningEffort": "high", "resumeState": "resumed",
                                 "mode": "default", "threadSource": "user", "modelProvider": "openai"]]
    }

    var state: JSON {
        get { envelope["params"]!["change"]!["conversationState"]! }
        set { envelope["params"]?["change"]?["conversationState"] = newValue }
    }

    var history: JSON {
        get { state["turnHistory"]!["history"]! }
        set { state["turnHistory"]?["history"] = newValue }
    }

    var failedTurn: JSON {
        get { history["entitiesByKey"]!["turn:failed-turn"]! }
        set { history["entitiesByKey"]?["turn:failed-turn"] = newValue }
    }

    var islands: [JSON] {
        get { history["islands"]!.array! }
        set { history["islands"] = .array(newValue) }
    }

    func view() throws -> DesktopView {
        try DesktopState.normalize(envelope, conversationID: "thread", ownerID: "owner", clientID: "client",
                                   modelSettings: settings)
    }

    func reject(_ code: String? = nil, sourceLocation: SourceLocation = #_sourceLocation) {
        do {
            _ = try view()
            Issue.record("Expected DesktopStateError", sourceLocation: sourceLocation)
        } catch let error as DesktopStateError {
            if let code { #expect(error.code == code, sourceLocation: sourceLocation) }
            #expect(!String(describing: error).contains("private"), sourceLocation: sourceLocation)
        } catch {
            Issue.record("Unexpected error \(error)", sourceLocation: sourceLocation)
        }
    }
}

private func merged(_ base: JSON, _ changes: [String: JSON]) -> JSON {
    var result = base
    for (key, value) in changes { result[key] = value }
    return result
}

private func dumps(_ value: JSON) throws -> String {
    try value.serialized(.ascii)
}

struct DesktopStateTests {
    // test_capacity_snapshot_is_lightweight_and_has_no_invented_completion_time
    @Test func capacitySnapshotIsLightweightAndHasNoInventedCompletionTime() throws {
        let view = try StateFixture().view()
        #expect(view.revision == 7)
        #expect(view.owner == "owner")
        #expect(view.thread["canAcceptDirectInput"] == true)
        #expect(view.thread["source"] == "desktop")
        #expect(view.turn == ["id": "failed-turn", "status": "failed",
                              "error": ["codexErrorInfo": "serverOverloaded", "message": .string(capacityMessage)]])
        let output = try dumps(["thread": view.thread, "turn": view.turn ?? .null])
        #expect(!output.contains("private"))
        #expect(!output.contains("completedAt"))
        #expect(!output.contains("durationMs"))
        #expect(view.settingsFingerprint.count == 64)
    }

    // test_latest_island_and_entry_win_over_dictionary_insertion_order
    @Test func latestIslandAndEntryWinOverDictionaryInsertionOrder() throws {
        var f = StateFixture()
        f.history["entitiesByKey"]?["turn:older"] = ["turnId": "older", "status": "failed", "error": [:]]
        f.islands.insert(["id": "old", "entries": [["key": "old", "value": "turn:older"]],
                          "newerBoundary": ["status": "unknown"]], at: 0)
        #expect(try f.view().turn?["id"] == "failed-turn")
        f.history["entitiesByKey"]?["turn:newest"] = ["turnId": "newest", "status": "completed"]
        var islands = f.islands
        var entries = islands[islands.count - 1]["entries"]!.array!
        entries.append(["key": "new", "value": "turn:newest"])
        islands[islands.count - 1]["entries"] = .array(entries)
        f.islands = islands
        #expect(try f.view().turn?["id"] == "newest")
    }

    // test_missing_older_history_does_not_hide_an_authoritative_latest_turn
    @Test func missingOlderHistoryDoesNotHideAnAuthoritativeLatestTurn() throws {
        var f = StateFixture()
        f.history["isComplete"] = false
        var islands = f.islands
        islands[islands.count - 1]["olderBoundary"] = ["status": "notLoaded"]
        f.islands = islands
        #expect(try f.view().turn?["id"] == "failed-turn")
    }

    // test_latest_gap_or_malformed_canonical_history_never_falls_back_to_turns
    @Test func latestGapOrMalformedCanonicalHistoryNeverFallsBackToTurns() {
        var f = StateFixture()
        let original = f.history
        f.state["turns"] = [["turnId": "wrong-fallback", "status": "failed"]]
        let histories: [JSON] = [
            [:], ["islands": [:], "entitiesByKey": [:]], ["islands": [], "entitiesByKey": ["orphan": [:]]],
            merged(original, ["islands": [["entries": [], "newerBoundary": ["status": "notLoaded"]]]]),
            merged(original, ["islands": [["entries": [["key": "x", "value": "missing"]],
                                           "newerBoundary": ["status": "exhausted"]]]]),
            merged(original, ["islands": [["entries": [["value": "turn:failed-turn"]],
                                           "newerBoundary": ["status": "exhausted"]]]]),
        ]
        for history in histories {
            f.history = history
            f.reject()
        }
        f.state["turnHistory"] = ["kind": "legacy"]
        f.reject("unsupported-history")
    }

    // test_empty_complete_history_returns_no_turn
    @Test func emptyCompleteHistoryReturnsNoTurn() throws {
        var f = StateFixture()
        f.history["islands"] = []
        f.history["entitiesByKey"] = [:]
        #expect(try f.view().turn == nil)
    }

    // test_newer_local_placeholder_blocks_even_when_older_capacity_failure_exists
    @Test(arguments: ["inProgress", "failed"])
    func newerLocalPlaceholderBlocksEvenWhenOlderCapacityFailureExists(status: String) throws {
        var f = StateFixture()
        f.history["entitiesByKey"]?["turn:local"] = ["turnId": .null, "status": .string(status),
                                                     "params": ["clientUserMessageId": "private-local-message"]]
        var islands = f.islands
        islands[islands.count - 1]["entries"] = [["key": "failure", "value": "turn:failed-turn"],
                                                 ["key": "local", "value": "turn:local"]]
        f.islands = islands
        let view = try f.view()
        #expect(view.thread["canAcceptDirectInput"] == false)
        let turn = try #require(view.turn)
        #expect(turn["id"] == .null)
        #expect(turn["id"] != "failed-turn")
    }

    // test_untrusted_envelopes_are_rejected
    @Test(arguments: [
        ("type", "response"), ("method", "unexpected"), ("version", 12), ("version", true),
        ("sourceClientId", "another-owner"), ("targetClientIds", ["another-client"]),
        ("targetClientIds", "client"), ("targetClientIds", ["client", .null]),
    ] as [(String, JSON)])
    func untrustedEnvelopesAreRejected(key: String, value: JSON) {
        var f = StateFixture()
        f.envelope[key] = value
        f.reject()
    }

    // test_remote_or_mismatched_conversation_and_invalid_revision_are_rejected
    @Test func remoteOrMismatchedConversationAndInvalidRevisionAreRejected() {
        let mutations: [(inout StateFixture) -> Void] = [
            { $0.envelope["params"]?["hostId"] = "remote" },
            { $0.envelope["params"]?["conversationId"] = "wrong" },
            { $0.envelope["params"]?["change"]?["type"] = "patches" },
            { $0.envelope["params"]?["change"]?["revision"] = true },
            { $0.envelope["params"]?["change"]?["revision"] = -1 },
            { $0.state["id"] = "wrong" },
            { $0.state["sessionId"] = "wrong" },
            { $0.state["hostId"] = "remote" },
        ]
        for mutate in mutations {
            var f = StateFixture()
            mutate(&f)
            f.reject()
        }
    }

    // test_active_approval_and_unknown_runtime_states_block
    @Test(arguments: [
        .null, [:], ["type": "notLoaded"], ["type": "futureState"],
        ["type": "idle", "activeFlags": "unknown"],
        ["type": "idle", "activeFlags": [.null]],
        ["type": "active"],
        ["type": "active", "activeFlags": ["waitingOnApproval"]],
        ["type": "idle", "activeFlags": ["waitingOnApproval"]],
    ] as [JSON])
    func activeApprovalAndUnknownRuntimeStatesBlock(runtime: JSON) throws {
        var f = StateFixture()
        f.state["threadRuntimeStatus"] = runtime
        #expect(try f.view().thread["canAcceptDirectInput"] == false)
    }

    // test_known_active_runtime_preserves_capability_for_recovery_observation
    @Test func knownActiveRuntimePreservesCapabilityForRecoveryObservation() throws {
        var f = StateFixture()
        f.state["threadRuntimeStatus"] = ["type": "active", "activeFlags": []]
        f.failedTurn["status"] = "inProgress"
        f.failedTurn["error"] = .null
        let view = try f.view()
        #expect(view.thread["canAcceptDirectInput"] == true)
        #expect(view.thread["status"] == ["type": "active", "activeFlags": []])
        #expect(view.blockedReason == "active")
    }

    // test_in_progress_turn_with_idle_runtime_is_not_retryable
    @Test func inProgressTurnWithIdleRuntimeIsNotRetryable() throws {
        var f = StateFixture()
        f.state["threadRuntimeStatus"] = ["type": "idle"]
        f.failedTurn["status"] = "inProgress"
        f.failedTurn["error"] = .null
        let view = try f.view()
        #expect(view.thread["canAcceptDirectInput"] == false)
        #expect(view.blockedReason == "inconsistent-runtime")
    }

    // test_pending_requests_and_unconfirmed_submissions_block
    @Test func pendingRequestsAndUnconfirmedSubmissionsBlock() throws {
        for name in ["requests", "externalRequests", "unconfirmedTurnSubmissions"] {
            for value: JSON in [[["private": "approval text"]], [:], true, .null] {
                var f = StateFixture()
                f.state[name] = value
                #expect(try f.view().thread["canAcceptDirectInput"] == false, "\(name) = \(value)")
            }
        }
        var f = StateFixture()
        f.state["requests"] = nil
        #expect(try f.view().thread["canAcceptDirectInput"] == false)
    }

    // test_optional_absent_pending_fields_are_supported
    @Test func optionalAbsentPendingFieldsAreSupported() throws {
        var f = StateFixture()
        f.state["externalRequests"] = nil
        f.state["unconfirmedTurnSubmissions"] = nil
        #expect(try f.view().thread["canAcceptDirectInput"] == true)
    }

    // test_resume_and_non_user_states_block
    @Test(arguments: [
        (["resumeState": "resuming"], ["resumeState": "resuming"]),
        (["threadSource": "subAgent"], ["threadSource": "subAgent"]),
        (["parentThreadId": "parent"], [:]), (["ephemeral": true], [:]), (["ephemeral": .null], [:]),
    ] as [([String: JSON], [String: JSON])])
    func resumeAndNonUserStatesBlock(stateChanges: [String: JSON], modelChanges: [String: JSON]) throws {
        var f = StateFixture()
        for (key, value) in stateChanges { f.state[key] = value }
        for (key, value) in modelChanges { f.settings["settings"]?[key] = value }
        #expect(try f.view().thread["canAcceptDirectInput"] == false)
    }

    // test_model_resolution_matches_collaboration_precedence_and_null_fallback
    @Test func modelResolutionMatchesCollaborationPrecedenceAndNullFallback() throws {
        var f = StateFixture()
        f.state["latestModel"] = "stale-model"
        #expect(try f.view().thread["model"] == "model")
        f.state["latestCollaborationMode"]?["settings"]?["model"] = .null
        f.settings["settings"]?["model"] = "stale-model"
        #expect(try f.view().thread["model"] == "stale-model")
        f.state["latestReasoningEffort"] = .null
        f.settings["settings"]?["reasoningEffort"] = .null
        #expect(try f.view().thread["reasoningEffort"] == .null)
    }

    // test_model_settings_mismatch_or_invalid_shapes_are_rejected
    @Test func modelSettingsMismatchOrInvalidShapesAreRejected() {
        let mismatches: [(String, JSON)] = [("model", "changed"), ("reasoningEffort", "low"),
                                            ("resumeState", "resuming"), ("threadSource", "subAgent"), ("mode", "plan")]
        for (key, value) in mismatches {
            var f = StateFixture()
            f.settings["settings"]?[key] = value
            f.reject("settings-mismatch")
        }
        var f = StateFixture()
        for value: JSON in [.null, [:], ["settings": .null], ["settings": [:]], ["settings": ["model": true]]] {
            f.settings = value
            f.reject()
        }
    }

    // test_settings_fingerprint_changes_for_policy_tier_model_and_mode
    @Test func settingsFingerprintChangesForPolicyTierModelAndMode() throws {
        let before = try StateFixture().view().settingsFingerprint
        let mutations: [(inout StateFixture) -> Void] = [
            { $0.state["currentPermissions"]?["approvalPolicy"] = "never" },
            { $0.state["latestThreadSettings"]?["serviceTier"] = "fast" },
            { $0.state["latestThreadSettings"]?["cwd"] = "/private/path" },
            { $0.settings["settings"]?["modelProvider"] = "another-provider" },
        ]
        for mutate in mutations {
            var f = StateFixture()
            mutate(&f)
            let view = try f.view()
            #expect(view.settingsFingerprint != before)
            #expect(!(try dumps(view.thread)).contains("/private/path"))
        }
    }

    // test_saved_inheritance_model_effort_and_collaboration_mismatches_hold
    @Test(arguments: [
        ["model": "stale-private-model"],
        ["effort": "low"], ["effort": .null],
        ["collaborationMode": ["mode": "default", "settings": ["model": "stale-private-model"]]],
        ["collaborationMode": ["mode": "plan", "settings": ["model": "model"]]],
        ["collaborationMode": ["mode": "default", "settings": ["model": "model", "reasoning_effort": "low"]]],
        ["collaborationMode": "unsupported"],
    ] as [[String: JSON]])
    func savedInheritanceModelEffortAndCollaborationMismatchesHold(change: [String: JSON]) throws {
        var f = StateFixture()
        for (key, value) in change { f.state["latestThreadSettings"]?[key] = value }
        let view = try f.view()
        #expect(view.thread["canAcceptDirectInput"] == false)
        #expect(view.blockedReason == "inheritance-mismatch")
        #expect(!(try dumps(view.thread)).contains("stale-private-model"))
    }

    // test_inheritance_null_and_absent_fallbacks_keep_coherent_selection_ready
    @Test func inheritanceNullAndAbsentFallbacksKeepCoherentSelectionReady() throws {
        let cases: [([String], [String: JSON])] = [
            (["model"], [:]), ([], ["model": .null]),
            (["effort"], [:]), ([], ["collaborationMode": .null]),
            (["model", "effort", "collaborationMode"], [:]),
        ]
        var f = StateFixture()
        for (remove, replace) in cases {
            f = StateFixture()
            for name in remove { f.state["latestThreadSettings"]?[name] = nil }
            for (key, value) in replace { f.state["latestThreadSettings"]?[key] = value }
            #expect(try f.view().thread["canAcceptDirectInput"] == true, "remove \(remove), replace \(replace)")
        }
        // The current collaboration may select a model over an older raw fallback.
        f.state["latestModel"] = "unselected-fallback"
        f.state["latestThreadSettings"]?["model"] = .null
        #expect(try f.view().thread["canAcceptDirectInput"] == true)
    }

    // test_coherent_saved_collaboration_and_explicit_null_effort_are_supported
    @Test func coherentSavedCollaborationAndExplicitNullEffortAreSupported() throws {
        var f = StateFixture()
        f.state["latestCollaborationMode"]?["settings"]?["reasoning_effort"] = "high"
        f.state["latestCollaborationMode"]?["settings"]?["developer_instructions"] = .null
        let collaboration = f.state["latestCollaborationMode"]!
        f.state["latestThreadSettings"]?["collaborationMode"] = collaboration
        #expect(try f.view().thread["canAcceptDirectInput"] == true)
        f.state["latestReasoningEffort"] = .null
        f.settings["settings"]?["reasoningEffort"] = .null
        f.state["latestThreadSettings"]?["effort"] = .null
        f.state["latestCollaborationMode"]?["settings"]?["reasoning_effort"] = .null
        let cleared = f.state["latestCollaborationMode"]!
        f.state["latestThreadSettings"]?["collaborationMode"] = cleared
        #expect(try f.view().thread["canAcceptDirectInput"] == true)
        f.state["latestCollaborationMode"] = .null
        f.state["latestThreadSettings"]?["collaborationMode"] = nil
        #expect(try f.view().thread["canAcceptDirectInput"] == true)
    }

    // test_defined_collaboration_effort_is_ambiguous_when_it_disagrees_with_resolved_effort
    @Test func definedCollaborationEffortIsAmbiguousWhenItDisagreesWithResolvedEffort() throws {
        var f = StateFixture()
        for effort: JSON in [.null, "low"] {
            f.state["latestCollaborationMode"]?["settings"]?["reasoning_effort"] = effort
            let collaboration = f.state["latestCollaborationMode"]!
            f.state["latestThreadSettings"]?["collaborationMode"] = collaboration
            let view = try f.view()
            #expect(view.thread["canAcceptDirectInput"] == false, "effort \(effort)")
            #expect(view.blockedReason == "inheritance-mismatch", "effort \(effort)")
        }
    }

    // test_saved_permission_mismatch_holds_but_matching_or_absent_fields_do_not
    @Test func savedPermissionMismatchHoldsButMatchingOrAbsentFieldsDoNot() throws {
        var f = StateFixture()
        for (key, value) in f.state["currentPermissions"]!.object! {
            f.state["latestThreadSettings"]?[key] = value
        }
        #expect(try f.view().thread["canAcceptDirectInput"] == true)
        let mismatches: [(String, JSON)] = [("approvalPolicy", "never"), ("approvalPolicy", .null),
                                            ("sandboxPolicy", ["type": "dangerFullAccess"])]
        for (name, value) in mismatches {
            let original = f.state["latestThreadSettings"]![name]!
            f.state["latestThreadSettings"]?[name] = value
            let view = try f.view()
            #expect(view.thread["canAcceptDirectInput"] == false, "\(name) = \(value)")
            #expect(view.blockedReason == "inheritance-mismatch", "\(name) = \(value)")
            f.state["latestThreadSettings"]?[name] = original
        }
        f.state["currentPermissions"]?["approvalPolicy"] = nil
        f.state["latestThreadSettings"]?["approvalPolicy"] = "on-request"
        #expect(try f.view().thread["canAcceptDirectInput"] == true)
    }

    // test_server_error_details_and_arbitrary_messages_are_not_exported
    @Test func serverErrorDetailsAndArbitraryMessagesAreNotExported() throws {
        var f = StateFixture()
        f.failedTurn["error"] = ["codexErrorInfo": "usageLimitExceeded", "message": "private account information",
                                 "additionalDetails": "private operation", "misalignment": ["private": "value"]]
        #expect(try f.view().turn?["error"] == ["codexErrorInfo": "usageLimitExceeded", "message": ""])
        for info: JSON in ["unauthorized", ["private": "details"], ["unexpected"], true] {
            f.failedTurn["error"] = ["codexErrorInfo": info, "message": .string(capacityMessage)]
            #expect(try f.view().turn?["error"]?["codexErrorInfo"] == "unsupported")
        }
        for info: JSON in [.null, "other"] {
            f.failedTurn["error"] = ["codexErrorInfo": info, "message": .string(capacityMessage)]
            #expect(try f.view().turn?["error"]?["message"] == .string(capacityMessage))
        }
    }

    // test_invalid_turn_or_non_json_settings_fail_without_payload_text
    @Test func invalidTurnOrNonJSONSettingsFailWithoutPayloadText() {
        var f = StateFixture()
        let updates: [(String, JSON)] = [("turnId", 123), ("status", "private-new-status"), ("error", "private error")]
        for (key, value) in updates {
            let original = f.failedTurn
            f.failedTurn[key] = value
            f.reject()
            f.failedTurn = original
        }
        f.state["latestThreadSettings"]?["value"] = .double(.nan)
        f.reject("invalid-model-settings")
    }
}
