// Ported from tests/test_sound.py. Retry audio checks use fake players and RPCs, never real sounds or sessions.
import Foundation
import Testing
@testable import WhipEngine

/// The bundled clip in the source tree, used as the sound file so no lookup depends on the test runner.
private let soundFile = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Sources/WhipEngine/Resources/whip.wav")

/// Records every playback; the player runs on the sound queue, so access is locked.
final class SoundTestRecorder {
    private let lock = NSLock()
    private var items: [URL] = []
    var played: [URL] { lock.lock(); defer { lock.unlock() }; return items }
    func append(_ url: URL) { lock.lock(); items.append(url); lock.unlock() }
}

private func userThread(_ id: String = "user-session") -> JSON {
    ["id": .string(id), "model": "keep-this-model", "reasoningEffort": "xhigh", "status": ["type": "idle"],
     "source": "vscode", "originator": "codex-tui", "parentThreadId": .null, "threadSource": "user",
     "canAcceptDirectInput": true]
}

private func capacityTurn(_ id: String = "capacity-failure", completedAt: Double = 1100) -> JSON {
    ["id": .string(id), "status": "failed",
     "error": ["codexErrorInfo": "serverOverloaded", "message": .string(capacityMessage)],
     "completedAt": .double(completedAt)]
}

private func quotaTurn(_ id: String = "quota-failure", completedAt: Double = 1100) -> JSON {
    var turn = capacityTurn(id, completedAt: completedAt)
    turn["error"] = ["codexErrorInfo": "usageLimitExceeded", "message": "Usage limit reached"]
    return turn
}

/// Port of test_core.FakeRPC.
class SoundFakeRPC: RPCClient {
    var threads: [String: JSON] = ["user-session": userThread()]
    var turns: [String: JSON] = ["user-session": capacityTurn()]
    var loaded = ["user-session"]
    var calls: [(String, JSON)] = []
    var sendError: RPCError?

    func call(_ method: String, _ params: JSON) throws -> JSON {
        calls.append((method, params))
        if method == "thread/loaded/list" {
            return ["data": .array(loaded.map(JSON.string)), "nextCursor": .null]
        }
        let threadID = params["threadId"]?.string ?? ""
        switch method {
        case "thread/read":
            return ["thread": threads[threadID] ?? .null]
        case "thread/turns/list":
            return ["data": turns[threadID].map { [$0] } ?? [], "nextCursor": .null]
        case "turn/start":
            if let sendError { throw sendError }
            return ["turn": ["id": "retry-turn", "status": "inProgress"]]
        default:
            Issue.record("Unexpected RPC: \(method)")
            throw RPCError.request("Unexpected RPC: \(method)")
        }
    }

    func sends() -> [JSON] { calls.filter { $0.0 == "turn/start" }.map(\.1) }
}

/// Port of test_quota.QuotaRPC.
final class SoundQuotaRPC: SoundFakeRPC {
    var quota: JSON = ["accountId": "private-account-A", "ordinaryUsageAllowed": false,
                       "rateLimits": ["primary": ["usedPercent": 100, "resetsAt": 9999999999]]]

    override init() {
        super.init()
        turns["user-session"] = quotaTurn()
    }

    override func call(_ method: String, _ params: JSON) throws -> JSON {
        guard method == "account/rateLimits/read" else { return try super.call(method, params) }
        calls.append((method, params))
        return quota
    }
}

@Suite final class SoundTests {
    let recorder = SoundTestRecorder()
    var sound: RetrySound
    var state = RetryState(enabledAt: 1000)
    var engine: RetryEngine!

    init() throws {
        let recorder = self.recorder
        sound = RetrySound(file: soundFile, player: { recorder.append($0) })
        engine = try makeEngine(state)
    }

    deinit { sound.close() }

    func makeEngine(_ state: RetryState) throws -> RetryEngine {
        try RetryEngine(state: state, save: { _ in }, emit: { [unowned self] event, _ in self.sound.report(event) },
                        interval: 180, scanInterval: 300)
    }

    var played: [URL] { recorder.played }

    @discardableResult
    func retry(_ rpc: SoundFakeRPC = SoundFakeRPC()) throws -> SoundFakeRPC {
        try engine.step(rpc, now: 1100)
        try engine.step(rpc, now: 1280)
        return rpc
    }

    // test_sound_is_off_until_explicitly_enabled_and_does_not_replay_when_enabled
    @Test func soundIsOffUntilExplicitlyEnabledAndDoesNotReplayWhenEnabled() throws {
        let rpc = try retry()
        #expect(rpc.sends().count == 1)
        sound.drain()
        #expect(played == [])
        sound.configure(true)
        try engine.step(rpc, now: 1580)
        sound.drain()
        #expect(played == [])
    }

    // test_confirmed_capacity_retry_sounds_once_without_detection_or_history_replay
    @Test func confirmedCapacityRetrySoundsOnceWithoutDetectionOrHistoryReplay() throws {
        sound.configure(true)
        let rpc = SoundFakeRPC()
        try engine.step(rpc, now: 1100)
        sound.drain()
        #expect(played == [])
        try engine.step(rpc, now: 1280)
        sound.drain()
        #expect(played == [soundFile])
        try engine.step(rpc, now: 1580)
        // Python passed a Mock history; Swift needs a real store, kept in a temporary directory.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sound-history-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = try History(directory: directory, clock: { 1580 })
        defer { history.close() }
        try reconcileHistory(state, history, now: 1580)
        for event in ["started", "waiting", "quota_waiting", "settings_changed", "retry_result", "uncertain", "stopped"] {
            sound.report(event)
        }
        sound.drain()
        #expect(played == [soundFile])
    }

    // test_quota_checks_stay_silent_until_a_confirmed_continuation
    @Test func quotaChecksStaySilentUntilAConfirmedContinuation() throws {
        sound.configure(true)
        let rpc = SoundQuotaRPC()
        try engine.step(rpc, now: 1100)
        try engine.step(rpc, now: 1400)
        sound.drain()
        #expect(played == [])
        rpc.quota["ordinaryUsageAllowed"] = true
        try engine.step(rpc, now: 1700)
        sound.drain()
        #expect(rpc.sends().count == 1)
        #expect(played == [soundFile])
    }

    // test_failed_or_uncertain_submission_stays_silent_including_after_restart
    @Test func failedOrUncertainSubmissionStaysSilentIncludingAfterRestart() throws {
        sound.configure(true)
        let rpc = SoundFakeRPC()
        rpc.sendError = RPCError.transport("Response lost")
        #expect(throws: RPCError.self) { try self.retry(rpc) }
        sound.drain()
        #expect(played == [])
        engine = try makeEngine(try RetryState(json: state.json))
        rpc.sendError = nil
        try engine.step(rpc, now: 2000)
        sound.drain()
        #expect(played == [])
        #expect(rpc.sends().count == 1)
    }

    // test_playback_does_not_block_retries_and_disabling_drops_queued_sounds
    @Test func playbackDoesNotBlockRetriesAndDisablingDropsQueuedSounds() throws {
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let recorder = self.recorder
        sound.close()
        sound = RetrySound(file: soundFile, player: { url in
            recorder.append(url)
            started.signal()
            _ = release.wait(timeout: .now() + 2)
        })
        defer { release.signal() }
        sound.configure(true)
        let rpc = try retry()
        #expect(rpc.sends().count == 1)
        #expect(started.wait(timeout: .now() + 1) == .success)
        sound.report("retry")
        sound.configure(false)
        sound.configure(true)
        release.signal()
        sound.drain()
        #expect(played == [soundFile])
        sound.report("retry")
        // The second playback waits on release again; let it finish promptly.
        release.signal()
        sound.drain()
        #expect(played == [soundFile, soundFile])
    }

    // test_broken_audio_player_cannot_fail_the_retry_or_the_next_sound
    // Swift's player is `(URL) -> Void` and cannot throw, so "broken" here is a player that
    // records the call and plays nothing, as RetrySound.play does when afplay cannot start.
    @Test func brokenAudioPlayerCannotFailTheRetryOrTheNextSound() throws {
        let called = SoundTestRecorder()
        sound.close()
        sound = RetrySound(file: soundFile, player: { called.append($0) })
        sound.configure(true)
        let rpc = try retry()
        sound.drain()
        #expect(state.handled["user-session"]?.outcome == "submitted")
        #expect(rpc.sends().count == 1)
        sound.report("retry")
        sound.drain()
        #expect(called.played == [soundFile, soundFile])
    }

    // test_thread_start_failure_preserves_the_accepted_retry_and_allows_later_audio is not ported:
    // Swift plays through a dispatch queue, which cannot fail to start the way a Python thread can.

    // test_bundled_clip_is_short_original_pcm_and_player_uses_current_output_volume (file half)
    @Test func bundledClipIsShortOriginalPCM() throws {
        let data = try Data(contentsOf: soundFile)
        func u16(_ offset: Int) -> Int { Int(data[offset]) | Int(data[offset + 1]) << 8 }
        func u32(_ offset: Int) -> Int { u16(offset) | u16(offset + 2) << 16 }
        #expect(String(decoding: data[0..<4], as: UTF8.self) == "RIFF")
        #expect(String(decoding: data[8..<12], as: UTF8.self) == "WAVE")
        var channels = 0, sampleWidth = 0, rate = 0, format = 0, dataBytes = -1
        var offset = 12
        while offset + 8 <= data.count {
            let id = String(decoding: data[offset..<offset + 4], as: UTF8.self)
            let size = u32(offset + 4)
            if id == "fmt " {
                format = u16(offset + 8)
                channels = u16(offset + 10)
                rate = u32(offset + 12)
                sampleWidth = u16(offset + 22) / 8
            } else if id == "data" {
                dataBytes = size
            }
            offset += 8 + size + (size % 2)
        }
        #expect(format == 1)
        #expect(channels == 1)
        #expect(sampleWidth == 2)
        let frames = Double(dataBytes) / Double(channels * sampleWidth)
        // Python assertAlmostEqual: equal when rounded to 7 places.
        #expect(abs(frames / Double(rate) - 0.55) < 5e-8)
    }

    // test_bundled_clip_is_short_original_pcm_and_player_uses_current_output_volume (player half)
    // test_bundled_clip_is_short_original_pcm_and_player_uses_current_output_volume (player half)
    @Test func playerUsesCurrentOutputVolume() throws {
        let file = URL(fileURLWithPath: "/tmp/whip.wav")
        let command = RetrySound.playCommand(file)
        #expect(command.executable == "/usr/bin/afplay")
        #expect(command.arguments == ["-v", "0.4", file.path])
        #expect(command.timeout == 2)
    }

    // WorkerSoundTests.test_saved_sound_toggle_is_live_and_only_new_submissions_sound is in WorkerLoopTests.swift.
}
