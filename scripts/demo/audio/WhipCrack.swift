import Foundation

// The whip: an airy wind-up, then a crack whose absolute peak sits exactly on
// the cue's sample. The crack is an N-wave (the sonic boom of the tip) with a
// high noise burst and a short body, plus early reflections. Hero cracks add a
// sub boom, a long noise tail and, when no riser leads in, a reverse swell.

struct WhipSound {
    var clip: Clip
    var verbSend: Double
    var hallSend: Double
    let peakSample: Int
}

final class WhipDesigner {
    private let plan: Plan

    init(plan: Plan) {
        self.plan = plan
    }

    private struct Core {
        let data: [Double]
        let peak: Int
    }

    /// The mono crack. Index `peak` holds the N-wave maximum, and the build
    /// loop guarantees it is the strict absolute maximum of the core.
    private func crackCore(_ rng: inout SplitMix64) -> Core {
        let rise = 5
        let fall = max(20, sampleIndex(0.0008 * (1 + 0.1 * rng.bipolar())))
        let back = 7
        let depth = 0.42 + 0.05 * rng.bipolar()
        let bodyFrequency = rng.range(180, 250)
        // 15 to 25 ms until the burst is about 40 dB down.
        let noiseTau = rng.range(0.015, 0.025) / 4.6
        let total = rise + sampleIndex(0.09)
        let noiseSeed = rng.next()
        let drive = 0.6
        let norm = 1 / tanh(drive)
        var noiseAmount = 0.34
        var result: [Double] = []
        for attempt in 0..<16 {
            var data = [Double](repeating: 0, count: total)
            for k in 0...rise {
                data[k] = raisedCosine(Double(k) / Double(rise))
            }
            for k in 1...fall {
                data[rise + k] = 1 - (1 + depth) * Double(k) / Double(fall)
            }
            for k in 1...back {
                data[rise + fall + k] = -depth * (1 - raisedCosine(Double(k) / Double(back)))
            }
            var noise = SplitMix64(seed: noiseSeed)
            var highpass = Biquad.highpass(2000, q: 0.7)
            var lowpass = Biquad.lowpass(10_000, q: 0.7)
            var noiseEnv = 1.0
            let noiseStep = decayFactor(noiseTau)
            var phase = 0.0
            for k in 0..<(total - rise) {
                let t = Double(k) / sampleRate
                let filtered = lowpass.process(highpass.process(noise.bipolar()))
                if k >= 2 {
                    data[rise + k] += filtered * noiseAmount * min(1, Double(k - 2) / 12) * noiseEnv
                    noiseEnv *= noiseStep
                }
                let bend = 1 - 0.18 * (1 - exp(-t / 0.02))
                data[rise + k] += sin(twoPi * phase) * min(1, t / 0.0004) * exp(-t / 0.013) * 0.3
                advance(&phase, bodyFrequency * bend / sampleRate)
            }
            // Light saturation; tanh is monotonic, so it cannot move the peak.
            for k in 0..<total {
                data[k] = tanh(drive * data[k]) * norm
            }
            let peakValue = abs(data[rise])
            var near = 0.0
            var far = 0.0
            for k in 0..<total where k != rise {
                if abs(k - rise) <= 10 {
                    near = max(near, abs(data[k]))
                } else {
                    far = max(far, abs(data[k]))
                }
            }
            result = data
            if (near < peakValue - 0.005 && far < 0.8 * peakValue) || attempt == 15 {
                break
            }
            noiseAmount *= 0.85
        }
        return Core(data: result, peak: rise)
    }

    func render(_ cue: Cue) -> WhipSound {
        let hero = cue.strength == .hero
        let center = sampleIndex(cue.time)
        var rng = SplitMix64(seed: seed("whip", center))
        let followsRiser = plan.cues(.riser).contains { abs(($0.end ?? -10) - cue.time) < 0.002 }
        // After a riser the wind-up stops with it, leaving 30 ms of silence.
        let gap = followsRiser ? 0.03 : 0.004
        let swell = hero && !followsRiser
        let preroll = 0.32
        let lead = swell ? 0.62 : preroll
        let tail = hero ? 2.4 : 0.75
        let start = center - sampleIndex(lead)
        var clip = Clip(start: start, count: sampleIndex(lead + tail))
        let c = center - start

        // Wind-up: noise in a band rising from 400 Hz to 4 kHz, getting louder,
        // panned from the right toward the strike.
        let preStart = c - sampleIndex(preroll)
        let preEnd = c - sampleIndex(gap)
        let airCount = preEnd - preStart
        var band = SVF()
        var whistle = SVF()
        let fadeIn = sampleIndex(0.02)
        let fadeOut = sampleIndex(0.006)
        let airGain = hero ? 0.42 : 0.4
        for k in 0..<airCount {
            let u = Double(k) / Double(airCount)
            if k % 16 == 0 {
                let f = 400 * pow(10, u)
                band.set(cutoff: f, q: 1.4)
                whistle.set(cutoff: f * 1.5, q: 6)
            }
            let white = rng.bipolar()
            let env = pow(u, 2.2) * raisedCosine(Double(k) / Double(fadeIn)) * endFade(k, airCount, fadeOut)
            let air = (band.bandpass(white) + 0.25 * whistle.bandpass(white)) * env * airGain
            let (gl, gr) = panGains(0.6 + (cue.pan - 0.6) * u)
            let n = preStart + k
            clip.left[n] += Float(air * gl)
            clip.right[n] += Float(air * gr)
        }

        // The crack. Balance panning keeps the louder channel at the design
        // level so a panned strike never outshines a centered hero.
        let core = crackCore(&rng)
        let crackGain = hero ? 1.0 : 0.95
        let (pl, pr) = panGains(cue.pan)
        let loudest = max(pl, pr)
        let cl = pl / loudest
        let cr = pr / loudest
        for k in 0..<core.data.count {
            let n = c - core.peak + k
            guard n >= 0 && n < clip.count else { continue }
            clip.left[n] += Float(core.data[k] * crackGain * cl)
            clip.right[n] += Float(core.data[k] * crackGain * cr)
        }

        // Quiet early reflections at about 9, 17 and 29 ms, each duller.
        let reflections: [(delay: Double, gain: Double, pan: Double, cutoff: Double)] = [
            (0.009, 0.24, cue.pan - 0.5, 5000),
            (0.017, 0.16, cue.pan + 0.55, 3600),
            (0.029, 0.10, cue.pan - 0.15, 2600),
        ]
        for reflection in reflections {
            let delay = sampleIndex(reflection.delay * (1 + 0.06 * rng.bipolar()))
            var lowpass = OnePole(cutoff: reflection.cutoff)
            let (gl, gr) = panGains(clamp(reflection.pan, -1, 1))
            for k in 0..<core.data.count {
                let y = lowpass.lowpass(core.data[k]) * reflection.gain * crackGain
                let n = c - core.peak + k + delay
                guard n >= 0 && n < clip.count else { continue }
                clip.left[n] += Float(y * gl)
                clip.right[n] += Float(y * gr)
            }
        }

        if hero {
            // Sub boom gliding from 70 Hz to 35 Hz. It starts at zero phase, so
            // it adds nothing at the crack's peak sample.
            let boomCount = min(sampleIndex(0.85), clip.count - c)
            var phase = 0.0
            let boomFade = sampleIndex(0.2)
            for k in 0..<boomCount {
                let t = Double(k) / sampleRate
                let env = raisedCosine(t / 0.004) * exp(-t / 0.3) * endFade(k, boomCount, boomFade)
                let y = Float(sin(twoPi * phase) * env * 0.25)
                clip.left[c + k] += y
                clip.right[c + k] += y
                advance(&phase, (35 + 35 * exp(-t / 0.16)) / sampleRate)
            }

            // Long noise crash tail, wide and darkening.
            let tailOffset = c + sampleIndex(0.001)
            let tailCount = min(sampleIndex(2.2), clip.count - tailOffset)
            var highL = Biquad.highpass(500)
            var highR = Biquad.highpass(500)
            var lowL = SVF()
            var lowR = SVF()
            var tailEnv = 1.0
            let tailStep = decayFactor(0.55)
            let tailAttack = sampleIndex(0.008)
            let tailFade = sampleIndex(0.4)
            for k in 0..<tailCount {
                if k % 32 == 0 {
                    let cutoff = 3500 + 3500 * exp(-Double(k) / sampleRate / 0.6)
                    lowL.set(cutoff: cutoff, q: 0.6)
                    lowR.set(cutoff: cutoff * 1.04, q: 0.6)
                }
                let env = raisedCosine(Double(k) / Double(tailAttack)) * tailEnv * endFade(k, tailCount, tailFade) * 0.16
                let common = rng.bipolar()
                let l = lowL.lowpass(highL.process(0.6 * common + 0.8 * rng.bipolar())) * env
                let r = lowR.lowpass(highR.process(0.6 * common + 0.8 * rng.bipolar())) * env
                clip.left[tailOffset + k] += Float(l)
                clip.right[tailOffset + k] += Float(r)
                tailEnv *= tailStep
            }

            if swell {
                // The crack's own hall response, reversed, swelling into it.
                var burst = Clip(start: 0, count: core.data.count)
                for k in 0..<core.data.count {
                    burst.left[k] = Float(core.data[k])
                    burst.right[k] = Float(core.data[k])
                }
                let (sl, sr) = reverseSwell(seconds: 0.6, source: burst, settings: .hall)
                let end = c - sampleIndex(0.004)
                let begin = end - sl.count
                for k in 0..<sl.count where begin + k >= 0 {
                    clip.left[begin + k] += sl[k] * 0.3
                    clip.right[begin + k] += sr[k] * 0.3
                }
            }
        }
        return WhipSound(clip: clip, verbSend: hero ? 0.18 : 0.22, hallSend: hero ? 0.4 : 0.06, peakSample: center)
    }
}
