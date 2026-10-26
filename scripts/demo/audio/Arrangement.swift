import Foundation

// Turns the plan into a musical timeline: harmony, a sequence of groove modes
// derived from sections and cues, automation curves, and note events.

struct Voicing {
    let pad: [Int]
    let bass: Int
}

enum ChordBook {
    static let supported = ["Dm9", "Bbmaj9", "F/A", "Cadd9", "Fmaj9", "C/E", "Gm9", "Csus4-C", "N.C."]

    /// Pad voicing (MIDI) and bass root for each part of the bar. A split
    /// symbol such as Csus4-C has two halves; N.C. has none.
    static func voicings(_ symbol: String) -> [Voicing]? {
        switch symbol {
        case "Dm9": return [Voicing(pad: [53, 57, 60, 64], bass: 38)]
        case "Bbmaj9": return [Voicing(pad: [53, 57, 60, 62], bass: 34)]
        case "F/A": return [Voicing(pad: [57, 60, 65, 69], bass: 33)]
        case "Cadd9": return [Voicing(pad: [55, 60, 62, 64], bass: 36)]
        case "Fmaj9": return [Voicing(pad: [57, 60, 64, 67], bass: 41)]
        case "C/E": return [Voicing(pad: [55, 60, 64, 67], bass: 40)]
        case "Gm9": return [Voicing(pad: [53, 57, 58, 62], bass: 43)]
        case "Csus4-C":
            return [Voicing(pad: [53, 55, 60, 65], bass: 36), Voicing(pad: [52, 55, 60, 64], bass: 36)]
        case "N.C.": return []
        default: return nil
        }
    }
}

struct HarmonySpan {
    let start: Double
    let end: Double
    let symbol: String
    let voicing: Voicing?
}

struct Harmony {
    let spans: [HarmonySpan]

    init(plan: Plan) {
        var result: [HarmonySpan] = []
        if let first = plan.chords.first, first.start > 0 {
            result.append(HarmonySpan(start: 0, end: first.start, symbol: "N.C.", voicing: nil))
        }
        for (i, chord) in plan.chords.enumerated() {
            let end = i + 1 < plan.chords.count ? plan.chords[i + 1].start : plan.duration
            let parts = ChordBook.voicings(chord.symbol) ?? []
            if parts.isEmpty {
                result.append(HarmonySpan(start: chord.start, end: end, symbol: chord.symbol, voicing: nil))
                continue
            }
            let width = (end - chord.start) / Double(parts.count)
            for (j, voicing) in parts.enumerated() {
                result.append(HarmonySpan(start: chord.start + width * Double(j),
                                          end: chord.start + width * Double(j + 1),
                                          symbol: chord.symbol, voicing: voicing))
            }
        }
        spans = result
    }

    func index(at time: Double) -> Int? {
        guard let first = spans.first, time >= first.start - 1e-9 else { return nil }
        var low = 0
        var high = spans.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if spans[mid].start <= time + 1e-9 {
                low = mid
            } else {
                high = mid - 1
            }
        }
        return low
    }

    /// The sounding voicing, or the last one before a no-chord stretch.
    func voicingOrPrevious(at time: Double) -> Voicing? {
        guard var i = index(at: time) else { return nil }
        while i >= 0 {
            if let voicing = spans[i].voicing {
                return voicing
            }
            i -= 1
        }
        return nil
    }
}

// MARK: - Modes

enum Mode {
    case intro, silent, drop, waiting, strikes, bright, breakdown, build, halftime, morning, outro, final
}

struct ModeSpan {
    let mode: Mode
    let start: Double
    let end: Double
    /// Automation transition length at the start of the span, in seconds.
    let ramp: Double
}

/// Settled automation targets for each mode.
struct Style {
    let padCutoff: Double
    let padLevel: Double
    let arpCutoff: Double
    let arpLevel: Double
    let hatLevel: Double
    let bassCutoff: Double

    static func of(_ mode: Mode) -> Style {
        switch mode {
        case .intro, .silent:
            return Style(padCutoff: 900, padLevel: 0.82, arpCutoff: 2000, arpLevel: 0.42, hatLevel: 0.42, bassCutoff: 380)
        case .drop:
            return Style(padCutoff: 4800, padLevel: 0.9, arpCutoff: 7800, arpLevel: 0.85, hatLevel: 1, bassCutoff: 1100)
        case .waiting:
            return Style(padCutoff: 1200, padLevel: 0.72, arpCutoff: 2600, arpLevel: 0.5, hatLevel: 0.6, bassCutoff: 800)
        case .strikes:
            return Style(padCutoff: 2400, padLevel: 0.85, arpCutoff: 4600, arpLevel: 0.75, hatLevel: 0.85, bassCutoff: 950)
        case .bright, .outro, .build, .final:
            return Style(padCutoff: 6000, padLevel: 0.95, arpCutoff: 9000, arpLevel: 0.9, hatLevel: 1, bassCutoff: 1250)
        case .breakdown:
            return Style(padCutoff: 1800, padLevel: 0.82, arpCutoff: 3200, arpLevel: 0.75, hatLevel: 0.45, bassCutoff: 340)
        case .halftime:
            return Style(padCutoff: 2600, padLevel: 0.8, arpCutoff: 4800, arpLevel: 0.72, hatLevel: 0.65, bassCutoff: 900)
        case .morning:
            return Style(padCutoff: 3400, padLevel: 0.95, arpCutoff: 6400, arpLevel: 0.8, hatLevel: 0.85, bassCutoff: 1050)
        }
    }
}

// MARK: - Events

struct DrumHit {
    enum Kind {
        case kick, clap, roll, closedHat, openHat, crash
    }

    let kind: Kind
    let time: Double
    let velocity: Double
    /// Kick: click amount. Clap and roll: band center in Hz. Hats: 1 bright, 0 dark.
    let tone: Double
}

enum BassStyle {
    case sub, groove, held, pulse
}

struct BassNote {
    let time: Double
    let length: Double
    let midi: Int
    let velocity: Double
    let style: BassStyle
    let cutoff: Double
}

struct PadNote {
    let midi: Int
    let start: Double
    let end: Double
    let attack: Double
    let release: Double
}

struct PluckNote {
    let time: Double
    let midi: Int
    let velocity: Double
    let gate: Double
    let decay: Double
    let cutoff: Double
    let pan: Double
    let delaySend: Double
}

struct BellNote {
    let time: Double
    let midi: Double
    let velocity: Double
    let decay: Double
    let index: Double
    let pan: Double
}

struct BuildSpan {
    let start: Double
    let end: Double
}

struct TapeStop {
    let time: Double
    let silenceEnd: Double
}

struct DroneSpan {
    let start: Double
    let end: Double
}

struct FinalHit {
    let time: Double
    let voicing: Voicing
}

private enum Patterns {
    struct BassStep {
        let step: Int
        let length: Int
        let octave: Int
        let velocity: Double
    }

    static let bassGroove = [
        BassStep(step: 0, length: 2, octave: 0, velocity: 1.0),
        BassStep(step: 3, length: 2, octave: 0, velocity: 0.78),
        BassStep(step: 6, length: 3, octave: 12, velocity: 0.9),
        BassStep(step: 10, length: 3, octave: 0, velocity: 0.84),
        BassStep(step: 14, length: 2, octave: 12, velocity: 0.76),
    ]
    static let bassMorning = [
        BassStep(step: 0, length: 3, octave: 0, velocity: 1.0),
        BassStep(step: 3, length: 2, octave: 0, velocity: 0.74),
        BassStep(step: 6, length: 3, octave: 0, velocity: 0.86),
        BassStep(step: 10, length: 3, octave: 0, velocity: 0.8),
        BassStep(step: 14, length: 2, octave: 12, velocity: 0.72),
    ]
    static let bassHalf = [
        BassStep(step: 0, length: 5, octave: 0, velocity: 0.95),
        BassStep(step: 7, length: 2, octave: 12, velocity: 0.7),
        BassStep(step: 10, length: 4, octave: 0, velocity: 0.82),
    ]

    // Indexes into eight chord tones spread over two octaves.
    static let arpOrderA = [0, 2, 1, 3, 2, 4, 3, 5, 4, 6, 5, 7, 6, 4, 3, 1]
    static let arpOrderB = [7, 5, 6, 4, 5, 3, 4, 2, 3, 1, 2, 0, 1, 3, 4, 6]

    static let arpIntro: [Double] = [0.8, 0, 0, 0, 0, 0, 0.55, 0, 0, 0, 0, 0.5, 0, 0, 0.4, 0]
    static let arpSparse: [Double] = [0.9, 0, 0, 0.55, 0, 0, 0.7, 0, 0, 0, 0.65, 0, 0, 0, 0, 0]
    static let arpNormal: [Double] = [1, 0, 0.62, 0.5, 0.85, 0, 0.62, 0.45, 0.95, 0, 0.62, 0.5, 0.85, 0, 0.6, 0.45]
    static let arpBusy: [Double] = [1, 0.5, 0.7, 0.5, 0.9, 0.5, 0.7, 0.5, 0.95, 0.5, 0.7, 0.5, 0.9, 0.5, 0.7, 0.55]
}

// MARK: - Arrangement

final class Arrangement {
    static let tapeOverflow = 0.3

    let plan: Plan
    let harmony: Harmony
    let spans: [ModeSpan]
    let builds: [BuildSpan]
    private let whipTimes: [Double]

    let padCutoff: ControlCurve
    let padLevel: ControlCurve
    let arpCutoff: ControlCurve
    let arpLevel: ControlCurve
    let hatLevel: ControlCurve
    let bassCutoff: ControlCurve

    private(set) var drums: [DrumHit] = []
    private(set) var bass: [BassNote] = []
    private(set) var pads: [PadNote] = []
    private(set) var plucks: [PluckNote] = []
    private(set) var bells: [BellNote] = []
    private(set) var tapeStops: [TapeStop] = []
    private(set) var drones: [DroneSpan] = []
    private(set) var finalHit: FinalHit?

    init(plan: Plan, frames: Int) {
        self.plan = plan
        harmony = Harmony(plan: plan)
        whipTimes = plan.cues(.whip).map(\.time)
        let spans = Arrangement.makeSpans(plan)
        self.spans = spans

        var builds = spans.filter { $0.mode == .build }.map { BuildSpan(start: $0.start, end: $0.end) }
        if let final = spans.first(where: { $0.mode == .final }),
           let outro = spans.last(where: { $0.mode == .outro && $0.end <= final.start + 1e-9 }) {
            let start = max(outro.start, final.start - plan.bar)
            if final.start - start >= plan.beat {
                builds.append(BuildSpan(start: start, end: final.start))
            }
        }
        builds.sort { $0.start < $1.start }
        self.builds = builds

        let automation = Automation(spans: spans)
        padCutoff = ControlCurve(frames: frames) { automation.value(at: $0, log: true, morning: (2200, 6000)) { $0.padCutoff } }
        padLevel = ControlCurve(frames: frames) { automation.value(at: $0, log: false, morning: nil) { $0.padLevel } }
        arpCutoff = ControlCurve(frames: frames) { automation.value(at: $0, log: true, morning: (4200, 7400)) { $0.arpCutoff } }
        arpLevel = ControlCurve(frames: frames) { automation.value(at: $0, log: false, morning: nil) { $0.arpLevel } }
        hatLevel = ControlCurve(frames: frames) { automation.value(at: $0, log: false, morning: nil) { $0.hatLevel } }
        bassCutoff = ControlCurve(frames: frames) { automation.value(at: $0, log: true, morning: nil) { $0.bassCutoff } }

        generateGrid()
        generatePads()
        generateFeatures()
    }

    // MARK: Spans

    static func makeSpans(_ plan: Plan) -> [ModeSpan] {
        var spans: [ModeSpan] = []
        func add(_ mode: Mode, _ start: Double, _ end: Double, ramp: Double) {
            guard end - start > 1e-6 else { return }
            if let last = spans.last, last.mode == mode, abs(last.end - start) < 1e-9 {
                spans[spans.count - 1] = ModeSpan(mode: mode, start: last.start, end: end, ramp: last.ramp)
                return
            }
            spans.append(ModeSpan(mode: mode, start: start, end: end, ramp: ramp))
        }
        let impact = 0.004
        for section in plan.sections {
            let inside = plan.cues.filter { $0.time >= section.start - 1e-9 && $0.time < section.end - 1e-9 }
            func first(_ type: CueType, after time: Double) -> Cue? {
                inside.first { $0.type == type && $0.time > time + 1e-9 }
            }
            let before = section.start - 1
            switch section.name {
            case .night:
                add(.intro, section.start, section.end, ramp: 0)
            case .stop:
                if let stop = first(.stop, after: before) {
                    add(.intro, section.start, stop.time, ramp: 0)
                    add(.silent, stop.time, section.end, ramp: 0)
                } else {
                    add(.silent, section.start, section.end, ramp: 0)
                }
            case .reveal:
                add(.drop, section.start, section.end, ramp: impact)
            case .capacity:
                // Waiting texture until one beat before the first strike, strikes
                // until the resume cue, then full brightness.
                let whip = first(.whip, after: before)
                let resume = first(.resume, after: whip?.time ?? before)
                let waitTarget = whip.map { $0.time - plan.beat } ?? resume?.time ?? section.end
                let waitEnd = clamp(waitTarget, section.start, section.end)
                let brightStart = max(waitEnd, resume?.time ?? section.end)
                add(.waiting, section.start, waitEnd, ramp: 1.0)
                add(.strikes, waitEnd, brightStart, ramp: 0.5)
                add(.bright, brightStart, section.end, ramp: 0.35)
            case .quota, .reset:
                // Groove until the warning, a lull (breakdown or half time), a build
                // from the confirmation, and the full groove again at the next whip.
                let lull: Mode = section.name == .quota ? .breakdown : .halftime
                let warn = first(.warn, after: before)
                let lullStart = warn?.time ?? section.end
                let confirm = warn.flatMap { first(.confirm, after: $0.time) }
                let whip = first(.whip, after: confirm?.time ?? lullStart)
                add(.bright, section.start, lullStart, ramp: 0.35)
                if let whip = whip {
                    let buildStart = clamp(confirm?.time ?? whip.time, lullStart, whip.time)
                    add(lull, lullStart, buildStart, ramp: 0.35)
                    add(.build, buildStart, whip.time, ramp: 0)
                    add(.bright, whip.time, section.end, ramp: impact)
                } else {
                    add(lull, lullStart, section.end, ramp: 0.35)
                }
            case .morning:
                add(.morning, section.start, section.end, ramp: 0.5)
            case .outro:
                if let end = first(.end, after: before) {
                    add(.outro, section.start, end.time, ramp: impact)
                    add(.final, end.time, section.end, ramp: impact)
                } else {
                    add(.outro, section.start, section.end, ramp: impact)
                }
            }
        }
        return spans
    }

    func spanIndex(at time: Double) -> Int {
        var low = 0
        var high = spans.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if spans[mid].start <= time + 1e-9 {
                low = mid
            } else {
                high = mid - 1
            }
        }
        return low
    }

    /// The span whose patterns play at this time. Just after a tape stop the
    /// previous texture keeps running so the slowdown has material to stretch.
    private func eventSpanIndex(at time: Double) -> Int? {
        let i = spanIndex(at: time)
        switch spans[i].mode {
        case .final:
            return nil
        case .silent:
            return i > 0 && time < spans[i].start + Arrangement.tapeOverflow ? i - 1 : nil
        default:
            return i
        }
    }

    /// True where the kick-driven groove plays at full or near-full density.
    func isFullGroove(at time: Double) -> Bool {
        switch spans[spanIndex(at: time)].mode {
        case .drop, .waiting, .strikes, .bright, .morning, .outro, .build:
            return true
        default:
            return false
        }
    }

    /// True within 5 ms of a whip crack, where the crack must be the only transient.
    private func nearWhip(_ time: Double) -> Bool {
        whipTimes.contains { abs($0 - time) < 0.005 }
    }

    static func arpTones(_ voicing: Voicing) -> [Int] {
        (voicing.pad.map { $0 + 12 } + voicing.pad.map { $0 + 24 }).sorted()
    }

    // MARK: Grid events

    private func generateGrid() {
        let step = plan.step
        let barSteps = plan.beatsPerBar * 4
        let total = Int((plan.duration / step).rounded(.up))
        let swing = (0.54 - 0.5) * 2 * step
        for k in 0..<total {
            let t = Double(k) * step
            guard let i = eventSpanIndex(at: t) else { continue }
            let span = spans[i]
            let mode = span.mode
            let s = k % barSteps
            let p = s % 16
            let bar = k / barSteps
            var rng = SplitMix64(seed: seed("grid", k))
            let build = builds.first { t >= $0.start - 1e-9 && t < $0.end - 1e-9 }
            let u = build.map { clamp((t - $0.start) / max($0.end - $0.start, 1e-6), 0, 1) } ?? 0
            // Notes may ring into a following tape stop; otherwise they end with the span.
            var spanEnd = span.end
            if i + 1 < spans.count, spans[i + 1].mode == .silent {
                spanEnd += Arrangement.tapeOverflow
            }

            // Kick.
            switch mode {
            case .drop, .waiting, .strikes, .bright, .morning, .outro:
                if s % 4 == 0 {
                    let accent = s == 0 ? 1.0 : 0.94
                    let warm = mode == .morning
                    let weight = mode == .waiting ? 0.86 : (warm ? 0.92 : 1)
                    drums.append(DrumHit(kind: .kick, time: t, velocity: accent * weight,
                                         tone: nearWhip(t) ? 0 : (warm ? 0.55 : 1)))
                }
            case .halftime:
                if p == 0 {
                    drums.append(DrumHit(kind: .kick, time: t, velocity: 0.95, tone: nearWhip(t) ? 0 : 0.8))
                } else if p == 10 {
                    drums.append(DrumHit(kind: .kick, time: t, velocity: 0.72, tone: nearWhip(t) ? 0 : 0.8))
                }
            default:
                break
            }

            // Clap roll in builds (8ths, then 16ths), otherwise the backbeat.
            var rolled = false
            if let b = build, t < b.end - 0.06, u >= 0.5 || k % 2 == 0 {
                drums.append(DrumHit(kind: .roll, time: t, velocity: 0.28 + 0.72 * pow(u, 1.2), tone: 1050 + 700 * u))
                rolled = true
            }
            if !rolled {
                switch mode {
                case .drop, .strikes, .bright, .morning, .outro:
                    if s % 8 == 4 {
                        drums.append(DrumHit(kind: .clap, time: t, velocity: mode == .morning ? 0.86 : 1, tone: 1200))
                    }
                case .halftime:
                    if p == 8 {
                        drums.append(DrumHit(kind: .clap, time: t, velocity: 0.92, tone: 1150))
                    }
                default:
                    break
                }
            }

            // Hats with light swing on the odd sixteenths and seeded humanizing.
            let pattern = hatPattern(mode, p, u)
            let jitter = 0.0012 * rng.bipolar()
            let hatTime = max(0, t + (k % 2 == 1 ? swing : 0) + jitter)
            let level = hatLevel.at(time: t)
            let closedVariation = 1 + 0.12 * rng.bipolar()
            let openVariation = 1 + 0.08 * rng.bipolar()
            if pattern.closed > 0 && !nearWhip(hatTime) {
                drums.append(DrumHit(kind: .closedHat, time: hatTime, velocity: pattern.closed * level * closedVariation,
                                     tone: mode == .intro ? 0 : 1))
            }
            if pattern.open > 0 && !nearWhip(hatTime) {
                drums.append(DrumHit(kind: .openHat, time: hatTime, velocity: pattern.open * level * openVariation,
                                     tone: 1))
            }

            guard let voicing = harmony.voicingOrPrevious(at: t) else { continue }

            // Bass on chord roots.
            let root = voicing.bass
            let cutoff = bassCutoff.at(time: t)
            func addBass(_ length: Double, _ midi: Int, _ velocity: Double, _ style: BassStyle) {
                let trimmed = min(length, spanEnd - t)
                guard trimmed > 0.02 else { return }
                bass.append(BassNote(time: t, length: trimmed, midi: midi, velocity: velocity, style: style, cutoff: cutoff))
            }
            switch mode {
            case .intro:
                if p == 0 {
                    addBass(12 * step, root, 0.55, .sub)
                }
            case .drop, .strikes, .bright, .outro, .waiting, .morning, .halftime:
                let steps = mode == .halftime ? Patterns.bassHalf : (mode == .morning ? Patterns.bassMorning : Patterns.bassGroove)
                if let hit = steps.first(where: { $0.step == p }) {
                    let scale = mode == .waiting ? 0.74 : 1
                    addBass(Double(hit.length) * step, root + hit.octave, hit.velocity * scale, .groove)
                }
            case .breakdown:
                let h = harmony.index(at: t)
                let chordStart = h.map { harmony.spans[$0].start } ?? t
                let chordEnd = h.map { harmony.spans[$0].end } ?? span.end
                let isChange = abs(t - chordStart) < step * 0.5
                let isFirst = t - span.start < step - 1e-9
                if isChange || isFirst {
                    addBass(max(step, min(chordEnd, span.end) - t), root, 0.62, .held)
                }
            case .build:
                if k % 2 == 0 {
                    addBass(1.5 * step, root, 0.62 + 0.3 * u, .pulse)
                }
            default:
                break
            }

            // Pluck arpeggio over two octaves of chord tones.
            let arp: [Double]
            var busy = false
            switch mode {
            case .intro:
                arp = Patterns.arpIntro
            case .waiting:
                arp = Patterns.arpSparse
            case .drop, .strikes, .breakdown, .halftime, .morning:
                arp = Patterns.arpNormal
            case .bright, .outro, .build:
                arp = Patterns.arpBusy
                busy = true
            default:
                arp = []
            }
            if p < arp.count, arp[p] > 0 {
                let base = arp[p]
                let tones = Arrangement.arpTones(voicing)
                let order = bar % 2 == 0 ? Patterns.arpOrderA : Patterns.arpOrderB
                let midi = tones[order[p] % tones.count]
                var velocity = base * arpLevel.at(time: t) * (1 + 0.06 * rng.bipolar())
                if mode == .build {
                    velocity *= 0.6 + 0.4 * u
                }
                plucks.append(PluckNote(time: t, midi: midi, velocity: velocity,
                                        gate: step * (busy ? 0.85 : 1.5),
                                        decay: mode == .intro ? 0.34 : (busy ? 0.17 : 0.22),
                                        cutoff: arpCutoff.at(time: t) * (0.6 + 0.4 * base),
                                        pan: k % 2 == 0 ? -0.22 : 0.22,
                                        delaySend: mode == .intro ? 0.5 : 0.26))
            }
        }
    }

    private func hatPattern(_ mode: Mode, _ p: Int, _ u: Double) -> (closed: Double, open: Double) {
        let q = p % 4
        switch mode {
        case .intro:
            let ticks: [Int: Double] = [6: 0.6, 14: 0.55, 15: 0.25]
            return (ticks[p] ?? 0, 0)
        case .waiting:
            return ([0, 0, 0.75, 0.28][q], 0)
        case .strikes:
            return ([0.35, 0.45, 0.85, 0.45][q], 0)
        case .drop, .bright, .outro:
            return ([0.3, 0.45, 0, 0.5][q], [0, 0, 0.85, 0][q])
        case .breakdown:
            return ([0.45, 0, 0.6, 0][q], 0)
        case .halftime:
            if p == 14 {
                return (0, 0.6)
            }
            return ([0, 0, 0.7, 0.3][q], 0)
        case .build:
            return (0.35 + 0.6 * u * (q == 2 ? 1 : 0.8), 0)
        case .morning:
            return ([0.25, 0.4, 0, 0.42][q], [0, 0, 0.7, 0][q])
        case .silent, .final:
            return (0, 0)
        }
    }

    // MARK: Pads

    private func generatePads() {
        var open: [(midi: Int, start: Double, attack: Double)] = []
        func close(_ index: Int, at time: Double, release: Double) {
            let note = open[index]
            if time > note.start + 0.01 {
                pads.append(PadNote(midi: note.midi, start: note.start, end: time, attack: note.attack, release: release))
            }
            open.remove(at: index)
        }
        func closeAll(at time: Double, release: Double) {
            while !open.isEmpty {
                close(open.count - 1, at: time, release: release)
            }
        }
        func attack(_ mode: Mode) -> Double {
            switch mode {
            case .intro: return 0.6
            case .drop: return 0.012
            case .breakdown: return 0.35
            case .halftime: return 0.25
            case .morning: return 0.3
            case .build: return 0.1
            default: return 0.15
            }
        }
        for h in harmony.spans {
            let index = spanIndex(at: h.start)
            let span = spans[index]
            guard let voicing = h.voicing, span.mode != .silent, span.mode != .final else {
                // At a tape stop the chord keeps sounding into the slowdown.
                let atStop = span.mode == .silent && abs(span.start - h.start) < 1e-6
                closeAll(at: h.start + (atStop ? Arrangement.tapeOverflow : 0), release: atStop ? 0.3 : 0.45)
                continue
            }
            // Common tones sustain; moving voices cross-fade.
            var j = open.count - 1
            while j >= 0 {
                if !voicing.pad.contains(open[j].midi) {
                    close(j, at: h.start, release: 0.45)
                }
                j -= 1
            }
            for midi in voicing.pad where !open.contains(where: { $0.midi == midi }) {
                open.append((midi, h.start, attack(span.mode)))
            }
            // A tape stop or the final hit inside this chord ends the pad there.
            if let cut = spans.first(where: { ($0.mode == .silent || $0.mode == .final) && $0.start > h.start + 1e-6 && $0.start < h.end - 1e-6 }) {
                let atStop = cut.mode == .silent
                closeAll(at: cut.start + (atStop ? Arrangement.tapeOverflow : 0), release: atStop ? 0.3 : 0.05)
            }
        }
        closeAll(at: plan.duration, release: 0.3)
        pads.sort { $0.start != $1.start ? $0.start < $1.start : $0.midi < $1.midi }
    }

    // MARK: Crashes, bells, tape stops, drones and the final hit

    private func generateFeatures() {
        for (i, span) in spans.enumerated() {
            switch span.mode {
            case .drop, .outro:
                drums.append(DrumHit(kind: .crash, time: span.start, velocity: 1, tone: 1))
            case .bright where i > 0 && spans[i - 1].mode == .build:
                drums.append(DrumHit(kind: .crash, time: span.start, velocity: 0.9, tone: 1))
            case .morning:
                drums.append(DrumHit(kind: .crash, time: span.start, velocity: 0.5, tone: 1))
            default:
                break
            }
        }
        drums.sort { $0.time < $1.time }

        // The morning motif: F5 A5 C6 A5 in dotted quarters, stated twice.
        for section in plan.sections where section.name == .morning {
            let motif: [Double] = [77, 81, 84, 81]
            let pans = [-0.15, 0.1, 0.2, -0.05]
            for statement in 0..<2 {
                let start = section.start + Double(statement) * 2 * plan.bar
                guard start + 4.5 * plan.beat + 0.5 < section.end else { break }
                for (j, midi) in motif.enumerated() {
                    bells.append(BellNote(time: start + Double(j) * 1.5 * plan.beat, midi: midi,
                                          velocity: j == 2 ? 1 : 0.86, decay: 1.1, index: 2.2, pan: pans[j]))
                }
            }
        }

        for cue in plan.cues(.stop) {
            let i = spanIndex(at: cue.time)
            let silenceEnd = spans[i].mode == .silent ? spans[i].end : cue.time
            tapeStops.append(TapeStop(time: cue.time, silenceEnd: silenceEnd))
        }

        for span in spans where span.mode == .silent {
            let start = span.start + 0.6
            let end = span.end - 0.03
            if end - start > 0.5 {
                drones.append(DroneSpan(start: start, end: end))
            }
        }

        if let final = spans.first(where: { $0.mode == .final }),
           let voicing = harmony.voicingOrPrevious(at: final.start + 1e-6) {
            finalHit = FinalHit(time: final.start, voicing: voicing)
        }
    }
}

/// Evaluates automation targets with ramps at span boundaries and
/// interpolation through builds.
private struct Automation {
    let spans: [ModeSpan]

    private func index(at time: Double) -> Int {
        var low = 0
        var high = spans.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if spans[mid].start <= time + 1e-9 {
                low = mid
            } else {
                high = mid - 1
            }
        }
        return low
    }

    private func mix(_ a: Double, _ b: Double, _ u: Double, _ log: Bool) -> Double {
        if log {
            return a * pow(b / a, u)
        }
        return a + (b - a) * u
    }

    private func settled(_ i: Int, _ time: Double, _ log: Bool, _ morning: (Double, Double)?,
                         _ pick: (Style) -> Double) -> Double {
        let span = spans[i]
        switch span.mode {
        case .silent, .final:
            return i > 0 ? settled(i - 1, spans[i - 1].end, log, morning, pick) : pick(Style.of(.intro))
        case .build:
            let from = i > 0 ? settled(i - 1, spans[i - 1].end, log, morning, pick) : pick(Style.of(.bright))
            let to = i + 1 < spans.count ? settled(i + 1, spans[i + 1].start, log, morning, pick) : pick(Style.of(.bright))
            let u = clamp((time - span.start) / max(span.end - span.start, 1e-6), 0, 1)
            return mix(from, to, pow(u, 1.5), log)
        case .morning:
            if let range = morning {
                let u = clamp((time - span.start) / max(span.end - span.start, 1e-6), 0, 1)
                return mix(range.0, range.1, smoothstep(u), log)
            }
            return pick(Style.of(.morning))
        default:
            return pick(Style.of(span.mode))
        }
    }

    func value(at time: Double, log: Bool, morning: (Double, Double)?, _ pick: (Style) -> Double) -> Double {
        let i = index(at: time)
        let span = spans[i]
        let target = settled(i, time, log, morning, pick)
        if i > 0, span.ramp > 0, span.mode != .build, time < span.start + span.ramp {
            let previous = settled(i - 1, span.start, log, morning, pick)
            return mix(previous, target, smoothstep((time - span.start) / span.ramp), log)
        }
        return target
    }
}
