import AppKit
import CoreGraphics

// Shared math, easing, palette, type and drawing helpers. Stage drawing uses a
// y-down coordinate space on a 1920 × 1080 design canvas.

typealias V2 = SIMD2<Double>

extension SIMD2 where Scalar == Double {
    var cg: CGPoint { CGPoint(x: x, y: y) }
    var length: Double { (x * x + y * y).squareRoot() }
    var normalized: V2 { let l = length; return l > 1e-9 ? self / l : V2(1, 0) }
    var perpendicular: V2 { V2(-y, x) }
}

func clamp01(_ x: Double) -> Double { max(0, min(1, x)) }
func clamp(_ x: Double, _ lower: Double, _ upper: Double) -> Double { max(lower, min(upper, x)) }
func mix(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
func mix(_ a: V2, _ b: V2, _ t: Double) -> V2 { a + (b - a) * t }
func progress(_ t: Double, _ start: Double, _ duration: Double) -> Double { clamp01((t - start) / duration) }
func smooth(_ x: Double) -> Double { let t = clamp01(x); return t * t * (3 - 2 * t) }
func smoother(_ x: Double) -> Double { let t = clamp01(x); return t * t * t * (t * (t * 6 - 15) + 10) }
func easeOut(_ x: Double, _ power: Double = 3) -> Double { 1 - pow(1 - clamp01(x), power) }
func easeIn(_ x: Double, _ power: Double = 3) -> Double { pow(clamp01(x), power) }
func easeInOut(_ x: Double) -> Double {
    let t = clamp01(x)
    return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
}
func degrees(_ value: Double) -> Double { value * .pi / 180 }
func direction(_ angleDegrees: Double) -> V2 { V2(cos(degrees(angleDegrees)), sin(degrees(angleDegrees))) }

/// Underdamped spring step response from 0 to 1, starting at `t = 0`.
func spring(_ t: Double, frequency: Double = 1.6, damping: Double = 0.62) -> Double {
    guard t > 0 else { return 0 }
    let omega = 2 * .pi * frequency
    let damped = omega * (1 - damping * damping).squareRoot()
    let decay = exp(-damping * omega * t)
    return 1 - decay * (cos(damped * t) + damping * omega / damped * sin(damped * t))
}

/// 0 → 1 → 0 presence across an interval with eased edges.
func presence(_ t: Double, _ start: Double, _ end: Double, fadeIn: Double = 0.35, fadeOut: Double = 0.35) -> Double {
    if t < start || t > end { return 0 }
    return smooth((t - start) / fadeIn) * (1 - smooth((t - (end - fadeOut)) / fadeOut))
}

/// Deterministic hash noise in 0...1.
func hashNoise(_ n: Int) -> Double {
    var x = UInt64(bitPattern: Int64(n)) &* 0x9E3779B97F4A7C15
    x ^= x >> 30; x &*= 0xBF58476D1CE4E5B9
    x ^= x >> 27; x &*= 0x94D049BB133111EB
    x ^= x >> 31
    return Double(x >> 11) / Double(1 << 53)
}

struct RGBA {
    var r, g, b, a: Double
    init(_ hex: UInt32, _ alpha: Double = 1) {
        r = Double((hex >> 16) & 255) / 255
        g = Double((hex >> 8) & 255) / 255
        b = Double(hex & 255) / 255
        a = alpha
    }
    init(r: Double, g: Double, b: Double, a: Double) { self.r = r; self.g = g; self.b = b; self.a = a }
    func alpha(_ value: Double) -> RGBA { RGBA(r: r, g: g, b: b, a: a * value) }
    func mixed(_ other: RGBA, _ t: Double) -> RGBA {
        RGBA(r: mix(r, other.r, t), g: mix(g, other.g, t), b: mix(b, other.b, t), a: mix(a, other.a, t))
    }
    var cg: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
    var ns: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }
}

enum Palette {
    static let ink = RGBA(0x050B14)
    static let night = RGBA(0x081525)
    static let navy = RGBA(0x0C2140)
    static let white = RGBA(0xF2F7FF)
    static let secondary = RGBA(0x9DB1C8)
    static let tertiary = RGBA(0x62788F)
    static let cyan = RGBA(0x5FD8F2)
    static let ice = RGBA(0xB8F3FF)
    static let blue = RGBA(0x2F8CFF)
    static let red = RGBA(0xFF8B7B)
    static let amber = RGBA(0xF5C46B)
    static let green = RGBA(0x80E2B2)
    static let grid = RGBA(0x5DBBEE)
    static let leatherDeep = RGBA(0x3A190C)
    static let leatherDark = RGBA(0x683016)
    static let leather = RGBA(0x924F28)
    static let leatherLight = RGBA(0xC2773F)
    static let leatherShine = RGBA(0xF6C38D)
    static let brassDark = RGBA(0x6E4E1F)
    static let brass = RGBA(0xC09452)
    static let brassLight = RGBA(0xF6DEA3)
    static let terminal = RGBA(0x0A111C)
    static let terminalBar = RGBA(0x131E2D)
    static let terminalInput = RGBA(0x0E1926)
    static let border = RGBA(0x2B3D54)
    static let menu = RGBA(0x262A31)
}

enum Fonts {
    static func display(_ size: Double, _ weight: NSFont.Weight = .bold) -> NSFont {
        NSFont.systemFont(ofSize: size, weight: weight)
    }
    static func text(_ size: Double, _ weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.systemFont(ofSize: size, weight: weight)
    }
    static func mono(_ size: Double, _ weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: size, weight: weight)
    }
}

/// A y-down bitmap canvas with AppKit text drawing.
final class Canvas {
    let width: Int, height: Int
    let context: CGContext
    let graphics: NSGraphicsContext

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.setShouldSmoothFonts(false)
        context.setAllowsFontSmoothing(false)
        context.interpolationQuality = .high
        graphics = NSGraphicsContext(cgContext: context, flipped: true)
    }

    func clear() {
        context.saveGState()
        context.resetClip()
        context.setBlendMode(.copy)
        context.setFillColor(CGColor(gray: 0, alpha: 0))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.restoreGState()
    }

    func image() -> CGImage { context.makeImage()! }

    /// Runs drawing with this canvas as the current AppKit context.
    func draw(_ body: (CGContext) -> Void) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        context.saveGState()
        body(context)
        context.restoreGState()
        NSGraphicsContext.restoreGraphicsState()
    }
}

extension CGContext {
    func fill(_ rect: CGRect, _ color: RGBA, radius: Double = 0) {
        setFillColor(color.cg)
        if radius > 0 {
            addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
            fillPath()
        } else {
            fill(rect)
        }
    }

    func strokeRounded(_ rect: CGRect, _ color: RGBA, radius: Double, width: Double = 1) {
        setStrokeColor(color.cg)
        setLineWidth(width)
        addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        strokePath()
    }

    func line(_ a: V2, _ b: V2, _ color: RGBA, width: Double = 1, cap: CGLineCap = .round) {
        setStrokeColor(color.cg)
        setLineWidth(width)
        setLineCap(cap)
        move(to: a.cg)
        addLine(to: b.cg)
        strokePath()
    }

    func circle(_ center: V2, _ radius: Double, fill color: RGBA) {
        setFillColor(color.cg)
        fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    }

    func ring(_ center: V2, _ radius: Double, _ color: RGBA, width: Double) {
        setStrokeColor(color.cg)
        setLineWidth(width)
        strokeEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    }

    /// An arc that starts at 12 o'clock and runs clockwise for `fraction` of a turn.
    func arc(_ center: V2, _ radius: Double, fraction: Double, _ color: RGBA, width: Double) {
        guard fraction > 0.0005 else { return }
        setStrokeColor(color.cg)
        setLineWidth(width)
        setLineCap(.round)
        addArc(center: center.cg, radius: radius, startAngle: -.pi / 2, endAngle: -.pi / 2 + 2 * .pi * min(1, fraction), clockwise: false)
        strokePath()
    }

    /// Fades drawing by multiplying the opacity of any enclosing fade.
    func withAlpha(_ value: Double, _ body: () -> Void) {
        guard value > 0.001 else { return }
        let combined = alphaStack.last! * min(1, value)
        saveGState()
        setAlpha(combined)
        alphaStack.append(combined)
        body()
        alphaStack.removeLast()
        restoreGState()
    }

    func withState(_ body: () -> Void) {
        saveGState()
        body()
        restoreGState()
    }

    /// Applies a shadow to the drawing operations in `body`. Each operation casts its own shadow.
    func shadowed(blur: Double, offset: V2 = V2(0, 0), color: RGBA, _ body: () -> Void) {
        saveGState()
        // Shadow offsets are specified in base space, which stays y-up.
        setShadow(offset: CGSize(width: offset.x, height: -offset.y), blur: blur, color: color.cg)
        body()
        restoreGState()
    }
}

/// CGContext.setAlpha replaces rather than multiplies, so nested fades track their product here.
var alphaStack: [Double] = [1]

struct TextStyle {
    var font: NSFont
    var color: RGBA
    var kern: Double = 0

    var attributes: [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: color.ns, .kern: kern]
    }
    func with(color: RGBA) -> TextStyle { var copy = self; copy.color = color; return copy }
}

/// Typeset lines are reused across frames; most text repeats from frame to frame.
enum TextCache {
    private static var lines: [String: CTLine] = [:]

    static func line(_ text: String, _ style: TextStyle) -> CTLine {
        let c = style.color
        let key = "\(style.font.fontName)|\(style.font.pointSize)|\(style.kern)|\(c.r),\(c.g),\(c.b),\(c.a)|\(text)"
        if let line = lines[key] { return line }
        if lines.count > 8000 { lines.removeAll(keepingCapacity: true) }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: style.font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): c.cg,
            .kern: style.kern,
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        lines[key] = line
        return line
    }
}

func measure(_ text: String, _ style: TextStyle) -> Double {
    Double(CTLineGetTypographicBounds(TextCache.line(text, style), nil, nil, nil))
}

/// Draws text with its baseline at `baseline`, starting at `x`, in the current y-down context.
func drawText(_ text: String, x: Double, baseline: Double, _ style: TextStyle) {
    guard let cg = NSGraphicsContext.current?.cgContext else { return }
    cg.saveGState()
    cg.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
    cg.textPosition = CGPoint(x: x, y: baseline)
    CTLineDraw(TextCache.line(text, style), cg)
    cg.restoreGState()
}

func numberWord(_ number: Int) -> String {
    let words = [1: "one", 2: "two", 3: "three", 4: "four", 5: "five", 6: "six", 7: "seven", 8: "eight", 9: "nine",
                 10: "ten", 12: "twelve", 15: "fifteen", 20: "twenty", 30: "thirty", 45: "forty-five", 60: "sixty"]
    return words[number] ?? String(number)
}

/// "three minutes", "five minutes", "30 seconds".
func spokenDuration(_ seconds: Int) -> String {
    if seconds % 60 == 0 {
        let minutes = seconds / 60
        return "\(numberWord(minutes)) \(minutes == 1 ? "minute" : "minutes")"
    }
    return "\(numberWord(seconds)) seconds"
}

/// The native menu's compact form: "3 min", "30 sec".
func menuDuration(_ seconds: Int) -> String {
    seconds % 60 == 0 ? "\(seconds / 60) min" : "\(seconds) sec"
}

/// 2:14 AM style clock text for minutes after midnight.
func clockText(_ minutes: Double) -> String {
    let total = Int(minutes.rounded(.down)) % (24 * 60)
    let hour = total / 60, minute = total % 60
    let display = hour % 12 == 0 ? 12 : hour % 12
    return String(format: "%d:%02d %@", display, minute, hour < 12 ? "AM" : "PM")
}
