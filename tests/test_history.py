#!/usr/bin/env python3
"""Local SQLite history checks. No Codex connection or model requests."""

import importlib.util
import json
from contextlib import closing
from pathlib import Path
import sqlite3
import tempfile
import unittest


SPEC = importlib.util.spec_from_file_location(
    "history", Path(__file__).resolve().parents[1] / "history.py"
)
history_module = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(history_module)
HOUR = 3600


class HistoryTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.directory = Path(self.temporary.name) / "private-history"
        self.now = 1_800_000_000.0
        self.history = history_module.History(self.directory, clock=lambda: self.now)

    def tearDown(self):
        self.history.close()
        self.temporary.cleanup()

    def record(self, event, turn_id, thread_id="session", **fields):
        return self.history.record(event, thread_id=thread_id, turn_id=turn_id, **fields)

    def report(self, **options):
        return history_module.read_report(self.directory, now=self.now, **options)

    def test_counts_capacity_retries_and_all_terminal_outcomes(self):
        for number, status, capacity in ((1, "completed", False), (2, "failed", True),
                                         (3, "failed", False), (4, "interrupted", False)):
            self.record("waiting", f"failure-{number}", model="selected-model", due_at=self.now + 300)
            self.record("retry", f"failure-{number}", retry_turn_id=f"retry-{number}")
            self.record("retry_result", f"retry-{number}", status=status, capacity=capacity)
        self.record("uncertain", "failure-uncertain")
        result = self.report(limit=20)
        self.assertTrue(result["available"])
        self.assertEqual({name: result[name] for name in history_module.COUNTERS}, {
            "capacity": 4, "retries": 4, "successful": 1, "completed": 1, "failed": 2,
            "failed_capacity": 1, "failed_other": 1, "interrupted": 1,
            "uncertain": 1, "awaiting": 0,
        })
        capacity_row = next(row for row in result["recent"] if row["event"] == "capacity")
        self.assertEqual(capacity_row["model"], "selected-model")
        self.assertIn("due_at", capacity_row)

    def test_duplicate_events_count_once_and_keep_original_time(self):
        original_time = self.now
        self.assertTrue(self.record("waiting", "failure"))
        self.now += 60
        self.assertFalse(self.record("waiting", "failure"))
        self.assertTrue(self.record("waiting", "failure", thread_id="another-session"))
        self.assertTrue(self.record("uncertain", "failure"))
        result = self.report(limit=10)
        self.assertEqual(result["capacity"], 2)
        self.assertEqual(result["uncertain"], 1)
        row = next(row for row in result["recent"] if row["event"] == "capacity" and row["thread_id"] == "session")
        self.assertEqual(row["ts"], original_time)

    def test_successful_and_legacy_completed_results_both_count_as_success(self):
        self.record("retry", "old-failure", retry_turn_id="old-retry")
        self.record("retry_result", "old-retry", status="completed", capacity=False)
        self.record("retry", "new-failure", retry_turn_id="new-retry")
        self.record("retry_result", "new-retry", status="successful", capacity=False)
        result = self.report()
        self.assertEqual(result["successful"], 2)
        self.assertEqual(result["completed"], 1)
        self.assertEqual(result["awaiting"], 0)

    def test_success_result_is_deduplicated_and_late_failure_cannot_replace_it(self):
        self.record("retry", "failure", retry_turn_id="retry")
        self.assertTrue(self.record("retry_result", "retry", status="successful", capacity=False))
        self.now += 60
        self.assertFalse(self.record("retry_result", "retry", status="successful", capacity=False))
        self.assertFalse(self.record("retry_result", "retry", status="failed", capacity=True))
        result = self.report()
        self.assertEqual(result["successful"], 1)
        self.assertEqual(result["failed"], 0)
        self.assertEqual(result["awaiting"], 0)

    def test_new_success_status_remains_deduplicated_after_store_reopens(self):
        self.record("retry", "failure", retry_turn_id="retry")
        self.record("retry_result", "retry", status="successful", capacity=False)
        self.history.close()
        self.now += 60
        self.history = history_module.History(self.directory, clock=lambda: self.now)
        self.assertFalse(self.record("retry_result", "retry", status="successful", capacity=False))
        result = self.report()
        self.assertEqual(result["successful"], 1)
        self.assertEqual(result["awaiting"], 0)

    def test_restart_preserves_history_and_deduplication(self):
        initial_time = self.now
        self.record("retry", "failure", retry_turn_id="retry")
        self.history.close()
        self.now += 120
        self.history = history_module.History(self.directory, clock=lambda: self.now)
        self.assertFalse(self.record("retry", "failure", retry_turn_id="retry"))
        self.record("retry_result", "retry", status="completed", capacity=False)
        result = self.report()
        self.assertEqual(result["retries"], 1)
        self.assertEqual(result["completed"], 1)
        self.assertEqual(result["awaiting"], 0)
        self.assertEqual(result["recorded_since"], initial_time)

    def test_awaiting_links_result_by_retry_turn_and_thread(self):
        self.record("retry", "failure-one", retry_turn_id="retry-one")
        self.record("retry", "failure-two", retry_turn_id="retry-two")
        # The original failed turn and another session's identical retry ID
        # cannot satisfy this session's pending retry.
        self.record("retry_result", "failure-one", status="failed", capacity=True)
        self.record("retry_result", "retry-one", thread_id="another-session", status="completed", capacity=False)
        self.assertEqual(self.report()["awaiting"], 2)
        self.record("retry_result", "retry-one", status="completed", capacity=False)
        self.assertEqual(self.report()["awaiting"], 1)

    def test_24_hour_boundaries_exclude_older_and_future_events(self):
        base = self.now
        self.record("waiting", "older")
        self.now = base + 1
        self.record("waiting", "boundary")
        self.now = base + 2
        self.record("waiting", "inside")
        self.now = base + 24 * HOUR + 2
        self.record("waiting", "future")
        self.now = base + 24 * HOUR + 1
        result = self.report(limit=20)
        self.assertEqual(result["capacity"], 2)
        self.assertEqual([row["turn_id"] for row in result["recent"]], ["inside", "boundary"])

    def test_outcomes_count_when_observed_even_for_older_retries(self):
        base = self.now
        self.record("retry", "old-failure", retry_turn_id="old-retry")
        self.now += 25 * HOUR
        self.record("retry_result", "old-retry", status="completed", capacity=False)
        result = self.report()
        self.assertEqual(result["retries"], 0)
        self.assertEqual(result["completed"], 1)
        self.assertEqual(result["awaiting"], 0)
        self.assertEqual(result["recorded_since"], base)

    def test_delayed_observation_uses_actual_completion_time(self):
        base = self.now
        self.record("retry", "failure", retry_turn_id="retry")
        self.now += 25 * HOUR
        completed_at = base + 60
        self.record("retry_result", "retry", status="completed", capacity=False, occurred_at=completed_at)
        result = self.report()
        self.assertEqual(result["completed"], 0)
        wider_result = self.report(hours=48)
        self.assertEqual(wider_result["completed"], 1)
        completion = next(row for row in wider_result["recent"] if row["event"] == "retry_result")
        self.assertEqual(completion["ts"], completed_at)
        self.assertEqual(completion["occurred_at"], completed_at)

    def test_delayed_outcome_beyond_retention_is_not_inserted(self):
        self.assertFalse(self.record("retry_result", "expired", status="completed", capacity=False,
                                     occurred_at=self.now - 49 * HOUR))
        self.assertEqual(self.report(hours=72)["completed"], 0)
        with closing(sqlite3.connect(self.directory / history_module.DATABASE_NAME)) as connection:
            self.assertEqual(connection.execute("SELECT COUNT(*) FROM events").fetchone()[0], 0)

    def test_retention_prunes_older_than_48_hours_and_keeps_boundary(self):
        base = self.now
        self.record("waiting", "expired")
        self.now += 1
        self.record("waiting", "boundary")
        self.now = base + 48 * HOUR + 1
        self.record("waiting", "current")
        result = self.report(hours=48, limit=20)
        self.assertEqual(result["capacity"], 2)
        self.assertEqual(result["recorded_since"], base + 1)
        with closing(sqlite3.connect(self.directory / history_module.DATABASE_NAME)) as connection:
            self.assertEqual(connection.execute("SELECT COUNT(*) FROM events").fetchone()[0], 2)

    def test_read_report_applies_retention_without_writing_database(self):
        base = self.now
        self.record("waiting", "expired")
        path = self.directory / history_module.DATABASE_NAME
        before = path.read_bytes()
        result = history_module.read_report(self.directory, hours=72, now=base + 49 * HOUR)
        self.assertEqual(result["capacity"], 0)
        self.assertEqual(result["recorded_since"], base + HOUR)
        self.assertEqual(path.read_bytes(), before)

    def test_recent_is_newest_first_and_limit_does_not_change_counts(self):
        for number in range(5):
            self.now += 1
            self.record("waiting", f"failure-{number}")
        result = self.report(limit=2)
        self.assertEqual(result["capacity"], 5)
        self.assertEqual([row["turn_id"] for row in result["recent"]], ["failure-4", "failure-3"])
        self.assertEqual(self.report(limit=0)["recent"], [])

    def test_unrelated_events_are_ignored_and_database_is_private(self):
        self.assertFalse(self.history.record("started", message="observer started"))
        self.assertFalse(self.history.record("connection_error", message="temporarily offline"))
        self.assertEqual(self.report()["recent"], [])
        self.assertEqual(self.directory.stat().st_mode & 0o777, 0o700)
        self.assertEqual((self.directory / history_module.DATABASE_NAME).stat().st_mode & 0o777, 0o600)

    def test_invalid_terminal_result_is_not_silently_counted(self):
        with self.assertRaises(ValueError):
            self.record("retry_result", "retry", status="inProgress", capacity=False)
        with self.assertRaises(ValueError):
            self.record("retry_result", "retry", status="failed", capacity="false")
        self.assertEqual(self.report()["recent"], [])

    def test_missing_database_report_does_not_create_directory_or_database(self):
        missing = Path(self.temporary.name) / "missing-directory"
        result = history_module.read_report(missing, now=self.now)
        self.assertFalse(result["available"])
        self.assertIsNone(result["recorded_since"])
        self.assertTrue(all(result[name] == 0 for name in history_module.COUNTERS))
        self.assertEqual(result["recent"], [])
        self.assertFalse(missing.exists())

    def test_quota_activity_has_separate_counters_and_preserves_origin(self):
        self.record("waiting", "capacity-failure")
        self.record("retry", "capacity-failure", retry_turn_id="capacity-retry")
        self.record("retry_result", "capacity-retry", status="successful", capacity=False)
        outcomes = (("successful", False), ("completed", False), ("failed", True),
                    ("failed", False), ("interrupted", False))
        for number, (status, capacity) in enumerate(outcomes):
            self.record("quota_waiting", f"quota-failure-{number}")
            self.record("retry", f"quota-failure-{number}", kind="quota",
                        retry_turn_id=f"quota-retry-{number}")
            self.record("retry_result", f"quota-retry-{number}", kind="quota",
                        status=status, capacity=capacity)
        self.record("quota_waiting", "quota-awaiting")
        self.record("retry", "quota-awaiting", kind="quota", retry_turn_id="quota-in-progress")
        self.record("uncertain", "quota-uncertain", kind="quota")
        result = self.report(limit=50)
        self.assertEqual({name: result[name] for name in history_module.COUNTERS}, {
            "capacity": 1, "retries": 1, "successful": 1, "completed": 0,
            "failed": 0, "failed_capacity": 0, "failed_other": 0,
            "interrupted": 0, "uncertain": 0, "awaiting": 0,
        })
        self.assertEqual({name: result[name] for name in history_module.QUOTA_COUNTERS}, {
            "quota": 6, "quota_retries": 6, "quota_successful": 2, "quota_completed": 1,
            "quota_failed": 2, "quota_failed_capacity": 1, "quota_failed_other": 1,
            "quota_interrupted": 1, "quota_uncertain": 1, "quota_awaiting": 1,
        })
        self.assertTrue(all(row["kind"] == "quota" for row in result["recent"]
                            if row["turn_id"].startswith("quota-")))
        self.assertTrue(all(row["kind"] == "capacity" for row in result["recent"]
                            if row["turn_id"].startswith("capacity-")))

    def test_quota_duplicate_events_stay_deduplicated_after_restart(self):
        original = self.now
        self.assertTrue(self.record("quota_waiting", "quota-failure"))
        self.assertTrue(self.record("retry", "quota-failure", kind="quota", retry_turn_id="quota-retry"))
        self.history.close()
        self.now += 60
        self.history = history_module.History(self.directory, clock=lambda: self.now)
        self.assertFalse(self.record("quota_waiting", "quota-failure"))
        self.assertFalse(self.record("retry", "quota-failure", kind="quota", retry_turn_id="quota-retry"))
        self.assertTrue(self.record("retry_result", "quota-retry", kind="quota",
                                    status="successful", capacity=False))
        self.assertFalse(self.record("retry_result", "quota-retry", kind="quota",
                                     status="failed", capacity=True))
        result = self.report(limit=10)
        self.assertEqual((result["quota"], result["quota_retries"], result["quota_successful"],
                          result["quota_failed"], result["quota_awaiting"]), (1, 1, 1, 0, 0))
        self.assertEqual(result["retries"], 0)
        waiting = next(row for row in result["recent"] if row["event"] == "quota")
        self.assertEqual(waiting["ts"], original)
        self.assertEqual(result["recorded_since"], original)

    def test_legacy_rows_without_kind_remain_capacity_and_are_not_rewritten(self):
        original = self.now
        rows = [
            (original, "capacity", "legacy", "failure", json.dumps({"model": "selected-model"})),
            (original, "retry", "legacy", "failure", json.dumps({"retry_turn_id": "retry"})),
            (original, "retry_result", "legacy", "retry", json.dumps({"status": "completed", "capacity": False})),
        ]
        self.history.connection.executemany("INSERT INTO events VALUES (?, ?, ?, ?, ?)", rows)
        self.history.connection.commit()
        self.history.close()
        self.now += 120
        self.history = history_module.History(self.directory, clock=lambda: self.now)
        self.record("quota_waiting", "new-quota", thread_id="new-session")
        before = (self.directory / history_module.DATABASE_NAME).read_bytes()
        result = self.report(limit=10)
        self.assertEqual((result["capacity"], result["retries"], result["successful"], result["awaiting"]),
                         (1, 1, 1, 0))
        self.assertEqual(result["quota"], 1)
        self.assertTrue(all(row["kind"] == "capacity" for row in result["recent"] if row["thread_id"] == "legacy"))
        self.assertEqual(result["recorded_since"], original)
        self.assertEqual((self.directory / history_module.DATABASE_NAME).read_bytes(), before)
        stored = self.history.connection.execute("SELECT fields FROM events WHERE thread_id = 'legacy'").fetchall()
        self.assertTrue(all("kind" not in json.loads(row[0]) for row in stored))
        self.assertEqual(self.history.connection.execute("PRAGMA user_version").fetchone()[0], 1)

    def test_quota_awaiting_requires_result_from_the_same_origin(self):
        self.record("retry", "quota-failure", kind="quota", retry_turn_id="retry")
        self.record("retry_result", "retry", status="successful", capacity=False)
        result = self.report()
        self.assertEqual(result["successful"], 1)
        self.assertEqual(result["quota_successful"], 0)
        self.assertEqual(result["quota_awaiting"], 1)

    def test_quota_outcome_occurrence_time_and_retention_keep_capacity_counts_zero(self):
        base = self.now
        self.record("quota_waiting", "old-quota")
        self.record("retry", "old-quota", kind="quota", retry_turn_id="quota-retry")
        self.now += 25 * HOUR
        self.record("retry_result", "quota-retry", kind="quota", status="successful", capacity=False,
                    occurred_at=base + 60)
        recent = self.report()
        self.assertEqual((recent["quota"], recent["quota_retries"], recent["quota_successful"]), (0, 0, 0))
        wider = self.report(hours=48)
        self.assertEqual((wider["quota"], wider["quota_retries"], wider["quota_successful"],
                          wider["quota_awaiting"]), (1, 1, 1, 0))
        self.assertTrue(all(wider[name] == 0 for name in history_module.COUNTERS))
        self.now = base + 49 * HOUR
        self.assertEqual(self.report(hours=72)["recent"], [])
        self.assertFalse(self.record("retry_result", "expired-quota", kind="quota",
                                     status="successful", capacity=False, occurred_at=base))

    def test_history_drops_account_bindings_raw_quota_and_message_text(self):
        self.record("quota_waiting", "failure", kind="quota", model="selected-model",
                    detected_at=self.now, accountId="private-account", account_binding="private-binding",
                    rateLimits={"usedPercent": 30}, credits=12, message="private continuation")
        self.record("retry", "failure", kind="quota", retry_turn_id="retry", account_id="private-account")
        self.record("retry_result", "retry", kind="quota", status="successful", capacity=False,
                    accountId="private-account")
        rows = self.history.connection.execute("SELECT fields FROM events").fetchall()
        stored = " ".join(row[0] for row in rows)
        self.assertNotIn("private-account", stored)
        self.assertNotIn("private-binding", stored)
        self.assertNotIn("private continuation", stored)
        self.assertNotIn("rateLimits", stored)
        self.assertNotIn("credits", stored)
        result = self.report(limit=10)
        self.assertEqual(result["quota_successful"], 1)
        waiting = next(row for row in result["recent"] if row["event"] == "quota")
        self.assertEqual(waiting["model"], "selected-model")
        self.assertEqual(waiting["detected_at"], self.now)

    def test_invalid_or_conflicting_origin_is_rejected_without_counting(self):
        for event, kind in (("waiting", "quota"), ("quota_waiting", "capacity"),
                            ("retry", "other"), ("uncertain", None)):
            with self.subTest(event=event, kind=kind), self.assertRaises(ValueError):
                self.record(event, "invalid", kind=kind, retry_turn_id="retry")
        self.assertEqual(self.report()["recent"], [])

    def test_unavailable_report_zero_fills_quota_counters_without_creating_files(self):
        missing = Path(self.temporary.name) / "missing-quota-history"
        result = history_module.read_report(missing, now=self.now)
        self.assertTrue(all(result[name] == 0 for name in history_module.QUOTA_COUNTERS))
        self.assertFalse(missing.exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
