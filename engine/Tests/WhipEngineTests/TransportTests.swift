// Port of the local WebSocket transport and doctor checks in tests/test_core.py.
// A fake server on a temporary Unix socket stands in for the Codex daemon.

import CryptoKit
import Foundation
import Testing
@testable import WhipEngine

struct CoreClientClosed: Error {}

/// One accepted connection on the fake server, with blocking reads under a receive timeout.
final class CoreTestConnection {
    let descriptor: Int32

    init(_ descriptor: Int32) {
        self.descriptor = descriptor
        var on: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        setTimeout(3)
    }

    func setTimeout(_ seconds: Int) {
        var value = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
    }

    func readExact(_ count: Int) throws -> [UInt8] {
        var result: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: max(count, 1))
        while result.count < count {
            let received = chunk.withUnsafeMutableBytes { recv(descriptor, $0.baseAddress!, count - result.count, 0) }
            if received == 0 { throw CoreClientClosed() }
            if received < 0 {
                if errno == EINTR { continue }
                throw CoreFakeFailure("Server read failed: errno \(errno)")
            }
            result += chunk[..<received]
        }
        return result
    }

    /// read_client_frame: returns the opcode and the unmasked payload.
    func readClientFrame() throws -> (opcode: UInt8, payload: [UInt8]) {
        let head = try readExact(2)
        guard head[1] & 0x80 != 0 else { throw CoreFakeFailure("Client WebSocket frames must be masked") }
        var size = Int(head[1] & 0x7F)
        if size == 126 {
            size = try readExact(2).reduce(0) { $0 << 8 | Int($1) }
        } else if size == 127 {
            size = try readExact(8).reduce(0) { $0 << 8 | Int($1) }
        }
        let mask = try readExact(4)
        let payload = try readExact(size)
        return (head[0] & 0x0F, payload.enumerated().map { $0.element ^ mask[$0.offset % 4] })
    }

    func readClientJSON() throws -> (opcode: UInt8, value: JSON) {
        let frame = try readClientFrame()
        return (frame.opcode, try JSON.parse(Data(frame.payload)))
    }

    func send(_ bytes: [UInt8]) throws {
        var offset = 0
        while offset < bytes.count {
            let sent = bytes.withUnsafeBytes { Darwin.send(descriptor, $0.baseAddress! + offset, bytes.count - offset, 0) }
            if sent < 0 {
                if errno == EINTR { continue }
                throw CoreFakeFailure("Server send failed: errno \(errno)")
            }
            offset += sent
        }
    }
}

/// server_frame: an unmasked server frame with a 7, 16 or 64 bit length.
func coreServerFrame(_ payload: [UInt8], opcode: UInt8 = 1, final: Bool = true) -> [UInt8] {
    var frame: [UInt8] = [(final ? 0x80 : 0) | opcode]
    let size = payload.count
    if size < 126 {
        frame.append(UInt8(size))
    } else if size < 65536 {
        frame += [126, UInt8(size >> 8), UInt8(size & 0xFF)]
    } else {
        frame.append(127)
        frame += (0..<8).reversed().map { UInt8((UInt64(size) >> (UInt64($0) * 8)) & 0xFF) }
    }
    return frame + payload
}

func coreServerFrame(_ value: JSON) throws -> [UInt8] {
    coreServerFrame(Array(try value.serialized().utf8))
}

/// LocalWebSocketServer: accepts one client, completes the upgrade and the initialize exchange,
/// then hands the connection to the test's handler on a background thread.
final class CoreTestWebSocketServer: @unchecked Sendable {
    let directory: URL
    let path: URL
    private let listener: Int32
    private let handler: (CoreTestConnection) throws -> Void
    private let finished = DispatchSemaphore(value: 0)
    private var error: Error?

    init(socketPath: (URL) -> URL = { $0.appendingPathComponent("rpc.sock") },
         handler: @escaping (CoreTestConnection) throws -> Void) throws {
        // Unix socket paths are limited to 104 bytes, so stay under /tmp as the Python test did.
        var template = Array("/tmp/cw-test-XXXXXX".utf8CString)
        guard let made = mkdtemp(&template) else { throw CoreFakeFailure("mkdtemp failed: errno \(errno)") }
        directory = URL(fileURLWithPath: String(cString: made))
        path = socketPath(directory)
        self.handler = handler
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
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
            throw CoreFakeFailure("Cannot listen on \(path.path): errno \(errno)")
        }
        Thread { [self] in
            do { try serve() } catch { self.error = error }
            finished.signal()
        }.start()
    }

    private func serve() throws {
        var entry = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
        guard poll(&entry, 1, 3000) > 0 else { throw CoreFakeFailure("No client connected") }
        let descriptor = accept(listener, nil, nil)
        guard descriptor >= 0 else { throw CoreFakeFailure("accept failed: errno \(errno)") }
        defer { Darwin.close(descriptor) }
        let connection = CoreTestConnection(descriptor)
        var headers: [UInt8] = []
        while headers.count < 4 || Array(headers.suffix(4)) != [13, 10, 13, 10] {
            headers += try connection.readExact(1)
        }
        var parsed: [String: String] = [:]
        for line in String(decoding: headers, as: UTF8.self).components(separatedBy: "\r\n").dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            parsed[String(line[..<colon])] = String(line[line.index(after: colon)...])
        }
        guard let key = parsed["Sec-WebSocket-Key"]?.trimmingCharacters(in: .whitespaces) else {
            throw CoreFakeFailure("No Sec-WebSocket-Key")
        }
        let digest = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8)))
            .base64EncodedString()
        try connection.send(Array(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n"
            + "Connection: Upgrade\r\nSec-WebSocket-Accept: \(digest)\r\n\r\n").utf8))
        let initialize = try connection.readClientJSON()
        guard initialize.opcode == 1, initialize.value["method"] == "initialize" else {
            throw CoreFakeFailure("Expected initialize request")
        }
        try connection.send(coreServerFrame(["id": initialize.value["id"] ?? nil, "result": ["platformOs": "test"]]))
        let initialized = try connection.readClientJSON()
        guard initialized.opcode == 1, initialized.value["method"] == "initialized" else {
            throw CoreFakeFailure("Expected initialized notification")
        }
        try handler(connection)
    }

    /// __exit__: waits for the handler, removes the socket, and reports a server-side failure.
    func finish(timeout: Double = 4) throws {
        let done = finished.wait(timeout: .now() + timeout) == .success
        Darwin.close(listener)
        try? FileManager.default.removeItem(at: directory)
        guard done else { throw CoreFakeFailure("Local WebSocket server did not finish") }
        if let error { throw error }
    }
}

/// `with LocalWebSocketServer(handler) as server:`. A failure in the body wins over a server failure.
func coreWithServer(socketPath: (URL) -> URL = { $0.appendingPathComponent("rpc.sock") }, joinTimeout: Double = 4,
                    _ handler: @escaping (CoreTestConnection) throws -> Void,
                    body: (CoreTestWebSocketServer) throws -> Void) throws {
    let server = try CoreTestWebSocketServer(socketPath: socketPath, handler: handler)
    do {
        try body(server)
    } catch {
        try? server.finish(timeout: joinTimeout)
        throw error
    }
    try server.finish(timeout: joinTimeout)
}

/// Waits until the client closes, failing if it sends any further frame.
private func expectNoFurtherRequest(_ connection: CoreTestConnection) throws {
    do {
        _ = try connection.readClientFrame()
        throw CoreFakeFailure("Client sent a request")
    } catch is CoreClientClosed {
        return
    }
}

// MARK: - WebSocketTests

@Suite struct CoreWebSocketTests {
    // test_cancellable_read_polling_waits_for_a_slow_successful_rpc
    @Test func cancellableReadPollingWaitsForASlowSuccessfulRpc() throws {
        try coreWithServer({ connection in
            let request = try connection.readClientJSON().value
            Thread.sleep(forTimeInterval: 0.6)
            try connection.send(coreServerFrame(["id": request["id"] ?? nil, "result": ["data": []]]))
        }) { server in
            let rpc = try WebSocketRPC(path: server.path, timeout: 1, shouldStop: { false })
            defer { rpc.close() }
            #expect(try rpc.call("thread/loaded/list", [:]) == ["data": []])
        }
    }

    // test_cancelled_transport_sends_no_request
    // Python built the object without connecting and checked that the mock socket sent nothing.
    // Swift cannot skip the initializer, so the stop request starts after the handshake and the fake
    // server checks that no request frame ever arrives.
    @Test func cancelledTransportSendsNoRequest() throws {
        let stopping = CoreFlag()
        try coreWithServer({ connection in try expectNoFurtherRequest(connection) }) { server in
            let rpc = try WebSocketRPC(path: server.path, timeout: 1, shouldStop: { stopping.value })
            defer { rpc.close() }
            stopping.value = true
            #expect {
                _ = try rpc.call("test/read-only-request", [:])
            } throws: { ($0 as? RPCError)?.kind == .cancelled }
        }
    }

    // test_real_unix_socket_handshake_ping_fragmentation_and_notifications
    @Test func realUnixSocketHandshakePingFragmentationAndNotifications() throws {
        try coreWithServer({ connection in
            let (opcode, request) = try connection.readClientJSON()
            guard opcode == 1 else { throw CoreFakeFailure("opcode \(opcode)") }
            guard request["method"] == "thread/loaded/list" else { throw CoreFakeFailure("method \(String(describing: request["method"]))") }
            try connection.send(coreServerFrame(["method": "thread/status/changed", "params": [:]]))
            let response = Array(try JSON.object(["id": request["id"] ?? nil,
                                                  "result": ["data": ["session"], "note": .string(String(repeating: "x", count: 200))]])
                .serialized().utf8)
            try connection.send(coreServerFrame(Array(response[..<20]), final: false)
                + coreServerFrame(Array("keepalive".utf8), opcode: 9)
                + coreServerFrame(Array(response[20...]), opcode: 0))
            let pong = try connection.readClientFrame()
            guard pong.opcode == 10, pong.payload == Array("keepalive".utf8) else {
                throw CoreFakeFailure("Expected pong keepalive, got \(pong)")
            }
        }) { server in
            let rpc = try WebSocketRPC(path: server.path, timeout: 1)
            defer { rpc.close() }
            let response = try rpc.call("thread/loaded/list", [:])
            #expect(response["data"] == ["session"])
            #expect(rpc.events.first?["method"] == "thread/status/changed")
        }
    }

    // test_remote_error_is_not_a_success
    @Test func remoteErrorIsNotASuccess() throws {
        try coreWithServer({ connection in
            let request = try connection.readClientJSON().value
            try connection.send(coreServerFrame(["id": request["id"] ?? nil, "error": [
                "code": -32000, "message": "Thread unavailable",
            ]]))
        }) { server in
            let rpc = try WebSocketRPC(path: server.path, timeout: 1)
            defer { rpc.close() }
            #expect {
                _ = try rpc.call("thread/read", ["threadId": "gone"])
            } throws: { ($0 as? RPCError)?.description.contains("Thread unavailable") == true }
        }
    }

    // test_interleaved_approval_request_receives_no_automatic_response
    @Test func interleavedApprovalRequestReceivesNoAutomaticResponse() throws {
        try coreWithServer({ connection in
            let request = try connection.readClientJSON().value
            try connection.send(coreServerFrame([
                "id": 99, "method": "item/commandExecution/requestApproval",
                "params": ["threadId": "user-session", "command": "needs user approval"],
            ]) + coreServerFrame(["id": request["id"] ?? nil, "result": ["data": []]]))
            // The next client frame must be its next explicit RPC, never a reply
            // resolving the approval on behalf of the user's Codex client.
            let (opcode, next) = try connection.readClientJSON()
            guard opcode == 1, next["method"] == "test/next" else {
                throw CoreFakeFailure("Expected test/next, got \(opcode) \(next)")
            }
            try connection.send(coreServerFrame(["id": next["id"] ?? nil, "result": ["ok": true]]))
        }) { server in
            let rpc = try WebSocketRPC(path: server.path, timeout: 1)
            defer { rpc.close() }
            #expect(try rpc.call("thread/loaded/list", [:]) == ["data": []])
            #expect(rpc.events.first?["id"] == 99)
            #expect(try rpc.call("test/next", [:])["ok"] == true)
        }
    }

    // test_large_masked_request_and_64_bit_length_response
    @Test func largeMaskedRequestAnd64BitLengthResponse() throws {
        try coreWithServer({ connection in
            let request = try connection.readClientJSON().value
            guard request["params"]?["payload"]?.string?.count == 70000 else {
                throw CoreFakeFailure("Request payload was not 70000 characters")
            }
            try connection.send(coreServerFrame(["id": request["id"] ?? nil,
                                                 "result": ["payload": .string(String(repeating: "x", count: 70000))]]))
        }) { server in
            let rpc = try WebSocketRPC(path: server.path, timeout: 1)
            defer { rpc.close() }
            let response = try rpc.call("test", ["payload": .string(String(repeating: "y", count: 70000))])
            #expect(response["payload"]?.string?.count == 70000)
        }
    }

    /// A server that reads the request and never answers, then waits for the client to give up.
    private func silentServer(_ body: (CoreTestWebSocketServer) throws -> Void) throws {
        try coreWithServer(joinTimeout: 25, { connection in
            _ = try connection.readClientFrame()
            connection.setTimeout(25)
            try expectNoFurtherRequest(connection)
        }, body: body)
    }

    // test_socket_timeout_does_not_become_success
    // Python injected socket.timeout from a mock recv. Swift has no per-read timeout to inject; a
    // server that never answers makes the real read wait end in an error, never a result.
    @Test func socketTimeoutDoesNotBecomeSuccess() throws {
        try silentServer { server in
            let rpc = try WebSocketRPC(path: server.path, timeout: 1)
            defer { rpc.close() }
            var result: JSON?
            #expect(throws: RPCError.self) { result = try rpc.call("thread/read", ["threadId": "missing"]) }
            #expect(result == nil)
        }
    }

    // test_response_deadline_is_reported_as_failure
    // Python patched time.monotonic to jump 16 seconds. WebSocketRPC.call reads the private
    // monotonic() with no clock seam, so this waits out the real 15 second response deadline.
    @Test func responseDeadlineIsReportedAsFailure() throws {
        try silentServer { server in
            let rpc = try WebSocketRPC(path: server.path, timeout: 1)
            defer { rpc.close() }
            #expect {
                _ = try rpc.call("thread/read", ["threadId": "missing"])
            } throws: { ($0 as? RPCError)?.description.contains("deadline exceeded") == true }
        }
    }
}

// MARK: - DoctorTests

@Suite struct CoreDoctorTests {
    // test_unreadable_thread_is_skipped_without_model_or_turn_requests
    // Python patched WebSocketRPC and resolve_socket. Here the fake server listens at the socket path
    // resolveSocket expects under a temporary Codex home and answers from the FakeRPC, so the real
    // transport and doctor run. The server finishing on EOF stands in for `rpc.close` being called.
    @Test func unreadableThreadIsSkippedWithoutModelOrTurnRequests() throws {
        let rpc = CoreFakeRPC()
        rpc.loaded = ["a-unavailable", "user-session"]
        rpc.beforeCall = { method, params in
            if method == "thread/read" && params["threadId"] == "a-unavailable" {
                throw RPCError.request("Thread unavailable")
            }
        }
        var closed = false
        var output: [String] = []
        try coreWithServer(socketPath: { $0.appendingPathComponent("app-server-control/app-server-control.sock") }, { connection in
            while true {
                let request: JSON
                do {
                    request = try connection.readClientJSON().value
                } catch is CoreClientClosed {
                    closed = true
                    return
                }
                let id = request["id"] ?? nil
                do {
                    let result = try rpc.call(request["method"]?.string ?? "", request["params"] ?? [:])
                    try connection.send(coreServerFrame(["id": id, "result": result]))
                } catch let error as RPCError {
                    try connection.send(coreServerFrame(["id": id, "error": ["code": -32000, "message": .string(error.description)]]))
                }
            }
        }) { server in
            try Service.doctor(codexHome: server.directory, output: { output.append($0) })
        }
        let text = output.joined(separator: "\n")
        #expect(text.contains("2 loaded sessions, 1 accept direct input"))
        #expect(text.contains("Skipped 1 sessions"))
        #expect(text.contains("Read-only check passed"))
        #expect(rpc.sends() == [])
        #expect(!rpc.calls.contains { $0.method == "thread/turns/list" })
        #expect(closed)
    }
}
