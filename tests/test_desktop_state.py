"""Desktop state parsing uses synthetic snapshots and no live conversations."""

import copy
import json
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from desktop_state import CAPACITY_MESSAGE, DesktopStateError, normalize_snapshot


def fixture():
    turn = {
        "turnId": "failed-turn", "status": "failed",
        "error": {"codexErrorInfo": "serverOverloaded", "message": CAPACITY_MESSAGE + "."},
        "turnStartedAtMs": 1780000000000, "durationMs": 1000,
        "params": {"input": [{"type": "text", "text": "private prompt"}]},
        "items": [{"type": "agentMessage", "text": "private response"}],
    }
    state = {
        "id": "thread", "sessionId": "thread", "hostId": "local",
        "threadSource": "user", "parentThreadId": None, "ephemeral": False,
        "mode": "default", "resumeState": "resumed", "threadRuntimeStatus": {"type": "systemError"},
        "latestModel": "model", "latestReasoningEffort": "high",
        "latestCollaborationMode": {"mode": "default", "settings": {"model": "model"}},
        "latestThreadSettings": {"model": "model", "effort": "high", "serviceTier": None},
        "currentPermissions": {"approvalPolicy": "on-request", "sandboxPolicy": {"type": "workspaceWrite"}},
        "requests": [], "externalRequests": [], "unconfirmedTurnSubmissions": [], "turns": [],
        "turnHistory": {"kind": "canonical", "history": {
            "isComplete": True, "entitiesByKey": {"turn:failed-turn": turn},
            "islands": [{"id": "latest", "entries": [{"key": "entry", "value": "turn:failed-turn"}],
                         "olderBoundary": {"status": "exhausted"}, "newerBoundary": {"status": "exhausted"}}],
        }},
    }
    envelope = {"type": "broadcast", "method": "thread-stream-state-changed", "version": 11,
                "sourceClientId": "owner", "targetClientIds": ["client"], "params": {
                    "hostId": "local", "conversationId": "thread", "change": {
                        "type": "snapshot", "revision": 7, "conversationState": state}}}
    settings = {"settings": {"model": "model", "reasoningEffort": "high", "resumeState": "resumed",
                              "mode": "default", "threadSource": "user", "modelProvider": "openai"}}
    return envelope, settings


class DesktopStateTests(unittest.TestCase):
    def setUp(self):
        self.envelope, self.settings = fixture()
        self.state = self.envelope["params"]["change"]["conversationState"]
        self.history = self.state["turnHistory"]["history"]

    def view(self):
        return normalize_snapshot(self.envelope, "thread", "owner", "client", self.settings)

    def reject(self, code=None):
        with self.assertRaises(DesktopStateError) as caught:
            self.view()
        if code:
            self.assertEqual(caught.exception.code, code)
        self.assertNotIn("private", str(caught.exception))

    def test_capacity_snapshot_is_lightweight_and_has_no_invented_completion_time(self):
        view = self.view()
        self.assertEqual(view.revision, 7)
        self.assertEqual(view.owner, "owner")
        self.assertTrue(view.thread["canAcceptDirectInput"])
        self.assertEqual(view.thread["source"], "desktop")
        self.assertEqual(view.turn, {"id": "failed-turn", "status": "failed",
                                    "error": {"codexErrorInfo": "serverOverloaded", "message": CAPACITY_MESSAGE}})
        output = json.dumps({"thread": view.thread, "turn": view.turn})
        self.assertNotIn("private", output)
        self.assertNotIn("completedAt", output)
        self.assertNotIn("durationMs", output)
        self.assertEqual(len(view.settings_fingerprint), 64)

    def test_latest_island_and_entry_win_over_dictionary_insertion_order(self):
        self.history["entitiesByKey"]["turn:older"] = {"turnId": "older", "status": "failed", "error": {}}
        self.history["islands"].insert(0, {"id": "old", "entries": [{"key": "old", "value": "turn:older"}],
                                          "newerBoundary": {"status": "unknown"}})
        self.assertEqual(self.view().turn["id"], "failed-turn")
        self.history["entitiesByKey"]["turn:newest"] = {"turnId": "newest", "status": "completed"}
        self.history["islands"][-1]["entries"].append({"key": "new", "value": "turn:newest"})
        self.assertEqual(self.view().turn["id"], "newest")

    def test_missing_older_history_does_not_hide_an_authoritative_latest_turn(self):
        self.history["isComplete"] = False
        self.history["islands"][-1]["olderBoundary"] = {"status": "notLoaded"}
        self.assertEqual(self.view().turn["id"], "failed-turn")

    def test_latest_gap_or_malformed_canonical_history_never_falls_back_to_turns(self):
        original = copy.deepcopy(self.history)
        self.state["turns"] = [{"turnId": "wrong-fallback", "status": "failed"}]
        for history in [
            {}, {"islands": {}, "entitiesByKey": {}}, {"islands": [], "entitiesByKey": {"orphan": {}}},
            {**original, "islands": [{"entries": [], "newerBoundary": {"status": "notLoaded"}}]},
            {**original, "islands": [{"entries": [{"key": "x", "value": "missing"}], "newerBoundary": {"status": "exhausted"}}]},
            {**original, "islands": [{"entries": [{"value": "turn:failed-turn"}], "newerBoundary": {"status": "exhausted"}}]},
        ]:
            with self.subTest(history=history):
                self.state["turnHistory"]["history"] = history
                self.reject()
        self.state["turnHistory"] = {"kind": "legacy"}
        self.reject("unsupported-history")

    def test_empty_complete_history_returns_no_turn(self):
        self.history.update(islands=[], entitiesByKey={})
        self.assertIsNone(self.view().turn)

    def test_newer_local_placeholder_blocks_even_when_older_capacity_failure_exists(self):
        for status in ["inProgress", "failed"]:
            with self.subTest(status=status):
                self.history["entitiesByKey"]["turn:local"] = {"turnId": None, "status": status,
                    "params": {"clientUserMessageId": "private-local-message"}}
                self.history["islands"][-1]["entries"] = [
                    {"key": "failure", "value": "turn:failed-turn"}, {"key": "local", "value": "turn:local"}]
                view = self.view()
                self.assertFalse(view.thread["canAcceptDirectInput"])
                self.assertIsNone(view.turn["id"])
                self.assertNotEqual(view.turn["id"], "failed-turn")

    def test_untrusted_envelopes_are_rejected(self):
        for key, value in [
            ("type", "response"), ("method", "unexpected"), ("version", 12), ("version", True),
            ("sourceClientId", "another-owner"), ("targetClientIds", ["another-client"]),
            ("targetClientIds", "client"), ("targetClientIds", ["client", None]),
        ]:
            with self.subTest(key=key, value=value):
                self.envelope, self.settings = fixture()
                self.envelope[key] = value
                self.reject()

    def test_remote_or_mismatched_conversation_and_invalid_revision_are_rejected(self):
        mutations = [
            lambda e: e["params"].update(hostId="remote"),
            lambda e: e["params"].update(conversationId="wrong"),
            lambda e: e["params"]["change"].update(type="patches"),
            lambda e: e["params"]["change"].update(revision=True),
            lambda e: e["params"]["change"].update(revision=-1),
            lambda e: e["params"]["change"]["conversationState"].update(id="wrong"),
            lambda e: e["params"]["change"]["conversationState"].update(sessionId="wrong"),
            lambda e: e["params"]["change"]["conversationState"].update(hostId="remote"),
        ]
        for mutate in mutations:
            self.envelope, self.settings = fixture()
            mutate(self.envelope)
            self.reject()

    def test_active_approval_and_unknown_runtime_states_block(self):
        for runtime in [None, {}, {"type": "notLoaded"}, {"type": "futureState"},
                        {"type": "idle", "activeFlags": "unknown"},
                        {"type": "idle", "activeFlags": [None]},
                        {"type": "active"},
                        {"type": "active", "activeFlags": ["waitingOnApproval"]},
                        {"type": "idle", "activeFlags": ["waitingOnApproval"]}]:
            with self.subTest(runtime=runtime):
                self.state["threadRuntimeStatus"] = runtime
                self.assertFalse(self.view().thread["canAcceptDirectInput"])

    def test_known_active_runtime_preserves_capability_for_recovery_observation(self):
        self.state["threadRuntimeStatus"] = {"type": "active", "activeFlags": []}
        self.history["entitiesByKey"]["turn:failed-turn"].update(status="inProgress", error=None)
        view = self.view()
        self.assertTrue(view.thread["canAcceptDirectInput"])
        self.assertEqual(view.thread["status"], {"type": "active", "activeFlags": []})
        self.assertEqual(view.blocked_reason, "active")

    def test_in_progress_turn_with_idle_runtime_is_not_retryable(self):
        self.state["threadRuntimeStatus"] = {"type": "idle"}
        self.history["entitiesByKey"]["turn:failed-turn"].update(status="inProgress", error=None)
        view = self.view()
        self.assertFalse(view.thread["canAcceptDirectInput"])
        self.assertEqual(view.blocked_reason, "inconsistent-runtime")

    def test_pending_requests_and_unconfirmed_submissions_block(self):
        for name in ["requests", "externalRequests", "unconfirmedTurnSubmissions"]:
            for value in [[{"private": "approval text"}], {}, True, None]:
                with self.subTest(name=name, value=value):
                    self.envelope, self.settings = fixture()
                    self.state = self.envelope["params"]["change"]["conversationState"]
                    self.state[name] = value
                    self.assertFalse(self.view().thread["canAcceptDirectInput"])
        self.envelope, self.settings = fixture()
        self.state = self.envelope["params"]["change"]["conversationState"]
        del self.state["requests"]
        self.assertFalse(self.view().thread["canAcceptDirectInput"])

    def test_optional_absent_pending_fields_are_supported(self):
        del self.state["externalRequests"]
        del self.state["unconfirmedTurnSubmissions"]
        self.assertTrue(self.view().thread["canAcceptDirectInput"])

    def test_resume_and_non_user_states_block(self):
        for state_changes, model_changes in [
            ({"resumeState": "resuming"}, {"resumeState": "resuming"}),
            ({"threadSource": "subAgent"}, {"threadSource": "subAgent"}),
            ({"parentThreadId": "parent"}, {}), ({"ephemeral": True}, {}), ({"ephemeral": None}, {}),
        ]:
            with self.subTest(state_changes=state_changes):
                self.envelope, self.settings = fixture()
                state = self.envelope["params"]["change"]["conversationState"]
                state.update(state_changes)
                self.settings["settings"].update(model_changes)
                self.assertFalse(self.view().thread["canAcceptDirectInput"])

    def test_model_resolution_matches_collaboration_precedence_and_null_fallback(self):
        self.state["latestModel"] = "stale-model"
        self.assertEqual(self.view().thread["model"], "model")
        self.state["latestCollaborationMode"]["settings"]["model"] = None
        self.settings["settings"]["model"] = "stale-model"
        self.assertEqual(self.view().thread["model"], "stale-model")
        self.state["latestReasoningEffort"] = None
        self.settings["settings"]["reasoningEffort"] = None
        self.assertIsNone(self.view().thread["reasoningEffort"])

    def test_model_settings_mismatch_or_invalid_shapes_are_rejected(self):
        for key, value in [("model", "changed"), ("reasoningEffort", "low"),
                           ("resumeState", "resuming"), ("threadSource", "subAgent"), ("mode", "plan")]:
            self.envelope, self.settings = fixture()
            self.settings["settings"][key] = value
            self.reject("settings-mismatch")
        for value in [None, {}, {"settings": None}, {"settings": {}}, {"settings": {"model": True}}]:
            self.settings = value
            self.reject()

    def test_settings_fingerprint_changes_for_policy_tier_model_and_mode(self):
        before = self.view().settings_fingerprint
        for mutate in [
            lambda state, settings: state["currentPermissions"].update(approvalPolicy="never"),
            lambda state, settings: state["latestThreadSettings"].update(serviceTier="fast"),
            lambda state, settings: state["latestThreadSettings"].update(cwd="/private/path"),
            lambda state, settings: settings["settings"].update(modelProvider="another-provider"),
        ]:
            self.envelope, self.settings = fixture()
            self.state = self.envelope["params"]["change"]["conversationState"]
            mutate(self.state, self.settings)
            view = self.view()
            self.assertNotEqual(view.settings_fingerprint, before)
            self.assertNotIn("/private/path", json.dumps(view.thread))

    def test_saved_inheritance_model_effort_and_collaboration_mismatches_hold(self):
        for change in [
            {"model": "stale-private-model"},
            {"effort": "low"}, {"effort": None},
            {"collaborationMode": {"mode": "default", "settings": {"model": "stale-private-model"}}},
            {"collaborationMode": {"mode": "plan", "settings": {"model": "model"}}},
            {"collaborationMode": {"mode": "default", "settings": {"model": "model", "reasoning_effort": "low"}}},
            {"collaborationMode": "unsupported"},
        ]:
            with self.subTest(change=change):
                self.envelope, self.settings = fixture()
                self.state = self.envelope["params"]["change"]["conversationState"]
                self.state["latestThreadSettings"].update(change)
                view = self.view()
                self.assertFalse(view.thread["canAcceptDirectInput"])
                self.assertEqual(view.blocked_reason, "inheritance-mismatch")
                self.assertNotIn("stale-private-model", json.dumps(view.thread))

    def test_inheritance_null_and_absent_fallbacks_keep_coherent_selection_ready(self):
        for remove, replace in [
            (["model"], {}), ([], {"model": None}),
            (["effort"], {}), ([], {"collaborationMode": None}),
            (["model", "effort", "collaborationMode"], {}),
        ]:
            with self.subTest(remove=remove, replace=replace):
                self.envelope, self.settings = fixture()
                self.state = self.envelope["params"]["change"]["conversationState"]
                saved = self.state["latestThreadSettings"]
                for name in remove:
                    saved.pop(name, None)
                saved.update(replace)
                self.assertTrue(self.view().thread["canAcceptDirectInput"])
        # The current collaboration may select a model over an older raw fallback.
        self.state["latestModel"] = "unselected-fallback"
        self.state["latestThreadSettings"]["model"] = None
        self.assertTrue(self.view().thread["canAcceptDirectInput"])

    def test_coherent_saved_collaboration_and_explicit_null_effort_are_supported(self):
        collaboration = self.state["latestCollaborationMode"]
        collaboration["settings"].update(reasoning_effort="high", developer_instructions=None)
        self.state["latestThreadSettings"]["collaborationMode"] = copy.deepcopy(collaboration)
        self.assertTrue(self.view().thread["canAcceptDirectInput"])
        self.state["latestReasoningEffort"] = None
        self.settings["settings"]["reasoningEffort"] = None
        self.state["latestThreadSettings"]["effort"] = None
        collaboration["settings"]["reasoning_effort"] = None
        self.state["latestThreadSettings"]["collaborationMode"] = copy.deepcopy(collaboration)
        self.assertTrue(self.view().thread["canAcceptDirectInput"])
        self.state["latestCollaborationMode"] = None
        self.state["latestThreadSettings"].pop("collaborationMode")
        self.assertTrue(self.view().thread["canAcceptDirectInput"])

    def test_defined_collaboration_effort_is_ambiguous_when_it_disagrees_with_resolved_effort(self):
        for effort in [None, "low"]:
            with self.subTest(effort=effort):
                self.state["latestCollaborationMode"]["settings"]["reasoning_effort"] = effort
                self.state["latestThreadSettings"]["collaborationMode"] = copy.deepcopy(self.state["latestCollaborationMode"])
                view = self.view()
                self.assertFalse(view.thread["canAcceptDirectInput"])
                self.assertEqual(view.blocked_reason, "inheritance-mismatch")

    def test_saved_permission_mismatch_holds_but_matching_or_absent_fields_do_not(self):
        saved = self.state["latestThreadSettings"]
        permissions = self.state["currentPermissions"]
        saved.update(copy.deepcopy(permissions))
        self.assertTrue(self.view().thread["canAcceptDirectInput"])
        for name, value in [("approvalPolicy", "never"), ("approvalPolicy", None),
                            ("sandboxPolicy", {"type": "dangerFullAccess"})]:
            with self.subTest(name=name, value=value):
                original = copy.deepcopy(saved[name])
                saved[name] = value
                view = self.view()
                self.assertFalse(view.thread["canAcceptDirectInput"])
                self.assertEqual(view.blocked_reason, "inheritance-mismatch")
                saved[name] = original
        del permissions["approvalPolicy"]
        saved["approvalPolicy"] = "on-request"
        self.assertTrue(self.view().thread["canAcceptDirectInput"])

    def test_server_error_details_and_arbitrary_messages_are_not_exported(self):
        turn = self.history["entitiesByKey"]["turn:failed-turn"]
        turn["error"] = {"codexErrorInfo": "usageLimitExceeded", "message": "private account information",
                         "additionalDetails": "private operation", "misalignment": {"private": "value"}}
        self.assertEqual(self.view().turn["error"], {"codexErrorInfo": "usageLimitExceeded", "message": ""})
        for info in ["unauthorized", {"private": "details"}, ["unexpected"], True]:
            turn["error"] = {"codexErrorInfo": info, "message": CAPACITY_MESSAGE}
            self.assertEqual(self.view().turn["error"]["codexErrorInfo"], "unsupported")
        for info in [None, "other"]:
            turn["error"] = {"codexErrorInfo": info, "message": CAPACITY_MESSAGE}
            self.assertEqual(self.view().turn["error"]["message"], CAPACITY_MESSAGE)

    def test_invalid_turn_or_non_json_settings_fail_without_payload_text(self):
        turn = self.history["entitiesByKey"]["turn:failed-turn"]
        for update in [{"turnId": 123}, {"status": "private-new-status"}, {"error": "private error"}]:
            original = copy.deepcopy(turn)
            turn.update(update)
            self.reject()
            turn.clear()
            turn.update(original)
        self.state["latestThreadSettings"]["value"] = float("nan")
        self.reject("invalid-model-settings")


if __name__ == "__main__":
    unittest.main()
