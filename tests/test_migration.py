"""Default-directory and managed-command migration without real login services."""

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
SPEC = importlib.util.spec_from_file_location("codex_whip_migration_test", MODULE_PATH)
helper = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(helper)


class MigrationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.home = self.root / "home"
        self.home.mkdir()
        self.enter(mock.patch.object(helper.Path, "home", return_value=self.home))
        self.enter(mock.patch.object(helper.sys, "platform", "darwin"))
        self.enter(mock.patch.dict(helper.os.environ, {"CODEX_HOME": str(self.home / ".codex")}))
        self.running = self.enter(mock.patch.object(helper, "service_running", return_value=False))
        self.stop = self.enter(mock.patch.object(helper, "stop_service"))
        self.runner = self.enter(mock.patch.object(helper.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "", "")))
        self.enter(mock.patch.object(helper, "WebSocketRPC", side_effect=AssertionError("No Codex calls")))
        self.old = helper.legacy_state_directory()
        self.new = helper.default_state_directory()
        self.old_command = self.home / ".local/bin/codex-keep-going"
        self.new_command = self.home / ".local/bin/codex-whip"

    def enter(self, context):
        value = context.__enter__()
        self.addCleanup(context.__exit__, None, None, None)
        return value

    def legacy_tree(self):
        self.old.mkdir(parents=True, mode=0o700)
        state = {
            "version": 1, "enabled_at": 1000, "threads": ["session"],
            "pending": {"session": {"turn_id": "failure", "due_at": 1400, "detected_at": 1100,
                                      "model": "selected-model", "effort": "xhigh"}},
            "handled": {"other": {"turn_id": "older", "outcome": "cancelled"}},
            "paused": {"paused-session": True}, "last_error": None,
        }
        helper.atomic_json(self.old / "state.json", state)
        (self.old / "worker.lock").touch(mode=0o600)
        (self.old / "worker.log").write_bytes(b"existing log\n")
        (self.old / "extra-private-file").write_bytes(b"preserve every file")
        (self.old / "extra-private-file").chmod(0o640)
        helper.save_settings(self.old, {**helper.DEFAULT_SETTINGS, "retry_seconds": 600, "message": "Existing custom message"})
        history = helper.History(self.old, clock=lambda: 1200)
        history.record("retry", thread_id="finished-session", turn_id="original", retry_turn_id="retry")
        history.record("retry_result", thread_id="finished-session", turn_id="retry", status="successful", capacity=False)
        history.close()
        return state

    def write_job(self, state_directory=None, codex_home=None):
        path = helper.agent_path()
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(plistlib.dumps({
            "Label": helper.LABEL,
            "ProgramArguments": ["python3", "legacy.py", "--state-dir", str(state_directory or self.old),
                                 "--codex-home", str(codex_home or self.home / ".codex"), "_run"],
            "EnvironmentVariables": {"PYTHONUNBUFFERED": "1"},
        }))
        return path

    def managed_old_source(self):
        source = self.root / "legacy-source/codex_keep_going.py"
        source.parent.mkdir()
        source.write_text('LABEL = "com.aktay.codex-keep-going"\ndef run_worker():\n    pass\n')
        self.old_command.parent.mkdir(parents=True, exist_ok=True)
        self.old_command.symlink_to(source)
        return source

    def test_default_migration_moves_all_files_with_history_settings_and_permissions(self):
        state = self.legacy_tree()
        before = {path.name: (path.read_bytes(), path.stat().st_mode & 0o777) for path in self.old.iterdir()}
        self.assertTrue(helper.prepare_state(self.new))
        self.assertFalse(self.old.exists())
        self.assertEqual(helper.read_json(self.new / "state.json"), state)
        for name, (contents, permissions) in before.items():
            self.assertEqual((self.new / name).read_bytes(), contents, name)
            self.assertEqual((self.new / name).stat().st_mode & 0o777, permissions, name)
        self.assertEqual(helper.read_report(self.new, now=1201)["successful"], 1)
        self.assertEqual(helper.read_settings(self.new)["message"], "Existing custom message")
        self.assertFalse(self.new_command.exists())
        self.stop.assert_not_called()

    def test_conflicting_directories_are_left_untouched_before_stopping_any_job(self):
        self.legacy_tree()
        self.new.mkdir()
        (self.new / "state.json").write_bytes(b"another installation")
        job = self.write_job()
        before = job.read_bytes()
        with self.assertRaisesRegex(RuntimeError, "Both.*state directories"):
            helper.prepare_state(self.new)
        self.assertEqual((self.new / "state.json").read_bytes(), b"another installation")
        self.assertTrue((self.old / "state.json").exists())
        self.assertEqual(job.read_bytes(), before)
        self.stop.assert_not_called()

    def test_active_native_old_worker_prevents_all_migration_changes(self):
        self.legacy_tree()
        self.managed_old_source()
        with (self.old / "worker.lock").open("r") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            with self.assertRaisesRegex(RuntimeError, "worker is still running"):
                helper.prepare_state(self.new)
        self.assertTrue(self.old.exists())
        self.assertFalse(self.new.exists())
        self.assertTrue(self.old_command.is_symlink())
        self.assertFalse(self.new_command.exists())
        self.stop.assert_not_called()

    def test_matching_old_cli_job_is_stopped_before_its_state_moves(self):
        self.legacy_tree()
        self.write_job()
        self.running.return_value = True
        with (self.old / "worker.lock").open("r") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.stop.side_effect = lambda: fcntl.flock(lock, fcntl.LOCK_UN)
            self.assertTrue(helper.prepare_state(self.new))
        self.stop.assert_called_once_with()
        self.assertTrue((self.new / "state.json").exists())
        self.assertFalse(self.old.exists())

    def assert_custom_job_refused(self, custom_home):
        self.legacy_tree()
        self.managed_old_source()
        path = self.write_job(
            state_directory=self.old if custom_home else self.root / "custom-state",
            codex_home=self.root / "custom-codex" if custom_home else self.home / ".codex",
        )
        before = path.read_bytes()
        with self.assertRaisesRegex(RuntimeError, "different state directory or Codex home"):
            helper.prepare_state(self.new)
        self.assertFalse(self.new.exists())
        self.assertTrue(self.old_command.is_symlink())
        self.assertFalse(self.new_command.exists())
        self.assertEqual(path.read_bytes(), before)
        self.stop.assert_not_called()

    def test_custom_legacy_state_directory_refuses_before_files_or_links_change(self):
        self.assert_custom_job_refused(custom_home=False)

    def test_custom_legacy_codex_home_refuses_before_files_or_links_change(self):
        self.assert_custom_job_refused(custom_home=True)

    def test_malformed_old_settings_refuse_before_job_is_stopped_or_directory_moves(self):
        self.legacy_tree()
        (self.old / "settings.json").write_bytes(b"{broken")
        self.write_job()
        with self.assertRaises(helper.SettingsError):
            helper.prepare_state(self.new)
        self.stop.assert_not_called()
        self.assertFalse(self.new.exists())
        self.assertEqual((self.old / "settings.json").read_bytes(), b"{broken")

    def test_managed_source_command_moves_to_new_name_without_an_alias(self):
        self.legacy_tree()
        self.managed_old_source()
        helper.prepare_state(self.new)
        self.assertFalse(self.old_command.is_symlink())
        self.assertTrue(self.new_command.is_symlink())
        self.assertEqual(self.new_command.resolve(), MODULE_PATH.resolve())

    def test_conflicting_new_command_refuses_before_moving_state_or_stopping_job(self):
        self.legacy_tree()
        self.managed_old_source()
        self.new_command.write_text("unrelated new command")
        self.write_job()
        with self.assertRaisesRegex(RuntimeError, "Refusing to replace an existing command"):
            helper.prepare_state(self.new)
        self.assertTrue(self.old.exists())
        self.assertFalse(self.new.exists())
        self.assertTrue(self.old_command.is_symlink())
        self.assertEqual(self.new_command.read_text(), "unrelated new command")
        self.stop.assert_not_called()

    def test_unrelated_legacy_command_is_preserved_and_native_app_creates_no_cli(self):
        self.legacy_tree()
        self.old_command.parent.mkdir(parents=True)
        self.old_command.write_text("unrelated user command")
        helper.prepare_state(self.new)
        self.assertEqual(self.old_command.read_text(), "unrelated user command")
        self.assertFalse(self.new_command.exists())

    def test_identified_old_bundled_helper_migrates_to_new_frozen_helper(self):
        self.legacy_tree()
        old_contents = self.root / "Codex Keep Going.app/Contents"
        old_helper = old_contents / "Helpers/keep-going-helper"
        old_helper.parent.mkdir(parents=True)
        old_helper.write_bytes(b"old helper fixture")
        (old_contents / "Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": "com.aktay.codex-keep-going.app"}))
        self.old_command.parent.mkdir(parents=True)
        self.old_command.symlink_to(old_helper)
        executable = self.root / "Codex Whip.app/Contents/Helpers/whip-helper"
        executable.parent.mkdir(parents=True)
        executable.write_bytes(b"new helper fixture")
        with (mock.patch.object(helper.sys, "frozen", True, create=True),
              mock.patch.object(helper.sys, "executable", str(executable))):
            helper.prepare_state(self.new)
        self.assertEqual(self.new_command.resolve(), executable.resolve())
        self.assertFalse(self.old_command.is_symlink())

    def replaced_app_fixture(self, bundle_id="com.aktay.codex-keep-going.app"):
        contents = self.root / "Codex Keep Going.app/Contents"
        executable = contents / "Helpers/whip-helper"
        executable.parent.mkdir(parents=True)
        executable.write_bytes(b"replacement helper fixture")
        (contents / "Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": bundle_id}))
        self.old_command.parent.mkdir(parents=True)
        self.old_command.symlink_to(contents / "Helpers/keep-going-helper")
        return executable

    def test_sparkle_in_place_replacement_migrates_dangling_managed_command(self):
        original = self.legacy_tree()
        executable = self.replaced_app_fixture()
        self.assertTrue(self.old_command.is_symlink())
        self.assertFalse(self.old_command.exists())
        history_before = (self.old / "history.sqlite3").read_bytes()
        with (mock.patch.object(helper.sys, "frozen", True, create=True),
              mock.patch.object(helper.sys, "executable", str(executable))):
            helper.prepare_state(self.new)
        self.assertEqual(self.new_command.resolve(), executable.resolve())
        self.assertFalse(self.old_command.is_symlink())
        self.assertFalse(self.old.exists())
        self.assertEqual(helper.read_json(self.new / "state.json"), original)
        self.assertEqual((self.new / "history.sqlite3").read_bytes(), history_before)

    def test_in_place_replacement_refuses_new_command_conflict_before_any_migration(self):
        self.legacy_tree()
        executable = self.replaced_app_fixture()
        self.new_command.write_text("unrelated new command")
        job = self.write_job()
        before = {path.name: path.read_bytes() for path in self.old.iterdir()}
        old_link = self.old_command.readlink()
        job_before = job.read_bytes()
        with (mock.patch.object(helper.sys, "frozen", True, create=True),
              mock.patch.object(helper.sys, "executable", str(executable))):
            with self.assertRaisesRegex(RuntimeError, "Refusing to replace an existing command"):
                helper.prepare_state(self.new)
        self.assertEqual(self.old_command.readlink(), old_link)
        self.assertEqual(self.new_command.read_text(), "unrelated new command")
        self.assertFalse(self.new.exists())
        self.assertEqual({path.name: path.read_bytes() for path in self.old.iterdir()}, before)
        self.assertEqual(job.read_bytes(), job_before)
        self.stop.assert_not_called()

    def test_dangling_command_with_wrong_bundle_identity_is_not_claimed(self):
        self.legacy_tree()
        executable = self.replaced_app_fixture(bundle_id="com.example.unrelated")
        old_link = self.old_command.readlink()
        with (mock.patch.object(helper.sys, "frozen", True, create=True),
              mock.patch.object(helper.sys, "executable", str(executable))):
            self.assertIsNone(helper.managed_legacy_command(executable.resolve()))
            helper.prepare_state(self.new)
        self.assertEqual(self.old_command.readlink(), old_link)
        self.assertFalse(self.new_command.exists())

    def test_dangling_command_beside_another_helper_is_not_claimed(self):
        self.legacy_tree()
        self.replaced_app_fixture()
        executable = self.root / "Another App.app/Contents/Helpers/whip-helper"
        executable.parent.mkdir(parents=True)
        executable.write_bytes(b"unrelated current helper")
        old_link = self.old_command.readlink()
        with (mock.patch.object(helper.sys, "frozen", True, create=True),
              mock.patch.object(helper.sys, "executable", str(executable))):
            self.assertIsNone(helper.managed_legacy_command(executable.resolve()))
            helper.prepare_state(self.new)
        self.assertEqual(self.old_command.readlink(), old_link)
        self.assertFalse(self.new_command.exists())

    def test_changed_old_command_during_job_shutdown_is_detected_before_state_moves(self):
        self.legacy_tree()
        executable = self.replaced_app_fixture()
        self.write_job()
        changed_target = self.root / "unrelated-helper"

        def change_link():
            self.old_command.unlink()
            self.old_command.symlink_to(changed_target)

        self.stop.side_effect = change_link
        before = (self.old / "state.json").read_bytes()
        with (mock.patch.object(helper.sys, "frozen", True, create=True),
              mock.patch.object(helper.sys, "executable", str(executable))):
            with self.assertRaisesRegex(RuntimeError, "old CLI command changed"):
                helper.prepare_state(self.new)
        self.assertTrue(self.old.exists())
        self.assertFalse(self.new.exists())
        self.assertFalse(self.new_command.exists())
        self.assertEqual((self.old / "state.json").read_bytes(), before)
        self.assertEqual(self.old_command.resolve(), changed_target.resolve())

    def test_source_start_preserves_migrated_activation_journal_and_history_without_flag(self):
        original = self.legacy_tree()
        history_before = (self.old / "history.sqlite3").read_bytes()
        with contextlib.redirect_stdout(io.StringIO()):
            helper.start_service(argparse.Namespace(thread=[], preserve_state=False), self.new, self.home / ".codex")
        self.assertEqual(helper.read_json(self.new / "state.json"), original)
        self.assertEqual((self.new / "history.sqlite3").read_bytes(), history_before)
        self.assertFalse(self.old.exists())
        self.assertEqual(self.new_command.resolve(), MODULE_PATH.resolve())
        self.runner.assert_called_once()

    def test_fresh_native_prepare_does_not_install_a_cli_link(self):
        self.assertFalse(helper.prepare_state(self.new))
        self.assertEqual(helper.read_json(self.new / "state.json")["version"], 1)
        self.assertFalse(self.new_command.parent.exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
