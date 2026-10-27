import CryptoKit
import Foundation

public let capacityMessage = "Selected model is at capacity. Please try a different model"

/// Errors from Codex or a retry backend. The kinds mirror how the engine reacts to each.
public struct RPCError: Error, CustomStringConvertible, LocalizedError {
    public enum Kind: Sendable {
        /// The connection or protocol failed; the worker reconnects.
        case transport
        /// A rejected request, while the transport remains usable.
        case request
        /// A Desktop conversation with no active owner, a kind of rejected request.
        case noOwner
        /// The owning worker is stopping; this is not a connection failure.
        case cancelled
        /// A local preflight refused a retry before any submission was attempted.
        case notSubmitted
        /// A temporary preflight failure; the pending retry can be checked again.
        case deferred
    }

    public let kind: Kind
    public let description: String

    public init(_ kind: Kind, _ description: String) {
        self.kind = kind
        self.description = description
    }

    public static func transport(_ message: String) -> RPCError { RPCError(.transport, message) }
    public static func request(_ message: String) -> RPCError { RPCError(.request, message) }

    public var isRequest: Bool { kind == .request || kind == .noOwner }
    public var isNotSubmitted: Bool { kind == .notSubmitted || kind == .deferred }
    public var errorDescription: String? { description }
}

/// One Codex connection: the terminal daemon's control socket, or the Desktop facade.
public protocol RPCClient: AnyObject {
    func call(_ method: String, _ params: JSON) throws -> JSON
}

extension JSON {
    /// Python truthiness, which the engine's checks were written against.
    public var isTruthy: Bool { History.truthy(self) }

    /// Strict lookup in an RPC result: a missing field is a protocol failure.
    func required(_ key: String, _ method: String) throws -> JSON {
        guard let value = self[key] else { throw RPCError.transport("\(method): response has no \(key)") }
        return value
    }
}

private func trimmedMessage(_ error: JSON?) -> String {
    let message = error?["message"]?.string ?? ""
    var text = message.trimmingCharacters(in: pythonWhitespace)
    while text.hasSuffix(".") { text.removeLast() }
    return text
}

public func isCapacity(_ turn: JSON?) -> Bool {
    guard let turn, turn.isTruthy, turn["status"]?.string == "failed" else { return false }
    let error = turn["error"].flatMap { $0.isTruthy ? $0 : nil }
    let info = error?["codexErrorInfo"]
    // A specific non-capacity code always wins over a matching message.
    if info?.string == "serverOverloaded" { return true }
    let unspecified = info == nil || info == .null || info?.string == "other"
    return unspecified && trimmedMessage(error) == capacityMessage
}

/// Only Codex's explicit included-usage error can arm a quota wait.
public func isQuota(_ turn: JSON?) -> Bool {
    guard let turn, turn.isTruthy, turn["status"]?.string == "failed" else { return false }
    return turn["error"]?["codexErrorInfo"]?.string == "usageLimitExceeded"
}

public func failureKind(_ turn: JSON?) -> String? {
    if isCapacity(turn) { return "capacity" }
    if isQuota(turn) { return "quota" }
    return nil
}

/// Returns only a private account binding and explicit permission, never balances.
public func quotaSnapshot(_ rpc: RPCClient) throws -> (binding: String?, permission: Bool?) {
    let value = try rpc.call("account/rateLimits/read", ["excludeResetCreditDetails": true])
    guard value.object != nil else { return (nil, nil) }
    var binding: String?
    if let identity = value["accountId"]?.string, !identity.trimmingCharacters(in: pythonWhitespace).isEmpty {
        binding = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    return (binding, value["ordinaryUsageAllowed"]?.bool)
}

public func loadedThreads(_ rpc: RPCClient) throws -> [String] {
    var result: [String] = []
    var cursor: JSON = .null
    while true {
        let page = try rpc.call("thread/loaded/list", ["cursor": cursor, "limit": 100])
        guard let data = try page.required("data", "thread/loaded/list").array else {
            throw RPCError.transport("thread/loaded/list: data is not a list")
        }
        result += data.compactMap(\.string)
        cursor = page["nextCursor"] ?? .null
        if !cursor.isTruthy { return result }
    }
}

/// Reads a session and, when it is eligible, its latest turn. With `verify`, the runtime
/// status is read again last, immediately before a submission.
public func snapshot(_ rpc: RPCClient, _ threadID: String, verify: Bool = false) throws -> (thread: JSON, turn: JSON?) {
    let readParams: JSON = ["threadId": .string(threadID), "includeTurns": false]
    var thread = try rpc.call("thread/read", readParams).required("thread", "thread/read")
    guard eligible(thread) else { return (thread, nil) }
    let turns = try rpc.call("thread/turns/list", [
        "threadId": .string(threadID), "limit": 1, "sortDirection": "desc", "itemsView": "notLoaded",
    ]).required("data", "thread/turns/list").array ?? []
    if verify {
        thread = try rpc.call("thread/read", readParams).required("thread", "thread/read")
    }
    return (thread, turns.first)
}

public func watchable(_ thread: JSON) -> Bool {
    let source = thread["source"]?.string
    let originator = thread["originator"]?.string
    let terminal = ["cli", "vscode", "appServer"].contains(source ?? "") && (source == "cli" || originator == "codex-tui")
    let desktop = source == "desktop" && originator == "codex-desktop" && thread["controlBackend"]?.string == "desktop-ipc"
    let threadSource = thread["threadSource"]
    return !(thread["parentThreadId"]?.isTruthy ?? false)
        && !(thread["ephemeral"]?.isTruthy ?? false)
        && (threadSource == nil || threadSource == .null || threadSource?.string == "user")
        && thread["source"]?.object == nil
        && (terminal || desktop)
        && thread["canAcceptDirectInput"] == .bool(true)
        && (thread["model"]?.isTruthy ?? false)
}

public func eligible(_ thread: JSON) -> Bool {
    watchable(thread) && ["idle", "systemError"].contains(thread["status"]?["type"]?.string ?? "")
}

func sameControlContext(_ thread: JSON, _ pending: Pending) -> Bool {
    [("controlBackend", pending.controlBackend), ("controlOwner", pending.controlOwner),
     ("controlSettingsFingerprint", pending.controlSettings)].allSatisfy { field, saved in
        (thread[field] ?? .null) == JSON(saved)
    }
}
