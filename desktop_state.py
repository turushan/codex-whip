"""Reduce trusted Desktop snapshots to private, retry-relevant state."""

from __future__ import annotations

from dataclasses import dataclass
import hashlib
import json
from typing import Optional


CAPACITY_MESSAGE = "Selected model is at capacity. Please try a different model"


class DesktopStateError(RuntimeError):
    """A sanitized protocol error that never includes a received payload."""

    def __init__(self, code):
        self.code = code
        super().__init__(f"Desktop state is unavailable ({code}).")


@dataclass(frozen=True)
class DesktopView:
    thread: dict
    turn: Optional[dict]
    revision: int
    owner: str
    settings_fingerprint: str
    blocked_reason: Optional[str] = None


def _require(condition, code):
    if not condition:
        raise DesktopStateError(code)


def _text(value):
    return isinstance(value, str) and bool(value.strip())


def _latest_turn(state):
    history = state.get("turnHistory")
    _require(isinstance(history, dict) and history.get("kind") == "canonical", "unsupported-history")
    history = history.get("history")
    _require(isinstance(history, dict), "invalid-history")
    islands, entities = history.get("islands"), history.get("entitiesByKey")
    _require(isinstance(islands, list) and isinstance(entities, dict), "invalid-history")
    if not islands:
        _require(not entities, "invalid-history")
        return None
    newest = islands[-1]
    _require(isinstance(newest, dict), "invalid-history")
    boundary = newest.get("newerBoundary")
    _require(isinstance(boundary, dict) and boundary.get("status") == "exhausted", "incomplete-latest-history")
    entries = newest.get("entries")
    _require(isinstance(entries, list), "invalid-history")
    if not entries:
        return None
    entry = entries[-1]
    _require(isinstance(entry, dict) and _text(entry.get("key")) and _text(entry.get("value")), "invalid-history")
    turn = entities.get(entry["value"])
    _require(isinstance(turn, dict), "invalid-history")
    return turn


def _error(value):
    if value is None:
        return None
    _require(isinstance(value, dict), "invalid-turn-error")
    info = value.get("codexErrorInfo")
    if info not in (None, "other", "serverOverloaded", "usageLimitExceeded"):
        info = "unsupported"
    # A server error may contain conversation text or operational details. The
    # fixed capacity sentence is the only message needed by retry classification.
    message = value.get("message")
    capacity = isinstance(message, str) and message.strip().rstrip(".") == CAPACITY_MESSAGE
    return {"codexErrorInfo": info, "message": CAPACITY_MESSAGE if capacity else ""}


def _inheritance_matches(state, model, effort):
    """Do not send when Desktop would inherit a different saved selection."""
    saved = state["latestThreadSettings"]
    current_collaboration = state.get("latestCollaborationMode")
    saved_model = saved.get("model")
    if saved_model is not None and saved_model != model:
        return False
    inherited_model = state.get("latestModel") if saved_model is None else saved_model
    inherited_effort = saved["effort"] if "effort" in saved else state.get("latestReasoningEffort")
    if inherited_effort != effort:
        return False
    collaboration = saved.get("collaborationMode")
    collaboration = current_collaboration if collaboration is None else collaboration
    if collaboration != current_collaboration:
        return False
    if collaboration is not None:
        if not isinstance(collaboration, dict):
            return False
        settings = collaboration.get("settings")
        if settings is not None:
            if not isinstance(settings, dict):
                return False
            if settings.get("model") is not None:
                inherited_model = settings["model"]
            # There is no verified null fallback for this collaboration field.
            if "reasoning_effort" in settings and settings["reasoning_effort"] != effort:
                return False
    if inherited_model != model:
        return False
    permissions = state.get("currentPermissions")
    if isinstance(permissions, dict):
        for name in ("approvalPolicy", "sandboxPolicy"):
            if name in saved and name in permissions and saved[name] != permissions[name]:
                return False
    return True


def normalize_snapshot(envelope, conversation_id, owner_id, client_id, model_settings):
    """Validate a full, targeted v11 snapshot without returning its transcript.

    Completion times come from a separately matched persisted turn summary.
    Desktop's start-time-plus-duration estimate is deliberately not exported.
    """
    _require(all(_text(value) for value in (conversation_id, owner_id, client_id)), "invalid-binding")
    _require(isinstance(envelope, dict), "invalid-envelope")
    _require(envelope.get("type") == "broadcast"
             and envelope.get("method") == "thread-stream-state-changed"
             and type(envelope.get("version")) is int and envelope["version"] == 11,
             "unsupported-envelope")
    targets = envelope.get("targetClientIds")
    _require(envelope.get("sourceClientId") == owner_id
             and isinstance(targets, list) and all(_text(value) for value in targets)
             and client_id in targets, "untrusted-binding")
    params = envelope.get("params")
    _require(isinstance(params, dict) and params.get("hostId") == "local"
             and params.get("conversationId") == conversation_id, "untrusted-conversation")
    change = params.get("change")
    _require(isinstance(change, dict) and change.get("type") == "snapshot", "unsupported-change")
    revision = change.get("revision")
    _require(type(revision) is int and revision >= 0, "invalid-revision")
    state = change.get("conversationState")
    _require(isinstance(state, dict) and state.get("id") == conversation_id
             and state.get("sessionId") == conversation_id and state.get("hostId") == "local",
             "untrusted-conversation")

    _require(isinstance(model_settings, dict) and isinstance(model_settings.get("settings"), dict),
             "invalid-model-settings")
    settings = model_settings["settings"]
    _require(_text(settings.get("model")) and "reasoningEffort" in settings
             and (settings["reasoningEffort"] is None or _text(settings["reasoningEffort"])),
             "invalid-model-settings")
    _require(all(_text(settings.get(name)) for name in ("resumeState", "threadSource", "mode")),
             "invalid-model-settings")
    collaboration = state.get("latestCollaborationMode")
    _require(collaboration is None or isinstance(collaboration, dict), "invalid-model-settings")
    collaboration_settings = collaboration.get("settings") if collaboration else None
    _require(collaboration_settings is None or isinstance(collaboration_settings, dict), "invalid-model-settings")
    model = collaboration_settings.get("model") if collaboration_settings else None
    model = state.get("latestModel") if model is None else model
    effort = state.get("latestReasoningEffort")
    _require("latestReasoningEffort" in state and _text(model)
             and settings["model"] == model and settings["reasoningEffort"] == effort,
             "settings-mismatch")
    for name in ("resumeState", "threadSource", "mode"):
        _require(name in settings and name in state and settings[name] == state[name], "settings-mismatch")

    thread_settings = state.get("latestThreadSettings")
    permissions = state.get("currentPermissions")
    _require(isinstance(thread_settings, dict) and bool(thread_settings)
             and (permissions is None or isinstance(permissions, dict)), "invalid-model-settings")
    fingerprint_values = {
        "settings": thread_settings, "permissions": permissions,
        "collaboration": collaboration, "mode": settings["mode"],
        "model": model, "effort": effort, "modelProvider": settings.get("modelProvider"),
    }
    try:
        encoded = json.dumps(fingerprint_values, sort_keys=True, separators=(",", ":"), allow_nan=False).encode()
    except (TypeError, ValueError, OverflowError, RecursionError):
        raise DesktopStateError("invalid-model-settings") from None
    fingerprint = hashlib.sha256(encoded).hexdigest()

    reasons = []
    if not _inheritance_matches(state, model, effort):
        reasons.append("inheritance-mismatch")
    if state.get("parentThreadId") is not None or state.get("ephemeral", False) is not False:
        reasons.append("not-user-thread")
    if state.get("threadSource") != "user":
        reasons.append("not-user-thread")
    if state.get("resumeState") != "resumed":
        reasons.append("not-resumed")
    for name in ("requests", "externalRequests", "unconfirmedTurnSubmissions"):
        value = state.get(name, [] if name != "requests" else None)
        if not isinstance(value, list) or value:
            reasons.append("pending-input")

    runtime = state.get("threadRuntimeStatus")
    kind = runtime.get("type") if isinstance(runtime, dict) else None
    flags = runtime.get("activeFlags", None if kind == "active" else []) if isinstance(runtime, dict) else []
    valid_active = False
    if kind not in ("idle", "systemError", "active"):
        reasons.append("unknown-runtime")
        status = {"type": "unknown"}
    elif not isinstance(flags, list) or not all(_text(flag) for flag in flags):
        reasons.append("unknown-runtime")
        status = {"type": "unknown"}
    else:
        status = {"type": kind}
        if kind == "active" or flags:
            # The core uses an explicit empty activeFlags list for healthy work.
            status["activeFlags"] = list(flags)
        if flags:
            reasons.append("pending-input")
        elif kind == "active":
            valid_active = True

    latest = _latest_turn(state)
    turn = None
    if latest is not None:
        turn_id, turn_status = latest.get("turnId"), latest.get("status")
        _require(turn_id is None or _text(turn_id), "invalid-turn")
        _require(turn_status in ("inProgress", "completed", "failed", "interrupted"), "unsupported-turn")
        turn = {"id": turn_id, "status": turn_status, "error": _error(latest.get("error"))}
        if turn_id is None:
            reasons.append("unconfirmed-turn")
        elif turn_status == "inProgress" and kind != "active":
            reasons.append("inconsistent-runtime")

    blocked = reasons[0] if reasons else ("active" if valid_active else None)
    thread = {
        "id": conversation_id, "source": "desktop", "originator": "codex-desktop",
        "controlBackend": "desktop-ipc", "canAcceptDirectInput": not reasons,
        "threadSource": "user" if state.get("threadSource") == "user" else "unsupported",
        "parentThreadId": None, "ephemeral": False,
        "model": model, "reasoningEffort": effort, "status": status,
    }
    return DesktopView(thread, turn, revision, owner_id, fingerprint, blocked)
