import Foundation

// Time-based effects: a sixteen-line modulated feedback delay network reverb, a dotted
// eighth ping-pong delay, the tape stop and reversed reverb swells.

struct ReverbSettings {
    var rt60: Double
    var size: Double
    var predelay: Double
    var damping: Double
    var lowCut: Double
    var highCut: Double
    var diffusion: Double
    var modulation: Double
    var gain: Double

    /// The main room, RT60 about 1.6 s.
    static let room = ReverbSettings(rt60: 1.6, size: 1.0, predelay: 0.018, damping: 0.25, lowCut: 180,
                                     highCut: 9000, diffusion: 0.62, modulation: 5, gain: 0.5)
    /// A tighter, darker space for claps and hats.
    static let drums = ReverbSettings(rt60: 1.1, size: 0.9, predelay: 0.012, damping: 0.3, lowCut: 250,
                                      highCut: 8500, diffusion: 0.6, modulation: 4, gain: 0.5)
    /// The long variant for hero moments and the final chord.
    static let hall = ReverbSettings(rt60: 2.8, size: 1.35, predelay: 0.022, damping: 0.22, lowCut: 160,
                                     highCut: 8500, diffusion: 0.65, modulation: 6, gain: 0.5)
}

/// Delay line with a power-of-two buffer and fractional reads.
private final class DelayLine {
    let mask: Int
    let buffer: UnsafeMutablePointer<Double>
    var write = 0

    init(capacity: Int) {
        var size = 1
        while size < capacity + 4 {
            size <<= 1
        }
        mask = size - 1
        buffer = .allocate(capacity: size)
        buffer.initialize(repeating: 0, count: size)
    }

    deinit {
        buffer.deallocate()
    }

    @inline(__always) func read(_ delay: Int) -> Double {
        buffer[(write - delay) & mask]
    }

    @inline(__always) func read(fractional delay: Double) -> Double {
        let position = Double(write) - delay
        let base = position.rounded(.down)
        let i = Int(base)
        let fraction = position - base
        let a = buffer[i & mask]
        let b = buffer[(i + 1) & mask]
        return a + (b - a) * fraction
    }

    @inline(__always) func push(_ x: Double) {
        buffer[write & mask] = x
        write &+= 1
    }
}

/// Schroeder allpass used as an input diffuser.
private struct Allpass {
    let line: DelayLine
    let length: Int
    let gain: Double

    init(length: Int, gain: Double) {
        line = DelayLine(capacity: length + 1)
        self.length = length
        self.gain = gain
    }

    @inline(__always) func process(_ x: Double) -> Double {
        let delayed = line.read(length)
        let w = x + gain * delayed
        line.push(w)
        return delayed - gain * w
    }
}

/// Sixteen-line feedback delay network: input diffusion allpasses, an
/// orthogonal Hadamard mix, one-pole damping in every loop and slow delay
/// modulation on every line so no single mode rings out.
final class FDNReverb {
    private static let lineCount = 16
    private static let baseLengths = [709, 787, 859, 947, 1039, 1129, 1223, 1327,
                                      1433, 1553, 1667, 1801, 1949, 2099, 2251, 2423]
    private static let diffuserLeft = [142, 107, 379, 277]
    private static let diffuserRight = [151, 113, 389, 263]

    private let settings: ReverbSettings

    init(_ settings: ReverbSettings) {
        self.settings = settings
    }

    /// Adds the wet response to `input` into `output`, over the active input
    /// range plus the decay tail.
    func process(input: Layer, output: Layer, gain: Double = 1) {
        guard let active = input.activeRange() else { return }
        let count = FDNReverb.lineCount
        let tail = sampleIndex(settings.rt60 * 1.3 + settings.predelay + 0.1)
        let from = active.lowerBound
        let to = min(max(input.end, output.end), active.upperBound + tail)
        let depth = settings.modulation
        let lengths = FDNReverb.baseLengths.map { Double(Int((Double($0) * settings.size).rounded())) }
        let lines = lengths.map { DelayLine(capacity: Int($0) + 2 * Int(depth.rounded(.up)) + 4) }
        // The mean delay includes the modulation offset, so the decay matches RT60.
        let feedback = lengths.map { pow(10, -3 * ($0 + depth) / (settings.rt60 * sampleRate)) }
        let predelay = max(1, sampleIndex(settings.predelay))
        let preLeft = DelayLine(capacity: predelay + 1)
        let preRight = DelayLine(capacity: predelay + 1)
        let diffL = FDNReverb.diffuserLeft.map { Allpass(length: Int(Double($0) * settings.size), gain: settings.diffusion) }
        let diffR = FDNReverb.diffuserRight.map { Allpass(length: Int(Double($0) * settings.size), gain: settings.diffusion) }
        var lowL = Biquad.highpass(settings.lowCut, q: 0.7071)
        var lowR = Biquad.highpass(settings.lowCut, q: 0.7071)
        var highL = Biquad.lowpass(settings.highCut, q: 0.7071)
        var highR = Biquad.lowpass(settings.highCut, q: 0.7071)
        let damping = settings.damping
        let outputGain = settings.gain * gain * 0.25
        // Each line gets its own slow sine LFO, advanced by a unit-circle rotation.
        let lfoCos = UnsafeMutablePointer<Double>.allocate(capacity: count)
        let lfoSin = UnsafeMutablePointer<Double>.allocate(capacity: count)
        let rotCos = UnsafeMutablePointer<Double>.allocate(capacity: count)
        let rotSin = UnsafeMutablePointer<Double>.allocate(capacity: count)
        let state = UnsafeMutablePointer<Double>.allocate(capacity: count)
        let f = UnsafeMutablePointer<Double>.allocate(capacity: count)
        defer {
            lfoCos.deallocate()
            lfoSin.deallocate()
            rotCos.deallocate()
            rotSin.deallocate()
            state.deallocate()
            f.deallocate()
        }
        for j in 0..<count {
            let rate = 0.09 + 0.057 * Double(j)
            let phase = 1.7 * Double(j)
            lfoCos[j] = cos(phase)
            lfoSin[j] = sin(phase)
            rotCos[j] = cos(twoPi * rate / sampleRate)
            rotSin[j] = sin(twoPi * rate / sampleRate)
            state[j] = 0
            f[j] = 0
        }
        // Output taps are two orthogonal Hadamard rows, so left and right decorrelate.
        let signLeft: [Double] = (0..<count).map { $0 & 1 == 0 ? 1 : -1 }
        let signRight: [Double] = (0..<count).map { $0 & 2 == 0 ? 1 : -1 }
        var step = 0
        for n in from..<to {
            var xl = 0.0
            var xr = 0.0
            if n < active.upperBound && n >= input.offset && n < input.end {
                xl = Double(input.left[n - input.offset])
                xr = Double(input.right[n - input.offset])
            }
            preLeft.push(xl)
            preRight.push(xr)
            var dl = preLeft.read(predelay)
            var dr = preRight.read(predelay)
            for a in 0..<4 {
                dl = diffL[a].process(dl)
                dr = diffR[a].process(dr)
            }
            for j in 0..<count {
                let o = lines[j].read(fractional: lengths[j] + depth + depth * lfoSin[j])
                let c = lfoCos[j] * rotCos[j] - lfoSin[j] * rotSin[j]
                lfoSin[j] = lfoSin[j] * rotCos[j] + lfoCos[j] * rotSin[j]
                lfoCos[j] = c
                state[j] = o + damping * (state[j] - o)
                f[j] = state[j] * feedback[j]
            }
            var h = 1
            while h < count {
                var i = 0
                while i < count {
                    for j in i..<(i + h) {
                        let a = f[j]
                        let b = f[j + h]
                        f[j] = a + b
                        f[j + h] = a - b
                    }
                    i += 2 * h
                }
                h *= 2
            }
            var wetL = 0.0
            var wetR = 0.0
            for j in 0..<count {
                let injected = (j & 1 == 0 ? dl : dr) * (j & 2 == 0 ? 1 : -1)
                lines[j].push(f[j] * 0.25 + injected)
                wetL += signLeft[j] * state[j]
                wetR += signRight[j] * state[j]
            }
            step += 1
            if step == 4096 {
                step = 0
                for j in 0..<count {
                    let norm = 1 / (lfoCos[j] * lfoCos[j] + lfoSin[j] * lfoSin[j]).squareRoot()
                    lfoCos[j] *= norm
                    lfoSin[j] *= norm
                }
            }
            let yl = highL.process(lowL.process(wetL * outputGain))
            let yr = highR.process(lowR.process(wetR * outputGain))
            if n >= output.offset && n < output.end {
                output.left[n - output.offset] += Float(yl)
                output.right[n - output.offset] += Float(yr)
            }
        }
    }
}

/// Ping-pong delay: the first echo lands left, then right, with filtered feedback.
final class PingPongDelay {
    private let delay: Int
    private let feedback: Double

    init(seconds: Double, feedback: Double) {
        delay = max(1, sampleIndex(seconds))
        self.feedback = feedback
    }

    func process(input: Layer, output: Layer, gain: Double = 1) {
        guard let active = input.activeRange() else { return }
        let bounces = Int((log(1e-4) / log(max(feedback, 0.01))).rounded(.up)) + 1
        let to = min(output.end, active.upperBound + delay * bounces)
        let lineL = DelayLine(capacity: delay + 1)
        let lineR = DelayLine(capacity: delay + 1)
        var lpL = OnePole(cutoff: 4200)
        var lpR = OnePole(cutoff: 4200)
        var hpL = OnePole(cutoff: 240)
        var hpR = OnePole(cutoff: 240)
        for n in active.lowerBound..<to {
            var mono = 0.0
            if n < active.upperBound && n >= input.offset && n < input.end {
                mono = 0.5 * Double(input.left[n - input.offset] + input.right[n - input.offset])
            }
            let outL = lineL.read(delay)
            let outR = lineR.read(delay)
            let toLeft = hpL.highpass(lpL.lowpass(outR))
            let toRight = hpR.highpass(lpR.lowpass(outL))
            lineL.push(mono + feedback * toLeft)
            lineR.push(feedback * toRight)
            if n >= output.offset && n < output.end {
                output.left[n - output.offset] += Float(outL * gain)
                output.right[n - output.offset] += Float(outR * gain)
            }
        }
    }
}

/// Tape stop: playback speed falls linearly from 1 to 0 while a low-pass
/// closes, then the layer stays silent until `silenceEnd`.
func applyTapeStop(_ layer: Layer, start: Int, duration: Int, silenceEnd: Int) {
    let warm = 512
    let from = start - warm
    let readEnd = start + duration / 2 + 8
    let count = readEnd - from + 4
    var original = [Double](repeating: 0, count: count * 2)
    for i in 0..<count {
        let n = from + i
        if n >= layer.offset && n < layer.end {
            original[2 * i] = Double(layer.left[n - layer.offset])
            original[2 * i + 1] = Double(layer.right[n - layer.offset])
        }
    }
    func sample(_ position: Double, _ channel: Int) -> Double {
        let base = position.rounded(.down)
        let i = Int(base)
        let t = position - base
        func x(_ k: Int) -> Double {
            let j = min(max(k, 0), count - 1)
            return original[2 * j + channel]
        }
        let x0 = x(i - 1)
        let x1 = x(i)
        let x2 = x(i + 1)
        let x3 = x(i + 2)
        let c1 = 0.5 * (x2 - x0)
        let c2 = x0 - 2.5 * x1 + 2 * x2 - 0.5 * x3
        let c3 = 0.5 * (x3 - x0) + 1.5 * (x1 - x2)
        return ((c3 * t + c2) * t + c1) * t + x1
    }
    var lpL = SVF(cutoff: 18_000, q: 0.6)
    var lpR = SVF(cutoff: 18_000, q: 0.6)
    // Warm the filters on the material just before the stop so the hand-off is seamless.
    for i in 0..<warm {
        _ = lpL.lowpass(original[2 * i])
        _ = lpR.lowpass(original[2 * i + 1])
    }
    let total = Double(duration) / sampleRate
    let handoff = sampleIndex(0.002)
    for i in 0..<duration {
        let n = start + i
        let tau = Double(i) / sampleRate
        let u = tau / total
        let v = 1 - u
        if i % 16 == 0 {
            let cutoff = 150 + 17_850 * v * v
            lpL.set(cutoff: cutoff, q: 0.6)
            lpR.set(cutoff: cutoff, q: 0.6)
        }
        let position = Double(warm) + (tau - tau * tau / (2 * total)) * sampleRate
        let gain = pow(v, 0.6) * (u > 0.88 ? 1 - raisedCosine((u - 0.88) / 0.12) : 1)
        var yl = lpL.lowpass(sample(position, 0)) * gain
        var yr = lpR.lowpass(sample(position, 1)) * gain
        // Cross-fade from the untouched signal over 2 ms so the hand-off is seamless.
        if i < handoff {
            let w = raisedCosine(Double(i) / Double(handoff))
            yl = original[2 * (warm + i)] * (1 - w) + yl * w
            yr = original[2 * (warm + i) + 1] * (1 - w) + yr * w
        }
        if n >= layer.offset && n < layer.end {
            layer.left[n - layer.offset] = Float(yl)
            layer.right[n - layer.offset] = Float(yr)
        }
    }
    layer.clear(from: start + duration, to: silenceEnd)
}

/// A reverb tail of `source`, reversed so it swells into an impact. The
/// returned stereo pair ends at the reverb onset, its loudest point.
func reverseSwell(seconds: Double, source: Clip, settings: ReverbSettings) -> ([Float], [Float]) {
    let n = max(2, sampleIndex(seconds))
    let onset = sampleIndex(settings.predelay)
    let input = Layer(frames: n + onset + sampleIndex(0.05))
    input.add(source)
    let wet = Layer(frames: input.frames)
    FDNReverb(settings).process(input: input, output: wet)
    var left = [Float](repeating: 0, count: n)
    var right = [Float](repeating: 0, count: n)
    for i in 0..<n {
        let k = onset + n - 1 - i
        left[i] = wet.left[k]
        right[i] = wet.right[k]
    }
    let fade = sampleIndex(0.003)
    for i in 0..<n {
        let g = Float(endFade(i, n, fade))
        left[i] *= g
        right[i] *= g
    }
    return normalized(left, right, to: 1)
}
