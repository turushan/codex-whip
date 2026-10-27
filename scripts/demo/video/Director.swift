import AppKit
import CoreImage

// Composes one frame: camera, stage, whip, effects, interface and type.

struct Camera {
    var zoom: Double
    var center: V2
    var tilt: Tilt
    var roll: Double
    var shake: V2 = .zero

    func toScreen(_ p: V2) -> V2 {
        let r = degrees(roll)
        let q = (p - center) * zoom
        let rotated = V2(q.x * cos(r) - q.y * sin(r), q.x * sin(r) + q.y * cos(r))
        return tilt.project(rotated + V2(960, 540) + shake)
    }

    func apply(_ cg: CGContext) {
        cg.translateBy(x: 960 + shake.x, y: 540 + shake.y)
        cg.rotate(by: degrees(roll))
        cg.scaleBy(x: zoom, y: zoom)
        cg.translateBy(x: -center.x, y: -center.y)
    }
}

enum Ease { case linear, smooth, snap, anticipate, blast }

struct CameraKey {
    let time: Double, zoom: Double, center: V2, pitch: Double, yaw: Double, roll: Double, ease: Ease
    init(_ time: Double, _ zoom: Double, _ center: V2, pitch: Double = 0, yaw: Double = 0, roll: Double = 0, _ ease: Ease = .smooth) {
        self.time = time; self.zoom = zoom; self.center = center
        self.pitch = pitch; self.yaw = yaw; self.roll = roll; self.ease = ease
    }
}

struct Crack {
    let time: Double
    let hero: Bool
    let space: StrikeSpace
    let target: V2
    let aim: Double
    let seed: Int
}

final class Director {
    let film: Film
    let terminal: Terminal
    let passes: [WhipPass]
    let whips: [Whip]
    let cracks: [Crack]
    let compositor: Compositor
    let art: Lockup.Art
    let avatar: CGImage
    var freezeAmbient = false
    var grain = 1.6

    private let stage = Canvas(width: 1920, height: 1080)
    private let whipCanvas = Canvas(width: 1920, height: 1080)
    private let hud = Canvas(width: 1920, height: 1080)
    private let captions = Canvas(width: 1920, height: 1080)
    private let lockup = Canvas(width: 1920, height: 1080)
    private let emissive = Canvas(width: 1920, height: 1080)
    private let errorLayer = Canvas(width: 1920, height: 1080)
    private let cameraKeys: [CameraKey]
    private let captionList: [Caption]
    private var emitted = false

    init(film: Film, icon: CGImage, avatar: CGImage) {
        self.film = film
        terminal = Terminal(film: film)
        compositor = Compositor(width: 1920, height: 1080)
        self.avatar = avatar
        art = Lockup.Art(icon: icon, iconMask: Director.mask(from: icon))

        let words = film.messageWords
        let chunks = film.strikeChunks
        func caret(_ count: Int) -> V2 { TerminalLayout.caret(after: count, of: words) + V2(12, -30) }
        let middle = TerminalLayout.caret(after: words.count, of: words)
        let center = V2((TerminalLayout.textX + middle.x) / 2 + 60, middle.y - 30)
        // Each pass enters before its first wind-up and leaves after its last follow-through.
        let strikes = film.capacityStrikes
        passes = [
            WhipPass(enter: film.reveal - 0.88, exit: film.reveal + 0.22, space: .screen,
                     strikes: [StrikePlan(impact: film.reveal, target: V2(960, 468), aim: 151, hero: true)]),
            WhipPass(enter: strikes[0] - 0.75, exit: strikes.last! + 0.75, space: .stage,
                     strikes: zip(strikes, chunks).enumerated().map { index, pair in
                         StrikePlan(impact: pair.0, target: caret(pair.1), aim: 144 + Double(index) * 2, hero: false)
                     }),
            WhipPass(enter: film.quotaStrike - 0.85, exit: film.quotaStrike + 0.55, space: .stage,
                     strikes: [StrikePlan(impact: film.quotaStrike, target: center, aim: 146, hero: false)]),
            WhipPass(enter: film.resetStrike - 0.85, exit: film.resetStrike + 0.55, space: .stage,
                     strikes: [StrikePlan(impact: film.resetStrike, target: center, aim: 146, hero: false)]),
            WhipPass(enter: film.finale - 0.88, exit: film.finale + 0.22, space: .screen,
                     strikes: [StrikePlan(impact: film.finale, target: V2(960, 392), aim: 152, hero: true)]),
        ]
        whips = passes.map(Whip.init)
        var cracks: [Crack] = []
        for pass in passes {
            for strike in pass.strikes {
                cracks.append(Crack(time: strike.impact, hero: strike.hero, space: pass.space, target: strike.target,
                                    aim: strike.aim, seed: Int(strike.impact * 1000)))
            }
        }
        self.cracks = cracks
        captionList = film.captions
        let overview = V2(960, 540)
        // Push in toward the input while the whip works, then settle back.
        func push(_ impacts: [Double], zoom: Double) -> [CameraKey] {
            [CameraKey(impacts[0] - 0.65, 1, overview), CameraKey(impacts[0] - 0.1, zoom, V2(880, 545)),
             CameraKey(impacts.last! + 0.6, zoom, V2(880, 545)), CameraKey(impacts.last! + 1.4, 1, overview)]
        }
        // A short breath out while time skips forward.
        func lapse(_ span: (start: Double, end: Double)) -> [CameraKey] {
            [CameraKey(span.start, 1, overview), CameraKey(span.start + 0.4, 0.97, V2(960, 560)), CameraKey(span.end + 0.05, 1, overview)]
        }
        cameraKeys = [
            CameraKey(0, 0.98, V2(640, 520), pitch: 8, yaw: -19, roll: 1.2),
            CameraKey(film.stop - 0.05, 1.3, V2(625, 536), pitch: 4, yaw: -10, roll: 0.3, .blast),
            CameraKey(film.stop + 0.35, 1.6, V2(640, 700), .snap),
            CameraKey(film.reveal - 0.45, 1.68, V2(640, 700), .linear),
            CameraKey(film.reveal - 0.05, 1.46, V2(650, 690), .anticipate),
            CameraKey(film.reveal + 0.6, 0.9, V2(820, 620), pitch: 7, yaw: -9, .blast),
            CameraKey(film.reveal + 3.0, 0.93, V2(840, 600), pitch: 5, yaw: -6, .linear),
            CameraKey(film.reveal + 4.1, 1, overview),
        ] + push(strikes, zoom: 1.06) + lapse(film.quotaLapse) + push([film.quotaStrike], zoom: 1.05)
          + lapse(film.resetLapse) + push([film.resetStrike], zoom: 1.05) + lapse(film.morningLapse) + [
            CameraKey(film.activityEnters - 0.2, 1, overview),
            CameraKey(film.activityEnters + 0.5, 0.98, V2(1010, 560)),
            CameraKey(film.finale - 0.45, 0.98, V2(1010, 560)),
            CameraKey(film.finale - 0.05, 1.05, V2(1000, 560), .anticipate),
            CameraKey(film.finale + 0.6, 0.88, V2(980, 600), pitch: 6, yaw: -8, .blast),
            CameraKey(Film.duration, 0.9, V2(980, 600), pitch: 5, yaw: -6, .linear),
        ]
        precondition(zip(cameraKeys, cameraKeys.dropFirst()).allSatisfy { $0.time <= $1.time }, "Camera keys must be in time order")
    }

    /// A DeviceGray mask from the icon's alpha, for clipped highlights.
    static func mask(from icon: CGImage) -> CGImage {
        let w = icon.width, h = icon.height
        let alpha = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                              space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue)!
        alpha.draw(icon, in: CGRect(x: 0, y: 0, width: w, height: h))
        let gray = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                             space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        let source = alpha.data!.assumingMemoryBound(to: UInt8.self)
        let target = gray.data!.assumingMemoryBound(to: UInt8.self)
        for i in 0..<(w * h) { target[i] = source[i] }
        return gray.makeImage()!
    }

    // MARK: Camera

    func camera(_ t: Double) -> Camera {
        let keys = cameraKeys
        var camera: Camera
        if let index = keys.lastIndex(where: { $0.time <= t }), index < keys.count - 1 {
            let a = keys[index], b = keys[index + 1]
            let u = clamp01((t - a.time) / (b.time - a.time))
            let f: Double
            switch b.ease {
            case .linear: f = u
            case .smooth: f = smoother(u)
            case .snap: f = easeOut(u, 4)
            case .anticipate: f = easeInOut(u)
            case .blast: f = easeOut(u, 3)
            }
            camera = Camera(zoom: mix(a.zoom, b.zoom, f), center: mix(a.center, b.center, f),
                            tilt: Tilt(pitch: mix(a.pitch, b.pitch, f), yaw: mix(a.yaw, b.yaw, f)), roll: mix(a.roll, b.roll, f))
        } else {
            let k = t < keys[0].time ? keys[0] : keys[keys.count - 1]
            camera = Camera(zoom: k.zoom, center: k.center, tilt: Tilt(pitch: k.pitch, yaw: k.yaw), roll: k.roll)
        }
        var shake = V2.zero
        for crack in cracks where t >= crack.time && t < crack.time + 0.5 {
            let tau = t - crack.time
            let amplitude = (crack.hero ? 15.0 : 6.5) * exp(-tau / 0.085)
            shake += V2(sin(2 * .pi * 29 * tau + Double(crack.seed)), cos(2 * .pi * 23 * tau)) * amplitude
        }
        if t >= film.stop && t < film.stop + 0.3 {
            let tau = t - film.stop
            shake += V2(sin(tau * 160) * 9, cos(tau * 130) * 4) * exp(-tau / 0.08)
        }
        camera.shake = shake
        return camera
    }

    func screenPoint(_ crack: Crack, camera: Camera) -> V2 {
        crack.space == .screen ? crack.target : camera.toScreen(crack.target)
    }

    // MARK: Frame

    func frame(_ t: Double, index: Int) -> CIImage {
        let cam = camera(t)
        let c = compositor

        // Stage: terminal and cards in world space.
        stage.clear()
        stage.draw { cg in
            cam.apply(cg)
            let glitch = t >= film.stop && t < film.stop + 0.32 ? 1 - (t - film.stop) / 0.32 : 0
            terminal.draw(cg, t: t, glitch: glitch)
            drawCards(cg, t)
        }
        var world = c.image(stage)
        let lapse = [film.quotaLapse, film.resetLapse, film.morningLapse].contains { t >= $0.start && t < $0.end + 0.1 }
        if lapse {
            let all = [film.quotaLapse, film.resetLapse, film.morningLapse]
            let speed = all.map { presence(t, $0.start, $0.end + 0.1, fadeIn: 0.25, fadeOut: 0.3) }.max() ?? 0
            world = c.motionBlur(world, velocity: V2(0, 9 * speed))
        }
        world = c.perspective(world, cam.tilt)
        // Focus pulls: the caption after the stop, the reveal and the finale.
        let pull = presence(t, 4.6, 8.1, fadeIn: 0.45, fadeOut: 0.12)
        let focus = 7 * pull + mix(0, 16, smooth((t - 8.0) / 0.4)) * (1 - smooth((t - 10.8) / 1.1)) + 18 * smooth((t - 51.95) / 0.45)
        let dimAmount = min(1 - 0.42 * pull, 1 - 0.58 * smooth((t - 8.0) / 0.3) * (1 - smooth((t - 10.8) / 1.1)),
                            1 - 0.5 * smooth((t - 52.0) / 0.4))
        // The finale lets the terminal dissolve so the end card sits on the open blueprint.
        world = c.fade(c.dim(c.blur(world, focus), dimAmount), 1 - smooth((t - 52.15) / 1.5))
        // The capacity error stays sharp and bright while the session waits, so it can be read,
        // and softens with the rest of the terminal when the reveal arrives.
        let readable = presence(t, 4.6, 8.35, fadeIn: 0.45, fadeOut: 0.3)
        if readable > 0 {
            errorLayer.clear()
            errorLayer.draw { cg in
                cam.apply(cg)
                terminal.drawErrors(cg, t: t)
            }
            world = c.fade(c.perspective(c.image(errorLayer), cam.tilt), readable).composited(over: world)
        }

        // Whip with motion blur and a soft shadow.
        if let whipLayer = whipImage(t, camera: cam) {
            let shadow = c.shadow(of: whipLayer, offset: V2(10, 16), radius: 9, opacity: 0.5)
            world = whipLayer.composited(over: shadow.composited(over: world))
        }
        let dawn = smooth((t - film.morningLapse.start) / 2.2)
        let brand = smooth((t - film.finale) / 1.2)
        let night = 1 - smooth((t - film.morningLapse.start) / 1.6)
        let background = c.background(t: t, dawn: dawn, brand: brand, parallax: (cam.center - V2(960, 540)) * 0.18,
                                      stars: night * 0.9, freeze: freezeAmbient)
        var image = world.composited(over: background)

        // Crack distortion.
        var exposure = 0.0
        for crack in cracks where t >= crack.time && t < crack.time + 0.6 {
            let tau = t - crack.time
            let p = screenPoint(crack, camera: cam)
            let life = crack.hero ? 0.6 : 0.42
            let u = tau / life
            image = c.shockwave(image, center: p, radius: (crack.hero ? 40 : 24) + (crack.hero ? 1250 : 460) * easeOut(u, 2.2),
                                width: crack.hero ? 110 : 46, refraction: (crack.hero ? 2.0 : 1.5) * (1 - smooth(u)))
            image = c.chromatic(image, center: p, amount: (crack.hero ? 9 : 4) * exp(-tau / 0.07))
            if crack.hero {
                image = c.zoomBlur(image, center: p, amount: 18 * exp(-tau / 0.06))
                exposure += 0.45 * exp(-tau / 0.09)
            }
        }
        if t >= film.stop && t < film.stop + 0.4 {
            exposure -= 0.55 * sin(.pi * clamp01((t - film.stop) / 0.4))
        }

        // Light: flashes, sparks, rings and glows.
        emissive.clear()
        emitted = false
        emissive.draw { cg in drawEmissive(cg, t, cam) }
        if emitted {
            let glowSource = c.image(emissive)
            image = c.add(c.glow(glowSource, strength: 1), over: image)
            image = c.add(c.fade(glowSource, 0.85), over: image)
        }

        // Lockups, captions and interface stay crisp.
        if (t >= 8.0 && t < 11.4) || t >= film.finale {
            lockup.clear()
            lockup.draw { cg in drawLockups(cg, t) }
            image = c.image(lockup).composited(over: image)
        }

        let active = captionList.filter { t >= $0.start && t <= $0.end }
        if !active.isEmpty {
            captions.clear()
            var captionBlur = 0.0
            captions.draw { cg in
                for caption in active {
                    CaptionArt.draw(cg, caption, t)
                    captionBlur = max(captionBlur, CaptionArt.blur(caption, t))
                }
            }
            let captionImage = c.blur(c.image(captions), captionBlur)
            let captionShadow = c.shadow(of: captionImage, offset: V2(0, 4), radius: 16, opacity: 0.7)
            image = captionImage.composited(over: captionShadow.composited(over: image))
        }

        hud.clear()
        hud.draw { cg in drawInterface(cg, t) }
        image = c.image(hud).composited(over: image)

        let fadeIn = smooth(t / 0.7)
        image = c.dim(image, fadeIn)
        return c.finish(image, exposure: exposure, vignette: 0.55, grain: freezeAmbient ? 0 : grain, frame: index)
    }

    // MARK: Whip

    private func whipImage(_ t: Double, camera: Camera) -> CIImage? {
        guard let whip = whips.first(where: { t >= $0.visible.0 && t <= $0.visible.1 }) else { return nil }
        let shutter = 0.5 / Double(Film.fps)
        let early = whip.pose(t - shutter / 2), late = whip.pose(t + shutter / 2)
        var travel = 0.0
        for (a, b) in zip(early.points, late.points) { travel = max(travel, (a - b).length) }
        travel = max(travel, (early.grip - late.grip).length)
        let scale = whip.pass.space == .stage ? camera.zoom : 1
        let samples = max(1, min(24, Int(ceil(travel * scale / 5))))
        var images: [CIImage] = []
        for k in 0..<samples {
            let time = samples == 1 ? t : t - shutter / 2 + shutter * Double(k) / Double(samples - 1)
            let pose = whip.pose(time)
            whipCanvas.clear()
            whipCanvas.draw { cg in
                if whip.pass.space == .stage { camera.apply(cg) }
                WhipArt.draw(pose, in: cg)
            }
            images.append(compositor.image(whipCanvas))
        }
        var image = compositor.average(images)
        if samples > 1 {
            // Keep the lash readable at speed: a crisp pose rides on its own motion trail.
            let pose = whip.pose(t)
            whipCanvas.clear()
            whipCanvas.draw { cg in
                if whip.pass.space == .stage { camera.apply(cg) }
                WhipArt.draw(pose, in: cg)
            }
            image = compositor.fade(compositor.image(whipCanvas), 0.72).composited(over: image)
        }
        if whip.pass.space == .stage { image = compositor.perspective(image, camera.tilt) }
        return image
    }

    // MARK: Stage cards

    private func drawCards(_ cg: CGContext, _ t: Double) {
        if t >= film.postEnters && t < film.postLeaves + 0.5 {
            let enter = spring(t - film.postEnters, frequency: 1.4, damping: 0.72)
            let leave = smooth((t - film.postLeaves) / 0.45)
            cg.withAlpha(clamp01((t - film.postEnters) / 0.2) * (1 - leave)) {
                cg.withState {
                    let origin = V2(700 + (1 - enter) * 460, 410 - leave * 40)
                    cg.translateBy(x: origin.x + 300, y: origin.y + 103)
                    cg.rotate(by: degrees(-4 * (1 - enter)))
                    cg.scaleBy(x: 1.22, y: 1.22)
                    cg.translateBy(x: -origin.x - 300, y: -origin.y - 103)
                    PostCard.draw(cg, at: origin, avatar: avatar)
                }
            }
        }
        if t >= film.activityEnters && t < film.activityLeaves + 0.4 {
            let enter = spring(t - film.activityEnters, frequency: 1.5, damping: 0.75)
            let leave = smooth((t - film.activityLeaves) / 0.4)
            cg.withAlpha(clamp01((t - film.activityEnters) / 0.25) * (1 - leave)) {
                cg.withState {
                    let f = ActivityWindow.frame
                    let s = 0.9 + 0.1 * enter
                    cg.translateBy(x: f.midX, y: f.midY + (1 - enter) * 40)
                    cg.scaleBy(x: s, y: s)
                    cg.translateBy(x: -f.midX, y: -f.midY)
                    ActivityWindow.draw(cg, recent: recentActivity)
                }
            }
        }
    }

    /// The Activity report's five newest events, newest first. A retry counts as successful
    /// after two uninterrupted minutes.
    private var recentActivity: [(clock: Double, label: String)] {
        let quotaSent = film.quotaCheckTimes[1], resetSent = film.resetCheckAt
        return [(resetSent + 2, "Quota retry successful"), (resetSent, "Quota retry sent"), (film.resetAt, "Quota limit found"),
                (quotaSent + 2, "Quota retry successful"), (quotaSent, "Quota retry sent")]
    }

    // MARK: Light

    private func drawEmissive(_ cg: CGContext, _ t: Double, _ camera: Camera) {
        for crack in cracks where t >= crack.time && t < crack.time + 0.9 {
            emitted = true
            let tau = t - crack.time
            let p = screenPoint(crack, camera: camera)
            let flashLife = crack.hero ? 0.42 : 0.26
            if tau < flashLife {
                let u = tau / flashLife
                let radius = (crack.hero ? 120 : 46) + (crack.hero ? 520 : 170) * easeOut(tau / 0.14, 3)
                let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                          colors: [RGBA(0xFFFFFF, 0.95 * pow(1 - u, 2)).cg, Palette.ice.alpha(0.5 * pow(1 - u, 2)).cg,
                                                   Palette.cyan.alpha(0).cg] as CFArray, locations: [0, 0.18, 1])!
                cg.drawRadialGradient(gradient, startCenter: p.cg, startRadius: 0, endCenter: p.cg, endRadius: radius, options: [])
            }
            let ringLife = crack.hero ? 0.75 : 0.5
            if tau < ringLife {
                let u = tau / ringLife
                cg.ring(p, 18 + (crack.hero ? 980 : 330) * easeOut(u, 2.4), Palette.ice.alpha(0.75 * pow(1 - u, 1.5)),
                        width: (crack.hero ? 5 : 3) * (1 - u) + 0.5)
            }
            let count = crack.hero ? 36 : 18
            for i in 0..<count {
                let r1 = hashNoise(crack.seed + i * 13), r2 = hashNoise(crack.seed + i * 13 + 5), r3 = hashNoise(crack.seed + i * 13 + 9)
                let life = 0.22 + 0.4 * r3
                guard tau < life else { continue }
                let angle = crack.aim + (r1 - 0.5) * (crack.hero ? 300 : 150)
                let speed = (crack.hero ? 900 : 520) + (crack.hero ? 1400 : 900) * r2
                let k = 5.5
                func position(_ s: Double) -> V2 {
                    p + direction(angle) * speed * (1 - exp(-k * s)) / k + V2(0, 700) * s * s / 2
                }
                let head = position(tau), tail = position(max(0, tau - 0.028))
                let fade = 1 - tau / life
                let color = i % 4 == 0 ? Palette.amber : (i % 3 == 0 ? Palette.cyan : Palette.ice)
                cg.line(tail, head, color.alpha(0.95 * fade), width: 2.4 * fade + 0.4)
            }
        }
        // The menu bar glyph glows when Whip acts.
        if t >= 11.3 {
            let center = MenuBar.glyphCenter()
            let events = cracks.filter { $0.space == .stage }.map(\.time) + film.quotaChecks + [film.resetCheck, 11.3]
            for e in events where t >= e && t < e + 1.0 {
                emitted = true
                let u = (t - e) / 1.0
                cg.ring(center, 12 + 34 * easeOut(u), Palette.cyan.alpha(0.7 * (1 - u)), width: 2)
                cg.circle(center, 16, fill: Palette.cyan.alpha(0.35 * (1 - u)))
            }
        }
        // Rows in the Whip column glow faintly as they land.
        if let rows = timelineRows(t) {
            var y = TimelineColumn.top + TimelineColumn.firstRow
            for row in rows.rows where t >= row.time {
                let age = t - row.time
                if age < 0.9 {
                    emitted = true
                    cg.circle(V2(TimelineColumn.x + 12, y + 14), 16,
                              fill: TimelineColumn.color(row.mark).alpha(0.5 * (1 - age / 0.9) * rows.alpha))
                }
                y += TimelineColumn.rowHeight(row)
            }
        }
        // Logo glow.
        for (start, end, center, size) in [(8.02, 11.35, revealIconCenter(t), revealIconSize(t)), (52.02, 61.0, V2(960, 350), 210.0)]
        where t >= start && t < end {
            let pulse = t >= film.finalHit ? 0.25 * exp(-(t - film.finalHit) / 0.6) : 0
            let alpha = (0.32 + pulse) * smooth((t - start) / 0.3) * (1 - smooth((t - (end - 0.2)) / 0.2))
            emitted = true
            cg.fill(CGRect(x: center.x - size * 0.42, y: center.y - size * 0.42, width: size * 0.84, height: size * 0.84),
                    Palette.blue.alpha(alpha), radius: size * 0.2)
        }
    }

    // MARK: Lockups

    private func revealIconCenter(_ t: Double) -> V2 {
        let fly = easeInOut((t - 10.6) / 0.75)
        let start = V2(960, 404), end = MenuBar.glyphCenter()
        let arc = V2(0, -120) * sin(.pi * fly)
        return mix(start, end, fly) + arc
    }

    private func revealIconSize(_ t: Double) -> Double {
        let pop = 0.5 + 0.5 * spring(t - 8.02, frequency: 1.45, damping: 0.5)
        return 236 * pop * mix(1, 0.1, easeInOut((t - 10.6) / 0.75))
    }

    private func drawLockups(_ cg: CGContext, _ t: Double) {
        if t >= 8.0 && t < 11.4 {
            let fly = easeInOut((t - 10.6) / 0.75)
            let textAlpha = 1 - smooth((t - 10.4) / 0.35)
            Lockup.blueprint(cg, center: V2(960, 404), t: t, start: 8.05, alpha: 1 - smooth((t - 10.3) / 0.5))
            cg.withAlpha(1 - smooth((t - 11.15) / 0.2)) {
                Lockup.icon(cg, art, center: revealIconCenter(t), size: revealIconSize(t),
                            rotation: -10 * (1 - spring(t - 8.02, frequency: 1.3, damping: 0.55)) + 8 * sin(.pi * fly),
                            sweep: (t - 8.45) / 0.9)
            }
            cg.withAlpha(textAlpha) {
                Lockup.wordmark(cg, centerX: 960, baseline: 652, size: 104, reveal: (t - 8.3) / 0.6)
                let tagline = TextStyle(font: Fonts.text(36), color: Palette.secondary)
                let text = "Keep Codex working."
                let enter = spring(t - 8.75, frequency: 1.5, damping: 0.8)
                cg.withAlpha(clamp01((t - 8.75) / 0.3)) {
                    drawText(text, x: 960 - measure(text, tagline) / 2, baseline: 722 + (1 - enter) * 16, tagline)
                }
            }
        }
        if t >= 52.0 {
            Lockup.blueprint(cg, center: V2(960, 350), t: t, start: 52.05, alpha: 1)
            let pop = 0.5 + 0.5 * spring(t - 52.02, frequency: 1.45, damping: 0.5)
            let float = sin((t - 52) * 1.4) * 3
            Lockup.icon(cg, art, center: V2(960, 350 + float), size: 210 * pop,
                        rotation: -10 * (1 - spring(t - 52.02, frequency: 1.3, damping: 0.55)),
                        sweep: t < film.finalHit ? (t - 52.45) / 0.9 : (t - film.finalHit) / 0.9)
            Lockup.wordmark(cg, centerX: 960, baseline: 566, size: 96, reveal: (t - 52.3) / 0.6)
            let left = TextStyle(font: Fonts.display(52, .bold), color: Palette.white, kern: -1.0)
            let right = left.with(color: Palette.cyan)
            let a = "Codex stops. ", b = "Whip doesn’t."
            let total = measure(a, left) + measure(b, right)
            let x = 960 - total / 2
            for (offset, text, style, delay) in [(0.0, a, left, 52.75), (measure(a, left), b, right, 53.0)] where t >= delay {
                let enter = spring(t - delay, frequency: 1.7, damping: 0.72)
                cg.withAlpha(clamp01((t - delay) / 0.25)) {
                    drawText(text, x: x + offset, baseline: 650 + (1 - enter) * 30, style)
                }
            }
            if t >= film.ctaEnters {
                let enter = spring(t - film.ctaEnters, frequency: 1.6, damping: 0.75)
                cg.withAlpha(clamp01((t - film.ctaEnters) / 0.3)) {
                    let pillStyle = TextStyle(font: Fonts.text(24, .semibold), color: Palette.ink)
                    let urlStyle = TextStyle(font: Fonts.text(30, .semibold), color: Palette.white, kern: -0.3)
                    let pillText = "Download free", url = "codexwhip.com"
                    let pillWidth = measure(pillText, pillStyle) + 56
                    let gap = 28.0
                    let rowWidth = pillWidth + gap + measure(url, urlStyle)
                    let rowX = 960 - rowWidth / 2, y = 712 + (1 - enter) * 20
                    let pill = CGRect(x: rowX, y: y, width: pillWidth, height: 56)
                    cg.fill(pill, Palette.cyan, radius: 28)
                    drawText(pillText, x: pill.minX + 28, baseline: pill.minY + 36, pillStyle)
                    drawText(url, x: pill.maxX + gap, baseline: pill.minY + 38, urlStyle)
                    let fine = TextStyle(font: Fonts.text(18), color: Palette.tertiary)
                    let fineText = "Open source · MIT licensed · macOS 14+ · Unofficial Codex CLI companion"
                    drawText(fineText, x: 960 - measure(fineText, fine) / 2, baseline: 818 + (1 - enter) * 12, fine)
                }
            }
        }
    }

    // MARK: Interface

    func timelineRows(_ t: Double) -> (rows: [TimelineRow], alpha: Double)? {
        let s = film.settings
        if t >= 12.2 && t < 22.0 {
            return ([
                TimelineRow(time: 12.45, clock: clockText(film.capacityFoundAt), label: "Capacity error", detail: "Found on the next check", mark: .error),
                TimelineRow(time: 12.75, clock: clockText(film.capacityFoundAt), label: "Retry in", detail: nil, mark: .pending,
                            countdown: (film.retryCountdown.start, film.retryCountdown.end, s.retrySeconds)),
                TimelineRow(time: film.capacitySend + 0.05, clock: clockText(film.retryAt), label: "Retry sent",
                            detail: "Saved message, same model", mark: .sent),
            ], presence(t, 12.2, 22.0, fadeIn: 0.4, fadeOut: 0.45))
        }
        if t >= 22.7 && t < 32.0 {
            return ([
                TimelineRow(time: 22.85, clock: clockText(film.quotaAt), label: "Usage limit reached", detail: "Waiting for quota", mark: .warn),
                TimelineRow(time: film.quotaChecks[0], clock: clockText(film.quotaCheckTimes[0]), label: "Checked Codex",
                            detail: "Not available yet", mark: .pending),
                TimelineRow(time: film.quotaChecks[1], clock: clockText(film.quotaCheckTimes[1]), label: "Quota available",
                            detail: "Confirmed by Codex", mark: .check),
                TimelineRow(time: film.quotaSend + 0.05, clock: clockText(film.quotaCheckTimes[1]), label: "Retry sent",
                            detail: "Saved message, same model", mark: .sent),
            ], presence(t, 22.7, 32.0, fadeIn: 0.35, fadeOut: 0.45))
        }
        if t >= 32.7 && t < 42.0 {
            return ([
                TimelineRow(time: 32.85, clock: clockText(film.resetAt), label: "Usage limit reached", detail: "Waiting for quota", mark: .warn),
                TimelineRow(time: film.resetCheck, clock: clockText(film.resetCheckAt), label: "Quota available",
                            detail: "Confirmed by Codex", mark: .check),
                TimelineRow(time: film.resetSend + 0.05, clock: clockText(film.resetCheckAt), label: "Retry sent",
                            detail: "Saved message, same model", mark: .sent),
            ], presence(t, 32.7, 42.0, fadeIn: 0.35, fadeOut: 0.45))
        }
        return nil
    }

    private var menuItems: [MenuItem] {
        let s = film.settings
        return [
            MenuItem(title: "Watching 1 session", enabled: false), .line,
            MenuItem(title: "Pause"), MenuItem(title: "Start at Login", checked: true),
            MenuItem(title: "Retry every \(menuDuration(s.retrySeconds))", submenu: true),
            MenuItem(title: "Check every \(menuDuration(s.checkSeconds))", submenu: true),
            MenuItem(title: "Retry Message: Default", submenu: true), .line,
            MenuItem(title: "Check for Updates…"), MenuItem(title: "Automatic Updates", checked: true), .line,
            MenuItem(title: "Activity"), MenuItem(title: "Watch Demo"), .line,
            MenuItem(title: "Quit Codex Whip", key: "⌘Q"),
        ]
    }

    /// native/Settings.swift's retry choices. The film runs on the defaults, so the default is also selected.
    private var retryChoices: [MenuItem] {
        [60, 120, 180, 300, 600, 900, 1800, 3600].map { value in
            MenuItem(title: menuDuration(value) + (value == film.settings.retrySeconds ? " (default)" : ""),
                     checked: value == film.settings.retrySeconds)
        }
    }

    private let menuWidth = 436.0, submenuWidth = 290.0
    private var menuOrigin: V2 { V2(1920 - 10 - menuWidth, 38) }
    private var submenuOrigin: V2 {
        V2(menuOrigin.x - submenuWidth + 6, MenuArt.rowTop(menuItems, retryRowIndex, origin: menuOrigin) - 5 * MenuArt.scale)
    }
    /// The interval row the pointer opens, wherever it sits in the menu.
    private var retryRowIndex: Int { menuItems.firstIndex { $0.title.hasPrefix("Retry every") }! }

    private func cursorPosition(_ t: Double) -> V2 {
        let glyph = MenuBar.glyphCenter() + V2(2, 2)
        let retryRow = V2(menuOrigin.x + 170, MenuArt.rowTop(menuItems, retryRowIndex, origin: menuOrigin) + MenuArt.rowHeight / 2)
        let choice = V2(submenuOrigin.x + 120, MenuArt.rowTop(retryChoices, 2, origin: submenuOrigin) + MenuArt.rowHeight / 2)
        let path: [(Double, V2)] = [(47.3, V2(1240, 660)), (48.1, glyph), (48.65, glyph), (49.2, retryRow), (49.65, retryRow),
                                    (50.15, choice), (50.8, choice), (51.0, V2(1180, 700)), (52.0, V2(1180, 700))]
        guard let index = path.lastIndex(where: { $0.0 <= t }), index < path.count - 1 else { return t < path[0].0 ? path[0].1 : path.last!.1 }
        let a = path[index], b = path[index + 1]
        return mix(a.1, b.1, easeInOut((t - a.0) / (b.0 - a.0)))
    }

    private func drawInterface(_ cg: CGContext, _ t: Double) {
        // Menu bar.
        let menuOpen = t >= film.menuClick && t < film.menuCloses
        cg.withAlpha(1 - smooth((t - 52.0) / 0.5)) {
            let glyphGlow = cracks.filter { $0.space == .stage }.map { t >= $0.time ? exp(-(t - $0.time) / 0.35) : 0 }.max() ?? 0
            MenuBar.draw(cg, minutes: film.clock(at: t), glyph: smooth((t - 11.2) / 0.25), glyphGlow: glyphGlow,
                         highlight: menuOpen ? 1 : 0)
        }
        // Time-skip chips.
        for lapse in [film.quotaLapse, film.resetLapse, film.morningLapse] {
            let a = presence(t, lapse.start, lapse.end + 0.45, fadeIn: 0.2, fadeOut: 0.3)
            guard a > 0 else { continue }
            cg.withAlpha(a) {
                let style = TextStyle(font: Fonts.text(22, .semibold), color: Palette.white)
                let text = "▸▸  " + clockText(film.clock(at: t))
                let width = measure(text, style) + 44
                let rect = CGRect(x: 960 - width / 2, y: 62, width: width, height: 46)
                cg.fill(rect, RGBA(0x0D1B2D, 0.86), radius: 23)
                cg.strokeRounded(rect, Palette.cyan.alpha(0.35), radius: 23, width: 1)
                drawText(text, x: rect.minX + 22, baseline: rect.minY + 31, style)
            }
        }
        // Whip column.
        if let rows = timelineRows(t) {
            // The column steps back while the whip works across it.
            let busy = passes.filter { $0.space == .stage }.map { presence(t, $0.enter + 0.1, $0.strikes.last!.impact + 0.45, fadeIn: 0.3, fadeOut: 0.3) }.max() ?? 0
            TimelineColumn.draw(cg, rows: rows.rows, t: t, alpha: rows.alpha * (1 - 0.72 * busy))
        }
        // Chapters and disclosure.
        let chapterAlpha = presence(t, 12.0, 52.0, fadeIn: 0.5, fadeOut: 0.5)
        if chapterAlpha > 0 {
            cg.withAlpha(chapterAlpha) {
                var x = 120.0
                for chapter in film.chapters {
                    let active = t >= chapter.start && t < chapter.end
                    let style = TextStyle(font: Fonts.text(15, .semibold), color: active ? Palette.white : Palette.tertiary, kern: 1.1)
                    let label = chapter.name.uppercased()
                    drawText(label, x: x, baseline: 1036, style)
                    let width = measure(label, style)
                    cg.fill(CGRect(x: x, y: 1046, width: width, height: 3), RGBA(0x5DBBEE, 0.18), radius: 1.5)
                    if active {
                        cg.fill(CGRect(x: x, y: 1046, width: width * clamp01((t - chapter.start) / (chapter.end - chapter.start)), height: 3),
                                Palette.cyan, radius: 1.5)
                    }
                    x += width + 34
                }
            }
        }
        let disclosure = TextStyle(font: Fonts.text(15.5, .medium), color: Palette.tertiary)
        let note = "Illustrated demo · Time compressed"
        drawText(note, x: 1800 - measure(note, disclosure), baseline: 1036, disclosure)

        // Morning: the real menu and its interval submenu.
        if t >= film.menuClick && t < film.menuCloses + 0.2 {
            let open = clamp01((t - film.menuClick - 0.03) / 0.12)
            let close = smooth((t - film.menuCloses) / 0.15)
            cg.withAlpha((1 - close) * clamp01(open * 3)) {
                let hover: Int? = t >= 49.15 ? retryRowIndex : nil
                MenuArt.draw(cg, menuItems, origin: menuOrigin, width: menuWidth, hover: hover, reveal: easeOut(open, 2))
                if t >= film.submenuOpens {
                    let sub = clamp01((t - film.submenuOpens) / 0.1)
                    MenuArt.draw(cg, retryChoices, origin: submenuOrigin, width: submenuWidth, hover: t >= 50.1 ? 2 : nil, reveal: sub)
                }
            }
        }
        if t >= 47.3 && t < 51.6 {
            let alpha = presence(t, 47.3, 51.6, fadeIn: 0.25, fadeOut: 0.3)
            var press = 0.0
            for click in [film.menuClick, film.menuCloses] where t >= click && t < click + 0.16 {
                press = max(press, sin(Double.pi * (t - click) / 0.16))
            }
            cg.withAlpha(alpha) { Cursor.draw(cg, at: cursorPosition(t), scale: 1 - 0.12 * press) }
        }
    }
}
