"""Quota recovery and deadline checks use only local protocol stubs."""

import copy
import json
from pathlib import Path
import signal
import tempfile
import unittest
from unittest import mock

from test_core import FakeRPC, capacity, capacity_turn, user_thread


def quota_turn(turn_id="quota-failure", completed_at=1100):
    return capacity_turn(turn_id, completed_at,
                         error={"codexErrorInfo": "usageLimitExceeded", "message": "Usage limit reached"})


class QuotaRPC(FakeRPC):
    def __init__(self):
        super().__init__()
        self.turns["user-session"] = quota_turn()
        self.quota = {"accountId": "private-account-A", "ordinaryUsageAllowed": False,
                      "rateLimits": {"primary": {"usedPercent": 100, "resetsAt": 9999999999}}}
        self.quota_error = None

    def call(self, method, params):
        if method != "account/rateLimits/read":
            return super().call(method, params)
        self.calls.append((method, copy.deepcopy(params)))
        if self.before_call:
            self.before_call(method, params)
        if self.quota_error:
            raise self.quota_error
        return copy.deepcopy(self.quota)

    def reads(self):
        return [params for method, params in self.calls if method == "account/rateLimits/read"]


class QuotaRecoveryTests(unittest.TestCase):
    def setUp(self):
        self.rpc, self.events, self.saved = QuotaRPC(), [], []
        self.state = {"enabled_at": 1000}
        self.engine = self.new_engine()

    def new_engine(self):
        return capacity.RetryEngine(self.state, lambda state: self.saved.append(copy.deepcopy(state)),
                                    lambda event, **fields: self.events.append((event, fields)),
                                    interval=180, scan_interval=300)

    def arm(self):
        self.engine.step(self.rpc, 1100)

    def test_exact_quota_code_is_required_and_other_errors_never_arm(self):
        self.assertTrue(capacity.is_quota(quota_turn()))
        for code in (None, "other", "rateLimitExceeded", "contextWindowExceeded", "sessionBudgetExceeded",
                     "unauthorized", "cyberPolicy", {"usageLimitExceeded": {}}, ["usageLimitExceeded"]):
            with self.subTest(code=code):
                turn = quota_turn()
                turn["error"] = {"codexErrorInfo": code, "message": "Usage limit reached"}
                self.assertFalse(capacity.is_quota(turn))
                self.rpc.turns["user-session"] = turn
                self.engine.step(self.rpc, 1100)
                self.assertEqual(self.state["pending"], {})
                self.assertEqual(self.rpc.reads(), [])
        turn = quota_turn()
        turn["status"] = "completed"
        self.assertFalse(capacity.is_quota(turn))

    def test_five_minute_checks_notice_early_permission_without_waiting_for_reset_timestamp(self):
        self.arm()
        self.assertEqual(self.state["pending"]["user-session"]["due_at"], 1400)
        self.rpc.quota["ordinaryUsageAllowed"] = True
        self.engine.step(self.rpc, 1399)
        self.assertEqual(len(self.rpc.reads()), 1)
        self.assertEqual(self.rpc.sends(), [])
        self.engine.step(self.rpc, 1400)
        self.assertEqual(self.rpc.sends(), [{"threadId": "user-session", "input": [{
            "type": "text", "text": capacity.DEFAULT_MESSAGE,
        }]}])
        self.assertTrue(all(params == {"excludeResetCreditDetails": True} for params in self.rpc.reads()))
        self.assertFalse(any(method in ("thread/resume", "account/rateLimitResetCredit/consume",
                                       "account/login/start") for method, _ in self.rpc.calls))
        self.assertEqual(self.state["handled"]["user-session"]["kind"], "quota")

    def test_false_permission_keeps_waiting_then_regular_renewal_allows_one_attempt(self):
        self.arm()
        self.engine.step(self.rpc, 1400)
        self.assertEqual(self.rpc.sends(), [])
        self.assertEqual(self.state["pending"]["user-session"]["due_at"], 1700)
        self.rpc.quota["ordinaryUsageAllowed"] = True
        self.engine.step(self.rpc, 1700)
        self.engine.step(self.rpc, 2000)
        self.assertEqual(len(self.rpc.sends()), 1)

    def test_true_at_first_binding_still_waits_for_a_later_fresh_check(self):
        self.rpc.quota["ordinaryUsageAllowed"] = True
        self.arm()
        self.assertEqual(self.rpc.sends(), [])
        self.engine.step(self.rpc, 1400)
        self.assertEqual(len(self.rpc.sends()), 1)

    def test_unknown_permission_never_uses_percentages_or_elapsed_reset_times(self):
        for permission in (None, "true", 1, {}, []):
            with self.subTest(permission=permission):
                self.setUp()
                self.rpc.quota.update(ordinaryUsageAllowed=permission,
                                      rateLimits={"primary": {"usedPercent": 0, "resetsAt": 100}})
                self.arm()
                self.engine.step(self.rpc, 1400)
                self.assertEqual(self.rpc.sends(), [])
                self.assertEqual(self.state["pending"]["user-session"]["quota_status"], "unknown")
        self.rpc.quota = []
        self.engine.step(self.rpc, 1700)
        self.assertEqual(self.rpc.sends(), [])

    def test_missing_account_requires_binding_then_a_subsequent_matching_read(self):
        self.rpc.quota.update(accountId=None, ordinaryUsageAllowed=True)
        self.arm()
        self.engine.step(self.rpc, 1400)
        self.assertNotIn("account_binding", self.state["pending"]["user-session"])
        self.rpc.quota["accountId"] = "private-account-A"
        self.engine.step(self.rpc, 1700)
        self.assertEqual(self.rpc.sends(), [])
        self.engine.step(self.rpc, 2000)
        self.assertEqual(len(self.rpc.sends()), 1)

    def test_changed_account_is_held_until_original_account_returns(self):
        self.arm()
        self.rpc.quota.update(accountId="private-account-B", ordinaryUsageAllowed=True)
        self.engine.step(self.rpc, 1400)
        self.assertEqual(self.rpc.sends(), [])
        self.assertEqual(self.state["pending"]["user-session"]["quota_status"], "account_changed")
        self.assertEqual(self.state["pending"]["user-session"]["due_at"], 1700)
        self.rpc.quota["accountId"] = "private-account-A"
        self.engine.step(self.rpc, 1700)
        self.assertEqual(len(self.rpc.sends()), 1)

    def test_account_switch_after_batch_poll_is_caught_before_submission(self):
        self.arm()
        self.rpc.quota["ordinaryUsageAllowed"] = True
        reads = 0

        def change_account(method, _params):
            nonlocal reads
            if method == "thread/read":
                reads += 1
                if reads == 2:
                    self.rpc.quota["accountId"] = "private-account-B"

        self.rpc.before_call = change_account
        self.engine.step(self.rpc, 1400)
        self.assertEqual(self.rpc.sends(), [])
        self.assertEqual(self.state["pending"]["user-session"]["quota_status"], "account_changed")

    def test_permission_revoked_during_preflight_does_not_send(self):
        self.arm()
        self.rpc.quota["ordinaryUsageAllowed"] = True
        quota_reads = 0

        def revoke(method, _params):
            nonlocal quota_reads
            if method == "account/rateLimits/read":
                quota_reads += 1
                if quota_reads == 2:
                    self.rpc.quota["ordinaryUsageAllowed"] = False

        self.rpc.before_call = revoke
        self.engine.step(self.rpc, 1400)
        self.assertEqual(self.rpc.sends(), [])

    def test_session_changes_while_fresh_quota_is_read_are_rechecked(self):
        for change in ("busy", "model", "effort", "newer"):
            with self.subTest(change=change):
                self.setUp()
                self.arm()
                self.rpc.quota["ordinaryUsageAllowed"] = True
                quota_reads = 0

                def change_session(method, _params):
                    nonlocal quota_reads
                    if method != "account/rateLimits/read":
                        return
                    quota_reads += 1
                    if quota_reads != 2:
                        return
                    if change == "busy":
                        self.rpc.threads["user-session"]["status"] = {"type": "active"}
                    elif change == "model":
                        self.rpc.threads["user-session"]["model"] = "different-user-model"
                    elif change == "effort":
                        self.rpc.threads["user-session"]["reasoningEffort"] = "low"
                    else:
                        self.rpc.turns["user-session"] = quota_turn("newer-user-turn", 1400)

                self.rpc.before_call = change_session
                self.engine.step(self.rpc, 1400)
                self.assertEqual(self.rpc.sends(), [])
                self.assertEqual(self.state["pending"], {})

    def test_rpc_rejection_is_unknown_and_does_not_reuse_old_permission(self):
        self.arm()
        self.rpc.quota_error = capacity.RequestError("unsupported endpoint, private-account-A")
        self.engine.step(self.rpc, 1400)
        self.assertEqual(self.rpc.sends(), [])
        self.assertEqual(self.state["pending"]["user-session"]["quota_status"], "unknown")
        self.assertNotIn("private-account-A", json.dumps(self.events))

    def test_transport_error_defers_quota_check_and_reconnect_requires_fresh_permission(self):
        self.arm()
        self.rpc.quota_error = capacity.RPCError("private-account-A transport error")
        with self.assertRaisesRegex(capacity.RPCError, "quota status could not be read"):
            self.engine.step(self.rpc, 1400)
        self.assertEqual(self.state["pending"]["user-session"]["due_at"], 1700)
        self.rpc.quota_error = None
        self.rpc.quota["ordinaryUsageAllowed"] = True
        self.engine.step(self.rpc, 1699)
        self.assertEqual(self.rpc.sends(), [])
        self.engine.step(self.rpc, 1700)
        self.assertEqual(len(self.rpc.sends()), 1)

    def test_restart_keeps_account_binding_but_reads_fresh_permission(self):
        self.arm()
        binding = self.state["pending"]["user-session"]["account_binding"]
        self.engine = self.new_engine()
        self.assertEqual(self.state["pending"]["user-session"]["account_binding"], binding)
        self.rpc.quota["ordinaryUsageAllowed"] = True
        self.engine.step(self.rpc, 1400)
        self.assertEqual(len(self.rpc.sends()), 1)

    def test_uncertain_delivery_is_latched_durably_across_restart(self):
        self.arm()
        self.rpc.quota["ordinaryUsageAllowed"] = True
        self.rpc.send_error = capacity.RPCError("send acceptance unknown")
        with self.assertRaises(capacity.RPCError):
            self.engine.step(self.rpc, 1400)
        self.assertEqual(self.saved[-1]["handled"]["user-session"]["outcome"], "uncertain")
        self.assertEqual(self.events[-1][0], "uncertain")
        self.assertEqual(self.events[-1][1]["kind"], "quota")
        self.engine = self.new_engine()
        self.rpc.send_error = None
        self.engine.step(self.rpc, 1700)
        self.assertEqual(len(self.rpc.sends()), 1)

    def test_account_identity_and_binding_never_enter_events_or_reconciled_history(self):
        self.arm()
        self.assertNotEqual(self.state["pending"]["user-session"]["account_binding"], "private-account-A")
        history = mock.Mock()
        capacity.reconcile_history(self.state, history, 1101)
        self.assertEqual(history.record.call_args.args[0], "quota_waiting")
        self.assertEqual(history.record.call_args.kwargs["kind"], "quota")
        serialized = json.dumps(self.events) + repr(history.record.call_args_list)
        self.assertNotIn("private-account", serialized)
        self.assertNotIn("account_binding", serialized)
        self.assertNotIn("ordinaryUsageAllowed", serialized)

    def test_historical_unloaded_and_nonterminal_sessions_do_not_poll(self):
        for change in ("historical", "unloaded", "subagent", "paused", "active"):
            with self.subTest(change=change):
                self.setUp()
                if change == "historical":
                    self.rpc.turns["user-session"]["completedAt"] = 999
                elif change == "unloaded":
                    self.rpc.loaded = []
                elif change == "subagent":
                    self.rpc.threads["user-session"]["parentThreadId"] = "parent"
                elif change == "paused":
                    self.state["paused"]["user-session"] = True
                else:
                    self.rpc.threads["user-session"]["status"] = {"type": "active"}
                self.arm()
                self.assertEqual(self.rpc.reads(), [])
                self.assertEqual(self.rpc.sends(), [])

    def test_settings_changes_keep_quota_checks_separate_from_capacity_retry_interval(self):
        self.arm()
        self.engine.apply_settings({**capacity.DEFAULT_SETTINGS, "retry_seconds": 900, "scan_seconds": 300})
        self.assertEqual(self.state["pending"]["user-session"]["due_at"], 1400)
        self.engine.apply_settings({**capacity.DEFAULT_SETTINGS, "retry_seconds": 180, "scan_seconds": 60})
        self.assertEqual(self.state["pending"]["user-session"]["due_at"], 1160)
        self.assertIn("account_binding", self.state["pending"]["user-session"])

    def test_quota_retry_result_retains_origin_when_it_encounters_capacity(self):
        self.arm()
        self.rpc.quota["ordinaryUsageAllowed"] = True
        self.engine.step(self.rpc, 1400)
        self.rpc.turns["user-session"] = capacity_turn("retry-turn", 1405)
        self.engine.step(self.rpc, 1430, discover=False)
        result = next(fields for event, fields in self.events if event == "retry_result")
        self.assertEqual((result["kind"], result["status"], result["capacity"]), ("quota", "failed", True))
        self.assertEqual(self.state["pending"]["user-session"].get("kind", "capacity"), "capacity")
        self.assertEqual(self.state["pending"]["user-session"]["due_at"], 1610)

    def test_maintenance_preserves_discovery_counts_and_does_not_discover_new_failures(self):
        self.rpc.turns["user-session"] = capacity_turn()
        self.arm()
        old_counts = copy.deepcopy(self.state["sessions"])
        self.rpc.loaded.append("new-session")
        self.rpc.threads["new-session"] = user_thread("new-session")
        self.rpc.turns["new-session"] = quota_turn("new-quota")
        self.assertFalse(self.engine.maintenance_due(1279))
        self.assertTrue(self.engine.maintenance_due(1280))
        self.engine.step(self.rpc, 1280, discover=False)
        self.assertEqual(len(self.rpc.sends()), 1)
        self.assertEqual(self.state["sessions"], old_counts)
        self.assertNotIn("new-session", self.state["pending"])
        self.assertEqual(self.rpc.reads(), [])
        self.assertFalse(self.engine.maintenance_due(1309))
        self.assertTrue(self.engine.maintenance_due(1310))

    def test_submitted_retry_is_observed_every_thirty_seconds_and_recovers_after_two_minutes(self):
        self.arm()
        self.rpc.quota["ordinaryUsageAllowed"] = True
        self.engine.step(self.rpc, 1400)
        self.rpc.turns["user-session"] = capacity_turn("retry-turn", status="inProgress", error=None)
        self.rpc.threads["user-session"]["status"] = {"type": "active", "activeFlags": []}
        for now in (1430, 1460, 1490, 1520):
            self.assertTrue(self.engine.maintenance_due(now))
            self.engine.step(self.rpc, now, discover=False)
        self.assertNotIn("result_status", self.state["handled"]["user-session"])
        self.engine.step(self.rpc, 1550, discover=False)
        self.assertEqual(self.state["handled"]["user-session"]["result_status"], "successful")
        self.assertFalse(self.engine.maintenance_due(1700))


class WorkerDeadlineTests(unittest.TestCase):
    def test_due_retry_connection_failures_use_backoff_instead_of_reconnecting_each_second(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            (directory / "state.json").write_text(json.dumps({"version": 1, "enabled_at": 1000,
                "pending": {"user-session": {"turn_id": "capacity-failure", "model": "keep-this-model",
                    "effort": "xhigh", "detected_at": 1000, "wait_started_at": 1000, "due_at": 1180}},
            }))
            clock, handlers, connections = [1200], {}, []

            def connect(_path, **_kwargs):
                connections.append(clock[0])
                raise capacity.RPCError("temporary local transport failure")

            def sleep(_seconds):
                clock[0] += 1
                if clock[0] >= 1262:
                    handlers[signal.SIGTERM](signal.SIGTERM, None)

            with (mock.patch.object(capacity, "configured_parent_pid", return_value=None),
                  mock.patch.object(capacity.os, "umask"),
                  mock.patch.object(capacity.signal, "signal", side_effect=lambda event, callback: handlers.update({event: callback})),
                  mock.patch.object(capacity, "History", return_value=mock.Mock()),
                  mock.patch.object(capacity, "log_emitter", return_value=mock.Mock()),
                  mock.patch.object(capacity, "WebSocketRPC", side_effect=connect),
                  mock.patch.object(capacity, "resolve_socket", return_value=directory / "unused.sock"),
                  mock.patch.object(capacity, "read_settings", return_value={
                      "retry_seconds": 180, "scan_seconds": 300, "message": capacity.DEFAULT_MESSAGE}),
                  mock.patch.object(capacity.time, "monotonic", side_effect=lambda: clock[0]),
                  mock.patch.object(capacity.time, "time", side_effect=lambda: clock[0]),
                  mock.patch.object(capacity.time, "sleep", side_effect=sleep)):
                capacity.run_worker(directory, directory / "missing-codex")
            self.assertEqual(connections, [1200, 1230, 1260])
            self.assertEqual(capacity.read_json(directory / "state.json")["pending"]["user-session"]["turn_id"],
                             "capacity-failure")

    def test_capacity_deadline_runs_before_next_five_minute_discovery_without_extra_quota_poll(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            (directory / "state.json").write_text(json.dumps({"version": 1, "enabled_at": 1000}))
            rpc, clock, handlers, sends = QuotaRPC(), [1100], {}, []
            rpc.loaded.append("capacity-session")
            rpc.threads["capacity-session"] = user_thread("capacity-session")
            rpc.turns["capacity-session"] = capacity_turn("capacity-error")
            rpc.close = mock.Mock()

            def observe(method, _params):
                if method == "turn/start":
                    sends.append(clock[0])

            rpc.before_call = observe

            def sleep(_seconds):
                clock[0] += 1
                if clock[0] >= 1282:
                    handlers[signal.SIGTERM](signal.SIGTERM, None)

            with (mock.patch.object(capacity, "configured_parent_pid", return_value=None),
                  mock.patch.object(capacity.os, "umask"),
                  mock.patch.object(capacity.signal, "signal", side_effect=lambda event, callback: handlers.update({event: callback})),
                  mock.patch.object(capacity, "History", return_value=mock.Mock()),
                  mock.patch.object(capacity, "log_emitter", return_value=mock.Mock()),
                  mock.patch.object(capacity, "WebSocketRPC", return_value=rpc),
                  mock.patch.object(capacity, "resolve_socket", return_value=directory / "unused.sock"),
                  mock.patch.object(capacity, "read_settings", return_value={
                      "retry_seconds": 180, "scan_seconds": 300, "message": capacity.DEFAULT_MESSAGE}),
                  mock.patch.object(capacity.time, "monotonic", side_effect=lambda: clock[0]),
                  mock.patch.object(capacity.time, "time", side_effect=lambda: clock[0]),
                  mock.patch.object(capacity.time, "sleep", side_effect=sleep)):
                capacity.run_worker(directory, directory / "missing-codex")
            self.assertEqual(sends, [1280])
            self.assertEqual(len(rpc.reads()), 1)
            saved = capacity.read_json(directory / "state.json")
            self.assertEqual(saved["last_scan_at"], 1100)
            self.assertEqual(saved["sessions"]["total"], 2)
            self.assertEqual(saved["pending"]["user-session"]["due_at"], 1400)


if __name__ == "__main__":
    unittest.main()
