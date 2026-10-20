// Draws Kabuk's app icon: a dark glass tile with a prompt and an orange spark.
// Usage: swift scripts/make-icon.swift <output.iconset>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func draw(size: CGFloat) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024
    let tile = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let path = NSBezierPath(roundedRect: tile, xRadius: 185 * s, yRadius: 185 * s)
    NSGradient(colors: [NSColor(red: 0.16, green: 0.17, blue: 0.22, alpha: 1),
                        NSColor(red: 0.05, green: 0.05, blue: 0.08, alpha: 1)])!.draw(in: path, angle: -90)
    NSColor.white.withAlphaComponent(0.12).setStroke()
    path.lineWidth = 6 * s
    path.stroke()

    let prompt = NSBezierPath()
    prompt.move(to: NSPoint(x: 260 * s, y: 640 * s))
    prompt.line(to: NSPoint(x: 420 * s, y: 512 * s))
    prompt.line(to: NSPoint(x: 260 * s, y: 384 * s))
    prompt.lineWidth = 58 * s
    prompt.lineCapStyle = .round
    prompt.lineJoinStyle = .round
    NSColor(white: 0.92, alpha: 1).setStroke()
    prompt.stroke()

    let cursor = NSBezierPath(roundedRect: NSRect(x: 480 * s, y: 360 * s, width: 210 * s, height: 52 * s), xRadius: 26 * s, yRadius: 26 * s)
    NSColor(white: 0.92, alpha: 1).setFill()
    cursor.fill()

    let spark = NSAttributedString(string: "✻", attributes: [
        .font: NSFont.systemFont(ofSize: 300 * s, weight: .heavy),
        .foregroundColor: NSColor(red: 0.95, green: 0.56, blue: 0.33, alpha: 1),
    ])
    spark.draw(at: NSPoint(x: 560 * s, y: 520 * s))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try! draw(size: CGFloat(base)).write(to: out.appendingPathComponent("icon_\(base)x\(base).png"))
    try! draw(size: CGFloat(base * 2)).write(to: out.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
