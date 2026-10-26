import AppKit
import CoreGraphics

// The illustrated Codex terminal: a scrolling log, a working indicator and the input
// composer the whip types into. Nothing here reads a real session.

enum TerminalLayout {
    static let frame = CGRect(x: 120, y: 300, width: 1280, height: 660)
    static let titleHeight = 50.0
    static let logTop = 386.0
    static let logBottom = 826.0
    static let row = 40.0
    static let glyphX = 154.0
    static let textX = 186.0
    static let inputTop = 846.0
    static let inputBaseline = 920.0
    static let fontSize = 23.0
    static var body: TextStyle { TextStyle(font: Fonts.mono(fontSize), color: RGBA(0xD3DFEC)) }
    static var strong: TextStyle { TextStyle(font: Fonts.mono(fontSize, .medium), color: Palette.white) }

    /// The caret position after `words` words of the message, in stage space.
    static func caret(after words: Int, of message: [String]) -> V2 {
        let text = message.prefix(words).joined(separator: " ")
        return V2(textX + measure(text, strong), inputBaseline - 8)
    }
}

struct InputState {
    var text: String = ""
    var slam: [(range: Range<Int>, time: Double)] = []
    var sending: Double = 0
    var labelAlpha: Double = 0
}

final class Terminal {
    let film: Film
    let lines: [LogLine]
    let words: [String]

    init(film: Film) {
        self.film = film
        lines = film.log
        words = film.messageWords
    }

    private func height(of line: LogLine) -> Double {
        switch line.kind {
        case .user, .error, .warn, .success: return TerminalLayout.row + 14
        default: return TerminalLayout.row
        }
    }

    private func appear(_ start: Double, _ t: Double) -> Double { easeOut((t - start) / 0.3) }

    func isWorking(_ t: Double) -> (Bool, Double) {
        for (start, end) in film.working where t >= start && t < end + 0.25 {
            return (true, t < end ? smooth((t - start) / 0.3) : 1 - smooth((t - end) / 0.25))
        }
        return (false, 0)
    }

    // MARK: Input composer

    func input(_ t: Double) -> InputState {
        var state = InputState()
        let chunks = film.strikeChunks
        func full(at impact: Double, send: Double) -> InputState? {
            guard t >= impact - 0.0001, t < send + 0.45 else { return nil }
            var s = InputState()
            s.text = film.settings.message
            s.slam = [(0..<words.count, impact)]
            s.sending = clamp01((t - send) / 0.4)
            s.labelAlpha = presence(t, impact - 0.6, send + 0.3, fadeIn: 0.3, fadeOut: 0.3)
            return s
        }
        if t >= film.capacityStrikes[0] - 0.0001 && t < film.capacitySend + 0.45 {
            var revealed = 0
            for (index, impact) in film.capacityStrikes.enumerated() where t >= impact {
                state.slam.append(((index == 0 ? 0 : chunks[index - 1])..<chunks[index], impact))
                revealed = chunks[index]
            }
            state.text = words.prefix(revealed).joined(separator: " ")
            state.sending = clamp01((t - film.capacitySend) / 0.4)
            state.labelAlpha = presence(t, film.capacityStrikes[0] - 0.8, film.capacitySend + 0.3, fadeIn: 0.3, fadeOut: 0.3)
            return state
        }
        if let s = full(at: film.quotaStrike, send: film.quotaSend) { return s }
        if let s = full(at: film.resetStrike, send: film.resetSend) { return s }
        // Show the label just before the first strike arrives.
        state.labelAlpha = presence(t, film.capacityStrikes[0] - 0.8, film.capacityStrikes[0], fadeIn: 0.3, fadeOut: 0.01)
            + presence(t, film.quotaStrike - 0.6, film.quotaStrike, fadeIn: 0.3, fadeOut: 0.01)
            + presence(t, film.resetStrike - 0.6, film.resetStrike, fadeIn: 0.3, fadeOut: 0.01)
        return state
    }

    // MARK: Drawing

    func draw(_ cg: CGContext, t: Double, glitch: Double) {
        let frame = TerminalLayout.frame
        // Screen light spills around the window, then a deep drop shadow grounds it.
        cg.shadowed(blur: 120, offset: V2(0, 0), color: RGBA(0x2D8CFF, 0.34)) {
            cg.fill(frame, Palette.terminal, radius: 16)
        }
        cg.shadowed(blur: 60, offset: V2(0, 26), color: RGBA(0x000000, 0.55)) {
            cg.fill(frame, Palette.terminal.alpha(0.97), radius: 16)
        }
        let sheen = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                               colors: [RGBA(0x7FB8FF, 0.07).cg, RGBA(0x7FB8FF, 0).cg] as CFArray, locations: [0, 1])!
        cg.withState {
            cg.addPath(CGPath(roundedRect: frame, cornerWidth: 16, cornerHeight: 16, transform: nil))
            cg.clip()
            cg.drawLinearGradient(sheen, start: CGPoint(x: 0, y: frame.minY), end: CGPoint(x: 0, y: frame.minY + 380), options: [])
        }
        // Title bar.
        cg.withState {
            cg.addPath(CGPath(roundedRect: frame, cornerWidth: 16, cornerHeight: 16, transform: nil))
            cg.clip()
            cg.fill(CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: TerminalLayout.titleHeight), Palette.terminalBar)
            cg.line(V2(frame.minX, frame.minY + TerminalLayout.titleHeight), V2(frame.maxX, frame.minY + TerminalLayout.titleHeight),
                    RGBA(0x31445C, 0.8), width: 1, cap: .butt)
            cg.fill(CGRect(x: frame.minX, y: TerminalLayout.inputTop, width: frame.width, height: frame.maxY - TerminalLayout.inputTop),
                    Palette.terminalInput)
            cg.line(V2(frame.minX, TerminalLayout.inputTop), V2(frame.maxX, TerminalLayout.inputTop), RGBA(0x31445C, 0.9), width: 1, cap: .butt)
        }
        cg.strokeRounded(frame.insetBy(dx: 0.5, dy: 0.5), RGBA(0x3A5170, 0.55), radius: 16, width: 1)
        cg.strokeRounded(frame.insetBy(dx: 1.5, dy: 1.5), RGBA(0xFFFFFF, 0.05), radius: 15, width: 1)
        cg.withState {
            cg.clip(to: CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: 18))
            cg.strokeRounded(frame.insetBy(dx: 1.5, dy: 1.5), RGBA(0xFFFFFF, 0.16), radius: 15, width: 1)
        }
        for (index, color) in [RGBA(0xF0857B), RGBA(0xE7C06A), RGBA(0x79C79A)].enumerated() {
            cg.circle(V2(frame.minX + 30 + Double(index) * 24, frame.minY + 25), 7, fill: color)
        }
        let title = TextStyle(font: Fonts.text(17, .medium), color: Palette.secondary)
        let titleText = "palette · codex"
        drawText(titleText, x: frame.midX - measure(titleText, title) / 2, baseline: frame.minY + 31, title)
        let chipText = "Selected model"
        let chipStyle = TextStyle(font: Fonts.text(15, .medium), color: Palette.secondary)
        let chipWidth = measure(chipText, chipStyle) + 40
        let chip = CGRect(x: frame.maxX - chipWidth - 18, y: frame.minY + 11, width: chipWidth, height: 28)
        // The model chip lights up as each retry goes out on the same model.
        var kept = 0.0
        for send in [film.capacitySend, film.quotaSend, film.resetSend] where t >= send {
            kept = max(kept, exp(-(t - send) / 0.5))
        }
        cg.fill(chip, RGBA(0x1D2B3E).mixed(RGBA(0x1C4A5E), kept), radius: 14)
        if kept > 0.01 { cg.strokeRounded(chip, Palette.cyan.alpha(0.8 * kept), radius: 14, width: 1.5) }
        cg.circle(V2(chip.minX + 15, chip.midY), 4 + 1.5 * kept, fill: Palette.cyan)
        drawText(chipText, x: chip.minX + 27, baseline: chip.minY + 19.5, chipStyle.with(color: Palette.secondary.mixed(Palette.white, kept)))

        drawLog(cg, t: t, glitch: glitch)
        drawInput(cg, t: t)
        // A light sweep across the glass as the film opens.
        if t > 0.3 && t < 2.4 {
            let x = frame.minX - 500 + (frame.width + 1000) * easeInOut((t - 0.3) / 2.1)
            let band = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                  colors: [RGBA(0xBFE6FF, 0).cg, RGBA(0xBFE6FF, 0.09).cg, RGBA(0xBFE6FF, 0).cg] as CFArray,
                                  locations: [0, 0.5, 1])!
            cg.withState {
                cg.addPath(CGPath(roundedRect: frame, cornerWidth: 16, cornerHeight: 16, transform: nil))
                cg.clip()
                cg.drawLinearGradient(band, start: CGPoint(x: x - 260, y: frame.minY), end: CGPoint(x: x + 260, y: frame.minY + 300), options: [])
            }
        }
    }

    private func drawLog(_ cg: CGContext, t: Double, glitch: Double) {
        let visible = lines.filter { $0.time <= t }
        var offsets: [Double] = []
        var total = 0.0
        for line in visible {
            offsets.append(total)
            total += height(of: line) * (line.time < 0 ? 1 : appear(line.time, t))
        }
        let (working, workingAlpha) = isWorking(t)
        let indicatorHeight = working ? TerminalLayout.row * workingAlpha : 0
        let area = TerminalLayout.logBottom - TerminalLayout.logTop
        let scroll = max(0, total + indicatorHeight - area)
        cg.withState {
            cg.clip(to: CGRect(x: TerminalLayout.frame.minX, y: TerminalLayout.frame.minY + TerminalLayout.titleHeight + 4,
                               width: TerminalLayout.frame.width, height: TerminalLayout.logBottom - TerminalLayout.frame.minY - TerminalLayout.titleHeight + 10))
            for (index, line) in visible.enumerated() {
                let top = TerminalLayout.logTop + offsets[index] - scroll
                if top < TerminalLayout.logTop - 120 || top > TerminalLayout.logBottom + 20 { continue }
                let fade = line.time < 0 ? 1 : appear(line.time, t)
                cg.withState {
                    // A new line opens its own slot, so it never crosses the working indicator.
                    if fade < 1 { cg.clip(to: CGRect(x: TerminalLayout.frame.minX, y: top, width: TerminalLayout.frame.width, height: height(of: line) * fade)) }
                    cg.withAlpha(fade) {
                        drawLine(cg, line, top: top, t: t, glitch: line.kind == .error ? glitch : 0)
                    }
                }
            }
            if working {
                let top = TerminalLayout.logTop + total - scroll
                cg.withAlpha(workingAlpha) { drawWorking(cg, top: top, t: t) }
            }
        }
        // Soft fade where the log scrolls under the title bar.
        let fadeTop = TerminalLayout.frame.minY + TerminalLayout.titleHeight
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                  colors: [Palette.terminal.cg, Palette.terminal.alpha(0).cg] as CFArray, locations: [0, 1])!
        cg.withState {
            cg.clip(to: CGRect(x: TerminalLayout.frame.minX + 1, y: fadeTop + 1, width: TerminalLayout.frame.width - 2, height: 40))
            cg.drawLinearGradient(gradient, start: CGPoint(x: 0, y: fadeTop), end: CGPoint(x: 0, y: fadeTop + 40), options: [])
        }
    }

    private func drawLine(_ cg: CGContext, _ line: LogLine, top: Double, t: Double, glitch: Double) {
        let baseline = top + 28
        let count = line.typing > 0 ? Int(Double(line.text.count) * clamp01((t - line.time) / line.typing)) : line.text.count
        let text = String(line.text.prefix(count))
        switch line.kind {
        case .user:
            drawText("›", x: TerminalLayout.glyphX, baseline: baseline, TerminalLayout.strong.with(color: Palette.cyan))
            drawText(text, x: TerminalLayout.textX, baseline: baseline, TerminalLayout.strong)
        case .step:
            drawText("•", x: TerminalLayout.glyphX + 2, baseline: baseline, TerminalLayout.body.with(color: Palette.cyan.alpha(0.85)))
            drawText(text, x: TerminalLayout.textX, baseline: baseline, TerminalLayout.body)
        case .dim:
            drawText(text, x: TerminalLayout.textX, baseline: baseline, TerminalLayout.body.with(color: Palette.secondary))
        case .success:
            drawText("✓", x: TerminalLayout.glyphX, baseline: baseline, TerminalLayout.strong.with(color: Palette.green))
            drawText(text, x: TerminalLayout.textX, baseline: baseline, TerminalLayout.strong.with(color: Palette.green))
        case .error, .warn:
            let color = line.kind == .error ? Palette.red : Palette.amber
            let band = CGRect(x: TerminalLayout.frame.minX + 14, y: top + 2, width: TerminalLayout.frame.width - 28, height: 38)
            cg.fill(band, color.alpha(0.09), radius: 8)
            cg.fill(CGRect(x: TerminalLayout.glyphX, y: top + 9, width: 6, height: 24), color, radius: 3)
            if glitch > 0.001 {
                let frame = Int(t * 60)
                let jitter = (hashNoise(frame) - 0.5) * 18 * glitch
                drawText(text, x: TerminalLayout.textX + jitter - 4 * glitch, baseline: baseline,
                         TerminalLayout.strong.with(color: RGBA(0xFF3B5C, 0.55 * glitch)))
                drawText(text, x: TerminalLayout.textX + jitter + 4 * glitch, baseline: baseline,
                         TerminalLayout.strong.with(color: RGBA(0x37E6FF, 0.45 * glitch)))
                drawText(text, x: TerminalLayout.textX + jitter * 0.4, baseline: baseline, TerminalLayout.strong.with(color: color))
            } else {
                drawText(text, x: TerminalLayout.textX, baseline: baseline, TerminalLayout.strong.with(color: color))
            }
        }
    }

    private func drawWorking(_ cg: CGContext, top: Double, t: Double) {
        let baseline = top + 28
        let pulse = 0.55 + 0.45 * (0.5 + 0.5 * sin(t * 5))
        cg.circle(V2(TerminalLayout.glyphX + 7, baseline - 8), 5.5, fill: Palette.cyan.alpha(pulse))
        let style = TerminalLayout.body.with(color: Palette.secondary)
        let label = "Working"
        drawText(label, x: TerminalLayout.textX, baseline: baseline, style)
        // A shimmer travels across the label.
        let width = measure(label, style)
        let sweep = TerminalLayout.textX - 60 + (width + 120) * ((t * 0.7).truncatingRemainder(dividingBy: 1))
        cg.withState {
            cg.clip(to: CGRect(x: sweep - 40, y: top, width: 80, height: TerminalLayout.row))
            drawText(label, x: TerminalLayout.textX, baseline: baseline, style.with(color: Palette.ice))
        }
        let dots = Int(t * 3) % 4
        drawText(String(repeating: ".", count: dots), x: TerminalLayout.textX + width, baseline: baseline, style)
    }

    private func drawInput(_ cg: CGContext, t: Double) {
        let state = input(t)
        let labelStyle = TextStyle(font: Fonts.text(14.5, .semibold), color: Palette.tertiary, kern: 0.6)
        cg.withAlpha(clamp01(state.labelAlpha)) {
            drawText("WHIP’S RETRY MESSAGE", x: TerminalLayout.textX, baseline: TerminalLayout.inputTop + 26, labelStyle)
        }
        let baseline = TerminalLayout.inputBaseline
        let caretBlink = 0.5 + 0.5 * cos(t * .pi * 2)
        drawText("›", x: TerminalLayout.glyphX, baseline: baseline, TerminalLayout.strong.with(color: Palette.cyan))
        guard !state.text.isEmpty else {
            cg.fill(CGRect(x: TerminalLayout.textX, y: baseline - 22, width: 12, height: 27), Palette.cyan.alpha(0.35 + 0.5 * caretBlink), radius: 1.5)
            return
        }
        let sendLift = easeIn(state.sending, 2)
        cg.withAlpha(1 - smooth(state.sending * 1.4)) {
            var x = TerminalLayout.textX
            for (index, word) in words.enumerated() {
                guard let slam = state.slam.first(where: { $0.range.contains(index) }) else { break }
                let age = t - slam.time - Double(index - slam.range.lowerBound) * 0.035
                let width = measure(word, TerminalLayout.strong)
                if age >= 0 {
                    let pop = spring(age, frequency: 2.6, damping: 0.5)
                    let scale = 1.16 - 0.16 * pop
                    let center = V2(x + width / 2, baseline - 9 - sendLift * 58)
                    let flash = exp(-age / 0.12)
                    cg.withState {
                        cg.translateBy(x: center.x, y: center.y)
                        cg.scaleBy(x: scale, y: scale)
                        cg.translateBy(x: -center.x, y: -center.y)
                        cg.withAlpha(clamp01(age / 0.05)) {
                            drawText(word, x: x, baseline: baseline - sendLift * 58,
                                     TerminalLayout.strong.with(color: Palette.white.mixed(Palette.ice, flash)))
                        }
                    }
                }
                x += width + measure(" ", TerminalLayout.strong)
            }
            if state.sending == 0 {
                let caret = TerminalLayout.caret(after: state.text.split(separator: " ").count, of: words)
                cg.fill(CGRect(x: caret.x + 6, y: baseline - 22, width: 12, height: 27), Palette.cyan.alpha(0.4 + 0.45 * caretBlink), radius: 1.5)
            }
        }
        if state.sending > 0.3 {
            cg.fill(CGRect(x: TerminalLayout.textX, y: baseline - 22, width: 12, height: 27),
                    Palette.cyan.alpha((0.35 + 0.5 * caretBlink) * smooth((state.sending - 0.3) / 0.5)), radius: 1.5)
        }
    }
}
