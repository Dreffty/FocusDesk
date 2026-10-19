import AppKit
let folder = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let rect = NSRect(x: 0, y: 0, width: pixels, height: pixels)
        NSColor(calibratedRed: 0.055, green: 0.07, blue: 0.09, alpha: 1).setFill()
        NSBezierPath(roundedRect: rect.insetBy(dx: Double(pixels) * 0.03, dy: Double(pixels) * 0.03), xRadius: Double(pixels) * 0.23, yRadius: Double(pixels) * 0.23).fill()
        let mint = NSColor(calibratedRed: 0.64, green: 0.89, blue: 0.73, alpha: 1)
        for (fraction, alpha) in [(0.20, 0.25), (0.31, 0.65)] {
            mint.withAlphaComponent(alpha).setStroke()
            let ring = NSBezierPath(ovalIn: rect.insetBy(dx: Double(pixels) * fraction, dy: Double(pixels) * fraction)); ring.lineWidth = max(1, Double(pixels) * 0.018); ring.stroke()
        }
        mint.setFill(); NSBezierPath(ovalIn: rect.insetBy(dx: Double(pixels) * 0.43, dy: Double(pixels) * 0.43)).fill()
        image.unlockFocus()
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent(name))
    }
}
