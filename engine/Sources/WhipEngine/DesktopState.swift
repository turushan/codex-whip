import CryptoKit
import Foundation

/// A sanitized protocol error that never includes a received payload.
public struct DesktopStateError: Error, CustomStringConvertible, LocalizedError {
    public let code: String
    public init(_ code: String) { self.code = code }
    public var description: String { "Desktop state is unavailable (\(code))." }
    public var errorDescription: String? { description }
}

/// The retry-relevant part of a trusted Desktop snapshot, without its transcript.
public struct DesktopView {
    public var thread: JSON
    public var turn: JSON?
    public var revision: Int
    public var owner: String
    public var settingsFingerprint: String
    public var blockedReason: String?
}

enum DesktopState {
    static func require(_ condition: Bool, _ code: String) throws {
        if !condition { throw DesktopStateError(code) }
    }

    static func text(_ value: JSON?) -> Bool {
        guard let string = value?.string else { return false }
        return !string.trimmingCharacters(in: pythonWhitespace).isEmpty
    }

    static func latestTurn(_ state: JSON) throws -> JSON? {
        let wrapper = state["turnHistory"]
        try require(wrapper?.object != nil && wrapper?["kind"] == "canonical", "unsupported-history")
        let history = wrapper?["history"]
        try require(history?.object != nil, "invalid-history")
        guard let islands = history?["islands"]?.array, let entities = history?["entitiesByKey"]?.object else {
            throw DesktopStateError("invalid-history")
        }
        guard let newest = islands.last else {
            try require(entities.isEmpty, "invalid-history")
            return nil
        }
        try require(newest.object != nil, "invalid-history")
        let boundary = newest["newerBoundary"]
        try require(boundary?.object != nil && boundary?["status"] == "exhausted", "incomplete-latest-history")
        guard let entries = newest["entries"]?.array else { throw DesktopStateError("invalid-history") }
        guard let entry = entries.last else { return nil }
        try require(entry.object != nil && text(entry["key"]) && text(entry["value"]), "invalid-history")
        guard let turn = entities[entry["value"]!.string!], turn.object != nil else { throw DesktopStateError("invalid-history") }
        return turn
    }

    static func error(_ value: JSON?) throws -> JSON {
        guard let value, !value.isNull else { return .null }
        try require(value.object != nil, "invalid-turn-error")
        var info = value["codexErrorInfo"] ?? .null
        if ![.null, "other", "serverOverloaded", "usageLimitExceeded"].contains(info) { info = "unsupported" }
        // A server error may contain conversation text or operational details. The
        // fixed capacity sentence is the only message needed by retry classification.
        var message = (value["message"]?.string ?? "").trimmingCharacters(in: pythonWhitespace)
        while message.hasSuffix(".") { message.removeLast() }
        let capacity = value["message"]?.string != nil && message == capacityMessage
        return ["codexErrorInfo": info, "message": .string(capacity ? capacityMessage : "")]
    }

    /// Does not send when Desktop would inherit a different saved selection.
    static func inheritanceMatches(_ state: JSON, model: String, effort: JSON) -> Bool {
        let saved = state["latestThreadSettings"] ?? [:]
        let currentCollaboration = state["latestCollaborationMode"] ?? .null
        let savedModel = saved["model"] ?? .null
        if !savedModel.isNull && savedModel != .string(model) { return false }
        var inheritedModel = savedModel.isNull ? (state["latestModel"] ?? .null) : savedModel
        let inheritedEffort = saved["effort"] ?? (state["latestReasoningEffort"] ?? .null)
        if inheritedEffort != effort { return false }
        var collaboration = saved["collaborationMode"] ?? .null
        if collaboration.isNull { collaboration = currentCollaboration }
        if collaboration != currentCollaboration { return false }
        if !collaboration.isNull {
            guard collaboration.object != nil else { return false }
            let settings = collaboration["settings"] ?? .null
            if !settings.isNull {
                guard settings.object != nil else { return false }
                if let value = settings["model"], !value.isNull { inheritedModel = value }
                // There is no verified null fallback for this collaboration field.
                if let value = settings["reasoning_effort"], value != effort { return false }
            }
        }
        if inheritedModel != .string(model) { return false }
        if let permissions = state["currentPermissions"]?.object {
            for name in ["approvalPolicy", "sandboxPolicy"] {
                if let savedValue = saved[name], let current = permissions[name], savedValue != current { return false }
            }
        }
        return true
    }

    /// Validates a full, targeted version 11 snapshot without returning its transcript.
    ///
    /// Completion times come from a separately matched persisted turn summary.
    /// Desktop's start-time-plus-duration estimate is deliberately not exported.
    static func normalize(_ envelope: JSON, conversationID: String, ownerID: String, clientID: String,
                          modelSettings: JSON) throws -> DesktopView {
        try require([conversationID, ownerID, clientID].allSatisfy { text(.string($0)) }, "invalid-binding")
        try require(envelope.object != nil, "invalid-envelope")
        try require(envelope["type"] == "broadcast" && envelope["method"] == "thread-stream-state-changed"
                    && envelope["version"] == .int(11), "unsupported-envelope")
        let targets = envelope["targetClientIds"]?.array
        try require(envelope["sourceClientId"] == .string(ownerID) && targets != nil
                    && targets!.allSatisfy({ text($0) }) && targets!.contains(.string(clientID)), "untrusted-binding")
        let params = envelope["params"]
        try require(params?.object != nil && params?["hostId"] == "local"
                    && params?["conversationId"] == .string(conversationID), "untrusted-conversation")
        let change = params?["change"]
        try require(change?.object != nil && change?["type"] == "snapshot", "unsupported-change")
        guard let revision = change?["revision"]?.int, revision >= 0 else { throw DesktopStateError("invalid-revision") }
        let state = change?["conversationState"] ?? .null
        try require(state.object != nil && state["id"] == .string(conversationID)
                    && state["sessionId"] == .string(conversationID) && state["hostId"] == "local", "untrusted-conversation")

        guard let settings = modelSettings["settings"], settings.object != nil else {
            throw DesktopStateError("invalid-model-settings")
        }
        let reasoning = settings["reasoningEffort"]
        try require(text(settings["model"]) && reasoning != nil && (reasoning!.isNull || text(reasoning)), "invalid-model-settings")
        try require(["resumeState", "threadSource", "mode"].allSatisfy { text(settings[$0]) }, "invalid-model-settings")
        let collaboration = state["latestCollaborationMode"] ?? .null
        try require(collaboration.isNull || collaboration.object != nil, "invalid-model-settings")
        let collaborationSettings = collaboration.isTruthy ? (collaboration["settings"] ?? .null) : .null
        try require(collaborationSettings.isNull || collaborationSettings.object != nil, "invalid-model-settings")
        var modelValue = collaborationSettings.isTruthy ? (collaborationSettings["model"] ?? .null) : .null
        if modelValue.isNull { modelValue = state["latestModel"] ?? .null }
        let effort = state["latestReasoningEffort"] ?? .null
        try require(state["latestReasoningEffort"] != nil && text(modelValue)
                    && settings["model"] == modelValue && settings["reasoningEffort"] == effort, "settings-mismatch")
        for name in ["resumeState", "threadSource", "mode"] {
            try require(settings[name] != nil && state[name] != nil && settings[name] == state[name], "settings-mismatch")
        }
        let model = modelValue.string!

        let threadSettings = state["latestThreadSettings"]
        let permissions = state["currentPermissions"] ?? .null
        try require(threadSettings?.object != nil && threadSettings!.isTruthy
                    && (permissions.isNull || permissions.object != nil), "invalid-model-settings")
        let fingerprintValues: JSON = [
            "settings": threadSettings!, "permissions": permissions, "collaboration": collaboration,
            "mode": settings["mode"]!, "model": .string(model), "effort": effort,
            "modelProvider": settings["modelProvider"] ?? .null,
        ]
        let encoded: String
        do { encoded = try fingerprintValues.serialized(.ascii) } catch { throw DesktopStateError("invalid-model-settings") }
        let fingerprint = SHA256.hash(data: Data(encoded.utf8)).map { String(format: "%02x", $0) }.joined()

        var reasons: [String] = []
        if !inheritanceMatches(state, model: model, effort: effort) { reasons.append("inheritance-mismatch") }
        if !(state["parentThreadId"] ?? .null).isNull || (state["ephemeral"] ?? false) != false { reasons.append("not-user-thread") }
        if state["threadSource"] != "user" { reasons.append("not-user-thread") }
        if state["resumeState"] != "resumed" { reasons.append("not-resumed") }
        for name in ["requests", "externalRequests", "unconfirmedTurnSubmissions"] {
            let value = state[name] ?? (name == "requests" ? .null : .array([]))
            if value.array.map({ !$0.isEmpty }) ?? true { reasons.append("pending-input") }
        }

        let runtime = state["threadRuntimeStatus"]
        let kind = runtime?.object != nil ? runtime?["type"]?.string : nil
        let flags: JSON = runtime?.object != nil ? (runtime?["activeFlags"] ?? (kind == "active" ? .null : .array([]))) : .array([])
        var validActive = false
        var status: JSON
        if !["idle", "systemError", "active"].contains(kind ?? "") {
            reasons.append("unknown-runtime")
            status = ["type": "unknown"]
        } else if flags.array == nil || !flags.array!.allSatisfy({ text($0) }) {
            reasons.append("unknown-runtime")
            status = ["type": "unknown"]
        } else {
            status = ["type": .string(kind!)]
            let list = flags.array!
            if kind == "active" || !list.isEmpty {
                // The core uses an explicit empty activeFlags list for healthy work.
                status["activeFlags"] = .array(list)
            }
            if !list.isEmpty {
                reasons.append("pending-input")
            } else if kind == "active" {
                validActive = true
            }
        }

        var turn: JSON?
        if let latest = try latestTurn(state) {
            let turnID = latest["turnId"] ?? .null
            let turnStatus = latest["status"]?.string ?? ""
            try require(turnID.isNull || text(turnID), "invalid-turn")
            try require(["inProgress", "completed", "failed", "interrupted"].contains(turnStatus), "unsupported-turn")
            turn = ["id": turnID, "status": .string(turnStatus), "error": try error(latest["error"])]
            if turnID.isNull {
                reasons.append("unconfirmed-turn")
            } else if turnStatus == "inProgress" && kind != "active" {
                reasons.append("inconsistent-runtime")
            }
        }

        let blocked = reasons.first ?? (validActive ? "active" : nil)
        let thread: JSON = [
            "id": .string(conversationID), "source": "desktop", "originator": "codex-desktop",
            "controlBackend": "desktop-ipc", "canAcceptDirectInput": .bool(reasons.isEmpty),
            "threadSource": state["threadSource"] == "user" ? "user" : "unsupported",
            "parentThreadId": .null, "ephemeral": false,
            "model": .string(model), "reasoningEffort": effort, "status": status,
        ]
        return DesktopView(thread: thread, turn: turn, revision: revision, owner: ownerID,
                           settingsFingerprint: fingerprint, blockedReason: blocked)
    }
}
