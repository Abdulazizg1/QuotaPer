import AppKit

/// Gauge-ring glyph used in the menu bar. `progress` (0...1) fills the ring clockwise from the top.
/// Drawn as a template image so macOS tints it for light/dark menu bars automatically.
func ringIcon(size: CGFloat = 18, progress: Double?) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
        let color = NSColor.black
        let lineWidth = size * 0.13
        let radius = (size - lineWidth) / 2 - size * 0.06
        let center = CGPoint(x: size / 2, y: size / 2)

        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        track.lineWidth = lineWidth
        color.withAlphaComponent(0.35).setStroke()
        track.stroke()

        if let p = progress {
            let clamped = min(max(p, 0.04), 1)
            let arc = NSBezierPath()
            arc.appendArc(withCenter: center, radius: radius,
                          startAngle: 90, endAngle: 90 - 360 * clamped, clockwise: true)
            arc.lineWidth = lineWidth
            arc.lineCapStyle = .round
            color.setStroke()
            arc.stroke()
        }

        let dot = size * 0.17
        color.setFill()
        NSBezierPath(ovalIn: CGRect(x: center.x - dot / 2, y: center.y - dot / 2, width: dot, height: dot)).fill()
        return true
    }
    image.isTemplate = true
    return image
}
