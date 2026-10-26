"""Private local event history for Codex Whip. No conversation text is stored."""

from __future__ import annotations

import json
import math
import os
from pathlib import Path
import sqlite3
import time


DATABASE_NAME = "history.sqlite3"
RETENTION_SECONDS = 48 * 60 * 60
EVENTS = {
    "waiting": "capacity", "quota_waiting": "quota", "retry": "retry",
    "retry_result": "retry_result", "uncertain": "uncertain",
}
COUNTERS = (
    "capacity", "retries", "successful", "completed", "failed", "failed_capacity", "failed_other",
    "interrupted", "uncertain", "awaiting",
)
QUOTA_COUNTERS = ("quota",) + tuple("quota_" + name for name in COUNTERS if name != "capacity")
# History is an activity record, not a copy of the engine's private state or
# account response. In particular, account bindings and message text never enter it.
EVENT_FIELDS = frozenset({
    "thread_id", "turn_id", "kind", "model", "effort", "detected_at",
    "wait_started_at", "due_at", "at", "capacity_at", "quota_at", "outcome",
    "retry_turn_id", "status", "capacity", "occurred_at",
})


def event_kind(event, fields):
    expected = {"capacity": "capacity", "quota": "quota"}.get(event)
    kind = fields.get("kind", expected or "capacity")
    if kind not in ("capacity", "quota") or (expected is not None and kind != expected):
        raise ValueError("Retry history kind must match capacity or quota origin")
    return kind


class History:
    def __init__(self, directory, clock=time.time):
        directory = Path(directory)
        directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        os.chmod(directory, 0o700)
        self.clock = clock
        path = directory / DATABASE_NAME
        try:
            descriptor = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        except FileExistsError:
            pass
        else:
            os.close(descriptor)
        os.chmod(path, 0o600)
        self.connection = sqlite3.connect(path, timeout=5)
        try:
            version = self.connection.execute("PRAGMA user_version").fetchone()[0]
            if version not in (0, 1):
                raise RuntimeError(f"Unsupported retry history version: {version}")
            self.connection.executescript("""
                CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY, value REAL NOT NULL);
                CREATE TABLE IF NOT EXISTS events (
                    ts REAL NOT NULL,
                    event TEXT NOT NULL,
                    thread_id TEXT NOT NULL,
                    turn_id TEXT NOT NULL,
                    fields TEXT NOT NULL,
                    PRIMARY KEY (event, thread_id, turn_id)
                );
                CREATE INDEX IF NOT EXISTS events_by_ts ON events(ts);
                PRAGMA user_version = 1;
            """)
            now = float(self.clock())
            with self.connection:
                self.connection.execute(
                    "INSERT OR IGNORE INTO metadata(key, value) VALUES ('recorded_since', ?)", (now,)
                )
                self.connection.execute("DELETE FROM events WHERE ts < ?", (now - RETENTION_SECONDS,))
        except BaseException:
            self.connection.close()
            raise

    def record(self, event, **fields):
        """Return whether a new tracked event was inserted; repeated events count once."""
        normalized = EVENTS.get(event)
        now = float(self.clock())
        occurred_at = now
        if normalized:
            fields = {name: value for name, value in fields.items() if name in EVENT_FIELDS}
            fields["kind"] = event_kind(normalized, fields)
            if fields.get("occurred_at") is not None:
                occurred_at = fields["occurred_at"]
                if (isinstance(occurred_at, bool) or not isinstance(occurred_at, (int, float))
                        or not math.isfinite(occurred_at)):
                    raise ValueError("Retry history occurred_at requires a finite Unix timestamp")
            for name in ("thread_id", "turn_id"):
                if not isinstance(fields.get(name), str) or not fields[name]:
                    raise ValueError(f"Retry history {event} requires {name}")
            if event == "retry" and not fields.get("retry_turn_id"):
                raise ValueError("Retry history retry requires retry_turn_id")
            if event == "retry_result":
                if fields.get("status") not in ("successful", "completed", "failed", "interrupted"):
                    raise ValueError("Retry history retry_result requires a retry outcome")
                if not isinstance(fields.get("capacity"), bool):
                    raise ValueError("Retry history retry_result requires a capacity boolean")
            encoded = json.dumps(fields, separators=(",", ":"))
        with self.connection:
            self.connection.execute("DELETE FROM events WHERE ts < ?", (now - RETENTION_SECONDS,))
            if not normalized or occurred_at < now - RETENTION_SECONDS:
                return False
            cursor = self.connection.execute(
                "INSERT OR IGNORE INTO events(ts, event, thread_id, turn_id, fields) VALUES (?, ?, ?, ?, ?)",
                (occurred_at, normalized, fields["thread_id"], fields["turn_id"], encoded),
            )
            return cursor.rowcount == 1

    def close(self):
        self.connection.close()


def read_report(directory, hours=24, limit=5, now=None):
    """Read a time-window report without creating or modifying a history database.

    Outcomes count at the supplied occurrence time, or observation time when
    unavailable. Awaiting counts retries sent in the window without a terminal
    result, including results outside that window.
    Retained coverage is limited to the most recent 48 hours.
    """
    if hours <= 0 or limit < 0:
        raise ValueError("hours must be positive and limit cannot be negative")
    now = time.time() if now is None else float(now)
    report = {"available": False, "recorded_since": None,
              **dict.fromkeys(COUNTERS + QUOTA_COUNTERS, 0), "recent": []}
    path = Path(directory) / DATABASE_NAME
    if not path.exists():
        return report
    connection = sqlite3.connect(path.resolve().as_uri() + "?mode=ro", uri=True, timeout=5)
    try:
        with connection:
            since = connection.execute("SELECT value FROM metadata WHERE key = 'recorded_since'").fetchone()[0]
            records = connection.execute(
                "SELECT ts, event, thread_id, turn_id, fields FROM events "
                "WHERE ts >= ? AND ts <= ? ORDER BY ts DESC, event, thread_id, turn_id",
                (now - RETENTION_SECONDS, now),
            ).fetchall()
    finally:
        connection.close()
    report.update(available=True, recorded_since=max(since, now - RETENTION_SECONDS))
    rows = []
    for ts, event, thread_id, turn_id, fields in records:
        metadata = {name: value for name, value in json.loads(fields).items() if name in EVENT_FIELDS}
        rows.append({**metadata, "ts": ts, "event": event,
                     "thread_id": thread_id, "turn_id": turn_id,
                     "kind": event_kind(event, metadata)})
    finished = {(row["kind"], row["thread_id"], row["turn_id"])
                for row in rows if row["event"] == "retry_result"}
    cutoff = now - hours * 60 * 60
    recent = [row for row in rows if row["ts"] >= cutoff]
    for row in recent:
        event = row["event"]
        if event == "capacity":
            report["capacity"] += 1
        elif event == "quota":
            report["quota"] += 1
        elif event == "retry":
            prefix = "quota_" if row["kind"] == "quota" else ""
            report[prefix + "retries"] += 1
            if (row["kind"], row["thread_id"], row["retry_turn_id"]) not in finished:
                report[prefix + "awaiting"] += 1
        elif event == "uncertain":
            prefix = "quota_" if row["kind"] == "quota" else ""
            report[prefix + "uncertain"] += 1
        elif event == "retry_result":
            prefix = "quota_" if row["kind"] == "quota" else ""
            status = row["status"]
            report[prefix + status] += 1
            if status == "completed":
                report[prefix + "successful"] += 1
            if status == "failed":
                report[prefix + ("failed_capacity" if row["capacity"] else "failed_other")] += 1
    report["recent"] = recent[:limit]
    return report
