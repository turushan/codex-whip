import Foundation
import Testing
@testable import WhipEngine

// Port of tests/test_desktop_backend.py.
//
// The Python suite fakes the Desktop IPC object itself. DesktopIPC is a final class, so these
// tests substitute it one level lower: `DesktopPeerStub` is a local Unix-socket protocol stub
// that speaks Desktop's framing to a real DesktopIPC built by DesktopRPC's `makeIPC` factory.
// Every connection gets a fresh client ID, exactly like the Python `DesktopPeer.__call__`.

// MARK: - Shared stubs (also used by DesktopRunnerTests and DesktopSocketRetryTests)

extension JSON {
    /// Nested object access for fixtures; missing intermediate objects are created on set.
    subscript(backendPath path: [String]) -> JSON? {
        get {
            var value: JSON? = self
            for key in path { value = value?[key] }
            return value
        }
        set {
            guard let first = path.first else { return }
            if path.count == 1 {
                self[first] = newValue
                return
            }
            var child = self[first] ?? .object([:])
            child[backendPath: Array(path.dropFirst())] = newValue
            self[first] = child
        }
    }
}

/// tests/test_desktop_state.py `fixture()`.
func desktopBackendFixture() -> (envelope: JSON, settings: JSON) {
    let turn: JSON = [
        "turnId": "failed-turn", "status": "failed",
        "error": ["codexErrorInfo": "serverOverloaded", "message": .string(capacityMessage + ".")],
        "turnStartedAtMs": 1780000000000, "durationMs": 1000,
        "params": ["input": [["type": "text", "text": "private prompt"]]],
        "items": [["type": "agentMessage", "text": "private response"]],
    ]
    let state: JSON = [
        "id": "thread", "sessionId": "thread", "hostId": "local",
        "threadSource": "user", "parentThreadId": nil, "ephemeral": false,
        "mode": "default", "resumeState": "resumed", "threadRuntimeStatus": ["type": "systemError"],
        "latestModel": "model", "latestReasoningEffort": "high",
        "latestCollaborationMode": ["mode": "default", "settings": ["model": "model"]],
        "latestThreadSettings": ["model": "model", "effort": "high", "serviceTier": nil],
        "currentPermissions": ["approvalPolicy": "on-request", "sandboxPolicy": ["type": "workspaceWrite"]],
        "requests": [], "externalRequests": [], "unconfirmedTurnSubmissions": [], "turns": [],
        "turnHistory": ["kind": "canonical", "history": [
            "isComplete": true, "entitiesByKey": ["turn:failed-turn": turn],
            "islands": [["id": "latest", "entries": [["key": "entry", "value": "turn:failed-turn"]],
                         "olderBoundary": ["status": "exhausted"], "newerBoundary": ["status": "exhausted"]]],
        ]],
    ]
    let envelope: JSON = [
        "type": "broadcast", "method": "thread-stream-state-changed", "version": 11,
        "sourceClientId": "owner", "targetClientIds": ["client"], "params": [
            "hostId": "local", "conversationId": "thread", "change": [
                "type": "snapshot", "revision": 7, "conversationState": state]]]
    let settings: JSON = ["settings": ["model": "model", "reasoningEffort": "high", "resumeState": "resumed",
                                       "mode": "default", "threadSource": "user", "modelProvider": "openai"]]
    return (envelope, settings)
}

struct BackendTestError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// tests/test_desktop_backend.py `MetadataPeer`: the shared app-server connection, which may
/// only list persisted turns.
final class MetadataPeerStub: RPCClient, @unchecked Sendable {
    var calls: [(method: String, params: JSON)] = []
    var turns: [JSON] = [["id": "failed-turn", "status": "failed", "completedAt": 1100,
                          "error": ["codexErrorInfo": "serverOverloaded", "message": .string(capacityMessage)]]]
    var error: Error?
    var unexpected: [String] = []
    /// Runs after a successful read, standing in for Python's replaced `metadata.call`.
    var afterRead: (() -> Void)?
    var shouldStop: () -> Bool = { false }

    func call(_ method: String, _ params: JSON) throws -> JSON {
        calls.append((method, params))
        guard method == "thread/turns/list" else {
            unexpected.append(method)
            throw BackendTestError("Metadata must never start, resume, or authorize a turn")
        }
        if let error { throw error }
        let limit = params["limit"]?.int ?? 0
        let result: JSON = ["data": .array(Array(turns.prefix(limit))), "nextCursor": nil]
        afterRead?()
        return result
    }
}

/// One accepted client binding, as seen by the stub.
final class StubConnection: @unchecked Sendable {
    let clientID: String
    private let lock = NSLock()
    private var _closed = false
    private var _follows: [Bool] = []
    private var _calls: [String] = []

    init(clientID: String) { self.clientID = clientID }

    var closed: Bool { lock.withLock { _closed } }
    var follows: [Bool] { lock.withLock { _follows } }
    var calls: [String] { lock.withLock { _calls } }
    func markClosed() { lock.withLock { _closed = true } }
    func follow(_ value: Bool) { lock.withLock { _follows.append(value) } }
    func record(_ method: String) { lock.withLock { _calls.append(method) } }
}

/// tests/test_desktop_backend.py `DesktopPeer` and `DesktopConnection`, served over a real
/// temporary Unix socket so DesktopRPC talks to it through DesktopIPC's framing.
final class DesktopPeerStub: @unchecked Sendable {
    static let statePath = ["params", "change", "conversationState"]
    static let turnPath = statePath + ["turnHistory", "history", "entitiesByKey", "turn:failed-turn"]

    var snapshot: JSON
    var model: JSON
    var owner = "owner"
    var ownerError: String?
    var ownerResult: JSON = ["supportsUntrustedAppInput": true]
    var startError: String?
    var ack: JSON = ["result": ["turn": ["id": "retry-turn", "status": "inProgress"]]]
    var starts: [(params: JSON, options: JSON)] = []
    var beforeStart: ((JSON) -> Void)?
    var beforeSnapshot: (() -> Void)?
    /// Frames are written in small pieces with short pauses, like test_desktop_ipc's `fragmented`.
    var fragmented = false
    var clientPrefix = "client-"

    let path: URL
    private let directory: URL
    private let lock = NSLock()
    private var listener: Int32 = -1
    private var finished = false
    private var _connections: [StubConnection] = []
    private var _failures: [String] = []
    private var descriptors: [Int32] = []
    private let acceptDone = DispatchSemaphore(value: 0)

    init() throws {
        (snapshot, model) = desktopBackendFixture()
        // Unix socket paths are limited to 104 bytes, so the stub lives directly under /tmp.
        var template = Array("/tmp/whip-desktop-XXXXXX".utf8CString)
        guard let made = mkdtemp(&template) else { throw BackendTestError("mkdtemp failed") }
        directory = URL(fileURLWithPath: String(cString: made))
        path = directory.appendingPathComponent("ipc.sock")
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw BackendTestError("socket failed") }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.path.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(listener, 8) == 0 else { throw BackendTestError("bind failed") }
        let thread = Thread { [unowned self] in self.acceptLoop() }
        thread.start()
    }

    deinit { stop() }

    var connections: [StubConnection] { lock.withLock { _connections } }
    var failures: [String] { lock.withLock { _failures } }

    /// The factory DesktopRPC uses in place of `DesktopIPC(path:timeout:shouldStop:)`. Like the
    /// Python peer, it ignores the requested path.
    var factory: DesktopRPC.IPCFactory {
        { [path] _, timeout, shouldStop in try DesktopIPC(path: path, timeout: timeout, shouldStop: shouldStop) }
    }

    func stop() {
        let alreadyFinished = lock.withLock { () -> Bool in
            let was = finished
            finished = true
            return was
        }
        if alreadyFinished { return }
        _ = acceptDone.wait(timeout: .now() + 3)
        Darwin.close(listener)
        lock.withLock { descriptors.forEach { shutdown($0, SHUT_RDWR) } }
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: Fixture mutations

    var state: JSON {
        get { snapshot[backendPath: DesktopPeerStub.statePath] ?? .null }
        set { snapshot[backendPath: DesktopPeerStub.statePath] = newValue }
    }

    var turn: JSON {
        get { snapshot[backendPath: DesktopPeerStub.turnPath] ?? .null }
        set { snapshot[backendPath: DesktopPeerStub.turnPath] = newValue }
    }

    func setModel(_ value: String) {
        state["latestModel"] = .string(value)
        state[backendPath: ["latestCollaborationMode", "settings", "model"]] = .string(value)
        state[backendPath: ["latestThreadSettings", "model"]] = .string(value)
        model[backendPath: ["settings", "model"]] = .string(value)
    }

    func setTurn(_ id: String?, _ status: String, error: JSON = nil) {
        turn["turnId"] = JSON(id)
        turn["status"] = .string(status)
        turn["error"] = error
    }

    /// Waits for the client to finish its unfollow broadcast and close, then checks
    /// tests/test_desktop_backend.py `assert_clean_connections`.
    func cleanConnections() -> Bool {
        let deadline = Date().addingTimeInterval(3)
        while connections.contains(where: { !$0.closed }) && Date() < deadline { usleep(5_000) }
        return connections.allSatisfy { $0.closed && ($0.follows.isEmpty || $0.follows == [true, false]) }
            && failures.isEmpty
    }

    // MARK: Server

    private func fail(_ message: String) { lock.withLock { _failures.append(message) } }

    private func acceptLoop() {
        defer { acceptDone.signal() }
        var sequence = 0
        while !lock.withLock({ finished }) {
            var entry = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            guard poll(&entry, 1, 50) > 0 else { continue }
            let descriptor = accept(listener, nil, nil)
            guard descriptor >= 0 else { continue }
            var noSigPipe: Int32 = 1
            setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) & ~O_NONBLOCK)
            sequence += 1
            let connection = StubConnection(clientID: clientPrefix + String(sequence))
            lock.withLock {
                _connections.append(connection)
                descriptors.append(descriptor)
            }
            let worker = Thread { [self] in
                self.serve(descriptor, connection)
                connection.markClosed()
                // Forget the descriptor before closing it, so stop() never shuts down a reused number.
                self.lock.withLock { self.descriptors.removeAll { $0 == descriptor } }
                Darwin.close(descriptor)
            }
            worker.start()
        }
    }

    private static func readExact(_ descriptor: Int32, _ size: Int) -> [UInt8]? {
        var data = [UInt8]()
        var chunk = [UInt8](repeating: 0, count: max(1, min(size, 65536)))
        while data.count < size {
            let wanted = min(size - data.count, chunk.count)
            let count = chunk.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress!, wanted) }
            if count > 0 { data += chunk[..<count]; continue }
            if count < 0 && errno == EINTR { continue }
            return nil
        }
        return data
    }

    static func readMessage(_ descriptor: Int32) -> JSON? {
        guard let header = readExact(descriptor, 4) else { return nil }
        let size = Int(header[0]) | Int(header[1]) << 8 | Int(header[2]) << 16 | Int(header[3]) << 24
        guard let body = readExact(descriptor, size) else { return nil }
        return try? JSON.parse(Data(body))
    }

    static func writeMessage(_ descriptor: Int32, _ message: JSON, fragmented: Bool) {
        guard let text = try? message.serialized(JSON.Format(sortKeys: false)) else { return }
        let payload = Array(text.utf8)
        let length = UInt32(payload.count)
        let frame = [UInt8(length & 0xFF), UInt8((length >> 8) & 0xFF), UInt8((length >> 16) & 0xFF),
                     UInt8(length >> 24)] + payload
        let pieces = fragmented ? [(0, 1), (1, 3), (3, 7), (7, 11), (11, frame.count)] : [(0, frame.count)]
        for (start, end) in pieces {
            var offset = start
            while offset < end {
                let written = frame.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress! + offset, end - offset) }
                if written > 0 { offset += written; continue }
                if written < 0 && errno == EINTR { continue }
                return
            }
            if fragmented { usleep(2_000) }
        }
    }

    static func success(_ request: JSON, _ result: JSON, owner: String) -> JSON {
        ["type": "response", "requestId": request["requestId"] ?? nil, "resultType": "success",
         "method": request["method"] ?? nil, "handledByClientId": .string(owner), "result": result]
    }

    static func failure(_ request: JSON, _ code: String) -> JSON {
        ["type": "response", "requestId": request["requestId"] ?? nil, "resultType": "error", "error": .string(code)]
    }

    private func serve(_ descriptor: Int32, _ connection: StubConnection) {
        let client = connection.clientID
        guard let initialize = DesktopPeerStub.readMessage(descriptor), initialize["method"] == "initialize" else {
            fail("The client must initialize first")
            return
        }
        DesktopPeerStub.writeMessage(descriptor, DesktopPeerStub.success(initialize, ["clientId": .string(client)],
                                                                         owner: client), fragmented: fragmented)
        while let message = DesktopPeerStub.readMessage(descriptor) {
            let method = message["method"]?.string ?? ""
            let params = message["params"] ?? [:]
            connection.record(method)
            let reply: JSON?
            if message["type"] == "broadcast" {
                guard method == "thread-stream-following-changed" else {
                    fail("Unexpected Desktop broadcast \(method)")
                    continue
                }
                let following = params["following"] == true
                connection.follow(following)
                if following {
                    beforeSnapshot?()
                    var envelope = snapshot
                    envelope["sourceClientId"] = .string(owner)
                    envelope["targetClientIds"] = [.string(client)]
                    reply = envelope
                } else {
                    reply = nil
                }
            } else if method == "thread-owner-discovery" {
                if let ownerError {
                    reply = DesktopPeerStub.failure(message, ownerError)
                } else {
                    reply = DesktopPeerStub.success(message, ownerResult, owner: owner)
                }
            } else if message["targetClientId"]?.string != owner {
                fail("Desktop requests must target the discovered owner")
                reply = DesktopPeerStub.failure(message, "request-failed")
            } else if method == "thread-follower-read-model-settings" {
                reply = DesktopPeerStub.success(message, model, owner: owner)
            } else if method == "thread-follower-start-turn" {
                let timeout = message["timeoutMs"]?.int.map { JSON.double(Double($0) / 1000) } ?? nil
                starts.append((params, ["version": message["version"] ?? nil,
                                        "target": message["targetClientId"] ?? nil, "timeout": timeout]))
                beforeStart?(params)
                if let startError {
                    reply = DesktopPeerStub.failure(message, startError)
                } else {
                    reply = DesktopPeerStub.success(message, ack, owner: owner)
                }
            } else {
                fail("Unexpected Desktop request \(method)")
                reply = DesktopPeerStub.failure(message, "method-not-found")
            }
            if let reply { DesktopPeerStub.writeMessage(descriptor, reply, fragmented: fragmented) }
        }
    }
}

/// Returns the thrown RPCError, if any.
func backendRPCError(_ body: () throws -> Void) -> RPCError? {
    do {
        try body()
        return nil
    } catch let error as RPCError {
        return error
    } catch {
        return nil
    }
}

// MARK: - Tests

/// tests/test_desktop_backend.py `DesktopBackendTests.setUp`.
final class BackendHarness {
    let metadata = MetadataPeerStub()
    let desktop: DesktopPeerStub
    let backend: DesktopRPC
    var state = RetryState(enabledAt: 1000)
    var saved: [JSON] = []
    var events: [(event: String, fields: [String: JSON])] = []
    var onWriteAhead: (() -> Void)?
    var engine: RetryEngine!

    init() throws {
        desktop = try DesktopPeerStub()
        backend = try DesktopRPC(socketPath: URL(fileURLWithPath: "unused.sock"), metadata: metadata,
                                 threadIDs: ["thread"], makeIPC: desktop.factory)
        engine = try newEngine()
    }

    deinit { desktop.stop() }

    func newEngine() throws -> RetryEngine {
        try RetryEngine(state: state, save: { [unowned self] in self.save($0) },
                        emit: { [unowned self] event, fields in self.events.append((event, fields)) },
                        interval: 180, threads: ["thread"], scanInterval: 300)
    }

    func save(_ value: RetryState) {
        let document = value.json
        saved.append(document)
        if document[backendPath: ["handled", "thread", "outcome"]] == "uncertain", let callback = onWriteAhead {
            onWriteAhead = nil
            callback()
        }
    }

    func arm() throws { try engine.step(backend, now: 1100) }
    func due() throws { try engine.step(backend, now: 1280) }
    func count(_ name: String) -> Int { events.filter { $0.event == name }.count }
}

@Suite struct DesktopBackendTests {
    // test_confirmed_retry_uses_owner_v2_saved_correlation_and_only_inherited_settings
    @Test func confirmedRetryUsesOwnerV2SavedCorrelationAndOnlyInheritedSettings() throws {
        let h = try BackendHarness()
        var observed: (outcome: JSON?, saved: JSON?, sent: JSON?, pendingHasThread: Bool)?
        h.desktop.beforeStart = { params in
            let last = h.saved.last
            observed = (last?[backendPath: ["handled", "thread", "outcome"]],
                        last?[backendPath: ["handled", "thread", "client_message_id"]],
                        params[backendPath: ["turnStart", "request", "clientUserMessageId"]],
                        last?[backendPath: ["pending", "thread"]] != nil)
        }
        try h.arm()
        try h.engine.step(h.backend, now: 1279)
        #expect(h.desktop.starts.isEmpty)
        try h.due()
        #expect(h.desktop.starts.count == 1)
        let check = try #require(observed)
        #expect(check.outcome == "uncertain")
        #expect(check.saved == check.sent)
        let messageID = try #require(check.saved?.string)
        #expect(UUID(uuidString: messageID)?.uuidString.lowercased() == messageID)
        #expect(!check.pendingHasThread)
        let (params, options) = h.desktop.starts[0]
        #expect(options == ["version": 2, "target": "owner", "timeout": 10.0])
        let request = try #require(params[backendPath: ["turnStart", "request"]]?.object)
        #expect(Set(request.keys) == ["threadId", "input", "clientUserMessageId"])
        #expect(request["threadId"] == "thread")
        #expect(request["input"] == [["type": "text", "text": .string(Settings.defaultMessage), "text_elements": []]])
        #expect(params[backendPath: ["turnStart", "context"]] == ["inheritThreadSettings": true])
        #expect(h.state.handled["thread"]?.outcome == "submitted")
        #expect(h.state.handled["thread"]?.retryTurnID == "retry-turn")
        #expect(h.count("retry") == 1)
        #expect(!h.metadata.calls.isEmpty)
        #expect(h.metadata.calls.allSatisfy { $0.method == "thread/turns/list" && $0.params["itemsView"] == "notLoaded" })
        #expect(h.desktop.cleanConnections())
    }

    // test_persisted_completion_time_is_required_and_never_derived_from_desktop_duration
    @Test func persistedCompletionTimeIsRequiredAndNeverDerivedFromDesktopDuration() throws {
        let h = try BackendHarness()
        let result = try h.backend.call("thread/turns/list", ["threadId": "thread"])
        #expect(result["data"]?.array?.first?["completedAt"] == 1100)
        let values: [JSON] = [nil, true, .double(.nan), .double(.infinity), "1100", -1]
        for value in values {
            h.metadata.turns[0]["completedAt"] = value
            h.state = RetryState(enabledAt: 1000)
            h.engine = try h.newEngine()
            try h.arm()
            try h.engine.step(h.backend, now: 100000)
            #expect(h.state.pending.isEmpty, "completedAt \(value)")
            #expect(h.desktop.starts.isEmpty, "completedAt \(value)")
        }
    }

    // test_failures_before_activation_are_not_retried
    @Test func failuresBeforeActivationAreNotRetried() throws {
        let h = try BackendHarness()
        h.state.enabledAt = 1200
        try h.engine.step(h.backend, now: 1300)
        try h.engine.step(h.backend, now: 100000)
        #expect(h.desktop.starts.isEmpty)
        #expect(h.state.pending.isEmpty)
    }

    // test_metadata_must_match_latest_desktop_turn_id_status_and_error
    @Test func metadataMustMatchLatestDesktopTurnIDStatusAndError() throws {
        let h = try BackendHarness()
        let changes: [[String: JSON]] = [["id": "older"], ["status": "completed"],
                                          ["error": ["codexErrorInfo": "unauthorized", "message": .string(capacityMessage)]]]
        for change in changes {
            let original = h.metadata.turns
            for (key, value) in change { h.metadata.turns[0][key] = value }
            let error = backendRPCError { _ = try h.backend.call("thread/turns/list", ["threadId": "thread"]) }
            #expect(error?.isRequest == true, "change \(change)")
            h.metadata.turns = original
        }
        #expect(h.desktop.starts.isEmpty)
    }

    // test_busy_pending_and_placeholder_changes_during_wait_never_send
    @Test func busyPendingAndPlaceholderChangesDuringWaitNeverSend() throws {
        let mutations: [(DesktopPeerStub) -> Void] = [
            { $0.state["threadRuntimeStatus"] = ["type": "active", "activeFlags": []] },
            { $0.state["requests"] = [["type": "approval"]] },
            { $0.state["unconfirmedTurnSubmissions"] = [["id": "new-user-message"]] },
            { $0.setTurn(nil, "inProgress") },
        ]
        for (index, mutate) in mutations.enumerated() {
            let h = try BackendHarness()
            try h.arm()
            mutate(h.desktop)
            try h.due()
            #expect(h.desktop.starts.isEmpty, "mutation \(index)")
            #expect(h.state.pending.isEmpty, "mutation \(index)")
        }
    }

    // test_model_policy_and_owner_changes_during_wait_cancel_the_old_failure
    @Test func modelPolicyAndOwnerChangesDuringWaitCancelTheOldFailure() throws {
        let mutations: [(DesktopPeerStub) -> Void] = [
            { $0.setModel("another-model") },
            { $0.state[backendPath: ["currentPermissions", "approvalPolicy"]] = "never" },
            { $0.owner = "another-owner" },
        ]
        for (index, mutate) in mutations.enumerated() {
            let h = try BackendHarness()
            try h.arm()
            mutate(h.desktop)
            try h.due()
            #expect(h.desktop.starts.isEmpty, "mutation \(index)")
            #expect(h.state.pending.isEmpty, "mutation \(index)")
            #expect(h.state.handled["thread"]?.outcome == "cancelled", "mutation \(index)")
        }
    }

    // test_final_preflight_blocks_every_changed_state_after_write_ahead_save
    @Test func finalPreflightBlocksEveryChangedStateAfterWriteAheadSave() throws {
        let mutations: [(DesktopPeerStub) -> Void] = [
            { $0.state["threadRuntimeStatus"] = ["type": "active", "activeFlags": []] },
            { $0.state["requests"] = [["type": "input"]] },
            { $0.setTurn(nil, "inProgress") },
            { $0.setModel("another-model") },
            { $0.state[backendPath: ["currentPermissions", "approvalPolicy"]] = "never" },
            { $0.owner = "another-owner" },
            { peer in
                let path = ["params", "change", "revision"]
                peer.snapshot[backendPath: path] = .int((peer.snapshot[backendPath: path]?.int ?? 0) + 1)
            },
        ]
        for (index, mutate) in mutations.enumerated() {
            let h = try BackendHarness()
            try h.arm()
            h.onWriteAhead = { mutate(h.desktop) }
            try h.due()
            #expect(h.desktop.starts.isEmpty, "mutation \(index)")
            #expect(h.state.handled["thread"]?.outcome == "cancelled", "mutation \(index)")
            #expect(h.count("retry") == 0, "mutation \(index)")
            #expect(h.desktop.cleanConnections(), "mutation \(index)")
        }
    }

    // test_timeout_and_malformed_ack_are_uncertain_and_never_resent_after_restart
    @Test func timeoutAndMalformedAckAreUncertainAndNeverResentAfterRestart() throws {
        // A remote "timeout" error code yields the same DesktopIPCError("timeout") the Python
        // fake raised from request().
        enum Response { case error(String), ack(JSON) }
        let cases: [Response] = [.error("timeout"), .ack(nil), .ack([:]), .ack(["result": [:]]),
                                 .ack(["result": ["turn": ["id": ""]]]), .ack(["result": ["turn": ["id": nil]]])]
        for (index, response) in cases.enumerated() {
            let h = try BackendHarness()
            try h.arm()
            switch response {
            case .error(let code): h.desktop.startError = code
            case .ack(let value): h.desktop.ack = value
            }
            #expect(backendRPCError { try h.due() } != nil, "case \(index)")
            #expect(h.state.handled["thread"]?.outcome == "uncertain", "case \(index)")
            let messageID = h.state.handled["thread"]?.clientMessageID
            #expect(h.desktop.starts.count == 1, "case \(index)")
            #expect(h.count("retry") == 0, "case \(index)")
            h.state = try RetryState(json: h.state.json)
            h.engine = try h.newEngine()
            h.desktop.startError = nil
            h.desktop.ack = ["result": ["turn": ["id": "retry-turn"]]]
            try h.engine.step(h.backend, now: 2000)
            #expect(h.desktop.starts.count == 1, "case \(index)")
            #expect(h.state.handled["thread"]?.clientMessageID == messageID, "case \(index)")
            #expect(h.desktop.cleanConnections(), "case \(index)")
        }
    }

    // test_temporary_preflight_failure_restores_pending_and_previous_result_then_retries_later
    @Test func temporaryPreflightFailureRestoresPendingAndPreviousResultThenRetriesLater() throws {
        let previous: [JSON?] = [nil, ["turn_id": "earlier-failure", "retry_turn_id": "earlier-retry",
                                       "outcome": "submitted", "result_status": "successful", "at": 1000]]
        for earlier in previous {
            let h = try BackendHarness()
            let expected = try earlier.map { try Attempt(json: $0) }
            if let expected { h.state.handled["thread"] = expected }
            try h.arm()
            let pending = h.state.pending["thread"]
            #expect(pending != nil)
            h.onWriteAhead = { h.metadata.error = RPCError.request("Temporarily loading") }
            try h.due()
            #expect(h.desktop.starts.isEmpty)
            #expect(h.state.pending["thread"] == pending)
            #expect(h.state.handled["thread"] == expected)
            #expect(h.count("retry_deferred") == 1)
            #expect(h.count("retry") == 0 && h.count("uncertain") == 0)
            h.metadata.error = nil
            try h.engine.step(h.backend, now: 1309)
            #expect(h.desktop.starts.isEmpty)
            try h.engine.step(h.backend, now: 1310)
            #expect(h.desktop.starts.count == 1)
            #expect(h.state.handled["thread"]?.outcome == "submitted")
            #expect(h.desktop.cleanConnections())
        }
    }

    // test_runtime_snapshot_follows_slow_metadata_read_in_final_preflight
    @Test func runtimeSnapshotFollowsSlowMetadataReadInFinalPreflight() throws {
        let h = try BackendHarness()
        try h.arm()
        h.onWriteAhead = {
            h.metadata.afterRead = { h.desktop.state["threadRuntimeStatus"] = ["type": "active", "activeFlags": []] }
        }
        try h.due()
        #expect(h.desktop.starts.isEmpty)
        #expect(h.state.handled["thread"]?.outcome == "cancelled")
        #expect(h.count("retry") == 0 && h.count("uncertain") == 0)
        #expect(h.desktop.cleanConnections())
    }

    // test_same_old_turn_is_not_an_accepted_new_retry_acknowledgement
    @Test func sameOldTurnIsNotAnAcceptedNewRetryAcknowledgement() throws {
        let h = try BackendHarness()
        try h.arm()
        h.desktop.ack = ["result": ["turn": ["id": "failed-turn", "status": "failed"]]]
        #expect(backendRPCError { try h.due() } != nil)
        #expect(h.state.handled["thread"]?.outcome == "uncertain")
        #expect(h.count("retry") == 0)
    }

    // test_quota_wait_stays_held_without_reading_cli_account_permission
    @Test func quotaWaitStaysHeldWithoutReadingCLIAccountPermission() throws {
        let h = try BackendHarness()
        let error: JSON = ["codexErrorInfo": "usageLimitExceeded", "message": "Usage limit reached"]
        h.desktop.turn["error"] = error
        h.metadata.turns[0]["error"] = error
        try h.arm()
        try h.engine.step(h.backend, now: 1400)
        try h.engine.step(h.backend, now: 2000)
        #expect(h.desktop.starts.isEmpty)
        #expect(h.state.pending["thread"]?.kind == "quota")
        #expect(h.state.pending["thread"]?.quotaStatus == "unknown")
        #expect(h.metadata.calls.allSatisfy { $0.method == "thread/turns/list" })
    }

    // test_each_read_gets_a_new_targeted_snapshot_and_cleans_up_following
    @Test func eachReadGetsANewTargetedSnapshotAndCleansUpFollowing() throws {
        let h = try BackendHarness()
        for _ in 0..<2 {
            let result = try h.backend.call("thread/read", ["threadId": "thread"])
            #expect(result[backendPath: ["thread", "controlOwner"]] == "owner")
        }
        #expect(h.desktop.connections.count == 2)
        #expect(h.desktop.connections[0].clientID != h.desktop.connections[1].clientID)
        #expect(h.desktop.cleanConnections())
        h.desktop.snapshot["version"] = 12
        #expect(backendRPCError { _ = try h.backend.call("thread/read", ["threadId": "thread"]) }?.isRequest == true)
        #expect(h.desktop.cleanConnections())
    }

    // test_missing_owner_is_unloaded_but_unsupported_owner_is_a_protocol_error
    @Test func missingOwnerIsUnloadedButUnsupportedOwnerIsAProtocolError() throws {
        let h = try BackendHarness()
        h.desktop.ownerError = "no-client-found"
        #expect(try h.backend.call("thread/loaded/list", [:]) == ["data": [], "nextCursor": nil])
        #expect(backendRPCError { _ = try h.backend.call("thread/read", ["threadId": "thread"]) }?.kind == .noOwner)
        h.desktop.ownerError = nil
        let results: [JSON] = [[:], ["supportsUntrustedAppInput": false], ["supportsUntrustedAppInput": 1], nil]
        for result in results {
            h.desktop.ownerResult = result
            #expect(backendRPCError { _ = try h.backend.call("thread/loaded/list", [:]) }?.isRequest == true,
                    "owner result \(result)")
        }
        #expect(h.desktop.cleanConnections())
    }

    // test_scope_is_explicit_and_never_expands_to_other_conversations
    @Test func scopeIsExplicitAndNeverExpandsToOtherConversations() throws {
        let h = try BackendHarness()
        for ids in [[], (0..<9).map { "thread-\($0)" }] {
            #expect(throws: WhipError.self) {
                _ = try DesktopRPC(socketPath: URL(fileURLWithPath: "unused.sock"), metadata: h.metadata,
                                   threadIDs: ids, makeIPC: h.desktop.factory)
            }
        }
        #expect(backendRPCError { _ = try h.backend.call("thread/read", ["threadId": "another-thread"]) }?.isRequest == true)
        #expect(h.desktop.connections.isEmpty)
        #expect(h.metadata.calls.isEmpty)
    }

    // test_other_mutating_operations_are_unavailable_without_any_transport_call
    @Test func otherMutatingOperationsAreUnavailableWithoutAnyTransportCall() throws {
        let h = try BackendHarness()
        for method in ["thread/start", "thread/resume", "thread/archive", "turn/interrupt",
                       "account/login/start", "account/rateLimitResetCredit/consume"] {
            #expect(backendRPCError { _ = try h.backend.call(method, ["threadId": "thread"]) }?.isRequest == true,
                    "method \(method)")
        }
        #expect(h.desktop.connections.isEmpty)
        #expect(h.metadata.calls.isEmpty)
    }

    // test_stop_and_transport_cancellation_stay_cancellation_without_a_send
    @Test func stopAndTransportCancellationStayCancellationWithoutASend() throws {
        let h = try BackendHarness()
        let stopped = try DesktopRPC(socketPath: URL(fileURLWithPath: "unused.sock"), metadata: h.metadata,
                                     threadIDs: ["thread"], shouldStop: { true }, makeIPC: h.desktop.factory)
        #expect(backendRPCError { _ = try stopped.call("thread/loaded/list", [:]) }?.kind == .cancelled)
        #expect(h.desktop.connections.isEmpty)
        h.desktop.ownerError = "cancelled"
        #expect(backendRPCError { _ = try h.backend.call("thread/read", ["threadId": "thread"]) }?.kind == .cancelled)
        #expect(h.desktop.starts.isEmpty)
        #expect(h.desktop.cleanConnections())
    }

    // test_active_retry_is_successful_after_two_minutes_of_observed_healthy_work
    @Test func activeRetryIsSuccessfulAfterTwoMinutesOfObservedHealthyWork() throws {
        let h = try BackendHarness()
        try h.arm()
        try h.due()
        h.desktop.setTurn("retry-turn", "inProgress")
        h.desktop.state["threadRuntimeStatus"] = ["type": "active", "activeFlags": []]
        h.metadata.turns = [["id": "retry-turn", "status": "inProgress", "error": nil]]
        try h.engine.step(h.backend, now: 1290)
        try h.engine.step(h.backend, now: 1350)
        try h.engine.step(h.backend, now: 1410)
        #expect(h.state.handled["thread"]?.resultStatus == "successful")
        #expect(h.desktop.starts.count == 1)
    }

    // test_older_retry_result_keeps_capacity_classification_without_exporting_content
    @Test func olderRetryResultKeepsCapacityClassificationWithoutExportingContent() throws {
        let h = try BackendHarness()
        try h.arm()
        try h.due()
        h.desktop.setTurn("new-user-turn", "completed")
        h.desktop.state["threadRuntimeStatus"] = ["type": "idle"]
        h.metadata.turns = [
            ["id": "new-user-turn", "status": "completed", "error": nil, "completedAt": 1350],
            ["id": "retry-turn", "status": "failed", "completedAt": 1340,
             "error": ["codexErrorInfo": "serverOverloaded", "message": "private operation detail",
                       "additionalDetails": "private account detail"],
             "items": [["text": "private response"]]],
        ]
        let turns = try h.backend.call("thread/turns/list", ["threadId": "thread", "limit": 20])["data"] ?? nil
        #expect(!(try turns.serialized()).contains("private"))
        try h.engine.step(h.backend, now: 1400)
        let attempt = h.state.handled["thread"]
        #expect(attempt?.resultStatus == "failed")
        #expect(attempt?.resultCapacity == true)
        #expect(h.desktop.starts.count == 1)
    }
}
