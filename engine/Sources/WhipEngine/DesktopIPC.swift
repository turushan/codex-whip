import Foundation

/// Stable error codes with public-safe text; never includes a remote payload.
public struct DesktopIPCError: Error, CustomStringConvertible, LocalizedError {
    static let messages = [
        "unavailable": "Desktop's local connection is unavailable.",
        "closed": "Desktop's local connection is closed.",
        "disconnected": "Desktop's local connection ended.",
        "cancelled": "Desktop's local request was cancelled.",
        "timeout": "Desktop's local request timed out.",
        "invalid-request": "The Desktop request is invalid.",
        "invalid-response": "Desktop returned an unsupported response.",
        "malformed-frame": "Desktop returned an invalid message.",
        "oversized-frame": "Desktop's local message exceeds the supported size.",
        "buffer-overflow": "Desktop sent too many pending messages.",
        "no-client-found": "The Desktop conversation has no active owner.",
        "method-not-found": "Desktop does not support this operation.",
        "unsupported-version": "Desktop does not support this protocol version.",
        "version-mismatch": "Desktop does not support this protocol version.",
        "request-timeout": "Desktop could not finish the local request in time.",
        "request-failed": "Desktop could not finish the local request.",
    ]

    public let code: String

    public init(_ code: String?) {
        self.code = code.flatMap { DesktopIPCError.messages[$0] != nil ? $0 : nil } ?? "request-failed"
    }

    public var description: String { DesktopIPCError.messages[code]! }
    public var errorDescription: String? { description }
}

/// A bounded local transport for Desktop's versioned coordination messages.
///
/// Only one caller reads the socket at a time. Requests can receive broadcasts or discovery
/// questions while waiting; those messages never become request results. Callers validate each
/// method's response and broadcast schema separately.
public final class DesktopIPC {
    static let maxFrameBytes = 16 * 1024 * 1024
    static let maxBufferedBytes = 32 * 1024 * 1024
    static let maxBufferedMessages = 128
    static let pollSeconds = 0.05

    public private(set) var clientID: String?
    private let timeout: Double
    private let shouldStop: () -> Bool
    private var descriptor: Int32 = -1
    private var closed = false
    private let operation = NSRecursiveLock()
    private var broadcasts: [(size: Int, message: JSON)] = []
    private var responses: [String: (size: Int, message: JSON)] = [:]
    private var bufferedBytes = 0

    public init(path: URL, timeout: Double = 12, shouldStop: @escaping () -> Bool = { false }) throws {
        self.timeout = try DesktopIPC.validTimeout(timeout)
        self.shouldStop = shouldStop
        do {
            descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
            guard descriptor >= 0 else { throw DesktopIPCError("unavailable") }
            _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
            var noSigPipe: Int32 = 1
            setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
            try connect(path, deadline: monotonic() + self.timeout)
            let response = try requestFull("initialize", ["clientType": "codex_whip"], version: 0, timeout: min(self.timeout, 5))
            guard let client = response["result"]?["clientId"]?.string, !client.isEmpty, client.count <= 512,
                  response["handledByClientId"]?.string == client else {
                try fatal("invalid-response")
            }
            clientID = client
        } catch {
            close()
            throw error
        }
    }

    deinit { close() }

    static func validTimeout(_ value: Double) throws -> Double {
        guard value.isFinite, value > 0 else { throw DesktopIPCError("invalid-request") }
        return value
    }

    private func check(_ deadline: Double) throws {
        if closed { throw DesktopIPCError("closed") }
        if shouldStop() { try fatal("cancelled") }
        if monotonic() >= deadline { try fatal("timeout") }
    }

    private func wait(_ deadline: Double, writable: Bool = false) throws {
        while true {
            try check(deadline)
            var entry = pollfd(fd: descriptor, events: Int16(writable ? POLLOUT : POLLIN), revents: 0)
            let slice = min(DesktopIPC.pollSeconds, max(0, deadline - monotonic()))
            let result = poll(&entry, 1, Int32((slice * 1000).rounded(.up)))
            if result < 0 && errno != EINTR { try fatal("disconnected") }
            if result > 0 {
                try check(deadline)
                return
            }
        }
    }

    private func connect(_ path: URL, deadline: Double) throws {
        try check(deadline)
        var metadata = stat()
        guard lstat(path.path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFSOCK, metadata.st_uid == getuid() else {
            try fatal("unavailable")
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { try fatal("unavailable") }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(descriptor, $0, size) }
        }
        if result != 0 && errno != EISCONN {
            guard [EINPROGRESS, EALREADY, EWOULDBLOCK].contains(errno) else { try fatal("unavailable") }
            try wait(deadline, writable: true)
            var error: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &error, &length)
            if error != 0 { try fatal("unavailable") }
        }
        var peer = sockaddr_un()
        var peerSize = socklen_t(MemoryLayout<sockaddr_un>.size)
        let named = withUnsafeMutablePointer(to: &peer) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getpeername(descriptor, $0, &peerSize) }
        }
        if named != 0 { try fatal("unavailable") }
    }

    private func fatal(_ code: String) throws -> Never {
        close()
        throw DesktopIPCError(code)
    }

    private func send(_ message: JSON, deadline: Double) throws {
        try check(deadline)
        let payload: [UInt8]
        do {
            payload = Array(try message.serialized(JSON.Format(sortKeys: false)).utf8)
        } catch {
            throw DesktopIPCError("invalid-request")
        }
        guard !payload.isEmpty, payload.count <= DesktopIPC.maxFrameBytes else { throw DesktopIPCError("oversized-frame") }
        let length = UInt32(payload.count)
        let data = [UInt8(length & 0xFF), UInt8((length >> 8) & 0xFF), UInt8((length >> 16) & 0xFF), UInt8(length >> 24)] + payload
        var offset = 0
        while offset < data.count {
            try check(deadline)
            let written = data.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress! + offset, data.count - offset) }
            if written > 0 { offset += written; continue }
            if written == 0 { try fatal("disconnected") }
            if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR {
                try wait(deadline, writable: true)
            } else {
                try fatal("disconnected")
            }
        }
    }

    private func readExact(_ size: Int, deadline: Double) throws -> [UInt8] {
        var data = [UInt8]()
        data.reserveCapacity(size)
        var chunk = [UInt8](repeating: 0, count: min(size, 65536))
        while data.count < size {
            try check(deadline)
            let wanted = min(size - data.count, chunk.count)
            let count = chunk.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress!, wanted) }
            if count > 0 { data += chunk[..<count]; continue }
            if count == 0 { try fatal("disconnected") }
            if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR {
                try wait(deadline)
            } else {
                try fatal("disconnected")
            }
        }
        return data
    }

    private func receive(deadline: Double) throws -> (Int, JSON) {
        let header = try readExact(4, deadline: deadline)
        let size = Int(header[0]) | Int(header[1]) << 8 | Int(header[2]) << 16 | Int(header[3]) << 24
        if size == 0 { try fatal("malformed-frame") }
        if size > DesktopIPC.maxFrameBytes { try fatal("oversized-frame") }
        let body = try readExact(size, deadline: deadline)
        guard let value = try? JSON.parse(Data(body), rejectDuplicateKeys: true), value.object != nil else {
            try fatal("malformed-frame")
        }
        return (size, value)
    }

    static func identifier(_ value: JSON?) -> Bool {
        guard let text = value?.string else { return false }
        return !text.isEmpty && text.count <= 512
    }

    private func route(_ size: Int, _ message: JSON, deadline: Double) throws {
        try check(deadline)
        let kind = message["type"]?.string
        if kind == "client-discovery-request" {
            guard DesktopIPC.identifier(message["requestId"]) else { try fatal("invalid-response") }
            try send(["type": "client-discovery-response", "requestId": message["requestId"]!,
                      "response": ["canHandle": false]], deadline: deadline)
            return
        }
        if kind == "response" {
            guard DesktopIPC.identifier(message["requestId"]),
                  ["success", "error"].contains(message["resultType"]?.string ?? ""),
                  responses[message["requestId"]!.string!] == nil else { try fatal("invalid-response") }
        } else if kind == "broadcast" {
            guard message["method"]?.nonemptyString != nil, message["version"]?.int != nil else { try fatal("invalid-response") }
        } else {
            try fatal("invalid-response")
        }
        if broadcasts.count + responses.count >= DesktopIPC.maxBufferedMessages
            || bufferedBytes + size > DesktopIPC.maxBufferedBytes {
            try fatal("buffer-overflow")
        }
        bufferedBytes += size
        if kind == "response" {
            responses[message["requestId"]!.string!] = (size, message)
        } else {
            broadcasts.append((size, message))
        }
    }

    private static func validateCall(_ method: String, _ params: JSON, _ version: Int) throws {
        guard !method.isEmpty, params.object != nil, version >= 0 else { throw DesktopIPCError("invalid-request") }
    }

    /// Returns the successful response envelope, keeping its owner identity.
    public func requestFull(_ method: String, _ params: JSON, version: Int = 1, target: String? = nil,
                            timeout given: Double? = nil) throws -> JSON {
        operation.lock()
        defer { operation.unlock() }
        let duration = try given.map(DesktopIPC.validTimeout) ?? timeout
        try DesktopIPC.validateCall(method, params, version)
        if let target, !DesktopIPC.identifier(.string(target)) { throw DesktopIPCError("invalid-request") }
        if method == "initialize" && clientID != nil { throw DesktopIPCError("invalid-request") }
        let deadline = monotonic() + duration
        let identifier = UUID().uuidString.lowercased()
        var message: JSON = ["type": "request", "requestId": .string(identifier),
                             "sourceClientId": .string(clientID ?? "initializing-client"),
                             "version": .int(version), "method": .string(method), "params": params,
                             "timeoutMs": .int(max(1, Int((duration * 1000).rounded(.up))))]
        if let target { message["targetClientId"] = .string(target) }
        try send(message, deadline: deadline)
        while responses[identifier] == nil {
            let (size, value) = try receive(deadline: deadline)
            try route(size, value, deadline: deadline)
        }
        let (size, response) = responses.removeValue(forKey: identifier)!
        bufferedBytes -= size
        if response["resultType"] == "error" { throw DesktopIPCError(response["error"]?.string) }
        if let answered = response["method"], answered != .string(method) { try fatal("invalid-response") }
        if let target, response["handledByClientId"]?.string != target { try fatal("invalid-response") }
        return response
    }

    public func request(_ method: String, _ params: JSON, version: Int = 1, target: String? = nil,
                        timeout: Double? = nil) throws -> JSON {
        try requestFull(method, params, version: version, target: target, timeout: timeout)["result"] ?? .null
    }

    public func broadcast(_ method: String, _ params: JSON, version: Int = 1, targets: [String]? = nil,
                          timeout given: Double? = nil) throws {
        operation.lock()
        defer { operation.unlock() }
        let duration = try given.map(DesktopIPC.validTimeout) ?? timeout
        try DesktopIPC.validateCall(method, params, version)
        var message: JSON = ["type": "broadcast", "sourceClientId": JSON(clientID), "version": .int(version),
                             "method": .string(method), "params": params]
        if let targets {
            guard targets.allSatisfy({ DesktopIPC.identifier(.string($0)) }) else { throw DesktopIPCError("invalid-request") }
            message["targetClientIds"] = .array(targets.map(JSON.string))
        }
        try send(message, deadline: monotonic() + duration)
    }

    public func waitBroadcast(timeout given: Double? = nil, _ predicate: (JSON) -> Bool) throws -> JSON {
        operation.lock()
        defer { operation.unlock() }
        let duration = try given.map(DesktopIPC.validTimeout) ?? timeout
        let deadline = monotonic() + duration
        while true {
            try check(deadline)
            if let index = broadcasts.firstIndex(where: { predicate($0.message) }) {
                let (size, message) = broadcasts.remove(at: index)
                bufferedBytes -= size
                return message
            }
            let (size, value) = try receive(deadline: deadline)
            try route(size, value, deadline: deadline)
        }
    }

    public func close() {
        if closed { return }
        closed = true
        if descriptor >= 0 {
            shutdown(descriptor, SHUT_RDWR)
            Darwin.close(descriptor)
            descriptor = -1
        }
        broadcasts.removeAll()
        responses.removeAll()
        bufferedBytes = 0
    }
}
