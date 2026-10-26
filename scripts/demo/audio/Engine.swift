import Foundation

// Renders the five buses (drums, bass, music, sfx, whip) from the arrangement
// and the cues, including sidechain pumping, ducking, the tape stop and the
// final hit. The master stage then sums them.

/// Static mix levels. The master normalizes loudness afterwards, so these
/// only set the balance.
enum Levels {
    static let kick = 0.71
    static let clap = 0.42
    static let roll = 0.32
    static let closedHat = 0.2
    static let openHat = 0.15
    static let crash = 0.16
    static let buildRiser = 0.12
    static let bass = 0.44
    static let pad = 0.085
    static let pluck = 0.26
    static let bell = 0.2
    static let drone = 0.26
    static let sfx = 1.25
    static let whip = 1.9
}

struct Stems {
    let drums: Layer
    let bass: Layer
    let music: Layer
    let sfx: Layer
    let whip: Layer

    var named: [(String, Layer)] {
        [("drums", drums), ("bass", bass), ("music", music), ("sfx", sfx), ("whip", whip)]
    }
}

enum Envelopes {
    /// A 0...1 dip around each time: a raised cosine attack that starts `lead`
    /// seconds early, a hold, then a linear-shaped or exponential release.
    static func dips(frames: Int, times: [Double], lead: Double, attack: Double, hold: Double,
                     release: Double, exponential: Bool) -> [Float] {
        var out = [Float](repeating: 0, count: frames)
        let attackCount = max(1, sampleIndex(attack))
        let holdCount = sampleIndex(hold)
        let releaseCount = max(1, sampleIndex(exponential ? release * 5 : release))
        for time in times {
            let begin = sampleIndex(time - lead)
            for k in 0..<(attackCount + holdCount + releaseCount) {
                let n = begin + k
                guard n >= 0 && n < frames else { continue }
                let value: Double
                if k < attackCount {
                    value = raisedCosine(Double(k) / Double(attackCount))
                } else if k < attackCount + holdCount {
                    value = 1
                } else {
                    let r = Double(k - attackCount - holdCount)
                    value = exponential ? exp(-r / (release * sampleRate)) : 1 - raisedCosine(r / Double(releaseCount))
                }
                out[n] = max(out[n], Float(value))
            }
        }
        return out
    }

    /// Converts dips to linear gains: each dip of 1 attenuates by its depth in dB.
    static func gains(_ layers: [(dip: [Float], depthDb: Double)], frames: Int) -> [Float] {
        var out = [Float](repeating: 1, count: frames)
        for n in 0..<frames {
            var db = 0.0
            for layer in layers {
                db += layer.depthDb * Double(layer.dip[n])
            }
            if db > 0 {
                out[n] = Float(pow(10, -db / 20))
            }
        }
        return out
    }

    static func fadeIn(frames: Int, seconds: Double) -> [Float] {
        var out = [Float](repeating: 1, count: frames)
        let count = min(frames, sampleIndex(seconds))
        for n in 0..<count {
            out[n] = Float(raisedCosine(Double(n) / Double(count)))
        }
        return out
    }
}

extension Layer {
    /// Silence between two samples with short fades on either side.
    func gate(from: Int, to: Int, fade: Int) {
        let f = max(1, fade)
        for i in 0..<f {
            let n = from - f + i
            if n >= offset && n < end {
                let g = Float(1 - raisedCosine(Double(i) / Double(f)))
                left[n - offset] *= g
                right[n - offset] *= g
            }
            let m = to + i
            if m >= offset && m < end {
                let g = Float(raisedCosine(Double(i) / Double(f)))
                left[m - offset] *= g
                right[m - offset] *= g
            }
        }
        clear(from: from, to: to)
    }

    func multiply(by curve: ControlCurve) {
        for i in 0..<frames {
            let g = Float(curve.at(offset + i))
            left[i] *= g
            right[i] *= g
        }
    }
}

final class Engine {
    let plan: Plan
    let frames: Int
    let arrangement: Arrangement
    private let bank = WaveBank()

    init(plan: Plan) {
        self.plan = plan
        frames = sampleIndex(plan.duration)
        arrangement = Arrangement(plan: plan, frames: frames)
    }

    func render() -> Stems {
        let kicks = arrangement.drums.filter { $0.kind == .kick }.map(\.time)
        // Trigger-driven sidechain: full dip 4 ms after each kick, about 120 ms to recover.
        let pump = Envelopes.dips(frames: frames, times: kicks, lead: 0.002, attack: 0.006, hold: 0,
                                  release: 0.045, exponential: true)
        let drums = renderDrums()
        let bass = renderBass(pump)
        let music = renderMusic(pump)
        let grooves = [drums, bass, music]

        for stop in arrangement.tapeStops {
            let start = sampleIndex(stop.time)
            for layer in grooves {
                applyTapeStop(layer, start: start, duration: sampleIndex(0.45), silenceEnd: sampleIndex(stop.silenceEnd))
            }
        }
        if let hit = arrangement.finalHit {
            let at = sampleIndex(hit.time)
            for layer in grooves {
                layer.cut(at: at, fade: sampleIndex(0.03))
            }
            renderFinalHit(hit, music: music, bass: bass)
        }
        for drone in arrangement.drones {
            let (l, r) = Synths.drone(duration: drone.end - drone.start, bank: bank)
            music.add(Clip(start: sampleIndex(drone.start), left: l, right: r), gain: Levels.drone)
        }

        let fade = Envelopes.fadeIn(frames: frames, seconds: 0.6)
        for layer in grooves {
            layer.multiply(by: fade)
        }

        // Duck music and drums by 6 dB around each crack, the bass by 3 dB so its
        // sub does not offset the crack, and the music a little under tonal cues.
        let whips = plan.cues(.whip)
        let strikeDip = Envelopes.dips(frames: frames, times: whips.filter { $0.strength == .strike }.map(\.time),
                                       lead: 0.012, attack: 0.011, hold: 0.04, release: 0.11, exponential: false)
        let heroTimes = whips.filter { $0.strength == .hero }.map(\.time)
        let heroDip = Envelopes.dips(frames: frames, times: heroTimes, lead: 0.012, attack: 0.011, hold: 0.06,
                                     release: 0.16, exponential: false)
        var crackDip = strikeDip
        for n in 0..<frames {
            crackDip[n] = max(crackDip[n], heroDip[n])
        }
        let tonalTypes: [CueType] = [.logo, .check, .confirm, .resume, .done, .post, .warn, .error]
        var tonalTimes = plan.cues.filter { tonalTypes.contains($0.type) }.map(\.time)
        tonalTimes += plan.cues(.countdown).map { $0.end ?? $0.time }
        let tonalDip = Envelopes.dips(frames: frames, times: tonalTimes, lead: 0, attack: 0.03, hold: 0.1,
                                      release: 0.25, exponential: false)
        music.multiply(by: Envelopes.gains([(crackDip, 6), (tonalDip, 2.5)], frames: frames))
        drums.multiply(by: Envelopes.gains([(crackDip, 6)], frames: frames))
        bass.multiply(by: Envelopes.gains([(crackDip, 3)], frames: frames))

        let sfx = renderEffects()
        let whip = renderWhips()
        return Stems(drums: drums, bass: bass, music: music, sfx: sfx, whip: whip)
    }

    /// Sums the buses into the bed (drums, bass, music, sfx) and the whip.
    func mixdown(_ stems: Stems) -> (bed: ([Double], [Double]), whip: ([Double], [Double])) {
        var left = [Double](repeating: 0, count: frames)
        var right = [Double](repeating: 0, count: frames)
        for layer in [stems.drums, stems.bass, stems.music, stems.sfx] {
            for n in 0..<min(frames, layer.frames) {
                left[n] += Double(layer.left[n])
                right[n] += Double(layer.right[n])
            }
        }
        var whipLeft = [Double](repeating: 0, count: frames)
        var whipRight = [Double](repeating: 0, count: frames)
        for n in 0..<min(frames, stems.whip.frames) {
            whipLeft[n] = Double(stems.whip.left[n])
            whipRight[n] = Double(stems.whip.right[n])
        }
        return ((left, right), (whipLeft, whipRight))
    }

    // MARK: Buses

    private func renderDrums() -> Layer {
        let dry = Layer(frames: frames)
        let send = Layer(frames: frames)
        for hit in arrangement.drums {
            let start = sampleIndex(hit.time)
            switch hit.kind {
            case .kick:
                let data = Drums.kick(velocity: hit.velocity, click: hit.tone, seed: seed("kick", start))
                dry.addMono(data, start: start, gainLeft: Levels.kick, gainRight: Levels.kick)
            case .clap, .roll:
                let (l, r) = Drums.clap(velocity: hit.velocity, tone: hit.tone, seed: seed("clap", start))
                let clip = Clip(start: start, left: l, right: r)
                let level = hit.kind == .clap ? Levels.clap : Levels.roll
                dry.add(clip, gain: level)
                send.add(clip, gain: level * 0.35)
            case .closedHat, .openHat:
                let open = hit.kind == .openHat
                let (l, r) = Drums.hat(open: open, velocity: hit.velocity, bright: hit.tone > 0.5,
                                       seed: seed(open ? "openhat" : "hat", start))
                let (gl, gr) = panGains(open ? -0.12 : 0.15)
                let level = open ? Levels.openHat : Levels.closedHat
                let clip = Clip(start: start, left: l.map { $0 * Float(gl) }, right: r.map { $0 * Float(gr) })
                dry.add(clip, gain: level)
                send.add(clip, gain: level * 0.06)
            case .crash:
                let (l, r) = Drums.crash(velocity: hit.velocity, seed: seed("crash", start))
                let clip = Clip(start: start, left: l, right: r)
                dry.add(clip, gain: Levels.crash)
                send.add(clip, gain: Levels.crash * 0.15)
            }
        }
        for build in arrangement.builds {
            let (l, r) = Drums.buildRiser(duration: max(0.1, build.end - build.start - 0.02),
                                          seed: seed("build", sampleIndex(build.start)))
            let clip = Clip(start: sampleIndex(build.start), left: l, right: r)
            dry.add(clip, gain: Levels.buildRiser)
            send.add(clip, gain: Levels.buildRiser * 0.2)
        }
        FDNReverb(.drums).process(input: send, output: dry)
        return dry
    }

    private func renderBass(_ pump: [Float]) -> Layer {
        let layer = Layer(frames: frames)
        for note in arrangement.bass {
            let data = Synths.bass(note, bank: bank)
            layer.addMono(data, start: sampleIndex(note.time), gainLeft: Levels.bass, gainRight: Levels.bass)
        }
        layer.multiply(by: Envelopes.gains([(pump, 4.5)], frames: frames))
        return layer
    }

    private func renderMusic(_ pump: [Float]) -> Layer {
        let pad = Layer(frames: frames)
        for note in arrangement.pads {
            Synths.pad(note, bank: bank, gain: Levels.pad, into: pad)
        }
        let cutoff = arrangement.padCutoff
        Synths.filterPad(pad) { cutoff.at($0) }
        pad.multiply(by: arrangement.padLevel)
        pad.multiply(by: Envelopes.gains([(pump, 4)], frames: frames))

        let pluck = Layer(frames: frames)
        let delaySend = Layer(frames: frames)
        for note in arrangement.plucks {
            let start = sampleIndex(note.time)
            let (l, r) = Synths.pluck(note, bank: bank, seed: seed("pluck", start, note.midi))
            let clip = Clip(start: start, left: l, right: r)
            pluck.add(clip, gain: Levels.pluck)
            delaySend.add(clip, gain: Levels.pluck * note.delaySend)
        }
        pluck.multiply(by: Envelopes.gains([(pump, 3)], frames: frames))

        let bells = Layer(frames: frames)
        for note in arrangement.bells {
            let data = Synths.bell(midi: note.midi, velocity: note.velocity, decay: note.decay, index: note.index)
            let (gl, gr) = panGains(note.pan)
            bells.addMono(data, start: sampleIndex(note.time), gainLeft: Levels.bell * gl, gainRight: Levels.bell * gr)
        }
        delaySend.add(bells, gain: 0.2)

        let music = Layer(frames: frames)
        music.add(pad)
        music.add(pluck)
        music.add(bells)
        let verb = Layer(frames: frames)
        verb.add(pad, gain: 0.38)
        verb.add(pluck, gain: 0.22)
        verb.add(bells, gain: 0.35)
        FDNReverb(.room).process(input: verb, output: music)
        PingPongDelay(seconds: 0.75 * plan.beat, feedback: 0.35).process(input: delaySend, output: music)
        return music
    }

    /// Everything stops except one big chord: pad, strummed pluck, bells and
    /// sub, with a long hall that fades to silence about 3.5 s later.
    private func renderFinalHit(_ hit: FinalHit, music: Layer, bass: Layer) {
        let start = sampleIndex(hit.time)
        let length = frames - start
        guard length > sampleIndex(0.5) else { return }
        let voicing = hit.voicing

        let pad = Layer(offset: start, frames: length)
        let padNotes = [voicing.bass + 12] + voicing.pad + [voicing.pad[1] + 12]
        for midi in padNotes {
            Synths.pad(PadNote(midi: midi, start: hit.time, end: hit.time + 1.4, attack: 0.012, release: 2.0),
                       bank: bank, gain: Levels.pad * 0.85, into: pad)
        }
        Synths.filterPad(pad) { n in
            1400 + 3800 * exp(-Double(n - start) / sampleRate / 1.2)
        }
        let layer = Layer(offset: start, frames: length)
        layer.add(pad)

        for (j, midi) in Arrangement.arpTones(voicing).enumerated() {
            let note = PluckNote(time: hit.time + 0.018 * Double(j), midi: midi, velocity: 0.8, gate: 2.4, decay: 0.9,
                                 cutoff: 5200, pan: j % 2 == 0 ? -0.3 : 0.3, delaySend: 0)
            let (l, r) = Synths.pluck(note, bank: bank, seed: seed("final.pluck", j), release: 0.6)
            layer.add(Clip(start: sampleIndex(note.time), left: l, right: r), gain: Levels.pluck * 0.6)
        }

        let bellNotes = [Double(voicing.bass + 36)] + voicing.pad.map { Double($0 + 24) }
        for (j, midi) in bellNotes.enumerated() {
            let data = Synths.bell(midi: midi, velocity: 1, decay: 1.6, index: 1.6, length: 3.4)
            let (gl, gr) = panGains(-0.4 + 0.2 * Double(j))
            layer.addMono(data, start: start + sampleIndex(0.01 * Double(j)),
                          gainLeft: Levels.bell * 0.55 * gl, gainRight: Levels.bell * 0.55 * gr)
        }

        let send = Layer(offset: start, frames: length)
        send.add(layer, gain: 0.55)
        FDNReverb(.hall).process(input: send, output: layer)

        let fadeEnd = min(start + sampleIndex(3.5), frames - sampleIndex(0.5))
        let fadeStart = fadeEnd - sampleIndex(0.9)
        for n in start..<frames {
            let g: Double
            if n < fadeStart {
                g = 1
            } else if n >= fadeEnd {
                g = 0
            } else {
                g = 1 - raisedCosine(Double(n - fadeStart) / Double(fadeEnd - fadeStart))
            }
            layer.left[n - start] *= Float(g)
            layer.right[n - start] *= Float(g)
        }
        music.add(layer)

        let subCount = min(length, sampleIndex(3.4))
        var sub = [Float](repeating: 0, count: subCount)
        var phase = 0.0
        let f = midiToHz(Double(voicing.bass))
        let subFade = sampleIndex(0.6)
        for k in 0..<subCount {
            let t = Double(k) / sampleRate
            sub[k] = Float(sin(twoPi * phase) * raisedCosine(t / 0.008) * exp(-t / 1.0) * endFade(k, subCount, subFade))
            advance(&phase, f / sampleRate)
        }
        bass.addMono(sub, start: start, gainLeft: Levels.bass * 0.7, gainRight: Levels.bass * 0.7)
    }

    private func renderEffects() -> Layer {
        let dry = Layer(frames: frames)
        let verb = Layer(frames: frames)
        let hall = Layer(frames: frames)
        let effects = SoundEffects(plan: plan, harmony: arrangement.harmony, bank: bank)
        for cue in plan.cues {
            guard let sound = effects.render(cue) else { continue }
            // Small ticks get a lift where the full groove would otherwise bury them.
            let ticks: [CueType] = [.type, .click, .hover, .counter, .menu]
            let lift = ticks.contains(cue.type) && arrangement.isFullGroove(at: cue.time) ? 3.0 : 0.0
            let gain = Levels.sfx * dbToGain(SoundEffects.trimDb(cue.type) + lift)
            dry.add(sound.clip, gain: gain)
            verb.add(sound.clip, gain: gain * sound.verbSend)
            hall.add(sound.clip, gain: gain * sound.hallSend)
        }
        FDNReverb(.room).process(input: verb, output: dry)
        FDNReverb(.hall).process(input: hall, output: dry)
        // Keep the 30 ms before each riser's impact truly silent.
        for riser in plan.cues(.riser) {
            let end = sampleIndex(riser.end ?? riser.time)
            dry.gate(from: end - sampleIndex(0.03), to: end, fade: sampleIndex(0.003))
        }
        return dry
    }

    private func renderWhips() -> Layer {
        let dry = Layer(frames: frames)
        let verb = Layer(frames: frames)
        let hall = Layer(frames: frames)
        let designer = WhipDesigner(plan: plan)
        for cue in plan.cues(.whip) {
            let sound = designer.render(cue)
            dry.add(sound.clip, gain: Levels.whip)
            verb.add(sound.clip, gain: Levels.whip * sound.verbSend)
            hall.add(sound.clip, gain: Levels.whip * sound.hallSend)
        }
        FDNReverb(.room).process(input: verb, output: dry)
        FDNReverb(.hall).process(input: hall, output: dry)
        return dry
    }
}
