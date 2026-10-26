"""Installation checks using temporary directories and a mocked login service."""

import argparse
import contextlib
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
SPEC = importlib.util.spec_from_file_location("codex_whip_install_test", MODULE_PATH)
helper = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(helper)


class InstallationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.home = Path(self.temporary.name) / "home"
        self.home.mkdir()
        self.directory = self.home / "Library/Application Support/Codex Whip"
        self.codex_home = self.home / ".codex"
        self.plist = self.home / "Library/LaunchAgents/com.aktay.codex-keep-going.plist"
        self.command = self.home / ".local/bin/codex-whip"
        self.launch = subprocess.CompletedProcess([], 0, stdout="", stderr="")
        self.runner = self.enter(mock.patch.object(helper.subprocess, "run", return_value=self.launch))
        self.enter(mock.patch.object(helper.Path, "home", return_value=self.home))
        self.enter(mock.patch.object(helper, "agent_path", return_value=self.plist))
        self.enter(mock.patch.object(helper, "service_running", return_value=False))
        self.enter(mock.patch.object(helper.sys, "platform", "darwin"))
        self.enter(mock.patch.object(helper.time, "time", return_value=20000))
        self.enter(contextlib.redirect_stdout(io.StringIO()))

    def enter(self, context):
        result = context.__enter__()
        self.addCleanup(context.__exit__, None, None, None)
        return result

    def start(self, preserve_state=False, threads=()):
        helper.start_service(
            argparse.Namespace(thread=list(threads), preserve_state=preserve_state),
            self.directory, self.codex_home,
        )

    def existing_state(self):
        self.directory.mkdir(parents=True)
        state = {
            "version": 1,
            "enabled_at": 10000,
            "threads": ["selected-session"],
            "pending": {"selected-session": {"turn_id": "failure", "due_at": 20500,
                                                "model": "selected-model", "effort": "xhigh"}},
            "handled": {"earlier-session": {"turn_id": "earlier-failure", "outcome": "submitted",
                                             "retry_turn_id": "earlier-retry"}},
            "paused": {"paused-session": True},
            "last_error": None,
        }
        (self.directory / "state.json").write_text(json.dumps(state))
        (self.directory / "history.sqlite3").write_bytes(b"existing-history-must-stay")
        return state

    def test_fresh_start_installs_command_and_login_job(self):
        self.start(threads=["one-session"])
        state = json.loads((self.directory / "state.json").read_text())
        self.assertEqual(state["enabled_at"], 20000)
        self.assertEqual(state["threads"], ["one-session"])
        self.assertEqual(state["pending"], {})
        self.assertEqual(state["handled"], {})
        self.assertEqual(state["paused"], {})
        self.assertTrue(self.command.is_symlink())
        self.assertEqual(self.command.resolve(), MODULE_PATH.resolve())
        launch_agent = plistlib.loads(self.plist.read_bytes())
        self.assertEqual(launch_agent["Label"], "com.aktay.codex-keep-going")
        self.assertTrue(launch_agent["RunAtLoad"])
        self.assertIn(str(MODULE_PATH.resolve()), launch_agent["ProgramArguments"])
        self.assertIn(str(self.directory), launch_agent["ProgramArguments"])
        self.assertIn(str(self.codex_home), launch_agent["ProgramArguments"])
        self.assertEqual(launch_agent["ProgramArguments"][-1], "_run")
        self.runner.assert_called_once()
        self.assertEqual(self.runner.call_args.args[0][0:2], ["launchctl", "bootstrap"])

    def test_preserved_start_keeps_timers_journal_scope_and_history(self):
        original = self.existing_state()
        self.start(preserve_state=True)
        state = json.loads((self.directory / "state.json").read_text())
        for key in ("enabled_at", "threads", "pending", "handled", "paused"):
            self.assertEqual(state[key], original[key], key)
        self.assertEqual((self.directory / "history.sqlite3").read_bytes(), b"existing-history-must-stay")
        self.assertTrue(self.plist.exists())

    def test_fresh_restart_resets_retry_scope_but_retains_history(self):
        self.existing_state()
        self.start(preserve_state=False, threads=["new-session"])
        state = json.loads((self.directory / "state.json").read_text())
        self.assertEqual(state["enabled_at"], 20000)
        self.assertEqual(state["threads"], ["new-session"])
        self.assertEqual(state["pending"], {})
        self.assertEqual(state["handled"], {})
        self.assertEqual(state["paused"], {})
        self.assertEqual((self.directory / "history.sqlite3").read_bytes(), b"existing-history-must-stay")

    def test_preserve_flag_without_previous_state_installs_fresh(self):
        self.start(preserve_state=True)
        state = json.loads((self.directory / "state.json").read_text())
        self.assertEqual(state["enabled_at"], 20000)
        self.assertEqual(state["pending"], {})

    def test_existing_matching_command_is_kept_on_reinstall(self):
        self.command.parent.mkdir(parents=True)
        self.command.symlink_to(MODULE_PATH.resolve())
        self.start()
        self.assertEqual(self.command.resolve(), MODULE_PATH.resolve())
        self.assertTrue(self.plist.exists())

    def test_different_existing_command_is_never_replaced_or_started(self):
        self.command.parent.mkdir(parents=True)
        self.command.write_text("user's existing command")
        with self.assertRaisesRegex(RuntimeError, "Refusing to replace an existing command"):
            self.start()
        self.assertEqual(self.command.read_text(), "user's existing command")
        self.assertFalse(self.plist.exists())
        self.runner.assert_not_called()


if __name__ == "__main__":
    unittest.main(verbosity=2)
