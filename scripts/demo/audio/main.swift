import Foundation

// render-score --plan plan.json --output score.wav --report report.json [--stems DIR]
//
// Renders the film's score and sound effects from the plan with original,
// deterministic procedural synthesis, masters to -16 LUFS and -1.5 dBTP, and
// writes a 48 kHz 24-bit stereo WAV plus a measurement report.

let sourceNote = "Original deterministic procedural synthesis; no samples or outside audio"

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data(("error: " + message + "\n").utf8))
    exit(code)
}

func uptime() -> Double {
    Double(DispatchTime.now().uptimeNanoseconds) / 1e9
}

struct Options {
    var plan = ""
    var output = ""
    var report = ""
    var stems: String?
}

func parseOptions() -> Options {
    let usage = "usage: render-score --plan plan.json --output score.wav --report report.json [--stems DIR]"
    var options = Options()
    var arguments = Array(CommandLine.arguments.dropFirst())
    if arguments.contains("--help") || arguments.contains("-h") {
        print(usage)
        exit(0)
    }
    while !arguments.isEmpty {
        let flag = arguments.removeFirst()
        guard !arguments.isEmpty else { fail("\(flag) needs a value\n\(usage)", code: 2) }
        let value = arguments.removeFirst()
        switch flag {
        case "--plan": options.plan = value
        case "--output": options.output = value
        case "--report": options.report = value
        case "--stems": options.stems = value
        default: fail("unknown option \(flag)\n\(usage)", code: 2)
        }
    }
    if options.plan.isEmpty || options.output.isEmpty || options.report.isEmpty {
        fail("--plan, --output and --report are required\n\(usage)", code: 2)
    }
    return options
}

func decode(_ samples: [Int32]) -> [Double] {
    samples.map { Double($0) / Master.fullScale }
}

func rmsDb(_ left: [Double], _ right: [Double], _ range: Range<Int>) -> Double {
    guard !range.isEmpty else { return -240 }
    var sum = 0.0
    for n in range {
        sum += left[n] * left[n] + right[n] * right[n]
    }
    return 10 * log10(max(sum / Double(2 * range.count), 1e-24))
}

func peakDb(_ left: [Double], _ right: [Double], _ range: Range<Int>) -> Double {
    var peak = 0.0
    for n in range {
        peak = max(peak, abs(left[n]), abs(right[n]))
    }
    return gainToDb(peak)
}

/// Index of the largest absolute sample over both channels in a window.
func peakIndex(_ left: UnsafePointer<Float>, _ right: UnsafePointer<Float>, frames: Int, around center: Int, radius: Int) -> Int {
    var best = center
    var value: Float = -1
    for n in max(0, center - radius)..<min(frames, center + radius + 1) {
        let v = max(abs(left[n]), abs(right[n]))
        if v > value {
            value = v
            best = n
        }
    }
    return best
}

func peakIndex(_ left: [Double], _ right: [Double], around center: Int, radius: Int) -> Int {
    var best = center
    var value = -1.0
    for n in max(0, center - radius)..<min(left.count, center + radius + 1) {
        let v = max(abs(left[n]), abs(right[n]))
        if v > value {
            value = v
            best = n
        }
    }
    return best
}

let options = parseOptions()
let started = uptime()

let plan: Plan
do {
    plan = try Plan.load(path: options.plan)
} catch {
    fail("\(error)")
}
for warning in plan.warnings {
    FileHandle.standardError.write(Data(("warning: " + warning + "\n").utf8))
}

let engine = Engine(plan: plan)
let stems = engine.render()
let mix = engine.mixdown(stems)
let master = Master.process(bed: mix.bed, whip: mix.whip)
let wavBytes = WAV.encode(left: master.left, right: master.right)
do {
    try WAV.write(wavBytes, to: options.output)
} catch {
    fail("cannot write \(options.output): \(error.localizedDescription)")
}
let outputHash = SHA256.hex(wavBytes)

// Measure what was written, from the quantized samples.
let left = decode(master.left)
let right = decode(master.right)
let frames = left.count
let loudness = Loudness.measure(left, right)
let truePeak = gainToDb(max(TruePeak.peak(left), TruePeak.peak(right)))
let samplePeak = peakDb(left, right, 0..<frames)
let staticGainDb = master.preSaturationGainDb + master.normalizationGainDb

var stemReport: JSON = .null
if let directory = options.stems {
    var loudest = 0.0
    for (_, layer) in stems.named {
        loudest = max(loudest, layer.peak())
    }
    let gain = min(dbToGain(staticGainDb), loudest > 0 ? 0.999 / loudest : 1)
    var files: [JSON] = []
    for (name, layer) in stems.named {
        var l = [Double](repeating: 0, count: frames)
        var r = [Double](repeating: 0, count: frames)
        for n in 0..<min(frames, layer.frames) {
            l[n] = Double(layer.left[n]) * gain
            r[n] = Double(layer.right[n]) * gain
        }
        let path = (directory as NSString).appendingPathComponent(name + ".wav")
        do {
            try WAV.write(WAV.encode(left: Master.quantize(l), right: Master.quantize(r)), to: path)
        } catch {
            fail("cannot write stem \(path): \(error.localizedDescription)")
        }
        files.append(.string(path))
    }
    stemReport = .object([
        ("directory", .string(directory)),
        ("gainDB", .number(gainToDb(gain), 2)),
        ("note", .string("Bus signals before the master chain, scaled by one static gain")),
        ("files", .array(files)),
    ])
}

// Whip alignment: the crack's absolute peak in the final output and in the whip bus.
var whipRows: [JSON] = []
var maxOffset = 0.0
for cue in plan.cues(.whip) {
    let center = sampleIndex(cue.time)
    let radius = sampleIndex(0.02)
    let peak = peakIndex(left, right, around: center, radius: radius)
    let stemPeak = peakIndex(stems.whip.left, stems.whip.right, frames: stems.whip.frames, around: center, radius: radius)
    let offset = Double(peak - center) / sampleRate * 1000
    maxOffset = max(maxOffset, abs(offset))
    whipRows.append(.object([
        ("time", .number(cue.time, 3)),
        ("strength", .string(cue.strength.rawValue)),
        ("pan", .number(cue.pan, 2)),
        ("cueSample", .integer(center)),
        ("peakSample", .integer(peak)),
        ("offsetMs", .number(offset, 3)),
        ("peakDBFS", .number(peakDb(left, right, peak..<(peak + 1)), 2)),
        ("whipBusPeakSample", .integer(stemPeak)),
    ]))
}

var sectionRows: [JSON] = []
for section in plan.sections {
    let range = sampleIndex(section.start)..<min(frames, sampleIndex(section.end))
    sectionRows.append(.object([
        ("name", .string(section.name.rawValue)),
        ("start", .number(section.start, 3)),
        ("end", .number(section.end, 3)),
        ("rmsDBFS", .number(rmsDb(left, right, range), 2)),
        ("peakDBFS", .number(peakDb(left, right, range), 2)),
    ]))
}

var busRows: [JSON] = []
let staticGain = dbToGain(staticGainDb)
for (name, layer) in stems.named {
    var l = [Double](repeating: 0, count: frames)
    var r = [Double](repeating: 0, count: frames)
    for n in 0..<min(frames, layer.frames) {
        l[n] = Double(layer.left[n]) * staticGain
        r[n] = Double(layer.right[n]) * staticGain
    }
    busRows.append(.object([
        ("name", .string(name)),
        ("integratedLUFS", .number(Loudness.integrated(l, r), 2)),
        ("peakDBFS", .number(peakDb(l, r, 0..<frames), 2)),
    ]))
}

// DC offset and low-frequency mono compatibility.
var sumL = 0.0
var sumR = 0.0
var crossLR = 0.0
var energyL = 0.0
var energyR = 0.0
var lowMid = 0.0
var lowSide = 0.0
// Eighth-order low-pass at 120 Hz, so the figure reflects only the sub band.
var midFilters = (0..<4).map { _ in Biquad.lowpass(120) }
var sideFilters = (0..<4).map { _ in Biquad.lowpass(120) }
for n in 0..<frames {
    sumL += left[n]
    sumR += right[n]
    crossLR += left[n] * right[n]
    energyL += left[n] * left[n]
    energyR += right[n] * right[n]
    var m = 0.5 * (left[n] + right[n])
    var s = 0.5 * (left[n] - right[n])
    for k in 0..<4 {
        m = midFilters[k].process(m)
        s = sideFilters[k].process(s)
    }
    lowMid += m * m
    lowSide += s * s
}

let renderSeconds = uptime() - started
let report = JSON.object([
    ("source", .string(sourceNote)),
    ("output", .string(options.output)),
    ("sha256", .string(outputHash)),
    ("format", .object([
        ("sampleRate", .integer(48_000)),
        ("channels", .integer(2)),
        ("bitsPerSample", .integer(24)),
        ("frames", .integer(frames)),
        ("durationSeconds", .number(Double(frames) / sampleRate, 3)),
    ])),
    ("loudness", .object([
        ("integratedLUFS", .number(loudness.integrated, 2)),
        ("targetLUFS", .number(Master.targetLufs, 1)),
        ("truePeakDBTP", .number(truePeak, 2)),
        ("truePeakMethod", .string("4x polyphase Kaiser-windowed sinc reconstruction")),
        ("samplePeakDBFS", .number(samplePeak, 2)),
        ("loudnessRangeLU", .number(loudness.range, 2)),
        ("maxMomentaryLUFS", .number(loudness.momentaryMax, 2)),
        ("maxShortTermLUFS", .number(loudness.shortTermMax, 2)),
    ])),
    ("master", .object([
        ("masterGainDB", .number(staticGainDb, 2)),
        ("preSaturationGainDB", .number(master.preSaturationGainDb, 2)),
        ("normalizationGainDB", .number(master.normalizationGainDb, 2)),
        ("highpassHz", .integer(25)),
        ("monoBelowHz", .integer(150)),
        ("glue", .object([
            ("ratio", .number(master.glue.ratio, 1)),
            ("thresholdDBFS", .number(master.glue.thresholdDbfs, 2)),
            ("averageReductionDB", .number(master.glue.averageReductionDb, 2)),
            ("loudPassageReductionDB", .number(master.glue.loudReductionDb, 2)),
            ("maxReductionDB", .number(master.glue.maxReductionDb, 2)),
        ])),
        ("saturation", .string("tanh, drive \(master.saturationDrive), 2x oversampled")),
        ("limiter", .object([
            ("ceilingDBTP", .number(master.limiter.ceilingDbtp, 3)),
            ("maxReductionDB", .number(master.limiter.maxReductionDb, 2)),
            ("limitedMilliseconds", .number(master.limiter.limitedMilliseconds, 1)),
        ])),
        ("iterations", .integer(master.iterations)),
    ])),
    ("sections", .array(sectionRows)),
    ("whips", .array(whipRows)),
    ("whipAlignment", .object([
        ("count", .integer(whipRows.count)),
        ("searchWindowMs", .number(20, 0)),
        ("maxAbsOffsetMs", .number(maxOffset, 3)),
        ("allWithin1ms", .bool(maxOffset <= 1.0)),
    ])),
    ("buses", .array(busRows)),
    ("dcOffset", .object([
        ("left", .number(sumL / Double(frames), 8)),
        ("right", .number(sumR / Double(frames), 8)),
    ])),
    ("stereo", .object([
        ("correlation", .number(crossLR / max((energyL * energyR).squareRoot(), 1e-24), 3)),
        ("sideToMidBelow120HzDB", .number(10 * log10(max(lowSide, 1e-24) / max(lowMid, 1e-24)), 1)),
    ])),
    ("stems", stemReport),
    ("plan", .object([
        ("path", .string(options.plan)),
        ("sha256", .string(plan.sha256)),
        ("durationSeconds", .number(plan.duration, 3)),
        ("bpm", .number(plan.bpm, 2)),
        ("sections", .integer(plan.sections.count)),
        ("chords", .integer(plan.chords.count)),
        ("cues", .integer(plan.cues.count)),
        ("warnings", .array(plan.warnings.map { .string($0) })),
    ])),
    ("renderSeconds", .number(renderSeconds, 2)),
])

do {
    let url = URL(fileURLWithPath: options.report)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data((report.rendered() + "\n").utf8).write(to: url)
} catch {
    fail("cannot write report \(options.report): \(error.localizedDescription)")
}

print(String(format: "wrote %@ (%.1f s, %.2f LUFS, %.2f dBTP, whip offset max %.3f ms) in %.2f s",
             options.output, Double(frames) / sampleRate, loudness.integrated, truePeak, maxOffset, renderSeconds))
print("sha256 \(outputHash)")
