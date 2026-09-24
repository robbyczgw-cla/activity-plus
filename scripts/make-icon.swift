// Renders Resources/AppIcon.icns: a blue-violet squircle with a white heartbeat line and a small plus.
// Run: DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift scripts/make-icon.swift
import AppKit

func render(_ size: Int) -> Data {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let inset = s * 0.1
    let rect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let squircle = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
    NSGradient(colors: [NSColor(calibratedRed: 0.20, green: 0.45, blue: 1.0, alpha: 1),
                        NSColor(calibratedRed: 0.55, green: 0.25, blue: 0.95, alpha: 1)])!
        .draw(in: squircle, angle: -60)

    // Heartbeat line
    let line = NSBezierPath()
    let y = rect.midY - rect.height * 0.04
    let points: [(CGFloat, CGFloat)] = [(0.12, 0), (0.34, 0), (0.42, 0.16), (0.52, -0.26), (0.62, 0.30), (0.70, 0), (0.88, 0)]
    for (index, point) in points.enumerated() {
        let p = CGPoint(x: rect.minX + rect.width * point.0, y: y + rect.height * point.1)
        index == 0 ? line.move(to: p) : line.line(to: p)
    }
    line.lineWidth = rect.width * 0.065
    line.lineCapStyle = .round
    line.lineJoinStyle = .round
    NSColor.white.setStroke()
    line.stroke()

    // Plus in the top-right corner
    let plus = NSBezierPath()
    let c = CGPoint(x: rect.maxX - rect.width * 0.2, y: rect.maxY - rect.height * 0.2)
    let arm = rect.width * 0.075
    plus.move(to: CGPoint(x: c.x - arm, y: c.y)); plus.line(to: CGPoint(x: c.x + arm, y: c.y))
    plus.move(to: CGPoint(x: c.x, y: c.y - arm)); plus.line(to: CGPoint(x: c.x, y: c.y + arm))
    plus.lineWidth = rect.width * 0.045
    plus.lineCapStyle = .round
    NSColor.white.withAlphaComponent(0.9).setStroke()
    plus.stroke()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let iconset = URL(fileURLWithPath: "Resources/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try! task.run(); task.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print("Resources/AppIcon.icns")
