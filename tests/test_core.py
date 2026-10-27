#!/usr/bin/env python3
"""Behavior and local-transport checks. Never contacts a real Codex session."""

from __future__ import annotations

import base64
import contextlib
import copy
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import socket
import struct
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock


MODULE_PATH = Path(__file__).resolve().parents[1] / "codex_whip.py"
sys.path.insert(0, str(MODULE_PATH.parent))
from history import QUOTA_COUNTERS
SPEC = importlib.util.spec_from_file_location("codex_whip", MODULE_PATH)
capacity = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(capacity)


def user_thread(thread_id="user-session", **changes):
    value = {
        "id": thread_id,
        "model": "keep-this-model",
        "reasoningEffort": "xhigh",
        "status": {"type": "idle"},
        "source": "vscode",
        "originator": "codex-tui",
        "parentThreadId": None,
        "threadSource": "user",
        "canAcceptDirectInput": True,
    }
    value.update(changes)
    return value


def capacity_turn(turn_id="capacity-failure", completed_at=1100, **changes):
    value = {
        "id": turn_id,
        "status": "failed",
        "error": {"codexErrorInfo": "serverOverloaded", "message": capacity.CAPACITY_MESSAGE},
        "completedAt": completed_at,
    }
    value.update(changes)
    return value


class FakeRPC:
    def __init__(self):
        self.threads = {"user-session": user_thread()}
        self.turns = {"user-session": capacity_turn()}
        self.loaded = ["user-session"]
        self.calls = []
        self.before_call = None
        self.send_error = None
        self.pages = None

    def call(self, method, params):
        self.calls.append((method, copy.deepcopy(params)))
        if self.before_call:
            self.before_call(method, params)
        if method == "thread/loaded/list":
            if self.pages:
                return copy.deepcopy(self.pages[params.get("cursor")])
            return {"data": self.loaded.copy(), "nextCursor": None}
        thread_id = params["threadId"]
        if method == "thread/read":
            return {"thread": copy.deepcopy(self.threads[thread_id])}
        if method == "thread/turns/list":
            turn = self.turns.get(thread_id)
            return {"data": [copy.deepcopy(turn)] if turn else [], "nextCursor": None}
        if method == "turn/start":
            if self.send_error:
                raise self.send_error
            return {"turn": {"id": "retry-turn", "status": "inProgress"}}
        raise AssertionError(f"Unexpected RPC: {method}")

    def sends(self):
        return [params for method, params in self.calls if method == "turn/start"]


class RetryEngineTests(unittest.TestCase):
    def setUp(self):
        self.rpc = FakeRPC()
        self.state = {"enabled_at": 1000}
        self.saved = []
        self.events = []
        self.engine = self.new_engine()

    def new_engine(self, **kwargs):
        kwargs = {"interval": 300, "scan_interval": 60, **kwargs}
        return capacity.RetryEngine(
            self.state,
            lambda value: self.saved.append(copy.deepcopy(value)),
            lambda event, **fields: self.events.append((event, fields)),
            **kwargs,
        )

    def arm(self):
        self.engine.step(self.rpc, 1100)

    def test_waits_five_minutes_before_continuing_same_session(self):
        self.arm()
        self.engine.step(self.rpc, 1399)
        self.assertEqual(self.rpc.sends(), [])
        self.engine.step(self.rpc, 1400)
        self.assertEqual(self.rpc.sends(), [{
            "threadId": "user-session",
            "input": [{"type": "text", "text": "Keep using the selected model. Continue the unfinished work."}],
        }])
        # No resume, approval, sandbox, tier, model or reasoning override is sent.
        self.assertFalse(any(method == "thread/resume" for method, _ in self.rpc.calls))

    def test_does_not_retry_historical_failures(self):
        for completed_at in (999, None, "1100"):
            with self.subTest(completed_at=completed_at):
                self.rpc.turns["user-session"] = capacity_turn(completed_at=completed_at)
                self.engine.step(self.rpc, 1100)
                self.engine.step(self.rpc, 10000)
                self.assertEqual(self.rpc.sends(), [])
                self.assertEqual(self.state["pending"], {})

    def test_recovery_interruption_and_other_errors_cancel_pending_retry(self):
        replacements = [
            capacity_turn("finished", status="completed", error=None),
            capacity_turn("cancelled", status="interrupted"),
            capacity_turn("still-working", status="inProgress"),
            capacity_turn("bad-auth", error={"codexErrorInfo": "unauthorized", "message": "Sign in"}),
            None,
        ]
        for replacement in replacements:
            with self.subTest(replacement=replacement):
                self.setUp()
                self.arm()
                self.rpc.turns["user-session"] = replacement
                self.engine.step(self.rpc, 1400)
                self.assertEqual(self.rpc.sends(), [])
                self.assertEqual(self.state["pending"], {})

    def test_busy_session_is_not_steered(self):
        self.arm()
        self.rpc.threads["user-session"]["status"] = {"type": "active", "activeFlags": []}
        self.engine.step(self.rpc, 1400)
        self.assertEqual(self.rpc.sends(), [])
        self.assertEqual(self.state["pending"], {})

    def test_model_or_reasoning_change_cancels_and_never_rearms_old_failure(self):
        for key, value in (("model", "new-user-choice"), ("reasoningEffort", "low")):
            with self.subTest(key=key):
                self.setUp()
                self.arm()
                self.rpc.threads["user-session"][key] = value
                self.engine.step(self.rpc, 1400)
                self.engine.step(self.rpc, 1800)
                self.assertEqual(self.rpc.sends(), [])
                self.assertEqual(self.state["pending"], {})

    def test_newer_capacity_failure_gets_its_own_full_wait(self):
        self.arm()
        self.rpc.turns["user-session"] = capacity_turn("new-user-turn", 1300)
        self.engine.step(self.rpc, 1400)
        self.assertEqual(self.rpc.sends(), [])
        self.engine.step(self.rpc, 1699)
        self.assertEqual(self.rpc.sends(), [])
        self.engine.step(self.rpc, 1700)
        self.assertEqual(len(self.rpc.sends()), 1)

    def test_final_recheck_catches_new_work_before_sending(self):
        self.arm()
        reads = 0

        def change_on_final_read(method, _params):
            nonlocal reads
            if method == "thread/turns/list":
                reads += 1
                if reads == 2:
                    self.rpc.turns["user-session"] = capacity_turn("user-started", status="inProgress")

        self.rpc.before_call = change_on_final_read
        self.engine.step(self.rpc, 1400)
        self.assertEqual(self.rpc.sends(), [])
        self.assertEqual(self.state["pending"], {})

    def test_final_recheck_catches_busy_or_changed_model(self):
        for key, value in (("status", {"type": "active"}), ("model", "another-model")):
            with self.subTest(key=key):
                self.setUp()
                self.arm()
                reads = 0

                def change_on_final_read(method, _params):
                    nonlocal reads
                    if method == "thread/read":
                        reads += 1
                        if reads == 2:
                            self.rpc.threads["user-session"][key] = value

                self.rpc.before_call = change_on_final_read
                self.engine.step(self.rpc, 1400)
                self.assertEqual(self.rpc.sends(), [])

    def test_final_runtime_status_read_catches_activity_after_turn_read(self):
        self.arm()
        reads = 0

        def change_on_last_metadata_read(method, _params):
            nonlocal reads
            if method == "thread/read":
                reads += 1
                if reads == 3:
                    self.rpc.threads["user-session"]["status"] = {"type": "active"}

        self.rpc.before_call = change_on_last_metadata_read
        self.engine.step(self.rpc, 1400)
        self.assertEqual(reads, 3)
        self.assertEqual(self.rpc.sends(), [])

    def test_stop_request_during_final_read_prevents_submission(self):
        stopping = False
        self.engine = self.new_engine(should_stop=lambda: stopping)
        self.arm()
        reads = 0

        def stop_on_last_metadata_read(method, _params):
            nonlocal reads, stopping
            if method == "thread/read":
                reads += 1
                if reads == 3:
                    stopping = True

        self.rpc.before_call = stop_on_last_metadata_read
        self.engine.step(self.rpc, 1400)
        self.assertTrue(stopping)
        self.assertEqual(self.rpc.sends(), [])
        self.assertEqual(self.state["handled"], {})

    def test_stop_request_during_journal_save_prevents_submission(self):
        stopping = False

        def stop_after_journaling(value):
            nonlocal stopping
            self.saved.append(copy.deepcopy(value))
            if value["handled"].get("user-session", {}).get("outcome") == "uncertain":
                stopping = True

        self.engine = capacity.RetryEngine(
            self.state, stop_after_journaling,
            lambda event, **fields: self.events.append((event, fields)),
            should_stop=lambda: stopping,
            interval=300, scan_interval=60,
        )
        self.arm()
        self.engine.step(self.rpc, 1400)
        self.assertTrue(stopping)
        self.assertEqual(self.rpc.sends(), [])
        self.assertEqual(self.saved[-1]["handled"]["user-session"]["outcome"], "uncertain")

    def test_one_unavailable_thread_does_not_starve_another(self):
        self.rpc.loaded = ["a-unavailable", "user-session"]

        def reject_unavailable(method, params):
            if method == "thread/read" and params["threadId"] == "a-unavailable":
                raise capacity.RequestError("Thread unavailable")

        self.rpc.before_call = reject_unavailable
        self.arm()
        self.engine.step(self.rpc, 1400)
        self.assertEqual(len(self.rpc.sends()), 1)
        self.assertTrue(any(event == "thread_unavailable" for event, _ in self.events))

    def test_unavailable_final_read_defers_retry_until_verified(self):
        self.arm()
        reads = 0

        def reject_final_read(method, _params):
            nonlocal reads
            if method == "thread/read":
                reads += 1
                if reads == 2:
                    raise capacity.RequestError("Thread temporarily unavailable")

        self.rpc.before_call = reject_final_read
        self.engine.step(self.rpc, 1400)
        self.assertEqual(self.rpc.sends(), [])
        self.rpc.before_call = None
        self.engine.step(self.rpc, 1410)
        self.assertEqual(len(self.rpc.sends()), 1)

    def test_restart_preserves_pending_wait(self):
        self.arm()
        self.engine = self.new_engine()
        self.engine.step(self.rpc, 1399)
        self.assertEqual(self.rpc.sends(), [])
        self.engine.step(self.rpc, 1400)
        self.assertEqual(len(self.rpc.sends()), 1)

    def test_sent_failure_cannot_be_sent_twice_after_restart(self):
        self.arm()
        self.engine.step(self.rpc, 1400)
        self.engine = self.new_engine()
        self.engine.step(self.rpc, 1800)
        self.assertEqual(len(self.rpc.sends()), 1)
        self.assertEqual(self.state["handled"]["user-session"]["outcome"], "submitted")

    def test_disconnect_during_send_is_journaled_before_send_and_never_resent(self):
        self.arm()
        self.rpc.send_error = capacity.RPCError("connection closed after sending")
        with self.assertRaises(capacity.RPCError):
            self.engine.step(self.rpc, 1400)
        self.assertEqual(self.saved[-1]["handled"]["user-session"]["outcome"], "uncertain")
        self.assertEqual(self.saved[-1]["pending"], {})
        self.engine = self.new_engine()
        self.rpc.send_error = None
        self.engine.step(self.rpc, 1800)
        self.assertEqual(len(self.rpc.sends()), 1)

    def test_repeated_capacity_failures_continue_until_success(self):
        self.arm()
        self.engine.step(self.rpc, 1400)
        self.rpc.turns["user-session"] = capacity_turn("retry-turn", 1410)
        self.engine.step(self.rpc, 1410)
        self.engine.step(self.rpc, 1709)
        self.assertEqual(len(self.rpc.sends()), 1)
        self.engine.step(self.rpc, 1710)
        self.assertEqual(len(self.rpc.sends()), 2)
        self.rpc.turns["user-session"] = capacity_turn("done", status="completed", error=None)
        self.engine.step(self.rpc, 2000)
        self.engine.step(self.rpc, 10000)
        self.assertEqual(len(self.rpc.sends()), 2)
        self.assertEqual(self.state["pending"], {})

    def test_unloaded_session_is_cancelled_and_not_rearmed_when_reopened(self):
        self.arm()
        self.rpc.loaded = []
        self.engine.step(self.rpc, 1400)
        self.rpc.loaded = ["user-session"]
        self.engine.step(self.rpc, 1500)
        self.engine.step(self.rpc, 1900)
        self.assertEqual(self.rpc.sends(), [])

    def test_paused_session_is_not_retried(self):
        self.arm()
        self.state["paused"]["user-session"] = True
        self.engine.step(self.rpc, 1400)
        self.assertEqual(self.rpc.sends(), [])
        self.assertEqual(self.state["pending"], {})

    def test_explicit_thread_scope_does_not_touch_other_sessions(self):
        self.engine = self.new_engine(threads=["another-session"])
        self.engine.step(self.rpc, 1100)
        self.assertEqual([method for method, _ in self.rpc.calls], ["thread/loaded/list"])
        self.assertEqual(self.rpc.sends(), [])

    def test_only_loaded_top_level_user_sessions_with_known_model_are_eligible(self):
        variants = [
            {"parentThreadId": "parent"},
            {"ephemeral": True},
            {"threadSource": "subAgent"},
            {"source": {"subAgent": {"thread_spawn": {}}}},
            {"source": "exec"},
            {"source": "unknown"},
            {"source": "vscode", "originator": None},
            {"source": "appServer", "originator": "codex-desktop"},
            {"canAcceptDirectInput": False},
            {"canAcceptDirectInput": None},
            {"model": None},
            {"status": {"type": "notLoaded"}},
        ]
        for changes in variants:
            with self.subTest(changes=changes):
                self.setUp()
                self.rpc.threads["user-session"].update(changes)
                self.arm()
                self.engine.step(self.rpc, 1400)
                self.assertEqual(self.rpc.sends(), [])
                self.assertEqual(self.state["pending"], {})
                self.assertFalse(any(method == "thread/turns/list" for method, _ in self.rpc.calls))

    def test_terminal_sessions_are_identified_by_source_or_tui_originator(self):
        for source, originator in (("cli", None), ("vscode", "codex-tui"), ("appServer", "codex-tui")):
            with self.subTest(source=source, originator=originator):
                self.setUp()
                self.rpc.threads["user-session"]["source"] = source
                self.rpc.threads["user-session"]["originator"] = originator
                self.arm()
                self.engine.step(self.rpc, 1400)
                self.assertEqual(len(self.rpc.sends()), 1)

    def test_real_capacity_error_runtime_is_retried_after_full_wait(self):
        self.rpc.threads["user-session"]["status"] = {"type": "systemError"}
        self.arm()
        self.assertIn("user-session", self.state["pending"])
        self.assertEqual(self.state["sessions"]["errored"], 1)
        self.engine.step(self.rpc, 1399)
        self.assertEqual(self.rpc.sends(), [])
        self.engine.step(self.rpc, 1400)
        self.assertEqual(len(self.rpc.sends()), 1)

    def test_unrelated_system_error_never_triggers_retry(self):
        self.rpc.threads["user-session"]["status"] = {"type": "systemError"}
        self.rpc.turns["user-session"] = capacity_turn(error={"codexErrorInfo": "unauthorized"})
        self.arm()
        self.engine.step(self.rpc, 1400)
        self.assertEqual(self.rpc.sends(), [])
        self.assertEqual(self.state["pending"], {})

    def test_loaded_session_pagination_is_followed(self):
        self.rpc.pages = {
            None: {"data": [], "nextCursor": "second"},
            "second": {"data": ["user-session"], "nextCursor": None},
        }
        self.arm()
        self.engine.step(self.rpc, 1400)
        self.assertEqual(len(self.rpc.sends()), 1)
        list_calls = [params for method, params in self.rpc.calls if method == "thread/loaded/list"]
        self.assertEqual([params["cursor"] for params in list_calls], [None, "second", None, "second"])


class ReportingTests(unittest.TestCase):
    def engine(self, state, events):
        return capacity.RetryEngine(state, lambda _value: None,
                                    lambda event, **fields: events.append((event, fields)),
                                    threads=state.get("threads", []), interval=300, scan_interval=60)

    def test_session_counts_include_active_and_idle_but_exclude_unwatched_threads(self):
        rpc = FakeRPC()
        rpc.loaded = ["idle", "active", "child", "paused", "ide"]
        rpc.threads = {
            "idle": user_thread("idle"),
            "active": user_thread("active", status={"type": "active"}),
            "child": user_thread("child", parentThreadId="parent"),
            "paused": user_thread("paused"),
            "ide": user_thread("ide", originator="ide-client"),
        }
        rpc.turns = {}
        state = {"enabled_at": 1000, "paused": {"paused": True}}
        self.engine(state, []).step(rpc, 1100)
        self.assertEqual(state["sessions"], {
            "total": 2, "active": 1, "idle": 1, "errored": 0, "other": 0, "unavailable": 0,
        })
        self.assertEqual(rpc.sends(), [])

    def test_session_counts_respect_explicit_scope(self):
        rpc = FakeRPC()
        rpc.loaded.append("another")
        rpc.threads["another"] = user_thread("another")
        state = {"enabled_at": 1000, "threads": ["another"]}
        self.engine(state, []).step(rpc, 1100)
        self.assertEqual(state["sessions"]["total"], 1)
        self.assertFalse(any(params.get("threadId") == "user-session" for _, params in rpc.calls))

    def test_completed_retry_is_observed_once_and_send_acceptance_is_not_success(self):
        rpc, events = FakeRPC(), []
        state = {"enabled_at": 1000, "handled": {"user-session": {
            "outcome": "submitted", "turn_id": "original", "retry_turn_id": "retry-turn",
        }}}
        engine = self.engine(state, events)
        rpc.turns["user-session"] = capacity_turn("retry-turn", status="inProgress", error=None)
        rpc.threads["user-session"]["status"] = {"type": "active"}
        engine.step(rpc, 1100)
        self.assertFalse(any(event == "retry_result" for event, _ in events))
        rpc.turns["user-session"] = capacity_turn("retry-turn", status="completed", error=None)
        rpc.threads["user-session"]["status"] = {"type": "idle"}
        engine.step(rpc, 1160)
        engine.step(rpc, 1220)
        results = [fields for event, fields in events if event == "retry_result"]
        self.assertEqual(results, [{"thread_id": "user-session", "turn_id": "retry-turn",
                                   "status": "successful", "capacity": False, "occurred_at": 1100,
                                   "kind": "capacity"}])

    def test_failed_retry_records_capacity_separately_from_other_errors(self):
        for error, is_capacity in (({"codexErrorInfo": "serverOverloaded"}, True),
                                   ({"codexErrorInfo": "unauthorized"}, False)):
            with self.subTest(error=error):
                rpc, events = FakeRPC(), []
                state = {"enabled_at": 1000, "handled": {"user-session": {
                    "outcome": "submitted", "turn_id": "original", "retry_turn_id": "retry-turn",
                }}}
                rpc.turns["user-session"] = capacity_turn("retry-turn", error=error)
                self.engine(state, events).step(rpc, 1100)
                result = next(fields for event, fields in events if event == "retry_result")
                self.assertEqual(result["capacity"], is_capacity)
                self.assertEqual(result["status"], "failed")

    def test_new_user_turn_is_not_mistaken_for_retry_success(self):
        rpc, events = FakeRPC(), []
        state = {"enabled_at": 1000, "handled": {"user-session": {
            "outcome": "submitted", "turn_id": "original", "retry_turn_id": "retry-turn",
        }}}
        rpc.turns["user-session"] = capacity_turn("new-user-turn", status="completed", error=None)
        self.engine(state, events).step(rpc, 1100)
        self.assertFalse(any(event == "retry_result" for event, _ in events))
        self.assertNotIn("result_status", state["handled"]["user-session"])

    def test_retry_outcome_is_found_after_a_new_user_turn_starts(self):
        rpc, events = FakeRPC(), []
        state = {"enabled_at": 1000, "handled": {"user-session": {
            "outcome": "submitted", "turn_id": "original", "retry_turn_id": "retry-turn",
        }}}
        newer = capacity_turn("new-user-turn", status="inProgress", error=None)
        completed = capacity_turn("retry-turn", status="completed", error=None)
        rpc.threads["user-session"]["status"] = {"type": "active"}
        original_call = rpc.call

        def recent_turns(method, params):
            if method == "thread/turns/list" and params.get("limit") == 20:
                return {"data": [newer, completed]}
            return original_call(method, params)

        rpc.call = recent_turns
        self.engine(state, events).step(rpc, 1160)
        result = next(fields for event, fields in events if event == "retry_result")
        self.assertEqual(result["turn_id"], "retry-turn")
        self.assertEqual(result["status"], "successful")

    def test_finished_retry_is_recorded_after_terminal_session_unloads(self):
        rpc, events = FakeRPC(), []
        rpc.loaded = []
        rpc.turns["user-session"] = capacity_turn("retry-turn", status="completed", error=None)
        state = {"enabled_at": 1000, "handled": {"user-session": {
            "outcome": "submitted", "turn_id": "original", "retry_turn_id": "retry-turn", "at": 1100,
        }}}
        self.engine(state, events).step(rpc, 1160)
        result = next(fields for event, fields in events if event == "retry_result")
        self.assertEqual(result["status"], "successful")
        self.assertEqual(state["sessions"]["total"], 0)
        self.assertEqual(rpc.sends(), [])
        self.assertFalse(any(method == "thread/resume" for method, _ in rpc.calls))

    def test_status_uses_saved_counts_and_reports_stopped_as_zero(self):
        state = {"sessions": {"total": 9, "active": 3, "idle": 6}, "pending": {},
                 "last_scan_at": 1000}
        for enabled, expected in ((True, "Watching: 9 terminal sessions (3 active, 6 idle)"),
                                  (False, "Watching: 0 terminal sessions (stopped)")):
            with self.subTest(enabled=enabled), tempfile.TemporaryDirectory() as temporary:
                directory = Path(temporary)
                (directory / "state.json").write_text(json.dumps(state))
                output = io.StringIO()
                with (mock.patch.object(capacity, "service_running", return_value=enabled),
                      mock.patch.object(capacity, "print_activity"),
                      mock.patch.object(capacity.sys, "platform", "darwin"),
                      contextlib.redirect_stdout(output)):
                    capacity.status(directory)
                self.assertIn(expected, output.getvalue())
                self.assertIn("Checks: every 5 minutes. Capacity retries: every 3 minutes.", output.getvalue())

    def test_history_reconciles_crash_between_state_save_and_event_write(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            history = capacity.History(directory, clock=lambda: 1500)
            try:
                state = {
                    "pending": {"waiting-session": {
                        "turn_id": "capacity-1", "detected_at": 1200, "due_at": 1500,
                    }},
                    "handled": {"sent-session": {
                        "turn_id": "capacity-2", "capacity_at": 1100, "at": 1400,
                        "outcome": "submitted", "retry_turn_id": "retry-2",
                    }},
                }
                capacity.reconcile_history(state, history, 1500)
                capacity.reconcile_history(state, history, 1500)
                report = capacity.read_report(directory, now=1500)
                self.assertEqual(report["capacity"], 2)
                self.assertEqual(report["retries"], 1)
                self.assertEqual(report["awaiting"], 1)
                retry = next(event for event in report["recent"] if event["event"] == "retry")
                self.assertEqual(retry["ts"], 1400)
            finally:
                history.close()

    def test_cli_report_describes_recovery_success_and_awaiting_recovery(self):
        report = {
            **dict.fromkeys(QUOTA_COUNTERS, 0),
            "available": True, "capacity": 4, "retries": 3, "successful": 2,
            "failed": 0, "failed_capacity": 0, "failed_other": 0, "interrupted": 0,
            "awaiting": 1, "uncertain": 0, "recorded_since": None,
            "recent": [{"event": "retry_result", "status": "completed", "ts": 1200,
                        "thread_id": "session", "capacity": False}],
        }
        output = io.StringIO()
        with (mock.patch.object(capacity, "read_report", return_value=report),
              contextlib.redirect_stdout(output)):
            capacity.print_activity(Path("unused-test-directory"))
        self.assertIn("Successful: 2", output.getvalue())
        self.assertIn("Awaiting recovery: 1", output.getvalue())
        self.assertIn("2 minutes of continuously observed healthy activity", output.getvalue())
        self.assertIn("retry successful", output.getvalue())

    def test_cli_report_names_sessions_by_the_end_of_their_ids(self):
        # Neighboring sessions share a timestamp prefix; only the ending tells them apart.
        report = {
            **dict.fromkeys(QUOTA_COUNTERS, 0),
            "available": True, "capacity": 2, "retries": 0, "successful": 0,
            "failed": 0, "failed_capacity": 0, "failed_other": 0, "interrupted": 0,
            "awaiting": 0, "uncertain": 0, "recorded_since": None,
            "recent": [{"event": "capacity", "ts": 1200, "capacity": True,
                        "thread_id": f"019a2b3c-4d5e-7f00-8a1b-00000000{suffix}"}
                       for suffix in ("7f3a", "c2d9")],
        }
        output = io.StringIO()
        with (mock.patch.object(capacity, "read_report", return_value=report),
              contextlib.redirect_stdout(output)):
            capacity.print_activity(Path("unused-test-directory"))
        self.assertIn(" · 00007f3a · capacity error found", output.getvalue())
        self.assertIn(" · 0000c2d9 · capacity error found", output.getvalue())
        self.assertNotIn("019a2b3c", output.getvalue())


class RecoverySuccessTests(unittest.TestCase):
    def setUp(self):
        self.rpc = FakeRPC()
        self.rpc.threads["user-session"]["status"] = {"type": "active", "activeFlags": []}
        self.rpc.turns["user-session"] = capacity_turn("retry-turn", status="inProgress", error=None)
        self.state = {"enabled_at": 1000, "handled": {"user-session": {
            "outcome": "submitted", "turn_id": "original", "retry_turn_id": "retry-turn", "at": 1000,
        }}}
        self.events, self.saved = [], []
        self.engine = self.new_engine()

    def new_engine(self):
        return capacity.RetryEngine(
            self.state, lambda value: self.saved.append(copy.deepcopy(value)),
            lambda event, **fields: self.events.append((event, fields)),
            interval=300, scan_interval=60,
        )

    def results(self):
        return [fields for event, fields in self.events if event == "retry_result"]

    def test_success_requires_observed_healthy_activity_spanning_120_seconds(self):
        self.engine.step(self.rpc, 1100)
        self.engine.step(self.rpc, 1160)
        self.engine.step(self.rpc, 1219)
        self.assertEqual(self.results(), [])
        self.assertEqual(self.saved[-1]["handled"]["user-session"]["healthy_since"], 1100)
        self.assertEqual(self.saved[-1]["handled"]["user-session"]["healthy_last_seen"], 1219)
        self.engine.step(self.rpc, 1220)
        self.assertEqual(self.results(), [{
            "thread_id": "user-session", "turn_id": "retry-turn", "status": "successful",
            "capacity": False, "occurred_at": 1220, "kind": "capacity",
        }])
        self.assertEqual(self.state["handled"]["user-session"]["result_status"], "successful")
        self.assertNotIn("healthy_since", self.state["handled"]["user-session"])

    def test_active_snapshot_without_latest_turn_uses_first_recent_retry_for_success(self):
        thread, latest = capacity.snapshot(self.rpc, "user-session")
        self.assertEqual(thread["status"], {"type": "active", "activeFlags": []})
        self.assertIsNone(latest)
        self.rpc.calls.clear()
        for now in (1100, 1160, 1220):
            self.engine.step(self.rpc, now)
        turn_queries = [params for method, params in self.rpc.calls if method == "thread/turns/list"]
        self.assertEqual([query["limit"] for query in turn_queries], [20, 20, 20])
        self.assertEqual(self.results()[0]["status"], "successful")

    def test_success_latches_and_ends_outcome_polling_after_restart(self):
        for now in (1100, 1160, 1220):
            self.engine.step(self.rpc, now)
        self.rpc.calls.clear()
        self.engine = self.new_engine()
        self.engine.step(self.rpc, 1280)
        self.assertEqual(len(self.results()), 1)
        self.assertFalse(any(method == "thread/turns/list" for method, _ in self.rpc.calls))

    def test_timer_and_send_acceptance_without_positive_work_are_insufficient(self):
        for runtime in ("idle", "systemError", "notLoaded"):
            with self.subTest(runtime=runtime):
                self.setUp()
                self.rpc.threads["user-session"]["status"] = {"type": runtime, "activeFlags": []}
                for now in (1100, 1160, 1220, 1280):
                    self.engine.step(self.rpc, now)
                self.assertEqual(self.results(), [])
                self.assertNotIn("healthy_since", self.state["handled"]["user-session"])

    def test_waiting_flags_and_unknown_flags_reset_the_full_window(self):
        for flags in (["waitingOnApproval"], ["waitingOnUserInput"], ["unknown"], None):
            with self.subTest(flags=flags):
                self.setUp()
                self.engine.step(self.rpc, 1100)
                self.rpc.threads["user-session"]["status"] = {"type": "active", "activeFlags": flags}
                self.engine.step(self.rpc, 1160)
                self.assertNotIn("healthy_since", self.state["handled"]["user-session"])
                self.rpc.threads["user-session"]["status"] = {"type": "active", "activeFlags": []}
                self.engine.step(self.rpc, 1220)
                self.engine.step(self.rpc, 1280)
                self.assertEqual(self.results(), [])
                self.engine.step(self.rpc, 1340)
                self.assertEqual(self.results()[0]["occurred_at"], 1340)

    def test_in_progress_turn_error_is_not_healthy_activity(self):
        self.engine.step(self.rpc, 1100)
        self.rpc.turns["user-session"]["error"] = {"message": "Stream unavailable"}
        self.engine.step(self.rpc, 1160)
        self.assertNotIn("healthy_since", self.state["handled"]["user-session"])
        self.assertEqual(self.results(), [])

    def test_paused_unloaded_and_unavailable_observations_reset_continuity(self):
        for condition in ("paused", "unloaded", "unavailable"):
            with self.subTest(condition=condition):
                self.setUp()
                self.engine.step(self.rpc, 1100)
                if condition == "paused":
                    self.state["paused"]["user-session"] = True
                elif condition == "unloaded":
                    self.rpc.loaded = []
                else:
                    def unavailable(method, _params):
                        if method == "thread/read":
                            raise capacity.RequestError("Thread unavailable")
                    self.rpc.before_call = unavailable
                self.engine.step(self.rpc, 1160)
                self.assertNotIn("healthy_since", self.state["handled"]["user-session"])
                self.state["paused"].clear()
                self.rpc.loaded = ["user-session"]
                self.rpc.before_call = None
                self.engine.step(self.rpc, 1220)
                self.engine.step(self.rpc, 1280)
                self.assertEqual(self.results(), [])
                self.engine.step(self.rpc, 1340)
                self.assertEqual(self.results()[0]["occurred_at"], 1340)

    def test_reconnect_does_not_count_offline_time(self):
        self.engine.step(self.rpc, 1100)
        self.engine.step(self.rpc, 1160)

        def disconnect(method, _params):
            if method == "thread/loaded/list":
                raise capacity.RPCError("Socket disconnected")

        self.rpc.before_call = disconnect
        with self.assertRaises(capacity.RPCError):
            self.engine.step(self.rpc, 1190)
        self.assertNotIn("healthy_since", self.state["handled"]["user-session"])
        self.rpc.before_call = None
        self.engine.step(self.rpc, 1200)
        self.engine.step(self.rpc, 1260)
        self.assertEqual(self.results(), [])
        self.engine.step(self.rpc, 1320)
        self.assertEqual(self.results()[0]["occurred_at"], 1320)

    def test_long_observation_gap_starts_a_new_window(self):
        self.engine.step(self.rpc, 1100)
        self.engine.step(self.rpc, 1191)
        self.assertEqual(self.state["handled"]["user-session"]["healthy_since"], 1191)
        self.engine.step(self.rpc, 1251)
        self.assertEqual(self.results(), [])
        self.engine.step(self.rpc, 1311)
        self.assertEqual(self.results()[0]["occurred_at"], 1311)

    def test_restart_discards_persisted_active_observation_time(self):
        self.engine.step(self.rpc, 1100)
        self.engine.step(self.rpc, 1160)
        self.assertIn("healthy_since", self.saved[-1]["handled"]["user-session"])
        self.engine = self.new_engine()
        self.assertNotIn("healthy_since", self.state["handled"]["user-session"])
        self.assertEqual(self.state["handled"]["user-session"]["at"], 1000)
        self.engine.step(self.rpc, 1190)
        self.engine.step(self.rpc, 1250)
        self.assertEqual(self.results(), [])
        self.engine.step(self.rpc, 1310)
        self.assertEqual(self.results()[0]["occurred_at"], 1310)

    def test_missing_retry_turn_or_newer_user_activity_does_not_imply_success(self):
        for missing in (True, False):
            with self.subTest(missing=missing):
                self.setUp()
                self.engine.step(self.rpc, 1100)
                own_turn = self.rpc.turns["user-session"]
                newer = capacity_turn("user-turn", status="inProgress", error=None)
                original = self.rpc.call

                def turns(method, params):
                    if method == "thread/turns/list" and params.get("limit") == 20:
                        return {"data": [newer] if missing else [newer, own_turn]}
                    return original(method, params)

                self.rpc.call = turns
                self.engine.step(self.rpc, 1160)
                self.engine.step(self.rpc, 1220)
                self.assertEqual(self.results(), [])
                self.assertNotIn("healthy_since", self.state["handled"]["user-session"])

    def test_failure_or_interruption_before_success_keeps_actual_outcome(self):
        for status, error in (("failed", {"codexErrorInfo": "serverOverloaded"}),
                              ("failed", {"codexErrorInfo": "unauthorized"}),
                              ("interrupted", None)):
            with self.subTest(status=status, error=error):
                self.setUp()
                self.engine.step(self.rpc, 1100)
                self.engine.step(self.rpc, 1160)
                self.rpc.threads["user-session"]["status"] = {"type": "idle"}
                self.rpc.turns["user-session"] = capacity_turn("retry-turn", 1219, status=status, error=error)
                self.engine.step(self.rpc, 1219)
                self.assertEqual(self.results()[0]["status"], status)

    def test_capacity_failure_after_success_arms_new_retry_without_rewriting_success(self):
        for now in (1100, 1160, 1220):
            self.engine.step(self.rpc, now)
        self.rpc.threads["user-session"]["status"] = {"type": "systemError"}
        self.rpc.turns["user-session"] = capacity_turn("retry-turn", 1300)
        self.engine.step(self.rpc, 1300)
        self.assertEqual(len(self.results()), 1)
        self.assertEqual(self.results()[0]["status"], "successful")
        self.assertEqual(self.state["pending"]["user-session"]["turn_id"], "retry-turn")
        self.assertEqual(self.state["pending"]["user-session"]["due_at"], 1600)

    def test_success_is_crash_reconciled_from_durable_result_latch(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            path = directory / "state.json"

            def fail_result_event(event, **_fields):
                if event == "retry_result":
                    raise RuntimeError("Interrupted before history write")

            self.engine = capacity.RetryEngine(
                self.state, lambda value: capacity.atomic_json(path, value), fail_result_event,
                interval=300, scan_interval=60,
            )
            self.engine.step(self.rpc, 1100)
            self.engine.step(self.rpc, 1160)
            with self.assertRaisesRegex(RuntimeError, "before history write"):
                self.engine.step(self.rpc, 1220)
            saved = capacity.read_json(path)
            self.assertEqual(saved["handled"]["user-session"]["result_status"], "successful")
            self.assertEqual(saved["handled"]["user-session"]["result_at"], 1220)
            history = capacity.History(directory, clock=lambda: 1300)
            try:
                capacity.reconcile_history(saved, history, 1300)
                capacity.reconcile_history(saved, history, 1300)
                report = capacity.read_report(directory, now=1300)
                self.assertEqual(report["successful"], 1)
                self.assertEqual(report["awaiting"], 0)
            finally:
                history.close()


class CapacityClassificationTests(unittest.TestCase):
    def test_structured_capacity_code_is_authoritative(self):
        self.assertTrue(capacity.is_capacity(capacity_turn(error={
            "codexErrorInfo": "serverOverloaded", "message": "Localized overload explanation",
        })))

    def test_exact_text_fallback_accepts_optional_final_period(self):
        for code in (None, "other"):
            for suffix in ("", "."):
                with self.subTest(code=code, suffix=suffix):
                    self.assertTrue(capacity.is_capacity(capacity_turn(error={
                        "codexErrorInfo": code, "message": capacity.CAPACITY_MESSAGE + suffix,
                    })))

    def test_noncapacity_codes_win_over_matching_text(self):
        for code in ("usageLimitExceeded", "rateLimitExceeded", "unauthorized", "cyberPolicy",
                     "misalignmentPolicyViolation", {"httpConnectionFailed": {"httpStatusCode": 503}}):
            with self.subTest(code=code):
                self.assertFalse(capacity.is_capacity(capacity_turn(error={
                    "codexErrorInfo": code, "message": capacity.CAPACITY_MESSAGE,
                })))

    def test_other_messages_and_nonfailed_turns_are_not_capacity(self):
        for turn in (None, {}, capacity_turn(status="inProgress"), capacity_turn(status="interrupted"),
                     capacity_turn(error=None), capacity_turn(error={"message": "capacity"}),
                     capacity_turn(error={"message": "Log says: " + capacity.CAPACITY_MESSAGE})):
            with self.subTest(turn=turn):
                self.assertFalse(capacity.is_capacity(turn))


class DoctorTests(unittest.TestCase):
    def test_unreadable_thread_is_skipped_without_model_or_turn_requests(self):
        rpc = FakeRPC()
        rpc.loaded = ["a-unavailable", "user-session"]
        rpc.close = mock.Mock()

        def reject_unavailable(method, params):
            if method == "thread/read" and params["threadId"] == "a-unavailable":
                raise capacity.RequestError("Thread unavailable")

        rpc.before_call = reject_unavailable
        output = io.StringIO()
        with (mock.patch.object(capacity, "WebSocketRPC", return_value=rpc),
              mock.patch.object(capacity, "resolve_socket", return_value=Path("unused-test-socket")),
              contextlib.redirect_stdout(output)):
            capacity.doctor(Path("unused-test-home"))
        self.assertIn("2 loaded sessions, 1 accept direct input", output.getvalue())
        self.assertIn("Skipped 1 sessions", output.getvalue())
        self.assertIn("Read-only check passed", output.getvalue())
        self.assertEqual(rpc.sends(), [])
        self.assertFalse(any(method == "thread/turns/list" for method, _ in rpc.calls))
        rpc.close.assert_called_once_with()


def read_exact(connection, count):
    result = bytearray()
    while len(result) < count:
        chunk = connection.recv(count - len(result))
        if not chunk:
            raise EOFError("Client closed connection")
        result.extend(chunk)
    return bytes(result)


def read_client_frame(connection):
    first, second = read_exact(connection, 2)
    if not second & 0x80:
        raise AssertionError("Client WebSocket frames must be masked")
    size = second & 0x7F
    if size == 126:
        size = struct.unpack("!H", read_exact(connection, 2))[0]
    elif size == 127:
        size = struct.unpack("!Q", read_exact(connection, 8))[0]
    mask = read_exact(connection, 4)
    payload = read_exact(connection, size)
    return first & 0x0F, bytes(value ^ mask[i % 4] for i, value in enumerate(payload))


def server_frame(payload, opcode=1, final=True):
    if isinstance(payload, dict):
        payload = json.dumps(payload).encode()
    size = len(payload)
    header = bytes([(0x80 if final else 0) | opcode])
    if size < 126:
        return header + bytes([size]) + payload
    if size < 65536:
        return header + bytes([126]) + struct.pack("!H", size) + payload
    return header + bytes([127]) + struct.pack("!Q", size) + payload


class LocalWebSocketServer:
    def __init__(self, handler):
        self.handler = handler
        self.error = None
        self.directory = tempfile.TemporaryDirectory(prefix="cc-test-", dir="/tmp")
        self.path = Path(self.directory.name) / "rpc.sock"
        self.listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.listener.bind(str(self.path))
        self.listener.listen(1)
        self.listener.settimeout(3)
        self.thread = threading.Thread(target=self.serve, daemon=True)

    def __enter__(self):
        self.thread.start()
        return self

    def serve(self):
        try:
            with self.listener.accept()[0] as connection:
                connection.settimeout(3)
                headers = bytearray()
                while b"\r\n\r\n" not in headers:
                    headers.extend(read_exact(connection, 1))
                parsed = dict(line.split(":", 1) for line in headers.decode().split("\r\n")[1:] if ":" in line)
                key = parsed["Sec-WebSocket-Key"].strip()
                digest = base64.b64encode(hashlib.sha1(
                    (key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()
                ).digest()).decode()
                connection.sendall(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n"
                                    "Connection: Upgrade\r\n"
                                    f"Sec-WebSocket-Accept: {digest}\r\n\r\n").encode())
                opcode, payload = read_client_frame(connection)
                initialize = json.loads(payload)
                if opcode != 1 or initialize["method"] != "initialize":
                    raise AssertionError("Expected initialize request")
                connection.sendall(server_frame({"id": initialize["id"], "result": {"platformOs": "test"}}))
                opcode, payload = read_client_frame(connection)
                if opcode != 1 or json.loads(payload)["method"] != "initialized":
                    raise AssertionError("Expected initialized notification")
                self.handler(connection)
        except BaseException as error:
            self.error = error

    def __exit__(self, exc_type, _exc, _traceback):
        self.thread.join(timeout=4)
        self.listener.close()
        self.directory.cleanup()
        if exc_type is None:
            if self.thread.is_alive():
                raise AssertionError("Local WebSocket server did not finish")
            if self.error:
                raise self.error


class WebSocketTests(unittest.TestCase):
    def test_cancellable_read_polling_waits_for_a_slow_successful_rpc(self):
        def handler(connection):
            _opcode, payload = read_client_frame(connection)
            request = json.loads(payload)
            time.sleep(0.6)
            connection.sendall(server_frame({"id": request["id"], "result": {"data": []}}))

        with LocalWebSocketServer(handler) as server:
            rpc = capacity.WebSocketRPC(server.path, timeout=1, should_stop=lambda: False)
            try:
                self.assertEqual(rpc.call("thread/loaded/list", {}), {"data": []})
            finally:
                rpc.close()

    def test_cancelled_transport_sends_no_request(self):
        rpc = capacity.WebSocketRPC.__new__(capacity.WebSocketRPC)
        rpc.should_stop = lambda: True
        rpc.sock = mock.Mock()
        rpc.sequence = 0
        with self.assertRaises(capacity.RPCCancelled):
            rpc.call("test/read-only-request", {})
        rpc.sock.send.assert_not_called()
        rpc.sock.sendall.assert_not_called()

    def test_real_unix_socket_handshake_ping_fragmentation_and_notifications(self):
        def handler(connection):
            opcode, payload = read_client_frame(connection)
            request = json.loads(payload)
            self.assertEqual(opcode, 1)
            self.assertEqual(request["method"], "thread/loaded/list")
            connection.sendall(server_frame({"method": "thread/status/changed", "params": {}}))
            response = json.dumps({"id": request["id"], "result": {"data": ["session"], "note": "x" * 200}}).encode()
            connection.sendall(server_frame(response[:20], final=False)
                               + server_frame(b"keepalive", opcode=9)
                               + server_frame(response[20:], opcode=0))
            self.assertEqual(read_client_frame(connection), (10, b"keepalive"))

        with LocalWebSocketServer(handler) as server:
            rpc = capacity.WebSocketRPC(server.path, timeout=1)
            try:
                response = rpc.call("thread/loaded/list", {})
                self.assertEqual(response["data"], ["session"])
                self.assertEqual(rpc.events[0]["method"], "thread/status/changed")
            finally:
                rpc.close()

    def test_remote_error_is_not_a_success(self):
        def handler(connection):
            _opcode, payload = read_client_frame(connection)
            request = json.loads(payload)
            connection.sendall(server_frame({"id": request["id"], "error": {
                "code": -32000, "message": "Thread unavailable",
            }}))

        with LocalWebSocketServer(handler) as server:
            rpc = capacity.WebSocketRPC(server.path, timeout=1)
            try:
                with self.assertRaisesRegex(capacity.RPCError, "Thread unavailable"):
                    rpc.call("thread/read", {"threadId": "gone"})
            finally:
                rpc.close()

    def test_interleaved_approval_request_receives_no_automatic_response(self):
        def handler(connection):
            _opcode, payload = read_client_frame(connection)
            request = json.loads(payload)
            connection.sendall(server_frame({
                "id": 99, "method": "item/commandExecution/requestApproval",
                "params": {"threadId": "user-session", "command": "needs user approval"},
            }) + server_frame({"id": request["id"], "result": {"data": []}}))
            # The next client frame must be its next explicit RPC, never a reply
            # resolving the approval on behalf of the user's Codex client.
            opcode, payload = read_client_frame(connection)
            next_request = json.loads(payload)
            self.assertEqual(opcode, 1)
            self.assertEqual(next_request.get("method"), "test/next")
            connection.sendall(server_frame({"id": next_request["id"], "result": {"ok": True}}))

        with LocalWebSocketServer(handler) as server:
            rpc = capacity.WebSocketRPC(server.path, timeout=1)
            try:
                self.assertEqual(rpc.call("thread/loaded/list", {}), {"data": []})
                self.assertEqual(rpc.events[0]["id"], 99)
                self.assertTrue(rpc.call("test/next", {})["ok"])
            finally:
                rpc.close()

    def test_large_masked_request_and_64_bit_length_response(self):
        def handler(connection):
            _opcode, payload = read_client_frame(connection)
            request = json.loads(payload)
            self.assertEqual(len(request["params"]["payload"]), 70000)
            connection.sendall(server_frame({"id": request["id"], "result": {"payload": "x" * 70000}}))

        with LocalWebSocketServer(handler) as server:
            rpc = capacity.WebSocketRPC(server.path, timeout=1)
            try:
                response = rpc.call("test", {"payload": "y" * 70000})
                self.assertEqual(len(response["payload"]), 70000)
            finally:
                rpc.close()

    def test_socket_timeout_does_not_become_success(self):
        rpc = capacity.WebSocketRPC.__new__(capacity.WebSocketRPC)
        rpc.sock = mock.Mock()
        rpc.sock.recv.side_effect = socket.timeout("no response")
        rpc.buffer = bytearray()
        rpc.sequence = 0
        rpc.events = []
        with self.assertRaises(socket.timeout):
            rpc.call("thread/read", {"threadId": "missing"})

    def test_response_deadline_is_reported_as_failure(self):
        rpc = capacity.WebSocketRPC.__new__(capacity.WebSocketRPC)
        rpc.sock = mock.Mock()
        rpc.sequence = 0
        with mock.patch.object(capacity.time, "monotonic", side_effect=[0, 16]):
            with self.assertRaisesRegex(capacity.RPCError, "deadline exceeded"):
                rpc.call("thread/read", {"threadId": "missing"})


if __name__ == "__main__":
    unittest.main(verbosity=2)
