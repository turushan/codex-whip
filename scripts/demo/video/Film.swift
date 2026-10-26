import Foundation

// The storyboard: one place for every timing, line of copy and sound cue.
// Sections sit on the 120 BPM bar grid (one bar = 2 s) shared with the score.

struct Settings {
    let message: String
    let retrySeconds: Int
    let checkSeconds: Int
}

struct Section { let name: String; let start: Double; let end: Double }

struct Caption {
    let start: Double, end: Double
    let lines: [[(String, RGBA)]]
    let subtitle: String?
    var lineDelays: [Double] = []
}

struct Cue {
    let time: Double
    let type: String
    var extra: [String: Any] = [:]
}

enum StrikeSpace { case stage, screen }

struct StrikePlan {
    let impact: Double
    let target: V2
    let aim: Double
    let hero: Bool
}

struct WhipPass {
    let enter: Double, exit: Double
    let space: StrikeSpace
    let strikes: [StrikePlan]
}

enum LogKind { case user, step, error, warn, success, dim }

struct LogLine {
    let time: Double
    let kind: LogKind
    let text: String
    var typing: Double = 0.32
}

final class Film {
    static let duration = 60.0
    static let fps = 60
    static let bpm = 120.0

    let settings: Settings
    let sections = [
        Section(name: "night", start: 0, end: 4), Section(name: "stop", start: 4, end: 8),
        Section(name: "reveal", start: 8, end: 12), Section(name: "capacity", start: 12, end: 22),
        Section(name: "quota", start: 22, end: 32), Section(name: "reset", start: 32, end: 42),
        Section(name: "morning", start: 42, end: 52), Section(name: "outro", start: 52, end: 60),
    ]
    // One chord per bar; the score voices them.
    let chords = ["Dm9", "Bbmaj9", "N.C.", "N.C.", "Dm9", "Bbmaj9", "F/A", "Cadd9", "Dm9", "Bbmaj9",
                  "F/A", "Cadd9", "Dm9", "Bbmaj9", "F/A", "Cadd9", "Dm9", "Bbmaj9", "F/A", "Cadd9",
                  "Dm9", "Fmaj9", "C/E", "Dm9", "Bbmaj9", "Gm9", "Bbmaj9", "Csus4-C", "Fmaj9", "Fmaj9"]

    // Story beats.
    let stop = 4.0
    let reveal = 8.0
    let retryCountdown = (start: 12.6, end: 15.0)
    let capacityStrikes = [16.0, 17.0, 18.0]
    let capacitySend = 18.5, capacityResume = 19.0
    let quotaLapse = (start: 22.0, end: 22.8)
    let quotaChecks = [24.5, 26.5]
    let quotaConfirm = 26.8, quotaStrike = 28.0, quotaSend = 28.3, quotaResume = 28.8
    let resetLapse = (start: 32.0, end: 32.8)
    let postEnters = 33.6, postLeaves = 36.4
    let resetCheck = 36.5, resetConfirm = 36.8, resetStrike = 38.0, resetSend = 38.3, resetResume = 38.8
    let morningLapse = (start: 42.0, end: 42.8)
    let activityEnters = 45.4, activityLeaves = 51.9
    let menuClick = 48.2, submenuOpens = 49.4, menuCloses = 51.0
    let finale = 52.0, ctaEnters = 53.6, finalHit = 56.0

    // Clock minutes after midnight for each overnight event.
    // Whip finds a failure on its next check, then waits the retry interval from there.
    let capacityAt = 2 * 60 + 14.0
    let capacityFoundAt = 2 * 60 + 15.0
    var retryAt: Double { capacityFoundAt + Double(settings.retrySeconds) / 60 }
    let quotaAt = 4 * 60 + 52.0
    var quotaCheckTimes: [Double] { [quotaAt + Double(settings.checkSeconds) / 60, quotaAt + 2 * Double(settings.checkSeconds) / 60] }
    let resetAt = 6 * 60 + 31.0
    let postAt = 6 * 60 + 33.0
    var resetCheckAt: Double { resetAt + Double(settings.checkSeconds) / 60 }
    let morningAt = 7 * 60 + 58.0

    init(settings: Settings) {
        self.settings = settings
    }

    func section(at t: Double) -> Section {
        sections.last(where: { t >= $0.start }) ?? sections[0]
    }

    /// The menu bar clock, in minutes after midnight, with compressed waits.
    func clock(at t: Double) -> Double {
        let keys: [(Double, Double)] = [
            (0, capacityAt - 1), (3.6, capacityAt - 1), (3.7, capacityAt),
            (12.3, capacityAt), (12.45, capacityFoundAt),
            (retryCountdown.start, capacityFoundAt), (retryCountdown.end, retryAt),
            (quotaLapse.start, retryAt), (quotaLapse.end, quotaAt),
            (quotaLapse.end + 0.3, quotaAt), (quotaChecks[0], quotaCheckTimes[0]),
            (quotaChecks[0] + 0.25, quotaCheckTimes[0]), (quotaChecks[1], quotaCheckTimes[1]),
            (resetLapse.start, quotaCheckTimes[1]), (resetLapse.end, resetAt),
            (postEnters, postAt), (postEnters + 0.2, postAt), (resetCheck, resetCheckAt),
            (morningLapse.start, resetCheckAt), (morningLapse.end, morningAt), (Film.duration, morningAt + 1),
        ]
        guard let index = keys.lastIndex(where: { $0.0 <= t }) else { return keys[0].1 }
        if index == keys.count - 1 { return keys[index].1 }
        let a = keys[index], b = keys[index + 1]
        let u = (t - a.0) / max(1e-6, b.0 - a.0)
        // Time-lapses accelerate and settle; compressed waits run evenly.
        let lapse = [quotaLapse.start, resetLapse.start, morningLapse.start].contains(a.0)
        return mix(a.1, b.1, lapse ? smoother(u) : u)
    }

    // MARK: Copy

    var captions: [Caption] {
        let w = Palette.white, c = Palette.cyan, a = Palette.amber, g = Palette.green
        return [
            Caption(start: 0.7, end: 3.85, lines: [[("Codex is on a roll.", w)]], subtitle: nil),
            Caption(start: 4.7, end: 7.65, lines: [[("Now it just waits.", w)], [("All night.", a)]], subtitle: nil,
                    lineDelays: [0, 1.0]),
            Caption(start: 12.3, end: 15.05, lines: [[("Whip waits \(spokenDuration(settings.retrySeconds)).", w)]],
                    subtitle: "No model switching. No starting over."),
            Caption(start: 15.2, end: 18.85, lines: [[("Then it nudges ", w), ("Codex.", c)]],
                    subtitle: "Your saved message, sent to the same session."),
            Caption(start: 19.15, end: 21.85, lines: [[("Back to work at \(clockText(retryAt)).", w)]],
                    subtitle: "Same session. Same model."),
            Caption(start: 22.9, end: 26.35, lines: [[("Out of quota? ", w), ("Whip waits.", a)]],
                    subtitle: "It checks Codex every \(spokenDuration(settings.checkSeconds))."),
            Caption(start: 26.5, end: 28.15, lines: [[("Quota’s back. ", g), ("Codex confirms it.", w)]], subtitle: nil),
            Caption(start: 28.4, end: 31.85, lines: [[("Back to work at \(clockText(quotaCheckTimes[1])).", w)]],
                    subtitle: "Regular renewals, handled."),
            Caption(start: 32.9, end: 35.9, lines: [[("Reset came early?", w)]], subtitle: nil),
            Caption(start: 36.0, end: 38.15, lines: [[("The next check ", w), ("catches it.", g)]],
                    subtitle: "Whip checks Codex quota, not posts."),
            Caption(start: 38.4, end: 41.85, lines: [[("Back to work at \(clockText(resetCheckAt)).", w)]],
                    subtitle: "Early resets, handled too."),
            Caption(start: 42.7, end: 45.25, lines: [[("Good morning.", w)]], subtitle: "Three interruptions overnight. Three recoveries."),
            Caption(start: 45.5, end: 48.1, lines: [[("See the night’s ", w), ("recoveries.", c)]],
                    subtitle: "Activity tracks capacity and quota retries separately."),
            Caption(start: 48.3, end: 51.75, lines: [[("Set the ", w), ("pace.", c)]],
                    subtitle: "Pick intervals and edit the message from the menu."),
        ]
    }

    var chapters: [(name: String, start: Double, end: Double)] {
        [("Capacity", 12, 22), ("Quota renewal", 22, 32), ("Early reset", 32, 42), ("Morning", 42, 52)]
    }

    // MARK: Terminal

    let prompt = "Add keyboard shortcuts to the command palette."
    var messageWords: [String] { settings.message.split(separator: " ").map(String.init) }

    /// Word counts revealed by each of the three capacity strikes.
    var strikeChunks: [Int] {
        let count = messageWords.count
        let first = max(1, Int((Double(count) / 3).rounded()))
        let second = max(first + 1, min(count - 1, Int((Double(count) * 2 / 3).rounded())))
        return [first, second, count]
    }

    var log: [LogLine] {
        var lines: [LogLine] = [
            LogLine(time: -10, kind: .user, text: prompt, typing: 0),
            LogLine(time: -9, kind: .step, text: "Reading src/palette/commands.ts", typing: 0),
            LogLine(time: -8, kind: .step, text: "Mapping 24 actions to shortcuts", typing: 0),
            LogLine(time: 0.35, kind: .step, text: "Writing tests for the new bindings"),
            LogLine(time: 0.95, kind: .step, text: "Running tests… 18 passed"),
            LogLine(time: 1.55, kind: .step, text: "Adding ⌘K to the palette view"),
            LogLine(time: 2.15, kind: .step, text: "Updating the shortcut reference"),
            LogLine(time: 2.75, kind: .step, text: "Checking conflicts with system keys"),
            LogLine(time: stop, kind: .error, text: "Selected model is at capacity. Please try a different model.", typing: 0),
            LogLine(time: capacitySend, kind: .user, text: settings.message, typing: 0),
            LogLine(time: capacityResume, kind: .step, text: "Continuing with the selected model"),
            LogLine(time: capacityResume + 0.6, kind: .step, text: "Resolving the last two conflicts"),
            LogLine(time: capacityResume + 1.2, kind: .step, text: "Running tests… 24 passed"),
        ]
        let lapse = ["Adding shortcut hints to menus", "Documenting the new bindings", "Refactoring the keymap loader",
                     "Running tests… 27 passed", "Polishing the palette layout", "Checking accessibility labels"]
        for (index, text) in lapse.enumerated() {
            lines.append(LogLine(time: quotaLapse.start + 0.06 + Double(index) * 0.11, kind: .step, text: text, typing: 0.08))
        }
        lines += [
            LogLine(time: quotaLapse.end, kind: .warn, text: "Usage limit reached. Try again later.", typing: 0),
            LogLine(time: quotaSend, kind: .user, text: settings.message, typing: 0),
            LogLine(time: quotaResume, kind: .step, text: "Continuing with the selected model"),
            LogLine(time: quotaResume + 0.6, kind: .step, text: "Adding shortcuts to the settings sheet"),
            LogLine(time: quotaResume + 1.2, kind: .step, text: "Running tests… 29 passed"),
        ]
        let lapse2 = ["Wiring shortcuts into context menus", "Updating snapshot tests", "Running tests… 30 passed",
                      "Cleaning up unused handlers", "Reviewing the diff"]
        for (index, text) in lapse2.enumerated() {
            lines.append(LogLine(time: resetLapse.start + 0.06 + Double(index) * 0.12, kind: .step, text: text, typing: 0.08))
        }
        lines += [
            LogLine(time: resetLapse.end, kind: .warn, text: "Usage limit reached. Try again later.", typing: 0),
            LogLine(time: resetSend, kind: .user, text: settings.message, typing: 0),
            LogLine(time: resetResume, kind: .step, text: "Continuing with the selected model"),
            LogLine(time: resetResume + 0.6, kind: .step, text: "Finishing the release notes"),
            LogLine(time: resetResume + 1.2, kind: .step, text: "Running tests… 31 passed"),
        ]
        let lapse3 = ["Final review of 14 changed files", "Formatting", "Running tests… 31 passed"]
        for (index, text) in lapse3.enumerated() {
            lines.append(LogLine(time: morningLapse.start + 0.08 + Double(index) * 0.16, kind: .step, text: text, typing: 0.08))
        }
        lines.append(LogLine(time: morningLapse.end, kind: .success, text: "Done. 24 shortcuts added, 31 tests passing.", typing: 0.45))
        return lines
    }

    /// Intervals where Codex shows its working indicator.
    var working: [(Double, Double)] {
        [(-10, stop), (capacityResume, quotaLapse.end), (quotaResume, resetLapse.end), (resetResume, morningLapse.end)]
    }

    // MARK: Cues for the score

    func cues(passes: [WhipPass], pan: (StrikePlan) -> Double) -> [Cue] {
        var list: [Cue] = []
        func add(_ time: Double, _ type: String, _ extra: [String: Any] = [:]) { list.append(Cue(time: time, type: type, extra: extra)) }
        for line in log where line.time >= 0 && line.kind == .step {
            add(line.time, "type", ["duration": max(0.12, line.typing + 0.1)])
        }
        add(stop, "stop")
        add(stop + 0.08, "error")
        add(5.0, "clock", ["end": 7.0])
        add(6.0, "riser", ["end": reveal])
        for pass in passes {
            add(pass.enter, "whoosh", ["pan": pass.space == .screen ? 0.7 : 0.6])
            for strike in pass.strikes {
                add(strike.impact, "whip", ["strength": strike.hero ? "hero" : "strike", "pan": pan(strike)])
            }
        }
        add(reveal + 0.25, "logo")
        add(10.75, "whoosh", ["pan": 0.6])
        add(11.3, "pop", ["pan": 0.75])
        add(12.45, "chip", ["pan": 0.7])
        add(retryCountdown.start, "countdown", ["end": retryCountdown.end])
        add(capacitySend, "send")
        add(capacityResume, "resume")
        add(quotaLapse.start, "timelapse", ["end": quotaLapse.end])
        add(quotaLapse.end, "warn")
        add(quotaChecks[0], "check", ["result": "waiting", "pan": 0.7])
        add(quotaChecks[1], "check", ["result": "available", "pan": 0.7])
        add(quotaConfirm, "confirm")
        add(quotaSend, "send")
        add(quotaResume, "resume")
        add(resetLapse.start, "timelapse", ["end": resetLapse.end])
        add(resetLapse.end, "warn")
        add(postEnters, "post", ["pan": 0.5])
        add(resetCheck, "check", ["result": "available", "pan": 0.7])
        add(resetConfirm, "confirm")
        add(resetSend, "send")
        add(resetResume, "resume")
        add(morningLapse.start, "timelapse", ["end": morningLapse.end])
        add(morningLapse.start, "sunrise", ["end": 44.0])
        add(morningLapse.end, "done")
        add(activityEnters, "window", ["pan": 0.3])
        add(46.0, "counter", ["end": 47.0])
        add(menuClick, "click", ["pan": 0.7])
        add(menuClick + 0.05, "menu", ["pan": 0.7])
        add(submenuOpens, "hover", ["pan": 0.5])
        add(menuCloses, "click", ["pan": 0.5])
        add(finale + 0.4, "logo")
        add(ctaEnters, "cta")
        add(finalHit, "end")
        return list.sorted { $0.time < $1.time }
    }
}
