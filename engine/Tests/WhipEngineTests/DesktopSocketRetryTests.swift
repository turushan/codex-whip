import Foundation
import Testing
@testable import WhipEngine

// Port of tests/test_desktop_socket_retry.py: the real DesktopIPC transport (DesktopRPC's
// default factory), the adapter and the retry engine against a local fake app. The fake app is
// DesktopPeerStub from DesktopBackendTests.swift, set to write fragmented frames and to name
// each binding "fresh-client-N", as the Python server does.

@Suite struct DesktopSocketRetryTests {
    // test_capacity_retry_round_trip_uses_real_framing_and_preserves_write_ahead
    @Test func capacityRetryRoundTripUsesRealFramingAndPreservesWriteAhead() throws {
        let desktop = try DesktopPeerStub()
        defer { desktop.stop() }
        desktop.fragmented = true
        desktop.clientPrefix = "fresh-client-"
        let metadata = MetadataPeerStub()
        let state = RetryState(enabledAt: 1000)
        // The Python server asserts these inside its thread; they are recorded there and
        // checked here.
        var observed: [(outcome: String?, saved: String?, sent: JSON?)] = []
        desktop.beforeStart = { params in
            let attempt = state.handled["thread"]
            observed.append((attempt?.outcome, attempt?.clientMessageID,
                             params[backendPath: ["turnStart", "request", "clientUserMessageId"]]))
        }
        let backend = try DesktopRPC(socketPath: desktop.path, metadata: metadata, threadIDs: ["thread"])
        defer { backend.close() }
        let engine = try RetryEngine(state: state, save: { _ in }, emit: { _, _ in }, interval: 180, threads: ["thread"])
        try engine.step(backend, now: 1100)
        #expect(desktop.starts.isEmpty)
        try engine.step(backend, now: 1280)
        #expect(desktop.starts.count == 1)
        #expect(observed.count == 1)
        #expect(observed.first?.outcome == "uncertain")
        #expect(observed.first.map { $0.saved != nil && JSON($0.saved) == $0.sent } == true)
        let start = try #require(desktop.starts.first)
        #expect(start.options["version"] == 2)
        #expect(start.options["target"] == "owner")
        #expect(start.params[backendPath: ["turnStart", "context"]] == ["inheritThreadSettings": true])
        #expect(state.handled["thread"]?.outcome == "submitted")
        #expect(state.handled["thread"]?.retryTurnID == "retry-turn")
        #expect(metadata.calls.allSatisfy { $0.method == "thread/turns/list" })
        #expect(desktop.connections.allSatisfy { $0.clientID.hasPrefix("fresh-client-") })
        #expect(desktop.cleanConnections())
        #expect(desktop.failures.isEmpty)
    }
}
