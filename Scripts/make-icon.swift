// Usage: swift Scripts/make-icon.swift <output .iconset dir>
// Draws the QuotaPer app icon at every size macOS needs.
import AppKit

func render(pixels: Int) -> Data {
    let s = CGFloat(pixels)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // macOS icon grid: artwork occupies ~80% of the canvas.
    let inset = s * 0.1
    let body = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let shape = NSBezierPath(roundedRect: body, xRadius: body.width * 0.225, yRadius: body.width * 0.225)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = s * 0.02
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.012)
    shadow.set()
    NSColor.black.setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGradient(colors: [NSColor(red: 0.36, green: 0.55, blue: 0.98, alpha: 1),
                        NSColor(red: 0.16, green: 0.22, blue: 0.62, alpha: 1)])!
        .draw(in: shape, angle: -90)

    // Gauge ring
    let center = CGPoint(x: s / 2, y: s / 2)
    let lineWidth = body.width * 0.11
    let radius = body.width * 0.30
    let track = NSBezierPath()
    track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
    track.lineWidth = lineWidth
    NSColor.white.withAlphaComponent(0.28).setStroke()
    track.stroke()

    let arc = NSBezierPath()
    arc.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: 90 - 360 * 0.68, clockwise: true)
    arc.lineWidth = lineWidth
    arc.lineCapStyle = .round
    NSColor.white.setStroke()
    arc.stroke()

    let dot = body.width * 0.11
    NSColor.white.setFill()
    NSBezierPath(ovalIn: CGRect(x: center.x - dot / 2, y: center.y - dot / 2, width: dot, height: dot)).fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                   ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512),
                   ("512x512@2x", 1024)] {
    try render(pixels: px).write(to: out.appendingPathComponent("icon_\(name).png"))
}
