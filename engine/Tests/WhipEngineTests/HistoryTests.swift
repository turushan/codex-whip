// Ported from tests/test_history.py. Local SQLite history checks. No Codex connection or model requests.
import Foundation
import SQLite3
import Testing
@testable import WhipEngine

private let hour: Double = 3600

final class HistoryTestClock {
    var now: Double
    init(_ now: Double) { self.now = now }
}

/// A separate SQLite connection for checks the Python tests made through `history.connection`.
final class HistoryTestDatabase {
    private var connection: OpaquePointer?

    init(_ url: URL) throws {
        guard sqlite3_open_v2(url.path, &connection, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            throw HistoryError("cannot open test connection")
        }
    }

    deinit { sqlite3_close(connection) }

    func execute(_ sql: String, _ values: [String] = []) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK else {
            throw HistoryError(String(cString: sqlite3_errmsg(connection)))
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in values.enumerated() {
            sqlite3_bind_text(statement, Int32(offset + 1), value, -1, transient)
        }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw HistoryError(String(cString: sqlite3_errmsg(connection))) }
    }

    func insert(ts: Double, _ event: String, _ thread: String, _ turn: String, _ fields: String) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, "INSERT INTO events VALUES (?, ?, ?, ?, ?)", -1, &statement, nil) == SQLITE_OK else {
            throw HistoryError(String(cString: sqlite3_errmsg(connection)))
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_double(statement, 1, ts)
        for (offset, value) in [event, thread, turn, fields].enumerated() {
            sqlite3_bind_text(statement, Int32(offset + 2), value, -1, transient)
        }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw HistoryError(String(cString: sqlite3_errmsg(connection))) }
    }

    func strings(_ sql: String) throws -> [String] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK else {
            throw HistoryError(String(cString: sqlite3_errmsg(connection)))
        }
        defer { sqlite3_finalize(statement) }
        var result: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW { result.append(String(cString: sqlite3_column_text(statement, 0))) }
        return result
    }

    func int(_ sql: String) throws -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK else {
            throw HistoryError(String(cString: sqlite3_errmsg(connection)))
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw HistoryError("no row") }
        return Int(sqlite3_column_int64(statement, 0))
    }
}

@Suite final class HistoryTests {
    let temporary: URL
    let directory: URL
    let clock = HistoryTestClock(1_800_000_000.0)
    var history: History

    var now: Double {
        get { clock.now }
        set { clock.now = newValue }
    }

    var databaseURL: URL { directory.appendingPathComponent(History.databaseName) }

    init() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("history-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        directory = temporary.appendingPathComponent("private-history")
        let clock = self.clock
        history = try History(directory: directory, clock: { clock.now })
    }

    deinit {
        history.close()
        try? FileManager.default.removeItem(at: temporary)
    }

    func reopen() throws {
        history.close()
        let clock = self.clock
        history = try History(directory: directory, clock: { clock.now })
    }

    @discardableResult
    func record(_ event: String, _ turnID: String, thread: String = "session", _ fields: [String: JSON] = [:]) throws -> Bool {
        var given = fields
        given["thread_id"] = .string(thread)
        given["turn_id"] = .string(turnID)
        return try history.record(event, given)
    }

    func report(hours: Int = 24, limit: Int = 5) throws -> JSON {
        try History.report(directory: directory, hours: hours, limit: limit, now: now)
    }

    func counts(_ result: JSON, _ names: [String]) -> [String: Int] {
        Dictionary(uniqueKeysWithValues: names.map { ($0, result[$0]?.int ?? -1) })
    }

    func recent(_ result: JSON) -> [[String: JSON]] {
        (result["recent"]?.array ?? []).compactMap(\.object)
    }

    // test_counts_capacity_retries_and_all_terminal_outcomes
    @Test func countsCapacityRetriesAndAllTerminalOutcomes() throws {
        for (number, status, capacity) in [(1, "completed", false), (2, "failed", true),
                                           (3, "failed", false), (4, "interrupted", false)] {
            try record("waiting", "failure-\(number)", ["model": "selected-model", "due_at": .double(now + 300)])
            try record("retry", "failure-\(number)", ["retry_turn_id": .string("retry-\(number)")])
            try record("retry_result", "retry-\(number)", ["status": .string(status), "capacity": .bool(capacity)])
        }
        try record("uncertain", "failure-uncertain")
        let result = try report(limit: 20)
        #expect(result["available"] == true)
        #expect(counts(result, History.counters) == [
            "capacity": 4, "retries": 4, "successful": 1, "completed": 1, "failed": 2,
            "failed_capacity": 1, "failed_other": 1, "interrupted": 1,
            "uncertain": 1, "awaiting": 0,
        ])
        let capacityRow = try #require(recent(result).first { $0["event"] == "capacity" })
        #expect(capacityRow["model"] == "selected-model")
        #expect(capacityRow["due_at"] != nil)
    }

    // test_duplicate_events_count_once_and_keep_original_time
    @Test func duplicateEventsCountOnceAndKeepOriginalTime() throws {
        let originalTime = now
        #expect(try record("waiting", "failure"))
        now += 60
        #expect(try !record("waiting", "failure"))
        #expect(try record("waiting", "failure", thread: "another-session"))
        #expect(try record("uncertain", "failure"))
        let result = try report(limit: 10)
        #expect(result["capacity"] == 2)
        #expect(result["uncertain"] == 1)
        let row = try #require(recent(result).first { $0["event"] == "capacity" && $0["thread_id"] == "session" })
        #expect(row["ts"]?.number == originalTime)
    }

    // test_successful_and_legacy_completed_results_both_count_as_success
    @Test func successfulAndLegacyCompletedResultsBothCountAsSuccess() throws {
        try record("retry", "old-failure", ["retry_turn_id": "old-retry"])
        try record("retry_result", "old-retry", ["status": "completed", "capacity": false])
        try record("retry", "new-failure", ["retry_turn_id": "new-retry"])
        try record("retry_result", "new-retry", ["status": "successful", "capacity": false])
        let result = try report()
        #expect(result["successful"] == 2)
        #expect(result["completed"] == 1)
        #expect(result["awaiting"] == 0)
    }

    // test_success_result_is_deduplicated_and_late_failure_cannot_replace_it
    @Test func successResultIsDeduplicatedAndLateFailureCannotReplaceIt() throws {
        try record("retry", "failure", ["retry_turn_id": "retry"])
        #expect(try record("retry_result", "retry", ["status": "successful", "capacity": false]))
        now += 60
        #expect(try !record("retry_result", "retry", ["status": "successful", "capacity": false]))
        #expect(try !record("retry_result", "retry", ["status": "failed", "capacity": true]))
        let result = try report()
        #expect(result["successful"] == 1)
        #expect(result["failed"] == 0)
        #expect(result["awaiting"] == 0)
    }

    // test_new_success_status_remains_deduplicated_after_store_reopens
    @Test func newSuccessStatusRemainsDeduplicatedAfterStoreReopens() throws {
        try record("retry", "failure", ["retry_turn_id": "retry"])
        try record("retry_result", "retry", ["status": "successful", "capacity": false])
        history.close()
        now += 60
        try reopen()
        #expect(try !record("retry_result", "retry", ["status": "successful", "capacity": false]))
        let result = try report()
        #expect(result["successful"] == 1)
        #expect(result["awaiting"] == 0)
    }

    // test_restart_preserves_history_and_deduplication
    @Test func restartPreservesHistoryAndDeduplication() throws {
        let initialTime = now
        try record("retry", "failure", ["retry_turn_id": "retry"])
        history.close()
        now += 120
        try reopen()
        #expect(try !record("retry", "failure", ["retry_turn_id": "retry"]))
        try record("retry_result", "retry", ["status": "completed", "capacity": false])
        let result = try report()
        #expect(result["retries"] == 1)
        #expect(result["completed"] == 1)
        #expect(result["awaiting"] == 0)
        #expect(result["recorded_since"]?.number == initialTime)
    }

    // test_awaiting_links_result_by_retry_turn_and_thread
    @Test func awaitingLinksResultByRetryTurnAndThread() throws {
        try record("retry", "failure-one", ["retry_turn_id": "retry-one"])
        try record("retry", "failure-two", ["retry_turn_id": "retry-two"])
        // The original failed turn and another session's identical retry ID
        // cannot satisfy this session's pending retry.
        try record("retry_result", "failure-one", ["status": "failed", "capacity": true])
        try record("retry_result", "retry-one", thread: "another-session", ["status": "completed", "capacity": false])
        #expect(try report()["awaiting"] == 2)
        try record("retry_result", "retry-one", ["status": "completed", "capacity": false])
        #expect(try report()["awaiting"] == 1)
    }

    // test_24_hour_boundaries_exclude_older_and_future_events
    @Test func twentyFourHourBoundariesExcludeOlderAndFutureEvents() throws {
        let base = now
        try record("waiting", "older")
        now = base + 1
        try record("waiting", "boundary")
        now = base + 2
        try record("waiting", "inside")
        now = base + 24 * hour + 2
        try record("waiting", "future")
        now = base + 24 * hour + 1
        let result = try report(limit: 20)
        #expect(result["capacity"] == 2)
        #expect(recent(result).map { $0["turn_id"]?.string } == ["inside", "boundary"])
    }

    // test_outcomes_count_when_observed_even_for_older_retries
    @Test func outcomesCountWhenObservedEvenForOlderRetries() throws {
        let base = now
        try record("retry", "old-failure", ["retry_turn_id": "old-retry"])
        now += 25 * hour
        try record("retry_result", "old-retry", ["status": "completed", "capacity": false])
        let result = try report()
        #expect(result["retries"] == 0)
        #expect(result["completed"] == 1)
        #expect(result["awaiting"] == 0)
        #expect(result["recorded_since"]?.number == base)
    }

    // test_delayed_observation_uses_actual_completion_time
    @Test func delayedObservationUsesActualCompletionTime() throws {
        let base = now
        try record("retry", "failure", ["retry_turn_id": "retry"])
        now += 25 * hour
        let completedAt = base + 60
        try record("retry_result", "retry", ["status": "completed", "capacity": false, "occurred_at": .double(completedAt)])
        let result = try report()
        #expect(result["completed"] == 0)
        let widerResult = try report(hours: 48)
        #expect(widerResult["completed"] == 1)
        let completion = try #require(recent(widerResult).first { $0["event"] == "retry_result" })
        #expect(completion["ts"]?.number == completedAt)
        #expect(completion["occurred_at"]?.number == completedAt)
    }

    // test_delayed_outcome_beyond_retention_is_not_inserted
    @Test func delayedOutcomeBeyondRetentionIsNotInserted() throws {
        #expect(try !record("retry_result", "expired", ["status": "completed", "capacity": false,
                                                         "occurred_at": .double(now - 49 * hour)]))
        #expect(try report(hours: 72)["completed"] == 0)
        #expect(try HistoryTestDatabase(databaseURL).int("SELECT COUNT(*) FROM events") == 0)
    }

    // test_retention_prunes_older_than_48_hours_and_keeps_boundary
    @Test func retentionPrunesOlderThan48HoursAndKeepsBoundary() throws {
        let base = now
        try record("waiting", "expired")
        now += 1
        try record("waiting", "boundary")
        now = base + 48 * hour + 1
        try record("waiting", "current")
        let result = try report(hours: 48, limit: 20)
        #expect(result["capacity"] == 2)
        #expect(result["recorded_since"]?.number == base + 1)
        #expect(try HistoryTestDatabase(databaseURL).int("SELECT COUNT(*) FROM events") == 2)
    }

    // test_read_report_applies_retention_without_writing_database
    @Test func readReportAppliesRetentionWithoutWritingDatabase() throws {
        let base = now
        try record("waiting", "expired")
        let before = try Data(contentsOf: databaseURL)
        let result = try History.report(directory: directory, hours: 72, now: base + 49 * hour)
        #expect(result["capacity"] == 0)
        #expect(result["recorded_since"]?.number == base + hour)
        #expect(try Data(contentsOf: databaseURL) == before)
    }

    // test_recent_is_newest_first_and_limit_does_not_change_counts
    @Test func recentIsNewestFirstAndLimitDoesNotChangeCounts() throws {
        for number in 0..<5 {
            now += 1
            try record("waiting", "failure-\(number)")
        }
        let result = try report(limit: 2)
        #expect(result["capacity"] == 5)
        #expect(recent(result).map { $0["turn_id"]?.string } == ["failure-4", "failure-3"])
        #expect(try report(limit: 0)["recent"] == [])
    }

    // test_unrelated_events_are_ignored_and_database_is_private
    @Test func unrelatedEventsAreIgnoredAndDatabaseIsPrivate() throws {
        #expect(try !history.record("started", ["message": "observer started"]))
        #expect(try !history.record("connection_error", ["message": "temporarily offline"]))
        #expect(try report()["recent"] == [])
        let manager = FileManager.default
        let directoryMode = try manager.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int
        let databaseMode = try manager.attributesOfItem(atPath: databaseURL.path)[.posixPermissions] as? Int
        #expect(directoryMode.map { $0 & 0o777 } == 0o700)
        #expect(databaseMode.map { $0 & 0o777 } == 0o600)
    }

    // test_invalid_terminal_result_is_not_silently_counted
    @Test func invalidTerminalResultIsNotSilentlyCounted() throws {
        #expect(throws: HistoryError.self) {
            try self.record("retry_result", "retry", ["status": "inProgress", "capacity": false])
        }
        #expect(throws: HistoryError.self) {
            try self.record("retry_result", "retry", ["status": "failed", "capacity": "false"])
        }
        #expect(try report()["recent"] == [])
    }

    // test_missing_database_report_does_not_create_directory_or_database
    @Test func missingDatabaseReportDoesNotCreateDirectoryOrDatabase() throws {
        let missing = temporary.appendingPathComponent("missing-directory")
        let result = try History.report(directory: missing, now: now)
        #expect(result["available"] == false)
        #expect(result["recorded_since"] == .null)
        #expect(History.counters.allSatisfy { result[$0] == 0 })
        #expect(result["recent"] == [])
        #expect(!FileManager.default.fileExists(atPath: missing.path))
    }

    // test_quota_activity_has_separate_counters_and_preserves_origin
    @Test func quotaActivityHasSeparateCountersAndPreservesOrigin() throws {
        try record("waiting", "capacity-failure")
        try record("retry", "capacity-failure", ["retry_turn_id": "capacity-retry"])
        try record("retry_result", "capacity-retry", ["status": "successful", "capacity": false])
        let outcomes: [(String, Bool)] = [("successful", false), ("completed", false), ("failed", true),
                                          ("failed", false), ("interrupted", false)]
        for (number, (status, capacity)) in outcomes.enumerated() {
            try record("quota_waiting", "quota-failure-\(number)")
            try record("retry", "quota-failure-\(number)", ["kind": "quota", "retry_turn_id": .string("quota-retry-\(number)")])
            try record("retry_result", "quota-retry-\(number)", ["kind": "quota", "status": .string(status),
                                                                  "capacity": .bool(capacity)])
        }
        try record("quota_waiting", "quota-awaiting")
        try record("retry", "quota-awaiting", ["kind": "quota", "retry_turn_id": "quota-in-progress"])
        try record("uncertain", "quota-uncertain", ["kind": "quota"])
        let result = try report(limit: 50)
        #expect(counts(result, History.counters) == [
            "capacity": 1, "retries": 1, "successful": 1, "completed": 0,
            "failed": 0, "failed_capacity": 0, "failed_other": 0,
            "interrupted": 0, "uncertain": 0, "awaiting": 0,
        ])
        #expect(counts(result, History.quotaCounters) == [
            "quota": 6, "quota_retries": 6, "quota_successful": 2, "quota_completed": 1,
            "quota_failed": 2, "quota_failed_capacity": 1, "quota_failed_other": 1,
            "quota_interrupted": 1, "quota_uncertain": 1, "quota_awaiting": 1,
        ])
        let rows = recent(result)
        #expect(rows.filter { $0["turn_id"]?.string?.hasPrefix("quota-") == true }.allSatisfy { $0["kind"] == "quota" })
        #expect(rows.filter { $0["turn_id"]?.string?.hasPrefix("capacity-") == true }.allSatisfy { $0["kind"] == "capacity" })
    }

    // test_quota_duplicate_events_stay_deduplicated_after_restart
    @Test func quotaDuplicateEventsStayDeduplicatedAfterRestart() throws {
        let original = now
        #expect(try record("quota_waiting", "quota-failure"))
        #expect(try record("retry", "quota-failure", ["kind": "quota", "retry_turn_id": "quota-retry"]))
        history.close()
        now += 60
        try reopen()
        #expect(try !record("quota_waiting", "quota-failure"))
        #expect(try !record("retry", "quota-failure", ["kind": "quota", "retry_turn_id": "quota-retry"]))
        #expect(try record("retry_result", "quota-retry", ["kind": "quota", "status": "successful", "capacity": false]))
        #expect(try !record("retry_result", "quota-retry", ["kind": "quota", "status": "failed", "capacity": true]))
        let result = try report(limit: 10)
        #expect([result["quota"], result["quota_retries"], result["quota_successful"],
                 result["quota_failed"], result["quota_awaiting"]] == [1, 1, 1, 0, 0])
        #expect(result["retries"] == 0)
        let waiting = try #require(recent(result).first { $0["event"] == "quota" })
        #expect(waiting["ts"]?.number == original)
        #expect(result["recorded_since"]?.number == original)
    }

    // test_legacy_rows_without_kind_remain_capacity_and_are_not_rewritten
    @Test func legacyRowsWithoutKindRemainCapacityAndAreNotRewritten() throws {
        let original = now
        do {
            // Python wrote these through history.connection; Swift keeps that connection private,
            // so a second connection to the same file inserts them.
            let database = try HistoryTestDatabase(databaseURL)
            try database.insert(ts: original, "capacity", "legacy", "failure", #"{"model": "selected-model"}"#)
            try database.insert(ts: original, "retry", "legacy", "failure", #"{"retry_turn_id": "retry"}"#)
            try database.insert(ts: original, "retry_result", "legacy", "retry", #"{"status": "completed", "capacity": false}"#)
        }
        history.close()
        now += 120
        try reopen()
        try record("quota_waiting", "new-quota", thread: "new-session")
        let before = try Data(contentsOf: databaseURL)
        let result = try report(limit: 10)
        #expect([result["capacity"], result["retries"], result["successful"], result["awaiting"]] == [1, 1, 1, 0])
        #expect(result["quota"] == 1)
        #expect(recent(result).filter { $0["thread_id"] == "legacy" }.allSatisfy { $0["kind"] == "capacity" })
        #expect(result["recorded_since"]?.number == original)
        #expect(try Data(contentsOf: databaseURL) == before)
        let database = try HistoryTestDatabase(databaseURL)
        let stored = try database.strings("SELECT fields FROM events WHERE thread_id = 'legacy'")
        #expect(stored.count == 3)
        #expect(try stored.allSatisfy { try JSON.parse($0)["kind"] == nil })
        #expect(try database.int("PRAGMA user_version") == 1)
    }

    // test_quota_awaiting_requires_result_from_the_same_origin
    @Test func quotaAwaitingRequiresResultFromTheSameOrigin() throws {
        try record("retry", "quota-failure", ["kind": "quota", "retry_turn_id": "retry"])
        try record("retry_result", "retry", ["status": "successful", "capacity": false])
        let result = try report()
        #expect(result["successful"] == 1)
        #expect(result["quota_successful"] == 0)
        #expect(result["quota_awaiting"] == 1)
    }

    // test_quota_outcome_occurrence_time_and_retention_keep_capacity_counts_zero
    @Test func quotaOutcomeOccurrenceTimeAndRetentionKeepCapacityCountsZero() throws {
        let base = now
        try record("quota_waiting", "old-quota")
        try record("retry", "old-quota", ["kind": "quota", "retry_turn_id": "quota-retry"])
        now += 25 * hour
        try record("retry_result", "quota-retry", ["kind": "quota", "status": "successful", "capacity": false,
                                                    "occurred_at": .double(base + 60)])
        let recentReport = try report()
        #expect([recentReport["quota"], recentReport["quota_retries"], recentReport["quota_successful"]] == [0, 0, 0])
        let wider = try report(hours: 48)
        #expect([wider["quota"], wider["quota_retries"], wider["quota_successful"], wider["quota_awaiting"]] == [1, 1, 1, 0])
        #expect(History.counters.allSatisfy { wider[$0] == 0 })
        now = base + 49 * hour
        #expect(try report(hours: 72)["recent"] == [])
        #expect(try !record("retry_result", "expired-quota", ["kind": "quota", "status": "successful",
                                                               "capacity": false, "occurred_at": .double(base)]))
    }

    // test_history_drops_account_bindings_raw_quota_and_message_text
    @Test func historyDropsAccountBindingsRawQuotaAndMessageText() throws {
        try record("quota_waiting", "failure", ["kind": "quota", "model": "selected-model",
            "detected_at": .double(now), "accountId": "private-account", "account_binding": "private-binding",
            "rateLimits": ["usedPercent": 30], "credits": 12, "message": "private continuation"])
        try record("retry", "failure", ["kind": "quota", "retry_turn_id": "retry", "account_id": "private-account"])
        try record("retry_result", "retry", ["kind": "quota", "status": "successful", "capacity": false,
                                             "accountId": "private-account"])
        let stored = try HistoryTestDatabase(databaseURL).strings("SELECT fields FROM events").joined(separator: " ")
        #expect(!stored.contains("private-account"))
        #expect(!stored.contains("private-binding"))
        #expect(!stored.contains("private continuation"))
        #expect(!stored.contains("rateLimits"))
        #expect(!stored.contains("credits"))
        let result = try report(limit: 10)
        #expect(result["quota_successful"] == 1)
        let waiting = try #require(recent(result).first { $0["event"] == "quota" })
        #expect(waiting["model"] == "selected-model")
        #expect(waiting["detected_at"]?.number == now)
    }

    // test_invalid_or_conflicting_origin_is_rejected_without_counting
    @Test func invalidOrConflictingOriginIsRejectedWithoutCounting() throws {
        let cases: [(String, JSON)] = [("waiting", "quota"), ("quota_waiting", "capacity"),
                                       ("retry", "other"), ("uncertain", .null)]
        for (event, kind) in cases {
            #expect(throws: HistoryError.self, "\(event) with kind \(kind)") {
                try self.record(event, "invalid", ["kind": kind, "retry_turn_id": "retry"])
            }
        }
        #expect(try report()["recent"] == [])
    }

    // test_unavailable_report_zero_fills_quota_counters_without_creating_files
    @Test func unavailableReportZeroFillsQuotaCountersWithoutCreatingFiles() throws {
        let missing = temporary.appendingPathComponent("missing-quota-history")
        let result = try History.report(directory: missing, now: now)
        #expect(History.quotaCounters.allSatisfy { result[$0] == 0 })
        #expect(!FileManager.default.fileExists(atPath: missing.path))
    }
}
