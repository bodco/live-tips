// Draws the Pacenote app icon (brand v1, direction A "Route P", light appearance) into an .iconset
// folder at build time, so the repository keeps no binary assets. The geometry is the master
// design/pacenote-0.8/brand/icon/AppIcon-light.svg (1024 x 1024); keep the two in step.
// The dark and tinted appearances need an asset catalog (Xcode), so 0.8 ships the light icon only.
import AppKit

let out = CommandLine.arguments[1]
let sizes: [(String, Int)] = [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                              ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)]

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

/// The mark: M400 742 V404 C400 312 466 262 556 262 C664 262 724 330 724 412 C724 500 662 560 556 560 H500
func markPath() -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: 400, y: 742))
    p.addLine(to: CGPoint(x: 400, y: 404))
    p.addCurve(to: CGPoint(x: 556, y: 262), control1: CGPoint(x: 400, y: 312), control2: CGPoint(x: 466, y: 262))
    p.addCurve(to: CGPoint(x: 724, y: 412), control1: CGPoint(x: 664, y: 262), control2: CGPoint(x: 724, y: 330))
    p.addCurve(to: CGPoint(x: 556, y: 560), control1: CGPoint(x: 724, y: 500), control2: CGPoint(x: 662, y: 560))
    p.addLine(to: CGPoint(x: 500, y: 560))
    return p
}

for (name, px) in sizes {
    let s = CGFloat(px)
    let img = NSImage(size: NSSize(width: s, height: s), flipped: true) { _ in
        guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
        ctx.scaleBy(x: s / 1024, y: s / 1024)       // draw in the master's 1024 units, y down like the SVG
        let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
        let shape = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
        ctx.saveGState()
        ctx.addPath(shape)
        ctx.clip()
        let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [rgb(0xFFFFFF), rgb(0xE6E8ED)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: tile.minY), end: CGPoint(x: 0, y: tile.maxY), options: [])
        ctx.restoreGState()
        ctx.addPath(CGPath(roundedRect: tile.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 184.5, cornerHeight: 184.5, transform: nil))
        ctx.setStrokeColor(rgb(0x000000, 0.08))
        ctx.setLineWidth(1)
        ctx.strokePath()
        ctx.addPath(markPath())
        ctx.setStrokeColor(rgb(0x1C1D21))
        ctx.setLineWidth(92)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.strokePath()
        ctx.setFillColor(rgb(0x0A6CFF))
        ctx.fillEllipse(in: CGRect(x: 400 - 70, y: 752 - 70, width: 140, height: 140))
        return true
    }
    // Render at exactly px x px pixels (not the screen's scale).
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: s, height: s)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    img.draw(in: NSRect(x: 0, y: 0, width: s, height: s))
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/icon_\(name).png"))
}
