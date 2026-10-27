"""Bounded local transport for Desktop's versioned coordination messages.

Only one caller reads the socket at a time. Requests can receive broadcasts or
discovery questions while waiting; those messages never become request results.
The caller validates each method's response and broadcast schema separately.
"""

from collections import deque
import errno
import json
import math
import os
from pathlib import Path
import select
import socket
import stat
import struct
import threading
import time
import uuid


MAX_FRAME_BYTES = 16 * 1024 * 1024
MAX_BUFFERED_BYTES = 32 * 1024 * 1024
MAX_BUFFERED_MESSAGES = 128
POLL_SECONDS = 0.05

_ERROR_MESSAGES = {
    "unavailable": "Desktop's local connection is unavailable.",
    "closed": "Desktop's local connection is closed.",
    "disconnected": "Desktop's local connection ended.",
    "cancelled": "Desktop's local request was cancelled.",
    "timeout": "Desktop's local request timed out.",
    "invalid-request": "The Desktop request is invalid.",
    "invalid-response": "Desktop returned an unsupported response.",
    "malformed-frame": "Desktop returned an invalid message.",
    "oversized-frame": "Desktop's local message exceeds the supported size.",
    "buffer-overflow": "Desktop sent too many pending messages.",
    "no-client-found": "The Desktop conversation has no active owner.",
    "method-not-found": "Desktop does not support this operation.",
    "unsupported-version": "Desktop does not support this protocol version.",
    "version-mismatch": "Desktop does not support this protocol version.",
    "request-timeout": "Desktop could not finish the local request in time.",
    "request-failed": "Desktop could not finish the local request.",
}


class DesktopIPCError(RuntimeError):
    """Stable error codes and public-safe text; never includes a remote payload."""

    def __init__(self, code="request-failed"):
        self.code = code if isinstance(code, str) and code in _ERROR_MESSAGES else "request-failed"
        super().__init__(_ERROR_MESSAGES[self.code])


def _object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("Duplicate message field")
        result[key] = value
    return result


def _nonfinite(_value):
    raise ValueError("Nonfinite JSON number")


class DesktopIPC:
    def __init__(self, path, timeout=12, should_stop=lambda: False):
        self.timeout = self._timeout(timeout)
        self.should_stop = should_stop
        self.client_id = None
        self._closed = False
        self._operation = threading.RLock()
        self._broadcasts = deque()
        self._responses = {}
        self._buffered_bytes = 0
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.setblocking(False)
        try:
            self._connect(Path(path), time.monotonic() + self.timeout)
            response = self.request_full("initialize", {"clientType": "codex_whip"},
                                         version=0, timeout=min(self.timeout, 5))
            result = response.get("result")
            client = result.get("clientId") if isinstance(result, dict) else None
            if (not isinstance(client, str) or not client or len(client) > 512
                    or response.get("handledByClientId") != client):
                self._fatal("invalid-response")
            self.client_id = client
        except BaseException:
            self.close()
            raise

    @staticmethod
    def _timeout(value):
        if (isinstance(value, bool) or not isinstance(value, (int, float))
                or not math.isfinite(value) or value <= 0):
            raise DesktopIPCError("invalid-request")
        return float(value)

    def _check(self, deadline):
        if self._closed:
            raise DesktopIPCError("closed")
        if self.should_stop():
            self._fatal("cancelled")
        if time.monotonic() >= deadline:
            self._fatal("timeout")

    def _wait(self, deadline, writable=False):
        while True:
            self._check(deadline)
            try:
                readers, writers, _ = select.select(
                    [] if writable else [self.sock], [self.sock] if writable else [], [],
                    min(POLL_SECONDS, max(0, deadline - time.monotonic())),
                )
            except (OSError, ValueError):
                self._fatal("disconnected")
            if (writers if writable else readers):
                self._check(deadline)
                return

    def _connect(self, path, deadline):
        self._check(deadline)
        try:
            metadata = path.lstat()
            if not stat.S_ISSOCK(metadata.st_mode) or metadata.st_uid != os.getuid():
                self._fatal("unavailable")
            result = self.sock.connect_ex(str(path))
            if result not in (0, errno.EISCONN):
                if result not in (errno.EINPROGRESS, errno.EALREADY, errno.EWOULDBLOCK):
                    self._fatal("unavailable")
                self._wait(deadline, writable=True)
                if self.sock.getsockopt(socket.SOL_SOCKET, socket.SO_ERROR):
                    self._fatal("unavailable")
            self.sock.getpeername()
        except OSError:
            self._fatal("unavailable")

    def _fatal(self, code):
        self.close()
        raise DesktopIPCError(code) from None

    def _send(self, message, deadline):
        self._check(deadline)
        try:
            payload = json.dumps(message, ensure_ascii=False, separators=(",", ":"),
                                 allow_nan=False).encode("utf-8")
        except (TypeError, ValueError, UnicodeError, RecursionError):
            raise DesktopIPCError("invalid-request") from None
        if not payload or len(payload) > MAX_FRAME_BYTES:
            raise DesktopIPCError("oversized-frame")
        data = memoryview(struct.pack("<I", len(payload)) + payload)
        while data:
            self._check(deadline)
            try:
                written = self.sock.send(data)
                if written == 0:
                    self._fatal("disconnected")
                data = data[written:]
            except (BlockingIOError, InterruptedError):
                self._wait(deadline, writable=True)
            except OSError:
                self._fatal("disconnected")

    def _read_exact(self, size, deadline):
        data = bytearray()
        while len(data) < size:
            self._check(deadline)
            try:
                chunk = self.sock.recv(size - len(data))
                if not chunk:
                    self._fatal("disconnected")
                data.extend(chunk)
            except (BlockingIOError, InterruptedError):
                self._wait(deadline)
            except OSError:
                self._fatal("disconnected")
        return data

    def _receive(self, deadline):
        size = struct.unpack("<I", self._read_exact(4, deadline))[0]
        if size == 0:
            self._fatal("malformed-frame")
        if size > MAX_FRAME_BYTES:
            self._fatal("oversized-frame")
        try:
            value = json.loads(self._read_exact(size, deadline).decode("utf-8"),
                               object_pairs_hook=_object, parse_constant=_nonfinite)
        except (ValueError, UnicodeError, RecursionError):
            self._fatal("malformed-frame")
        if not isinstance(value, dict):
            self._fatal("malformed-frame")
        return size, value

    @staticmethod
    def _identifier(value):
        return isinstance(value, str) and 0 < len(value) <= 512

    def _route(self, size, message, deadline):
        self._check(deadline)
        kind = message.get("type")
        if kind == "client-discovery-request":
            if not self._identifier(message.get("requestId")):
                self._fatal("invalid-response")
            self._send({"type": "client-discovery-response", "requestId": message["requestId"],
                        "response": {"canHandle": False}}, deadline)
            return
        if kind == "response":
            identifier = message.get("requestId")
            if (not self._identifier(identifier)
                    or message.get("resultType") not in ("success", "error")
                    or identifier in self._responses):
                self._fatal("invalid-response")
        elif kind == "broadcast":
            if (not isinstance(message.get("method"), str) or not message["method"]
                    or isinstance(message.get("version"), bool)
                    or not isinstance(message.get("version"), int)):
                self._fatal("invalid-response")
        else:
            self._fatal("invalid-response")
        if (len(self._broadcasts) + len(self._responses) >= MAX_BUFFERED_MESSAGES
                or self._buffered_bytes + size > MAX_BUFFERED_BYTES):
            self._fatal("buffer-overflow")
        self._buffered_bytes += size
        if kind == "response":
            self._responses[identifier] = (size, message)
        else:
            self._broadcasts.append((size, message))

    def request_full(self, method, params, version=1, target=None, timeout=None):
        """Return the successful response envelope, retaining its owner identity."""
        with self._operation:
            duration = self.timeout if timeout is None else self._timeout(timeout)
            self._validate_call(method, params, version)
            if target is not None and not self._identifier(target):
                raise DesktopIPCError("invalid-request")
            if method == "initialize" and self.client_id is not None:
                raise DesktopIPCError("invalid-request")
            deadline = time.monotonic() + duration
            identifier = str(uuid.uuid4())
            message = {"type": "request", "requestId": identifier,
                       "sourceClientId": self.client_id or "initializing-client",
                       "version": version, "method": method, "params": params,
                       "timeoutMs": max(1, math.ceil(duration * 1000))}
            if target is not None:
                message["targetClientId"] = target
            self._send(message, deadline)
            while identifier not in self._responses:
                self._route(*self._receive(deadline), deadline)
            size, response = self._responses.pop(identifier)
            self._buffered_bytes -= size
            if response["resultType"] == "error":
                raise DesktopIPCError(response.get("error"))
            if (response.get("method", method) != method
                    or (target is not None and response.get("handledByClientId") != target)):
                self._fatal("invalid-response")
            return response

    def request(self, method, params, version=1, target=None, timeout=None):
        return self.request_full(method, params, version, target, timeout).get("result")

    @staticmethod
    def _validate_call(method, params, version):
        if (not isinstance(method, str) or not method or not isinstance(params, dict)
                or isinstance(version, bool) or not isinstance(version, int) or version < 0):
            raise DesktopIPCError("invalid-request")

    def broadcast(self, method, params, version=1, targets=None, timeout=None):
        with self._operation:
            duration = self.timeout if timeout is None else self._timeout(timeout)
            self._validate_call(method, params, version)
            message = {"type": "broadcast", "sourceClientId": self.client_id,
                       "version": version, "method": method, "params": params}
            if targets is not None:
                if (not isinstance(targets, (list, tuple))
                        or not all(self._identifier(value) for value in targets)):
                    raise DesktopIPCError("invalid-request")
                message["targetClientIds"] = list(targets)
            self._send(message, time.monotonic() + duration)

    def wait_broadcast(self, predicate, timeout=None):
        with self._operation:
            duration = self.timeout if timeout is None else self._timeout(timeout)
            deadline = time.monotonic() + duration
            while True:
                self._check(deadline)
                for index, (size, message) in enumerate(self._broadcasts):
                    if predicate(message):
                        del self._broadcasts[index]
                        self._buffered_bytes -= size
                        return message
                self._route(*self._receive(deadline), deadline)

    def close(self):
        if self._closed:
            return
        self._closed = True
        try:
            self.sock.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        self.sock.close()
        self._broadcasts.clear()
        self._responses.clear()
        self._buffered_bytes = 0

    def __enter__(self):
        return self

    def __exit__(self, *_exc):
        self.close()
