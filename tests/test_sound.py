"""Retry audio checks use fake players and RPCs, never real sounds or sessions."""

import copy
import json
from pathlib import Path
import signal
import tempfile
import threading
import unittest
from unittest import mock
import wave

from test_core import FakeRPC, capacity
from test_quota import QuotaRPC
from whip_sound import RetrySound, SOUND_PATH, play_clip


class RetrySoundTests(unittest.TestCase):
    def setUp(self):
        self.played = []
        self.sound = RetrySound(player=lambda path: self.played.append(path))
        self.addCleanup(self.sound.close)
        self.state = {"enabled_at": 1000}
        self.engine = capacity.RetryEngine(self.state, lambda _value: None,
            lambda event, **_fields: self.sound.report(event), interval=180, scan_interval=300)

    def drain(self):
        finished = threading.Event()
        threading.Thread(target=lambda: (self.sound._queue.join(), finished.set()), daemon=True).start()
        self.assertTrue(finished.wait(1), "Audio queue should finish fake playback promptly")

    def retry(self, rpc=None):
        rpc = rpc or FakeRPC()
        self.engine.step(rpc, 1100)
        self.engine.step(rpc, 1280)
        return rpc

    def test_sound_is_off_until_explicitly_enabled_and_does_not_replay_when_enabled(self):
        rpc = self.retry()
        self.assertEqual(len(rpc.sends()), 1)
        self.assertEqual(self.played, [])
        self.sound.configure(True)
        self.engine.step(rpc, 1580)
        self.assertEqual(self.played, [])

    def test_confirmed_capacity_retry_sounds_once_without_detection_or_history_replay(self):
        self.sound.configure(True)
        rpc = FakeRPC()
        self.engine.step(rpc, 1100)
        self.assertEqual(self.played, [])
        self.engine.step(rpc, 1280)
        self.drain()
        self.assertEqual(self.played, [SOUND_PATH])
        self.engine.step(rpc, 1580)
        capacity.reconcile_history(self.state, mock.Mock(), 1580)
        for event in ["started", "waiting", "quota_waiting", "settings_changed", "retry_result", "uncertain", "stopped"]:
            self.sound.report(event)
        self.drain()
        self.assertEqual(self.played, [SOUND_PATH])

    def test_quota_checks_stay_silent_until_a_confirmed_continuation(self):
        self.sound.configure(True)
        rpc = QuotaRPC()
        self.engine.step(rpc, 1100)
        self.engine.step(rpc, 1400)
        self.assertEqual(self.played, [])
        rpc.quota["ordinaryUsageAllowed"] = True
        self.engine.step(rpc, 1700)
        self.drain()
        self.assertEqual(len(rpc.sends()), 1)
        self.assertEqual(self.played, [SOUND_PATH])

    def test_failed_or_uncertain_submission_stays_silent_including_after_restart(self):
        self.sound.configure(True)
        rpc = FakeRPC()
        rpc.send_error = capacity.RPCError("Response lost")
        with self.assertRaises(capacity.RPCError):
            self.retry(rpc)
        self.assertEqual(self.played, [])
        self.engine = capacity.RetryEngine(copy.deepcopy(self.state), lambda _value: None,
            lambda event, **_fields: self.sound.report(event), interval=180, scan_interval=300)
        rpc.send_error = None
        self.engine.step(rpc, 2000)
        self.assertEqual(self.played, [])
        self.assertEqual(len(rpc.sends()), 1)

    def test_playback_does_not_block_retries_and_disabling_drops_queued_sounds(self):
        started, release = threading.Event(), threading.Event()
        def player(path):
            self.played.append(path)
            started.set()
            release.wait(2)
        self.sound.close()
        self.sound = RetrySound(player=player)
        self.addCleanup(self.sound.close)
        self.addCleanup(release.set)
        self.sound.configure(True)
        rpc = self.retry()
        self.assertEqual(len(rpc.sends()), 1)
        self.assertTrue(started.wait(1))
        self.sound.report("retry")
        self.sound.configure(False)
        self.sound.configure(True)
        release.set()
        self.drain()
        self.assertEqual(self.played, [SOUND_PATH])
        self.sound.report("retry")
        self.drain()
        self.assertEqual(self.played, [SOUND_PATH, SOUND_PATH])

    def test_broken_audio_player_cannot_fail_the_retry_or_the_next_sound(self):
        called = []
        def unavailable(path):
            called.append(path)
            raise OSError("Audio device unavailable")
        self.sound.close()
        self.sound = RetrySound(player=unavailable)
        self.addCleanup(self.sound.close)
        self.sound.configure(True)
        rpc = self.retry()
        self.drain()
        self.assertEqual(self.state["handled"]["user-session"]["outcome"], "submitted")
        self.assertEqual(len(rpc.sends()), 1)
        self.sound.report("retry")
        self.drain()
        self.assertEqual(called, [SOUND_PATH, SOUND_PATH])

    def test_thread_start_failure_preserves_the_accepted_retry_and_allows_later_audio(self):
        self.sound.configure(True)
        with mock.patch("whip_sound.threading.Thread.start", side_effect=RuntimeError("No audio thread available")):
            rpc = self.retry()
        self.assertEqual(len(rpc.sends()), 1)
        self.assertEqual(self.state["handled"]["user-session"]["outcome"], "submitted")
        self.assertEqual(self.played, [])
        self.sound.report("retry")
        self.drain()
        self.assertEqual(self.played, [SOUND_PATH])

    def test_bundled_clip_is_short_original_pcm_and_player_uses_current_output_volume(self):
        with wave.open(str(SOUND_PATH), "rb") as clip:
            self.assertEqual(clip.getnchannels(), 1)
            self.assertEqual(clip.getsampwidth(), 2)
            self.assertAlmostEqual(clip.getnframes() / clip.getframerate(), 0.55)
        with mock.patch("whip_sound.sys.platform", "darwin"), mock.patch("whip_sound.subprocess.run") as run:
            play_clip(SOUND_PATH)
        self.assertEqual(run.call_args.args[0], ["/usr/bin/afplay", "-v", "0.4", str(SOUND_PATH)])
        self.assertEqual(run.call_args.kwargs["timeout"], 2)


class WorkerSoundTests(unittest.TestCase):
    def test_saved_sound_toggle_is_live_and_only_new_submissions_sound(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            (directory / "state.json").write_text(json.dumps({"version": 1, "enabled_at": 1000,
                "handled": {"old": {"turn_id": "old", "outcome": "submitted", "at": 1000, "retry_turn_id": "old-retry"}}}))
            clock, handlers, played = [1100], {}, []
            sound = RetrySound(player=lambda path: played.append(path))
            rpc = FakeRPC()
            rpc.close = mock.Mock()
            settings = {**capacity.DEFAULT_SETTINGS, "retry_seconds": 60}
            capacity.save_settings(directory, settings)
            def sleep(_seconds):
                clock[0] += 1
                if clock[0] == 1130:
                    capacity.save_settings(directory, {**settings, "sound_enabled": True})
                if clock[0] >= 1162:
                    self.assertTrue(thread_done.wait(1))
                    handlers[signal.SIGTERM](signal.SIGTERM, None)
            thread_done = threading.Event()
            def player(path):
                played.append(path)
                thread_done.set()
            sound._player = player
            with (mock.patch.object(capacity, "configured_parent_pid", return_value=None),
                  mock.patch.object(capacity.os, "umask"),
                  mock.patch.object(capacity.signal, "signal", side_effect=lambda event, callback: handlers.update({event: callback})),
                  mock.patch.object(capacity, "RetrySound", return_value=sound),
                  mock.patch.object(capacity, "History", return_value=mock.Mock()),
                  mock.patch.object(capacity, "log_emitter", return_value=mock.Mock()),
                  mock.patch.object(capacity, "WebSocketRPC", return_value=rpc),
                  mock.patch.object(capacity, "resolve_socket", return_value=directory / "unused.sock"),
                  mock.patch.object(capacity.time, "monotonic", side_effect=lambda: clock[0]),
                  mock.patch.object(capacity.time, "time", side_effect=lambda: clock[0]),
                  mock.patch.object(capacity.time, "sleep", side_effect=sleep)):
                capacity.run_worker(directory, directory / "codex")
            self.assertEqual(len(rpc.sends()), 1)
            self.assertEqual(played, [SOUND_PATH])


if __name__ == "__main__":
    unittest.main()
