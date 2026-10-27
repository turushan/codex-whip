#!/usr/bin/env python3
"""Retry capacity failures and resume quota-blocked loaded Codex terminal sessions."""

from __future__ import annotations

import argparse
import base64
import errno
import fcntl
import hashlib
import json
import logging
from logging.handlers import RotatingFileHandler
import math
import os
from pathlib import Path
import plistlib
import secrets
import select
import signal
import socket
import sqlite3
import struct
import subprocess
import sys
import time

from history import History, RETENTION_SECONDS, read_report
from settings import (DEFAULT_MESSAGE, DEFAULT_SETTINGS, ScanScheduler, SettingsError,
                      read_settings, save_settings, settings_envelope, validate_settings)


VERSION = "1.9.0"
LABEL = "com.aktay.codex-keep-going"
INTERVAL = DEFAULT_SETTINGS["retry_seconds"]
SCAN_INTERVAL = DEFAULT_SETTINGS["scan_seconds"]
SUCCESS_SECONDS = 120
MAX_OBSERVATION_GAP = 90
MESSAGE = DEFAULT_MESSAGE
CAPACITY_MESSAGE = "Selected model is at capacity. Please try a different model"


class RPCError(RuntimeError):
    pass


class RequestError(RPCError):
    """A rejected RPC request, while the transport remains usable."""


class RPCCancelled(RPCError):
    """The owning worker is stopping; this is not a connection failure."""


class WebSocketRPC:
    """Small RFC 6455 client for Codex's local control socket, with no packages."""

    def __init__(self, path: Path, timeout: float = 10, should_stop=None):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(timeout)
        self.timeout = timeout
        self.should_stop = should_stop
        self.buffer = bytearray()
        self.sequence = 0
        self.events = []
        self.deadline = None
        try:
            self._connect(path)
            self.deadline = time.monotonic() + timeout
            key = base64.b64encode(secrets.token_bytes(16)).decode()
            self._send_bytes((
                "GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\n"
                "Connection: Upgrade\r\nSec-WebSocket-Version: 13\r\n"
                f"Sec-WebSocket-Key: {key}\r\n\r\n"
            ).encode())
            while b"\r\n\r\n" not in self.buffer:
                self._receive()
                if len(self.buffer) > 65536:
                    raise RPCError("Oversized WebSocket handshake")
            header, rest = bytes(self.buffer).split(b"\r\n\r\n", 1)
            self.buffer = bytearray(rest)
            lines = header.decode("ascii").split("\r\n")
            headers = {name.lower(): value.strip() for name, value in
                       (line.split(":", 1) for line in lines[1:] if ":" in line)}
            expected = base64.b64encode(hashlib.sha1(
                (key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()
            ).digest()).decode()
            if (lines[0].split()[1] != "101"
                    or headers.get("sec-websocket-accept", "") != expected):
                raise RPCError("Codex control socket did not accept WebSocket upgrade")
            self.deadline = None
            self.call("initialize", {
                "clientInfo": {"name": "codex_whip", "title": "Codex Whip", "version": VERSION},
                "capabilities": {"experimentalApi": True},
            })
            self._send_json({"method": "initialized"})
        except BaseException:
            self.close()
            raise

    def close(self):
        self.sock.close()

    def _check_cancelled(self):
        callback = getattr(self, "should_stop", None)
        if callback is not None and callback():
            raise RPCCancelled("Codex request cancelled because the worker is stopping")

    def _connect(self, path):
        if self.should_stop is None:
            self.sock.connect(str(path))
            return
        deadline = time.monotonic() + self.timeout
        self.sock.setblocking(False)
        while True:
            self._check_cancelled()
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise socket.timeout("Codex connection timed out")
            error = self.sock.connect_ex(str(path))
            if error in (0, errno.EISCONN):
                break
            if error in (errno.EAGAIN, errno.EWOULDBLOCK):
                time.sleep(min(0.25, remaining))
                continue
            if error not in (errno.EINPROGRESS, errno.EALREADY):
                raise OSError(error, os.strerror(error))
            _, writable, failed = select.select([], [self.sock], [self.sock], min(0.25, remaining))
            if writable or failed:
                error = self.sock.getsockopt(socket.SOL_SOCKET, socket.SO_ERROR)
                if error:
                    raise OSError(error, os.strerror(error))
                break
        self.sock.settimeout(self.timeout)

    def _send_bytes(self, payload):
        self._check_cancelled()
        if getattr(self, "should_stop", None) is None:
            self.sock.sendall(payload)
            return
        deadline = self.deadline if self.deadline is not None else time.monotonic() + self.timeout
        remaining_payload = memoryview(payload)
        while remaining_payload:
            self._check_cancelled()
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise RPCError("Codex send deadline exceeded")
            self.sock.settimeout(min(0.25, remaining))
            try:
                sent = self.sock.send(remaining_payload)
            except socket.timeout:
                continue
            if not sent:
                raise RPCError("Codex control socket closed during send")
            remaining_payload = remaining_payload[sent:]

    def _receive(self):
        self._check_cancelled()
        if getattr(self, "should_stop", None) is not None:
            deadline = self.deadline if self.deadline is not None else time.monotonic() + self.timeout
            while True:
                self._check_cancelled()
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise RPCError("Codex response deadline exceeded")
                self.sock.settimeout(min(0.25, remaining))
                try:
                    data = self.sock.recv(65536)
                except socket.timeout:
                    continue
                self._check_cancelled()
                if not data:
                    raise RPCError("Codex control socket closed")
                self.buffer.extend(data)
                return
        if self.deadline is not None:
            remaining = self.deadline - time.monotonic()
            if remaining <= 0:
                raise RPCError("Codex response deadline exceeded")
            self.sock.settimeout(min(10, remaining))
        data = self.sock.recv(65536)
        if not data:
            raise RPCError("Codex control socket closed")
        self.buffer.extend(data)

    def _read(self, count):
        self._check_cancelled()
        while len(self.buffer) < count:
            self._receive()
        result = bytes(self.buffer[:count])
        del self.buffer[:count]
        return result

    def _send_frame(self, opcode, payload):
        size = len(payload)
        header = bytes([0x80 | opcode])
        if size < 126:
            header += bytes([0x80 | size])
        elif size < 65536:
            header += bytes([0x80 | 126]) + struct.pack("!H", size)
        else:
            header += bytes([0x80 | 127]) + struct.pack("!Q", size)
        mask = secrets.token_bytes(4)
        masked = bytes(value ^ mask[i % 4] for i, value in enumerate(payload))
        self._send_bytes(header + mask + masked)

    def _send_json(self, value):
        self._send_frame(1, json.dumps(value).encode())

    def _message(self):
        chunks = bytearray()
        started = False
        while True:
            first, second = self._read(2)
            final, opcode = bool(first & 0x80), first & 0x0F
            if first & 0x70:
                raise RPCError("Unsupported WebSocket extension")
            size = second & 0x7F
            if size == 126:
                size = struct.unpack("!H", self._read(2))[0]
            elif size == 127:
                size = struct.unpack("!Q", self._read(8))[0]
            if size > 32 * 1024 * 1024:
                raise RPCError("Oversized WebSocket message")
            mask = self._read(4) if second & 0x80 else None
            payload = self._read(size)
            if mask:
                payload = bytes(value ^ mask[i % 4] for i, value in enumerate(payload))
            if opcode == 8:
                raise RPCError("Codex closed the WebSocket connection")
            if opcode == 9:
                self._send_frame(10, payload)
                continue
            if opcode == 10:
                continue
            if opcode == 1 and not started:
                started = True
            elif opcode != 0 or not started:
                raise RPCError("Unexpected WebSocket frame")
            chunks.extend(payload)
            if len(chunks) > 32 * 1024 * 1024:
                raise RPCError("Oversized WebSocket message")
            if final:
                return json.loads(chunks)

    def call(self, method, params):
        self.sequence += 1
        request_id = self.sequence
        self._send_json({"id": request_id, "method": method, "params": params})
        self.deadline = time.monotonic() + 15
        try:
            while time.monotonic() < self.deadline:
                value = self._message()
                if value.get("id") == request_id and "method" not in value:
                    if "error" in value:
                        error = value["error"]
                        raise RequestError(f"{method}: {error.get('message', 'RPC failed')}")
                    return value["result"]
                # Leave interactive requests to the user's Codex client. Even an
                # error reply could resolve an approval that belongs to the UI.
                self.events.append(value)
                self.events = self.events[-100:]
            raise RPCError(f"{method}: response deadline exceeded")
        finally:
            self.deadline = None


def is_capacity(turn):
    if not turn or turn.get("status") != "failed":
        return False
    error = turn.get("error") or {}
    info = error.get("codexErrorInfo")
    # A specific non-capacity code always wins over a matching message.
    return info == "serverOverloaded" or (
        info in (None, "other")
        and error.get("message", "").strip().rstrip(".") == CAPACITY_MESSAGE
    )


def is_quota(turn):
    """Only Codex's explicit included-usage error can arm a quota wait."""
    return bool(turn and turn.get("status") == "failed"
                and (turn.get("error") or {}).get("codexErrorInfo") == "usageLimitExceeded")


def failure_kind(turn):
    if is_capacity(turn):
        return "capacity"
    if is_quota(turn):
        return "quota"
    return None


def quota_snapshot(rpc):
    """Return only a private account binding and explicit permission, never balances."""
    value = rpc.call("account/rateLimits/read", {"excludeResetCreditDetails": True})
    if not isinstance(value, dict):
        return None, None
    identity = value.get("accountId")
    binding = (hashlib.sha256(identity.encode("utf-8")).hexdigest()
               if isinstance(identity, str) and identity.strip() else None)
    permission = value.get("ordinaryUsageAllowed")
    return binding, permission if isinstance(permission, bool) else None


def loaded_threads(rpc):
    result, cursor = [], None
    while True:
        page = rpc.call("thread/loaded/list", {"cursor": cursor, "limit": 100})
        result.extend(page["data"])
        cursor = page.get("nextCursor")
        if not cursor:
            return result


def snapshot(rpc, thread_id, verify=False):
    thread = rpc.call("thread/read", {"threadId": thread_id, "includeTurns": False})["thread"]
    if not eligible(thread):
        return thread, None
    turns = rpc.call("thread/turns/list", {
        "threadId": thread_id, "limit": 1, "sortDirection": "desc", "itemsView": "notLoaded",
    })["data"]
    if verify:
        # Runtime status is the final read immediately before submission.
        thread = rpc.call("thread/read", {"threadId": thread_id, "includeTurns": False})["thread"]
    return thread, turns[0] if turns else None


def watchable(thread):
    source = thread.get("source")
    return (
        not thread.get("parentThreadId")
        and not thread.get("ephemeral")
        and thread.get("threadSource") in (None, "user")
        and not isinstance(source, dict)
        and source in ("cli", "vscode", "appServer")
        and (source == "cli" or thread.get("originator") == "codex-tui")
        and thread.get("canAcceptDirectInput") is True
        and bool(thread.get("model"))
    )


def eligible(thread):
    return watchable(thread) and thread.get("status", {}).get("type") in ("idle", "systemError")


class RetryEngine:
    def __init__(self, state, save, emit, interval=INTERVAL, threads=(), should_stop=lambda: False,
                 scan_interval=SCAN_INTERVAL, message=MESSAGE):
        self.state, self.save, self.emit = state, save, emit
        self.interval, self.threads = interval, set(threads)
        self.should_stop = should_stop
        self.scan_interval, self.message = scan_interval, message
        self.max_observation_gap = MAX_OBSERVATION_GAP
        self._observed_at, self._retry_after = {}, {}
        for key in ("pending", "handled", "paused"):
            state.setdefault(key, {})
        # Saved timestamps are useful evidence, but downtime never contributes
        # to a new process's continuous observation window.
        self.reset_observations()

    def apply_settings(self, value):
        value = validate_settings(value)
        changed = False
        if value["scan_seconds"] != self.scan_interval:
            self.reset_observations()
        for pending in self.state["pending"].values():
            if pending.get("kind") == "quota":
                checked = pending.get("quota_checked_at", pending.get("detected_at", 0))
                due = checked + value["scan_seconds"]
                if due != pending["due_at"]:
                    pending["due_at"] = due
                    changed = True
                continue
            if "wait_started_at" not in pending:
                pending["wait_started_at"] = pending["due_at"] - self.interval
                changed = True
            due = pending["wait_started_at"] + value["retry_seconds"]
            if due != pending["due_at"]:
                pending["due_at"] = due
                changed = True
        self.interval = value["retry_seconds"]
        self.scan_interval = value["scan_seconds"]
        self.message = value["message"]
        self.max_observation_gap = MAX_OBSERVATION_GAP
        if changed:
            self.save(self.state)

    def maintenance_due(self, now):
        """Known retry deadlines and health observations do not wait for discovery."""
        for thread_id, pending in self.state["pending"].items():
            if (pending.get("due_at", now + self.scan_interval) <= now
                    and self._retry_after.get(thread_id, 0) <= now):
                return True
        interval = min(30, self.scan_interval)
        return any(attempt.get("outcome") == "submitted" and not attempt.get("result_status")
                   and max(self._observed_at.get(thread_id, attempt.get("at", now)) + interval,
                           self._retry_after.get(thread_id, 0)) <= now
                   for thread_id, attempt in self.state["handled"].items())

    def step(self, rpc, now, discover=True):
        try:
            self._step(rpc, now, discover)
        except Exception:
            self.reset_observations()
            raise

    def _step(self, rpc, now, discover):
        loaded = set(loaded_threads(rpc))
        allowed = loaded & self.threads if self.threads else loaded
        tracked = {thread_id for thread_id, attempt in self.state["handled"].items()
                   if attempt.get("outcome") == "submitted" and not attempt.get("result_status")}
        targets = allowed if discover else allowed & (set(self.state["pending"]) | tracked)
        quota_candidates = []
        counts = {"total": 0, "active": 0, "idle": 0, "errored": 0, "other": 0, "unavailable": 0}
        for thread_id in self.state["handled"]:
            if thread_id not in allowed or thread_id in self.state["paused"]:
                self.reset_observations(thread_id)
        for thread_id in list(self.state["pending"]):
            if thread_id not in allowed or thread_id in self.state["paused"]:
                self._cancel(thread_id, "session unloaded or paused")
        for thread_id in sorted(targets):
            if self.should_stop():
                return
            if thread_id in self.state["paused"]:
                continue
            try:
                thread, turn = snapshot(rpc, thread_id)
                self._observe_result(rpc, thread_id, turn, now, thread)
            except RequestError as error:
                self.reset_observations(thread_id)
                self._retry_after[thread_id] = now + min(30, self.scan_interval)
                counts["unavailable"] += 1
                self.emit("thread_unavailable", thread_id=thread_id, message=str(error))
                continue
            if watchable(thread):
                counts["total"] += 1
                runtime = thread.get("status", {}).get("type")
                category = {"active": "active", "idle": "idle", "systemError": "errored"}.get(runtime, "other")
                counts[category] += 1
            pending = self.state["pending"].get(thread_id)
            kind = failure_kind(turn)
            if not eligible(thread) or kind is None:
                if pending:
                    self._cancel(thread_id, "session changed or recovered")
                continue
            turn_id = turn["id"]
            completed = turn.get("completedAt")
            if (isinstance(completed, bool) or not isinstance(completed, (int, float))
                    or not math.isfinite(completed) or completed < self.state["enabled_at"]):
                if pending:
                    self._cancel(thread_id, "failure timestamp is unavailable or predates activation")
                continue
            handled = self.state["handled"].get(thread_id, {})
            if handled.get("turn_id") == turn_id:
                continue
            if pending and pending["turn_id"] != turn_id:
                self._cancel(thread_id, "a newer turn replaced the failure")
                pending = None
            if pending and pending.get("kind", "capacity") != kind:
                self._cancel(thread_id, "failure classification changed")
                continue
            if pending and (pending["model"] != thread["model"]
                            or pending["effort"] != thread.get("reasoningEffort")):
                self._cancel(thread_id, "selected model or reasoning changed")
                continue
            if pending is None:
                pending = {
                    "turn_id": turn_id, "model": thread["model"],
                    "effort": thread.get("reasoningEffort"),
                    "detected_at": now,
                    "wait_started_at": max(now, completed),
                    "due_at": max(now, completed) + (self.scan_interval if kind == "quota" else self.interval),
                }
                if kind == "quota":
                    pending.update(kind="quota", quota_status="unknown")
                self.state["pending"][thread_id] = pending
                self.save(self.state)
                self.emit("quota_waiting" if kind == "quota" else "waiting",
                          thread_id=thread_id, **pending)
                if kind == "quota":
                    quota_candidates.append((thread_id, True))
            if kind == "quota":
                if now >= pending["due_at"] and self._retry_after.get(thread_id, 0) <= now:
                    quota_candidates.append((thread_id, False))
                continue
            if now < pending["due_at"]:
                continue
            self._send_retry(rpc, thread_id, pending, now)
        if quota_candidates and not self.should_stop():
            self._check_quota(rpc, quota_candidates, now)
        for thread_id, attempt in list(self.state["handled"].items()):
            if self.should_stop():
                return
            if attempt.get("outcome") != "submitted" or attempt.get("result_status"):
                continue
            if attempt.get("at", now) < now - RETENTION_SECONDS:
                attempt["result_status"] = "unknown"
                self.save(self.state)
                continue
            if thread_id in allowed:
                continue
            # Finished CLI sessions may unload before the next scan. Their
            # persisted turns still provide outcomes without resuming any work.
            try:
                self._observe_result(rpc, thread_id, None, now)
            except RequestError as error:
                self.reset_observations(thread_id)
                self.emit("thread_unavailable", thread_id=thread_id, message=str(error))
        if discover:
            self.state["sessions"] = counts

    def _check_quota(self, rpc, candidates, now):
        # One fresh snapshot serves the eligible quota waits due in this batch.
        # Nothing from this response is emitted or logged.
        try:
            binding, permission = quota_snapshot(rpc)
        except RequestError:
            binding, permission = None, None
        except RPCError:
            self._defer_quota(candidates, now)
            raise RPCError("Codex quota status could not be read.") from None
        for thread_id, new_wait in candidates:
            if self.should_stop():
                return
            pending = self.state["pending"].get(thread_id)
            if pending is None or pending.get("kind") != "quota":
                continue
            previous = pending.get("account_binding")
            pending["quota_checked_at"] = now
            pending["due_at"] = now + self.scan_interval
            if binding is None or permission is None:
                pending["quota_status"] = "unknown"
            elif previous is not None and previous != binding:
                pending["quota_status"] = "account_changed"
            else:
                pending["quota_status"] = "waiting"
            if previous is None and binding is not None:
                pending["account_binding"] = binding
            self.save(self.state)
            # First observation binds the account. Only a subsequent fresh read
            # for that same identity can authorize a continuation attempt.
            if (not new_wait and previous is not None and previous == binding
                    and permission is True):
                self._send_retry(rpc, thread_id, pending, now)

    def _defer_quota(self, candidates, now):
        for thread_id, _new_wait in candidates:
            pending = self.state["pending"].get(thread_id)
            if pending and pending.get("kind") == "quota":
                pending.update(quota_checked_at=now, due_at=now + self.scan_interval,
                               quota_status="unknown")
        self.save(self.state)

    def _send_retry(self, rpc, thread_id, pending, now):
        kind = pending.get("kind", "capacity")
        try:
            latest_thread, latest_turn = snapshot(rpc, thread_id, verify=True)
        except RequestError as error:
            self._retry_after[thread_id] = now + min(30, self.scan_interval)
            self.emit("thread_unavailable", thread_id=thread_id, message=str(error))
            return
        if (not eligible(latest_thread) or failure_kind(latest_turn) != kind
                or latest_turn["id"] != pending["turn_id"]
                or latest_thread["model"] != pending["model"]
                or latest_thread.get("reasoningEffort") != pending["effort"]):
            self._cancel(thread_id, "session changed before retry")
            return
        if kind == "quota":
            # Another session or a manual login can change the active account
            # after the batch poll. Revalidate separately for each continuation.
            try:
                binding, permission = quota_snapshot(rpc)
            except RequestError:
                binding, permission = None, None
            except RPCError:
                pending["quota_status"] = "unknown"
                self.save(self.state)
                raise RPCError("Codex quota status could not be read.") from None
            if binding is None or permission is None:
                pending["quota_status"] = "unknown"
            elif binding != pending.get("account_binding"):
                pending["quota_status"] = "account_changed"
            else:
                pending["quota_status"] = "waiting"
            self.save(self.state)
            if permission is not True or binding != pending.get("account_binding") or binding is None:
                return
            # The quota read can take time. Check the latest turn and runtime
            # again afterward, leaving runtime status as the final RPC read.
            try:
                latest_thread, latest_turn = snapshot(rpc, thread_id, verify=True)
            except RequestError as error:
                self._retry_after[thread_id] = now + min(30, self.scan_interval)
                self.emit("thread_unavailable", thread_id=thread_id, message=str(error))
                return
            if (not eligible(latest_thread) or failure_kind(latest_turn) != kind
                    or latest_turn["id"] != pending["turn_id"]
                    or latest_thread["model"] != pending["model"]
                    or latest_thread.get("reasoningEffort") != pending["effort"]):
                self._cancel(thread_id, "session changed before retry")
                return
        if self.should_stop():
            return
        # Commit before sending. A crash or disconnect must never cause a duplicate.
        attempt = {"turn_id": pending["turn_id"], "at": now, "outcome": "uncertain",
                   "kind": kind,
                   "quota_at" if kind == "quota" else "capacity_at": pending.get("detected_at", now)}
        self.state["handled"][thread_id] = attempt
        del self.state["pending"][thread_id]
        self.save(self.state)
        if self.should_stop():
            return
        try:
            result = rpc.call("turn/start", {
                "threadId": thread_id,
                "input": [{"type": "text", "text": self.message}],
            })
        except Exception:
            self.emit("uncertain", thread_id=thread_id, turn_id=attempt["turn_id"], kind=kind)
            raise
        attempt.update(outcome="submitted", retry_turn_id=result["turn"]["id"])
        self.save(self.state)
        self.emit("retry", thread_id=thread_id, model=pending["model"], **attempt)

    def reset_observations(self, thread_id=None):
        changed = False
        attempts = ([self.state["handled"].get(thread_id, {})] if thread_id is not None
                    else self.state["handled"].values())
        for attempt in attempts:
            for key in ("healthy_since", "healthy_last_seen"):
                if key in attempt:
                    del attempt[key]
                    changed = True
        if changed:
            self.save(self.state)

    def _observe_result(self, rpc, thread_id, latest_turn, now, thread=None):
        attempt = self.state["handled"].get(thread_id, {})
        retry_id = attempt.get("retry_turn_id")
        if attempt.get("outcome") != "submitted" or not retry_id or attempt.get("result_status"):
            return
        self._observed_at[thread_id] = now
        turn = latest_turn if latest_turn and latest_turn["id"] == retry_id else None
        is_latest = turn is not None
        if turn is None:
            # A user may already have started another turn. Look up the retry's
            # own outcome instead of treating the user's newer turn as its result.
            recent = rpc.call("thread/turns/list", {
                "threadId": thread_id, "limit": 20, "sortDirection": "desc", "itemsView": "notLoaded",
            })["data"]
            turn = next((item for item in recent if item["id"] == retry_id), None)
            is_latest = bool(recent and recent[0]["id"] == retry_id)
        if turn and turn.get("status") in ("completed", "failed", "interrupted"):
            status = "successful" if turn["status"] == "completed" else turn["status"]
            self._finish_result(thread_id, attempt, status, is_capacity(turn),
                                turn.get("completedAt") if turn.get("completedAt") is not None else now)
            return
        runtime = thread.get("status", {}) if thread else {}
        healthy = (
            thread is not None and watchable(thread) and is_latest and turn is not None
            and turn.get("status") == "inProgress" and not turn.get("error")
            and runtime.get("type") == "active" and runtime.get("activeFlags") == []
        )
        if not healthy:
            self.reset_observations(thread_id)
            return
        previous = attempt.get("healthy_last_seen")
        if previous is None or now < previous or now - previous > self.max_observation_gap:
            attempt["healthy_since"] = now
        attempt["healthy_last_seen"] = now
        if now - attempt["healthy_since"] >= SUCCESS_SECONDS:
            self._finish_result(thread_id, attempt, "successful", False, now)
        else:
            self.save(self.state)

    def _finish_result(self, thread_id, attempt, status, capacity, occurred_at):
        attempt.update(result_status=status, result_at=occurred_at, result_capacity=capacity)
        attempt.pop("healthy_since", None)
        attempt.pop("healthy_last_seen", None)
        # Save the latch first. Reconciliation recreates a missed history event
        # after a crash without reclassifying an already successful retry.
        self.save(self.state)
        self.emit("retry_result", thread_id=thread_id, turn_id=attempt["retry_turn_id"],
                  status=status, capacity=capacity, occurred_at=occurred_at,
                  kind=attempt.get("kind", "capacity"))

    def _cancel(self, thread_id, reason):
        pending = self.state["pending"].pop(thread_id)
        # Do not rearm the same old failure after a model change or unload.
        self.state["handled"][thread_id] = {
            "turn_id": pending["turn_id"], "outcome": "cancelled", "reason": reason,
            "kind": pending.get("kind", "capacity"),
        }
        self.save(self.state)
        self.emit("cancelled", thread_id=thread_id, reason=reason)


def atomic_json(path, value):
    temporary = path.with_suffix(".tmp")
    with temporary.open("w", encoding="utf-8") as file:
        os.chmod(temporary, 0o600)
        json.dump(value, file, indent=2)
        file.write("\n")
        file.flush()
        os.fsync(file.fileno())
    temporary.replace(path)


def read_json(path):
    return json.loads(path.read_text())


def resolve_socket(codex_home):
    path = codex_home / "app-server-control/app-server-control.sock"
    if not path.exists():
        # The native app recognizes this opening and shows plain words instead of the path.
        raise RPCError(f"Codex daemon socket is unavailable: {path}. Open Codex first.")
    return path


def log_emitter(directory):
    logger = logging.getLogger(LABEL)
    logger.setLevel(logging.INFO)
    logger.propagate = False
    handler = RotatingFileHandler(directory / "worker.log", maxBytes=1024 * 1024, backupCount=2)
    logger.addHandler(handler)

    def report(event, **fields):
        logger.info(json.dumps({
            "time": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "event": event, **fields,
        }))

    return report


def reconcile_history(state, history, now):
    # Reconstruct events from durable state if the process stopped between its
    # state save and history write. SQLite deduplication keeps counts stable.
    for thread_id, pending in state.get("pending", {}).items():
        kind = pending.get("kind", "capacity")
        detected = pending.get("detected_at", pending["due_at"] - INTERVAL)
        history.record("quota_waiting" if kind == "quota" else "waiting",
                       thread_id=thread_id, turn_id=pending["turn_id"],
                       occurred_at=detected, kind=kind)
    for thread_id, attempt in state.get("handled", {}).items():
        at = attempt.get("at")
        if at is not None and at >= now - RETENTION_SECONDS:
            if attempt.get("capacity_at") is not None:
                history.record("waiting", thread_id=thread_id, turn_id=attempt["turn_id"],
                               occurred_at=attempt["capacity_at"])
            if attempt.get("quota_at") is not None:
                history.record("quota_waiting", thread_id=thread_id, turn_id=attempt["turn_id"],
                               occurred_at=attempt["quota_at"], kind="quota")
            fields = {**attempt, "occurred_at": at}
            if attempt.get("outcome") == "submitted" and attempt.get("retry_turn_id"):
                history.record("retry", thread_id=thread_id, **fields)
            elif attempt.get("outcome") == "uncertain":
                history.record("uncertain", thread_id=thread_id, **fields)
        if (attempt.get("result_status") in ("successful", "completed", "failed", "interrupted")
                and attempt.get("retry_turn_id") and attempt.get("result_at") is not None):
            history.record("retry_result", thread_id=thread_id, turn_id=attempt["retry_turn_id"],
                           status=attempt["result_status"], capacity=attempt.get("result_capacity", False),
                           occurred_at=attempt["result_at"], kind=attempt.get("kind", "capacity"))


def configured_parent_pid():
    """The native app opts into parent monitoring; malformed values use CLI mode."""
    try:
        parent_pid = int(os.environ.get("CODEX_WHIP_PARENT_PID", ""))
    except ValueError:
        return None
    return parent_pid if parent_pid > 0 else None


def process_alive(pid):
    """Signal zero checks existence without sending a signal to the process."""
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def run_worker(directory, codex_home):
    os.umask(0o077)
    lock = (directory / "worker.lock").open("a")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        lock.close()
        raise RuntimeError("Codex Whip is already running")
    state_path = directory / "state.json"
    state = read_json(state_path)
    if state.get("version") != 1:
        raise RuntimeError("Unsupported retry-state version")
    stopping = False
    parent_pid = configured_parent_pid()
    # A frozen onefile helper's immediate parent can be its bootloader, while
    # parent_pid identifies the native app that owns the worker's lifetime.
    initial_parent_pid = os.getppid() if parent_pid is not None else None

    def stop(_signum, _frame):
        nonlocal stopping
        stopping = True

    def should_stop():
        return stopping or (parent_pid is not None and (
            os.getppid() != initial_parent_pid or not process_alive(parent_pid)
        ))

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    (directory / "worker.pid").write_text(str(os.getpid()))
    write_log = log_emitter(directory)
    history = History(directory)

    def report(event, **fields):
        history.record(event, **fields)
        write_log(event, **fields)
    engine = RetryEngine(state, lambda value: atomic_json(state_path, value), report,
                         threads=state.get("threads", []), should_stop=should_stop)
    rpc, last_error, settings_error = None, None, None
    reconnect_after = 0
    applied_settings = None
    scheduler = ScanScheduler()
    report("started", threads=state.get("threads", []) or "loaded terminal sessions")
    try:
        while not should_stop():
            try:
                current_settings = read_settings(directory)
                if current_settings != applied_settings:
                    engine.apply_settings(current_settings)
                    applied_settings = current_settings
                    report("settings_changed", retry_seconds=current_settings["retry_seconds"],
                           scan_seconds=current_settings["scan_seconds"])
                if settings_error is not None:
                    settings_error = None
                    state["last_error"] = last_error
                    atomic_json(state_path, state)
            except SettingsError as error:
                engine.reset_observations()
                state["last_error"] = str(error)
                if str(error) != settings_error:
                    report("settings_error", message=str(error))
                settings_error = str(error)
                atomic_json(state_path, state)
                if not should_stop():
                    time.sleep(1)
                continue
            clock = time.monotonic()
            if rpc is None and clock < reconnect_after:
                time.sleep(1)
                continue
            discovery_due = scheduler.due(clock, current_settings["scan_seconds"])
            if not discovery_due and engine.maintenance_due(time.time()) is not True:
                time.sleep(1)
                continue
            try:
                reconcile_history(state, history, time.time())
                if rpc is None:
                    rpc = WebSocketRPC(resolve_socket(codex_home), should_stop=should_stop)
                if discovery_due:
                    engine.step(rpc, time.time())
                else:
                    engine.step(rpc, time.time(), discover=False)
                if last_error:
                    report("reconnected")
                last_error = None
                reconnect_after = 0
                if discovery_due:
                    state["last_scan_at"] = time.time()
                state["last_error"] = None
            except RPCCancelled:
                engine.reset_observations()
                break
            except Exception as error:
                if should_stop():
                    engine.reset_observations()
                    break
                engine.reset_observations()
                state["last_error"] = str(error)
                if str(error) != last_error:
                    report("connection_error", message=str(error))
                last_error = str(error)
                if rpc:
                    rpc.close()
                    rpc = None
                reconnect_after = time.monotonic() + min(30, current_settings["scan_seconds"])
            atomic_json(state_path, state)
            if discovery_due:
                scheduler.finished(time.monotonic())
            if not should_stop():
                time.sleep(1)
    finally:
        if rpc:
            rpc.close()
        (directory / "worker.pid").unlink(missing_ok=True)
        report("stopped")
        history.close()
        lock.close()


def agent_path():
    return Path.home() / "Library/LaunchAgents" / f"{LABEL}.plist"


def default_state_directory():
    return Path.home() / "Library/Application Support/Codex Whip"


def legacy_state_directory():
    return Path.home() / "Library/Application Support/Codex Keep Going"


def initial_state(threads=()):
    return {
        "version": 1, "enabled_at": time.time(), "threads": list(threads),
        "pending": {}, "handled": {}, "paused": {}, "last_error": None,
    }


def worker_running(directory):
    """Probe the worker's advisory lock without creating or changing any files."""
    try:
        lock = (directory / "worker.lock").open("r")
    except FileNotFoundError:
        return False
    with lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return True
        fcntl.flock(lock, fcntl.LOCK_UN)
        return False


def legacy_job_paths(path):
    """Read effective paths without changing a legacy launch job."""
    try:
        job = plistlib.loads(path.read_bytes())
        arguments = job["ProgramArguments"]
        environment = job.get("EnvironmentVariables", {})
        if (not isinstance(arguments, list) or not arguments
                or not all(isinstance(value, str) and value for value in arguments)
                or not isinstance(environment, dict)
                or not all(isinstance(key, str) and isinstance(value, str)
                           for key, value in environment.items())):
            raise ValueError("Invalid launch arguments or environment")

        def argument(name, default):
            value = default
            for index, item in enumerate(arguments):
                if item == name:
                    if index + 1 >= len(arguments) or arguments[index + 1].startswith("--"):
                        raise ValueError(f"Missing value for {name}")
                    value = arguments[index + 1]
                elif item.startswith(name + "="):
                    value = item.split("=", 1)[1]
            if not value:
                raise ValueError(f"Empty value for {name}")
            resolved = Path(value).expanduser()
            if not resolved.is_absolute():
                working_directory = Path(job.get("WorkingDirectory", "")).expanduser()
                if not working_directory.is_absolute():
                    raise ValueError("Relative paths require a recorded absolute WorkingDirectory")
                resolved = working_directory / resolved
            return resolved.resolve()

        return (
            argument("--state-dir", str(legacy_state_directory())),
            argument("--codex-home", environment.get("CODEX_HOME", str(Path.home() / ".codex"))),
        )
    except Exception as error:
        raise RuntimeError(
            "Cannot safely read the existing CLI launch job. Keep that service, or stop it explicitly "
            "before setting up the app. Its launch file and saved state were left intact."
        ) from error


def current_command_target():
    return Path(sys.executable if getattr(sys, "frozen", False) else __file__).resolve()


def managed_legacy_command(script):
    command = Path.home() / ".local/bin/codex-keep-going"
    if not command.is_symlink():
        return None
    target = command.resolve()
    if target == script:
        return target
    if (target.name == "codex_keep_going.py" and target.parent == script.parent
            and script.name == "codex_whip.py"):
        return target
    try:
        if target.suffix == ".py" and target.is_file():
            source = target.read_text()
            if 'LABEL = "com.aktay.codex-keep-going"' in source and "def run_worker(" in source:
                return target
        if target.name == "keep-going-helper" and target.parent.name == "Helpers":
            replacement = target.with_name("whip-helper")
            replaced_in_place = (not target.exists() and replacement.is_file()
                                 and replacement.resolve() == script)
            if target.is_file() or replaced_in_place:
                info = plistlib.loads((target.parent.parent / "Info.plist").read_bytes())
                if info.get("CFBundleIdentifier") == "com.aktay.codex-keep-going.app":
                    return target
    except (OSError, ValueError, UnicodeError):
        pass
    return None


def check_command_target(script):
    command = Path.home() / ".local/bin/codex-whip"
    if (command.exists() or command.is_symlink()) and not (command.is_symlink() and command.resolve() == script):
        raise RuntimeError(f"Refusing to replace an existing command: {command}")
    return command


def check_legacy_command_target(expected_target):
    old = Path.home() / ".local/bin/codex-keep-going"
    if not old.is_symlink() or old.resolve() != expected_target:
        raise RuntimeError("The old CLI command changed during migration; it was left intact.")
    return old


def migrate_legacy_command(script, expected_target):
    old = check_legacy_command_target(expected_target)
    command = check_command_target(script)
    if not command.is_symlink():
        command.symlink_to(script)
    old.unlink()


def prepare_state(directory, codex_home=None):
    """Prepare the native worker and safely migrate the previous default installation."""
    directory = Path(directory).expanduser().resolve()
    migrated = False
    if sys.platform == "darwin" and directory == default_state_directory().resolve():
        old_directory = legacy_state_directory().resolve()
        if legacy_state_directory().is_symlink():
            raise RuntimeError("The old state directory is a symlink. Migrate that installation explicitly; "
                               "its files were left intact.")
        if old_directory.exists() and directory.exists():
            raise RuntimeError("Both Codex Keep Going and Codex Whip state directories exist. "
                               "Resolve that conflict before migrating; neither directory was changed.")
        if old_directory.exists():
            old_state = old_directory / "state.json"
            if old_state.exists() and read_json(old_state).get("version") != 1:
                raise RuntimeError("Unsupported retry-state version in the old installation; nothing was changed.")
            read_settings(old_directory)
        elif directory.exists():
            read_settings(directory)
        job_path = agent_path()
        running = service_running()
        old_job_directory = None
        if job_path.exists():
            old_job_directory, old_codex_home = legacy_job_paths(job_path)
            target_codex_home = Path(codex_home if codex_home is not None else os.environ.get(
                "CODEX_HOME", str(Path.home() / ".codex")
            )).expanduser().resolve()
            if old_job_directory not in (directory, old_directory) or old_codex_home != target_codex_home:
                raise RuntimeError(
                    "The existing CLI job uses a different state directory or Codex home. Keep that "
                    "service, or stop it explicitly before setting up the app separately. "
                    "Its launch file and saved state were left intact."
                )
        elif running:
            raise RuntimeError(
                "A CLI job is running, but its launch file is unavailable, so its configuration is "
                "unknown. Keep that service, or stop it explicitly before setting up the app."
            )
        script = current_command_target()
        old_command_target = managed_legacy_command(script)
        if old_command_target is not None:
            check_command_target(script)
        if worker_running(old_directory) and not (running and old_job_directory == old_directory):
            raise RuntimeError("Quit Codex Keep Going before migrating its state. Its worker is still running.")
        if job_path.exists():
            stop_service()
            deadline = time.monotonic() + 15
            while worker_running(directory) or worker_running(old_directory):
                if time.monotonic() >= deadline:
                    raise RuntimeError("The previous CLI worker is still stopping. Try again shortly.")
                time.sleep(0.1)
        if old_command_target is not None:
            check_legacy_command_target(old_command_target)
            check_command_target(script)
        if old_directory.exists():
            lock = None
            try:
                try:
                    lock = (old_directory / "worker.lock").open("r")
                except FileNotFoundError:
                    pass
                if lock is not None:
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                old_directory.rename(directory)
                migrated = True
            except BlockingIOError as error:
                raise RuntimeError("The old worker started during migration. Quit it and try again.") from error
            finally:
                if lock is not None:
                    lock.close()
        if old_command_target is not None:
            migrate_legacy_command(script, old_command_target)
            migrated = True
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    state_path = directory / "state.json"
    if state_path.exists():
        if read_json(state_path).get("version") != 1:
            raise RuntimeError("Unsupported retry-state version")
    else:
        atomic_json(state_path, initial_state())
    return migrated


def dashboard(directory):
    """Read the app's local dashboard without contacting Codex or changing state."""
    state_path = directory / "state.json"
    return {
        "state": read_json(state_path) if state_path.exists() else {},
        "history": read_report(directory),
        "running": worker_running(directory),
    }


def service_running():
    return subprocess.run(["launchctl", "print", f"gui/{os.getuid()}/{LABEL}"],
                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0


def stop_service():
    result = subprocess.run(["launchctl", "bootout", f"gui/{os.getuid()}/{LABEL}"],
                            capture_output=True, text=True)
    if result.returncode and service_running():
        raise RuntimeError(result.stderr.strip() or "Could not stop launch agent")
    agent_path().unlink(missing_ok=True)
    deadline = time.monotonic() + 15
    while service_running():
        if time.monotonic() >= deadline:
            raise RuntimeError("Login job removed, but worker is still stopping. Check status shortly.")
        time.sleep(0.1)


def start_service(args, directory, codex_home):
    if sys.platform != "darwin":
        raise RuntimeError("Background installation uses macOS launchd")
    if worker_running(directory):
        print("Already enabled. Use codex-whip status; native app workers are managed from the app menu.")
        return
    script = current_command_target()
    needs_migration = (directory.resolve() == default_state_directory().resolve()
                       and (legacy_state_directory().exists() or managed_legacy_command(script) is not None))
    if service_running() and not needs_migration:
        print("Already enabled. Use codex-whip status or stop.")
        return
    command = check_command_target(script)
    migrated = prepare_state(directory, codex_home)
    frozen = bool(getattr(sys, "frozen", False))
    interpreter = sys.executable
    state_path = directory / "state.json"
    if (getattr(args, "preserve_state", False) or migrated) and state_path.exists():
        state = read_json(state_path)
        if state.get("version") != 1:
            raise RuntimeError("Unsupported retry-state version")
        if args.thread:
            state["threads"] = args.thread
    else:
        state = initial_state(args.thread)
    atomic_json(directory / "state.json", state)
    # Keep executables outside this user's usual PATH untouched.
    bin_dir = Path.home() / ".local/bin"
    bin_dir.mkdir(parents=True, exist_ok=True)
    command = bin_dir / "codex-whip"
    if command.is_symlink() and command.resolve() == script:
        pass
    elif command.exists() or command.is_symlink():
        raise RuntimeError(f"Refusing to replace an existing command: {command}")
    else:
        command.symlink_to(script)
    log = directory / "worker.log"
    log.touch(mode=0o600, exist_ok=True)
    os.chmod(log, 0o600)
    launch_log = directory / "launchd.log"
    launch_log.touch(mode=0o600, exist_ok=True)
    os.chmod(launch_log, 0o600)
    launch_agent = {
        "Label": LABEL,
        "ProgramArguments": ([str(script)] if frozen else [interpreter, str(script)])
                            + ["--state-dir", str(directory),
                               "--codex-home", str(codex_home), "_run"],
        "RunAtLoad": True,
        "KeepAlive": {"SuccessfulExit": False},
        "ThrottleInterval": 30,
        "EnvironmentVariables": {"PYTHONUNBUFFERED": "1"},
        "StandardOutPath": str(launch_log),
        "StandardErrorPath": str(launch_log),
        "Umask": 0o077,
        "ProcessType": "Background",
    }
    plist = agent_path()
    plist.parent.mkdir(parents=True, exist_ok=True)
    plist.write_bytes(plistlib.dumps(launch_agent))
    os.chmod(plist, 0o600)
    result = subprocess.run(["launchctl", "bootstrap", f"gui/{os.getuid()}", str(plist)],
                            capture_output=True, text=True)
    if result.returncode:
        plist.unlink(missing_ok=True)
        raise RuntimeError(result.stderr.strip() or "Could not start launch agent")
    preferences = read_settings(directory)
    print(f"Enabled: retry capacity failures every {duration_label(preferences['retry_seconds'])}; "
          f"check quota every {duration_label(preferences['scan_seconds'])} in the same session and model.")
    print("Watching future failures in " + (", ".join(args.thread) if args.thread else "loaded terminal sessions."))
    print(f"Status: {command} status\nStop:   {command} stop")


def status(directory):
    path = directory / "state.json"
    enabled = worker_running(directory) or (sys.platform == "darwin" and service_running())
    if not path.exists():
        print("Not installed. Run codex-whip start.")
        return
    state = read_json(path)
    print("Enabled" if enabled else "Stopped")
    sessions = state.get("sessions")
    if not enabled:
        print("Watching: 0 terminal sessions (stopped)")
    elif sessions is None:
        print("Watching: waiting for the first session count")
    else:
        details = [f"{sessions['active']} active", f"{sessions['idle']} idle"]
        if sessions.get("errored"):
            details.append(f"{sessions['errored']} errored")
        if sessions.get("other"):
            details.append(f"{sessions['other']} other")
        print(f"Watching: {sessions['total']} terminal sessions ({', '.join(details)})")
        if sessions.get("unavailable"):
            print(f"Unavailable during scan: {sessions['unavailable']}")
    preferences = read_settings(directory)
    print(f"Checks: every {duration_label(preferences['scan_seconds'])}. "
          f"Capacity retries: every {duration_label(preferences['retry_seconds'])}.")
    print("Scope: " + (", ".join(state.get("threads", [])) or "loaded terminal sessions"))
    pending = state.get("pending", {}) if enabled else {}
    quotas = sum(item.get("kind") == "quota" for item in pending.values())
    print(f"Pending capacity retries: {len(pending) - quotas}")
    print(f"Waiting for quota: {quotas}")
    scanned = state.get("last_scan_at")
    print(f"Last scan: {int(time.time() - scanned)} seconds ago" if scanned else "Waiting for first scan")
    if state.get("last_error"):
        print(f"Connection: {state['last_error']}")
    for thread_id, item in state.get("pending", {}).items():
        delay = max(0, int(item["due_at"] - time.time()))
        if item.get("kind") == "quota":
            reason = {"unknown": "quota status unavailable", "account_changed": "account changed"}.get(
                item.get("quota_status"), "waiting for included usage")
            print(f"Quota wait: {thread_id} · {item['model']} · {reason} · check in {delay}s")
        else:
            print(f"Waiting: {thread_id} · {item['model']} · retry in {delay}s")
    for thread_id, item in state.get("handled", {}).items():
        if item["outcome"] == "uncertain":
            print(f"Uncertain send: {thread_id}. Check this session manually; it will not be sent twice.")
    print_activity(directory)


def duration_label(seconds):
    if seconds % 60 == 0:
        minutes = seconds // 60
        return f"{minutes} minute" + ("s" if minutes != 1 else "")
    return f"{seconds} seconds"


def print_activity(directory, hours=24, limit=5):
    report = read_report(directory, hours=hours, limit=limit)
    print(f"\nLast {hours} hours:")
    if not report["available"]:
        print("History will be available after the next watcher startup.")
        return
    print(f"Capacity errors found: {report['capacity']} · Retries sent: {report['retries']}")
    print(f"Successful: {report['successful']} · Failed: {report['failed']} "
          f"({report['failed_capacity']} capacity, {report['failed_other']} other) "
          f"· {report['interrupted']} interrupted")
    print(f"Awaiting recovery: {report['awaiting']} · Uncertain sends: {report['uncertain']}")
    print(f"Quota limits found: {report['quota']} · Quota retries sent: {report['quota_retries']}")
    print(f"Quota successful: {report['quota_successful']} · Failed: {report['quota_failed']} "
          f"· {report['quota_interrupted']} interrupted · Awaiting: {report['quota_awaiting']} "
          f"· Uncertain: {report['quota_uncertain']}")
    print("Success: 2 minutes of continuously observed healthy activity, or immediate completion.")
    since = report.get("recorded_since")
    if since and since > time.time() - hours * 3600:
        print("Recording since: " + time.strftime("%Y-%m-%d %H:%M:%S %Z", time.localtime(since)))
    if report["recent"]:
        print("Recent activity:")
    for event in reversed(report["recent"]):
        label = {"capacity": "capacity error found", "retry": "retry sent",
                 "quota": "quota limit found", "uncertain": "send uncertain"}.get(event["event"])
        if event["event"] == "retry_result":
            label = "retry " + ("successful" if event["status"] == "completed" else event["status"])
            if event.get("capacity"):
                label += " (capacity)"
        if event.get("kind") == "quota" and event["event"] != "quota":
            label = "quota " + label
        timestamp = time.strftime("%m-%d %H:%M:%S", time.localtime(event["ts"]))
        # Session IDs begin with a timestamp, so their endings tell neighbors apart.
        print(f"  {timestamp} · {event['thread_id'][-8:]} · {label}")


def doctor(codex_home):
    rpc = WebSocketRPC(resolve_socket(codex_home))
    try:
        ids = loaded_threads(rpc)
        count, skipped = 0, 0
        for thread_id in ids:
            try:
                thread = rpc.call("thread/read", {
                    "threadId": thread_id, "includeTurns": False,
                })["thread"]
            except RequestError:
                skipped += 1
                continue
            if not thread.get("parentThreadId") and thread.get("canAcceptDirectInput"):
                count += 1
        print(f"Connected to Codex. {len(ids)} loaded sessions, {count} accept direct input.")
        if skipped:
            print(f"Skipped {skipped} sessions that became unavailable.")
        print("Read-only check passed. No message sent and no model request made.")
    finally:
        rpc.close()


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--state-dir", type=Path,
                        default=default_state_directory())
    parser.add_argument("--codex-home", type=Path,
                        default=Path(os.environ.get("CODEX_HOME", str(Path.home() / ".codex"))))
    commands = parser.add_subparsers(dest="command", required=True)
    start = commands.add_parser("start", help="Enable future capacity retries and start at login")
    start.add_argument("--thread", action="append", default=[], help="Watch only this UUID (repeatable)")
    start.add_argument("--preserve-state", action="store_true",
                       help="Keep saved activation time, pending timers, and session scope during an update")
    commands.add_parser("stop", help="Disable retries and remove the login job")
    commands.add_parser("status", help="Show pending retries and connection health")
    commands.add_parser("doctor", help="Check Codex connection without submitting a turn")
    commands.add_parser("logs", help="Show the last 30 log lines")
    report = commands.add_parser("report", help="Show capacity and retry activity for the last 24 hours")
    report.add_argument("--hours", type=int, default=24, choices=range(1, 49), metavar="1-48")
    commands.add_parser("prepare", help="Prepare saved state for the native app (internal)")
    commands.add_parser("dashboard", help="Read the native app dashboard as JSON (internal)")
    commands.add_parser("settings", help="Read settings and defaults as JSON")
    commands.add_parser("configure", help="Save validated settings from JSON on stdin")
    commands.add_parser("_run", help="Run the installed worker (internal)")
    args = parser.parse_args(argv)
    args.state_dir = args.state_dir.expanduser().resolve()
    args.codex_home = args.codex_home.expanduser().resolve()
    try:
        if args.command == "start":
            doctor(args.codex_home)
            start_service(args, args.state_dir, args.codex_home)
        elif args.command == "stop":
            stop_service()
            print("Stopped. Automatic retries and start at login are disabled.")
        elif args.command == "status":
            status(args.state_dir)
        elif args.command == "doctor":
            doctor(args.codex_home)
        elif args.command == "report":
            print_activity(args.state_dir, hours=args.hours, limit=100)
        elif args.command == "prepare":
            prepare_state(args.state_dir, args.codex_home)
        elif args.command == "dashboard":
            print(json.dumps(dashboard(args.state_dir)))
        elif args.command == "settings":
            print(json.dumps(settings_envelope(args.state_dir)))
        elif args.command == "configure":
            if (args.state_dir == default_state_directory().resolve() and legacy_state_directory().exists()):
                raise SettingsError("Run prepare before configuring Codex Whip so existing files can migrate safely.")
            payload = sys.stdin.read(65537)
            if len(payload) > 65536:
                raise SettingsError("Settings JSON exceeds the allowed size.")
            save_settings(args.state_dir, json.loads(payload))
            print(json.dumps(settings_envelope(args.state_dir)))
        elif args.command == "logs":
            path = args.state_dir / "worker.log"
            if path.exists():
                print("\n".join(path.read_text().splitlines()[-30:]))
            else:
                print("No log yet.")
        else:
            run_worker(args.state_dir, args.codex_home)
    except (OSError, ValueError, KeyError, RPCError, RuntimeError, sqlite3.Error) as error:
        print(f"codex-whip: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
