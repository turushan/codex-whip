import AppKit

enum MenuBarIcon {
    /// A broad loop tapering into a fine tail, clear of the diagonal grip.
    /// Template rendering follows the menu bar's appearance and selection.
    static func whip(accessibilityDescription: String) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setStroke()
            NSColor.black.setFill()

            // A filled outline preserves the thick-to-thin rope at menu bar size.
            let lash = NSBezierPath()
            lash.move(to: NSPoint(x: 9.70, y: 8.56))
            lash.curve(to: NSPoint(x: 11.31, y: 11.98),
                       controlPoint1: NSPoint(x: 10.90, y: 10.05),
                       controlPoint2: NSPoint(x: 11.90, y: 10.50))
            lash.curve(to: NSPoint(x: 7.32, y: 14.99),
                       controlPoint1: NSPoint(x: 11.00, y: 14.00),
                       controlPoint2: NSPoint(x: 9.35, y: 15.38))
            lash.curve(to: NSPoint(x: 2.90, y: 10.67),
                       controlPoint1: NSPoint(x: 4.30, y: 14.80),
                       controlPoint2: NSPoint(x: 2.65, y: 12.95))
            lash.curve(to: NSPoint(x: 4.62, y: 7.33),
                       controlPoint1: NSPoint(x: 2.75, y: 8.95),
                       controlPoint2: NSPoint(x: 3.05, y: 7.80))
            lash.curve(to: NSPoint(x: 9.11, y: 5.58),
                       controlPoint1: NSPoint(x: 6.30, y: 6.83),
                       controlPoint2: NSPoint(x: 8.20, y: 6.80))
            lash.curve(to: NSPoint(x: 9.90, y: 3.60),
                       controlPoint1: NSPoint(x: 9.65, y: 4.90),
                       controlPoint2: NSPoint(x: 9.90, y: 4.10))
            lash.curve(to: NSPoint(x: 9.50, y: 3.60),
                       controlPoint1: NSPoint(x: 9.90, y: 3.38),
                       controlPoint2: NSPoint(x: 9.50, y: 3.38))
            lash.curve(to: NSPoint(x: 8.69, y: 5.22),
                       controlPoint1: NSPoint(x: 9.50, y: 4.05),
                       controlPoint2: NSPoint(x: 9.25, y: 4.60))
            lash.curve(to: NSPoint(x: 4.38, y: 6.47),
                       controlPoint1: NSPoint(x: 7.90, y: 6.15),
                       controlPoint2: NSPoint(x: 6.10, y: 5.99))
            lash.curve(to: NSPoint(x: 1.70, y: 10.53),
                       controlPoint1: NSPoint(x: 2.30, y: 7.00),
                       controlPoint2: NSPoint(x: 1.50, y: 8.30))
            lash.curve(to: NSPoint(x: 7.08, y: 16.41),
                       controlPoint1: NSPoint(x: 1.40, y: 13.40),
                       controlPoint2: NSPoint(x: 3.90, y: 16.05))
            lash.curve(to: NSPoint(x: 12.89, y: 12.62),
                       controlPoint1: NSPoint(x: 9.70, y: 16.95),
                       controlPoint2: NSPoint(x: 12.40, y: 15.60))
            lash.curve(to: NSPoint(x: 11.10, y: 7.44),
                       controlPoint1: NSPoint(x: 13.60, y: 10.90),
                       controlPoint2: NSPoint(x: 12.00, y: 8.60))
            lash.close()
            lash.fill()

            let grip = NSBezierPath()
            grip.lineWidth = 2.6
            grip.lineCapStyle = .round
            grip.move(to: NSPoint(x: 15.1, y: 2.6))
            grip.line(to: NSPoint(x: 10.4, y: 8.0))
            grip.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = accessibilityDescription
        return image
    }
}
