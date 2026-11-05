import AppKit
let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
func draw(_ px: Int, _ name: String) {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let inset = s * 0.1, r = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let body = NSBezierPath(roundedRect: r, xRadius: s * 0.18, yRadius: s * 0.18)
    NSGradient(colors: [NSColor(red: 0.04, green: 0.39, blue: 0.81, alpha: 1), NSColor(red: 0.02, green: 0.20, blue: 0.47, alpha: 1)])!.draw(in: body, angle: -90)
    // Four cells, one lit: the charger's slots.
    let w = r.width * 0.15, h = r.height * 0.56, gap = (r.width * 0.78 - 4 * w) / 3
    for i in 0..<4 {
        let x = r.minX + r.width * 0.11 + CGFloat(i) * (w + gap), y = r.minY + r.height * 0.2
        let lit = i == 3
        (lit ? NSColor(red: 1, green: 0.72, blue: 0.25, alpha: 1) : NSColor.white.withAlphaComponent(0.82)).setFill()
        NSBezierPath(roundedRect: NSRect(x: x, y: y, width: w, height: h), xRadius: w * 0.28, yRadius: w * 0.28).fill()
        NSBezierPath(roundedRect: NSRect(x: x + w * 0.3, y: y + h, width: w * 0.4, height: h * 0.08), xRadius: w * 0.1, yRadius: w * 0.1).fill()
    }
    NSGraphicsContext.current = nil
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out + "/" + name))
}
for (p, n) in [(16, "icon_16x16.png"), (32, "icon_16x16@2x.png"), (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"), (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"), (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"), (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png")] { draw(p, n) }
