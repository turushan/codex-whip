import AppKit
import CoreGraphics

// Kinetic captions and the logo lockup.

enum CaptionArt {
    static let left = 120.0
    static let firstBaseline = 196.0
    static let lineGap = 84.0
    static let headline = TextStyle(font: Fonts.display(74, .bold), color: Palette.white, kern: -1.6)
    static let subtitleStyle = TextStyle(font: Fonts.text(29), color: Palette.secondary, kern: -0.1)

    static func blur(_ caption: Caption, _ t: Double) -> Double {
        let entering = 1 - clamp01((t - caption.start) / 0.42)
        let leaving = clamp01((t - (caption.end - 0.3)) / 0.3)
        return 10 * max(entering, leaving)
    }

    static func draw(_ cg: CGContext, _ caption: Caption, _ t: Double) {
        guard t >= caption.start, t <= caption.end else { return }
        var index = 0
        var baseline = firstBaseline
        for (lineIndex, line) in caption.lines.enumerated() {
            let delay = lineIndex < caption.lineDelays.count ? caption.lineDelays[lineIndex] : Double(lineIndex) * 0.18
            var x = left
            for (text, color) in line {
                let words = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
                for (wordIndex, word) in words.enumerated() {
                    let style = headline.with(color: color)
                    let space = wordIndex < words.count - 1 ? measure(" ", style) : 0
                    defer { x += measure(word, style) + space }
                    if word.isEmpty { continue }
                    let enter = caption.start + delay + Double(index) * 0.055
                    let leave = caption.end - 0.32 + Double(index) * 0.018
                    index += 1
                    guard t >= enter else { continue }
                    let rise = 1 - spring(t - enter, frequency: 1.9, damping: 0.72)
                    let exit = smooth((t - leave) / 0.3)
                    let alpha = clamp01((t - enter) / 0.22) * (1 - exit)
                    cg.withAlpha(alpha) {
                        drawText(word, x: x, baseline: baseline + rise * 40 - exit * 22, style)
                    }
                }
            }
            baseline += lineGap
        }
        if let subtitle = caption.subtitle {
            let lastDelay = caption.lineDelays.last ?? 0
            let enter = caption.start + lastDelay + 0.28
            guard t >= enter else { return }
            let rise = 1 - spring(t - enter, frequency: 1.6, damping: 0.8)
            let exit = smooth((t - (caption.end - 0.3)) / 0.3)
            cg.withAlpha(clamp01((t - enter) / 0.3) * (1 - exit)) {
                drawText(subtitle, x: left + 2, baseline: baseline - lineGap + 54 + rise * 18 - exit * 14, subtitleStyle)
            }
        }
    }

}

/// Draws a CGImage upright inside a y-down context.
func drawImage(_ cg: CGContext, _ image: CGImage, in rect: CGRect) {
    cg.withState {
        cg.translateBy(x: rect.minX, y: rect.maxY)
        cg.scaleBy(x: 1, y: -1)
        cg.draw(image, in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
    }
}

enum Lockup {
    enum Variant { case reveal, outro }

    struct Art {
        let icon: CGImage
        let iconMask: CGImage
    }

    /// Blueprint construction lines behind the icon, drawn progressively.
    static func blueprint(_ cg: CGContext, center: V2, t: Double, start: Double, alpha: Double) {
        let p = easeOut((t - start) / 0.9, 3)
        guard p > 0, alpha > 0.001 else { return }
        let ink = Palette.cyan.alpha(0.24 * alpha)
        // Construction arcs stay above the centerline, clear of the wordmark below.
        cg.setStrokeColor(ink.cg)
        cg.setLineWidth(1.3)
        cg.addArc(center: center.cg, radius: 196, startAngle: .pi, endAngle: .pi + .pi * p, clockwise: false)
        cg.strokePath()
        cg.withState {
            cg.setLineDash(phase: CGFloat(t * 18), lengths: [6, 9])
            cg.setStrokeColor(Palette.cyan.alpha(0.16 * alpha).cg)
            cg.addArc(center: center.cg, radius: 262, startAngle: 2 * .pi, endAngle: 2 * .pi - .pi * p, clockwise: true)
            cg.strokePath()
        }
        let reach = 520 * p
        cg.line(center - V2(reach, 0), center + V2(reach, 0), ink, width: 1)
        cg.line(center - V2(0, 300 * p), center, ink, width: 1)
        for k in stride(from: -12.0, through: 12, by: 1) where abs(k) * 42 < reach {
            let x = center.x + k * 42
            cg.line(V2(x, center.y - (k.truncatingRemainder(dividingBy: 4) == 0 ? 9 : 5)), V2(x, center.y + 5), ink, width: 1)
        }
        let label = TextStyle(font: Fonts.mono(13, .medium), color: Palette.cyan.alpha(0.34 * alpha * p))
        drawText("R 196", x: center.x + 142, baseline: center.y - 142, label)
        drawText("1024 × 1024", x: center.x - 512 * p + 6, baseline: center.y - 12, label)
    }

    static func icon(_ cg: CGContext, _ art: Art, center: V2, size: Double, rotation: Double, sweep: Double) {
        let rect = CGRect(x: -size / 2, y: -size / 2, width: size, height: size)
        cg.withState {
            cg.translateBy(x: center.x, y: center.y)
            cg.rotate(by: degrees(rotation))
            cg.shadowed(blur: size * 0.16, offset: V2(0, size * 0.07), color: RGBA(0x000000, 0.5)) {
                drawImage(cg, art.icon, in: rect)
            }
            if sweep > 0 && sweep < 1 {
                cg.withState {
                    cg.translateBy(x: rect.minX, y: rect.maxY)
                    cg.scaleBy(x: 1, y: -1)
                    cg.clip(to: CGRect(x: 0, y: 0, width: size, height: size), mask: art.iconMask)
                    cg.scaleBy(x: 1, y: -1)
                    cg.translateBy(x: 0, y: -size)
                    let x = -size * 0.6 + size * 2.2 * sweep
                    let band = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                          colors: [RGBA(0xFFFFFF, 0).cg, RGBA(0xFFFFFF, 0.38).cg, RGBA(0xFFFFFF, 0).cg] as CFArray,
                                          locations: [0, 0.5, 1])!
                    cg.drawLinearGradient(band, start: CGPoint(x: x - size * 0.25, y: 0), end: CGPoint(x: x + size * 0.25, y: size * 0.35),
                                          options: [])
                }
            }
        }
    }

    static func wordmark(_ cg: CGContext, centerX: Double, baseline: Double, size: Double, reveal: Double) {
        let style = TextStyle(font: Fonts.display(size, .bold), color: Palette.white, kern: -size * 0.024)
        let text = "Codex Whip"
        let width = measure(text, style)
        let x = centerX - width / 2
        cg.withState {
            cg.clip(to: CGRect(x: x - 10, y: baseline - size * 1.1, width: (width + 20) * easeOut(reveal, 3), height: size * 1.5))
            drawText(text, x: x, baseline: baseline + (1 - easeOut(reveal)) * 12, style)
        }
    }
}
