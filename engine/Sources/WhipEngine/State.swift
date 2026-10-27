import Foundation

/// A failure waiting for its retry or quota check. Field names match `state.json`.
public struct Pending: Equatable, Sendable {
    public var turnID: String
    public var model: String
    public var effort: String?
    public var detectedAt: Double?
    public var waitStartedAt: Double?
    public var dueAt: Double
    public var kind: String?
    public var quotaStatus: String?
    public var quotaCheckedAt: Double?
    /// A private hash of the observed account, never logged or written to history.
    public var accountBinding: String?

    public init(turnID: String, model: String, effort: String?, detectedAt: Double?, waitStartedAt: Double?,
                dueAt: Double, kind: String? = nil) {
        self.turnID = turnID
        self.model = model
        self.effort = effort
        self.detectedAt = detectedAt
        self.waitStartedAt = waitStartedAt
        self.dueAt = dueAt
        self.kind = kind
    }

    public var resolvedKind: String { kind ?? "capacity" }

    public var json: JSON {
        var value: [String: JSON] = ["turn_id": .string(turnID), "model": .string(model),
                                     "effort": JSON(effort), "due_at": .double(dueAt)]
        value["detected_at"] = detectedAt.map(JSON.double)
        value["wait_started_at"] = waitStartedAt.map(JSON.double)
        value["kind"] = kind.map(JSON.string)
        value["quota_status"] = quotaStatus.map(JSON.string)
        value["quota_checked_at"] = quotaCheckedAt.map(JSON.double)
        value["account_binding"] = accountBinding.map(JSON.string)
        return .object(value)
    }

    /// Fields reported with the waiting event: everything except the account binding.
    var eventFields: [String: JSON] {
        var fields = json.object ?? [:]
        fields["account_binding"] = nil
        return fields
    }

    public init(json: JSON) throws {
        guard let turnID = json["turn_id"]?.string, let model = json["model"]?.string,
              let dueAt = json["due_at"]?.number else {
            throw StateError("A saved retry is missing its turn, model, or due time")
        }
        self.init(turnID: turnID, model: model, effort: json["effort"]?.string, detectedAt: json["detected_at"]?.number,
                  waitStartedAt: json["wait_started_at"]?.number, dueAt: dueAt, kind: json["kind"]?.string)
        quotaStatus = json["quota_status"]?.string
        quotaCheckedAt = json["quota_checked_at"]?.number
        accountBinding = json["account_binding"]?.string
    }
}

/// The latest handled failure in a session: a cancellation, or a send and its observed result.
public struct Attempt: Equatable, Sendable {
    public var turnID: String
    public var at: Double?
    public var outcome: String
    public var kind: String?
    public var reason: String?
    public var capacityAt: Double?
    public var quotaAt: Double?
    public var retryTurnID: String?
    public var resultStatus: String?
    public var resultAt: Double?
    public var resultCapacity: Bool?
    public var healthySince: Double?
    public var healthyLastSeen: Double?

    public init(turnID: String, at: Double? = nil, outcome: String, kind: String? = nil, reason: String? = nil) {
        self.turnID = turnID
        self.at = at
        self.outcome = outcome
        self.kind = kind
        self.reason = reason
    }

    public var resolvedKind: String { kind ?? "capacity" }

    /// A sent retry whose outcome is still being observed.
    public var awaitingResult: Bool {
        outcome == "submitted" && (resultStatus ?? "").isEmpty
    }

    public var json: JSON {
        var value: [String: JSON] = ["turn_id": .string(turnID), "outcome": .string(outcome)]
        value["at"] = at.map(JSON.double)
        value["kind"] = kind.map(JSON.string)
        value["reason"] = reason.map(JSON.string)
        value["capacity_at"] = capacityAt.map(JSON.double)
        value["quota_at"] = quotaAt.map(JSON.double)
        value["retry_turn_id"] = retryTurnID.map(JSON.string)
        value["result_status"] = resultStatus.map(JSON.string)
        value["result_at"] = resultAt.map(JSON.double)
        value["result_capacity"] = resultCapacity.map(JSON.bool)
        value["healthy_since"] = healthySince.map(JSON.double)
        value["healthy_last_seen"] = healthyLastSeen.map(JSON.double)
        return .object(value)
    }

    public init(json: JSON) throws {
        guard let turnID = json["turn_id"]?.string, let outcome = json["outcome"]?.string else {
            throw StateError("A saved retry attempt is missing its turn or outcome")
        }
        self.init(turnID: turnID, at: json["at"]?.number, outcome: outcome, kind: json["kind"]?.string,
                  reason: json["reason"]?.string)
        capacityAt = json["capacity_at"]?.number
        quotaAt = json["quota_at"]?.number
        retryTurnID = json["retry_turn_id"]?.string
        resultStatus = json["result_status"]?.string
        resultAt = json["result_at"]?.number
        resultCapacity = json["result_capacity"]?.bool
        healthySince = json["healthy_since"]?.number
        healthyLastSeen = json["healthy_last_seen"]?.number
    }
}

/// Session counts from the last discovery scan.
public struct SessionCounts: Equatable, Sendable {
    public var total = 0, active = 0, idle = 0, errored = 0, other = 0, unavailable = 0

    public init() {}

    public var json: JSON {
        ["total": .int(total), "active": .int(active), "idle": .int(idle), "errored": .int(errored),
         "other": .int(other), "unavailable": .int(unavailable)]
    }
}

/// The retry journal in `state.json`. A reference type, so the engine and the worker loop share it.
public final class RetryState {
    public var version: Int
    public var enabledAt: Double
    public var threads: [String]
    public var pending: [String: Pending] = [:]
    public var handled: [String: Attempt] = [:]
    public var paused: [String: JSON] = [:]
    public var lastError: String?
    public var lastScanAt: Double?
    public var sessions: JSON?

    public init(enabledAt: Double = Date().timeIntervalSince1970, threads: [String] = []) {
        version = 1
        self.enabledAt = enabledAt
        self.threads = threads
    }

    public init(json: JSON) throws {
        guard json.object != nil else { throw StateError("Retry state must be a JSON object") }
        guard json["version"]?.int == 1 else { throw StateError("Unsupported retry-state version") }
        version = 1
        guard let enabledAt = json["enabled_at"]?.number else { throw StateError("Retry state has no activation time") }
        self.enabledAt = enabledAt
        threads = (json["threads"]?.array ?? []).compactMap(\.string)
        for (id, value) in json["pending"]?.object ?? [:] { pending[id] = try Pending(json: value) }
        for (id, value) in json["handled"]?.object ?? [:] { handled[id] = try Attempt(json: value) }
        paused = json["paused"]?.object ?? [:]
        lastError = json["last_error"]?.string
        lastScanAt = json["last_scan_at"]?.number
        sessions = json["sessions"]
    }

    public var json: JSON {
        var value: [String: JSON] = [
            "version": .int(version), "enabled_at": .double(enabledAt), "threads": .array(threads.map(JSON.string)),
            "pending": .object(pending.mapValues(\.json)), "handled": .object(handled.mapValues(\.json)),
            "paused": .object(paused), "last_error": JSON(lastError),
        ]
        value["last_scan_at"] = lastScanAt.map(JSON.double)
        value["sessions"] = sessions
        return .object(value)
    }

    public static func read(_ url: URL) throws -> RetryState {
        try RetryState(json: FileStore.readJSON(url))
    }

    public func write(_ url: URL) throws {
        try FileStore.writeJSON(json, to: url)
    }
}

public struct StateError: Error, CustomStringConvertible, LocalizedError {
    public let description: String
    public init(_ description: String) { self.description = description }
    public var errorDescription: String? { description }
}
