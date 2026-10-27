"""Opt-in Desktop capacity control, bound to fresh owner snapshots.

The shared app-server connection supplies persisted completion timestamps only.
It never receives a turn/start, a resume, or an account request from this adapter.
"""

from contextlib import contextmanager
import math

import codex_whip as core
from desktop_ipc import DesktopIPC, DesktopIPCError
from desktop_state import normalize_snapshot, DesktopStateError


class DesktopNoOwner(core.RequestError):
    pass


def _safe_error(error):
    if not isinstance(error, dict):
        return None
    info = error.get("codexErrorInfo")
    if info not in (None, "other", "serverOverloaded", "usageLimitExceeded"):
        info = "unsupported"
    message = error.get("message")
    matches = isinstance(message, str) and message.strip().rstrip(".") == core.CAPACITY_MESSAGE
    return {"codexErrorInfo": info, "message": core.CAPACITY_MESSAGE if matches else ""}


def _signature(turn):
    error = turn.get("error")
    info = error.get("codexErrorInfo") if isinstance(error, dict) else None
    if info not in (None, "other", "serverOverloaded", "usageLimitExceeded"):
        info = "unsupported"
    return turn.get("id"), turn.get("status"), info, core.failure_kind(turn)


class DesktopRPC:
    """A narrow RetryEngine facade for explicitly selected Desktop threads."""

    def __init__(self, socket_path, metadata_rpc, thread_ids, should_stop=lambda: False,
                 ipc_factory=DesktopIPC):
        self.socket_path, self.metadata_rpc = socket_path, metadata_rpc
        self.thread_ids = tuple(dict.fromkeys(thread_ids))
        if not self.thread_ids or len(self.thread_ids) > 8:
            raise ValueError("Select from one to eight Desktop conversations explicitly.")
        self.should_stop, self.ipc_factory = should_stop, ipc_factory
        self.anchors = {}

    def close(self):
        # The caller owns metadata_rpc. Every Desktop snapshot lease is closed
        # before its call returns, so no follower or cached transcript survives.
        self.anchors.clear()

    def _scope(self, thread_id):
        if thread_id not in self.thread_ids:
            raise core.RequestError("The Desktop conversation is outside the selected scope.")

    def _owner(self, ipc, thread_id):
        response = ipc.request_full("thread-owner-discovery", {
            "hostId": "local", "conversationId": thread_id,
        }, version=1, timeout=12)
        owner, result = response.get("handledByClientId"), response.get("result")
        if (not isinstance(owner, str) or not owner or not isinstance(result, dict)
                or result.get("supportsUntrustedAppInput") is not True):
            raise core.RequestError("Desktop cannot accept external input for this conversation.")
        return owner

    @contextmanager
    def _lease(self, thread_id):
        self._scope(thread_id)
        ipc, owner, followed = None, None, False
        try:
            # A new client binding proves that a matching targeted snapshot was
            # produced for this read, even when its revision did not change.
            ipc = self.ipc_factory(self.socket_path, timeout=12, should_stop=self.should_stop)
            owner = self._owner(ipc, thread_id)
            settings = ipc.request("thread-follower-read-model-settings", {
                "conversationId": thread_id,
            }, version=1, target=owner, timeout=5)
            ipc.broadcast("thread-stream-following-changed", {
                "hostId": "local", "conversationId": thread_id, "following": True,
            }, version=1, targets=[owner])
            followed = True

            def relevant(message):
                params = message.get("params")
                return (message.get("method") == "thread-stream-state-changed"
                        and message.get("sourceClientId") == owner
                        and isinstance(params, dict) and params.get("conversationId") == thread_id)

            envelope = ipc.wait_broadcast(relevant, timeout=5)
            view = normalize_snapshot(envelope, thread_id, owner, ipc.client_id, settings)
            view.thread.update(controlOwner=view.owner,
                               controlSettingsFingerprint=view.settings_fingerprint)
            yield ipc, view
        except DesktopIPCError as error:
            if error.code == "cancelled":
                raise core.RPCCancelled("Desktop checking stopped.") from None
            if error.code == "no-client-found":
                raise DesktopNoOwner("The Desktop conversation has no active owner.") from None
            raise core.RequestError(str(error)) from None
        except DesktopStateError as error:
            raise core.RequestError(str(error)) from None
        finally:
            if ipc is not None:
                if followed:
                    try:
                        ipc.broadcast("thread-stream-following-changed", {
                            "hostId": "local", "conversationId": thread_id, "following": False,
                        }, version=1, targets=[owner], timeout=0.25)
                    except Exception:
                        pass
                ipc.close()

    def _stored_turns(self, thread_id, limit=1):
        try:
            result = self.metadata_rpc.call("thread/turns/list", {
                "threadId": thread_id, "limit": limit,
                "sortDirection": "desc", "itemsView": "notLoaded",
            })
            turns = result["data"]
            if not isinstance(turns, list) or not all(isinstance(t, dict) for t in turns):
                raise ValueError()
            return turns
        except core.RPCCancelled:
            raise
        except Exception:
            raise core.RequestError("Desktop's saved turn summary is unavailable.") from None

    def _matched_turn(self, view, stored):
        live = view.turn
        if (not isinstance(live, dict) or not live.get("id") or not stored
                or _signature(live) != _signature(stored[0])):
            raise core.RequestError("Desktop and its saved turn summary are not synchronized.")
        result = dict(live)
        completed = stored[0].get("completedAt")
        if (type(completed) in (int, float) and math.isfinite(completed) and completed >= 0):
            result["completedAt"] = completed
        return result

    @staticmethod
    def _anchor(view, turn):
        return (view.owner, view.revision, view.settings_fingerprint, _signature(turn))

    def call(self, method, params):
        if self.should_stop():
            raise core.RPCCancelled("Desktop checking stopped.")
        if method == "account/rateLimits/read":
            # CLI and Desktop may use different accounts. Never substitute CLI
            # quota permission for an unverified Desktop account response.
            return {"accountId": None, "ordinaryUsageAllowed": None}
        if method == "thread/loaded/list":
            result = []
            for thread_id in self.thread_ids:
                try:
                    with self._lease(thread_id):
                        result.append(thread_id)
                except core.RPCCancelled:
                    raise
                except DesktopNoOwner:
                    continue
            return {"data": result, "nextCursor": None}
        thread_id = params.get("threadId")
        self._scope(thread_id)
        if method == "thread/read":
            with self._lease(thread_id) as (_ipc, view):
                return {"thread": dict(view.thread)}
        if method == "thread/turns/list":
            limit = min(max(int(params.get("limit", 1)), 1), 20)
            with self._lease(thread_id) as (_ipc, view):
                stored = self._stored_turns(thread_id, limit)
                turn = self._matched_turn(view, stored)
                self.anchors[thread_id] = self._anchor(view, turn)
                # Older persisted results are used only for outcome tracking.
                # Their text/items are never returned to the retry engine.
                history = []
                for item in stored[1:]:
                    summary = {key: item.get(key) for key in ("id", "status", "completedAt")}
                    summary["error"] = _safe_error(item.get("error"))
                    history.append(summary)
                return {"data": [turn, *history], "nextCursor": None}
        if method == "turn/start":
            return self._start(thread_id, params)
        raise core.RequestError("This operation is unavailable in the Desktop prototype.")

    def _start(self, thread_id, params):
        anchor = self.anchors.get(thread_id)
        message_id, text = params.get("clientUserMessageId"), params.get("input")
        if (anchor is None or not isinstance(message_id, str) or not message_id
                or not isinstance(text, list) or len(text) != 1
                or not isinstance(text[0], dict) or text[0].get("type") != "text"
                or not isinstance(text[0].get("text"), str)
                or not text[0]["text"].strip()):
            raise core.RetryNotSubmitted("Desktop retry preflight is incomplete.")
        attempted = False
        try:
            # Persisted summaries can be slow. Obtain them BEFORE the final
            # owner-bound runtime snapshot, never after its inactivity check.
            stored = self._stored_turns(thread_id)
            with self._lease(thread_id) as (ipc, view):
                try:
                    turn = self._matched_turn(view, stored)
                except core.RequestError:
                    raise core.RetryNotSubmitted("Desktop changed before retry submission.") from None
                if (not core.eligible(view.thread) or not core.is_capacity(turn)
                        or self._anchor(view, turn) != anchor or self.should_stop()):
                    raise core.RetryNotSubmitted("Desktop changed before retry submission.")
                # This internal method has no compare-and-start precondition.
                # The final snapshot is immediately followed by the owner send.
                attempted = True
                result = ipc.request("thread-follower-start-turn", {
                    "conversationId": thread_id,
                    "turnStart": {
                        "request": {"threadId": thread_id,
                                    "input": [{**text[0], "text_elements": []}],
                                    "clientUserMessageId": message_id},
                        "context": {"inheritThreadSettings": True},
                    },
                }, version=2, target=view.owner, timeout=10)
                accepted = result.get("result") if isinstance(result, dict) else None
                new_turn = accepted.get("turn") if isinstance(accepted, dict) else None
                if (not isinstance(new_turn, dict) or not isinstance(new_turn.get("id"), str)
                        or not new_turn["id"] or new_turn["id"] == turn["id"]
                        or new_turn.get("status") not in ("inProgress", "completed", "failed", "interrupted")):
                    raise core.RPCError("Desktop's retry acknowledgement is unavailable; check the conversation manually.")
                return {"turn": {"id": new_turn["id"], "status": new_turn["status"]}}
        except core.RetryNotSubmitted:
            raise
        except core.RPCError:
            if not attempted:
                raise core.RetryDeferred("Desktop preflight is temporarily unavailable.") from None
            raise
