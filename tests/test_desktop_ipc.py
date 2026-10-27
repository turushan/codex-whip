"""Desktop framing checks use temporary socket servers, never the actual app."""

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

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import desktop_ipc
from desktop_ipc import DesktopIPC, DesktopIPCError


def read_exact(connection, size):
    result = bytearray()
    while len(result) < size:
        part = connection.recv(size - len(result))
        if not part:
            raise EOFError("Test client closed")
        result.extend(part)
    return bytes(result)


def read_message(connection):
    size = struct.unpack("<I", read_exact(connection, 4))[0]
    return json.loads(read_exact(connection, size))


def write_message(connection, message, fragmented=False):
    data = json.dumps(message, ensure_ascii=False).encode()
    frame = struct.pack("<I", len(data)) + data
    if fragmented:
        for start, end in [(0, 1), (1, 3), (3, 7), (7, 11), (11, len(frame))]:
            connection.sendall(frame[start:end])
            time.sleep(0.002)
    else:
        connection.sendall(frame)


def success(request, result=None, owner="desktop-owner", **changes):
    response = {"type": "response", "requestId": request["requestId"],
                "resultType": "success", "method": request["method"],
                "handledByClientId": owner, "result": result}
    response.update(changes)
    return response


def broadcast(method="thread-stream-state-changed", **changes):
    value = {"type": "broadcast", "sourceClientId": "desktop-owner", "version": 11,
             "method": method, "targetClientIds": ["test-client"],
             "params": {"conversationId": "synthetic-thread", "change": {"revision": 1}}}
    value.update(changes)
    return value


class Stub:
    def __init__(self, handler, initialize=None):
        self.handler, self.initialize = handler, initialize
        self.temporary = tempfile.TemporaryDirectory(prefix="whip-ipc-", dir="/tmp")
        self.path = Path(self.temporary.name) / "ipc.sock"
        self.listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.listener.bind(str(self.path))
        self.listener.listen(1)
        self.listener.settimeout(0.05)
        self.finish = threading.Event()
        self.errors = []
        self.initial = None
        self.thread = threading.Thread(target=self.run, daemon=True)

    def run(self):
        try:
            while not self.finish.is_set():
                try:
                    connection, _ = self.listener.accept()
                    break
                except socket.timeout:
                    continue
            else:
                return
            with connection:
                connection.settimeout(2)
                self.initial = read_message(connection)
                if self.initialize is not None:
                    self.initialize(connection, self.initial)
                else:
                    write_message(connection, success(self.initial, {"clientId": "test-client"},
                                                      owner="test-client"), fragmented=True)
                    self.handler(connection, self)
        except (EOFError, BrokenPipeError, ConnectionResetError):
            pass
        except BaseException as error:
            if not self.finish.is_set():
                self.errors.append(error)

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *_exc):
        self.finish.set()
        self.thread.join(timeout=2.2)
        self.listener.close()
        self.temporary.cleanup()
        if self.thread.is_alive():
            raise AssertionError("Socket stub did not stop")
        if self.errors:
            raise self.errors[0]


class DesktopIPCTests(unittest.TestCase):
    def test_handshake_targeted_request_and_void_success_keep_owner_and_unicode(self):
        requests = []
        def handle(connection, _stub):
            request = read_message(connection)
            requests.append(request)
            write_message(connection, success(request, {"label": "A synthetic 👋 result"}), fragmented=True)
            request = read_message(connection)
            requests.append(request)
            response = success(request)
            del response["result"]
            write_message(connection, response)
        with Stub(handle) as stub, DesktopIPC(stub.path) as ipc:
            self.assertEqual(ipc.client_id, "test-client")
            full = ipc.request_full("synthetic-read", {"text": "👩🏽‍💻"}, version=3, target="desktop-owner")
            self.assertEqual(full["handledByClientId"], "desktop-owner")
            self.assertEqual(full["result"]["label"], "A synthetic 👋 result")
            self.assertIsNone(ipc.request("synthetic-void", {}, target="desktop-owner"))
            self.assertEqual(stub.initial["sourceClientId"], "initializing-client")
            self.assertEqual(stub.initial["version"], 0)
            self.assertEqual(stub.initial["params"], {"clientType": "codex_whip"})
            self.assertEqual(stub.initial["timeoutMs"], 5000)
            self.assertEqual(requests[0]["sourceClientId"], "test-client")
            self.assertEqual(requests[0]["targetClientId"], "desktop-owner")
            self.assertEqual(requests[0]["version"], 3)
            self.assertEqual(requests[0]["params"]["text"], "👩🏽‍💻")

    def test_interleaved_discovery_and_broadcasts_do_not_replace_request_response(self):
        captured = []
        first = broadcast(params={"kind": "first"})
        second = broadcast(method="synthetic-second", params={"kind": "second"})
        def handle(connection, _stub):
            request = read_message(connection)
            write_message(connection, {"type": "client-discovery-request", "requestId": "discovery-question",
                                       "request": {"method": "thread-owner-discovery"}})
            captured.append(read_message(connection))
            write_message(connection, success({"requestId": "unrelated", "method": "other"}, {"ignored": True}))
            write_message(connection, first)
            write_message(connection, second)
            write_message(connection, success(request, {"ok": True}))
        with Stub(handle) as stub, DesktopIPC(stub.path) as ipc:
            self.assertEqual(ipc.request("synthetic-read", {}), {"ok": True})
            self.assertEqual(ipc.wait_broadcast(lambda v: v["params"].get("kind") == "second"), second)
            self.assertEqual(ipc.wait_broadcast(lambda v: v["params"].get("kind") == "first"), first)
            self.assertEqual(captured, [{"type": "client-discovery-response", "requestId": "discovery-question",
                                         "response": {"canHandle": False}}])

    def test_broadcast_preserves_version_targets_and_assigned_source(self):
        captured, ready = [], threading.Event()
        def handle(connection, _stub):
            captured.append(read_message(connection))
            ready.set()
        with Stub(handle) as stub, DesktopIPC(stub.path) as ipc:
            ipc.broadcast("thread-stream-following-changed", {"following": True}, version=1,
                          targets=["desktop-owner"])
            self.assertTrue(ready.wait(1))
            self.assertEqual(captured, [{"type": "broadcast", "sourceClientId": "test-client", "version": 1,
                                        "method": "thread-stream-following-changed", "params": {"following": True},
                                        "targetClientIds": ["desktop-owner"]}])

    def test_remote_errors_are_sanitized_and_do_not_close_a_valid_connection(self):
        errors = ["no-client-found", "SECRET transcript text", {"message": "SECRET account"}]
        def handle(connection, _stub):
            for error in errors:
                request = read_message(connection)
                write_message(connection, {"type": "response", "requestId": request["requestId"],
                                           "resultType": "error", "error": error})
            request = read_message(connection)
            write_message(connection, success(request, True))
        with Stub(handle) as stub, DesktopIPC(stub.path) as ipc:
            for expected in ["no-client-found", "request-failed", "request-failed"]:
                with self.assertRaises(DesktopIPCError) as caught:
                    ipc.request("synthetic-read", {})
                self.assertEqual(caught.exception.code, expected)
                self.assertNotIn("SECRET", str(caught.exception))
                self.assertNotIn("SECRET", repr(caught.exception))
            self.assertTrue(ipc.request("synthetic-read", {}))

    def test_handshake_requires_assigned_client_and_matching_owner(self):
        for result, owner in [({}, "client"), ({"clientId": "test-client"}, "other"), (None, None)]:
            with self.subTest(result=result):
                def initialize(connection, request):
                    write_message(connection, success(request, result, owner=owner))
                with Stub(None, initialize=initialize) as stub:
                    with self.assertRaises(DesktopIPCError) as caught:
                        DesktopIPC(stub.path)
                    self.assertEqual(caught.exception.code, "invalid-response")

    def test_malformed_frames_and_eof_fail_closed_without_payload_text(self):
        cases = [
            (struct.pack("<I", 0), "malformed-frame"),
            (struct.pack("<I", desktop_ipc.MAX_FRAME_BYTES + 1), "oversized-frame"),
            (struct.pack("<I", 3) + b"{!?", "malformed-frame"),
            (struct.pack("<I", 1) + b"\xff", "malformed-frame"),
            (struct.pack("<I", 2) + b"[]", "malformed-frame"),
            (struct.pack("<I", 7) + b'{"x":1}', "invalid-response"),
            (struct.pack("<I", 13) + b'{"a":1,"a":2}', "malformed-frame"),
            (struct.pack("<I", 9) + b'{"x":NaN}', "malformed-frame"),
            (b"\x00\x00", "disconnected"),
            (struct.pack("<I", 100) + b"SECRET partial", "disconnected"),
        ]
        for frame, expected in cases:
            with self.subTest(expected=expected, frame=frame[:8]):
                def handle(connection, _stub):
                    read_message(connection)
                    connection.sendall(frame)
                with Stub(handle) as stub, DesktopIPC(stub.path) as ipc:
                    with self.assertRaises(DesktopIPCError) as caught:
                        ipc.request("synthetic-read", {})
                    self.assertEqual(caught.exception.code, expected)
                    self.assertNotIn("SECRET", str(caught.exception))
                    with self.assertRaises(DesktopIPCError) as closed:
                        ipc.request("synthetic-read", {})
                    self.assertEqual(closed.exception.code, "closed")

    def test_wrong_method_wrong_owner_and_invalid_response_shapes_fail_closed(self):
        variants = [
            {"method": "wrong"}, {"handledByClientId": "wrong"},
            {"resultType": "unexpected"}, {"requestId": None},
            {"type": "unsupported"},
        ]
        for changes in variants:
            with self.subTest(changes=changes):
                def handle(connection, _stub):
                    request = read_message(connection)
                    write_message(connection, success(request, {}, **changes))
                with Stub(handle) as stub, DesktopIPC(stub.path) as ipc:
                    with self.assertRaises(DesktopIPCError) as caught:
                        ipc.request("synthetic-read", {}, target="desktop-owner")
                    self.assertEqual(caught.exception.code, "invalid-response")

    def test_message_and_byte_budgets_bound_interleaved_buffers(self):
        for field, value in [("MAX_BUFFERED_MESSAGES", 2), ("MAX_BUFFERED_BYTES", 250)]:
            with self.subTest(field=field):
                def handle(connection, _stub):
                    request = read_message(connection)
                    for index in range(4):
                        write_message(connection, broadcast(params={"index": index, "padding": "x" * 100}))
                    write_message(connection, success(request, {}))
                with Stub(handle) as stub, DesktopIPC(stub.path) as ipc:
                    with mock.patch.object(desktop_ipc, field, value):
                        with self.assertRaises(DesktopIPCError) as caught:
                            ipc.request("synthetic-read", {})
                    self.assertEqual(caught.exception.code, "buffer-overflow")

    def test_timeout_and_cancellation_bound_waits_and_close_the_socket(self):
        for cancelled in [False, True]:
            with self.subTest(cancelled=cancelled):
                stop = threading.Event()
                def handle(connection, stub):
                    read_message(connection)
                    if cancelled:
                        stop.set()
                    stub.finish.wait(1)
                with Stub(handle) as stub, DesktopIPC(stub.path, should_stop=stop.is_set) as ipc:
                    started = time.monotonic()
                    with self.assertRaises(DesktopIPCError) as caught:
                        ipc.request("synthetic-read", {}, timeout=0.08 if not cancelled else 2)
                    self.assertEqual(caught.exception.code, "cancelled" if cancelled else "timeout")
                    self.assertLess(time.monotonic() - started, 0.25)

    def test_oversized_outgoing_request_and_invalid_arguments_send_nothing(self):
        def handle(connection, _stub):
            request = read_message(connection)
            self.assertEqual(request["method"], "valid")
            write_message(connection, success(request, True))
        with Stub(handle) as stub, DesktopIPC(stub.path) as ipc:
            with mock.patch.object(desktop_ipc, "MAX_FRAME_BYTES", 1024):
                with self.assertRaises(DesktopIPCError) as caught:
                    ipc.request("oversized", {"content": "x" * 2000})
                self.assertEqual(caught.exception.code, "oversized-frame")
                for operation in [
                    lambda: ipc.request("bad", {}, version=True),
                    lambda: ipc.request("bad", {}, target=""),
                    lambda: ipc.request("bad", {}, timeout=0),
                    lambda: ipc.request("bad", {}, timeout=float("inf")),
                    lambda: ipc.request("bad", {"not-json": float("nan")}),
                    lambda: ipc.request("initialize", {}),
                    lambda: ipc.broadcast("bad", {}, targets="owner"),
                    lambda: ipc.broadcast("bad", {}, timeout=0),
                ]:
                    with self.assertRaises(DesktopIPCError) as caught:
                        operation()
                    self.assertEqual(caught.exception.code, "invalid-request")
                self.assertTrue(ipc.request("valid", {}))

    def test_broadcast_timeout_bounds_a_backpressured_cleanup_send(self):
        def handle(_connection, stub):
            # Stop reading after initialization so a large local broadcast must
            # wait for socket capacity instead of completing in one write.
            stub.finish.wait(1)
        with Stub(handle) as stub, DesktopIPC(stub.path, timeout=12) as ipc:
            ipc.sock.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 1024)
            started = time.monotonic()
            with self.assertRaises(DesktopIPCError) as caught:
                ipc.broadcast("synthetic-cleanup", {"padding": "x" * (256 * 1024)}, timeout=0.06)
            self.assertEqual(caught.exception.code, "timeout")
            self.assertLess(time.monotonic() - started, 0.25)
            with self.assertRaises(DesktopIPCError) as closed:
                ipc.broadcast("synthetic-cleanup", {}, timeout=0.06)
            self.assertEqual(closed.exception.code, "closed")

    def test_missing_socket_symlink_and_invalid_timeout_are_rejected_without_connection(self):
        with tempfile.TemporaryDirectory(prefix="whip-missing-", dir="/tmp") as temporary:
            with self.assertRaises(DesktopIPCError) as caught:
                DesktopIPC(Path(temporary) / "absent")
            self.assertEqual(caught.exception.code, "unavailable")
        with Stub(lambda _connection, _stub: None) as stub:
            link = stub.path.with_name("linked.sock")
            link.symlink_to(stub.path)
            with self.assertRaises(DesktopIPCError) as caught:
                DesktopIPC(link)
            self.assertEqual(caught.exception.code, "unavailable")
        for value in [0, -1, True, float("nan"), "12"]:
            with self.assertRaises(DesktopIPCError) as caught:
                DesktopIPC("/not-used", timeout=value)
            self.assertEqual(caught.exception.code, "invalid-request")

    def test_close_is_idempotent_and_context_manager_closes_peer(self):
        closed = threading.Event()
        def handle(connection, _stub):
            self.assertEqual(connection.recv(1), b"")
            closed.set()
        with Stub(handle) as stub:
            with DesktopIPC(stub.path) as ipc:
                pass
            ipc.close()
            self.assertTrue(closed.wait(1))
            with self.assertRaises(DesktopIPCError) as caught:
                ipc.broadcast("synthetic", {})
            self.assertEqual(caught.exception.code, "closed")


if __name__ == "__main__":
    unittest.main()
