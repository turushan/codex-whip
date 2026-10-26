import Foundation

// Interface and story sound effects, one renderer per cue type. Tonal cues use
// pitches from D minor and F major; pops follow the chord under them.

struct CueSound {
    var clip: Clip
    var verbSend: Double
    var hallSend: Double
}

extension Clip {
    mutating func addMono(_ data: [Float], at offset: Int, gain: Double, pan: Double) {
        let (gl, gr) = panGains(pan)
        let fl = Float(gain * gl)
        let fr = Float(gain * gr)
        let from = max(0, -offset)
        let to = min(data.count, count - offset)
        guard from < to else { return }
        for i in from..<to {
            left[offset + i] += data[i] * fl
            right[offset + i] += data[i] * fr
        }
    }

    /// Adds a stereo pair; `pan` acts as a balance control.
    mutating func addStereo(_ l: [Float], _ r: [Float], at offset: Int, gain: Double, pan: Double = 0) {
        let (gl, gr) = panGains(pan)
        let fl = Float(gain * gl)
        let fr = Float(gain * gr)
        let from = max(0, -offset)
        let to = min(l.count, count - offset)
        guard from < to else { return }
        for i in from..<to {
            left[offset + i] += l[i] * fl
            right[offset + i] += r[i] * fr
        }
    }
}

enum Tones {
    /// A band-passed noise tick with a fast exponential decay.
    static func noiseClick(center: Double, q: Double, decay: Double, length: Double, seed s: UInt64) -> [Float] {
        let n = max(2, sampleIndex(length))
        var rng = SplitMix64(seed: s)
        var filter = Biquad.bandpass(center, q: q)
        var second = Biquad.bandpass(center, q: q)
        var env = 1.0
        let step = decayFactor(decay)
        let attack = 0.0004 * sampleRate
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let x = second.process(filter.process(rng.bipolar()))
            out[i] = Float(x * env * min(1, Double(i) / attack) * endFade(i, n, max(1, n / 5)))
            env *= step
        }
        return normalized(out, to: 1)
    }

    static func blip(frequency: Double, decay: Double, length: Double) -> [Float] {
        let n = max(2, sampleIndex(length))
        var phase = 0.0
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = Double(i) / sampleRate
            out[i] = Float(sin(twoPi * phase) * min(1, t / 0.0004) * exp(-t / decay) * endFade(i, n, n / 4))
            advance(&phase, frequency / sampleRate)
        }
        return out
    }

    /// Wood-block style tick: a tuned partial, an inharmonic overtone and a knock.
    static func woodTick(frequency: Double, seed s: UInt64) -> [Float] {
        let n = sampleIndex(0.06)
        var rng = SplitMix64(seed: s)
        var knockFilter = Biquad.bandpass(3000, q: 1.2)
        var out = [Float](repeating: 0, count: n)
        var p1 = 0.0
        var p2 = 0.0
        for i in 0..<n {
            let t = Double(i) / sampleRate
            let body = sin(twoPi * p1) * exp(-t / 0.010) + 0.3 * sin(twoPi * p2) * exp(-t / 0.004)
            let knock = knockFilter.process(rng.bipolar()) * exp(-t / 0.0015) * 0.8
            out[i] = Float((body + knock) * min(1, t / 0.0003) * endFade(i, n, n / 4))
            advance(&p1, frequency / sampleRate)
            advance(&p2, frequency * 2.76 / sampleRate)
        }
        return normalized(out, to: 1)
    }

    /// Soft bubble pop: a sine gliding up an octave in 30 ms plus a tiny click.
    static func pop(endFrequency f: Double, seed s: UInt64) -> [Float] {
        let n = sampleIndex(0.13)
        var phase = 0.0
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = Double(i) / sampleRate
            let frequency = 0.5 * f * pow(2, min(t, 0.03) / 0.03)
            let env = min(1, t / 0.002) * exp(-t / 0.035) * endFade(i, n, n / 5)
            out[i] = Float(sin(twoPi * phase) * env)
            advance(&phase, frequency / sampleRate)
        }
        let click = noiseClick(center: 3000, q: 1.0, decay: 0.0012, length: 0.006, seed: s)
        for i in 0..<min(click.count, n) {
            out[i] += click[i] * 0.2
        }
        return out
    }

    /// Band-passed noise whose center glides from `from` to `to` (and back if asked).
    static func sweep(length: Double, from f0: Double, to f1: Double, returnToStart: Bool, q: Double,
                      seed s: UInt64, envelope: (Double) -> Double) -> ([Float], [Float]) {
        let n = max(2, sampleIndex(length))
        var rng = SplitMix64(seed: s)
        var bandL = SVF()
        var bandR = SVF()
        var left = [Float](repeating: 0, count: n)
        var right = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let u = Double(i) / Double(n - 1)
            if i % 16 == 0 {
                let shape = returnToStart ? sin(Double.pi * u) : u
                let center = f0 * pow(f1 / f0, shape)
                bandL.set(cutoff: center, q: q)
                bandR.set(cutoff: center * 1.04, q: q)
            }
            let env = envelope(u)
            let common = rng.bipolar()
            left[i] = Float(bandL.bandpass(0.85 * common + 0.35 * rng.bipolar()) * env)
            right[i] = Float(bandR.bandpass(0.85 * common + 0.35 * rng.bipolar()) * env)
        }
        return normalized(left, right, to: 1)
    }
}

final class SoundEffects {
    private let plan: Plan
    private let harmony: Harmony
    private let bank: WaveBank

    init(plan: Plan, harmony: Harmony, bank: WaveBank) {
        self.plan = plan
        self.harmony = harmony
        self.bank = bank
    }

    /// Presence trim per cue type in dB, set so tonal cues sit about 3 to 9 LU
    /// under the music bed and small ticks about 12 to 20 LU under it.
    static func trimDb(_ type: CueType) -> Double {
        switch type {
        case .type: return 8
        case .stop, .error, .end, .whip: return 0
        case .clock: return 7
        case .riser: return 4
        case .logo: return 4
        case .whoosh: return 9
        case .pop, .chip, .cta: return 11
        case .window: return 11
        case .countdown: return 6
        case .send: return 12
        case .resume: return 6
        case .timelapse: return 7
        case .warn: return 4.5
        case .check: return 3
        case .confirm: return 1.5
        case .post: return 6.5
        case .sunrise: return 4.5
        case .done: return 6
        case .counter: return 13
        case .click: return 9
        case .menu: return 15
        case .hover: return 9
        }
    }

    /// Whip cues are rendered by `WhipDesigner`; every other type is here.
    func render(_ cue: Cue) -> CueSound? {
        let start = sampleIndex(cue.time)
        var rng = SplitMix64(seed: seed("cue." + cue.type.rawValue, start))
        switch cue.type {
        case .whip: return nil
        case .type: return typing(cue, start, &rng)
        case .stop: return powerDown(cue, start)
        case .error: return errorBuzz(cue, start, &rng)
        case .clock: return clock(cue, start, &rng)
        case .riser: return riser(cue, start, &rng)
        case .logo: return logo(cue, start)
        case .whoosh: return whoosh(cue, start, &rng)
        case .pop, .chip, .cta: return popCue(cue, start, &rng, window: false)
        case .window: return popCue(cue, start, &rng, window: true)
        case .countdown: return countdown(cue, start)
        case .send: return send(cue, start, &rng)
        case .resume: return resume(cue, start)
        case .timelapse: return timelapse(cue, start, &rng)
        case .warn: return warn(cue, start)
        case .check: return check(cue, start)
        case .confirm: return confirm(cue, start)
        case .post: return post(cue, start, &rng)
        case .sunrise: return sunrise(cue, start, &rng)
        case .done: return done(cue, start)
        case .counter: return counter(cue, start, &rng)
        case .click: return click(cue, start, &rng)
        case .menu: return menu(cue, start, &rng)
        case .hover: return hover(cue, start, &rng)
        case .end: return endThump(start)
        }
    }

    /// Chord tone nearest D6, so interface pops sit inside the harmony.
    private func popFrequency(at time: Double) -> Double {
        guard let voicing = harmony.voicingOrPrevious(at: time) else { return midiToHz(86) }
        let classes = (voicing.pad + [voicing.bass]).map { $0 % 12 }
        var best = 86
        var distance = Int.max
        for midi in 80...92 where classes.contains(midi % 12) {
            if abs(midi - 86) < distance {
                best = midi
                distance = abs(midi - 86)
            }
        }
        return midiToHz(Double(best))
    }

    private func typing(_ cue: Cue, _ start: Int, _ rng: inout SplitMix64) -> CueSound {
        let duration = cue.duration ?? 0.45
        let count = 8 + rng.below(5)
        var clip = Clip(start: start, count: sampleIndex(duration + 0.03))
        let slot = duration / Double(count)
        for j in 0..<count {
            let t = max(0, slot * (Double(j) + 0.5 + 0.35 * rng.bipolar()))
            let center = 1500 * pow(4000.0 / 1500.0, rng.unit())
            let gain = rng.range(0.55, 1.0) * 0.07
            let pan = clamp(cue.pan + 0.18 * rng.bipolar(), -1, 1)
            let tick = Tones.noiseClick(center: center, q: 2.2, decay: 0.0022, length: 0.014, seed: rng.next())
            clip.addMono(tick, at: sampleIndex(t), gain: gain, pan: pan)
        }
        return CueSound(clip: clip, verbSend: 0.06, hallSend: 0)
    }

    /// Quiet power-down whine gliding from 800 Hz to 60 Hz over half a second.
    private func powerDown(_ cue: Cue, _ start: Int) -> CueSound {
        let n = sampleIndex(0.5)
        var data = [Float](repeating: 0, count: n)
        var phase = 0.0
        for i in 0..<n {
            let u = Double(i) / Double(n)
            let frequency = 800 * pow(60.0 / 800.0, u)
            let env = min(1, Double(i) / (0.008 * sampleRate)) * pow(1 - u, 0.6)
            data[i] = Float((sin(twoPi * phase) + 0.18 * sin(2 * twoPi * phase)) * env)
            advance(&phase, frequency / sampleRate)
        }
        var clip = Clip(start: start, count: n)
        clip.addMono(data, at: 0, gain: 0.06, pan: cue.pan)
        return CueSound(clip: clip, verbSend: 0.1, hallSend: 0)
    }

    /// Crunchy D3 plus E-flat 3 buzz with a quick downward bend, then a digital glitch.
    private func errorBuzz(_ cue: Cue, _ start: Int, _ rng: inout SplitMix64) -> CueSound {
        let n = sampleIndex(0.3)
        let low = midiToHz(50)
        let high = midiToHz(51)
        let saw = bank.saw(maxFrequency: high * 1.01)
        var pa = 0.0
        var pb = 0.31
        var tone = SVF(cutoff: 1900, q: 0.8)
        var smooth = Biquad.lowpass(3200)
        var buzz = [Float](repeating: 0, count: n)
        let fade = sampleIndex(0.05)
        for i in 0..<n {
            let t = Double(i) / sampleRate
            let bend = pow(2, -(2.5 / 12) * (1 - exp(-t / 0.07)))
            let x = 0.5 * (saw.read(pa) + saw.read(pb))
            let y = smooth.process(tanh(2.6 * tone.lowpass(x)))
            buzz[i] = Float(y * min(1, t / 0.003) * exp(-t / 0.12) * endFade(i, n, fade))
            advance(&pa, low * bend / sampleRate)
            advance(&pb, high * bend / sampleRate)
        }
        let gn = sampleIndex(0.06)
        var glitchL = [Float](repeating: 0, count: gn)
        var glitchR = [Float](repeating: 0, count: gn)
        var held = 0.0
        var holdLeft = 0
        var gateLeft = 0
        var gateTarget = 1.0
        var gate = 0.0
        var side = 0.0
        var filterL = Biquad.lowpass(7500)
        var filterR = Biquad.lowpass(7500)
        let glitchFade = sampleIndex(0.008)
        for i in 0..<gn {
            if gateLeft <= 0 {
                gateTarget = rng.unit() < 0.7 ? 1 : 0
                gateLeft = sampleIndex(rng.range(0.004, 0.011))
                side = rng.bipolar()
            }
            if holdLeft <= 0 {
                held = (rng.bipolar() * 4).rounded() / 4
                holdLeft = 3 + rng.below(16)
            }
            holdLeft -= 1
            gateLeft -= 1
            gate += 0.08 * (gateTarget - gate)
            let x = held * gate * endFade(i, gn, glitchFade) * min(1, Double(i) / 24)
            let (gl, gr) = panGains(clamp(cue.pan + 0.5 * side, -1, 1))
            glitchL[i] = Float(filterL.process(x * gl))
            glitchR[i] = Float(filterR.process(x * gr))
        }
        var clip = Clip(start: start, count: n)
        clip.addMono(buzz, at: 0, gain: 0.11, pan: cue.pan)
        clip.addStereo(glitchL, glitchR, at: 0, gain: 0.05)
        return CueSound(clip: clip, verbSend: 0.12, hallSend: 0)
    }

    /// Tick-tock on every beat, alternating D6 and A5 with a slight pan.
    private func clock(_ cue: Cue, _ start: Int, _ rng: inout SplitMix64) -> CueSound {
        let length = (cue.end ?? cue.time + 2) - cue.time
        var clip = Clip(start: start, count: sampleIndex(length + 0.12))
        var t = 0.0
        var j = 0
        while t < length - 1e-6 {
            let tick = j % 2 == 0
            let sound = Tones.woodTick(frequency: midiToHz(tick ? 86 : 81), seed: rng.next())
            clip.addMono(sound, at: sampleIndex(t), gain: tick ? 0.1 : 0.085,
                         pan: clamp(cue.pan + (tick ? 0.14 : -0.14), -1, 1))
            t += plan.beat
            j += 1
        }
        return CueSound(clip: clip, verbSend: 0.15, hallSend: 0)
    }

    /// Resonant noise sweep (300 Hz to 8 kHz), a rising pitched sweep and a
    /// reversed reverb swell, cut to silence 30 ms before the impact.
    private func riser(_ cue: Cue, _ start: Int, _ rng: inout SplitMix64) -> CueSound {
        let end = cue.end ?? cue.time + 2
        let duration = max(0.2, end - 0.03 - cue.time)
        let n = sampleIndex(duration)
        var bandL = SVF()
        var bandR = SVF()
        let f0 = midiToHz(50)
        let f1 = midiToHz(86)
        let saw = bank.saw(maxFrequency: f1 * 1.01)
        var pa = 0.0
        var pb = 0.5
        var toneFilter = SVF()
        var left = [Float](repeating: 0, count: n)
        var right = [Float](repeating: 0, count: n)
        let fadeIn = sampleIndex(0.05)
        let fadeOut = sampleIndex(0.003)
        for i in 0..<n {
            let u = Double(i) / Double(n)
            let frequency = f0 * pow(f1 / f0, pow(u, 1.3))
            if i % 16 == 0 {
                let center = 300 * pow(8000.0 / 300.0, u)
                let q = 5.5 - 2.5 * u
                bandL.set(cutoff: center, q: q)
                bandR.set(cutoff: center * 1.02, q: q)
                toneFilter.set(cutoff: min(9000, frequency * 4), q: 0.7)
            }
            let common = rng.bipolar()
            let nl = bandL.bandpass(0.8 * common + 0.4 * rng.bipolar())
            let nr = bandR.bandpass(0.8 * common + 0.4 * rng.bipolar())
            let noiseLevel = (0.1 + 0.9 * u * u) * (1 - 0.3 * u * u * u)
            let tone = toneFilter.lowpass(0.55 * saw.read(pa) + 0.45 * saw.read(pb))
            let toneLevel = 0.12 + 0.55 * pow(u, 1.5)
            let env = raisedCosine(Double(i) / Double(fadeIn)) * endFade(i, n, fadeOut)
            left[i] = Float((nl * noiseLevel * 1.6 + tone * toneLevel * 0.3) * env)
            right[i] = Float((nr * noiseLevel * 1.6 + tone * toneLevel * 0.3) * env)
            advance(&pa, frequency * centsRatio(-8) / sampleRate)
            advance(&pb, frequency * centsRatio(8) / sampleRate)
        }
        // A D minor stab through the hall, reversed so it swells into the cut.
        var stab = Clip(start: 0, count: sampleIndex(0.4))
        for (j, midi) in [62.0, 65, 69, 72, 76].enumerated() {
            let bell = Synths.bell(midi: midi, velocity: 0.3, decay: 0.12, index: 1.5, length: 0.4)
            stab.addMono(bell, at: 0, gain: 1, pan: -0.4 + 0.2 * Double(j))
        }
        let (swellL, swellR) = reverseSwell(seconds: min(1.4, duration), source: stab, settings: .hall)
        let offset = n - swellL.count
        for i in 0..<swellL.count {
            left[offset + i] += swellL[i] * 0.55
            right[offset + i] += swellR[i] * 0.55
        }
        let (l, r) = normalized(left, right, to: 0.3)
        // No reverb send: the silence before the impact must stay clean.
        return CueSound(clip: Clip(start: start, left: l, right: r), verbSend: 0, hallSend: 0)
    }

    /// Quick shimmering arpeggio D5 F5 A5 C6 E6 over a quarter second.
    private func logo(_ cue: Cue, _ start: Int) -> CueSound {
        var clip = Clip(start: start, count: sampleIndex(2.0))
        for (j, midi) in [74.0, 77, 81, 84, 88].enumerated() {
            let bell = Synths.bell(midi: midi, velocity: 1, decay: 1.2, index: 1.6, length: 1.7)
            clip.addMono(bell, at: sampleIndex(0.0625 * Double(j)), gain: 0.075,
                         pan: clamp(cue.pan - 0.35 + 0.175 * Double(j), -1, 1))
        }
        return CueSound(clip: clip, verbSend: 0.15, hallSend: 0.55)
    }

    /// Band-passed noise swept 300 Hz to 3 kHz and back, moving across the pan.
    private func whoosh(_ cue: Cue, _ start: Int, _ rng: inout SplitMix64) -> CueSound {
        let (l, r) = Tones.sweep(length: 0.45, from: 300, to: 3000, returnToStart: true, q: 1.2,
                                 seed: rng.next()) { u in pow(sin(Double.pi * u), 2) }
        var clip = Clip(start: start, count: l.count)
        for i in 0..<l.count {
            let u = Double(i) / Double(l.count)
            let (gl, gr) = panGains(clamp(cue.pan - 0.25 + 0.5 * u, -1, 1))
            let mid = 0.5 * Double(l[i] + r[i])
            let side = 0.5 * Double(l[i] - r[i])
            clip.left[i] = Float((mid * gl + side) * 0.12)
            clip.right[i] = Float((mid * gr - side) * 0.12)
        }
        return CueSound(clip: clip, verbSend: 0.15, hallSend: 0)
    }

    private func popCue(_ cue: Cue, _ start: Int, _ rng: inout SplitMix64, window: Bool) -> CueSound {
        var clip = Clip(start: start, count: sampleIndex(window ? 0.32 : 0.15))
        let pop = Tones.pop(endFrequency: popFrequency(at: cue.time), seed: rng.next())
        clip.addMono(pop, at: 0, gain: 0.11, pan: cue.pan)
        if window {
            let (l, r) = Tones.sweep(length: 0.25, from: 500, to: 2500, returnToStart: false, q: 1.1,
                                     seed: rng.next()) { u in pow(sin(Double.pi * u), 2) }
            clip.addStereo(l, r, at: 0, gain: 0.05, pan: cue.pan)
        }
        return CueSound(clip: clip, verbSend: 0.18, hallSend: 0)
    }

    /// Ticks accelerating from 4 to 16 per second with a slight rise, then a soft A5 ding.
    private func countdown(_ cue: Cue, _ start: Int) -> CueSound {
        let span = (cue.end ?? cue.time + 2.5) - cue.time
        var clip = Clip(start: start, count: sampleIndex(span + 1.6))
        var times: [Double] = [0]
        var phase = 0.0
        var t = 0.0
        let dt = 0.0005
        while t < span {
            phase += 4 * pow(4, t / span) * dt
            t += dt
            if phase >= 1 {
                phase -= 1
                if t < span - 0.03 {
                    times.append(t)
                }
            }
        }
        for (j, tick) in times.enumerated() {
            let u = tick / span
            let blip = Tones.blip(frequency: midiToHz(93 + 3 * u), decay: 0.004, length: 0.025)
            clip.addMono(blip, at: sampleIndex(tick), gain: 0.05 * (0.75 + 0.25 * u),
                         pan: clamp(cue.pan + (j % 2 == 0 ? 0.08 : -0.08), -1, 1))
        }
        let ding = Synths.bell(midi: 81, velocity: 1, decay: 0.5, index: 1.0, length: 1.4)
        clip.addMono(ding, at: sampleIndex(span), gain: 0.085, pan: cue.pan)
        return CueSound(clip: clip, verbSend: 0.12, hallSend: 0.15)
    }

    /// A soft 220 Hz thock as the key goes down, then a rising 0.18 s swoosh.
    private func send(_ cue: Cue, _ start: Int, _ rng: inout SplitMix64) -> CueSound {
        var clip = Clip(start: start, count: sampleIndex(0.3))
        let (l, r) = Tones.sweep(length: 0.18, from: 700, to: 4200, returnToStart: false, q: 1.3,
                                 seed: rng.next()) { u in
            pow(u, 1.6) * (u > 0.86 ? 1 - raisedCosine((u - 0.86) / 0.14) : 1)
        }
        clip.addStereo(l, r, at: 0, gain: 0.08, pan: cue.pan)
        let n = sampleIndex(0.1)
        var thock = [Float](repeating: 0, count: n)
        var phase = 0.0
        var lowpass = OnePole(cutoff: 1500)
        for i in 0..<n {
            let t = Double(i) / sampleRate
            let frequency = 220 * (1 + 0.35 * exp(-t / 0.006))
            let env = min(1, t / 0.0005) * exp(-t / 0.028) * endFade(i, n, n / 4)
            let knock = lowpass.lowpass(rng.bipolar()) * exp(-t / 0.002) * 0.25
            thock[i] = Float((sin(twoPi * phase) + knock) * env)
            advance(&phase, frequency / sampleRate)
        }
        clip.addMono(thock, at: 0, gain: 0.12, pan: cue.pan)
        return CueSound(clip: clip, verbSend: 0.15, hallSend: 0)
    }

    /// Two-note chime A5 then D6 with a short high shimmer.
    private func resume(_ cue: Cue, _ start: Int) -> CueSound {
        var clip = Clip(start: start, count: sampleIndex(1.5))
        let a = Synths.bell(midi: 81, velocity: 1, decay: 0.75, index: 1.3, length: 1.2)
        let d = Synths.bell(midi: 86, velocity: 1, decay: 0.8, index: 1.3, length: 1.3)
        clip.addMono(a, at: 0, gain: 0.085, pan: clamp(cue.pan - 0.12, -1, 1))
        clip.addMono(d, at: sampleIndex(0.11), gain: 0.08, pan: clamp(cue.pan + 0.12, -1, 1))
        let n = sampleIndex(0.6)
        var shimmer = [Float](repeating: 0, count: n)
        var p1 = 0.0
        var p2 = 0.0
        for i in 0..<n {
            let t = Double(i) / sampleRate
            let env = min(1, t / 0.025) * exp(-t / 0.18) * endFade(i, n, n / 4) * (0.75 + 0.25 * sin(twoPi * 11 * t))
            shimmer[i] = Float((sin(twoPi * p1) + 0.7 * sin(twoPi * p2)) * env)
            advance(&p1, midiToHz(93) / sampleRate)
            advance(&p2, midiToHz(98) / sampleRate)
        }
        clip.addMono(shimmer, at: sampleIndex(0.11), gain: 0.018, pan: cue.pan)
        return CueSound(clip: clip, verbSend: 0.2, hallSend: 0.3)
    }

    /// Fast-forward: accelerating ticks, a rising whoosh and a subtle chirp.
    private func timelapse(_ cue: Cue, _ start: Int, _ rng: inout SplitMix64) -> CueSound {
        let span = (cue.end ?? cue.time + 0.8) - cue.time
        var clip = Clip(start: start, count: sampleIndex(span + 0.1))
        var times: [Double] = [0]
        var phase = 0.0
        var t = 0.0
        let dt = 0.0005
        while t < span {
            phase += 8 * pow(4, t / span) * dt
            t += dt
            if phase >= 1 {
                phase -= 1
                if t < span - 0.02 {
                    times.append(t)
                }
            }
        }
        for (j, tick) in times.enumerated() {
            let click = Tones.noiseClick(center: 2600, q: 1.8, decay: 0.0015, length: 0.01, seed: rng.next())
            clip.addMono(click, at: sampleIndex(tick), gain: 0.045, pan: clamp(cue.pan + (j % 2 == 0 ? 0.1 : -0.1), -1, 1))
        }
        let (l, r) = Tones.sweep(length: span, from: 400, to: 5000, returnToStart: false, q: 1.4,
                                 seed: rng.next()) { u in
            pow(u, 1.4) * (u > 0.92 ? 1 - raisedCosine((u - 0.92) / 0.08) : 1)
        }
        clip.addStereo(l, r, at: 0, gain: 0.06, pan: cue.pan)
        let n = sampleIndex(span)
        var chirp = [Float](repeating: 0, count: n)
        var cp = 0.0
        for i in 0..<n {
            let u = Double(i) / Double(n)
            chirp[i] = Float(sin(twoPi * cp) * pow(sin(Double.pi * u), 1.5))
            advance(&cp, 440 * pow(2, u) / sampleRate)
        }
        clip.addMono(chirp, at: 0, gain: 0.025, pan: cue.pan)
        return CueSound(clip: clip, verbSend: 0.15, hallSend: 0)
    }

    /// Muted low two-tone, A3 then F3.
    private func warn(_ cue: Cue, _ start: Int) -> CueSound {
        var clip = Clip(start: start, count: sampleIndex(0.5))
        for (midi, offset, length) in [(57.0, 0.0, 0.16), (53.0, 0.17, 0.18)] {
            let n = sampleIndex(length + 0.02)
            var data = [Float](repeating: 0, count: n)
            var phase = 0.0
            var lowpass = Biquad.lowpass(900, q: 0.7)
            let frequency = midiToHz(midi)
            let fade = sampleIndex(0.025)
            for i in 0..<n {
                let t = Double(i) / sampleRate
                let x = sin(twoPi * phase) + 0.22 * sin(3 * twoPi * phase) + 0.08 * sin(5 * twoPi * phase)
                data[i] = Float(lowpass.process(x) * min(1, t / 0.006) * exp(-t / 0.25) * endFade(i, n, fade))
                advance(&phase, frequency / sampleRate)
            }
            clip.addMono(data, at: sampleIndex(offset), gain: 0.12, pan: cue.pan)
        }
        return CueSound(clip: clip, verbSend: 0.15, hallSend: 0)
    }

    /// Sonar ping with filtered echoes: A5 while waiting, a brighter D6 when available.
    private func check(_ cue: Cue, _ start: Int) -> CueSound {
        let available = cue.result == .available
        let frequency = midiToHz(available ? 86 : 81)
        let index = available ? 1.1 : 0.45
        let n = sampleIndex(0.42)
        var ping = [Float](repeating: 0, count: n)
        var pc = 0.0
        var pm = 0.0
        for i in 0..<n {
            let t = Double(i) / sampleRate
            let env = min(1, t / 0.002) * exp(-t / 0.11) * endFade(i, n, n / 5)
            ping[i] = Float(sin(twoPi * pc + index * exp(-t / 0.05) * sin(twoPi * pm)) * env)
            advance(&pc, frequency / sampleRate)
            advance(&pm, 2 * frequency / sampleRate)
        }
        var clip = Clip(start: start, count: n + sampleIndex(0.5))
        clip.addMono(ping, at: 0, gain: 0.11, pan: cue.pan)
        var echo = ping
        let delays = [0.15, 0.30, 0.45]
        let gains = [0.42, 0.22, 0.11]
        let pans = [-0.35, 0.35, -0.25]
        for k in 0..<3 {
            var lowpass = OnePole(cutoff: 2600)
            for i in 0..<echo.count {
                echo[i] = Float(lowpass.lowpass(Double(echo[i])))
            }
            clip.addMono(echo, at: sampleIndex(delays[k]), gain: 0.11 * gains[k], pan: clamp(cue.pan + pans[k], -1, 1))
        }
        return CueSound(clip: clip, verbSend: 0.2, hallSend: 0.2)
    }

    /// Rising F5 A5 C6 bell arpeggio.
    private func confirm(_ cue: Cue, _ start: Int) -> CueSound {
        var clip = Clip(start: start, count: sampleIndex(1.1))
        for (j, midi) in [77.0, 81, 84].enumerated() {
            let bell = Synths.bell(midi: midi, velocity: 1, decay: 0.5, index: 1.8, length: 0.9)
            clip.addMono(bell, at: sampleIndex(0.09 * Double(j)), gain: 0.08,
                         pan: clamp(cue.pan - 0.2 + 0.2 * Double(j), -1, 1))
        }
        return CueSound(clip: clip, verbSend: 0.2, hallSend: 0.35)
    }

    /// Notification pop plus soft E6 and A6 dings.
    private func post(_ cue: Cue, _ start: Int, _ rng: inout SplitMix64) -> CueSound {
        var clip = Clip(start: start, count: sampleIndex(1.0))
        clip.addMono(Tones.pop(endFrequency: popFrequency(at: cue.time), seed: rng.next()), at: 0, gain: 0.1, pan: cue.pan)
        clip.addMono(Synths.bell(midi: 88, velocity: 1, decay: 0.55, index: 1.0, length: 0.85),
                     at: sampleIndex(0.05), gain: 0.07, pan: cue.pan)
        clip.addMono(Synths.bell(midi: 93, velocity: 1, decay: 0.55, index: 0.8, length: 0.8),
                     at: sampleIndex(0.13), gain: 0.06, pan: cue.pan)
        return CueSound(clip: clip, verbSend: 0.2, hallSend: 0.1)
    }

    /// Warm swell of the chord under the cue (Fmaj9 at sunrise) with the filter
    /// opening from 300 Hz to 4 kHz and a high shimmer.
    private func sunrise(_ cue: Cue, _ start: Int, _ rng: inout SplitMix64) -> CueSound {
        let duration = (cue.end ?? cue.time + 2) - cue.time
        let release = 0.9
        let n = sampleIndex(duration + release)
        let gate = sampleIndex(duration)
        let voicing = harmony.voicingOrPrevious(at: cue.time + 1e-6) ?? Voicing(pad: [57, 60, 64, 67], bass: 41)
        let notes = [voicing.bass] + voicing.pad + [voicing.pad[1] + 12]
        var preL = [Double](repeating: 0, count: n)
        var preR = [Double](repeating: 0, count: n)
        for (j, midi) in notes.enumerated() {
            let f = midiToHz(Double(midi))
            let ratioA = centsRatio(-6)
            let ratioB = centsRatio(6)
            let table = bank.saw(maxFrequency: f * ratioB * 1.002)
            var pa = rng.unit()
            var pb = rng.unit()
            let weight = j == 0 ? 0.7 : 1.0
            for i in 0..<n {
                preL[i] += table.read(pa) * weight
                preR[i] += table.read(pb) * weight
                advance(&pa, f * ratioA / sampleRate)
                advance(&pb, f * ratioB / sampleRate)
            }
        }
        var l1 = SVF()
        var l2 = SVF()
        var r1 = SVF()
        var r2 = SVF()
        var left = [Float](repeating: 0, count: n)
        var right = [Float](repeating: 0, count: n)
        var s1 = 0.0
        var s2 = 0.0
        var s3 = 0.0
        let shimmer1 = midiToHz(89)
        let shimmer2 = midiToHz(93)
        let shimmer3 = midiToHz(96)
        for i in 0..<n {
            let t = Double(i) / sampleRate
            if i % 32 == 0 {
                let c = 300 * pow(4000.0 / 300.0, min(1, t / duration))
                l1.set(cutoff: c, q: 0.6)
                l2.set(cutoff: c, q: 0.9)
                r1.set(cutoff: c * 1.03, q: 0.6)
                r2.set(cutoff: c * 1.03, q: 0.9)
            }
            let rel = i < gate ? 1 : 1 - raisedCosine(Double(i - gate) / Double(max(1, n - gate)))
            let env = smoothstep(t / (0.7 * duration)) * rel
            let shimmerEnv = smoothstep((t - 0.4 * duration) / (0.5 * duration)) * rel * (0.7 + 0.3 * sin(twoPi * 6 * t))
            let sparkle = (sin(twoPi * s1) + 0.8 * sin(twoPi * s2) + 0.6 * sin(twoPi * s3)) * shimmerEnv * 0.05
            left[i] = Float(l2.lowpass(l1.lowpass(preL[i])) * env * 0.06 + sparkle)
            right[i] = Float(r2.lowpass(r1.lowpass(preR[i])) * env * 0.06 + sparkle)
            advance(&s1, shimmer1 / sampleRate)
            advance(&s2, shimmer2 / sampleRate)
            advance(&s3, shimmer3 / sampleRate)
        }
        return CueSound(clip: Clip(start: start, left: left, right: right), verbSend: 0.2, hallSend: 0.5)
    }

    /// F add9 bell chord, lightly strummed.
    private func done(_ cue: Cue, _ start: Int) -> CueSound {
        var clip = Clip(start: start, count: sampleIndex(1.4))
        for (j, midi) in [65.0, 69, 72, 77, 79].enumerated() {
            let bell = Synths.bell(midi: midi, velocity: 1, decay: 0.6, index: 1.4, length: 1.25)
            clip.addMono(bell, at: sampleIndex(0.012 * Double(j)), gain: 0.055,
                         pan: clamp(cue.pan - 0.3 + 0.15 * Double(j), -1, 1))
        }
        return CueSound(clip: clip, verbSend: 0.25, hallSend: 0.35)
    }

    /// Rapid soft rolling ticks.
    private func counter(_ cue: Cue, _ start: Int, _ rng: inout SplitMix64) -> CueSound {
        let span = (cue.end ?? cue.time + 1) - cue.time
        var clip = Clip(start: start, count: sampleIndex(span + 0.05))
        var t = 0.0
        var j = 0
        while t < span - 0.01 {
            let click = Tones.noiseClick(center: j % 2 == 0 ? 2200 : 2700, q: 2.0, decay: 0.0016, length: 0.01, seed: rng.next())
            clip.addMono(click, at: sampleIndex(t), gain: 0.035 * rng.range(0.7, 1.0),
                         pan: clamp(cue.pan + (j % 2 == 0 ? 0.08 : -0.08), -1, 1))
            t += (1.0 / 26.0) * (1 + 0.2 * rng.bipolar())
            j += 1
        }
        return CueSound(clip: clip, verbSend: 0.05, hallSend: 0)
    }

    /// Mouse click: a 3 ms noise burst plus a 4 kHz blip, over a short body
    /// resonance that gives the click weight without a high peak.
    private func click(_ cue: Cue, _ start: Int, _ rng: inout SplitMix64) -> CueSound {
        let n = sampleIndex(0.03)
        var data = [Float](repeating: 0, count: n)
        var highpass = Biquad.highpass(1000)
        var body = Biquad.bandpass(1600, q: 4)
        var phase = 0.0
        for i in 0..<n {
            let t = Double(i) / sampleRate
            let burstEnv = t < 0.003 ? min(1, t / 0.0001) * (1 - t / 0.003) : 0
            let white = rng.bipolar() * burstEnv
            let burst = highpass.process(white)
            let resonance = body.process(white) * 2.5
            let blip = sin(twoPi * phase) * exp(-t / 0.0012) * min(1, t / 0.0002)
            data[i] = Float((0.6 * burst + 0.5 * blip + resonance) * endFade(i, n, n / 4))
            advance(&phase, 4000 / sampleRate)
        }
        var clip = Clip(start: start, count: n)
        clip.addMono(data, at: 0, gain: 0.1, pan: cue.pan)
        return CueSound(clip: clip, verbSend: 0.05, hallSend: 0)
    }

    /// Short soft swish.
    private func menu(_ cue: Cue, _ start: Int, _ rng: inout SplitMix64) -> CueSound {
        let (l, r) = Tones.sweep(length: 0.12, from: 2400, to: 1100, returnToStart: false, q: 1.1,
                                 seed: rng.next()) { u in pow(sin(Double.pi * u), 1.5) }
        var clip = Clip(start: start, count: l.count)
        clip.addStereo(l, r, at: 0, gain: 0.05, pan: cue.pan)
        return CueSound(clip: clip, verbSend: 0.1, hallSend: 0)
    }

    /// Tiny tick.
    private func hover(_ cue: Cue, _ start: Int, _ rng: inout SplitMix64) -> CueSound {
        let tick = Tones.noiseClick(center: 3200, q: 1.5, decay: 0.0006, length: 0.006, seed: rng.next())
        var clip = Clip(start: start, count: tick.count)
        clip.addMono(tick, at: 0, gain: 0.03, pan: cue.pan)
        return CueSound(clip: clip, verbSend: 0.03, hallSend: 0)
    }

    /// The final hit itself is musical; this adds only a soft sub thump.
    private func endThump(_ start: Int) -> CueSound {
        let n = sampleIndex(0.7)
        var data = [Float](repeating: 0, count: n)
        var phase = 0.0
        for i in 0..<n {
            let t = Double(i) / sampleRate
            data[i] = Float(sin(twoPi * phase) * raisedCosine(t / 0.005) * exp(-t / 0.18) * endFade(i, n, n / 4))
            advance(&phase, (45 + 45 * exp(-t / 0.04)) / sampleRate)
        }
        var clip = Clip(start: start, count: n)
        clip.addMono(data, at: 0, gain: 0.12, pan: 0)
        return CueSound(clip: clip, verbSend: 0, hallSend: 0)
    }
}
