import Foundation
import SQLite3

/// Private local event history. No conversation text is stored.
public final class History {
    public static let databaseName = "history.sqlite3"
    public static let retentionSeconds: Double = 48 * 60 * 60
    static let events = ["waiting": "capacity", "quota_waiting": "quota", "retry": "retry",
                         "retry_result": "retry_result", "uncertain": "uncertain"]
    public static let counters = ["capacity", "retries", "successful", "completed", "failed", "failed_capacity",
                                  "failed_other", "interrupted", "uncertain", "awaiting"]
    public static let quotaCounters = ["quota"] + counters.filter { $0 != "capacity" }.map { "quota_" + $0 }
    /// History is an activity record, not a copy of the engine's private state or account
    /// response. In particular, account bindings and message text never enter it.
    static let eventFields: Set<String> = [
        "thread_id", "turn_id", "kind", "model", "effort", "detected_at", "wait_started_at", "due_at", "at",
        "capacity_at", "quota_at", "outcome", "retry_turn_id", "status", "capacity", "occurred_at",
    ]

    private var connection: OpaquePointer?
    private let clock: () -> Double

    public init(directory: URL, clock: @escaping () -> Double = { Date().timeIntervalSince1970 }) throws {
        self.clock = clock
        try FileStore.makePrivateDirectory(directory)
        let path = directory.appendingPathComponent(History.databaseName).path
        let descriptor = open(path, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, 0o600)
        if descriptor >= 0 { Darwin.close(descriptor) } else if errno != EEXIST { throw FileStore.posixError() }
        guard chmod(path, 0o600) == 0 else { throw FileStore.posixError() }
        guard sqlite3_open_v2(path, &connection, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let message = connection.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(connection)
            throw HistoryError("Cannot open retry history: \(message)")
        }
        sqlite3_busy_timeout(connection, 5000)
        do {
            let version = try History.scalarInt(connection, "PRAGMA user_version")
            guard version == 0 || version == 1 else { throw HistoryError("Unsupported retry history version: \(version)") }
            try execute("""
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
            let now = clock()
            try transaction {
                try run("INSERT OR IGNORE INTO metadata(key, value) VALUES ('recorded_since', ?)", [.double(now)])
                try run("DELETE FROM events WHERE ts < ?", [.double(now - History.retentionSeconds)])
            }
        } catch {
            sqlite3_close(connection)
            connection = nil
            throw error
        }
    }

    deinit { close() }

    public func close() {
        if let connection { sqlite3_close(connection) }
        connection = nil
    }

    static func eventKind(_ event: String, _ fields: [String: JSON]) throws -> String {
        let expected = ["capacity": "capacity", "quota": "quota"][event]
        let kind: JSON = fields["kind"] ?? .string(expected ?? "capacity")
        guard let value = kind.string, value == "capacity" || value == "quota",
              expected == nil || value == expected else {
            throw HistoryError("Retry history kind must match capacity or quota origin")
        }
        return value
    }

    /// Returns whether a new tracked event was inserted; repeated events count once.
    @discardableResult
    public func record(_ event: String, _ given: [String: JSON] = [:]) throws -> Bool {
        let normalized = History.events[event]
        let now = clock()
        var occurredAt = now
        var fields = given
        var encoded = ""
        if let normalized {
            fields = given.filter { History.eventFields.contains($0.key) }
            fields["kind"] = .string(try History.eventKind(normalized, fields))
            if let value = fields["occurred_at"], !value.isNull {
                guard let number = value.number, number.isFinite else {
                    throw HistoryError("Retry history occurred_at requires a finite Unix timestamp")
                }
                occurredAt = number
            }
            for name in ["thread_id", "turn_id"] where fields[name]?.nonemptyString == nil {
                throw HistoryError("Retry history \(event) requires \(name)")
            }
            if event == "retry" && !History.truthy(fields["retry_turn_id"]) {
                throw HistoryError("Retry history retry requires retry_turn_id")
            }
            if event == "retry_result" {
                guard let status = fields["status"]?.string,
                      ["successful", "completed", "failed", "interrupted"].contains(status) else {
                    throw HistoryError("Retry history retry_result requires a retry outcome")
                }
                guard fields["capacity"]?.bool != nil else {
                    throw HistoryError("Retry history retry_result requires a capacity boolean")
                }
            }
            encoded = try JSON.object(fields).serialized(.ascii)
        }
        var inserted = false
        try transaction {
            try run("DELETE FROM events WHERE ts < ?", [.double(now - History.retentionSeconds)])
            guard let normalized, occurredAt >= now - History.retentionSeconds else { return }
            try run("INSERT OR IGNORE INTO events(ts, event, thread_id, turn_id, fields) VALUES (?, ?, ?, ?, ?)",
                    [.double(occurredAt), .string(normalized), fields["thread_id"]!, fields["turn_id"]!, .string(encoded)])
            inserted = sqlite3_changes(connection) == 1
        }
        return inserted
    }

    static func truthy(_ value: JSON?) -> Bool {
        switch value {
        case nil, .null?: return false
        case .bool(let flag)?: return flag
        case .int(let number)?: return number != 0
        case .double(let number)?: return number != 0
        case .string(let text)?: return !text.isEmpty
        case .array(let items)?: return !items.isEmpty
        case .object(let items)?: return !items.isEmpty
        }
    }

    // MARK: SQLite helpers

    private func execute(_ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(connection, sql, nil, nil, &message) == SQLITE_OK else {
            let text = message.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(message)
            throw HistoryError("Retry history error: \(text)")
        }
    }

    private func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try body()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func run(_ sql: String, _ values: [JSON]) throws {
        let statement = try History.prepare(connection, sql, values)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw HistoryError("Retry history error: \(String(cString: sqlite3_errmsg(connection)))")
        }
    }

    static func prepare(_ connection: OpaquePointer?, _ sql: String, _ values: [JSON]) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK else {
            throw HistoryError("Retry history error: \(String(cString: sqlite3_errmsg(connection)))")
        }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .double(let number): sqlite3_bind_double(statement, index, number)
            case .int(let number): sqlite3_bind_int64(statement, index, Int64(number))
            case .string(let text): sqlite3_bind_text(statement, index, text, -1, transient)
            default: sqlite3_bind_null(statement, index)
            }
        }
        return statement
    }

    static func scalarInt(_ connection: OpaquePointer?, _ sql: String) throws -> Int {
        let statement = try prepare(connection, sql, [])
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw HistoryError("Retry history error") }
        return Int(sqlite3_column_int64(statement, 0))
    }
}

public struct HistoryError: Error, CustomStringConvertible, LocalizedError {
    public let description: String
    public init(_ description: String) { self.description = description }
    public var errorDescription: String? { description }
}

extension History {
    /// Reads a time-window report without creating or modifying a history database.
    ///
    /// Outcomes count at the supplied occurrence time, or observation time when unavailable.
    /// Awaiting counts retries sent in the window without a terminal result, including results
    /// outside that window. Retained coverage is limited to the most recent 48 hours.
    public static func report(directory: URL, hours: Int = 24, limit: Int = 5, now given: Double? = nil) throws -> JSON {
        guard hours > 0, limit >= 0 else { throw HistoryError("hours must be positive and limit cannot be negative") }
        let now = given ?? Date().timeIntervalSince1970
        var report: [String: JSON] = ["available": false, "recorded_since": .null, "recent": []]
        for name in counters + quotaCounters { report[name] = 0 }
        let url = directory.appendingPathComponent(databaseName)
        guard FileManager.default.fileExists(atPath: url.path) else { return .object(report) }
        var connection: OpaquePointer?
        let uri = url.standardizedFileURL.absoluteString + "?mode=ro"
        guard sqlite3_open_v2(uri, &connection, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            sqlite3_close(connection)
            throw HistoryError("Cannot read retry history")
        }
        defer { sqlite3_close(connection) }
        sqlite3_busy_timeout(connection, 5000)
        let sinceStatement = try prepare(connection, "SELECT value FROM metadata WHERE key = 'recorded_since'", [])
        guard sqlite3_step(sinceStatement) == SQLITE_ROW else {
            sqlite3_finalize(sinceStatement)
            throw HistoryError("Retry history has no recording start")
        }
        let since = sqlite3_column_double(sinceStatement, 0)
        sqlite3_finalize(sinceStatement)
        let statement = try prepare(connection,
            "SELECT ts, event, thread_id, turn_id, fields FROM events WHERE ts >= ? AND ts <= ? " +
            "ORDER BY ts DESC, event, thread_id, turn_id", [.double(now - retentionSeconds), .double(now)])
        defer { sqlite3_finalize(statement) }
        var rows: [[String: JSON]] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw HistoryError("Cannot read retry history") }
            let ts = sqlite3_column_double(statement, 0)
            let event = String(cString: sqlite3_column_text(statement, 1))
            let threadID = String(cString: sqlite3_column_text(statement, 2))
            let turnID = String(cString: sqlite3_column_text(statement, 3))
            let stored = try JSON.parse(String(cString: sqlite3_column_text(statement, 4)))
            var row = (stored.object ?? [:]).filter { eventFields.contains($0.key) }
            row["kind"] = .string(try eventKind(event, row))
            row["ts"] = .double(ts)
            row["event"] = .string(event)
            row["thread_id"] = .string(threadID)
            row["turn_id"] = .string(turnID)
            rows.append(row)
        }
        report["available"] = true
        report["recorded_since"] = .double(max(since, now - retentionSeconds))
        func key(_ row: [String: JSON], _ turn: String) -> String {
            "\(row["kind"]?.string ?? "")\u{0}\(row["thread_id"]?.string ?? "")\u{0}\(row[turn]?.string ?? "")"
        }
        let finished = Set(rows.filter { $0["event"] == "retry_result" }.map { key($0, "turn_id") })
        let cutoff = now - Double(hours) * 60 * 60
        let recent = rows.filter { ($0["ts"]?.number ?? 0) >= cutoff }
        func add(_ name: String) { report[name] = .int((report[name]?.int ?? 0) + 1) }
        for row in recent {
            let prefix = row["kind"] == "quota" ? "quota_" : ""
            switch row["event"]?.string {
            case "capacity": add("capacity")
            case "quota": add("quota")
            case "retry":
                add(prefix + "retries")
                if !finished.contains(key(row, "retry_turn_id")) { add(prefix + "awaiting") }
            case "uncertain": add(prefix + "uncertain")
            case "retry_result":
                guard let status = row["status"]?.string else { break }
                add(prefix + status)
                if status == "completed" { add(prefix + "successful") }
                if status == "failed" { add(prefix + (row["capacity"]?.bool == true ? "failed_capacity" : "failed_other")) }
            default: break
            }
        }
        report["recent"] = .array(recent.prefix(limit).map(JSON.object))
        return .object(report)
    }
}
