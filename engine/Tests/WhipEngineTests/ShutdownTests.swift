// Ported from tests/test_shutdown.py: SIGTERM checks against a stalled local protocol stub.
// The worker runs as the built `codex-whip` executable with a temporary state directory and a
// temporary Codex home whose control socket is served by the stub below. No real Codex is used.

import CryptoKit
import Foundation
import Testing
@testable import WhipEngine

/// A local stand-in for Codex's control socket that answers just far enough, then stalls.
final class StalledCodexStub: @unchecked Sendable {
    enum Phase {
        /// Reads the upgrade request and never answers it.
        case handshake
        /// Accepts the upgrade, reads `initialize`, and never answers it.
        case initialize
        /// Answers `initialize`, reads `initialized` and `thread/loaded/list`, and never answers.
        case rpc
        /// Answers `initialize` and every `thread/loaded/list` with no sessions.
        case serve
    }

    let socketPath: String
    let phase: Phase
    let ready = DispatchSemaphore(value: 0)
    private let done = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var listener: Int32 = -1
    private var finished = false
    private var failures: [String] = []
    private var received: [String] = []

    init(socketPath: String, phase: Phase) throws {
        self.socketPath = socketPath
        self.phase = phase
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw WhipError("socket failed") }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { throw WhipError("socket path too long") }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(listener, 1) == 0 else { throw WhipError("bind failed: \(String(cString: strerror(errno)))") }
        let thread = Thread { [self] in
            serve()
            done.signal()
        }
        thread.start()
    }

    var errors: [String] {
        lock.lock()
        defer { lock.unlock() }
        return failures
    }

    var methods: [String] {
        lock.lock()
        defer { lock.unlock() }
        return received
    }

    private var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }

    func stop() {
        lock.lock()
        finished = true
        lock.unlock()
        _ = done.wait(timeout: .now() + 2)
        if listener >= 0 { close(listener) }
        listener = -1
    }

    private struct Closed: Error {}

    private func fail(_ message: String) {
        lock.lock()
        failures.append(message)
        lock.unlock()
    }

    private func note(_ method: String) {
        lock.lock()
        received.append(method)
        lock.unlock()
    }

    /// Waits in quarter-second slices so `stop()` is noticed.
    private func waitReadable(_ descriptor: Int32, seconds: Double) throws -> Bool {
        let limit = Date().addingTimeInterval(seconds)
        while Date() < limit {
            if isFinished { throw Closed() }
            var entry = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            if poll(&entry, 1, 250) > 0 { return true }
        }
        return false
    }

    private func readExact(_ connection: Int32, _ size: Int) throws -> [UInt8] {
        var value: [UInt8] = []
        while value.count < size {
            guard try waitReadable(connection, seconds: 10) else { throw WhipError("Timed out reading from the helper") }
            var chunk = [UInt8](repeating: 0, count: size - value.count)
            let count = read(connection, &chunk, chunk.count)
            if count <= 0 { throw WhipError("Helper closed its connection") }
            value += chunk[..<count]
        }
        return value
    }

    private func readFrame(_ connection: Int32) throws -> JSON {
        let head = try readExact(connection, 2)
        guard head[0] == 0x81, head[1] & 0x80 != 0 else { throw WhipError("Expected a masked WebSocket text frame") }
        var size = Int(head[1] & 0x7F)
        if size == 126 {
            size = try readExact(connection, 2).reduce(0) { $0 << 8 | Int($1) }
        } else if size == 127 {
            size = try readExact(connection, 8).reduce(0) { $0 << 8 | Int($1) }
        }
        let mask = try readExact(connection, 4)
        let payload = try readExact(connection, size).enumerated().map { $0.element ^ mask[$0.offset % 4] }
        let value = try JSON.parse(Data(payload))
        note(value["method"]?.string ?? "")
        return value
    }

    private func sendFrame(_ connection: Int32, _ value: JSON) throws {
        let payload = Array(try value.serialized().utf8)
        guard payload.count < 126 else { throw WhipError("Test response unexpectedly needs an extended length") }
        let frame = [0x81, UInt8(payload.count)] + payload
        guard write(connection, frame, frame.count) == frame.count else { throw WhipError("Short write") }
    }

    private func serve() {
        var connection: Int32 = -1
        defer { if connection >= 0 { close(connection) } }
        do {
            guard try waitReadable(listener, seconds: 10) else { throw WhipError("Helper never connected") }
            connection = accept(listener, nil, nil)
            guard connection >= 0 else { throw WhipError("accept failed") }
            var noSigPipe: Int32 = 1
            setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            var headers: [UInt8] = []
            while !headers.suffix(4).elementsEqual([13, 10, 13, 10]) {
                headers += try readExact(connection, 1)
            }
            if phase != .handshake {
                let lines = String(decoding: headers, as: UTF8.self).components(separatedBy: "\r\n").dropFirst()
                var parsed: [String: String] = [:]
                for line in lines {
                    guard let colon = line.firstIndex(of: ":") else { continue }
                    parsed[String(line[..<colon])] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                }
                guard let key = parsed["Sec-WebSocket-Key"] else { throw WhipError("No Sec-WebSocket-Key") }
                let digest = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8)))
                    .base64EncodedString()
                let response = Array(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                    + "Sec-WebSocket-Accept: \(digest)\r\n\r\n").utf8)
                guard write(connection, response, response.count) == response.count else { throw WhipError("Short write") }
                let initialize = try readFrame(connection)
                guard initialize["method"] == "initialize" else { throw WhipError("Expected initialize, got \(initialize)") }
                if phase == .rpc || phase == .serve {
                    try sendFrame(connection, ["id": initialize["id"] ?? .null, "result": [:]])
                    let initialized = try readFrame(connection)
                    guard initialized["method"] == "initialized" else { throw WhipError("Expected initialized") }
                    let list = try readFrame(connection)
                    guard list["method"] == "thread/loaded/list" else { throw WhipError("Expected thread/loaded/list") }
                    if phase == .serve {
                        try sendFrame(connection, ["id": list["id"] ?? .null, "result": ["data": []]])
                    }
                }
            }
            ready.signal()
            if phase == .serve {
                while true {
                    let request = try readFrame(connection)
                    guard request["method"] == "thread/loaded/list" else { throw WhipError("Unexpected \(request)") }
                    try sendFrame(connection, ["id": request["id"] ?? .null, "result": ["data": []]])
                }
            }
            // Stall: read and discard until the helper hangs up or the test finishes.
            while true {
                guard try waitReadable(connection, seconds: 3600) else { continue }
                var scratch = [UInt8](repeating: 0, count: 1024)
                if read(connection, &scratch, scratch.count) <= 0 { break }
            }
        } catch is Closed {
        } catch {
            if !isFinished {
                fail(describe(error))
                ready.signal()
            }
        }
    }
}

/// Temporary directories and helpers for running the built `codex-whip` as a child process.
enum HelperProcess {
    static let engineDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// The executable `swift build` puts in .build/debug, built on demand.
    static func executable() throws -> URL {
        let built = engineDirectory.appendingPathComponent(".build/debug/codex-whip")
        if !FileManager.default.isExecutableFile(atPath: built.path) {
            let build = Process()
            build.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            build.arguments = ["swift", "build", "--product", "codex-whip"]
            build.currentDirectoryURL = engineDirectory
            try build.run()
            build.waitUntilExit()
        }
        guard FileManager.default.isExecutableFile(atPath: built.path) else {
            throw WhipError("Build the helper first: cd engine && swift build")
        }
        return built
    }

    /// A short directory under /tmp, so socket paths stay within the Unix-socket limit.
    static func temporaryDirectory(_ prefix: String = "ckg-stop-") throws -> URL {
        var template = Array("/tmp/\(prefix)XXXXXX".utf8CString)
        guard let made = mkdtemp(&template) else { throw WhipError("mkdtemp failed") }
        return Paths.resolve(String(cString: made))
    }

    /// A minimal environment that never carries the caller's parent-monitoring or Codex settings.
    static func environment(_ extra: [String: String] = [:]) -> [String: String] {
        var value: [String: String] = [:]
        for key in ["PATH", "HOME", "TMPDIR", "USER", "LOGNAME"] {
            if let item = ProcessInfo.processInfo.environment[key] { value[key] = item }
        }
        return value.merging(extra) { $1 }
    }

    static func waitUntil(_ seconds: Double, _ condition: () -> Bool) -> Bool {
        let limit = Date().addingTimeInterval(seconds)
        while Date() < limit {
            if condition() { return true }
            usleep(20_000)
        }
        return condition()
    }

    /// Whether another open file description holds the worker lock.
    static func lockHeld(_ directory: URL) -> Bool {
        let descriptor = open(directory.appendingPathComponent("worker.lock").path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
            flock(descriptor, LOCK_UN)
            return false
        }
        return errno == EWOULDBLOCK
    }

    static func writeState(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let state: JSON = ["version": 1, "enabled_at": .double(Date().timeIntervalSince1970), "threads": [],
                           "pending": [:], "handled": [:], "paused": [:], "last_error": nil]
        try Data(try state.serialized().utf8).write(to: directory.appendingPathComponent("state.json"))
    }

    static func events(_ directory: URL) -> [JSON] {
        let text = (try? String(contentsOf: directory.appendingPathComponent("worker.log"), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").compactMap { try? JSON.parse(String($0)) }
    }
}

@Suite struct ShutdownTests {
    func stalledShutdown(_ phase: StalledCodexStub.Phase) throws {
        let root = try HelperProcess.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let stateDirectory = root.appendingPathComponent("state")
        try HelperProcess.writeState(stateDirectory)
        let codexHome = root.appendingPathComponent("codex")
        let socketPath = codexHome.appendingPathComponent("app-server-control/app-server-control.sock")
        try FileManager.default.createDirectory(at: socketPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        let stub = try StalledCodexStub(socketPath: socketPath.path, phase: phase)
        defer { stub.stop() }
        let process = Process()
        process.executableURL = try HelperProcess.executable()
        process.arguments = ["--state-dir", stateDirectory.path, "--codex-home", codexHome.path, "_run"]
        process.environment = HelperProcess.environment(["CODEX_WHIP_PARENT_PID": String(getpid())])
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer { if process.isRunning { kill(process.processIdentifier, SIGKILL); process.waitUntilExit() } }

        #expect(stub.ready.wait(timeout: .now() + 15) == .success, "Helper did not reach the stalled protocol phase")
        #expect(stub.errors.isEmpty, "\(stub.errors)")
        try #require(stub.errors.isEmpty)
        #expect(HelperProcess.lockHeld(stateDirectory))
        let started = Date()
        process.terminate()
        #expect(HelperProcess.waitUntil(2) { !process.isRunning }, "Worker did not exit after SIGTERM")
        #expect(HelperProcess.waitUntil(1.5 - Date().timeIntervalSince(started)) { !HelperProcess.lockHeld(stateDirectory) },
                "Worker kept its lock after shutdown")
        let elapsed = Date().timeIntervalSince(started)
        #expect(elapsed < 1.5, "Shutdown took \(elapsed)s")
        #expect(!FileManager.default.fileExists(atPath: stateDirectory.appendingPathComponent("worker.pid").path))
        let saved = try FileStore.readJSON(stateDirectory.appendingPathComponent("state.json"))
        #expect((saved["last_error"] ?? .null) == .null)
        let events = HelperProcess.events(stateDirectory)
        #expect(!events.contains { $0["event"] == "connection_error" }, "\(events)")
        #expect(events.last?["event"] == "stopped", "\(events)")
    }

    // test_sigterm_interrupts_stalled_handshake_and_releases_worker_lock
    @Test func sigtermInterruptsStalledHandshakeAndReleasesWorkerLock() throws {
        try stalledShutdown(.handshake)
    }

    // test_sigterm_interrupts_stalled_initialize_and_releases_worker_lock
    @Test func sigtermInterruptsStalledInitializeAndReleasesWorkerLock() throws {
        try stalledShutdown(.initialize)
    }

    // test_sigterm_interrupts_stalled_metadata_rpc_and_releases_worker_lock
    @Test func sigtermInterruptsStalledMetadataRPCAndReleasesWorkerLock() throws {
        try stalledShutdown(.rpc)
    }
}
