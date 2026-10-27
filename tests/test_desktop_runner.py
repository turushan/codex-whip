"""Desktop doctor and watcher checks use private temp directories and fake peers."""

import contextlib
import copy
import io
import json
import os
from pathlib import Path
import signal
import stat
import tempfile
import unittest
from unittest import mock

import codex_whip as core
import desktop_whip as runner
from desktop_backend import DesktopRPC
from desktop_ipc import DesktopIPCError
from settings import DEFAULT_SETTINGS, read_settings
from test_desktop_backend import DesktopPeer, MetadataPeer


class FakeHistory:
    def __init__(self):
        self.events = []
        self.closed = False

    def record(self, event, **fields):
        self.events.append((event, copy.deepcopy(fields)))

    def close(self):
        self.closed = True


class FakeAudio:
    def __init__(self):
        self.configurations, self.events = [], []
        self.closed = False

    def configure(self, enabled):
        self.configurations.append(enabled)

    def report(self, event):
        self.events.append(event)

    def close(self):
        self.closed = True


class DesktopRunnerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="desktop-runner-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.directory, self.home = self.root / "prototype", self.root / "codex"
        self.production = self.root / "production"
        self.peer, self.metadata = DesktopPeer(), MetadataPeer()
        self.metadata.close = mock.Mock()
        self.history_instances, self.audio_instances, self.backends = [], [], []
        self.factory_error = self.backend_error = None
        self.clock = 1200
        self.original_signals = {signal.SIGINT: object(), signal.SIGTERM: object()}
        self.handlers = dict(self.original_signals)
        self.signal_calls = []
        self.messages = []
        self.stack = contextlib.ExitStack()
        self.addCleanup(self.stack.close)
        self.stack.enter_context(mock.patch.object(core, "default_state_directory", return_value=self.production))
        self.stack.enter_context(mock.patch.object(core, "resolve_socket", return_value=self.home / "unused.sock"))
        self.stack.enter_context(mock.patch.object(core, "History", side_effect=self.new_history))
        self.stack.enter_context(mock.patch.object(runner, "RetrySound", side_effect=self.new_audio))
        self.stack.enter_context(mock.patch.object(core, "log_emitter", return_value=self.log))
        self.stack.enter_context(mock.patch.object(runner.signal, "signal", side_effect=self.install_handler))
        self.stack.enter_context(mock.patch.object(runner.time, "time", side_effect=lambda: self.clock))
        self.stack.enter_context(mock.patch.object(runner.time, "monotonic", return_value=100))

    def new_history(self, _directory):
        result = FakeHistory()
        self.history_instances.append(result)
        return result

    def new_audio(self):
        result = FakeAudio()
        self.audio_instances.append(result)
        return result

    def log(self, event, **fields):
        self.messages.append((event, copy.deepcopy(fields)))

    def install_handler(self, signum, handler):
        previous = self.handlers[signum]
        self.handlers[signum] = handler
        self.signal_calls.append((signum, handler))
        return previous

    def metadata_factory(self, _path, should_stop=lambda: False):
        if self.factory_error:
            raise self.factory_error
        self.metadata.should_stop = should_stop
        return self.metadata

    def backend_factory(self, socket_path, metadata, threads, should_stop=lambda: False):
        if self.backend_error:
            raise self.backend_error
        backend = DesktopRPC(socket_path, metadata, threads, should_stop, ipc_factory=self.peer)
        backend.close = mock.Mock(wraps=backend.close)
        self.backends.append(backend)
        return backend

    def watch(self, **kwargs):
        return runner.watch(self.directory, self.home, "thread", once=True,
                            metadata_factory=self.metadata_factory, backend_factory=self.backend_factory,
                            **kwargs)

    def mark_journal(self, **changes):
        self.directory.mkdir(mode=0o700)
        state = {"version": 1, "enabled_at": 1000, "threads": ["thread"],
                 "pending": {}, "handled": {}, "paused": {}, "last_error": None,
                 "control_backend": "desktop-ipc", **changes}
        core.atomic_json(self.directory / "state.json", state)
        return state

    def state(self):
        return json.loads((self.directory / "state.json").read_text())

    def assert_resources_closed(self):
        self.assertEqual(self.handlers, self.original_signals)
        self.assertTrue(all(history.closed for history in self.history_instances))
        self.assertTrue(all(audio.closed for audio in self.audio_instances))
        for backend in self.backends:
            backend.close.assert_called_once()
        for connection in self.peer.connections:
            self.assertTrue(connection.closed)
            if connection.follows:
                self.assertEqual(connection.follows, [True, False])

    @staticmethod
    def directory_snapshot(directory):
        if not directory.exists():
            return None
        return {
            str(path.relative_to(directory)): (stat.S_IMODE(path.stat().st_mode),
                                               path.read_bytes() if path.is_file() else None)
            for path in [directory, *directory.rglob("*")]
        }

    def test_doctor_reads_only_and_reports_no_identifiers_or_contents(self):
        backend = self.backend_factory("unused.sock", self.metadata, ["thread"], lambda: False)
        result = runner.diagnostic(backend, "thread")
        backend.close()
        self.assertTrue(result["connected"])
        self.assertTrue(result["capacity_failure"])
        self.assertTrue(result["saved_turn_matches"])
        self.assertTrue(result["completion_timestamp_verified"])
        self.assertFalse(result["message_sent"])
        self.assertFalse(result["quota_recovery_supported"])
        self.assertFalse(self.directory.exists())
        self.assertEqual(self.peer.starts, [])
        self.assertTrue(all(method == "thread/turns/list" for method, _ in self.metadata.calls))
        output = json.dumps(result)
        self.assertNotIn("private", output)
        self.assertNotIn("failed-turn", output)
        self.assertNotIn("owner", output)
        self.assert_resources_closed()

    def test_doctor_distinguishes_unverified_persisted_time_without_deriving_it(self):
        self.metadata.turns[0]["completedAt"] = None
        backend = self.backend_factory("unused.sock", self.metadata, ["thread"], lambda: False)
        result = runner.diagnostic(backend, "thread")
        backend.close()
        self.assertTrue(result["saved_turn_matches"])
        self.assertFalse(result["completion_timestamp_verified"])
        self.assertFalse(result["message_sent"])
        self.metadata.error = core.RequestError("private metadata details")
        backend = self.backend_factory("unused.sock", self.metadata, ["thread"], lambda: False)
        result = runner.diagnostic(backend, "thread")
        backend.close()
        self.assertFalse(result["saved_turn_matches"])
        self.assertFalse(result["completion_timestamp_verified"])
        self.assertNotIn("private", json.dumps(result))

    def test_new_once_watcher_is_private_silent_and_uses_a_separate_journal(self):
        self.assertTrue(self.watch())
        state = self.state()
        self.assertEqual(state["control_backend"], "desktop-ipc")
        self.assertEqual(state["threads"], ["thread"])
        self.assertEqual(state["enabled_at"], 1200)
        self.assertEqual(state["pending"], {})
        self.assertEqual(read_settings(self.directory), {**DEFAULT_SETTINGS, "sound_enabled": False})
        self.assertEqual(self.audio_instances[0].configurations, [False])
        self.assertEqual(self.peer.starts, [])
        self.assertFalse(self.production.exists())
        self.assertEqual(stat.S_IMODE(self.directory.stat().st_mode), 0o700)
        for name in ["state.json", "settings.json", "worker.log"]:
            self.assertEqual(stat.S_IMODE((self.directory / name).stat().st_mode), 0o600)
        self.metadata.close.assert_called_once()
        self.assert_resources_closed()

    def test_production_directory_and_alias_are_rejected_without_file_changes(self):
        self.production.mkdir()
        (self.production / "settings.json").write_bytes(b"production settings stay untouched")
        before = self.directory_snapshot(self.production)
        alias = self.root / "production-alias"
        alias.symlink_to(self.production, target_is_directory=True)
        for directory in [self.production, alias]:
            with self.assertRaises(ValueError):
                runner.watch(directory, self.home, "thread", once=True,
                             metadata_factory=self.metadata_factory, backend_factory=self.backend_factory)
            self.assertEqual(self.directory_snapshot(self.production), before)
        self.assertEqual(self.metadata.calls, [])
        self.assertEqual(self.signal_calls, [])

    def test_unmarked_custom_and_other_scope_journals_are_rejected_without_changes(self):
        cases = [
            {"version": 1, "threads": ["thread"], "enabled_at": 1000},
            {"version": 1, "threads": ["other"], "control_backend": "desktop-ipc"},
            {"version": 1, "threads": ["thread"], "control_backend": "cli"},
        ]
        for index, state in enumerate(cases):
            directory = self.root / ("foreign-" + str(index))
            directory.mkdir(mode=0o755)
            (directory / "state.json").write_text(json.dumps(state))
            (directory / "settings.json").write_bytes(b"foreign settings")
            before = self.directory_snapshot(directory)
            with self.assertRaises(ValueError):
                runner.watch(directory, self.home, "thread", once=True,
                             metadata_factory=self.metadata_factory, backend_factory=self.backend_factory)
            self.assertEqual(self.directory_snapshot(directory), before)
        self.assertEqual(self.metadata.calls, [])
        self.assertEqual(self.signal_calls, [])

    def test_nonempty_unmarked_directory_is_rejected_without_changes(self):
        self.directory.mkdir(mode=0o755)
        (self.directory / "settings.json").write_bytes(b"existing settings")
        before = self.directory_snapshot(self.directory)
        with self.assertRaises(ValueError):
            self.watch()
        self.assertEqual(self.directory_snapshot(self.directory), before)
        self.assertEqual(self.signal_calls, [])

    def test_malformed_non_object_journal_is_rejected_without_file_changes(self):
        self.directory.mkdir(mode=0o755)
        for value in [[], None, "foreign data"]:
            with self.subTest(value=value):
                (self.directory / "state.json").write_text(json.dumps(value))
                before = self.directory_snapshot(self.directory)
                with self.assertRaises(ValueError):
                    self.watch()
                self.assertEqual(self.directory_snapshot(self.directory), before)
        self.assertEqual(self.signal_calls, [])

    def test_marked_pending_journal_and_exact_scope_survive_restart(self):
        self.mark_journal(handled={"earlier": {"turn_id": "old", "outcome": "cancelled"}},
                          paused={"other-paused": True})
        self.clock = 1100
        self.assertTrue(self.watch())
        before = self.state()
        self.assertIn("thread", before["pending"])
        self.clock = 1200
        self.assertTrue(self.watch())
        after = self.state()
        for name in ["enabled_at", "threads", "pending", "handled", "paused", "control_backend"]:
            self.assertEqual(after[name], before[name], name)
        self.assertEqual(self.peer.starts, [])
        self.assert_resources_closed()

    def test_legacy_settings_keep_custom_intervals_message_and_sound_off(self):
        self.mark_journal()
        custom = {"retry_seconds": 777, "scan_seconds": 123, "message": "My exact message 👩🏽‍💻.\nContinue."}
        path = self.directory / "settings.json"
        document = json.dumps(custom, ensure_ascii=False).encode()
        path.write_bytes(document)
        self.clock = 1100
        self.assertTrue(self.watch())
        self.assertEqual(path.read_bytes(), document)
        self.assertEqual(read_settings(self.directory), {**custom, "sound_enabled": False})
        self.assertEqual(self.state()["pending"]["thread"]["due_at"], 1877)
        self.clock = 1877
        self.assertTrue(self.watch())
        request = self.peer.starts[0][0]["turnStart"]["request"]
        self.assertEqual(request["input"][0]["text"], custom["message"])
        self.assertTrue(all(audio.configurations == [False] for audio in self.audio_instances))
        self.assert_resources_closed()

    def test_connection_or_owner_protocol_failure_holds_and_returns_false(self):
        for error_kind in ["connection", "owner"]:
            with self.subTest(error_kind=error_kind):
                if error_kind == "connection":
                    self.factory_error = OSError("private network detail")
                else:
                    self.factory_error = None
                    self.peer.owner_error = DesktopIPCError("unsupported-version")
                self.assertFalse(self.watch())
                state = self.state()
                self.assertIn("on hold", state["last_error"])
                self.assertNotIn("private", state["last_error"])
                self.assertEqual(self.peer.starts, [])
                self.assert_resources_closed()

    def test_unavailable_persisted_metadata_holds_and_returns_false(self):
        self.mark_journal()
        self.metadata.error = core.RequestError("private saved summary details")
        self.assertFalse(self.watch())
        self.assertEqual(self.peer.starts, [])
        self.assertEqual(self.state()["pending"], {})
        self.assert_resources_closed()

    def test_invalid_saved_settings_restore_handlers_and_close_resources(self):
        self.mark_journal()
        (self.directory / "settings.json").write_text('{"invalid":true}')
        with self.assertRaises(ValueError):
            self.watch()
        self.assertEqual(self.peer.connections, [])
        self.assert_resources_closed()

    def test_resource_initialization_failure_restores_signals_and_closes_earlier_resources(self):
        for target, name in [(core, "History"), (runner, "RetrySound")]:
            with self.subTest(name=name):
                with mock.patch.object(target, name, side_effect=RuntimeError("Resource unavailable")):
                    with self.assertRaises(RuntimeError):
                        self.watch()
                self.assert_resources_closed()

    def test_signal_stop_exits_foreground_loop_and_closes_connections(self):
        def stop(_seconds):
            self.handlers[signal.SIGTERM](signal.SIGTERM, None)
        with mock.patch.object(runner.time, "sleep", side_effect=stop):
            self.assertTrue(runner.watch(self.directory, self.home, "thread", once=False,
                                        metadata_factory=self.metadata_factory, backend_factory=self.backend_factory))
        self.assertTrue(self.metadata.should_stop())
        self.assert_resources_closed()

    def test_main_doctor_is_read_only_and_closes_backend_and_metadata(self):
        output = io.StringIO()
        with (mock.patch.object(core, "WebSocketRPC", side_effect=self.metadata_factory),
              mock.patch.object(runner, "DesktopRPC", side_effect=self.backend_factory),
              contextlib.redirect_stdout(output)):
            self.assertEqual(runner.main(["--codex-home", str(self.home), "--thread", "thread", "doctor"]), 0)
        result = json.loads(output.getvalue())
        self.assertFalse(result["message_sent"])
        self.assertEqual(self.peer.starts, [])
        self.metadata.close.assert_called_once()
        self.assert_resources_closed()


if __name__ == "__main__":
    unittest.main()
