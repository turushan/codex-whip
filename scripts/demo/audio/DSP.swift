import Foundation

// Shared DSP building blocks: constants, band-limited wavetables, filters,
// clips (short rendered sounds) and layers (long bus buffers).

let sampleRate = 48_000.0
let twoPi = 2.0 * Double.pi
let sqrtTwo = 2.0.squareRoot()

@inline(__always) func clamp(_ x: Double, _ low: Double, _ high: Double) -> Double {
    min(max(x, low), high)
}

@inline(__always) func midiToHz(_ midi: Double) -> Double {
    440.0 * pow(2.0, (midi - 69.0) / 12.0)
}

@inline(__always) func dbToGain(_ db: Double) -> Double {
    pow(10.0, db / 20.0)
}

@inline(__always) func gainToDb(_ gain: Double) -> Double {
    gain > 1e-12 ? 20.0 * log10(gain) : -240.0
}

@inline(__always) func sampleIndex(_ seconds: Double) -> Int {
    Int((seconds * sampleRate).rounded())
}

@inline(__always) func smoothstep(_ x: Double) -> Double {
    let t = clamp(x, 0, 1)
    return t * t * (3 - 2 * t)
}

/// Raised cosine from 0 to 1 as x goes from 0 to 1.
@inline(__always) func raisedCosine(_ x: Double) -> Double {
    let t = clamp(x, 0, 1)
    return 0.5 - 0.5 * cos(Double.pi * t)
}

/// Per-sample multiplier for an exponential decay with the given time constant.
@inline(__always) func decayFactor(_ seconds: Double) -> Double {
    exp(-1.0 / (max(seconds, 1e-6) * sampleRate))
}

@inline(__always) func centsRatio(_ cents: Double) -> Double {
    pow(2.0, cents / 1200.0)
}

/// Constant power pan with unity gain in both channels at the center.
@inline(__always) func panGains(_ pan: Double) -> (left: Double, right: Double) {
    let angle = (clamp(pan, -1, 1) + 1) * 0.25 * Double.pi
    return (cos(angle) * sqrtTwo, sin(angle) * sqrtTwo)
}

// MARK: - Band-limited wavetables

/// One cycle of a saw or square built from a finite harmonic series, so a
/// table chosen for a note's highest frequency never folds above Nyquist.
final class WaveTable {
    static let size = 2048
    static let sine: [Double] = (0..<size).map { sin(twoPi * Double($0) / Double(size)) }

    let data: UnsafeMutablePointer<Float>

    init(harmonics: Int, oddOnly: Bool) {
        let n = WaveTable.size
        data = .allocate(capacity: n + 1)
        var accumulator = [Double](repeating: 0, count: n)
        let sine = WaveTable.sine
        var k = 1
        while k <= max(1, harmonics) {
            // Saw: -(2/pi) sum sin(k x)/k rises from -1 to 1. Square: (4/pi) odd terms.
            let amplitude = oddOnly ? 4.0 / (Double.pi * Double(k)) : -2.0 / (Double.pi * Double(k))
            var index = 0
            for i in 0..<n {
                accumulator[i] += amplitude * sine[index]
                index = (index + k) & (n - 1)
            }
            k += oddOnly ? 2 : 1
        }
        for i in 0..<n {
            data[i] = Float(accumulator[i])
        }
        data[n] = data[0]
    }

    deinit {
        data.deallocate()
    }

    /// Linear interpolated read; phase must be in [0, 1).
    @inline(__always) func read(_ phase: Double) -> Double {
        let position = phase * Double(WaveTable.size)
        let i = Int(position)
        let fraction = position - Double(i)
        let a = Double(data[i])
        let b = Double(data[i + 1])
        return a + (b - a) * fraction
    }
}

/// Caches tables by harmonic count. Lookups only, never iteration, so the
/// randomized dictionary order cannot affect the output.
final class WaveBank {
    static let harmonicCeiling = 19_000.0
    private var saws: [Int: WaveTable] = [:]
    private var squares: [Int: WaveTable] = [:]

    func saw(maxFrequency: Double) -> WaveTable {
        let count = max(1, Int(WaveBank.harmonicCeiling / max(maxFrequency, 1)))
        if let table = saws[count] {
            return table
        }
        let table = WaveTable(harmonics: count, oddOnly: false)
        saws[count] = table
        return table
    }

    func square(maxFrequency: Double) -> WaveTable {
        let count = max(1, Int(WaveBank.harmonicCeiling / max(maxFrequency, 1)))
        if let table = squares[count] {
            return table
        }
        let table = WaveTable(harmonics: count, oddOnly: true)
        squares[count] = table
        return table
    }
}

/// Advances a normalized phase and wraps it into [0, 1).
@inline(__always) func advance(_ phase: inout Double, _ increment: Double) {
    phase += increment
    if phase >= 1 {
        phase -= floor(phase)
    }
}

// MARK: - Filters

/// Topology-preserving state variable filter (Zavalishin), stable under fast
/// cutoff modulation.
struct SVF {
    private var ic1 = 0.0
    private var ic2 = 0.0
    private var a1 = 0.0
    private var a2 = 0.0
    private var a3 = 0.0
    private(set) var k = 1.414

    init() {}

    init(cutoff: Double, q: Double) {
        set(cutoff: cutoff, q: q)
    }

    @inline(__always) mutating func set(cutoff: Double, q: Double) {
        let frequency = clamp(cutoff, 10, sampleRate * 0.475)
        let g = tan(Double.pi * frequency / sampleRate)
        k = 1.0 / max(q, 0.05)
        a1 = 1.0 / (1.0 + g * (g + k))
        a2 = g * a1
        a3 = g * a2
    }

    @inline(__always) mutating func tick(_ v0: Double) -> (low: Double, band: Double, high: Double) {
        let v3 = v0 - ic2
        let v1 = a1 * ic1 + a2 * v3
        let v2 = ic2 + a2 * ic1 + a3 * v3
        ic1 = 2.0 * v1 - ic1
        ic2 = 2.0 * v2 - ic2
        return (v2, v1, v0 - k * v1 - v2)
    }

    @inline(__always) mutating func lowpass(_ x: Double) -> Double {
        tick(x).low
    }

    /// Band output scaled to unity gain at the center frequency.
    @inline(__always) mutating func bandpass(_ x: Double) -> Double {
        k * tick(x).band
    }

    @inline(__always) mutating func highpass(_ x: Double) -> Double {
        tick(x).high
    }
}

/// Transposed direct form II biquad with RBJ cookbook designs.
struct Biquad {
    private(set) var b0 = 1.0
    private(set) var b1 = 0.0
    private(set) var b2 = 0.0
    private(set) var a1 = 0.0
    private(set) var a2 = 0.0
    private var z1 = 0.0
    private var z2 = 0.0

    init(b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) {
        self.b0 = b0
        self.b1 = b1
        self.b2 = b2
        self.a1 = a1
        self.a2 = a2
    }

    private init(_ b0: Double, _ b1: Double, _ b2: Double, _ a0: Double, _ a1: Double, _ a2: Double) {
        self.init(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0)
    }

    @inline(__always) mutating func process(_ x: Double) -> Double {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }

    private static func omega(_ frequency: Double) -> (cosine: Double, sine: Double) {
        let w = twoPi * clamp(frequency, 1, sampleRate * 0.49) / sampleRate
        return (cos(w), sin(w))
    }

    static func lowpass(_ frequency: Double, q: Double = 0.7071) -> Biquad {
        let (c, s) = omega(frequency)
        let alpha = s / (2 * q)
        return Biquad((1 - c) / 2, 1 - c, (1 - c) / 2, 1 + alpha, -2 * c, 1 - alpha)
    }

    static func highpass(_ frequency: Double, q: Double = 0.7071) -> Biquad {
        let (c, s) = omega(frequency)
        let alpha = s / (2 * q)
        return Biquad((1 + c) / 2, -(1 + c), (1 + c) / 2, 1 + alpha, -2 * c, 1 - alpha)
    }

    /// Band-pass with unity gain at the center frequency.
    static func bandpass(_ frequency: Double, q: Double) -> Biquad {
        let (c, s) = omega(frequency)
        let alpha = s / (2 * q)
        return Biquad(alpha, 0, -alpha, 1 + alpha, -2 * c, 1 - alpha)
    }

    static func peaking(_ frequency: Double, q: Double, gainDb: Double) -> Biquad {
        let (c, s) = omega(frequency)
        let alpha = s / (2 * q)
        let a = pow(10, gainDb / 40)
        return Biquad(1 + alpha * a, -2 * c, 1 - alpha * a, 1 + alpha / a, -2 * c, 1 - alpha / a)
    }

    static func highShelf(_ frequency: Double, gainDb: Double) -> Biquad {
        let (c, s) = omega(frequency)
        let a = pow(10, gainDb / 40)
        let alpha = s / 2 * sqrtTwo
        let root = 2 * a.squareRoot() * alpha
        return Biquad(
            a * ((a + 1) + (a - 1) * c + root),
            -2 * a * ((a - 1) + (a + 1) * c),
            a * ((a + 1) + (a - 1) * c - root),
            (a + 1) - (a - 1) * c + root,
            2 * ((a - 1) - (a + 1) * c),
            (a + 1) - (a - 1) * c - root
        )
    }
}

/// One-pole smoother used for gentle tone shaping and envelopes.
struct OnePole {
    private var state = 0.0
    private let coefficient: Double

    init(cutoff: Double) {
        coefficient = 1 - exp(-twoPi * cutoff / sampleRate)
    }

    @inline(__always) mutating func lowpass(_ x: Double) -> Double {
        state += coefficient * (x - state)
        return state
    }

    @inline(__always) mutating func highpass(_ x: Double) -> Double {
        x - lowpass(x)
    }
}

// MARK: - Clips and layers

/// A short stereo sound positioned at an absolute sample index.
struct Clip {
    var start: Int
    var left: [Float]
    var right: [Float]

    init(start: Int, count: Int) {
        self.start = start
        left = [Float](repeating: 0, count: max(0, count))
        right = [Float](repeating: 0, count: max(0, count))
    }

    init(start: Int, left: [Float], right: [Float]) {
        self.start = start
        self.left = left
        self.right = right
    }

    var count: Int {
        left.count
    }

    /// A mono signal placed with a constant power pan.
    init(start: Int, mono: [Float], pan: Double) {
        let (gl, gr) = panGains(pan)
        self.start = start
        left = mono.map { $0 * Float(gl) }
        right = mono.map { $0 * Float(gr) }
    }

    func peak() -> Double {
        var value: Float = 0
        for i in 0..<count {
            value = max(value, abs(left[i]), abs(right[i]))
        }
        return Double(value)
    }

    mutating func scale(_ gain: Double) {
        let g = Float(gain)
        for i in 0..<count {
            left[i] *= g
            right[i] *= g
        }
    }

    mutating func add(_ other: Clip, gain: Double = 1) {
        let g = Float(gain)
        let from = max(start, other.start)
        let to = min(start + count, other.start + other.count)
        guard from < to else { return }
        for n in from..<to {
            left[n - start] += other.left[n - other.start] * g
            right[n - start] += other.right[n - other.start] * g
        }
    }
}

/// A long stereo buffer covering [offset, offset + frames) in absolute samples.
final class Layer {
    let offset: Int
    let frames: Int
    let left: UnsafeMutablePointer<Float>
    let right: UnsafeMutablePointer<Float>

    init(offset: Int = 0, frames: Int) {
        self.offset = offset
        self.frames = max(0, frames)
        let capacity = max(1, frames)
        left = .allocate(capacity: capacity)
        left.initialize(repeating: 0, count: capacity)
        right = .allocate(capacity: capacity)
        right.initialize(repeating: 0, count: capacity)
    }

    deinit {
        left.deallocate()
        right.deallocate()
    }

    var end: Int {
        offset + frames
    }

    func add(_ clip: Clip, gain: Double = 1) {
        guard gain != 0 else { return }
        let g = Float(gain)
        let from = max(clip.start, offset)
        let to = min(clip.start + clip.count, end)
        guard from < to else { return }
        clip.left.withUnsafeBufferPointer { cl in
            clip.right.withUnsafeBufferPointer { cr in
                for n in from..<to {
                    left[n - offset] += cl[n - clip.start] * g
                    right[n - offset] += cr[n - clip.start] * g
                }
            }
        }
    }

    func addMono(_ data: [Float], start: Int, gainLeft: Double, gainRight: Double) {
        let gl = Float(gainLeft)
        let gr = Float(gainRight)
        let from = max(start, offset)
        let to = min(start + data.count, end)
        guard from < to else { return }
        data.withUnsafeBufferPointer { d in
            for n in from..<to {
                let x = d[n - start]
                left[n - offset] += x * gl
                right[n - offset] += x * gr
            }
        }
    }

    func add(_ other: Layer, gain: Double = 1) {
        guard gain != 0 else { return }
        let g = Float(gain)
        let from = max(offset, other.offset)
        let to = min(end, other.end)
        guard from < to else { return }
        for n in from..<to {
            left[n - offset] += other.left[n - other.offset] * g
            right[n - offset] += other.right[n - other.offset] * g
        }
    }

    /// Multiplies by a gain curve indexed by absolute sample.
    func multiply(by gains: [Float]) {
        let to = min(end, gains.count)
        guard offset < to else { return }
        gains.withUnsafeBufferPointer { g in
            for n in offset..<to {
                left[n - offset] *= g[n]
                right[n - offset] *= g[n]
            }
        }
    }

    /// Absolute range of samples that are not exactly zero.
    func activeRange() -> Range<Int>? {
        var first = -1
        for i in 0..<frames where left[i] != 0 || right[i] != 0 {
            first = i
            break
        }
        guard first >= 0 else { return nil }
        var last = first
        var i = frames - 1
        while i > first {
            if left[i] != 0 || right[i] != 0 {
                last = i
                break
            }
            i -= 1
        }
        return (offset + first)..<(offset + last + 1)
    }

    func clear(from: Int, to: Int) {
        let a = max(from, offset)
        let b = min(to, end)
        guard a < b else { return }
        for n in a..<b {
            left[n - offset] = 0
            right[n - offset] = 0
        }
    }

    /// Smooth fade to silence starting at an absolute sample; everything later is cleared.
    func cut(at sample: Int, fade: Int) {
        let fadeLength = max(1, fade)
        for i in 0..<fadeLength {
            let n = sample + i
            guard n >= offset && n < end else { continue }
            let g = Float(1 - raisedCosine(Double(i) / Double(fadeLength)))
            left[n - offset] *= g
            right[n - offset] *= g
        }
        clear(from: sample + fadeLength, to: end)
    }

    func peak() -> Double {
        var value: Float = 0
        for i in 0..<frames {
            value = max(value, abs(left[i]), abs(right[i]))
        }
        return Double(value)
    }
}

// MARK: - Control curves

/// Automation sampled every 32 samples and linearly interpolated.
final class ControlCurve {
    static let block = 32
    let values: [Double]

    init(frames: Int, _ function: (Double) -> Double) {
        let count = frames / ControlCurve.block + 3
        var result = [Double](repeating: 0, count: count)
        for i in 0..<count {
            result[i] = function(Double(i * ControlCurve.block) / sampleRate)
        }
        values = result
    }

    @inline(__always) func at(_ sample: Int) -> Double {
        let position = Double(max(0, sample)) / Double(ControlCurve.block)
        let i = min(Int(position), values.count - 2)
        let fraction = min(1, position - Double(i))
        return values[i] + (values[i + 1] - values[i]) * fraction
    }

    func at(time: Double) -> Double {
        at(Int((time * sampleRate).rounded()))
    }
}
