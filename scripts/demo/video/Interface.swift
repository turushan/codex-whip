import AppKit
import CoreGraphics

// Interface elements. The menu bar glyph, menu titles, interval choices and Activity
// labels mirror native/MenuBarIcon.swift, native/App.swift and native/Settings.swift.

enum MenuBarIcon {
    /// The 18-point template glyph from the app, in a y-down 18 × 18 box.
    static let lash: CGPath = {
        let p = CGMutablePath()
        func pt(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x, y: 18 - y) }
        p.move(to: pt(9.70, 8.56))
        p.addCurve(to: pt(11.31, 11.98), control1: pt(10.90, 10.05), control2: pt(11.90, 10.50))
        p.addCurve(to: pt(7.32, 14.99), control1: pt(11.00, 14.00), control2: pt(9.35, 15.38))
        p.addCurve(to: pt(2.90, 10.67), control1: pt(4.30, 14.80), control2: pt(2.65, 12.95))
        p.addCurve(to: pt(4.62, 7.33), control1: pt(2.75, 8.95), control2: pt(3.05, 7.80))
        p.addCurve(to: pt(9.11, 5.58), control1: pt(6.30, 6.83), control2: pt(8.20, 6.80))
        p.addCurve(to: pt(9.90, 3.60), control1: pt(9.65, 4.90), control2: pt(9.90, 4.10))
        p.addCurve(to: pt(9.50, 3.60), control1: pt(9.90, 3.38), control2: pt(9.50, 3.38))
        p.addCurve(to: pt(8.69, 5.22), control1: pt(9.50, 4.05), control2: pt(9.25, 4.60))
        p.addCurve(to: pt(4.38, 6.47), control1: pt(7.90, 6.15), control2: pt(6.10, 5.99))
        p.addCurve(to: pt(1.70, 10.53), control1: pt(2.30, 7.00), control2: pt(1.50, 8.30))
        p.addCurve(to: pt(7.08, 16.41), control1: pt(1.40, 13.40), control2: pt(3.90, 16.05))
        p.addCurve(to: pt(12.89, 12.62), control1: pt(9.70, 16.95), control2: pt(12.40, 15.60))
        p.addCurve(to: pt(11.10, 7.44), control1: pt(13.60, 10.90), control2: pt(12.00, 8.60))
        p.closeSubpath()
        return p
    }()

    static func draw(_ cg: CGContext, center: V2, size: Double, color: RGBA) {
        cg.withState {
            cg.translateBy(x: center.x - size / 2, y: center.y - size / 2)
            cg.scaleBy(x: size / 18, y: size / 18)
            cg.addPath(lash)
            cg.setFillColor(color.cg)
            cg.fillPath()
            cg.setStrokeColor(color.cg)
            cg.setLineWidth(2.6)
            cg.setLineCap(.round)
            cg.move(to: CGPoint(x: 15.1, y: 18 - 2.6))
            cg.addLine(to: CGPoint(x: 10.4, y: 18 - 8.0))
            cg.strokePath()
        }
    }
}

enum MenuBar {
    static let height = 34.0
    static let clockStyle = TextStyle(font: Fonts.text(15.5, .medium), color: RGBA(0xEAF1FA))
    static func clockString(_ minutes: Double) -> String { "Tue " + clockText(minutes) }
    static func glyphCenter() -> V2 {
        let width = measure(clockString(8 * 60 + 58), clockStyle)
        return V2(1920 - 26 - width - 36, height / 2)
    }

    static func draw(_ cg: CGContext, minutes: Double, glyph: Double, glyphGlow: Double, highlight: Double) {
        cg.fill(CGRect(x: 0, y: 0, width: 1920, height: height), RGBA(0x0A1524, 0.74))
        cg.line(V2(0, height - 0.5), V2(1920, height - 0.5), RGBA(0xFFFFFF, 0.07), width: 1, cap: .butt)
        let bold = TextStyle(font: Fonts.text(15.5, .bold), color: RGBA(0xEAF1FA))
        let regular = TextStyle(font: Fonts.text(15.5, .regular), color: RGBA(0xEAF1FA, 0.82))
        var x = 26.0
        drawText("Terminal", x: x, baseline: 23, bold)
        x += measure("Terminal", bold) + 26
        for item in ["Shell", "Edit", "View", "Window", "Help"] {
            drawText(item, x: x, baseline: 23, regular)
            x += measure(item, regular) + 24
        }
        let clock = clockString(minutes)
        drawText(clock, x: 1920 - 26 - measure(clock, clockStyle), baseline: 23, clockStyle)
        let center = glyphCenter()
        if highlight > 0.001 {
            cg.fill(CGRect(x: center.x - 18, y: 4, width: 36, height: 26), RGBA(0xFFFFFF, 0.2 * highlight), radius: 7)
        }
        if glyph > 0.001 {
            cg.withAlpha(glyph) {
                MenuBarIcon.draw(cg, center: center, size: 22, color: RGBA(0xEAF1FA).mixed(Palette.ice, glyphGlow))
            }
        }
    }
}

// MARK: Whip timeline column

struct TimelineRow {
    enum Mark { case error, warn, pending, check, sent }
    let time: Double
    let clock: String
    let label: String
    let detail: String?
    let mark: Mark
    var countdown: (start: Double, end: Double, total: Int)? = nil
}

enum TimelineColumn {
    static let x = 1440.0, top = 316.0, width = 400.0, firstRow = 60.0

    static func rowHeight(_ row: TimelineRow) -> Double {
        row.countdown != nil ? 116 : (row.detail != nil ? 100 : 72)
    }

    static func draw(_ cg: CGContext, rows: [TimelineRow], t: Double, alpha: Double) {
        guard alpha > 0.001 else { return }
        cg.withAlpha(alpha) {
            let header = TextStyle(font: Fonts.text(16.5, .semibold), color: Palette.secondary, kern: 1.6)
            MenuBarIcon.draw(cg, center: V2(x + 12, top + 9), size: 21, color: Palette.secondary)
            drawText("CODEX WHIP", x: x + 36, baseline: top + 15, header)
            var y = top + firstRow
            let visible = rows.filter { t >= $0.time }
            for (index, row) in visible.enumerated() {
                let age = t - row.time
                let enter = spring(age, frequency: 1.8, damping: 0.75)
                let height = rowHeight(row)
                cg.withAlpha(clamp01(age / 0.25)) {
                    cg.withState {
                        cg.translateBy(x: (1 - enter) * 44, y: 0)
                        drawRow(cg, row, y: y, t: t)
                    }
                }
                if index < visible.count - 1 {
                    cg.line(V2(x + 12, y + 30), V2(x + 12, y + height - 8), RGBA(0x5DBBEE, 0.24), width: 2)
                }
                y += height * clamp01(enter * 1.2)
            }
        }
    }

    static func color(_ mark: TimelineRow.Mark) -> RGBA {
        switch mark {
        case .error: return Palette.red
        case .warn: return Palette.amber
        case .pending: return Palette.secondary
        case .check: return Palette.green
        case .sent: return Palette.cyan
        }
    }

    private static func drawRow(_ cg: CGContext, _ row: TimelineRow, y: Double, t: Double) {
        let tint = color(row.mark)
        let dot = V2(x + 12, y + 14)
        switch row.mark {
        case .error, .warn:
            cg.circle(dot, 8, fill: tint)
        case .pending:
            cg.ring(dot, 8, tint, width: 2.4)
        case .check, .sent:
            cg.circle(dot, 12, fill: tint)
            cg.setStrokeColor(Palette.ink.cg); cg.setLineWidth(2.8); cg.setLineCap(.round); cg.setLineJoin(.round)
            cg.move(to: (dot + V2(-5.4, 0.6)).cg); cg.addLine(to: (dot + V2(-1.4, 4.6)).cg); cg.addLine(to: (dot + V2(5.8, -4.3)).cg)
            cg.strokePath()
        }
        let age = t - row.time
        if age < 1.1 {
            let p = age / 1.1
            cg.ring(dot, 12 + 30 * easeOut(p), tint.alpha(0.6 * (1 - p)), width: 2.2)
        }
        let timeStyle = TextStyle(font: Fonts.mono(17.5, .medium), color: Palette.tertiary)
        drawText(row.clock, x: x + 42, baseline: y + 4, timeStyle)
        let labelStyle = TextStyle(font: Fonts.text(26, .semibold), color: Palette.white, kern: -0.2)
        drawText(row.label, x: x + 42, baseline: y + 36, labelStyle)
        if let detail = row.detail {
            drawText(detail, x: x + 42, baseline: y + 66, TextStyle(font: Fonts.text(20), color: Palette.secondary))
        }
        if let countdown = row.countdown {
            let u = clamp01((t - countdown.start) / (countdown.end - countdown.start))
            let remaining = Double(countdown.total) * (1 - u)
            let text = String(format: "%d:%02d", Int(remaining) / 60, Int(remaining) % 60)
            let ringCenter = V2(x + 352, y + 46)
            cg.ring(ringCenter, 30, RGBA(0x5DBBEE, 0.2), width: 5)
            cg.arc(ringCenter, 30, fraction: 1 - u, Palette.cyan, width: 5)
            let mono = TextStyle(font: Fonts.mono(34, .semibold), color: Palette.white)
            drawText(text, x: x + 42, baseline: y + 78, mono)
            drawText("time compressed", x: x + 42 + measure(text, mono) + 14, baseline: y + 75,
                     TextStyle(font: Fonts.text(16.5, .medium), color: Palette.tertiary))
        }
    }
}

// MARK: Recreated post

enum PostCard {
    static func draw(_ cg: CGContext, at origin: V2, avatar: CGImage) {
        let card = CGRect(x: origin.x, y: origin.y, width: 600, height: 206)
        cg.shadowed(blur: 44, offset: V2(0, 22), color: RGBA(0x000000, 0.5)) {
            cg.fill(card, RGBA(0x14263A), radius: 22)
        }
        cg.strokeRounded(card.insetBy(dx: 0.5, dy: 0.5), RGBA(0x4F7393, 0.55), radius: 22, width: 1)
        let avatarRect = CGRect(x: card.minX + 26, y: card.minY + 24, width: 60, height: 60)
        cg.withState {
            cg.addEllipse(in: avatarRect)
            cg.clip()
            drawImage(cg, avatar, in: avatarRect)
        }
        let name = TextStyle(font: Fonts.text(23, .bold), color: Palette.white)
        drawText("Tibo", x: card.minX + 102, baseline: card.minY + 48, name)
        drawText("@thsottiaux", x: card.minX + 102, baseline: card.minY + 76, TextStyle(font: Fonts.text(18), color: Palette.secondary))
        drawText("Reset all propagated. Enjoy.", x: card.minX + 28, baseline: card.minY + 140,
                 TextStyle(font: Fonts.text(31, .medium), color: Palette.white))
        let pill = TextStyle(font: Fonts.text(14, .semibold), color: Palette.amber, kern: 0.5)
        let label = "RECREATED FROM X"
        let pillRect = CGRect(x: card.minX + 28, y: card.minY + 162, width: measure(label, pill) + 22, height: 26)
        cg.fill(pillRect, Palette.amber.alpha(0.12), radius: 13)
        drawText(label, x: pillRect.minX + 11, baseline: pillRect.minY + 18, pill)
    }
}

// MARK: Activity window

enum ActivityWindow {
    static let frame = CGRect(x: 690, y: 296, width: 760, height: 672)

    /// The native Activity report (native/App.swift), with illustrative counts and session ID. It opens
    /// on the night's totals, as the app's report does.
    static func draw(_ cg: CGContext, recent: [(clock: Double, label: String)]) {
        let f = frame
        cg.shadowed(blur: 60, offset: V2(0, 28), color: RGBA(0x000000, 0.55)) {
            cg.fill(f, RGBA(0x1E1E20), radius: 16)
        }
        cg.strokeRounded(f.insetBy(dx: 0.5, dy: 0.5), RGBA(0xFFFFFF, 0.13), radius: 16, width: 1)
        cg.withState {
            cg.addPath(CGPath(roundedRect: f, cornerWidth: 16, cornerHeight: 16, transform: nil))
            cg.clip()
            cg.fill(CGRect(x: f.minX, y: f.minY, width: f.width, height: 46), RGBA(0x2B2B2E))
        }
        for (index, color) in [RGBA(0xFF5F57), RGBA(0xFEBC2E), RGBA(0x28C840)].enumerated() {
            cg.circle(V2(f.minX + 24 + Double(index) * 22, f.minY + 23), 7, fill: color)
        }
        let title = TextStyle(font: Fonts.text(16.5, .semibold), color: RGBA(0xE6E6E8, 0.85))
        drawText("Codex Whip Activity", x: f.midX - measure("Codex Whip Activity", title) / 2, baseline: f.minY + 29, title)
        let body = TextStyle(font: Fonts.text(20), color: RGBA(0xF2F2F4))
        let head = TextStyle(font: Fonts.text(20, .semibold), color: RGBA(0xFFFFFF))
        let dim = TextStyle(font: Fonts.text(18), color: RGBA(0xA9A9AE))
        var lines: [(String, TextStyle)] = [
            ("Last 24 hours", head), ("", body),
            ("Capacity", head),
            ("Errors found: 1 · Retries sent: 1", body),
            ("Successful: 1 · Failed: 0 (0 capacity, 0 other)", body),
            ("Interrupted: 0 · Awaiting recovery: 0", body),
            ("Uncertain sends: 0", body), ("", body),
            ("Quota recovery", head),
            ("Limits found: 2 · Retries sent: 2", body),
            ("Successful: 2 · Failed: 0 (0 capacity, 0 other)", body),
            ("Interrupted: 0 · Awaiting recovery: 0", body),
            ("Uncertain sends: 0", body), ("", body),
            ("Success: 2 minutes without interruption, or a finished turn.", dim), ("", body),
            ("Recent activity", head),
        ]
        lines += recent.map { ("Oct 27, 2026 at \(clockText($0.clock)) · 7f3a91c2 · \($0.label)", dim) }
        var y = f.minY + 84
        for (text, style) in lines {
            if !text.isEmpty { drawText(text, x: f.minX + 32, baseline: y, style) }
            y += text.isEmpty ? 10 : 27.5
        }
    }
}

// MARK: Native menu

struct MenuItem {
    var title: String
    var enabled = true
    var checked = false
    var submenu = false
    var key: String? = nil
    var separator = false
    static let line = MenuItem(title: "", separator: true)
}

enum MenuArt {
    static let scale = 1.6
    static var font: NSFont { Fonts.text(13 * scale) }
    static var rowHeight: Double { 22 * scale }
    static var separatorHeight: Double { 11 * scale }

    static func height(_ items: [MenuItem]) -> Double {
        items.reduce(10 * scale) { $0 + ($1.separator ? separatorHeight : rowHeight) }
    }

    static func rowTop(_ items: [MenuItem], _ index: Int, origin: V2) -> Double {
        var y = origin.y + 5 * scale
        for item in items.prefix(index) { y += item.separator ? separatorHeight : rowHeight }
        return y
    }

    static func draw(_ cg: CGContext, _ items: [MenuItem], origin: V2, width: Double, hover: Int?, reveal: Double) {
        let h = height(items)
        let rect = CGRect(x: origin.x, y: origin.y, width: width, height: h * reveal)
        cg.shadowed(blur: 36, offset: V2(0, 16), color: RGBA(0x000000, 0.5)) {
            cg.fill(rect, RGBA(0x2A2C31, 0.97), radius: 12)
        }
        cg.strokeRounded(rect.insetBy(dx: 0.5, dy: 0.5), RGBA(0xFFFFFF, 0.14), radius: 12, width: 1)
        cg.withState {
            cg.addPath(CGPath(roundedRect: rect, cornerWidth: 12, cornerHeight: 12, transform: nil))
            cg.clip()
            var y = origin.y + 5 * scale
            for (index, item) in items.enumerated() {
                if item.separator {
                    cg.line(V2(origin.x + 14 * scale, y + separatorHeight / 2), V2(origin.x + width - 14 * scale, y + separatorHeight / 2),
                            RGBA(0xFFFFFF, 0.13), width: 1, cap: .butt)
                    y += separatorHeight
                    continue
                }
                let hovered = hover == index
                if hovered {
                    cg.fill(CGRect(x: origin.x + 5 * scale, y: y, width: width - 10 * scale, height: rowHeight), RGBA(0x2F7CF6), radius: 6 * scale)
                }
                let color = hovered ? Palette.white : (item.enabled ? RGBA(0xEDEDF0) : RGBA(0x8B8C92))
                let style = TextStyle(font: font, color: color)
                let baseline = y + rowHeight * 0.69
                if item.checked { drawText("✓", x: origin.x + 9 * scale, baseline: baseline, style) }
                drawText(item.title, x: origin.x + 25 * scale, baseline: baseline, style)
                if item.submenu {
                    drawText("›", x: origin.x + width - 20 * scale, baseline: baseline,
                             TextStyle(font: Fonts.text(15 * scale, .medium), color: color))
                }
                if let key = item.key {
                    let keyStyle = TextStyle(font: font, color: hovered ? Palette.white : RGBA(0x8B8C92))
                    drawText(key, x: origin.x + width - 14 * scale - measure(key, keyStyle), baseline: baseline, keyStyle)
                }
                y += rowHeight
            }
        }
    }
}

enum Cursor {
    /// The classic macOS arrow, drawn as vectors so no system image is needed.
    static func draw(_ cg: CGContext, at point: V2, scale: Double) {
        let points: [(Double, Double)] = [(0, 0), (0, 22.5), (5.4, 17.4), (9.1, 26.2), (12.6, 24.7), (8.9, 16.2), (16, 16.2)]
        let s = 1.5 * scale
        let path = CGMutablePath()
        path.move(to: CGPoint(x: point.x + points[0].0 * s, y: point.y + points[0].1 * s))
        for p in points.dropFirst() { path.addLine(to: CGPoint(x: point.x + p.0 * s, y: point.y + p.1 * s)) }
        path.closeSubpath()
        cg.shadowed(blur: 8, offset: V2(0, 4), color: RGBA(0x000000, 0.4)) {
            cg.addPath(path)
            cg.setFillColor(RGBA(0x000000).cg)
            cg.fillPath()
        }
        cg.addPath(path)
        cg.setStrokeColor(RGBA(0xFFFFFF).cg)
        cg.setLineWidth(1.6 * s)
        cg.setLineJoin(.round)
        cg.strokePath()
        cg.addPath(path)
        cg.setFillColor(RGBA(0x000000).cg)
        cg.fillPath()
    }
}
