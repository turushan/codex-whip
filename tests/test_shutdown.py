"""SIGTERM checks against a stalled local protocol stub, including frozen helpers.

Set CODEX_WHIP_TEST_HELPER to a bundled executable to run the same checks
against PyInstaller's onefile bootloader and its child. No real Codex is used.
"""

import base64
import contextlib
import fcntl
import hashlib
import json
import os
from pathlib import Path
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
import unittest


SOURCE = Path(__file__).resolve().parents[1] / "codex_whip.py"


def read_exact(connection, size):
    value = bytearray()
    while len(value) < size:
        packet = connection.recv(size - len(value))
        if not packet:
            raise EOFError("Helper closed its connection")
        value.extend(packet)
    return bytes(value)


def read_json_frame(connection):
    first, second = read_exact(connection, 2)
    if first != 0x81 or not second & 0x80:
        raise AssertionError("Expected a masked WebSocket text frame")
    size = second & 0x7F
    if size == 126:
        size = struct.unpack("!H", read_exact(connection, 2))[0]
    elif size == 127:
        size = struct.unpack("!Q", read_exact(connection, 8))[0]
    mask = read_exact(connection, 4)
    value = read_exact(connection, size)
    return json.loads(bytes(byte ^ mask[index % 4] for index, byte in enumerate(value)))


def send_json_frame(connection, value):
    payload = json.dumps(value).encode()
    if len(payload) >= 126:
        raise AssertionError("Test response unexpectedly needs an extended length")
    connection.sendall(bytes([0x81, len(payload)]) + payload)


class ShutdownTests(unittest.TestCase):
    def stalled_shutdown(self, phase):
        with tempfile.TemporaryDirectory(prefix="ckg-stop-", dir="/tmp") as temporary:
            root = Path(temporary)
            state_dir = root / "state"
            state_dir.mkdir()
            state = {"version": 1, "enabled_at": time.time(), "threads": [],
                     "pending": {}, "handled": {}, "paused": {}, "last_error": None}
            (state_dir / "state.json").write_text(json.dumps(state))
            codex_home = root / "codex"
            socket_path = codex_home / "app-server-control/app-server-control.sock"
            socket_path.parent.mkdir(parents=True)
            ready, finish = threading.Event(), threading.Event()
            errors = []
            listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            listener.bind(str(socket_path))
            listener.listen(1)
            listener.settimeout(10)

            def server():
                try:
                    with listener.accept()[0] as connection:
                        connection.settimeout(10)
                        headers = bytearray()
                        while b"\r\n\r\n" not in headers:
                            headers.extend(read_exact(connection, 1))
                        if phase != "handshake":
                            parsed = dict(line.split(":", 1) for line in headers.decode().split("\r\n")[1:] if ":" in line)
                            key = parsed["Sec-WebSocket-Key"].strip()
                            digest = base64.b64encode(hashlib.sha1(
                                (key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()
                            ).digest()).decode()
                            connection.sendall(("HTTP/1.1 101 Switching Protocols\r\n"
                                                "Upgrade: websocket\r\nConnection: Upgrade\r\n"
                                                f"Sec-WebSocket-Accept: {digest}\r\n\r\n").encode())
                            initialize = read_json_frame(connection)
                            self.assertEqual(initialize["method"], "initialize")
                            if phase == "rpc":
                                send_json_frame(connection, {"id": initialize["id"], "result": {}})
                                self.assertEqual(read_json_frame(connection)["method"], "initialized")
                                self.assertEqual(read_json_frame(connection)["method"], "thread/loaded/list")
                        ready.set()
                        connection.settimeout(0.25)
                        while not finish.is_set():
                            try:
                                if not connection.recv(1024):
                                    break
                            except socket.timeout:
                                continue
                except BaseException as error:
                    errors.append(error)
                    ready.set()

            thread = threading.Thread(target=server, daemon=True)
            thread.start()
            configured_helper = os.environ.get("CODEX_WHIP_TEST_HELPER")
            command = [configured_helper] if configured_helper else [sys.executable, str(SOURCE)]
            environment = dict(os.environ, CODEX_WHIP_PARENT_PID=str(os.getpid()))
            process = subprocess.Popen(
                command + ["--state-dir", str(state_dir), "--codex-home", str(codex_home), "_run"],
                env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                text=True, start_new_session=True,
            )
            clean_exit = False
            try:
                self.assertTrue(ready.wait(15), "Helper did not reach the stalled protocol phase")
                if errors:
                    raise errors[0]
                with (state_dir / "worker.lock").open("r") as lock:
                    with self.assertRaises(BlockingIOError):
                        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                started = time.monotonic()
                process.terminate()
                stdout, stderr = process.communicate(timeout=2)
                with (state_dir / "worker.lock").open("r") as lock:
                    while True:
                        try:
                            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                            break
                        except BlockingIOError:
                            if time.monotonic() - started >= 1.5:
                                self.fail(f"Worker kept its lock after shutdown: {stdout} {stderr}")
                            time.sleep(0.02)
                    fcntl.flock(lock, fcntl.LOCK_UN)
                elapsed = time.monotonic() - started
                self.assertLess(elapsed, 1.5, f"Shutdown took {elapsed:.2f}s: {stdout} {stderr}")
                self.assertFalse((state_dir / "worker.pid").exists())
                saved = json.loads((state_dir / "state.json").read_text())
                self.assertIsNone(saved.get("last_error"))
                events = [json.loads(line) for line in (state_dir / "worker.log").read_text().splitlines()]
                self.assertFalse(any(event["event"] == "connection_error" for event in events))
                self.assertEqual(events[-1]["event"], "stopped")
                clean_exit = True
            finally:
                if not clean_exit:
                    with contextlib.suppress(ProcessLookupError):
                        os.killpg(process.pid, signal.SIGKILL)
                    process.communicate(timeout=3)
                finish.set()
                listener.close()
                thread.join(timeout=2)
            if errors:
                raise errors[0]

    def test_sigterm_interrupts_stalled_handshake_and_releases_worker_lock(self):
        self.stalled_shutdown("handshake")

    def test_sigterm_interrupts_stalled_initialize_and_releases_worker_lock(self):
        self.stalled_shutdown("initialize")

    def test_sigterm_interrupts_stalled_metadata_rpc_and_releases_worker_lock(self):
        self.stalled_shutdown("rpc")


if __name__ == "__main__":
    unittest.main(verbosity=2)
