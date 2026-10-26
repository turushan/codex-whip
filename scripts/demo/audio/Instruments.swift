import Foundation

// Synthesized instruments. Every sound starts and ends on a smooth envelope so
// note boundaries never click.

/// Scales a buffer so its absolute peak equals `peak`.
func normalized(_ data: [Float], to peak: Double) -> [Float] {
    var maximum: Float = 0
    for x in data {
        maximum = max(maximum, abs(x))
    }
    guard maximum > 0 else { return data }
    let g = Float(peak) / maximum
    return data.map { $0 * g }
}

func normalized(_ left: [Float], _ right: [Float], to peak: Double) -> ([Float], [Float]) {
    var maximum: Float = 0
    for i in 0..<left.count {
        maximum = max(maximum, abs(left[i]), abs(right[i]))
    }
    guard maximum > 0 else { return (left, right) }
    let g = Float(peak) / maximum
    return (left.map { $0 * g }, right.map { $0 * g })
}

/// Raised cosine release over the last `fade` samples of `count`.
@inline(__always) func endFade(_ i: Int, _ count: Int, _ fade: Int) -> Double {
    let start = count - fade
    return i < start ? 1 : 1 - raisedCosine(Double(i - start) / Double(max(1, fade)))
}

enum Drums {
    /// Sine kick with a fast pitch drop (150 to 48 Hz), short click and gentle saturation.
    static func kick(velocity: Double, click: Double, seed s: UInt64) -> [Float] {
        let length = sampleIndex(0.42)
        var out = [Float](repeating: 0, count: length)
        var rng = SplitMix64(seed: s)
        var phase = 0.0
        var pitch = 1.0
        let pitchStep = decayFactor(0.03)
        var amp = 1.0
        let ampStep = decayFactor(0.12)
        var clickFilter = OnePole(cutoff: 2800)
        let clickLength = sampleIndex(0.006)
        let drive = 1.6
        let norm = 1 / tanh(drive)
        let attackLength = 0.0005 * sampleRate
        out.withUnsafeMutableBufferPointer { o in
            for i in 0..<length {
                let t = Double(i) / sampleRate
                let attack = min(1, Double(i) / attackLength)
                let tail = t > 0.32 ? 1 - raisedCosine((t - 0.32) / 0.1) : 1
                var x = sin(twoPi * phase) * amp * attack * tail
                if i < clickLength {
                    let white = rng.bipolar()
                    x += clickFilter.highpass(white) * click * 0.5 * exp(-t / 0.0009)
                }
                o[i] = Float(tanh(drive * x) * norm * velocity)
                advance(&phase, (48 + 102 * pitch) / sampleRate)
                pitch *= pitchStep
                amp *= ampStep
            }
        }
        return out
    }

    /// Four band-passed noise bursts about 10 ms apart, then a short tail.
    static func clap(velocity: Double, tone: Double, seed s: UInt64) -> ([Float], [Float]) {
        let length = sampleIndex(0.24)
        var rng = SplitMix64(seed: s)
        var offsets = [0.0, 0.0102, 0.0201, 0.0312]
        for j in 1..<offsets.count {
            offsets[j] += rng.range(-0.0008, 0.0008)
        }
        let amps = [0.72, 0.85, 0.95, 1.0]
        var burstL = Biquad.bandpass(tone, q: 1.5)
        var burstR = Biquad.bandpass(tone * 1.03, q: 1.5)
        var tailL = Biquad.bandpass(tone * 0.9, q: 0.85)
        var tailR = Biquad.bandpass(tone * 0.95, q: 0.85)
        var lowCutL = Biquad.highpass(420)
        var lowCutR = Biquad.highpass(420)
        var snapL = Biquad.bandpass(2400, q: 1.2)
        var snapR = Biquad.bandpass(2500, q: 1.2)
        var left = [Float](repeating: 0, count: length)
        var right = [Float](repeating: 0, count: length)
        let tailStart = offsets[3]
        for i in 0..<length {
            let t = Double(i) / sampleRate
            let common = rng.bipolar()
            let nl = 0.85 * common + 0.32 * rng.bipolar()
            let nr = 0.85 * common + 0.32 * rng.bipolar()
            var burst = 0.0
            for j in 0..<4 {
                let dt = t - offsets[j]
                if dt >= 0 {
                    burst += amps[j] * min(1, dt / 0.0003) * exp(-dt / 0.0032)
                }
            }
            var tail = 0.0
            if t >= tailStart {
                let dt = t - tailStart
                tail = min(1, dt / 0.002) * exp(-dt / 0.042) * (1 - raisedCosine((t - 0.19) / 0.05))
            }
            left[i] = Float(lowCutL.process((burstL.process(nl) + 0.45 * snapL.process(nl)) * burst + tailL.process(nl) * tail * 0.6))
            right[i] = Float(lowCutR.process((burstR.process(nr) + 0.45 * snapR.process(nr)) * burst + tailR.process(nr) * tail * 0.6))
        }
        return normalized(left, right, to: velocity)
    }

    /// Closed (about 40 ms) or open (about 200 ms) high-passed noise hat.
    static func hat(open: Bool, velocity: Double, bright: Bool, seed s: UInt64) -> ([Float], [Float]) {
        let length = sampleIndex(open ? 0.26 : 0.07)
        let fade = sampleIndex(open ? 0.05 : 0.02)
        var rng = SplitMix64(seed: s)
        var hp1L = Biquad.highpass(bright ? 6800 : 5200, q: 0.6)
        var hp2L = Biquad.highpass(bright ? 6000 : 4800, q: 0.6)
        var lpL = Biquad.lowpass(bright ? 14_000 : 8500, q: 0.6)
        var hp1R = hp1L
        var hp2R = hp2L
        var lpR = lpL
        var env = 1.0
        let step = decayFactor(open ? 0.07 : 0.0115)
        let attack = 0.0002 * sampleRate
        var left = [Float](repeating: 0, count: length)
        var right = [Float](repeating: 0, count: length)
        for i in 0..<length {
            let e = env * min(1, Double(i) / attack) * endFade(i, length, fade)
            let common = rng.bipolar()
            let nl = 0.8 * common + 0.3 * rng.bipolar()
            let nr = 0.8 * common + 0.3 * rng.bipolar()
            left[i] = Float(lpL.process(hp2L.process(hp1L.process(nl))) * e)
            right[i] = Float(lpR.process(hp2R.process(hp1R.process(nr))) * e)
            env *= step
        }
        return normalized(left, right, to: velocity)
    }

    /// Long filtered noise crash with a darkening tail.
    static func crash(velocity: Double, seed s: UInt64) -> ([Float], [Float]) {
        let length = sampleIndex(2.6)
        let fade = sampleIndex(0.4)
        var rng = SplitMix64(seed: s)
        var hpL = Biquad.highpass(420, q: 0.6)
        var hpR = Biquad.highpass(420, q: 0.6)
        var svfL = SVF()
        var svfR = SVF()
        var shimmerL = Biquad.bandpass(4300, q: 0.9)
        var shimmerR = Biquad.bandpass(4700, q: 0.9)
        var fast = 1.0
        var slow = 1.0
        let fastStep = decayFactor(0.45)
        let slowStep = decayFactor(1.25)
        let attack = sampleIndex(0.0015)
        var left = [Float](repeating: 0, count: length)
        var right = [Float](repeating: 0, count: length)
        for i in 0..<length {
            if i % 32 == 0 {
                let t = Double(i) / sampleRate
                let cutoff = 6000 + 7000 * exp(-t / 0.8)
                svfL.set(cutoff: cutoff, q: 0.6)
                svfR.set(cutoff: cutoff * 1.04, q: 0.6)
            }
            let nl = rng.bipolar()
            let nr = rng.bipolar()
            let env = (0.62 * fast + 0.38 * slow) * raisedCosine(Double(i) / Double(attack)) * endFade(i, length, fade)
            left[i] = Float((svfL.lowpass(hpL.process(nl)) + 0.3 * shimmerL.process(nl)) * env)
            right[i] = Float((svfR.lowpass(hpR.process(nr)) + 0.3 * shimmerR.process(nr)) * env)
            fast *= fastStep
            slow *= slowStep
        }
        return normalized(left, right, to: velocity)
    }

    /// Noise riser for builds: a band sweeping 500 Hz to 6 kHz, ending just before the impact.
    static func buildRiser(duration: Double, seed s: UInt64) -> ([Float], [Float]) {
        let length = max(2, sampleIndex(duration))
        let fadeIn = sampleIndex(0.02)
        let fadeOut = sampleIndex(0.015)
        var rng = SplitMix64(seed: s)
        var svfL = SVF()
        var svfR = SVF()
        var left = [Float](repeating: 0, count: length)
        var right = [Float](repeating: 0, count: length)
        for i in 0..<length {
            let u = Double(i) / Double(length)
            if i % 32 == 0 {
                let center = 500 * pow(12, u)
                svfL.set(cutoff: center, q: 1.2)
                svfR.set(cutoff: center * 1.03, q: 1.2)
            }
            let env = u * u * raisedCosine(Double(i) / Double(fadeIn)) * endFade(i, length, fadeOut)
            let common = rng.bipolar()
            left[i] = Float(svfL.bandpass(0.8 * common + 0.4 * rng.bipolar()) * env)
            right[i] = Float(svfR.bandpass(0.8 * common + 0.4 * rng.bipolar()) * env)
        }
        return normalized(left, right, to: 1)
    }
}

enum Synths {
    /// Sub sine plus a filtered saw an octave up, saturated for laptop audibility.
    static func bass(_ note: BassNote, bank: WaveBank) -> [Float] {
        let f0 = midiToHz(Double(note.midi))
        let release = note.style == .held ? 0.09 : 0.03
        let gate = sampleIndex(note.length)
        let length = gate + sampleIndex(release)
        let saw = bank.saw(maxFrequency: 2 * f0)
        var out = [Float](repeating: 0, count: length)
        var subPhase = 0.0
        var sawPhase = 0.0
        var lowCut = OnePole(cutoff: 95)
        var filter = SVF()
        let attack: Double
        switch note.style {
        case .sub: attack = 0.03
        case .held: attack = 0.05
        case .groove, .pulse: attack = 0.003
        }
        let sustainStep = decayFactor(note.style == .held ? 2.5 : 0.75)
        var level = 1.0
        let envelopeDepth = note.style == .groove || note.style == .pulse ? 1.3 : 0.2
        let drive = 1.3
        let norm = 1 / tanh(drive)
        let releaseLength = Double(max(1, length - gate))
        out.withUnsafeMutableBufferPointer { o in
            for i in 0..<length {
                let t = Double(i) / sampleRate
                if i % 16 == 0 {
                    filter.set(cutoff: note.cutoff * (1 + envelopeDepth * exp(-t / 0.06)), q: 0.85)
                }
                let a = smoothstep(t / attack)
                let r = i < gate ? 1 : 1 - raisedCosine(Double(i - gate) / releaseLength)
                let sub = sin(twoPi * subPhase)
                let x: Double
                if note.style == .sub {
                    x = sub * 0.92
                } else {
                    x = sub * 0.7 + filter.lowpass(lowCut.highpass(saw.read(sawPhase))) * 0.75
                }
                o[i] = Float(tanh(drive * x) * norm * a * r * level * note.velocity)
                advance(&subPhase, f0 / sampleRate)
                advance(&sawPhase, 2 * f0 / sampleRate)
                level *= sustainStep
            }
        }
        return out
    }

    /// Three detuned saws (about -7, 0, +7 cents) spread across the stereo field.
    /// Voices are summed before the shared pad filter.
    static func pad(_ note: PadNote, bank: WaveBank, gain: Double, into layer: Layer) {
        let f = midiToHz(Double(note.midi))
        let start = sampleIndex(note.start)
        let gate = max(1, sampleIndex(note.end) - start)
        let releaseLength = max(1, sampleIndex(note.release))
        let length = gate + releaseLength
        var rng = SplitMix64(seed: seed("pad", note.midi, start))
        let ratioA = centsRatio(-7 + rng.range(-1, 1))
        let ratioB = centsRatio(rng.range(-0.6, 0.6))
        let ratioC = centsRatio(7 + rng.range(-1, 1))
        let tableA = bank.saw(maxFrequency: f * ratioA * 1.002)
        let tableB = bank.saw(maxFrequency: f * ratioB * 1.002)
        let tableC = bank.saw(maxFrequency: f * ratioC * 1.002)
        var phaseA = rng.unit()
        var phaseB = rng.unit()
        var phaseC = rng.unit()
        let incA = f * ratioA / sampleRate
        let incB = f * ratioB / sampleRate
        let incC = f * ratioC / sampleRate
        let gA = panGains(-0.8)
        let gC = panGains(0.8)
        let attackLength = max(1, sampleIndex(note.attack))
        let from = max(0, layer.offset - start)
        let to = min(length, layer.end - start)
        guard from < to else { return }
        // Phases depend only on the note, so skipping samples outside the layer is safe.
        phaseA = (phaseA + incA * Double(from)).truncatingRemainder(dividingBy: 1)
        phaseB = (phaseB + incB * Double(from)).truncatingRemainder(dividingBy: 1)
        phaseC = (phaseC + incC * Double(from)).truncatingRemainder(dividingBy: 1)
        for i in from..<to {
            let a = i < attackLength ? raisedCosine(Double(i) / Double(attackLength)) : 1
            let r = i < gate ? 1 : 1 - raisedCosine(Double(i - gate) / Double(releaseLength))
            let e = a * r * gain
            let xa = tableA.read(phaseA)
            let xb = tableB.read(phaseB)
            let xc = tableC.read(phaseC)
            let n = start + i - layer.offset
            layer.left[n] += Float((xa * gA.left + xb + xc * gC.left) * e)
            layer.right[n] += Float((xa * gA.right + xb + xc * gC.right) * e)
            advance(&phaseA, incA)
            advance(&phaseB, incB)
            advance(&phaseC, incC)
        }
    }

    /// Four-pole low-pass shared by all pad voices, with slow cutoff drift.
    static func filterPad(_ layer: Layer, cutoff: (Int) -> Double) {
        var l1 = SVF()
        var l2 = SVF()
        var r1 = SVF()
        var r2 = SVF()
        for i in 0..<layer.frames {
            if i % 32 == 0 {
                let n = layer.offset + i
                let t = Double(n) / sampleRate
                let c = cutoff(n) * (1 + 0.12 * sin(twoPi * 0.13 * t))
                l1.set(cutoff: c, q: 0.6)
                l2.set(cutoff: c, q: 1.0)
                r1.set(cutoff: c * 1.03, q: 0.6)
                r2.set(cutoff: c * 1.03, q: 1.0)
            }
            layer.left[i] = Float(l2.lowpass(l1.lowpass(Double(layer.left[i]))))
            layer.right[i] = Float(r2.lowpass(r1.lowpass(Double(layer.right[i]))))
        }
    }

    /// Plucked saw and square with a fast filter envelope.
    static func pluck(_ note: PluckNote, bank: WaveBank, seed s: UInt64, release: Double = 0.05) -> ([Float], [Float]) {
        let f = midiToHz(Double(note.midi))
        let gate = sampleIndex(note.gate)
        let releaseLength = max(1, sampleIndex(release))
        let length = gate + releaseLength
        var rng = SplitMix64(seed: s)
        let ratioA = centsRatio(-4)
        let ratioB = centsRatio(4)
        let sawA = bank.saw(maxFrequency: f * ratioA * 1.002)
        let sawB = bank.saw(maxFrequency: f * ratioB * 1.002)
        let square = bank.square(maxFrequency: f * 1.002)
        var pa = rng.unit()
        var pb = rng.unit()
        var ps = rng.unit()
        var filterL = SVF()
        var filterR = SVF()
        let peak = clamp(note.cutoff, 300, 16_000)
        let floorCutoff = max(f * 1.2, peak * 0.16)
        var amp = 1.0
        let ampStep = decayFactor(note.decay)
        let (gl, gr) = panGains(note.pan)
        var left = [Float](repeating: 0, count: length)
        var right = [Float](repeating: 0, count: length)
        for i in 0..<length {
            if i % 8 == 0 {
                let t = Double(i) / sampleRate
                let c = floorCutoff + (peak - floorCutoff) * exp(-t / 0.055)
                filterL.set(cutoff: c, q: 1.0)
                filterR.set(cutoff: c, q: 1.0)
            }
            let a = min(1, Double(i) / 48)
            let r = i < gate ? 1 : 1 - raisedCosine(Double(i - gate) / Double(releaseLength))
            let x1 = sawA.read(pa)
            let x2 = sawB.read(pb)
            let sq = square.read(ps)
            let l = filterL.lowpass(0.75 * x1 + 0.3 * x2 + 0.28 * sq)
            let rr = filterR.lowpass(0.3 * x1 + 0.75 * x2 + 0.28 * sq)
            let e = amp * a * r * note.velocity
            left[i] = Float(l * e * gl)
            right[i] = Float(rr * e * gr)
            advance(&pa, f * ratioA / sampleRate)
            advance(&pb, f * ratioB / sampleRate)
            advance(&ps, f / sampleRate)
            amp *= ampStep
        }
        return (left, right)
    }

    /// FM bell, carrier to modulator 1:3.5, with a decaying index. The index is
    /// capped so no significant sideband reaches the harmonic ceiling.
    static func bell(midi: Double, velocity: Double, decay: Double, index: Double, length: Double? = nil) -> [Float] {
        let fc = midiToHz(midi)
        let fm = 3.5 * fc
        let maxIndex = max(0, (WaveBank.harmonicCeiling - fc) / fm - 1)
        let peakIndex = min(index, maxIndex)
        let count = sampleIndex(length ?? min(7, decay * 5.5))
        let fade = max(1, count / 10)
        // Phase modulation expands exactly into Bessel-weighted sidebands:
        // sin(wc t + I sin(wm t)) = sum over n of J_n(I) sin((wc + n wm) t).
        // Summing only the sidebands below the ceiling makes the bell strictly
        // band-limited, so nothing can fold back from above Nyquist.
        let order = Int(peakIndex.rounded(.up)) + 6
        var orders: [Int] = []
        var rotations: [(Double, Double)] = []
        for n in -order...order {
            let frequency = fc + Double(n) * fm
            if abs(frequency) < WaveBank.harmonicCeiling && frequency != 0 {
                orders.append(n)
                rotations.append((cos(twoPi * frequency / sampleRate), sin(twoPi * frequency / sampleRate)))
            }
        }
        let bands = orders.count
        var cosine = [Double](repeating: 1, count: bands)
        var sine = [Double](repeating: 0, count: bands)
        var weightNow = [Double](repeating: 0, count: bands)
        var weightNext = [Double](repeating: 0, count: bands)
        let block = 32
        let modulationTau = decay * 0.3
        func weights(_ i: Int, _ into: inout [Double]) {
            let x = peakIndex * exp(-Double(i) / sampleRate / modulationTau)
            for b in 0..<bands {
                into[b] = besselJ(orders[b], x)
            }
        }
        weights(0, &weightNext)
        var out = [Float](repeating: 0, count: count)
        var env = 1.0
        let envStep = decayFactor(decay)
        let attack = 0.0015 * sampleRate
        for i in 0..<count {
            if i % block == 0 {
                weightNow = weightNext
                weights(i + block, &weightNext)
                // Keep the rotating phasors on the unit circle.
                for b in 0..<bands {
                    let norm = 1 / (cosine[b] * cosine[b] + sine[b] * sine[b]).squareRoot()
                    cosine[b] *= norm
                    sine[b] *= norm
                }
            }
            let fraction = Double(i % block) / Double(block)
            var y = 0.0
            for b in 0..<bands {
                let w = weightNow[b] + (weightNext[b] - weightNow[b]) * fraction
                y += w * sine[b]
                let (c, s) = rotations[b]
                let nextCosine = cosine[b] * c - sine[b] * s
                sine[b] = sine[b] * c + cosine[b] * s
                cosine[b] = nextCosine
            }
            let a = min(1, Double(i) / attack)
            out[i] = Float(y * env * a * endFade(i, count, fade) * velocity)
            env *= envStep
        }
        return out
    }

    /// Bessel function of the first kind J_n(x) by its power series, accurate
    /// for the small modulation indexes used by the bells.
    static func besselJ(_ n: Int, _ x: Double) -> Double {
        let order = abs(n)
        var term = 1.0
        if order > 0 {
            for k in 1...order {
                term *= x / (2 * Double(k))
            }
        }
        var sum = term
        let q = -x * x / 4
        var k = 1
        while k < 80 {
            term *= q / (Double(k) * Double(k + order))
            sum += term
            if abs(term) <= 1e-16 * max(abs(sum), 1e-300) {
                break
            }
            k += 1
        }
        // J_-n(x) = (-1)^n J_n(x).
        return n < 0 && order % 2 == 1 ? -sum : sum
    }

    /// Low D drone: a sine plus two detuned, filtered saws that slowly open.
    static func drone(duration: Double, bank: WaveBank) -> ([Float], [Float]) {
        let f = midiToHz(38)
        let count = max(2, sampleIndex(duration))
        let ratioA = centsRatio(-5)
        let ratioB = centsRatio(5)
        let saw = bank.saw(maxFrequency: f * 1.01)
        var ps = 0.0
        var pa = 0.0
        var pb = 0.37
        var filterL = SVF()
        var filterR = SVF()
        let fadeOut = sampleIndex(0.006)
        var left = [Float](repeating: 0, count: count)
        var right = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let u = Double(i) / Double(count)
            if i % 32 == 0 {
                let cutoff = 170 + 480 * pow(u, 1.5)
                filterL.set(cutoff: cutoff, q: 0.9)
                filterR.set(cutoff: cutoff * 1.05, q: 0.9)
            }
            let env = smoothstep(u) * endFade(i, count, fadeOut)
            let sine = sin(twoPi * ps)
            left[i] = Float((0.7 * sine + 0.45 * filterL.lowpass(saw.read(pa))) * env)
            right[i] = Float((0.7 * sine + 0.45 * filterR.lowpass(saw.read(pb))) * env)
            advance(&ps, f / sampleRate)
            advance(&pa, f * ratioA / sampleRate)
            advance(&pb, f * ratioB / sampleRate)
        }
        return (left, right)
    }
}
