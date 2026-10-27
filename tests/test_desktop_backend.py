"""Desktop retry integration uses synthetic state and in-memory protocol peers."""

import copy
from pathlib import Path
import sys
import unittest
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import codex_whip as core
from desktop_backend import DesktopNoOwner, DesktopRPC
from desktop_ipc import DesktopIPCError
from test_desktop_state import fixture


class MetadataPeer:
    def __init__(self):
        self.calls = []
        self.turns = [{"id": "failed-turn", "status": "failed", "completedAt": 1100,
                       "error": {"codexErrorInfo": "serverOverloaded", "message": core.CAPACITY_MESSAGE}}]
        self.error = None

    def call(self, method, params):
        self.calls.append((method, copy.deepcopy(params)))
        if method != "thread/turns/list":
            raise AssertionError("Metadata must never start, resume, or authorize a turn")
        if self.error:
            raise self.error
        return {"data": copy.deepcopy(self.turns[:params["limit"]]), "nextCursor": None}


class DesktopPeer:
    def __init__(self):
        self.snapshot, self.model = fixture()
        self.owner = "owner"
        self.owner_error = None
        self.owner_result = {"supportsUntrustedAppInput": True}
        self.start_error = None
        self.ack = {"result": {"turn": {"id": "retry-turn", "status": "inProgress"}}}
        self.connections = []
        self.starts = []
        self.before_start = None
        self.before_snapshot = None

    @property
    def state(self):
        return self.snapshot["params"]["change"]["conversationState"]

    @property
    def turn(self):
        history = self.state["turnHistory"]["history"]
        key = history["islands"][-1]["entries"][-1]["value"]
        return history["entitiesByKey"][key]

    def set_model(self, model):
        self.state["latestModel"] = model
        self.state["latestCollaborationMode"]["settings"]["model"] = model
        self.state["latestThreadSettings"]["model"] = model
        self.model["settings"]["model"] = model

    def set_turn(self, turn_id, status, error=None):
        self.turn.update(turnId=turn_id, status=status, error=error)

    def __call__(self, _path, timeout, should_stop):
        connection = DesktopConnection(self, "client-" + str(len(self.connections) + 1))
        self.connections.append(connection)
        return connection


class DesktopConnection:
    def __init__(self, peer, client_id):
        self.peer, self.client_id = peer, client_id
        self.closed = False
        self.calls, self.follows = [], []

    def request_full(self, method, params, **kwargs):
        self.calls.append((method, copy.deepcopy(params), copy.deepcopy(kwargs)))
        if method != "thread-owner-discovery":
            raise AssertionError("Unexpected full Desktop request")
        if self.peer.owner_error:
            raise self.peer.owner_error
        return {"handledByClientId": self.peer.owner, "result": copy.deepcopy(self.peer.owner_result)}

    def request(self, method, params, **kwargs):
        self.calls.append((method, copy.deepcopy(params), copy.deepcopy(kwargs)))
        if kwargs.get("target") != self.peer.owner:
            raise AssertionError("Desktop requests must target the discovered owner")
        if method == "thread-follower-read-model-settings":
            return copy.deepcopy(self.peer.model)
        if method == "thread-follower-start-turn":
            self.peer.starts.append((copy.deepcopy(params), copy.deepcopy(kwargs)))
            if self.peer.before_start:
                self.peer.before_start(params)
            if self.peer.start_error:
                raise self.peer.start_error
            return copy.deepcopy(self.peer.ack)
        raise AssertionError("Unexpected Desktop request")

    def broadcast(self, method, params, **kwargs):
        self.calls.append((method, copy.deepcopy(params), copy.deepcopy(kwargs)))
        if method != "thread-stream-following-changed":
            raise AssertionError("Unexpected Desktop broadcast")
        self.follows.append(params["following"])

    def wait_broadcast(self, predicate, timeout):
        if self.peer.before_snapshot:
            self.peer.before_snapshot()
        envelope = copy.deepcopy(self.peer.snapshot)
        envelope["sourceClientId"] = self.peer.owner
        envelope["targetClientIds"] = [self.client_id]
        if not predicate(envelope):
            raise AssertionError("The fixture should match this snapshot read")
        return envelope

    def close(self):
        self.closed = True

    def __enter__(self):
        return self

    def __exit__(self, *_args):
        self.close()


class DesktopBackendTests(unittest.TestCase):
    def setUp(self):
        self.metadata, self.desktop = MetadataPeer(), DesktopPeer()
        self.backend = DesktopRPC("unused.sock", self.metadata, ["thread"], ipc_factory=self.desktop)
        self.state, self.saved, self.events = {"enabled_at": 1000}, [], []
        self.on_write_ahead = None
        self.engine = self.new_engine()

    def save(self, state):
        self.saved.append(copy.deepcopy(state))
        attempt = state.get("handled", {}).get("thread", {})
        if attempt.get("outcome") == "uncertain" and self.on_write_ahead:
            callback, self.on_write_ahead = self.on_write_ahead, None
            callback()

    def new_engine(self):
        return core.RetryEngine(self.state, self.save,
            lambda event, **fields: self.events.append((event, fields)),
            interval=180, scan_interval=300, threads=["thread"])

    def arm(self):
        self.engine.step(self.backend, 1100)

    def due(self):
        self.engine.step(self.backend, 1280)

    def assert_clean_connections(self):
        for connection in self.desktop.connections:
            self.assertTrue(connection.closed)
            if connection.follows:
                self.assertEqual(connection.follows, [True, False])

    def test_confirmed_retry_uses_owner_v2_saved_correlation_and_only_inherited_settings(self):
        def before_send(params):
            attempt = self.saved[-1]["handled"]["thread"]
            self.assertEqual(attempt["outcome"], "uncertain")
            self.assertEqual(attempt["client_message_id"], params["turnStart"]["request"]["clientUserMessageId"])
            self.assertEqual(str(uuid.UUID(attempt["client_message_id"])), attempt["client_message_id"])
            self.assertNotIn("thread", self.saved[-1]["pending"])
        self.desktop.before_start = before_send
        self.arm()
        self.engine.step(self.backend, 1279)
        self.assertEqual(self.desktop.starts, [])
        self.due()
        self.assertEqual(len(self.desktop.starts), 1)
        params, options = self.desktop.starts[0]
        self.assertEqual(options, {"version": 2, "target": "owner", "timeout": 10})
        request = params["turnStart"]["request"]
        self.assertEqual(set(request), {"threadId", "input", "clientUserMessageId"})
        self.assertEqual(request["threadId"], "thread")
        self.assertEqual(request["input"], [{"type": "text", "text": core.DEFAULT_MESSAGE, "text_elements": []}])
        self.assertEqual(params["turnStart"]["context"], {"inheritThreadSettings": True})
        self.assertEqual(self.state["handled"]["thread"]["outcome"], "submitted")
        self.assertEqual(self.state["handled"]["thread"]["retry_turn_id"], "retry-turn")
        self.assertEqual([event for event, _ in self.events].count("retry"), 1)
        self.assertTrue(self.metadata.calls)
        self.assertTrue(all(method == "thread/turns/list" and params["itemsView"] == "notLoaded"
                            for method, params in self.metadata.calls))
        self.assert_clean_connections()

    def test_persisted_completion_time_is_required_and_never_derived_from_desktop_duration(self):
        result = self.backend.call("thread/turns/list", {"threadId": "thread"})
        self.assertEqual(result["data"][0]["completedAt"], 1100)
        for value in [None, True, float("nan"), float("inf"), "1100", -1]:
            with self.subTest(value=value):
                self.metadata.turns[0]["completedAt"] = value
                self.state = {"enabled_at": 1000}
                self.engine = self.new_engine()
                self.arm()
                self.engine.step(self.backend, 100000)
                self.assertEqual(self.state["pending"], {})
                self.assertEqual(self.desktop.starts, [])

    def test_failures_before_activation_are_not_retried(self):
        self.state["enabled_at"] = 1200
        self.engine.step(self.backend, 1300)
        self.engine.step(self.backend, 100000)
        self.assertEqual(self.desktop.starts, [])
        self.assertEqual(self.state["pending"], {})

    def test_metadata_must_match_latest_desktop_turn_id_status_and_error(self):
        for change in [{"id": "older"}, {"status": "completed"},
                       {"error": {"codexErrorInfo": "unauthorized", "message": core.CAPACITY_MESSAGE}}]:
            with self.subTest(change=change):
                original = copy.deepcopy(self.metadata.turns)
                self.metadata.turns[0].update(change)
                with self.assertRaises(core.RequestError):
                    self.backend.call("thread/turns/list", {"threadId": "thread"})
                self.metadata.turns = original
        self.assertEqual(self.desktop.starts, [])

    def test_busy_pending_and_placeholder_changes_during_wait_never_send(self):
        for mutate in [
            lambda: self.desktop.state.update(threadRuntimeStatus={"type": "active", "activeFlags": []}),
            lambda: self.desktop.state.update(requests=[{"type": "approval"}]),
            lambda: self.desktop.state.update(unconfirmedTurnSubmissions=[{"id": "new-user-message"}]),
            lambda: self.desktop.set_turn(None, "inProgress"),
        ]:
            with self.subTest(mutate=mutate):
                self.setUp()
                self.arm()
                mutate()
                self.due()
                self.assertEqual(self.desktop.starts, [])
                self.assertEqual(self.state["pending"], {})

    def test_model_policy_and_owner_changes_during_wait_cancel_the_old_failure(self):
        for mutate in [
            lambda: self.desktop.set_model("another-model"),
            lambda: self.desktop.state["currentPermissions"].update(approvalPolicy="never"),
            lambda: setattr(self.desktop, "owner", "another-owner"),
        ]:
            with self.subTest(mutate=mutate):
                self.setUp()
                self.arm()
                mutate()
                self.due()
                self.assertEqual(self.desktop.starts, [])
                self.assertEqual(self.state["pending"], {})
                self.assertEqual(self.state["handled"]["thread"]["outcome"], "cancelled")

    def test_final_preflight_blocks_every_changed_state_after_write_ahead_save(self):
        def revision_change():
            self.desktop.snapshot["params"]["change"]["revision"] += 1
        for mutate in [
            lambda: self.desktop.state.update(threadRuntimeStatus={"type": "active", "activeFlags": []}),
            lambda: self.desktop.state.update(requests=[{"type": "input"}]),
            lambda: self.desktop.set_turn(None, "inProgress"),
            lambda: self.desktop.set_model("another-model"),
            lambda: self.desktop.state["currentPermissions"].update(approvalPolicy="never"),
            lambda: setattr(self.desktop, "owner", "another-owner"),
            revision_change,
        ]:
            with self.subTest(mutate=mutate):
                self.setUp()
                self.arm()
                self.on_write_ahead = mutate
                self.due()
                self.assertEqual(self.desktop.starts, [])
                self.assertEqual(self.state["handled"]["thread"]["outcome"], "cancelled")
                self.assertFalse(any(event == "retry" for event, _ in self.events))
                self.assert_clean_connections()

    def test_timeout_and_malformed_ack_are_uncertain_and_never_resent_after_restart(self):
        cases = [DesktopIPCError("timeout"), None, {}, {"result": {}},
                 {"result": {"turn": {"id": ""}}}, {"result": {"turn": {"id": None}}}]
        for response in cases:
            with self.subTest(response=response):
                self.setUp()
                self.arm()
                if isinstance(response, Exception):
                    self.desktop.start_error = response
                else:
                    self.desktop.ack = response
                with self.assertRaises(core.RPCError):
                    self.due()
                self.assertEqual(self.state["handled"]["thread"]["outcome"], "uncertain")
                message_id = self.state["handled"]["thread"]["client_message_id"]
                self.assertEqual(len(self.desktop.starts), 1)
                self.assertFalse(any(event == "retry" for event, _ in self.events))
                self.state = copy.deepcopy(self.state)
                self.engine = self.new_engine()
                self.desktop.start_error = None
                self.desktop.ack = {"result": {"turn": {"id": "retry-turn"}}}
                self.engine.step(self.backend, 2000)
                self.assertEqual(len(self.desktop.starts), 1)
                self.assertEqual(self.state["handled"]["thread"]["client_message_id"], message_id)
                self.assert_clean_connections()

    def test_temporary_preflight_failure_restores_pending_and_previous_result_then_retries_later(self):
        for previous in [None, {"turn_id": "earlier-failure", "retry_turn_id": "earlier-retry",
                                "outcome": "submitted", "result_status": "successful", "at": 1000}]:
            with self.subTest(previous=previous):
                self.setUp()
                if previous:
                    self.state["handled"]["thread"] = copy.deepcopy(previous)
                self.arm()
                pending = copy.deepcopy(self.state["pending"]["thread"])
                self.on_write_ahead = lambda: setattr(self.metadata, "error", core.RequestError("Temporarily loading"))
                self.due()
                self.assertEqual(self.desktop.starts, [])
                self.assertEqual(self.state["pending"]["thread"], pending)
                self.assertEqual(self.state["handled"].get("thread"), previous)
                self.assertEqual([event for event, _ in self.events].count("retry_deferred"), 1)
                self.assertFalse(any(event in ("retry", "uncertain") for event, _ in self.events))
                self.metadata.error = None
                self.engine.step(self.backend, 1309)
                self.assertEqual(self.desktop.starts, [])
                self.engine.step(self.backend, 1310)
                self.assertEqual(len(self.desktop.starts), 1)
                self.assertEqual(self.state["handled"]["thread"]["outcome"], "submitted")
                self.assert_clean_connections()

    def test_runtime_snapshot_follows_slow_metadata_read_in_final_preflight(self):
        self.arm()
        original_call = self.metadata.call
        def slow_read(method, params):
            result = original_call(method, params)
            self.desktop.state["threadRuntimeStatus"] = {"type": "active", "activeFlags": []}
            return result
        self.on_write_ahead = lambda: setattr(self.metadata, "call", slow_read)
        self.due()
        self.assertEqual(self.desktop.starts, [])
        self.assertEqual(self.state["handled"]["thread"]["outcome"], "cancelled")
        self.assertFalse(any(event in ("retry", "uncertain") for event, _ in self.events))
        self.assert_clean_connections()

    def test_same_old_turn_is_not_an_accepted_new_retry_acknowledgement(self):
        self.arm()
        self.desktop.ack = {"result": {"turn": {"id": "failed-turn", "status": "failed"}}}
        with self.assertRaises(core.RPCError):
            self.due()
        self.assertEqual(self.state["handled"]["thread"]["outcome"], "uncertain")
        self.assertFalse(any(event == "retry" for event, _ in self.events))

    def test_quota_wait_stays_held_without_reading_cli_account_permission(self):
        error = {"codexErrorInfo": "usageLimitExceeded", "message": "Usage limit reached"}
        self.desktop.turn["error"] = copy.deepcopy(error)
        self.metadata.turns[0]["error"] = error
        self.arm()
        self.engine.step(self.backend, 1400)
        self.engine.step(self.backend, 2000)
        self.assertEqual(self.desktop.starts, [])
        self.assertEqual(self.state["pending"]["thread"]["kind"], "quota")
        self.assertEqual(self.state["pending"]["thread"]["quota_status"], "unknown")
        self.assertTrue(all(method == "thread/turns/list" for method, _ in self.metadata.calls))

    def test_each_read_gets_a_new_targeted_snapshot_and_cleans_up_following(self):
        for _ in range(2):
            result = self.backend.call("thread/read", {"threadId": "thread"})
            self.assertEqual(result["thread"]["controlOwner"], "owner")
        self.assertEqual(len(self.desktop.connections), 2)
        self.assertNotEqual(self.desktop.connections[0].client_id, self.desktop.connections[1].client_id)
        self.assert_clean_connections()
        self.desktop.snapshot["version"] = 12
        with self.assertRaises(core.RequestError):
            self.backend.call("thread/read", {"threadId": "thread"})
        self.assert_clean_connections()

    def test_missing_owner_is_unloaded_but_unsupported_owner_is_a_protocol_error(self):
        self.desktop.owner_error = DesktopIPCError("no-client-found")
        self.assertEqual(self.backend.call("thread/loaded/list", {}), {"data": [], "nextCursor": None})
        with self.assertRaises(DesktopNoOwner):
            self.backend.call("thread/read", {"threadId": "thread"})
        self.desktop.owner_error = None
        for result in [{}, {"supportsUntrustedAppInput": False}, {"supportsUntrustedAppInput": 1}, None]:
            self.desktop.owner_result = result
            with self.assertRaises(core.RequestError):
                self.backend.call("thread/loaded/list", {})
        self.assert_clean_connections()

    def test_scope_is_explicit_and_never_expands_to_other_conversations(self):
        for ids in [[], ["thread-" + str(n) for n in range(9)]]:
            with self.assertRaises(ValueError):
                DesktopRPC("unused.sock", self.metadata, ids, ipc_factory=self.desktop)
        with self.assertRaises(core.RequestError):
            self.backend.call("thread/read", {"threadId": "another-thread"})
        self.assertEqual(self.desktop.connections, [])
        self.assertEqual(self.metadata.calls, [])

    def test_other_mutating_operations_are_unavailable_without_any_transport_call(self):
        for method in ["thread/start", "thread/resume", "thread/archive", "turn/interrupt",
                       "account/login/start", "account/rateLimitResetCredit/consume"]:
            with self.subTest(method=method), self.assertRaises(core.RequestError):
                self.backend.call(method, {"threadId": "thread"})
        self.assertEqual(self.desktop.connections, [])
        self.assertEqual(self.metadata.calls, [])

    def test_stop_and_transport_cancellation_stay_cancellation_without_a_send(self):
        stopped = DesktopRPC("unused.sock", self.metadata, ["thread"],
                             should_stop=lambda: True, ipc_factory=self.desktop)
        with self.assertRaises(core.RPCCancelled):
            stopped.call("thread/loaded/list", {})
        self.assertEqual(self.desktop.connections, [])
        self.desktop.owner_error = DesktopIPCError("cancelled")
        with self.assertRaises(core.RPCCancelled):
            self.backend.call("thread/read", {"threadId": "thread"})
        self.assertEqual(self.desktop.starts, [])
        self.assert_clean_connections()

    def test_active_retry_is_successful_after_two_minutes_of_observed_healthy_work(self):
        self.arm()
        self.due()
        self.desktop.set_turn("retry-turn", "inProgress")
        self.desktop.state["threadRuntimeStatus"] = {"type": "active", "activeFlags": []}
        self.metadata.turns = [{"id": "retry-turn", "status": "inProgress", "error": None}]
        self.engine.step(self.backend, 1290)
        self.engine.step(self.backend, 1350)
        self.engine.step(self.backend, 1410)
        self.assertEqual(self.state["handled"]["thread"]["result_status"], "successful")
        self.assertEqual(len(self.desktop.starts), 1)

    def test_older_retry_result_keeps_capacity_classification_without_exporting_content(self):
        self.arm()
        self.due()
        self.desktop.set_turn("new-user-turn", "completed")
        self.desktop.state["threadRuntimeStatus"] = {"type": "idle"}
        self.metadata.turns = [
            {"id": "new-user-turn", "status": "completed", "error": None, "completedAt": 1350},
            {"id": "retry-turn", "status": "failed", "completedAt": 1340,
             "error": {"codexErrorInfo": "serverOverloaded", "message": "private operation detail",
                       "additionalDetails": "private account detail"},
             "items": [{"text": "private response"}]},
        ]
        turns = self.backend.call("thread/turns/list", {"threadId": "thread", "limit": 20})["data"]
        self.assertNotIn("private", str(turns))
        self.engine.step(self.backend, 1400)
        attempt = self.state["handled"]["thread"]
        self.assertEqual(attempt["result_status"], "failed")
        self.assertTrue(attempt["result_capacity"])
        self.assertEqual(len(self.desktop.starts), 1)


if __name__ == "__main__":
    unittest.main()
