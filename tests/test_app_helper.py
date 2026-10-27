"""Native-app helper commands, isolated from the user's services and Codex."""

import argparse
import contextlib
import fcntl
import importlib.util
import io
import json
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


MODULE_PATH = Path(__file__).resolve().parents[1] / "codex_whip.py"
sys.path.insert(0, str(MODULE_PATH.parent))
SPEC = importlib.util.spec_from_file_location("codex_whip_app_test", MODULE_PATH)
helper = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(helper)


class AppHelperTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.home = self.root / "home"
        self.home.mkdir()
        self.directory = self.root / "custom-state"
        self.home_patch = mock.patch.object(helper.Path, "home", return_value=self.home)
        self.home_patch.start()
        self.addCleanup(self.home_patch.stop)
        self.environment = mock.patch.dict(helper.os.environ, {"CODEX_HOME": str(self.home / ".codex")})
        self.environment.start()
        self.addCleanup(self.environment.stop)
        self.network = mock.patch.object(helper, "WebSocketRPC", side_effect=AssertionError("No Codex calls"))
        self.network.start()
        self.addCleanup(self.network.stop)
        self.process = mock.patch.object(helper.subprocess, "run", side_effect=AssertionError("No real services"))
        self.process.start()
        self.addCleanup(self.process.stop)

    def saved_state(self, directory=None):
        directory = directory or self.directory
        directory.mkdir(parents=True)
        state = {
            "version": 1, "enabled_at": 10000, "threads": ["chosen-session"],
            "pending": {"chosen-session": {"turn_id": "failure", "due_at": 20500,
                                             "model": "selected-model", "effort": "xhigh"}},
            "handled": {"earlier-session": {"turn_id": "earlier-failure", "outcome": "submitted",
                                             "retry_turn_id": "retry"}},
            "paused": {"paused-session": True}, "last_error": None,
        }
        (directory / "state.json").write_text(json.dumps(state, indent=4) + "\n")
        return state

    def cli_job(self, arguments=None, environment=None):
        path = helper.agent_path()
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(plistlib.dumps({
            "Label": helper.LABEL,
            "ProgramArguments": arguments if arguments is not None else ["python3", str(MODULE_PATH), "_run"],
            "EnvironmentVariables": environment if environment is not None else {},
        }))
        return path

    def test_prepare_initializes_missing_state_in_custom_directory_without_services(self):
        with mock.patch.object(helper, "stop_service", side_effect=AssertionError("Custom state must be isolated")):
            result = helper.main(["--state-dir", str(self.directory), "prepare"])
        self.assertEqual(result, 0)
        state = json.loads((self.directory / "state.json").read_text())
        self.assertEqual(state["version"], 1)
        self.assertEqual(state["pending"], {})
        self.assertEqual(state["handled"], {})
        self.assertEqual(state["paused"], {})
        self.assertEqual(self.directory.stat().st_mode & 0o777, 0o700)
        self.assertEqual((self.directory / "state.json").stat().st_mode & 0o777, 0o600)

    def test_prepare_preserves_state_and_existing_history_bytes(self):
        state = self.saved_state()
        history = self.directory / "history.sqlite3"
        history.write_bytes(b"existing-history")
        before = (self.directory / "state.json").read_bytes()
        with mock.patch.object(helper, "stop_service", side_effect=AssertionError("Custom state must be isolated")):
            helper.prepare_state(self.directory)
        self.assertEqual((self.directory / "state.json").read_bytes(), before)
        self.assertEqual(history.read_bytes(), b"existing-history")
        self.assertEqual(helper.read_json(self.directory / "state.json"), state)

    def test_default_prepare_stops_cli_job_before_preserving_latest_state(self):
        directory = helper.default_state_directory()
        self.saved_state(directory)
        self.cli_job()
        latest = {"version": 1, "enabled_at": 123, "pending": {"updated": {"due_at": 999}}}

        def stop_and_flush_latest_state():
            (directory / "state.json").write_text(json.dumps(latest))

        with (mock.patch.object(helper.sys, "platform", "darwin"),
              mock.patch.object(helper, "service_running", return_value=True),
              mock.patch.object(helper, "stop_service", side_effect=stop_and_flush_latest_state) as stop):
            helper.prepare_state(directory)
        stop.assert_called_once_with()
        self.assertEqual(helper.read_json(directory / "state.json"), latest)

    def test_default_prepare_removes_unloaded_cli_job_file(self):
        directory = helper.default_state_directory()
        self.cli_job()
        with (mock.patch.object(helper.sys, "platform", "darwin"),
              mock.patch.object(helper, "service_running", return_value=False),
              mock.patch.object(helper, "stop_service") as stop):
            helper.prepare_state(directory)
        stop.assert_called_once_with()

    def assert_refused_cli_job(self, arguments=None, environment=None, malformed=None, missing=False):
        directory = helper.default_state_directory()
        self.saved_state(directory)
        path = self.cli_job(arguments, environment)
        if malformed is not None:
            path.write_bytes(malformed)
        if missing:
            path.unlink()
        state_before = (directory / "state.json").read_bytes()
        job_before = path.read_bytes() if path.exists() else None
        with (mock.patch.object(helper.sys, "platform", "darwin"),
              mock.patch.object(helper, "service_running", return_value=True),
              mock.patch.object(helper, "stop_service") as stop):
            with self.assertRaisesRegex(RuntimeError, "Keep that service|Keep that.*service"):
                helper.prepare_state(directory)
        stop.assert_not_called()
        self.assertEqual((directory / "state.json").read_bytes(), state_before)
        self.assertEqual(path.read_bytes() if path.exists() else None, job_before)

    def test_prepare_refuses_cli_job_with_custom_state_directory(self):
        self.assert_refused_cli_job(arguments=[
            "python3", str(MODULE_PATH), "--state-dir", str(self.directory), "_run",
        ])

    def test_prepare_refuses_cli_job_with_custom_codex_home_argument(self):
        self.assert_refused_cli_job(arguments=[
            "python3", str(MODULE_PATH), "--codex-home=" + str(self.root / "other-codex"), "_run",
        ])

    def test_prepare_refuses_cli_job_with_custom_codex_home_environment(self):
        self.assert_refused_cli_job(environment={"CODEX_HOME": str(self.root / "other-codex")})

    def test_prepare_refuses_malformed_existing_plist(self):
        self.assert_refused_cli_job(malformed=b"invalid plist")

    def test_prepare_refuses_running_cli_job_without_launch_file(self):
        self.assert_refused_cli_job(missing=True)

    def test_prepare_resolves_explicit_default_paths_and_argument_precedence(self):
        directory = helper.default_state_directory()
        self.saved_state(directory)
        self.cli_job(arguments=[
            "python3", str(MODULE_PATH), "--state-dir", str(directory / "unused/.."),
            "--codex-home", str(self.home / ".codex"), "_run",
        ], environment={"CODEX_HOME": str(self.root / "overridden-home")})
        with (mock.patch.object(helper.sys, "platform", "darwin"),
              mock.patch.object(helper, "service_running", return_value=True),
              mock.patch.object(helper, "stop_service") as stop):
            helper.prepare_state(directory, self.home / ".codex")
        stop.assert_called_once_with()

    def test_prepare_accepts_matching_recorded_codex_home_environment(self):
        directory = helper.default_state_directory()
        self.saved_state(directory)
        codex_home = self.root / "shared-codex"
        self.cli_job(environment={"CODEX_HOME": str(codex_home)})
        with (mock.patch.object(helper.sys, "platform", "darwin"),
              mock.patch.object(helper, "service_running", return_value=True),
              mock.patch.object(helper, "stop_service") as stop,
              mock.patch.dict(helper.os.environ, {"CODEX_HOME": str(codex_home)})):
            helper.prepare_state(directory)
        stop.assert_called_once_with()

    def test_custom_prepare_does_not_even_inspect_default_job(self):
        with (mock.patch.object(helper.sys, "platform", "darwin"),
              mock.patch.object(helper, "service_running", side_effect=AssertionError("Not this job")),
              mock.patch.object(helper, "agent_path", side_effect=AssertionError("Not this job"))):
            helper.prepare_state(self.directory)

    def test_dashboard_for_missing_state_is_json_only_and_creates_nothing(self):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            result = helper.main(["--state-dir", str(self.directory), "dashboard"])
        self.assertEqual(result, 0)
        value = json.loads(output.getvalue())
        self.assertEqual(set(value), {"state", "history", "running"})
        self.assertEqual(value["state"], {})
        self.assertFalse(value["history"]["available"])
        self.assertFalse(value["running"])
        self.assertFalse(self.directory.exists())

    def test_dashboard_preserves_state_and_database_and_ignores_stale_pid(self):
        state = self.saved_state()
        history = helper.History(self.directory)
        history.record("waiting", thread_id="chosen-session", turn_id="failure")
        history.close()
        (self.directory / "worker.pid").write_text("12345")
        state_before = (self.directory / "state.json").read_bytes()
        history_before = (self.directory / "history.sqlite3").read_bytes()
        entries_before = sorted(path.name for path in self.directory.iterdir())
        result = helper.dashboard(self.directory)
        self.assertEqual(result["state"], state)
        self.assertEqual(result["history"]["capacity"], 1)
        self.assertFalse(result["running"])
        self.assertEqual((self.directory / "state.json").read_bytes(), state_before)
        self.assertEqual((self.directory / "history.sqlite3").read_bytes(), history_before)
        self.assertEqual(sorted(path.name for path in self.directory.iterdir()), entries_before)

    def test_dashboard_running_uses_held_worker_lock(self):
        self.saved_state()
        path = self.directory / "worker.lock"
        with path.open("w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.assertTrue(helper.dashboard(self.directory)["running"])
            fcntl.flock(lock, fcntl.LOCK_UN)
        self.assertFalse(helper.dashboard(self.directory)["running"])
        self.assertEqual(path.read_bytes(), b"")

    def test_frozen_install_runs_executable_without_temporary_source_path(self):
        executable = self.root / "Contents/Helpers/whip-helper"
        executable.parent.mkdir(parents=True)
        executable.write_bytes(b"test executable")
        plist = self.home / "Library/LaunchAgents/com.turushan.codex-whip.plist"
        args = argparse.Namespace(thread=[], preserve_state=False)
        completed = subprocess.CompletedProcess([], 0, stdout="", stderr="")
        with (mock.patch.object(helper.sys, "platform", "darwin"),
              mock.patch.object(helper.sys, "frozen", True, create=True),
              mock.patch.object(helper.sys, "executable", str(executable)),
              mock.patch.object(helper, "service_running", return_value=False),
              mock.patch.object(helper, "agent_path", return_value=plist),
              mock.patch.object(helper.subprocess, "run", return_value=completed),
              contextlib.redirect_stdout(io.StringIO())):
            helper.start_service(args, self.directory, self.home / ".codex")
        program = plistlib.loads(plist.read_bytes())["ProgramArguments"]
        self.assertEqual(program[0], str(executable.resolve()))
        self.assertEqual(program[1], "--state-dir")
        self.assertNotIn(str(MODULE_PATH), program)
        self.assertEqual((self.home / ".local/bin/codex-whip").resolve(), executable.resolve())

    def test_cli_start_does_not_install_another_job_when_native_worker_is_running(self):
        self.saved_state()
        before = (self.directory / "state.json").read_bytes()
        output = io.StringIO()
        with (mock.patch.object(helper.sys, "platform", "darwin"),
              mock.patch.object(helper, "worker_running", return_value=True),
              mock.patch.object(helper, "service_running", side_effect=AssertionError("Worker already owns state")),
              contextlib.redirect_stdout(output)):
            helper.start_service(argparse.Namespace(thread=[], preserve_state=False), self.directory, self.home / ".codex")
        self.assertIn("Already enabled", output.getvalue())
        self.assertEqual((self.directory / "state.json").read_bytes(), before)
        self.assertFalse((self.home / ".local/bin/codex-whip").exists())
        self.assertFalse(helper.agent_path().exists())

    def test_cli_status_recognizes_native_worker_without_a_launch_agent(self):
        self.saved_state()
        output = io.StringIO()
        with (mock.patch.object(helper, "worker_running", return_value=True),
              mock.patch.object(helper, "service_running", side_effect=AssertionError("No CLI job needed")),
              contextlib.redirect_stdout(output)):
            helper.status(self.directory)
        self.assertTrue(output.getvalue().startswith("Enabled\n"))

    def test_invalid_or_missing_parent_pid_keeps_normal_cli_mode(self):
        for value in (None, "", "invalid", "0", "-10"):
            with self.subTest(value=value), mock.patch.dict(helper.os.environ):
                helper.os.environ.pop("CODEX_WHIP_PARENT_PID", None)
                if value is not None:
                    helper.os.environ["CODEX_WHIP_PARENT_PID"] = value
                self.assertIsNone(helper.configured_parent_pid())
        with mock.patch.dict(helper.os.environ, {"CODEX_WHIP_PARENT_PID": "123"}):
            self.assertEqual(helper.configured_parent_pid(), 123)

    def test_process_liveness_accepts_existing_process_and_permission_denial(self):
        for failure in (None, PermissionError("Not permitted")):
            with self.subTest(failure=failure), mock.patch.object(helper.os, "kill", side_effect=failure) as probe:
                self.assertTrue(helper.process_alive(123))
                probe.assert_called_once_with(123, 0)

    def test_process_liveness_rejects_missing_process(self):
        with mock.patch.object(helper.os, "kill", side_effect=ProcessLookupError("No such process")) as probe:
            self.assertFalse(helper.process_alive(123))
            probe.assert_called_once_with(123, 0)

    def test_missing_codex_error_opens_with_the_words_the_native_app_recognizes(self):
        # The menu replaces this error, socket path included, with plain words.
        source = (MODULE_PATH.parent / "native/App.swift").read_text()
        recognized = source.split('missingCodexMessage = "', 1)[1].split('"', 1)[0]
        with self.assertRaises(helper.RPCError) as raised:
            helper.resolve_socket(self.home / ".codex")
        self.assertTrue(str(raised.exception).startswith(recognized + ":"), str(raised.exception))

    def exercise_parent_shutdown(self, during_step, initial_parent=123, lose_ui=False):
        self.saved_state()
        actual_parent = initial_parent
        ui_alive = True
        engine = mock.Mock()
        captured = {}

        def engine_factory(*_args, **kwargs):
            captured["should_stop"] = kwargs["should_stop"]
            return engine

        def step(_rpc, _now):
            nonlocal actual_parent, ui_alive
            self.assertFalse(captured["should_stop"]())
            if during_step:
                if lose_ui:
                    ui_alive = False
                else:
                    actual_parent = 1
                self.assertTrue(captured["should_stop"]())

        def sleep(_duration):
            nonlocal actual_parent
            actual_parent = 1

        engine.step.side_effect = step
        rpc = mock.Mock()
        history = mock.Mock()
        with (mock.patch.dict(helper.os.environ, {"CODEX_WHIP_PARENT_PID": "123"}),
              mock.patch.object(helper.os, "getppid", side_effect=lambda: actual_parent),
              mock.patch.object(helper, "process_alive", side_effect=lambda _pid: ui_alive) as liveness,
              mock.patch.object(helper.os, "umask"),
              mock.patch.object(helper.signal, "signal"),
              mock.patch.object(helper, "RetryEngine", side_effect=engine_factory),
              mock.patch.object(helper, "History", return_value=history),
              mock.patch.object(helper, "log_emitter", return_value=mock.Mock()),
              mock.patch.object(helper, "WebSocketRPC", return_value=rpc),
              mock.patch.object(helper, "resolve_socket", return_value=self.root / "unused.sock"),
              mock.patch.object(helper.time, "sleep", side_effect=sleep) as sleeper):
            helper.run_worker(self.directory, self.home / ".codex")
        engine.step.assert_called_once()
        self.assertTrue(all(call.args == (123,) for call in liveness.call_args_list))
        if during_step:
            sleeper.assert_not_called()
        else:
            sleeper.assert_called_once_with(1)
        rpc.close.assert_called_once_with()
        history.close.assert_called_once_with()
        self.assertFalse((self.directory / "worker.pid").exists())

    def test_parent_death_reaches_engine_stop_predicate_before_submission(self):
        self.exercise_parent_shutdown(during_step=True)

    def test_worker_stops_during_scan_sleep_after_parent_death(self):
        self.exercise_parent_shutdown(during_step=False)

    def test_frozen_worker_accepts_distinct_bootloader_parent(self):
        self.exercise_parent_shutdown(during_step=True, initial_parent=456)

    def test_ui_exit_stops_worker_while_bootloader_parent_is_unchanged(self):
        self.exercise_parent_shutdown(during_step=True, initial_parent=456, lose_ui=True)


if __name__ == "__main__":
    unittest.main(verbosity=2)
