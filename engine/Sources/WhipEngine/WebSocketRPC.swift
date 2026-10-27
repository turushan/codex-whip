import CryptoKit
import Foundation

/// A small RFC 6455 client for Codex's local control socket, with no packages.
///
/// Every wait polls in short slices, so a stopping worker is noticed within a quarter second
/// and no request outlives its deadline.
public final class WebSocketRPC: RPCClient {
    public private(set) var events: [JSON] = []
    private var descriptor: Int32 = -1
    private let timeout: Double
    private let shouldStop: () -> Bool
    private var buffer: [UInt8] = []
    private var sequence = 0
    private var deadline: Double?

    public init(path: URL, timeout: Double = 10, shouldStop: @escaping () -> Bool = { false }) throws {
        self.timeout = timeout
        self.shouldStop = shouldStop
        do {
            try connect(path)
            deadline = monotonic() + timeout
            var keyBytes = [UInt8](repeating: 0, count: 16)
            _ = SecRandomCopyBytes(kSecRandomDefault, keyBytes.count, &keyBytes)
            let key = Data(keyBytes).base64EncodedString()
            try sendBytes(Array(("GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\n"
                + "Connection: Upgrade\r\nSec-WebSocket-Version: 13\r\n"
                + "Sec-WebSocket-Key: \(key)\r\n\r\n").utf8))
            let separator: [UInt8] = [13, 10, 13, 10]
            var end: Int?
            while end == nil {
                try receive()
                end = buffer.firstRange(of: separator)?.lowerBound
                if end == nil && buffer.count > 65536 { throw RPCError.transport("Oversized WebSocket handshake") }
            }
            let header = String(decoding: buffer[..<end!], as: UTF8.self)
            buffer.removeFirst(end! + 4)
            let lines = header.components(separatedBy: "\r\n")
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { continue }
                headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            let expected = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8)))
                .base64EncodedString()
            let statusParts = lines.first?.split(separator: " ") ?? []
            guard statusParts.count > 1, statusParts[1] == "101", headers["sec-websocket-accept"] == expected else {
                throw RPCError.transport("Codex control socket did not accept WebSocket upgrade")
            }
            deadline = nil
            _ = try call("initialize", [
                "clientInfo": ["name": "codex_whip", "title": "Codex Whip", "version": .string(engineVersion)],
                "capabilities": ["experimentalApi": true],
            ])
            try sendJSON(["method": "initialized"])
        } catch {
            close()
            throw error
        }
    }

    deinit { close() }

    public func close() {
        if descriptor >= 0 { Darwin.close(descriptor) }
        descriptor = -1
    }

    private func checkCancelled() throws {
        if shouldStop() { throw RPCError(.cancelled, "Codex request cancelled because the worker is stopping") }
    }

    private func connect(_ path: URL) throws {
        descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw RPCError.transport(String(cString: strerror(errno))) }
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        var noSigPipe: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw RPCError.transport("Codex control socket path is too long")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let limit = monotonic() + timeout
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        while true {
            try checkCancelled()
            guard monotonic() < limit else { throw RPCError.transport("Codex connection timed out") }
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(descriptor, $0, size) }
            }
            if result == 0 || errno == EISCONN { return }
            if errno == EAGAIN || errno == EWOULDBLOCK {
                usleep(useconds_t(min(0.25, max(0, limit - monotonic())) * 1_000_000))
                continue
            }
            guard errno == EINPROGRESS || errno == EALREADY || errno == EINTR else {
                throw RPCError.transport("[Errno \(errno)] \(String(cString: strerror(errno)))")
            }
            if try waitFor(Int16(POLLOUT), until: limit) {
                var error: Int32 = 0
                var length = socklen_t(MemoryLayout<Int32>.size)
                getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &error, &length)
                if error != 0 { throw RPCError.transport("[Errno \(error)] \(String(cString: strerror(error)))") }
                return
            }
        }
    }

    /// Polls for at most a quarter second; returns whether the socket became ready.
    private func waitFor(_ events: Int16, until limit: Double) throws -> Bool {
        var entry = pollfd(fd: descriptor, events: events, revents: 0)
        let slice = max(0, min(0.25, limit - monotonic()))
        let result = poll(&entry, 1, Int32(slice * 1000))
        if result < 0 && errno != EINTR { throw RPCError.transport(String(cString: strerror(errno))) }
        return result > 0
    }

    private func currentDeadline() -> Double { deadline ?? monotonic() + timeout }

    private func sendBytes(_ payload: [UInt8]) throws {
        try checkCancelled()
        let limit = currentDeadline()
        var offset = 0
        while offset < payload.count {
            try checkCancelled()
            guard monotonic() < limit else { throw RPCError.transport("Codex send deadline exceeded") }
            let sent = payload.withUnsafeBytes { write(descriptor, $0.baseAddress! + offset, payload.count - offset) }
            if sent > 0 { offset += sent; continue }
            if sent == 0 { throw RPCError.transport("Codex control socket closed during send") }
            guard errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR else {
                throw RPCError.transport("[Errno \(errno)] \(String(cString: strerror(errno)))")
            }
            _ = try waitFor(Int16(POLLOUT), until: limit)
        }
    }

    private func receive() throws {
        try checkCancelled()
        let limit = currentDeadline()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            try checkCancelled()
            guard monotonic() < limit else { throw RPCError.transport("Codex response deadline exceeded") }
            let count = chunk.withUnsafeMutableBytes { read(descriptor, $0.baseAddress!, $0.count) }
            if count > 0 {
                try checkCancelled()
                buffer.append(contentsOf: chunk[..<count])
                return
            }
            if count == 0 { throw RPCError.transport("Codex control socket closed") }
            guard errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR else {
                throw RPCError.transport("[Errno \(errno)] \(String(cString: strerror(errno)))")
            }
            _ = try waitFor(Int16(POLLIN), until: limit)
        }
    }

    private func readBytes(_ count: Int) throws -> [UInt8] {
        try checkCancelled()
        while buffer.count < count { try receive() }
        let result = Array(buffer[..<count])
        buffer.removeFirst(count)
        return result
    }

    private func sendFrame(_ opcode: UInt8, _ payload: [UInt8]) throws {
        var frame: [UInt8] = [0x80 | opcode]
        let size = payload.count
        if size < 126 {
            frame.append(0x80 | UInt8(size))
        } else if size < 65536 {
            frame.append(0x80 | 126)
            frame += [UInt8(size >> 8), UInt8(size & 0xFF)]
        } else {
            frame.append(0x80 | 127)
            frame += (0..<8).reversed().map { UInt8((UInt64(size) >> (UInt64($0) * 8)) & 0xFF) }
        }
        var mask = [UInt8](repeating: 0, count: 4)
        _ = SecRandomCopyBytes(kSecRandomDefault, 4, &mask)
        frame += mask
        frame += payload.enumerated().map { $0.element ^ mask[$0.offset % 4] }
        try sendBytes(frame)
    }

    private func sendJSON(_ value: JSON) throws {
        try sendFrame(1, Array(try value.serialized().utf8))
    }

    private func message() throws -> JSON {
        var chunks: [UInt8] = []
        var started = false
        while true {
            let head = try readBytes(2)
            let final = head[0] & 0x80 != 0, opcode = head[0] & 0x0F
            if head[0] & 0x70 != 0 { throw RPCError.transport("Unsupported WebSocket extension") }
            var size = UInt64(head[1] & 0x7F)
            if size == 126 {
                size = try readBytes(2).reduce(0) { $0 << 8 | UInt64($1) }
            } else if size == 127 {
                size = try readBytes(8).reduce(0) { $0 << 8 | UInt64($1) }
            }
            if size > 32 * 1024 * 1024 { throw RPCError.transport("Oversized WebSocket message") }
            let mask = head[1] & 0x80 != 0 ? try readBytes(4) : nil
            var payload = try readBytes(Int(size))
            if let mask { payload = payload.enumerated().map { $0.element ^ mask[$0.offset % 4] } }
            switch opcode {
            case 8: throw RPCError.transport("Codex closed the WebSocket connection")
            case 9: try sendFrame(10, payload); continue
            case 10: continue
            default: break
            }
            if opcode == 1 && !started {
                started = true
            } else if opcode != 0 || !started {
                throw RPCError.transport("Unexpected WebSocket frame")
            }
            chunks += payload
            if chunks.count > 32 * 1024 * 1024 { throw RPCError.transport("Oversized WebSocket message") }
            if final {
                do {
                    return try JSON.parse(Data(chunks))
                } catch {
                    throw RPCError.transport("Codex sent invalid JSON")
                }
            }
        }
    }

    public func call(_ method: String, _ params: JSON) throws -> JSON {
        sequence += 1
        let id = sequence
        try sendJSON(["id": .int(id), "method": .string(method), "params": params])
        deadline = monotonic() + 15
        defer { deadline = nil }
        while monotonic() < deadline! {
            let value = try message()
            if value["id"] == .int(id) && value["method"] == nil {
                if let error = value["error"] {
                    throw RPCError.request("\(method): \(error["message"]?.string ?? "RPC failed")")
                }
                return value["result"] ?? .null
            }
            // Leave interactive requests to the user's Codex client. Even an
            // error reply could resolve an approval that belongs to the UI.
            events.append(value)
            if events.count > 100 { events.removeFirst(events.count - 100) }
        }
        throw RPCError.transport("\(method): response deadline exceeded")
    }
}

public func monotonic() -> Double {
    Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1_000_000_000
}
