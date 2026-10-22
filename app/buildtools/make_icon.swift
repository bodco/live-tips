// Draws the Live Tips app icon (a speech bubble with a spark) into an .iconset folder.
import AppKit

let out = CommandLine.arguments[1]
let sizes: [(String, Int)] = [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                              ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)]
for (name, px) in sizes {
    let s = CGFloat(px)
    let img = NSImage(size: NSSize(width: s, height: s))
    img.lockFocus()
    let r = NSRect(x: s * 0.06, y: s * 0.06, width: s * 0.88, height: s * 0.88)
    let bg = NSBezierPath(roundedRect: r, xRadius: s * 0.2, yRadius: s * 0.2)
    NSGradient(starting: NSColor(calibratedRed: 0.16, green: 0.36, blue: 0.95, alpha: 1),
               ending: NSColor(calibratedRed: 0.42, green: 0.22, blue: 0.86, alpha: 1))!.draw(in: bg, angle: -60)
    let bubble = NSBezierPath(roundedRect: NSRect(x: s * 0.22, y: s * 0.36, width: s * 0.56, height: s * 0.36),
                              xRadius: s * 0.08, yRadius: s * 0.08)
    bubble.move(to: NSPoint(x: s * 0.32, y: s * 0.37))
    bubble.line(to: NSPoint(x: s * 0.28, y: s * 0.25))
    bubble.line(to: NSPoint(x: s * 0.44, y: s * 0.37))
    NSColor.white.setFill()
    bubble.fill()
    let bar = NSColor(calibratedRed: 0.25, green: 0.35, blue: 0.9, alpha: 1)
    bar.setFill()
    for (i, w) in [0.36, 0.26].enumerated() {
        NSBezierPath(roundedRect: NSRect(x: s * 0.30, y: s * (0.60 - 0.1 * CGFloat(i)), width: s * CGFloat(w), height: s * 0.05),
                     xRadius: s * 0.025, yRadius: s * 0.025).fill()
    }
    img.unlockFocus()
    let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/icon_\(name).png"))
}
