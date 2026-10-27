import Foundation

/// Opt-in Desktop capacity control, bound to fresh owner snapshots.
///
/// The shared app-server connection supplies persisted completion timestamps only. It never
/// receives a turn/start, a resume, or an account request from this adapter.
public final class DesktopRPC: RPCClient {
    public typealias IPCFactory = (URL, Double, @escaping () -> Bool) throws -> DesktopIPC
    let socketPath: URL
    let metadata: RPCClient
    let threadIDs: [String]
    let shouldStop: () -> Bool
    let makeIPC: IPCFactory
    private(set) var anchors: [String: JSON] = [:]

    public init(socketPath: URL, metadata: RPCClient, threadIDs: [String], shouldStop: @escaping () -> Bool = { false },
                makeIPC: @escaping IPCFactory = { try DesktopIPC(path: $0, timeout: $1, shouldStop: $2) }) throws {
        var unique: [String] = []
        for id in threadIDs where !unique.contains(id) { unique.append(id) }
        guard !unique.isEmpty, unique.count <= 8 else { throw WhipError("Select from one to eight Desktop conversations explicitly.") }
        self.socketPath = socketPath
        self.metadata = metadata
        self.threadIDs = unique
        self.shouldStop = shouldStop
        self.makeIPC = makeIPC
    }

    /// The caller owns the metadata connection. Every Desktop snapshot lease is closed
    /// before its call returns, so no follower or cached transcript survives.
    public func close() {
        anchors.removeAll()
    }

    static func safeError(_ error: JSON?) -> JSON {
        guard let error, error.object != nil else { return .null }
        var info = error["codexErrorInfo"] ?? .null
        if ![.null, "other", "serverOverloaded", "usageLimitExceeded"].contains(info) { info = "unsupported" }
        var message = (error["message"]?.string ?? "").trimmingCharacters(in: pythonWhitespace)
        while message.hasSuffix(".") { message.removeLast() }
        let matches = error["message"]?.string != nil && message == capacityMessage
        return ["codexErrorInfo": info, "message": .string(matches ? capacityMessage : "")]
    }

    static func signature(_ turn: JSON) -> JSON {
        var info = turn["error"]?.object != nil ? (turn["error"]?["codexErrorInfo"] ?? .null) : .null
        if ![.null, "other", "serverOverloaded", "usageLimitExceeded"].contains(info) { info = "unsupported" }
        return [turn["id"] ?? .null, turn["status"] ?? .null, info, JSON(failureKind(turn))]
    }

    private func scope(_ id: String?) throws -> String {
        guard let id, threadIDs.contains(id) else { throw RPCError.request("The Desktop conversation is outside the selected scope.") }
        return id
    }

    private func owner(_ ipc: DesktopIPC, _ id: String) throws -> String {
        let response = try ipc.requestFull("thread-owner-discovery", ["hostId": "local", "conversationId": .string(id)],
                                           version: 1, timeout: 12)
        guard let owner = response["handledByClientId"]?.nonemptyString,
              response["result"]?.object != nil, response["result"]?["supportsUntrustedAppInput"] == true else {
            throw RPCError.request("Desktop cannot accept external input for this conversation.")
        }
        return owner
    }

    /// Opens a fresh client binding, follows the conversation for one targeted snapshot, and
    /// always unfollows and closes before returning.
    func withLease<T>(_ id: String, _ body: (DesktopIPC, DesktopView) throws -> T) throws -> T {
        _ = try scope(id)
        var ipc: DesktopIPC?
        var ownerID: String?
        var followed = false
        defer {
            if let ipc {
                if followed, let ownerID {
                    try? ipc.broadcast("thread-stream-following-changed",
                                       ["hostId": "local", "conversationId": .string(id), "following": false],
                                       version: 1, targets: [ownerID], timeout: 0.25)
                }
                ipc.close()
            }
        }
        do {
            // A new client binding proves that a matching targeted snapshot was
            // produced for this read, even when its revision did not change.
            let connection = try makeIPC(socketPath, 12, shouldStop)
            ipc = connection
            let owner = try self.owner(connection, id)
            ownerID = owner
            let settings = try connection.request("thread-follower-read-model-settings", ["conversationId": .string(id)],
                                                  version: 1, target: owner, timeout: 5)
            try connection.broadcast("thread-stream-following-changed",
                                     ["hostId": "local", "conversationId": .string(id), "following": true],
                                     version: 1, targets: [owner])
            followed = true
            let envelope = try connection.waitBroadcast(timeout: 5) { message in
                message["method"] == "thread-stream-state-changed" && message["sourceClientId"] == .string(owner)
                    && message["params"]?.object != nil && message["params"]?["conversationId"] == .string(id)
            }
            var view = try DesktopState.normalize(envelope, conversationID: id, ownerID: owner,
                                                  clientID: connection.clientID ?? "", modelSettings: settings)
            view.thread["controlOwner"] = .string(view.owner)
            view.thread["controlSettingsFingerprint"] = .string(view.settingsFingerprint)
            return try body(connection, view)
        } catch let error as DesktopIPCError {
            if error.code == "cancelled" { throw RPCError(.cancelled, "Desktop checking stopped.") }
            if error.code == "no-client-found" { throw RPCError(.noOwner, "The Desktop conversation has no active owner.") }
            throw RPCError.request(error.description)
        } catch let error as DesktopStateError {
            throw RPCError.request(error.description)
        }
    }

    func storedTurns(_ id: String, limit: Int = 1) throws -> [JSON] {
        do {
            let result = try metadata.call("thread/turns/list", ["threadId": .string(id), "limit": .int(limit),
                                                                 "sortDirection": "desc", "itemsView": "notLoaded"])
            guard let turns = result["data"]?.array, turns.allSatisfy({ $0.object != nil }) else { throw WhipError("invalid") }
            return turns
        } catch let error as RPCError where error.kind == .cancelled {
            throw error
        } catch {
            throw RPCError.request("Desktop's saved turn summary is unavailable.")
        }
    }

    func matchedTurn(_ view: DesktopView, _ stored: [JSON]) throws -> JSON {
        guard let live = view.turn, live.object != nil, live["id"]?.isTruthy == true, let first = stored.first,
              DesktopRPC.signature(live) == DesktopRPC.signature(first) else {
            throw RPCError.request("Desktop and its saved turn summary are not synchronized.")
        }
        var result = live
        if let completed = first["completedAt"]?.number, completed.isFinite, completed >= 0 {
            result["completedAt"] = first["completedAt"]!
        }
        return result
    }

    static func anchor(_ view: DesktopView, _ turn: JSON) -> JSON {
        [.string(view.owner), .int(view.revision), .string(view.settingsFingerprint), signature(turn)]
    }

    public func call(_ method: String, _ params: JSON) throws -> JSON {
        if shouldStop() { throw RPCError(.cancelled, "Desktop checking stopped.") }
        if method == "account/rateLimits/read" {
            // CLI and Desktop may use different accounts. Never substitute CLI
            // quota permission for an unverified Desktop account response.
            return ["accountId": .null, "ordinaryUsageAllowed": .null]
        }
        if method == "thread/loaded/list" {
            var result: [JSON] = []
            for id in threadIDs {
                do {
                    try withLease(id) { _, _ in }
                    result.append(.string(id))
                } catch let error as RPCError where error.kind == .noOwner {
                    continue
                }
            }
            return ["data": .array(result), "nextCursor": .null]
        }
        let id = try scope(params["threadId"]?.string)
        switch method {
        case "thread/read":
            return try withLease(id) { _, view in ["thread": view.thread] }
        case "thread/turns/list":
            let requested = params["limit"]?.int ?? Int(params["limit"]?.number ?? 1)
            let limit = min(max(requested, 1), 20)
            return try withLease(id) { _, view in
                let stored = try storedTurns(id, limit: limit)
                let turn = try matchedTurn(view, stored)
                anchors[id] = DesktopRPC.anchor(view, turn)
                // Older persisted results are used only for outcome tracking.
                // Their text and items are never returned to the retry engine.
                let history: [JSON] = stored.dropFirst().map { item in
                    ["id": item["id"] ?? .null, "status": item["status"] ?? .null,
                     "completedAt": item["completedAt"] ?? .null, "error": DesktopRPC.safeError(item["error"])]
                }
                return ["data": .array([turn] + history), "nextCursor": .null]
            }
        case "turn/start":
            return try start(id, params)
        default:
            throw RPCError.request("This operation is unavailable in the Desktop prototype.")
        }
    }

    private func start(_ id: String, _ params: JSON) throws -> JSON {
        let input = params["input"]?.array
        guard let anchor = anchors[id], let messageID = params["clientUserMessageId"]?.nonemptyString,
              let input, input.count == 1, input[0].object != nil, input[0]["type"] == "text",
              let text = input[0]["text"]?.string, !text.trimmingCharacters(in: pythonWhitespace).isEmpty else {
            throw RPCError(.notSubmitted, "Desktop retry preflight is incomplete.")
        }
        var attempted = false
        do {
            // Persisted summaries can be slow. Obtain them BEFORE the final
            // owner-bound runtime snapshot, never after its inactivity check.
            let stored = try storedTurns(id)
            return try withLease(id) { ipc, view in
                let turn: JSON
                do {
                    turn = try matchedTurn(view, stored)
                } catch let error as RPCError where error.isRequest {
                    throw RPCError(.notSubmitted, "Desktop changed before retry submission.")
                }
                guard eligible(view.thread), isCapacity(turn), DesktopRPC.anchor(view, turn) == anchor, !shouldStop() else {
                    throw RPCError(.notSubmitted, "Desktop changed before retry submission.")
                }
                // This internal method has no compare-and-start precondition.
                // The final snapshot is immediately followed by the owner send.
                attempted = true
                var item = input[0]
                item["text_elements"] = .array([])
                let result = try ipc.request("thread-follower-start-turn", [
                    "conversationId": .string(id),
                    "turnStart": [
                        "request": ["threadId": .string(id), "input": [item], "clientUserMessageId": .string(messageID)],
                        "context": ["inheritThreadSettings": true],
                    ],
                ], version: 2, target: view.owner, timeout: 10)
                let accepted = result.object != nil ? result["result"] : nil
                let newTurn = accepted?.object != nil ? accepted?["turn"] : nil
                guard let newTurn, newTurn.object != nil, let newID = newTurn["id"]?.nonemptyString,
                      .string(newID) != turn["id"],
                      ["inProgress", "completed", "failed", "interrupted"].contains(newTurn["status"]?.string ?? "") else {
                    throw RPCError.transport("Desktop's retry acknowledgement is unavailable; check the conversation manually.")
                }
                return ["turn": ["id": .string(newID), "status": newTurn["status"]!]]
            }
        } catch let error as RPCError where error.isNotSubmitted {
            throw error
        } catch let error as RPCError {
            if !attempted { throw RPCError(.deferred, "Desktop preflight is temporarily unavailable.") }
            throw error
        }
    }
}
