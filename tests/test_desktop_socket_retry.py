"""Run the actual transport, adapter and retry engine against a local fake app."""

import copy
from pathlib import Path
import socket
import tempfile
import threading
import unittest

import codex_whip as core
from desktop_backend import DesktopRPC
from test_desktop_backend import DesktopPeer, MetadataPeer
from test_desktop_ipc import read_message, write_message, success


class DesktopSocketRetryTests(unittest.TestCase):
    def test_capacity_retry_round_trip_uses_real_framing_and_preserves_write_ahead(self):
        desktop, metadata = DesktopPeer(), MetadataPeer()
        state, starts, failures = {"enabled_at": 1000}, [], []
        finish = threading.Event()
        with tempfile.TemporaryDirectory(prefix="whip-desktop-e2e-", dir="/tmp") as directory:
            path = Path(directory) / "ipc.sock"
            listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            listener.bind(str(path))
            listener.listen(8)
            listener.settimeout(0.05)

            def serve():
                sequence = 0
                while not finish.is_set():
                    try:
                        connection, _ = listener.accept()
                    except socket.timeout:
                        continue
                    try:
                        with connection:
                            connection.settimeout(2)
                            initialize = read_message(connection)
                            sequence += 1
                            client = "fresh-client-" + str(sequence)
                            write_message(connection, success(initialize, {"clientId": client}, owner=client))
                            while True:
                                request = read_message(connection)
                                method, params = request.get("method"), request.get("params", {})
                                if method == "thread-owner-discovery":
                                    write_message(connection, success(request, {"supportsUntrustedAppInput": True}, owner="owner"))
                                elif method == "thread-follower-read-model-settings":
                                    write_message(connection, success(request, desktop.model, owner="owner"))
                                elif method == "thread-stream-following-changed":
                                    if params["following"]:
                                        snapshot = copy.deepcopy(desktop.snapshot)
                                        snapshot.update(sourceClientId="owner", targetClientIds=[client])
                                        write_message(connection, snapshot, fragmented=True)
                                elif method == "thread-follower-start-turn":
                                    attempt = state["handled"]["thread"]
                                    self.assertEqual(attempt["outcome"], "uncertain")
                                    self.assertEqual(attempt["client_message_id"], params["turnStart"]["request"]["clientUserMessageId"])
                                    starts.append(copy.deepcopy(request))
                                    write_message(connection, success(request, desktop.ack, owner="owner"), fragmented=True)
                                else:
                                    raise AssertionError("Unexpected operation in local fake app")
                    except (EOFError, BrokenPipeError, ConnectionResetError):
                        pass
                    except BaseException as error:
                        failures.append(error)
                        return

            server = threading.Thread(target=serve, daemon=True)
            server.start()
            backend = DesktopRPC(path, metadata, ["thread"])
            try:
                engine = core.RetryEngine(state, lambda _state: None, lambda *_args, **_fields: None,
                                          interval=180, threads=["thread"])
                engine.step(backend, 1100)
                self.assertEqual(starts, [])
                engine.step(backend, 1280)
                self.assertEqual(len(starts), 1)
                self.assertEqual(starts[0]["version"], 2)
                self.assertEqual(starts[0]["targetClientId"], "owner")
                self.assertEqual(starts[0]["params"]["turnStart"]["context"], {"inheritThreadSettings": True})
                self.assertEqual(state["handled"]["thread"]["outcome"], "submitted")
                self.assertEqual(state["handled"]["thread"]["retry_turn_id"], "retry-turn")
                self.assertTrue(all(method == "thread/turns/list" for method, _ in metadata.calls))
            finally:
                backend.close()
                finish.set()
                server.join(timeout=3)
                listener.close()
            self.assertFalse(server.is_alive())
            if failures:
                raise failures[0]


if __name__ == "__main__":
    unittest.main()
