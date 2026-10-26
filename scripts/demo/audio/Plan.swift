import Foundation

// The film's audio plan: timing, sections, one chord per bar and timed cues.
// Everything the arrangement does is derived from this file.

struct PlanError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}

enum SectionName: String, CaseIterable {
    case night, stop, reveal, capacity, quota, reset, morning, outro
}

struct Section {
    let name: SectionName
    let start: Double
    let end: Double
}

struct ChordSlot {
    let bar: Int
    let start: Double
    let symbol: String
}

enum CueType: String, CaseIterable {
    case whip, type, stop, error, clock, riser, logo, whoosh, pop, chip, window, cta
    case countdown, send, resume, timelapse, warn, check, confirm, post, sunrise, done
    case counter, click, menu, hover, end

    /// Cues that describe a span and therefore need an `end` time.
    var isRanged: Bool {
        switch self {
        case .clock, .riser, .countdown, .timelapse, .sunrise, .counter:
            return true
        default:
            return false
        }
    }
}

enum WhipStrength: String {
    case hero, strike
}

enum CheckResult: String {
    case waiting, available
}

struct Cue {
    let index: Int
    let time: Double
    let type: CueType
    let pan: Double
    let end: Double?
    let strength: WhipStrength
    let result: CheckResult
    let duration: Double?
}

struct Plan {
    let duration: Double
    let bpm: Double
    let beatsPerBar: Int
    let sections: [Section]
    let chords: [ChordSlot]
    let cues: [Cue]
    let warnings: [String]
    let sha256: String

    var beat: Double { 60 / bpm }
    var step: Double { beat / 4 }
    var bar: Double { beat * Double(beatsPerBar) }

    func cues(_ type: CueType) -> [Cue] {
        cues.filter { $0.type == type }
    }

    func section(at time: Double) -> Section? {
        sections.first { time >= $0.start && time < $0.end } ?? sections.last
    }
}

// MARK: - Parsing

extension Plan {
    static func load(path: String) throws -> Plan {
        let url = URL(fileURLWithPath: path)
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw PlanError("cannot read plan at \(path): \(error.localizedDescription)")
        }
        let root: Any
        do {
            root = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw PlanError("plan at \(path) is not valid JSON: \(error.localizedDescription)")
        }
        guard let object = root as? [String: Any] else {
            throw PlanError("plan must be a JSON object")
        }
        return try Plan(object: object, sha256: SHA256.hex(Array(data)))
    }

    private init(object: [String: Any], sha256: String) throws {
        var warnings: [String] = []
        let topKeys: Set<String> = ["provisional", "duration", "fps", "bpm", "beatsPerBar", "sections", "chords", "cues"]
        for key in object.keys.sorted() where !topKeys.contains(key) {
            warnings.append("ignoring unknown top-level key \"\(key)\"")
        }

        let duration = try Plan.number(object["duration"], "duration")
        guard duration >= 1 && duration <= 600 else {
            throw PlanError("duration must be from 1 to 600 seconds, got \(duration)")
        }
        let bpm = try Plan.number(object["bpm"], "bpm")
        guard bpm >= 40 && bpm <= 240 else {
            throw PlanError("bpm must be from 40 to 240, got \(bpm)")
        }
        var beatsPerBar = 4
        if let value = object["beatsPerBar"] {
            let raw = try Plan.number(value, "beatsPerBar")
            guard raw == raw.rounded(), raw >= 2, raw <= 12 else {
                throw PlanError("beatsPerBar must be a whole number from 2 to 12")
            }
            beatsPerBar = Int(raw)
        }

        // Sections must tile the film exactly, in order.
        guard let rawSections = object["sections"] as? [Any], !rawSections.isEmpty else {
            throw PlanError("sections must be a non-empty array")
        }
        var sections: [Section] = []
        for (i, raw) in rawSections.enumerated() {
            let path = "sections[\(i)]"
            guard let item = raw as? [String: Any] else {
                throw PlanError("\(path) must be an object")
            }
            for key in item.keys.sorted() where !["name", "start", "end"].contains(key) {
                warnings.append("\(path): ignoring unknown key \"\(key)\"")
            }
            guard let nameText = item["name"] as? String else {
                throw PlanError("\(path).name must be a string")
            }
            guard let name = SectionName(rawValue: nameText) else {
                let known = SectionName.allCases.map(\.rawValue).joined(separator: ", ")
                throw PlanError("\(path) has unknown section name \"\(nameText)\"; supported names: \(known)")
            }
            let start = try Plan.number(item["start"], "\(path).start")
            let end = try Plan.number(item["end"], "\(path).end")
            guard end > start else {
                throw PlanError("\(path) must end after it starts")
            }
            let expectedStart = sections.last?.end ?? 0
            guard abs(start - expectedStart) < 1e-6 else {
                throw PlanError("\(path) starts at \(start) but must start at \(expectedStart); sections must tile the film without gaps")
            }
            sections.append(Section(name: name, start: start, end: end))
        }
        guard let lastSection = sections.last, abs(lastSection.end - duration) < 1e-6 else {
            throw PlanError("the last section must end at duration \(duration)")
        }

        // One chord per bar, increasing start times, known symbols only.
        guard let rawChords = object["chords"] as? [Any] else {
            throw PlanError("chords must be an array")
        }
        var chords: [ChordSlot] = []
        for (i, raw) in rawChords.enumerated() {
            let path = "chords[\(i)]"
            guard let item = raw as? [String: Any] else {
                throw PlanError("\(path) must be an object")
            }
            for key in item.keys.sorted() where !["bar", "start", "symbol"].contains(key) {
                warnings.append("\(path): ignoring unknown key \"\(key)\"")
            }
            let barValue = try Plan.number(item["bar"], "\(path).bar")
            guard barValue == barValue.rounded(), barValue >= 1 else {
                throw PlanError("\(path).bar must be a positive whole number")
            }
            let start = try Plan.number(item["start"], "\(path).start")
            guard start >= 0 && start < duration else {
                throw PlanError("\(path).start must fall inside the film")
            }
            if let previous = chords.last, start <= previous.start {
                throw PlanError("\(path).start must be later than the previous chord")
            }
            guard let symbol = item["symbol"] as? String else {
                throw PlanError("\(path).symbol must be a string")
            }
            guard ChordBook.voicings(symbol) != nil else {
                let known = ChordBook.supported.joined(separator: ", ")
                throw PlanError("\(path) has unknown chord symbol \"\(symbol)\"; supported symbols: \(known)")
            }
            chords.append(ChordSlot(bar: Int(barValue), start: start, symbol: symbol))
        }

        // Cues: known types, typed fields, and spans for ranged cues.
        guard let rawCues = object["cues"] as? [Any] else {
            throw PlanError("cues must be an array")
        }
        guard rawCues.count <= 5000 else {
            throw PlanError("the plan supports at most 5,000 cues")
        }
        var cues: [Cue] = []
        let cueKeys: Set<String> = ["time", "type", "pan", "end", "strength", "result", "duration"]
        for (i, raw) in rawCues.enumerated() {
            let path = "cues[\(i)]"
            guard let item = raw as? [String: Any] else {
                throw PlanError("\(path) must be an object")
            }
            guard let typeText = item["type"] as? String else {
                throw PlanError("\(path).type must be a string")
            }
            guard let type = CueType(rawValue: typeText) else {
                let known = CueType.allCases.map(\.rawValue).joined(separator: ", ")
                throw PlanError("\(path) has unknown cue type \"\(typeText)\"; supported types: \(known)")
            }
            for key in item.keys.sorted() where !cueKeys.contains(key) {
                warnings.append("\(path) (\(typeText)): ignoring unknown key \"\(key)\"")
            }
            let time = try Plan.number(item["time"], "\(path).time")
            guard time >= 0 && time < duration else {
                throw PlanError("\(path).time must be from 0 to below \(duration), got \(time)")
            }
            var pan = 0.0
            if let value = item["pan"] {
                pan = try Plan.number(value, "\(path).pan")
                guard pan >= -1 && pan <= 1 else {
                    throw PlanError("\(path).pan must be from -1 to 1, got \(pan)")
                }
            }
            var end: Double?
            if let value = item["end"] {
                let parsed = try Plan.number(value, "\(path).end")
                guard parsed > time && parsed <= duration else {
                    throw PlanError("\(path).end must be after its time and no later than \(duration)")
                }
                end = parsed
            }
            if type.isRanged && end == nil {
                throw PlanError("\(path) (\(typeText)) needs an end time")
            }
            if !type.isRanged && end != nil {
                warnings.append("\(path) (\(typeText)): end is not used by this cue type")
            }
            var strength = WhipStrength.strike
            if let value = item["strength"] {
                guard let text = value as? String, let parsed = WhipStrength(rawValue: text) else {
                    throw PlanError("\(path).strength must be \"hero\" or \"strike\"")
                }
                strength = parsed
            }
            var result = CheckResult.waiting
            if let value = item["result"] {
                guard let text = value as? String, let parsed = CheckResult(rawValue: text) else {
                    throw PlanError("\(path).result must be \"waiting\" or \"available\"")
                }
                result = parsed
            }
            var cueDuration: Double?
            if let value = item["duration"] {
                let parsed = try Plan.number(value, "\(path).duration")
                guard parsed > 0 && parsed <= 10 else {
                    throw PlanError("\(path).duration must be above 0 and at most 10 seconds")
                }
                cueDuration = parsed
            }
            cues.append(Cue(index: i, time: time, type: type, pan: pan, end: end,
                            strength: strength, result: result, duration: cueDuration))
        }
        // Stable time order keeps rendering independent of how the file lists cues.
        cues.sort { $0.time != $1.time ? $0.time < $1.time : $0.index < $1.index }

        self.duration = duration
        self.bpm = bpm
        self.beatsPerBar = beatsPerBar
        self.sections = sections
        self.chords = chords
        self.cues = cues
        self.warnings = warnings
        self.sha256 = sha256
    }

    private static func number(_ value: Any?, _ path: String) throws -> Double {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
            throw PlanError("\(path) must be a number")
        }
        let result = number.doubleValue
        guard result.isFinite else {
            throw PlanError("\(path) must be finite")
        }
        return result
    }
}
