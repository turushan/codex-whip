// Port of tests/test_desktop_ipc.py.
// Desktop framing checks use temporary socket servers, never the actual app.

import Darwin
import Foundation
import Testing
@testable import WhipEngine

// MARK: - Fake length-prefixed JSON server

private struct StubEOF: Error {}
private struct StubFailure: Error, CustomStringConvertible { let description: String }

/// A one-shot flag that several threads can wait on, like Python's threading.Event.
private final class Event: @unchecked Sendable {
    private let condition = NSCondition()
    private var flag = false

    func set() {
        condition.lock()
        flag = true
        condition.broadcast()
        condition.unlock()
    }

    var isSet: Bool {
        condition.lock()
        defer { condition.unlock() }
        return flag
    }

    @discardableResult
    func wait(_ seconds: Double) -> Bool {
        let deadline = Date(timeIntervalSinceNow: seconds)
        condition.lock()
        defer { condition.unlock() }
        while !flag {
            if !condition.wait(until: deadline) { return flag }
        }
        return true
    }
}

/// A thread-safe list for values captured on the server thread.
private final class Captured<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []
    func append(_ item: T) { lock.lock(); items.append(item); lock.unlock() }
    var values: [T] { lock.lock(); defer { lock.unlock() }; return items }
}

/// The accepted side of a stub connection, with blocking reads bounded by a two-second timeout.
private final class Connection {
    let descriptor: Int32

    init(_ descriptor: Int32) {
        self.descriptor = descriptor
        var noSigPipe: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var limit = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
    }

    func readExact(_ size: Int) throws -> [UInt8] {
        var result = [UInt8]()
        var chunk = [UInt8](repeating: 0, count: max(1, min(size, 65536)))
        while result.count < size {
            let wanted = min(size - result.count, chunk.count)
            let count = chunk.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress!, wanted) }
            if count > 0 { result += chunk[..<count]; continue }
            if count == 0 { throw StubEOF() }
            if errno == EINTR { continue }
            if errno == ECONNRESET { throw StubEOF() }
            throw StubFailure(description: "Stub read failed with errno \(errno)")
        }
        return result
    }

    /// Reads one byte, returning an empty array at EOF, like `connection.recv(1)`.
    func receiveOne() throws -> [UInt8] {
        var byte: UInt8 = 0
        while true {
            let count = Darwin.read(descriptor, &byte, 1)
            if count == 1 { return [byte] }
            if count == 0 { return [] }
            if errno == EINTR { continue }
            throw StubFailure(description: "Stub read failed with errno \(errno)")
        }
    }

    func readMessage() throws -> JSON {
        let header = try readExact(4)
        let size = Int(header[0]) | Int(header[1]) << 8 | Int(header[2]) << 16 | Int(header[3]) << 24
        return try JSON.parse(Data(try readExact(size)))
    }

    func sendAll(_ bytes: [UInt8]) throws {
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress! + offset, bytes.count - offset) }
            if written > 0 { offset += written; continue }
            if errno == EINTR { continue }
            if errno == EPIPE || errno == ECONNRESET { throw StubEOF() }
            throw StubFailure(description: "Stub write failed with errno \(errno)")
        }
    }

    func writeMessage(_ message: JSON, fragmented: Bool = false) throws {
        try writeRaw(Array(try message.serialized(JSON.Format(sortKeys: false)).utf8), fragmented: fragmented)
    }

    func writeRaw(_ data: [UInt8], fragmented: Bool = false) throws {
        let frame = frameHeader(data.count) + data
        if fragmented {
            for (start, end) in [(0, 1), (1, 3), (3, 7), (7, 11), (11, frame.count)] {
                try sendAll(Array(frame[start..<end]))
                usleep(2000)
            }
        } else {
            try sendAll(frame)
        }
    }
}

private func frameHeader(_ size: Int) -> [UInt8] {
    let value = UInt32(size)
    return [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8(value >> 24)]
}

private func success(_ request: JSON, _ result: JSON = .null, owner: JSON = "desktop-owner",
                     _ changes: [String: JSON] = [:]) -> JSON {
    var response: JSON = ["type": "response", "requestId": request["requestId"] ?? .null,
                          "resultType": "success", "method": request["method"] ?? .null,
                          "handledByClientId": owner, "result": result]
    for (key, value) in changes { response[key] = value }
    return response
}

private func broadcast(method: String = "thread-stream-state-changed", params: JSON? = nil) -> JSON {
    ["type": "broadcast", "sourceClientId": "desktop-owner", "version": 11,
     "method": .string(method), "targetClientIds": ["test-client"],
     "params": params ?? ["conversationId": "synthetic-thread", "change": ["revision": 1]]]
}

private final class Stub: @unchecked Sendable {
    typealias Handler = (Connection, Stub) throws -> Void
    typealias Initialize = (Connection, JSON) throws -> Void

    let directory: URL
    let path: URL
    let finish = Event()
    private let handler: Handler?
    private let initialize: Initialize?
    private let listener: Int32
    private let done = Event()
    private let lock = NSLock()
    private var errors: [Error] = []
    private var initialMessage: JSON?
    /// A small receive buffer, used to make a large local send wait for socket capacity.
    var receiveBuffer: Int32?

    var initial: JSON? { lock.lock(); defer { lock.unlock() }; return initialMessage }

    init(_ handler: Handler?, initialize: Initialize? = nil) throws {
        self.handler = handler
        self.initialize = initialize
        var template = Array("/tmp/cw-XXXXXX".utf8CString)
        guard let made = mkdtemp(&template) else { throw StubFailure(description: "mkdtemp failed") }
        directory = URL(fileURLWithPath: String(cString: made))
        path = directory.appendingPathComponent("ipc.sock")
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw StubFailure(description: "socket failed") }
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
        guard bound == 0, listen(listener, 1) == 0 else {
            Darwin.close(listener)
            throw StubFailure(description: "bind or listen failed")
        }
    }

    func start() {
        let thread = Thread { [self] in
            run()
            done.set()
        }
        thread.start()
    }

    private func record(_ error: Error) {
        if error is StubEOF || finish.isSet { return }
        lock.lock()
        errors.append(error)
        lock.unlock()
    }

    private func run() {
        var accepted: Int32 = -1
        while !finish.isSet {
            var entry = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            if poll(&entry, 1, 50) > 0 {
                accepted = accept(listener, nil, nil)
                if accepted >= 0 { break }
            }
        }
        guard accepted >= 0 else { return }
        defer { Darwin.close(accepted) }
        if var size = receiveBuffer {
            setsockopt(accepted, SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout<Int32>.size))
        }
        let connection = Connection(accepted)
        do {
            let first = try connection.readMessage()
            lock.lock()
            initialMessage = first
            lock.unlock()
            if let initialize {
                try initialize(connection, first)
            } else {
                try connection.writeMessage(success(first, ["clientId": "test-client"], owner: "test-client"),
                                            fragmented: true)
                try handler?(connection, self)
            }
        } catch {
            record(error)
        }
    }

    /// Mirrors the Python stub's __exit__: stop, join, clean up, then surface server errors.
    func stop() throws {
        finish.set()
        let stopped = done.wait(2.2)
        Darwin.close(listener)
        try? FileManager.default.removeItem(at: directory)
        if !stopped { throw StubFailure(description: "Socket stub did not stop") }
        lock.lock()
        let first = errors.first
        lock.unlock()
        if let first { throw first }
    }
}

private func withStub<T>(_ handler: Stub.Handler?, initialize: Stub.Initialize? = nil,
                         configure: (Stub) -> Void = { _ in },
                         _ body: (Stub) throws -> T) throws -> T {
    let stub = try Stub(handler, initialize: initialize)
    configure(stub)
    stub.start()
    let result: T
    do {
        result = try body(stub)
    } catch {
        _ = try? stub.stop()
        throw error
    }
    try stub.stop()
    return result
}

/// Opens a client, runs the body and always closes the client before the stub stops.
private func withIPC<T>(_ stub: Stub, timeout: Double = 12, shouldStop: @escaping () -> Bool = { false },
                        _ body: (DesktopIPC) throws -> T) throws -> T {
    let ipc = try DesktopIPC(path: stub.path, timeout: timeout, shouldStop: shouldStop)
    defer { ipc.close() }
    return try body(ipc)
}

private func ipcError(_ operation: () throws -> Void) -> DesktopIPCError? {
    do {
        try operation()
    } catch let error as DesktopIPCError {
        return error
    } catch {
        Issue.record("Unexpected error \(error)")
        return nil
    }
    Issue.record("Expected DesktopIPCError")
    return nil
}

private func elapsed(since start: ContinuousClock.Instant) -> Double {
    let duration = ContinuousClock.now - start
    return Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
}

private func broadcastFrame(index: Int, paddingBytes: Int) -> [UInt8] {
    // Built by hand so a multi-megabyte padding does not pass through the serializer.
    let prefix = #"{"type":"broadcast","sourceClientId":"desktop-owner","version":11,"#
        + #""method":"thread-stream-state-changed","targetClientIds":["test-client"],"#
        + #""params":{"index":\#(index),"padding":""#
    return Array(prefix.utf8) + [UInt8](repeating: UInt8(ascii: "x"), count: paddingBytes) + Array(#""}}"#.utf8)
}

// MARK: - Tests

@Suite(.serialized)
struct DesktopIPCTests {
    // test_handshake_targeted_request_and_void_success_keep_owner_and_unicode
    @Test func handshakeTargetedRequestAndVoidSuccessKeepOwnerAndUnicode() throws {
        let requests = Captured<JSON>()
        try withStub({ connection, _ in
            var request = try connection.readMessage()
            requests.append(request)
            try connection.writeMessage(success(request, ["label": "A synthetic 👋 result"]), fragmented: true)
            request = try connection.readMessage()
            requests.append(request)
            var response = success(request)
            response["result"] = nil
            try connection.writeMessage(response)
        }) { stub in
            try withIPC(stub) { ipc in
                #expect(ipc.clientID == "test-client")
                let full = try ipc.requestFull("synthetic-read", ["text": "👩🏽‍💻"], version: 3, target: "desktop-owner")
                #expect(full["handledByClientId"] == "desktop-owner")
                #expect(full["result"]?["label"] == "A synthetic 👋 result")
                #expect(try ipc.request("synthetic-void", [:], target: "desktop-owner") == .null)
                let initial = try #require(stub.initial)
                #expect(initial["sourceClientId"] == "initializing-client")
                #expect(initial["version"] == 0)
                #expect(initial["params"] == ["clientType": "codex_whip"])
                #expect(initial["timeoutMs"] == 5000)
                let captured = requests.values
                try #require(captured.count == 2)
                #expect(captured[0]["sourceClientId"] == "test-client")
                #expect(captured[0]["targetClientId"] == "desktop-owner")
                #expect(captured[0]["version"] == 3)
                #expect(captured[0]["params"]?["text"] == "👩🏽‍💻")
            }
        }
    }

    // test_interleaved_discovery_and_broadcasts_do_not_replace_request_response
    @Test func interleavedDiscoveryAndBroadcastsDoNotReplaceRequestResponse() throws {
        let captured = Captured<JSON>()
        let first = broadcast(params: ["kind": "first"])
        let second = broadcast(method: "synthetic-second", params: ["kind": "second"])
        try withStub({ connection, _ in
            let request = try connection.readMessage()
            try connection.writeMessage(["type": "client-discovery-request", "requestId": "discovery-question",
                                         "request": ["method": "thread-owner-discovery"]])
            captured.append(try connection.readMessage())
            try connection.writeMessage(success(["requestId": "unrelated", "method": "other"], ["ignored": true]))
            try connection.writeMessage(first)
            try connection.writeMessage(second)
            try connection.writeMessage(success(request, ["ok": true]))
        }) { stub in
            try withIPC(stub) { ipc in
                let answer = try ipc.request("synthetic-read", [:]); #expect(answer == ["ok": true])
                let secondSeen = try ipc.waitBroadcast { $0["params"]?["kind"] == "second" }; #expect(secondSeen == second)
                let firstSeen = try ipc.waitBroadcast { $0["params"]?["kind"] == "first" }; #expect(firstSeen == first)
                #expect(captured.values == [["type": "client-discovery-response", "requestId": "discovery-question",
                                             "response": ["canHandle": false]]])
            }
        }
    }

    // test_broadcast_preserves_version_targets_and_assigned_source
    @Test func broadcastPreservesVersionTargetsAndAssignedSource() throws {
        let captured = Captured<JSON>()
        let ready = Event()
        try withStub({ connection, _ in
            captured.append(try connection.readMessage())
            ready.set()
        }) { stub in
            try withIPC(stub) { ipc in
                try ipc.broadcast("thread-stream-following-changed", ["following": true], version: 1,
                                  targets: ["desktop-owner"])
                #expect(ready.wait(1))
                #expect(captured.values == [["type": "broadcast", "sourceClientId": "test-client", "version": 1,
                                             "method": "thread-stream-following-changed", "params": ["following": true],
                                             "targetClientIds": ["desktop-owner"]]])
            }
        }
    }

    // test_remote_errors_are_sanitized_and_do_not_close_a_valid_connection
    @Test func remoteErrorsAreSanitizedAndDoNotCloseAValidConnection() throws {
        let errors: [JSON] = ["no-client-found", "SECRET transcript text", ["message": "SECRET account"]]
        try withStub({ connection, _ in
            for error in errors {
                let request = try connection.readMessage()
                try connection.writeMessage(["type": "response", "requestId": request["requestId"]!,
                                             "resultType": "error", "error": error])
            }
            let request = try connection.readMessage()
            try connection.writeMessage(success(request, true))
        }) { stub in
            try withIPC(stub) { ipc in
                for expected in ["no-client-found", "request-failed", "request-failed"] {
                    let caught = ipcError { _ = try ipc.request("synthetic-read", [:]) }
                    #expect(caught?.code == expected)
                    #expect(!String(describing: caught).contains("SECRET"))
                    #expect(!String(reflecting: caught).contains("SECRET"))
                }
                let recovered = try ipc.request("synthetic-read", [:]); #expect(recovered == true)
            }
        }
    }

    // test_handshake_requires_assigned_client_and_matching_owner
    @Test(arguments: [(JSON.object([:]), JSON.string("client")),
                      (JSON.object(["clientId": "test-client"]), JSON.string("other")),
                      (JSON.null, JSON.null)])
    func handshakeRequiresAssignedClientAndMatchingOwner(result: JSON, owner: JSON) throws {
        try withStub(nil, initialize: { connection, request in
            try connection.writeMessage(success(request, result, owner: owner))
        }) { stub in
            let caught = ipcError { _ = try DesktopIPC(path: stub.path) }
            #expect(caught?.code == "invalid-response")
        }
    }

    // test_malformed_frames_and_eof_fail_closed_without_payload_text
    @Test(arguments: [
        (frameHeader(0), "malformed-frame"),
        (frameHeader(DesktopIPC.maxFrameBytes + 1), "oversized-frame"),
        (frameHeader(3) + Array("{!?".utf8), "malformed-frame"),
        (frameHeader(1) + [0xFF], "malformed-frame"),
        (frameHeader(2) + Array("[]".utf8), "malformed-frame"),
        (frameHeader(7) + Array(#"{"x":1}"#.utf8), "invalid-response"),
        (frameHeader(13) + Array(#"{"a":1,"a":2}"#.utf8), "malformed-frame"),
        (frameHeader(9) + Array(#"{"x":NaN}"#.utf8), "malformed-frame"),
        ([0x00, 0x00], "disconnected"),
        (frameHeader(100) + Array("SECRET partial".utf8), "disconnected"),
    ] as [([UInt8], String)])
    func malformedFramesAndEOFFailClosedWithoutPayloadText(frame: [UInt8], expected: String) throws {
        try withStub({ connection, _ in
            _ = try connection.readMessage()
            try connection.sendAll(frame)
        }) { stub in
            try withIPC(stub) { ipc in
                let caught = ipcError { _ = try ipc.request("synthetic-read", [:]) }
                #expect(caught?.code == expected)
                #expect(!String(describing: caught).contains("SECRET"))
                let closed = ipcError { _ = try ipc.request("synthetic-read", [:]) }
                #expect(closed?.code == "closed")
            }
        }
    }

    // test_wrong_method_wrong_owner_and_invalid_response_shapes_fail_closed
    @Test(arguments: [
        ["method": "wrong"], ["handledByClientId": "wrong"],
        ["resultType": "unexpected"], ["requestId": .null],
        ["type": "unsupported"],
    ] as [[String: JSON]])
    func wrongMethodWrongOwnerAndInvalidResponseShapesFailClosed(changes: [String: JSON]) throws {
        try withStub({ connection, _ in
            let request = try connection.readMessage()
            try connection.writeMessage(success(request, [:], changes))
        }) { stub in
            try withIPC(stub) { ipc in
                let caught = ipcError { _ = try ipc.request("synthetic-read", [:], target: "desktop-owner") }
                #expect(caught?.code == "invalid-response")
            }
        }
    }

    // test_message_and_byte_budgets_bound_interleaved_buffers
    // Python patched MAX_BUFFERED_MESSAGES to 2 and MAX_BUFFERED_BYTES to 250. The Swift limits are
    // constants, so this port exceeds the real limits instead: more broadcasts than
    // DesktopIPC.maxBufferedMessages, or large broadcasts whose sizes add up past maxBufferedBytes.
    @Test func messageBudgetBoundsInterleavedBuffers() throws {
        let count = DesktopIPC.maxBufferedMessages + 2
        try withStub({ connection, _ in
            let request = try connection.readMessage()
            for index in 0..<count {
                try connection.writeRaw(broadcastFrame(index: index, paddingBytes: 100))
            }
            try connection.writeMessage(success(request, [:]))
        }) { stub in
            try withIPC(stub) { ipc in
                let caught = ipcError { _ = try ipc.request("synthetic-read", [:]) }
                #expect(caught?.code == "buffer-overflow")
            }
        }
    }

    @Test func byteBudgetBoundsInterleavedBuffers() throws {
        // Three of these exceed the byte budget while each stays under the frame limit.
        let padding = DesktopIPC.maxBufferedBytes / 3 + 1024
        try #require(padding < DesktopIPC.maxFrameBytes - 1024)
        try withStub({ connection, _ in
            let request = try connection.readMessage()
            for index in 0..<4 {
                try connection.writeRaw(broadcastFrame(index: index, paddingBytes: padding))
            }
            try connection.writeMessage(success(request, [:]))
        }) { stub in
            try withIPC(stub) { ipc in
                let caught = ipcError { _ = try ipc.request("synthetic-read", [:], timeout: 30) }
                #expect(caught?.code == "buffer-overflow")
            }
        }
    }

    // test_timeout_and_cancellation_bound_waits_and_close_the_socket
    @Test(arguments: [false, true])
    func timeoutAndCancellationBoundWaitsAndCloseTheSocket(cancelled: Bool) throws {
        let stop = Event()
        try withStub({ connection, stub in
            _ = try connection.readMessage()
            if cancelled { stop.set() }
            stub.finish.wait(1)
        }) { stub in
            try withIPC(stub, shouldStop: { stop.isSet }) { ipc in
                let started = ContinuousClock.now
                let caught = ipcError { _ = try ipc.request("synthetic-read", [:], timeout: cancelled ? 2 : 0.08) }
                #expect(caught?.code == (cancelled ? "cancelled" : "timeout"))
                #expect(elapsed(since: started) < 0.25)
            }
        }
    }

    // test_oversized_outgoing_request_and_invalid_arguments_send_nothing
    // Python patched MAX_FRAME_BYTES to 1024; this port sends a payload past the real limit instead.
    // Python cases that the Swift types make unrepresentable are omitted: version=True and
    // broadcast(targets="owner").
    @Test func oversizedOutgoingRequestAndInvalidArgumentsSendNothing() throws {
        try withStub({ connection, _ in
            let request = try connection.readMessage()
            guard request["method"] == "valid" else {
                throw StubFailure(description: "Stub received \(request["method"] ?? .null) before the valid request")
            }
            try connection.writeMessage(success(request, true))
        }) { stub in
            try withIPC(stub) { ipc in
                let content = String(repeating: "x", count: DesktopIPC.maxFrameBytes + 1)
                let caught = ipcError { _ = try ipc.request("oversized", ["content": .string(content)]) }
                #expect(caught?.code == "oversized-frame")
                let operations: [() throws -> Void] = [
                    { _ = try ipc.request("bad", [:], target: "") },
                    { _ = try ipc.request("bad", [:], timeout: 0) },
                    { _ = try ipc.request("bad", [:], timeout: .infinity) },
                    { _ = try ipc.request("bad", ["not-json": .double(.nan)]) },
                    { _ = try ipc.request("initialize", [:]) },
                    { try ipc.broadcast("bad", [:], timeout: 0) },
                ]
                for operation in operations {
                    let error = ipcError(operation)
                    #expect(error?.code == "invalid-request")
                }
                let valid = try ipc.request("valid", [:]); #expect(valid == true)
            }
        }
    }

    // test_broadcast_timeout_bounds_a_backpressured_cleanup_send
    // Python shrank the client's SO_SNDBUF through ipc.sock. The Swift descriptor is private,
    // so the stub shrinks its own receive buffer instead; the stalled peer still applies backpressure.
    @Test func broadcastTimeoutBoundsABackpressuredCleanupSend() throws {
        try withStub({ _, stub in
            // Stop reading after initialization so a large local broadcast must
            // wait for socket capacity instead of completing in one write.
            stub.finish.wait(1)
        }, configure: { $0.receiveBuffer = 1024 }) { stub in
            try withIPC(stub, timeout: 12) { ipc in
                let started = ContinuousClock.now
                let caught = ipcError {
                    try ipc.broadcast("synthetic-cleanup", ["padding": .string(String(repeating: "x", count: 256 * 1024))],
                                      timeout: 0.06)
                }
                #expect(caught?.code == "timeout")
                #expect(elapsed(since: started) < 0.25)
                let closed = ipcError { try ipc.broadcast("synthetic-cleanup", [:], timeout: 0.06) }
                #expect(closed?.code == "closed")
            }
        }
    }

    // test_missing_socket_symlink_and_invalid_timeout_are_rejected_without_connection
    // The Python timeout values True and "12" are unrepresentable in Swift and are omitted.
    @Test func missingSocketSymlinkAndInvalidTimeoutAreRejectedWithoutConnection() throws {
        var template = Array("/tmp/cw-XXXXXX".utf8CString)
        let made = try #require(mkdtemp(&template))
        let temporary = URL(fileURLWithPath: String(cString: made))
        defer { try? FileManager.default.removeItem(at: temporary) }
        let missing = ipcError { _ = try DesktopIPC(path: temporary.appendingPathComponent("absent")) }
        #expect(missing?.code == "unavailable")

        try withStub({ _, _ in }) { stub in
            let link = stub.directory.appendingPathComponent("linked.sock")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: stub.path)
            let caught = ipcError { _ = try DesktopIPC(path: link) }
            #expect(caught?.code == "unavailable")
        }
        for value in [0, -1, Double.nan] {
            let caught = ipcError { _ = try DesktopIPC(path: URL(fileURLWithPath: "/not-used"), timeout: value) }
            #expect(caught?.code == "invalid-request")
        }
    }

    // test_close_is_idempotent_and_context_manager_closes_peer
    @Test func closeIsIdempotentAndContextManagerClosesPeer() throws {
        let closed = Event()
        try withStub({ connection, _ in
            guard try connection.receiveOne().isEmpty else {
                throw StubFailure(description: "Stub expected EOF")
            }
            closed.set()
        }) { stub in
            let ipc = try DesktopIPC(path: stub.path)
            ipc.close()
            ipc.close()
            #expect(closed.wait(1))
            let caught = ipcError { try ipc.broadcast("synthetic", [:]) }
            #expect(caught?.code == "closed")
        }
    }
}
