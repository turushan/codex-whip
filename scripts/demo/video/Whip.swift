import AppKit
import CoreGraphics

// A kinematic bullwhip. The thong is an inextensible curve described by its tangent
// angle along its length, so every pose keeps its length and every crack lands on its
// beat. A throw lays the thong out behind the handle; the handle snaps forward and
// stops; a U-turn loop then rolls from the handle to the tip, which flips over the
// loop at full extension. That flip is the crack.

struct WhipPose {
    var grip: V2
    var angle: Double
    var points: [V2]

    var direction: V2 { Whip.directionOf(angle) }
    var butt: V2 { grip - direction * Whip.handle * 0.38 }
    var ferrule: V2 { grip + direction * Whip.handle * Whip.ferruleShare }
}

final class Whip {
    static let thong = 600.0
    static let handle = 150.0
    static let ferruleShare = 0.62
    static let samples = 121
    static var reach: Double { thong + handle * ferruleShare }
    static func directionOf(_ angle: Double) -> V2 { direction(angle) }

    let pass: WhipPass
    let windup = 0.62, stroke = 0.30, handleStop = 0.17, loopLead = 0.21
    let loopStartWidth = 96.0, loopEndWidth = 32.0
    let idleGrip: V2
    let offscreen: V2

    init(pass: WhipPass) {
        self.pass = pass
        let first = pass.strikes[0]
        let firstGrip = first.target - direction(first.aim) * Whip.reach
        idleGrip = firstGrip + V2(150, -40)
        offscreen = V2(820, -260)
    }

    func grip(for strike: StrikePlan) -> V2 { strike.target - direction(strike.aim) * Whip.reach }

    var visible: (Double, Double) { (pass.enter, keys.last!.time) }

    // MARK: Handle

    private struct Key { let time: Double; let grip: V2; let angle: Double; let snap: Bool }

    private lazy var keys: [Key] = {
        let idleAngle = 226.0
        var keys = [Key(time: pass.enter, grip: idleGrip + offscreen, angle: idleAngle + 14, snap: false),
                    Key(time: pass.enter + 0.6, grip: idleGrip, angle: idleAngle, snap: false)]
        for strike in pass.strikes {
            let g = grip(for: strike)
            keys.append(Key(time: strike.impact - windup, grip: keys.last!.grip, angle: keys.last!.angle, snap: false))
            keys.append(Key(time: strike.impact - stroke, grip: g + V2(52, -64), angle: strike.aim + 152, snap: false))
            keys.append(Key(time: strike.impact - handleStop, grip: g, angle: strike.aim, snap: true))
            keys.append(Key(time: strike.impact + 0.3, grip: g + V2(16, 12), angle: strike.aim + 10, snap: false))
        }
        // After the last follow-through the whip retracts off the frame while it curls back up.
        let last = pass.strikes.last!
        keys.append(Key(time: max(last.impact + 0.32, pass.exit) + 0.6, grip: grip(for: last) + offscreen,
                        angle: idleAngle + 16, snap: false))
        return keys
    }()

    func handlePose(_ t: Double) -> (grip: V2, angle: Double) {
        guard let index = keys.lastIndex(where: { $0.time <= t }) else { return (keys[0].grip, keys[0].angle) }
        if index == keys.count - 1 { return (keys[index].grip, keys[index].angle) }
        let a = keys[index], b = keys[index + 1]
        let u = (t - a.time) / max(1e-6, b.time - a.time)
        // The throw accelerates hard into a firm stop; everything else eases.
        let f = b.snap ? pow(clamp01(u), 2.2) : smoother(u)
        return (mix(a.grip, b.grip, f), mix(a.angle, b.angle, f))
    }

    // MARK: Thong shapes (tangent angles in degrees, one per sample)

    /// The approved icon's open curl: up from the ferrule, over the top, and a tail that flicks out.
    private static let curl: [(Double, Double)] = [(0, 0), (0.07, 38), (0.2, 22), (0.36, -38), (0.52, -106),
                                                   (0.66, -166), (0.78, -212), (0.9, -228), (1.0, -206)]

    private static func profile(_ keys: [(Double, Double)], _ s: Double) -> Double {
        guard let upper = keys.firstIndex(where: { $0.0 >= s }) else { return keys.last!.1 }
        if upper == 0 { return keys[0].1 }
        let i = upper - 1
        let p0 = keys[max(0, i - 1)].1, p1 = keys[i].1, p2 = keys[upper].1, p3 = keys[min(keys.count - 1, upper + 1)].1
        let t = (s - keys[i].0) / (keys[upper].0 - keys[i].0)
        return 0.5 * ((2 * p1) + (-p0 + p2) * t + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t * t + (-p0 + 3 * p1 - 3 * p2 + p3) * t * t * t)
    }

    private func fraction(_ i: Int) -> Double { Double(i) / Double(Whip.samples - 1) }

    private func idleShape(_ handleAngle: Double, _ t: Double) -> [Double] {
        (0..<Whip.samples).map { i in
            let s = fraction(i)
            return handleAngle + Whip.profile(Whip.curl, s) + 7 * sin(t * 2.3 - s * 4.2) * s
        }
    }

    private func strokeShape(_ strike: StrikePlan, travel: Double, handleAngle: Double, progress: Double) -> [Double] {
        // The turned branch follows the handle; the rest still points back and translates
        // forward. A U-turn joins them and tightens as it nears the tip.
        let width = mix(loopStartWidth, loopEndWidth, clamp01(travel / Whip.thong))
        return (0..<Whip.samples).map { i in
            let s = fraction(i) * Whip.thong
            let u = smooth((s - travel + width) / (2 * width))
            let back = strike.aim + 194 + 30 * pow(s / Whip.thong, 2) * (1 - progress)
            let forward = handleAngle + 7 * s / Whip.thong + 3 * sin(s / 90 + progress * 6) * (1 - progress)
            return mix(forward, back, u)
        }
    }

    private func laidBack(_ strike: StrikePlan, _ handleAngle: Double) -> [Double] {
        strokeShape(strike, travel: loopStartWidth, handleAngle: handleAngle, progress: 0)
    }

    private func followShape(_ strike: StrikePlan, _ handleAngle: Double, _ dt: Double) -> [Double] {
        (0..<Whip.samples).map { i in
            let s = fraction(i)
            let droop = (90 - strike.aim) * pow(s, 1.4) * 0.8 * (1 - exp(-dt / 0.22))
            let recoil = 46 * exp(-dt / 0.1) * sin(2 * .pi * dt / 0.2) * pow(s, 3)
            let ripple = 9 * exp(-dt / 0.16) * sin(s * 11 - dt * 38) * s
            return handleAngle + 4 * s + droop + recoil + ripple
        }
    }

    private func blend(_ a: [Double], _ b: [Double], _ t: Double, start: Double, duration: Double, lag: Double) -> [Double] {
        (0..<Whip.samples).map { i in
            let s = fraction(i)
            return mix(a[i], b[i], smoother((t - start - lag * s) / max(1e-6, duration - lag)))
        }
    }

    func shape(_ t: Double) -> [Double] {
        let hand = handlePose(t)
        var current = idleShape(hand.angle, t)
        for (index, strike) in pass.strikes.enumerated() {
            let windStart = strike.impact - windup, strokeStart = strike.impact - stroke
            if t < windStart { break }
            if t < strokeStart {
                current = blend(current, laidBack(strike, hand.angle), t, start: windStart, duration: strokeStart - windStart, lag: 0.2)
                continue
            }
            if t < strike.impact {
                let loopStart = strike.impact - loopLead
                let u = clamp01((t - loopStart) / (strike.impact - loopStart))
                let travel = loopStartWidth + (Whip.thong + loopEndWidth - loopStartWidth) * pow(u, 1.9)
                current = strokeShape(strike, travel: travel, handleAngle: hand.angle, progress: u)
                continue
            }
            current = followShape(strike, hand.angle, t - strike.impact)
            if index == pass.strikes.count - 1 {
                current = blend(current, idleShape(hand.angle, t), t, start: strike.impact + 0.36, duration: 0.75, lag: 0.25)
            }
        }
        return current
    }

    func pose(_ t: Double) -> WhipPose {
        let hand = handlePose(t)
        let theta = shape(t)
        let ferrule = hand.grip + direction(hand.angle) * Whip.handle * Whip.ferruleShare
        var points = [ferrule]
        points.reserveCapacity(Whip.samples)
        let step = Whip.thong / Double(Whip.samples - 1)
        for i in 1..<Whip.samples {
            points.append(points[i - 1] + direction((theta[i - 1] + theta[i]) / 2) * step)
        }
        return WhipPose(grip: hand.grip, angle: hand.angle, points: points)
    }
}

// MARK: Leather rendering

enum WhipArt {
    static let light = V2(-0.45, -0.89).normalized

    static func thongWidth(_ s: Double) -> Double {
        if s < 0.8 { return mix(15.5, 3.4, pow(s / 0.8, 0.85)) }
        if s < 0.95 { return mix(2.7, 1.8, (s - 0.8) / 0.15) }
        return mix(1.7, 0.8, (s - 0.95) / 0.05)
    }

    /// A polygon strip following the thong with per-sample center offset and half width.
    private static func strip(_ points: [V2], _ normals: [V2], range: Range<Int>,
                              offset: (Int) -> Double, half: (Int) -> Double) -> CGPath {
        let path = CGMutablePath()
        var right: [V2] = []
        for i in range {
            let o = offset(i), h = half(i)
            let left = points[i] + normals[i] * (o + h)
            if i == range.lowerBound { path.move(to: left.cg) } else { path.addLine(to: left.cg) }
            right.append(points[i] + normals[i] * (o - h))
        }
        for point in right.reversed() { path.addLine(to: point.cg) }
        path.closeSubpath()
        return path
    }

    static func draw(_ pose: WhipPose, in cg: CGContext) {
        let points = pose.points
        let count = points.count
        var normals: [V2] = []
        normals.reserveCapacity(count)
        for i in 0..<count {
            let a = points[max(0, i - 1)], b = points[min(count - 1, i + 1)]
            normals.append((b - a).normalized.perpendicular)
        }
        let widths = (0..<count).map { thongWidth(Double($0) / Double(count - 1)) }
        let facing = normals.map { ($0.x * light.x + $0.y * light.y) }
        let full = 0..<count
        let body = strip(points, normals, range: full, offset: { _ in 0 }, half: { widths[$0] / 2 })

        cg.withState {
            cg.addPath(body); cg.setFillColor(Palette.leatherDeep.cg); cg.fillPath()
            cg.addPath(strip(points, normals, range: full, offset: { facing[$0] * widths[$0] * 0.08 }, half: { widths[$0] * 0.4 }))
            cg.setFillColor(Palette.leatherDark.cg); cg.fillPath()
            cg.addPath(strip(points, normals, range: full, offset: { facing[$0] * widths[$0] * 0.16 }, half: { widths[$0] * 0.24 }))
            cg.setFillColor(Palette.leather.cg); cg.fillPath()

            // A four-strand plait: alternating diagonals, sunk dark with a lit edge.
            cg.addPath(body)
            cg.clip()
            var travelled = 0.0, next = 0.0, flip = false
            for i in 1..<count {
                travelled += (points[i] - points[i - 1]).length
                let s = Double(i) / Double(count - 1)
                guard s < 0.8, travelled >= next else { continue }
                let w = widths[i], n = normals[i], tangent = V2(n.y, -n.x)
                let skew = tangent * (flip ? w * 0.42 : -w * 0.42)
                let a = points[i] + n * (w * 0.55) + skew, b = points[i] - n * (w * 0.55) - skew
                cg.line(a, b, Palette.leatherDeep.alpha(0.75), width: max(0.6, w * 0.17), cap: .butt)
                cg.line(a + tangent * (w * 0.13), b + tangent * (w * 0.13), Palette.leatherShine.alpha(0.2), width: max(0.4, w * 0.08), cap: .butt)
                next = travelled + max(2.2, w * 0.82)
                flip.toggle()
            }
            cg.resetClip()

            cg.addPath(strip(points, normals, range: full, offset: { facing[$0] * widths[$0] * 0.27 }, half: { widths[$0] * 0.07 }))
            cg.setFillColor(Palette.leatherShine.alpha(0.62).cg); cg.fillPath()
            // Cool rim light from the screens on the edges facing away from the key light.
            for side in [1.0, -1.0] {
                for i in 1..<count {
                    let away = max(0, -side * facing[i])
                    guard away > 0.05 else { continue }
                    let a = points[i - 1] + normals[i - 1] * side * widths[i - 1] * 0.42
                    let b = points[i] + normals[i] * side * widths[i] * 0.42
                    cg.line(a, b, Palette.cyan.alpha(0.55 * away), width: max(0.6, widths[i] * 0.12), cap: .butt)
                }
            }

            // The cracker frays into a few loose strands.
            let tip = points[count - 1], tangent = (points[count - 1] - points[count - 4]).normalized
            for angle in [-16.0, 3, 19] {
                let c = cos(degrees(angle)), s = sin(degrees(angle))
                let strand = V2(tangent.x * c - tangent.y * s, tangent.x * s + tangent.y * c)
                cg.line(tip, tip + strand * 9, RGBA(0xC9A57A, 0.8), width: 0.8)
            }
        }
        drawHandle(pose, in: cg)
    }

    private static func drawHandle(_ pose: WhipPose, in cg: CGContext) {
        let d = pose.direction
        let butt = pose.butt, ferrule = pose.ferrule
        let length = (ferrule - butt).length
        let angle = atan2(d.y, d.x)
        // Light in the handle's local frame decides which edge is lit.
        let localLight = V2(light.x * cos(-angle) - light.y * sin(-angle), light.x * sin(-angle) + light.y * cos(-angle))
        let litTop = localLight.y < 0
        cg.withState {
            cg.translateBy(x: butt.x, y: butt.y)
            cg.rotate(by: angle)
            let grip = CGRect(x: 0, y: -13, width: length, height: 26)
            cg.addPath(CGPath(roundedRect: grip, cornerWidth: 12, cornerHeight: 12, transform: nil))
            cg.clip()
            let stops: [RGBA] = litTop
                ? [Palette.leatherLight, Palette.leather, Palette.leatherDark, Palette.leatherDeep]
                : [Palette.leatherDeep, Palette.leatherDark, Palette.leather, Palette.leatherLight]
            let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: stops.map(\.cg) as CFArray,
                                      locations: [0, 0.35, 0.72, 1])!
            cg.drawLinearGradient(gradient, start: CGPoint(x: 0, y: -13), end: CGPoint(x: 0, y: 13), options: [])
            // Diamond plait on the grip.
            for x in stride(from: -24.0, through: length + 24, by: 9) {
                cg.line(V2(x, -13), V2(x + 22, 13), Palette.leatherDeep.alpha(0.55), width: 1.6, cap: .butt)
                cg.line(V2(x + 22, -13), V2(x, 13), Palette.leatherDeep.alpha(0.42), width: 1.3, cap: .butt)
                cg.line(V2(x + 1.5, -13), V2(x + 23.5, 13), Palette.leatherShine.alpha(0.16), width: 0.8, cap: .butt)
            }
            cg.fill(CGRect(x: 0, y: litTop ? -10 : 6, width: length, height: 3.4), Palette.leatherShine.alpha(0.4))
            cg.fill(CGRect(x: 0, y: litTop ? 10.5 : -12.5, width: length, height: 2), Palette.cyan.alpha(0.4))
            cg.resetClip()
            // Brass ferrule.
            let band = CGRect(x: length - 17, y: -13.5, width: 15, height: 27)
            cg.addPath(CGPath(roundedRect: band, cornerWidth: 3, cornerHeight: 3, transform: nil))
            cg.clip()
            let brass = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                   colors: (litTop ? [Palette.brassLight, Palette.brass, Palette.brassDark]
                                                   : [Palette.brassDark, Palette.brass, Palette.brassLight]).map(\.cg) as CFArray,
                                   locations: [0, 0.5, 1])!
            cg.drawLinearGradient(brass, start: CGPoint(x: 0, y: -13.5), end: CGPoint(x: 0, y: 13.5), options: [])
            cg.resetClip()
            cg.line(V2(length - 17, -13), V2(length - 17, 13), Palette.brassDark.alpha(0.8), width: 1.2, cap: .butt)
            cg.line(V2(length - 2, -13), V2(length - 2, 13), Palette.brassDark.alpha(0.8), width: 1.2, cap: .butt)
        }
        // Knob.
        let knob = butt - d * 4
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                  colors: [Palette.leatherShine.alpha(0.9), Palette.leather, Palette.leatherDeep].map(\.cg) as CFArray,
                                  locations: [0, 0.45, 1])!
        cg.withState {
            cg.addEllipse(in: CGRect(x: knob.x - 16, y: knob.y - 16, width: 32, height: 32))
            cg.clip()
            let highlight = knob + light * 7
            cg.drawRadialGradient(gradient, startCenter: highlight.cg, startRadius: 0, endCenter: knob.cg, endRadius: 17, options: [])
        }
        cg.ring(knob, 15.5, Palette.leatherDeep.alpha(0.7), width: 1.2)
    }
}
