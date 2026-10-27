"""Optional, focus-free feedback for live retry submissions on macOS."""

from pathlib import Path
import queue
import subprocess
import sys
import threading


SOUND_PATH = Path(__file__).resolve().parent / "assets/sounds/whip.wav"


def play_clip(path):
    """Runs only on the audio thread; afplay respects the current output volume."""
    if sys.platform != "darwin" or not path.is_file():
        return
    subprocess.run(["/usr/bin/afplay", "-v", "0.4", str(path)],
                   stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                   stderr=subprocess.DEVNULL, timeout=2, check=False)


class RetrySound:
    """Queue short sounds without holding up retries or replaying old events.

    The worker feeds only its live report stream. Reconstructed history never
    reaches this object. Disabling cancels queued sounds; an already playing
    half-second clip finishes at the user's existing system volume.
    """

    def __init__(self, player=None, path=SOUND_PATH):
        self._player = player or play_clip
        self._path = path
        self._enabled = False
        self._closed = False
        self._generation = 0
        self._lock = threading.Lock()
        self._queue = queue.Queue()
        self._thread = None

    def configure(self, enabled):
        with self._lock:
            if enabled != self._enabled:
                self._enabled = enabled
                self._generation += 1

    def report(self, event):
        if event != "retry":
            return
        with self._lock:
            if self._closed or not self._enabled:
                return
            generation = self._generation
            if self._thread is None:
                self._thread = threading.Thread(target=self._run, name="whip-sound", daemon=True)
                try:
                    self._thread.start()
                except RuntimeError:
                    self._thread = None
                    return  # A later retry may create the audio thread successfully.
        self._queue.put_nowait(generation)

    def close(self):
        with self._lock:
            self._closed = True
            self._generation += 1
        self._queue.put_nowait(None)

    def _run(self):
        while True:
            generation = self._queue.get()
            try:
                with self._lock:
                    if self._closed:
                        return
                    enabled = self._enabled and generation == self._generation
                if enabled:
                    try:
                        self._player(self._path)
                    except Exception:
                        # Audio is optional feedback, never a watcher failure.
                        pass
            finally:
                self._queue.task_done()
