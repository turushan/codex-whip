import Foundation

public let successSeconds: Double = 120
public let maxObservationGap: Double = 90

/// Finds capacity and quota failures in loaded sessions, waits, and continues the same session
/// with the same model. Every send is journaled first, so a crash can never send it twice.
public final class RetryEngine {
    public typealias Emit = (_ event: String, _ fields: [String: JSON]) -> Void

    public let state: RetryState
    public var interval: Double
    public var scanInterval: Double
    public var message: String
    public var maxObservationGap = WhipEngine.maxObservationGap
    public let threads: Set<String>
    private let save: (RetryState) throws -> Void
    private let emit: Emit
    private let shouldStop: () -> Bool
    private var observedAt: [String: Double] = [:]
    private(set) var retryAfter: [String: Double] = [:]

    public init(state: RetryState, save: @escaping (RetryState) throws -> Void, emit: @escaping Emit,
                interval: Int = Settings.defaults.retrySeconds, threads: [String] = [],
                shouldStop: @escaping () -> Bool = { false },
                scanInterval: Int = Settings.defaults.scanSeconds, message: String = Settings.defaultMessage) throws {
        self.state = state
        self.save = save
        self.emit = emit
        self.interval = Double(interval)
        self.threads = Set(threads)
        self.shouldStop = shouldStop
        self.scanInterval = Double(scanInterval)
        self.message = message
        // Saved timestamps are useful evidence, but downtime never contributes
        // to a new process's continuous observation window.
        try resetObservations()
    }

    public func applySettings(_ value: Settings) throws {
        var changed = false
        if Double(value.scanSeconds) != scanInterval { try resetObservations() }
        for (id, var pending) in state.pending {
            if pending.kind == "quota" {
                let checked = pending.quotaCheckedAt ?? pending.detectedAt ?? 0
                let due = checked + Double(value.scanSeconds)
                if due != pending.dueAt {
                    pending.dueAt = due
                    changed = true
                }
                state.pending[id] = pending
                continue
            }
            if pending.waitStartedAt == nil {
                pending.waitStartedAt = pending.dueAt - interval
                changed = true
            }
            let due = pending.waitStartedAt! + Double(value.retrySeconds)
            if due != pending.dueAt {
                pending.dueAt = due
                changed = true
            }
            state.pending[id] = pending
        }
        interval = Double(value.retrySeconds)
        scanInterval = Double(value.scanSeconds)
        message = value.message
        maxObservationGap = WhipEngine.maxObservationGap
        if changed { try save(state) }
    }

    /// Known retry deadlines and health observations do not wait for discovery.
    public func maintenanceDue(_ now: Double) -> Bool {
        for (id, pending) in state.pending where pending.dueAt <= now && (retryAfter[id] ?? 0) <= now {
            return true
        }
        let observation = min(30, scanInterval)
        return state.handled.contains { id, attempt in
            attempt.awaitingResult
                && max((observedAt[id] ?? attempt.at ?? now) + observation, retryAfter[id] ?? 0) <= now
        }
    }

    public func step(_ rpc: RPCClient, now: Double, discover: Bool = true) throws {
        do {
            try performStep(rpc, now: now, discover: discover)
        } catch {
            try? resetObservations()
            throw error
        }
    }

    private func performStep(_ rpc: RPCClient, now: Double, discover: Bool) throws {
        let loaded = Set(try loadedThreads(rpc))
        let allowed = threads.isEmpty ? loaded : loaded.intersection(threads)
        let tracked = Set(state.handled.filter { $0.value.awaitingResult }.keys)
        let targets = discover ? allowed : allowed.intersection(Set(state.pending.keys).union(tracked))
        var quotaCandidates: [(id: String, newWait: Bool)] = []
        var counts = SessionCounts()
        for id in state.handled.keys where !allowed.contains(id) || state.paused[id] != nil {
            try resetObservations(id)
        }
        for id in Array(state.pending.keys) where !allowed.contains(id) || state.paused[id] != nil {
            try cancel(id, reason: "session unloaded or paused")
        }
        for id in targets.sorted() {
            if shouldStop() { return }
            if state.paused[id] != nil { continue }
            let thread: JSON, turn: JSON?
            do {
                (thread, turn) = try snapshot(rpc, id)
                try observeResult(rpc, id, latestTurn: turn, now: now, thread: thread)
            } catch let error as RPCError where error.isRequest {
                try resetObservations(id)
                retryAfter[id] = now + min(30, scanInterval)
                counts.unavailable += 1
                emit("thread_unavailable", ["thread_id": .string(id), "message": .string(error.description)])
                continue
            }
            if watchable(thread) {
                counts.total += 1
                switch thread["status"]?["type"]?.string {
                case "active": counts.active += 1
                case "idle": counts.idle += 1
                case "systemError": counts.errored += 1
                default: counts.other += 1
                }
            }
            var pending = state.pending[id]
            let kind = failureKind(turn)
            guard eligible(thread), let kind, let turn else {
                if pending != nil { try cancel(id, reason: "session changed or recovered") }
                continue
            }
            guard let turnID = turn["id"]?.string else { throw RPCError.transport("thread/turns/list: turn has no id") }
            guard let completed = turn["completedAt"]?.number, completed.isFinite, completed >= state.enabledAt else {
                if pending != nil { try cancel(id, reason: "failure timestamp is unavailable or predates activation") }
                continue
            }
            if state.handled[id]?.turnID == turnID { continue }
            if let current = pending, current.turnID != turnID {
                try cancel(id, reason: "a newer turn replaced the failure")
                pending = nil
            }
            if let current = pending, current.resolvedKind != kind {
                try cancel(id, reason: "failure classification changed")
                continue
            }
            if let current = pending, current.model != thread["model"]?.string
                || current.effort != thread["reasoningEffort"]?.string {
                try cancel(id, reason: "selected model or session settings changed")
                continue
            }
            if pending == nil {
                let start = max(now, completed)
                var created = Pending(turnID: turnID, model: thread["model"]?.string ?? "",
                                      effort: thread["reasoningEffort"]?.string, detectedAt: now, waitStartedAt: start,
                                      dueAt: start + (kind == "quota" ? scanInterval : interval))
                if kind == "quota" {
                    created.kind = "quota"
                    created.quotaStatus = "unknown"
                }
                state.pending[id] = created
                pending = created
                try save(state)
                emit(kind == "quota" ? "quota_waiting" : "waiting",
                     created.eventFields.merging(["thread_id": .string(id)]) { _, new in new })
                if kind == "quota" { quotaCandidates.append((id, true)) }
            }
            guard let current = pending else { continue }
            if kind == "quota" {
                if now >= current.dueAt && (retryAfter[id] ?? 0) <= now { quotaCandidates.append((id, false)) }
                continue
            }
            if now < current.dueAt { continue }
            try sendRetry(rpc, id, current, now: now)
        }
        if !quotaCandidates.isEmpty && !shouldStop() {
            try checkQuota(rpc, quotaCandidates, now: now)
        }
        for id in Array(state.handled.keys) {
            if shouldStop() { return }
            guard let attempt = state.handled[id], attempt.awaitingResult else { continue }
            if (attempt.at ?? now) < now - History.retentionSeconds {
                state.handled[id]?.resultStatus = "unknown"
                try save(state)
                continue
            }
            if allowed.contains(id) { continue }
            // Finished CLI sessions may unload before the next scan. Their
            // persisted turns still provide outcomes without resuming any work.
            do {
                try observeResult(rpc, id, latestTurn: nil, now: now)
            } catch let error as RPCError where error.isRequest {
                try resetObservations(id)
                emit("thread_unavailable", ["thread_id": .string(id), "message": .string(error.description)])
            }
        }
        if discover { state.sessions = counts.json }
    }

    private func checkQuota(_ rpc: RPCClient, _ candidates: [(id: String, newWait: Bool)], now: Double) throws {
        // One fresh snapshot serves the eligible quota waits due in this batch.
        // Nothing from this response is emitted or logged.
        let binding: String?, permission: Bool?
        do {
            (binding, permission) = try quotaSnapshot(rpc)
        } catch let error as RPCError where error.isRequest {
            (binding, permission) = (nil, nil)
        } catch is RPCError {
            try deferQuota(candidates, now: now)
            throw RPCError.transport("Codex quota status could not be read.")
        }
        for (id, newWait) in candidates {
            if shouldStop() { return }
            guard var pending = state.pending[id], pending.kind == "quota" else { continue }
            let previous = pending.accountBinding
            pending.quotaCheckedAt = now
            pending.dueAt = now + scanInterval
            if binding == nil || permission == nil {
                pending.quotaStatus = "unknown"
            } else if previous != nil && previous != binding {
                pending.quotaStatus = "account_changed"
            } else {
                pending.quotaStatus = "waiting"
            }
            if previous == nil && binding != nil { pending.accountBinding = binding }
            state.pending[id] = pending
            try save(state)
            // First observation binds the account. Only a subsequent fresh read
            // for that same identity can authorize a continuation attempt.
            if !newWait && previous != nil && previous == binding && permission == true {
                try sendRetry(rpc, id, pending, now: now)
            }
        }
    }

    private func deferQuota(_ candidates: [(id: String, newWait: Bool)], now: Double) throws {
        for (id, _) in candidates where state.pending[id]?.kind == "quota" {
            state.pending[id]?.quotaCheckedAt = now
            state.pending[id]?.dueAt = now + scanInterval
            state.pending[id]?.quotaStatus = "unknown"
        }
        try save(state)
    }

    private func unchanged(_ thread: JSON, _ turn: JSON?, _ pending: Pending, kind: String) -> Bool {
        eligible(thread) && failureKind(turn) == kind && turn?["id"]?.string == pending.turnID
            && thread["model"]?.string == pending.model && thread["reasoningEffort"]?.string == pending.effort
    }

    private func sendRetry(_ rpc: RPCClient, _ id: String, _ given: Pending, now: Double) throws {
        var pending = given
        let kind = pending.resolvedKind
        var latest: (thread: JSON, turn: JSON?)
        do {
            latest = try snapshot(rpc, id, verify: true)
        } catch let error as RPCError where error.isRequest {
            retryAfter[id] = now + min(30, scanInterval)
            emit("thread_unavailable", ["thread_id": .string(id), "message": .string(error.description)])
            return
        }
        guard unchanged(latest.thread, latest.turn, pending, kind: kind) else {
            try cancel(id, reason: "session changed before retry")
            return
        }
        if kind == "quota" {
            // Another session or a manual login can change the active account
            // after the batch poll. Revalidate separately for each continuation.
            let binding: String?, permission: Bool?
            do {
                (binding, permission) = try quotaSnapshot(rpc)
            } catch let error as RPCError where error.isRequest {
                (binding, permission) = (nil, nil)
            } catch is RPCError {
                state.pending[id]?.quotaStatus = "unknown"
                try save(state)
                throw RPCError.transport("Codex quota status could not be read.")
            }
            if binding == nil || permission == nil {
                pending.quotaStatus = "unknown"
            } else if binding != pending.accountBinding {
                pending.quotaStatus = "account_changed"
            } else {
                pending.quotaStatus = "waiting"
            }
            state.pending[id] = pending
            try save(state)
            if permission != true || binding == nil || binding != pending.accountBinding { return }
            // The quota read can take time. Check the latest turn and runtime
            // again afterward, leaving runtime status as the final RPC read.
            do {
                latest = try snapshot(rpc, id, verify: true)
            } catch let error as RPCError where error.isRequest {
                retryAfter[id] = now + min(30, scanInterval)
                emit("thread_unavailable", ["thread_id": .string(id), "message": .string(error.description)])
                return
            }
            guard unchanged(latest.thread, latest.turn, pending, kind: kind) else {
                try cancel(id, reason: "session changed before retry")
                return
            }
        }
        if shouldStop() { return }
        // Commit before sending. A crash or disconnect must never cause a duplicate.
        var attempt = Attempt(turnID: pending.turnID, at: now, outcome: "uncertain", kind: kind)
        if kind == "quota" { attempt.quotaAt = pending.detectedAt ?? now } else { attempt.capacityAt = pending.detectedAt ?? now }
        state.handled[id] = attempt
        state.pending[id] = nil
        try save(state)
        if shouldStop() { return }
        let result: JSON
        do {
            result = try rpc.call("turn/start", ["threadId": .string(id), "input": [["type": "text", "text": .string(message)]]])
        } catch {
            emit("uncertain", ["thread_id": .string(id), "turn_id": .string(attempt.turnID), "kind": .string(kind)])
            throw error
        }
        guard let retryTurnID = result["turn"]?["id"]?.string else {
            emit("uncertain", ["thread_id": .string(id), "turn_id": .string(attempt.turnID), "kind": .string(kind)])
            throw RPCError.transport("turn/start: response has no turn id")
        }
        attempt.outcome = "submitted"
        attempt.retryTurnID = retryTurnID
        state.handled[id] = attempt
        try save(state)
        var fields = attempt.json.object ?? [:]
        fields["thread_id"] = .string(id)
        fields["model"] = .string(pending.model)
        emit("retry", fields)
    }

    public func resetObservations(_ id: String? = nil) throws {
        var changed = false
        for key in id.map({ [$0] }) ?? Array(state.handled.keys) {
            guard var attempt = state.handled[key], attempt.healthySince != nil || attempt.healthyLastSeen != nil else { continue }
            attempt.healthySince = nil
            attempt.healthyLastSeen = nil
            state.handled[key] = attempt
            changed = true
        }
        if changed { try save(state) }
    }

    private func observeResult(_ rpc: RPCClient, _ id: String, latestTurn: JSON?, now: Double, thread: JSON? = nil) throws {
        guard var attempt = state.handled[id], attempt.outcome == "submitted",
              let retryID = attempt.retryTurnID, !retryID.isEmpty, (attempt.resultStatus ?? "").isEmpty else { return }
        observedAt[id] = now
        var turn = latestTurn?["id"]?.string == retryID ? latestTurn : nil
        var isLatest = turn != nil
        if turn == nil {
            // A user may already have started another turn. Look up the retry's
            // own outcome instead of treating the user's newer turn as its result.
            let recent = try rpc.call("thread/turns/list", [
                "threadId": .string(id), "limit": 20, "sortDirection": "desc", "itemsView": "notLoaded",
            ]).required("data", "thread/turns/list").array ?? []
            turn = recent.first { $0["id"]?.string == retryID }
            isLatest = recent.first?["id"]?.string == retryID
        }
        if let turn, let status = turn["status"]?.string, ["completed", "failed", "interrupted"].contains(status) {
            try finishResult(id, &attempt, status: status == "completed" ? "successful" : status,
                             capacity: isCapacity(turn), occurredAt: turn["completedAt"]?.number ?? now)
            return
        }
        let runtime = thread?["status"]
        let healthy = thread.map(watchable) == true && isLatest && turn != nil
            && turn?["status"]?.string == "inProgress" && !(turn?["error"]?.isTruthy ?? false)
            && runtime?["type"]?.string == "active" && runtime?["activeFlags"] == .array([])
        guard healthy else {
            try resetObservations(id)
            return
        }
        if let previous = attempt.healthyLastSeen, now >= previous, now - previous <= maxObservationGap,
           attempt.healthySince != nil {
            // The observation window continues.
        } else {
            attempt.healthySince = now
        }
        attempt.healthyLastSeen = now
        if now - attempt.healthySince! >= successSeconds {
            try finishResult(id, &attempt, status: "successful", capacity: false, occurredAt: now)
        } else {
            state.handled[id] = attempt
            try save(state)
        }
    }

    private func finishResult(_ id: String, _ attempt: inout Attempt, status: String, capacity: Bool, occurredAt: Double) throws {
        attempt.resultStatus = status
        attempt.resultAt = occurredAt
        attempt.resultCapacity = capacity
        attempt.healthySince = nil
        attempt.healthyLastSeen = nil
        state.handled[id] = attempt
        // Save the latch first. Reconciliation recreates a missed history event
        // after a crash without reclassifying an already successful retry.
        try save(state)
        emit("retry_result", ["thread_id": .string(id), "turn_id": JSON(attempt.retryTurnID), "status": .string(status),
                              "capacity": .bool(capacity), "occurred_at": .double(occurredAt),
                              "kind": .string(attempt.resolvedKind)])
    }

    private func cancel(_ id: String, reason: String) throws {
        guard let pending = state.pending.removeValue(forKey: id) else { return }
        // Do not rearm the same old failure after a model change or unload.
        state.handled[id] = Attempt(turnID: pending.turnID, outcome: "cancelled", kind: pending.resolvedKind, reason: reason)
        try save(state)
        emit("cancelled", ["thread_id": .string(id), "reason": .string(reason)])
    }
}

/// Rebuilds history events from durable state, if the process stopped between its state save
/// and its history write. SQLite deduplication keeps the counts stable.
public func reconcileHistory(_ state: RetryState, _ history: History, now: Double) throws {
    for (id, pending) in state.pending {
        let kind = pending.resolvedKind
        let detected = pending.detectedAt ?? pending.dueAt - Double(Settings.defaults.retrySeconds)
        try history.record(kind == "quota" ? "quota_waiting" : "waiting",
                           ["thread_id": .string(id), "turn_id": .string(pending.turnID),
                            "occurred_at": .double(detected), "kind": .string(kind)])
    }
    for (id, attempt) in state.handled {
        if let at = attempt.at, at >= now - History.retentionSeconds {
            if let capacityAt = attempt.capacityAt {
                try history.record("waiting", ["thread_id": .string(id), "turn_id": .string(attempt.turnID),
                                               "occurred_at": .double(capacityAt)])
            }
            if let quotaAt = attempt.quotaAt {
                try history.record("quota_waiting", ["thread_id": .string(id), "turn_id": .string(attempt.turnID),
                                                     "occurred_at": .double(quotaAt), "kind": "quota"])
            }
            var fields = attempt.json.object ?? [:]
            fields["thread_id"] = .string(id)
            fields["occurred_at"] = .double(at)
            if attempt.outcome == "submitted", !(attempt.retryTurnID ?? "").isEmpty {
                try history.record("retry", fields)
            } else if attempt.outcome == "uncertain" {
                try history.record("uncertain", fields)
            }
        }
        if let status = attempt.resultStatus, ["successful", "completed", "failed", "interrupted"].contains(status),
           let retryTurnID = attempt.retryTurnID, !retryTurnID.isEmpty, let resultAt = attempt.resultAt {
            try history.record("retry_result", ["thread_id": .string(id), "turn_id": .string(retryTurnID),
                                                "status": .string(status), "capacity": .bool(attempt.resultCapacity ?? false),
                                                "occurred_at": .double(resultAt), "kind": .string(attempt.resolvedKind)])
        }
    }
}
