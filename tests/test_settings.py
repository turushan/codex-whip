"""Preference validation and live scheduling against isolated state and fake RPCs."""

import argparse
import contextlib
import copy
import importlib.util
import io
import json
import math
from pathlib import Path
import signal
import sys
import tempfile
import unittest
from unittest import mock

from test_core import FakeRPC, capacity_turn


MODULE_PATH = Path(__file__).resolve().parents[1] / "codex_whip.py"
sys.path.insert(0, str(MODULE_PATH.parent))
SPEC = importlib.util.spec_from_file_location("codex_whip_settings_test", MODULE_PATH)
helper = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(helper)


def preferences(**changes):
    return {**helper.DEFAULT_SETTINGS, **changes}


class SettingsTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name) / "state"

    def command(self, name, payload=""):
        output, error = io.StringIO(), io.StringIO()
        with (mock.patch.object(helper.sys, "stdin", io.StringIO(payload)),
              mock.patch.object(helper, "WebSocketRPC", side_effect=AssertionError("No network")),
              contextlib.redirect_stdout(output), contextlib.redirect_stderr(error)):
            status = helper.main(["--state-dir", str(self.directory), name])
        return status, output.getvalue(), error.getvalue()

    def test_settings_returns_defaults_without_creating_files(self):
        status, output, error = self.command("settings")
        self.assertEqual(status, 0, error)
        self.assertEqual(json.loads(output), {"settings": helper.DEFAULT_SETTINGS, "defaults": helper.DEFAULT_SETTINGS})
        self.assertFalse(self.directory.exists())
        self.assertEqual(helper.DEFAULT_SETTINGS["retry_seconds"], 180)
        self.assertEqual(helper.DEFAULT_SETTINGS["scan_seconds"], 300)

    def test_configure_persists_private_settings_without_touching_state_or_history(self):
        self.directory.mkdir()
        (self.directory / "state.json").write_bytes(b"existing retry state")
        (self.directory / "history.sqlite3").write_bytes(b"existing history")
        value = preferences(retry_seconds=600, scan_seconds=15, message="Keep this exact model.\nContinue unfinished work.")
        status, output, error = self.command("configure", json.dumps(value))
        self.assertEqual(status, 0, error)
        self.assertEqual(json.loads(output), {"settings": value, "defaults": helper.DEFAULT_SETTINGS})
        self.assertEqual(helper.read_settings(self.directory), value)
        self.assertEqual((self.directory / "state.json").read_bytes(), b"existing retry state")
        self.assertEqual((self.directory / "history.sqlite3").read_bytes(), b"existing history")
        self.assertEqual((self.directory / "settings.json").stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.directory.stat().st_mode & 0o777, 0o700)

    def test_reset_to_defaults_preserves_other_files(self):
        helper.save_settings(self.directory, preferences(retry_seconds=600, message="Custom continuation"))
        (self.directory / "state.json").write_bytes(b"saved activation and timers")
        result, _, error = self.command("configure", json.dumps(helper.DEFAULT_SETTINGS))
        self.assertEqual(result, 0, error)
        self.assertEqual(helper.read_settings(self.directory), helper.DEFAULT_SETTINGS)
        self.assertEqual((self.directory / "state.json").read_bytes(), b"saved activation and timers")

    def test_invalid_values_do_not_overwrite_existing_valid_preferences(self):
        helper.save_settings(self.directory, preferences(message="Existing continuation"))
        before = (self.directory / "settings.json").read_bytes()
        invalid = [
            preferences(retry_seconds=True), preferences(retry_seconds=300.0),
            preferences(retry_seconds=59), preferences(retry_seconds=86401),
            preferences(scan_seconds=False), preferences(scan_seconds=14),
            preferences(scan_seconds=3601), preferences(scan_seconds=math.nan),
            preferences(retry_seconds=math.inf), preferences(message=" \n\t"),
            preferences(message="x" * 4001), preferences(message=False),
            {**preferences(), "extra": "unknown"}, {"retry_seconds": 300}, [], None,
        ]
        for value in invalid:
            with self.subTest(value=value):
                status, output, error = self.command("configure", json.dumps(value))
                self.assertEqual(status, 1)
                self.assertEqual(output, "")
                self.assertTrue(error)
                self.assertEqual((self.directory / "settings.json").read_bytes(), before)

    def test_range_boundaries_are_accepted(self):
        for retry, scan in ((60, 15), (86400, 3600)):
            with self.subTest(retry=retry, scan=scan):
                value = preferences(retry_seconds=retry, scan_seconds=scan, message="x" * 4000)
                self.assertEqual(helper.validate_settings(value), value)

    def test_malformed_settings_surface_error_and_are_not_silently_reset(self):
        self.directory.mkdir()
        path = self.directory / "settings.json"
        path.write_bytes(b"{broken preferences")
        status, output, error = self.command("settings")
        self.assertEqual(status, 1)
        self.assertEqual(output, "")
        self.assertIn("settings.json", error)
        self.assertEqual(path.read_bytes(), b"{broken preferences")

    def test_invalid_json_and_multiple_objects_do_not_create_settings(self):
        for payload in ("{", json.dumps(preferences()) + "\n{}"):
            with self.subTest(payload=payload):
                status, output, _error = self.command("configure", payload)
                self.assertEqual(status, 1)
                self.assertEqual(output, "")
                self.assertFalse(self.directory.exists())

    def test_scheduler_recomputes_from_last_scan_when_cadence_changes(self):
        scheduler = helper.ScanScheduler()
        self.assertTrue(scheduler.due(100, 60))
        scheduler.finished(100)
        self.assertFalse(scheduler.due(114.9, 15))
        self.assertTrue(scheduler.due(115, 15))
        self.assertFalse(scheduler.due(120, 60))
        self.assertTrue(scheduler.due(120, 15))
        scheduler.finished(120)
        self.assertFalse(scheduler.due(134.9, 15))
        self.assertTrue(scheduler.due(135, 15))


class EngineSettingsTests(unittest.TestCase):
    def setUp(self):
        self.rpc, self.events, self.saved = FakeRPC(), [], []
        self.state = {"enabled_at": 1000}
        self.engine = self.new_engine()

    def new_engine(self):
        return helper.RetryEngine(self.state, lambda value: self.saved.append(copy.deepcopy(value)),
                                  lambda event, **fields: self.events.append((event, fields)),
                                  interval=300, scan_interval=60)

    def test_custom_message_changes_only_turn_start_input(self):
        text = "Use this model. Keep going with the unfinished changes."
        self.engine.apply_settings(preferences(retry_seconds=60, message=text))
        self.engine.step(self.rpc, 1100)
        self.engine.step(self.rpc, 1160)
        self.assertEqual(self.rpc.sends(), [{"threadId": "user-session", "input": [{"type": "text", "text": text}]}])
        self.assertFalse(any(method == "thread/resume" for method, _ in self.rpc.calls))
        self.assertEqual(self.state["enabled_at"], 1000)

    def test_longer_and_shorter_waits_keep_the_original_wait_start(self):
        self.engine.step(self.rpc, 1100)
        self.engine.apply_settings(preferences(retry_seconds=600))
        self.assertEqual(self.state["pending"]["user-session"]["due_at"], 1700)
        self.engine.step(self.rpc, 1400)
        self.assertEqual(self.rpc.sends(), [])
        self.engine.apply_settings(preferences(retry_seconds=60))
        self.assertEqual(self.state["pending"]["user-session"]["due_at"], 1160)
        self.assertEqual(self.state["pending"]["user-session"]["wait_started_at"], 1100)
        self.engine.step(self.rpc, 1401)
        self.assertEqual(len(self.rpc.sends()), 1)

    def test_legacy_pending_timer_is_anchored_once_across_changes_and_restart(self):
        self.state["pending"]["user-session"] = {"turn_id": "failure", "due_at": 1400,
                                                    "detected_at": 1100, "model": "chosen", "effort": "xhigh"}
        self.engine.apply_settings(preferences(retry_seconds=600))
        self.assertEqual(self.state["pending"]["user-session"]["due_at"], 1700)
        self.engine = self.new_engine()
        self.engine.apply_settings(preferences(retry_seconds=1200))
        self.assertEqual(self.state["pending"]["user-session"]["due_at"], 2300)
        self.assertEqual(self.state["pending"]["user-session"]["wait_started_at"], 1100)

    def active_retry(self):
        self.state["handled"]["user-session"] = {"turn_id": "original", "outcome": "submitted",
                                                 "retry_turn_id": "retry", "at": 1000}
        self.rpc.threads["user-session"]["status"] = {"type": "active", "activeFlags": []}
        self.rpc.turns["user-session"] = capacity_turn("retry", status="inProgress", error=None)

    def test_discovery_cadence_change_resets_health_but_tracking_stays_frequent(self):
        self.active_retry()
        self.engine.step(self.rpc, 1100)
        self.engine.step(self.rpc, 1160)
        self.engine.apply_settings(preferences(scan_seconds=120))
        self.assertNotIn("healthy_since", self.state["handled"]["user-session"])
        self.engine.step(self.rpc, 1280)
        self.assertFalse(any(event == "retry_result" for event, _ in self.events))
        for now in (1310, 1340, 1370, 1400):
            self.engine.step(self.rpc, now)
        result = next(fields for event, fields in self.events if event == "retry_result")
        self.assertEqual(result["status"], "successful")
        self.assertEqual(result["occurred_at"], 1400)

    def test_long_gap_resets_health_even_with_long_discovery_cadence(self):
        self.active_retry()
        self.engine.apply_settings(preferences(scan_seconds=120))
        self.engine.step(self.rpc, 1100)
        self.engine.step(self.rpc, 1191)
        self.assertEqual(self.state["handled"]["user-session"]["healthy_since"], 1191)
        self.assertFalse(any(event == "retry_result" for event, _ in self.events))

    def test_settings_preserve_journal_and_activation(self):
        entry = {"turn_id": "older", "outcome": "submitted", "retry_turn_id": "older-retry", "result_status": "successful"}
        self.state["handled"]["other-session"] = copy.deepcopy(entry)
        self.engine.apply_settings(preferences(retry_seconds=600, scan_seconds=15, message="New continuation"))
        self.assertEqual(self.state["handled"]["other-session"], entry)
        self.assertEqual(self.state["enabled_at"], 1000)


class WorkerSettingsTests(unittest.TestCase):
    def test_invalid_live_settings_pause_scans_until_repaired_without_losing_retry_state(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            pending = {"session": {"turn_id": "failure", "due_at": 1400, "detected_at": 1100}}
            (directory / "state.json").write_text(json.dumps({
                "version": 1, "enabled_at": 1000, "pending": pending, "handled": {}, "paused": {},
            }))
            clock, handlers, scans = [100], {}, []
            engine, rpc, history, logger = mock.Mock(), mock.Mock(), mock.Mock(), mock.Mock()
            engine.step.side_effect = lambda _rpc, _now: scans.append(clock[0])

            def current_preferences(_directory):
                if 105 <= clock[0] < 125:
                    raise helper.SettingsError("Invalid settings.json: malformed preferences")
                return preferences(scan_seconds=15)

            def sleep(_seconds):
                clock[0] += 1
                if clock[0] >= 130:
                    handlers[signal.SIGTERM](signal.SIGTERM, None)

            with (mock.patch.object(helper, "configured_parent_pid", return_value=None),
                  mock.patch.object(helper.os, "umask"),
                  mock.patch.object(helper.signal, "signal", side_effect=lambda event, callback: handlers.update({event: callback})),
                  mock.patch.object(helper, "RetryEngine", return_value=engine),
                  mock.patch.object(helper, "History", return_value=history),
                  mock.patch.object(helper, "log_emitter", return_value=logger),
                  mock.patch.object(helper, "WebSocketRPC", return_value=rpc),
                  mock.patch.object(helper, "resolve_socket", return_value=directory / "unused.sock"),
                  mock.patch.object(helper, "read_settings", side_effect=current_preferences),
                  mock.patch.object(helper.time, "monotonic", side_effect=lambda: clock[0]),
                  mock.patch.object(helper.time, "time", side_effect=lambda: clock[0]),
                  mock.patch.object(helper.time, "sleep", side_effect=sleep)):
                helper.run_worker(directory, directory / "codex")
            self.assertEqual(scans, [100, 125])
            self.assertEqual(helper.read_json(directory / "state.json")["pending"], pending)
            self.assertEqual(helper.read_json(directory / "state.json")["enabled_at"], 1000)
            self.assertIsNone(helper.read_json(directory / "state.json").get("last_error"))
            self.assertEqual(sum(call.args[0] == "settings_error" for call in logger.call_args_list), 1)
            self.assertGreaterEqual(engine.reset_observations.call_count, 20)

    def test_live_changes_are_polled_each_second_without_exceeding_scan_cadence(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            (directory / "state.json").write_text(json.dumps({"version": 1, "enabled_at": 1}))
            clock, handlers, scans = [100], {}, []
            engine, rpc, history = mock.Mock(), mock.Mock(), mock.Mock()
            engine.step.side_effect = lambda _rpc, _now: scans.append(clock[0])

            def current_preferences(_directory):
                scan = 15 if clock[0] < 105 or clock[0] == 125 else 60
                return preferences(scan_seconds=scan)

            def sleep(_seconds):
                clock[0] += 1
                if clock[0] >= 140:
                    handlers[signal.SIGTERM](signal.SIGTERM, None)

            with (mock.patch.object(helper, "configured_parent_pid", return_value=None),
                  mock.patch.object(helper.os, "umask"),
                  mock.patch.object(helper.signal, "signal", side_effect=lambda event, callback: handlers.update({event: callback})),
                  mock.patch.object(helper, "RetryEngine", return_value=engine),
                  mock.patch.object(helper, "History", return_value=history),
                  mock.patch.object(helper, "log_emitter", return_value=mock.Mock()),
                  mock.patch.object(helper, "WebSocketRPC", return_value=rpc),
                  mock.patch.object(helper, "resolve_socket", return_value=directory / "unused.sock"),
                  mock.patch.object(helper, "read_settings", side_effect=current_preferences) as reader,
                  mock.patch.object(helper.time, "monotonic", side_effect=lambda: clock[0]),
                  mock.patch.object(helper.time, "time", side_effect=lambda: clock[0]),
                  mock.patch.object(helper.time, "sleep", side_effect=sleep)):
                helper.run_worker(directory, directory / "codex")
            self.assertEqual(scans, [100, 125])
            self.assertGreaterEqual(reader.call_count, 40)
            self.assertEqual([call.args[0]["scan_seconds"] for call in engine.apply_settings.call_args_list], [15, 60, 15, 60])


if __name__ == "__main__":
    unittest.main(verbosity=2)
