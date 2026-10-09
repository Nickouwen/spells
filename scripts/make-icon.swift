// make-icon.swift <source.png> <out.icns> — macOS app icon from a square image:
// 824/1024 rounded-rect (Big Sur+ grid), soft shadow, all iconset sizes, iconutil.
import AppKit

let args = CommandLine.arguments
guard args.count == 3, let src = NSImage(contentsOfFile: args[1]) else {
    FileHandle.standardError.write("usage: make-icon <source.png> <out.icns>\n".data(using: .utf8)!); exit(64)
}
func master(_ px: Int) -> Data {
    let s = CGFloat(px), inset = s * 100 / 1024, side = s * 824 / 1024
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let rect = NSRect(x: inset, y: inset + s * 10 / 1024, width: side, height: side)   // nudged up for the shadow
    let path = NSBezierPath(roundedRect: rect, xRadius: side * 0.225, yRadius: side * 0.225)
    let shadow = NSShadow(); shadow.shadowColor = .black.withAlphaComponent(0.35)
    shadow.shadowOffset = NSSize(width: 0, height: -s * 10 / 1024); shadow.shadowBlurRadius = s * 20 / 1024
    NSGraphicsContext.saveGraphicsState(); shadow.set(); NSColor.black.setFill(); path.fill(); NSGraphicsContext.restoreGraphicsState()
    path.addClip()
    NSGraphicsContext.current?.imageInterpolation = .high
    src.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
    // Faint light rim so the dark edge reads against dark Docks (as Apple's dark icons do).
    NSColor.white.withAlphaComponent(0.18).setStroke(); path.lineWidth = max(1, s * 6 / 1024); path.stroke()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}
let set = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: set)
try! FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! master(base).write(to: set.appendingPathComponent("icon_\(base)x\(base).png"))
    try! master(base * 2).write(to: set.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set.path, "-o", args[2]]; try! p.run(); p.waitUntilExit(); exit(p.terminationStatus)
