import AppKit
import SwiftUI

/// Pacenote brand (0.8, direction A "Route P"). The shapes are drawn from the brand SVG geometry
/// (design/pacenote-0.8/brand), so the repository keeps no binary assets: the app icon is drawn at
/// build time by buildtools/make_icon.swift, the menu bar images and the mark here, at runtime.
enum Brand {
    // The mark: one route line that reads as a P, with the blue start dot. SVG viewBox 320 206 460 626.
    static let markD = "M400 742V404C400 312 466 262 556 262C664 262 724 330 724 412C724 500 662 560 556 560H500"
    static let markBox = CGRect(x: 320, y: 206, width: 460, height: 626)
    static let markStroke: CGFloat = 92
    static let dot = (center: CGPoint(x: 400, y: 752), radius: CGFloat(70))

    // Menu bar template, 18 x 18 pt: idle (open dot) and recording (filled dot, slightly shorter line).
    static let barIdleD = "M6 13.1V6.6C6 4.6 7.3 3 9.5 3C11.7 3 13.2 4.4 13.2 6.4C13.2 8.5 11.7 9.9 9.5 9.9H8.4"
    static let barRecD = "M6 12.9V6.6C6 4.6 7.3 3 9.5 3C11.7 3 13.2 4.4 13.2 6.4C13.2 8.5 11.7 9.9 9.5 9.9H8.4"

    // The wordmark, Manrope Bold in outlines. SVG viewBox 0 -1460 8832 2030.
    static let wordmarkBox = CGRect(x: 0, y: -1460, width: 8832, height: 2030)
    static let wordmarkD = "M140 0V-1440H735Q756 -1440 789.2 -1438.5Q822.5 -1437 850.3 -1432Q975.2 -1412.7 1056.7 -1348.6Q1138.2 -1284.5 1177.6 -1187.3Q1217 -1090.2 1217 -971.3Q1217 -852.5 1177.2 -755.3Q1137.3 -658.2 1055.8 -594.1Q974.3 -530 850.3 -510.7Q822.5 -506.7 788.8 -504.7Q755.2 -502.7 735 -502.7H380.7V0ZM380.7 -728.3H725Q745.3 -728.3 770.1 -730.3Q794.8 -732.3 816.3 -738Q876 -753.2 910.4 -791.1Q944.8 -829 959.3 -877.2Q973.7 -925.3 973.7 -971.3Q973.7 -1017.3 959.3 -1065.5Q944.8 -1113.7 910.4 -1151.6Q876 -1189.5 816.3 -1204.7Q794.8 -1210.5 770.1 -1212.4Q745.3 -1214.3 725 -1214.3H380.7Z M1642.3 30Q1524.7 30 1443.8 -14.4Q1362.8 -58.8 1321.4 -132.9Q1280 -207 1280 -296Q1280 -374.3 1306.1 -436.4Q1332.2 -498.5 1386.3 -544.1Q1440.3 -589.7 1525.7 -619Q1591.3 -640.5 1678.4 -657.1Q1765.5 -673.7 1868.2 -688.2Q1970.8 -702.8 2083.3 -719.7L1996.7 -671.3Q1997.5 -783.2 1946.8 -836.3Q1896 -889.3 1774.7 -889.3Q1702 -889.3 1634.1 -855.1Q1566.2 -820.8 1539 -738.3L1318.7 -807.3Q1358.8 -944 1471.6 -1027Q1584.3 -1110 1775.3 -1110Q1919.5 -1110 2028.7 -1063.2Q2137.8 -1016.3 2191.3 -909Q2220.3 -852.3 2226.3 -792.8Q2232.3 -733.3 2232.3 -662.7V0H2021V-234.3L2056 -195.7Q1983 -79.2 1885.4 -24.6Q1787.8 30 1642.3 30ZM1690 -162.3Q1772 -162.3 1829.8 -191.4Q1887.7 -220.5 1922.3 -262.1Q1957 -303.7 1968.7 -341.3Q1987.5 -387.3 1990.4 -446.8Q1993.3 -506.2 1993.3 -543.3L2067.3 -521Q1957.7 -503.5 1879.6 -490.8Q1801.5 -478.2 1745.8 -466.8Q1690.2 -455.3 1647 -441Q1605.5 -425.7 1576.4 -405.9Q1547.3 -386.2 1531.8 -360Q1516.3 -333.8 1516.3 -299Q1516.3 -259.5 1536.1 -228.6Q1555.8 -197.7 1594.4 -180Q1633 -162.3 1690 -162.3Z M2911 30Q2744.2 30 2626 -44.5Q2507.8 -119 2445.2 -247.9Q2382.5 -376.8 2382 -540Q2382.5 -705.5 2447.3 -834.3Q2512.2 -963.2 2631.2 -1036.6Q2750.2 -1110 2914.3 -1110Q3098.5 -1110 3226 -1017.7Q3353.5 -925.3 3391.7 -765.3L3151.7 -699.7Q3124.2 -787 3059 -835.7Q2993.8 -884.3 2911 -884.3Q2816.7 -884.3 2756 -839.5Q2695.3 -794.7 2666.3 -716.8Q2637.3 -639 2637 -540Q2637.5 -385.8 2706.4 -290.7Q2775.3 -195.7 2911 -195.7Q3007.5 -195.7 3062.8 -239.8Q3118.2 -284 3146.3 -366.7L3391.7 -312.3Q3342.2 -147.3 3217.2 -58.7Q3092.2 30 2911 30Z M4003.7 30Q3839.8 30 3716 -41.1Q3592.2 -112.2 3522.6 -238.1Q3453 -364 3453 -528.3Q3453 -705.3 3521.2 -835.8Q3589.5 -966.3 3710.4 -1038.2Q3831.3 -1110 3990.3 -1110Q4157.8 -1110 4275.3 -1031.7Q4392.8 -953.3 4450.1 -810.3Q4507.3 -667.3 4493.2 -472.7H4254V-560.7Q4253 -737 4192 -818.2Q4131 -899.3 4000.3 -899.3Q3852.5 -899.3 3780.2 -807.7Q3708 -716 3708 -540Q3708 -375.7 3780.2 -285.7Q3852.5 -195.7 3990.3 -195.7Q4079.3 -195.7 4143.7 -235.3Q4208 -275 4243 -349.7L4481.3 -278Q4419.5 -131.7 4289.7 -50.8Q4160 30 4003.7 30ZM3632 -472.7V-655H4375.3V-472.7Z M5384 0V-520.3Q5384 -570.5 5376.8 -632.5Q5369.5 -694.5 5344.3 -752.1Q5319.2 -809.7 5268.7 -846.7Q5218.2 -883.7 5131.7 -883.7Q5086 -883.7 5041.1 -868.8Q4996.2 -853.8 4959.8 -817.6Q4923.5 -781.3 4901.4 -717.5Q4879.3 -653.7 4879.3 -555L4736.3 -616.3Q4736.3 -753.8 4789.8 -866.1Q4843.3 -978.3 4947.2 -1044.5Q5051 -1110.7 5203.3 -1110.7Q5322.8 -1110.7 5400.9 -1071Q5479 -1031.3 5525 -969.1Q5571 -906.8 5593 -836.8Q5615 -766.7 5621.5 -704.1Q5628 -641.5 5628 -603V0ZM4635.3 0V-1080H4850V-745H4879.3V0Z M6298.3 30Q6135.8 30 6015 -43Q5894.2 -116 5827.6 -244.6Q5761 -373.2 5761 -540.3Q5761 -709.5 5829 -837.9Q5897 -966.3 6017.9 -1038.2Q6138.8 -1110 6298.3 -1110Q6461 -1110 6582.2 -1037.1Q6703.5 -964.2 6770.4 -835.8Q6837.3 -707.3 6837.3 -540.3Q6837.3 -371.8 6769.9 -243.3Q6702.5 -114.8 6581.2 -42.4Q6459.8 30 6298.3 30ZM6298.3 -195.7Q6441.5 -195.7 6511.9 -292Q6582.3 -388.3 6582.3 -540.3Q6582.3 -697.2 6511 -790.8Q6439.7 -884.3 6298.3 -884.3Q6201.3 -884.3 6138.9 -840.7Q6076.5 -797 6046.2 -719.7Q6016 -642.3 6016 -540.3Q6016 -382.8 6087.7 -289.2Q6159.3 -195.7 6298.3 -195.7Z M7640 0Q7533.2 20.5 7430.4 17.7Q7327.7 14.8 7246.9 -20.3Q7166.2 -55.5 7124.3 -132.7Q7087 -203.2 7084.8 -276Q7082.7 -348.8 7082.7 -441.3V-1380H7323.3V-454.7Q7323.3 -390.5 7324.8 -341.2Q7326.3 -292 7345.3 -260.7Q7381.3 -201.2 7460.2 -194.2Q7539 -187.3 7640 -201.7ZM6887 -891V-1080H7640V-891Z M8258.7 30Q8094.8 30 7971 -41.1Q7847.2 -112.2 7777.6 -238.1Q7708 -364 7708 -528.3Q7708 -705.3 7776.2 -835.8Q7844.5 -966.3 7965.4 -1038.2Q8086.3 -1110 8245.3 -1110Q8412.8 -1110 8530.3 -1031.7Q8647.8 -953.3 8705.1 -810.3Q8762.3 -667.3 8748.2 -472.7H8509V-560.7Q8508 -737 8447 -818.2Q8386 -899.3 8255.3 -899.3Q8107.5 -899.3 8035.2 -807.7Q7963 -716 7963 -540Q7963 -375.7 8035.2 -285.7Q8107.5 -195.7 8245.3 -195.7Q8334.3 -195.7 8398.7 -235.3Q8463 -275 8498 -349.7L8736.3 -278Q8674.5 -131.7 8544.7 -50.8Q8415 30 8258.7 30ZM7887 -472.7V-655H8630.3V-472.7Z"

    static let ink = Color(red: 0x1C / 255, green: 0x1D / 255, blue: 0x21 / 255)
    static let paper = Color(red: 0xF5 / 255, green: 0xF5 / 255, blue: 0xF7 / 255)
    static let blue = Color(red: 0x0A / 255, green: 0x6C / 255, blue: 0xFF / 255)
    static let blueLight = Color(red: 0x4D / 255, green: 0x9D / 255, blue: 0xFF / 255)

    /// The menu bar image: a template (macOS tints it for the menu bar), drawn as vectors.
    static func menuBarImage(recording: Bool) -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.setStrokeColor(NSColor.black.cgColor)
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.setLineWidth(2)
            ctx.addPath(SVGPath.cgPath(recording ? barRecD : barIdleD))
            ctx.strokePath()
            let r: CGFloat = recording ? 2.1 : 1.75
            let rect = CGRect(x: 6 - r, y: 15 - r, width: 2 * r, height: 2 * r)
            if recording { ctx.fillEllipse(in: rect) } else { ctx.setLineWidth(1.4); ctx.strokeEllipse(in: rect) }
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = "Pacenote"
        return img
    }

    /// The app icon (from AppIcon.icns in the bundle; the generic icon when run outside the bundle).
    @MainActor static var appIcon: NSImage { NSApp.applicationIconImage ?? NSImage() }
}

/// A minimal SVG path reader for the brand shapes: absolute M, L, H, V, C, Q and Z (all the brand files use).
enum SVGPath {
    static func cgPath(_ d: String) -> CGPath {
        let p = CGMutablePath()
        var tokens: [String] = []
        var num = ""
        func flush() { if !num.isEmpty { tokens.append(num); num = "" } }
        for ch in d {
            if ch.isLetter && ch != "e" && ch != "E" { flush(); tokens.append(String(ch)) }
            else if ch == "-" && !(num.last == "e" || num.last == "E") { flush(); num = "-" }
            else if ch == " " || ch == "," || ch == "\n" { flush() }
            else { num.append(ch) }
        }
        flush()
        var i = 0, cmd = "M"
        var cur = CGPoint.zero
        func n() -> CGFloat { defer { i += 1 }; return i < tokens.count ? CGFloat(Double(tokens[i]) ?? 0) : 0 }
        func isNum() -> Bool { i < tokens.count && !(tokens[i].first?.isLetter ?? false) }
        while i < tokens.count {
            if !isNum() { cmd = tokens[i]; i += 1 }
            switch cmd {
            case "M": cur = CGPoint(x: n(), y: n()); p.move(to: cur); cmd = "L"
            case "L": cur = CGPoint(x: n(), y: n()); p.addLine(to: cur)
            case "H": cur.x = n(); p.addLine(to: cur)
            case "V": cur.y = n(); p.addLine(to: cur)
            case "C":
                let c1 = CGPoint(x: n(), y: n()), c2 = CGPoint(x: n(), y: n()); cur = CGPoint(x: n(), y: n())
                p.addCurve(to: cur, control1: c1, control2: c2)
            case "Q":
                let c = CGPoint(x: n(), y: n()); cur = CGPoint(x: n(), y: n())
                p.addQuadCurve(to: cur, control: c)
            case "Z", "z": p.closeSubpath(); cur = p.currentPoint
            default: i += 1     // unknown command: skip its number
            }
        }
        return p
    }
}

/// The Pacenote symbol: Ink line on light, Paper line on dark, the start dot in brand blue.
struct PacenoteSymbol: View {
    var height: CGFloat
    /// Force a look (the white symbol on a dark title bar); nil follows the appearance.
    var dark: Bool? = nil
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let isDark = dark ?? (scheme == .dark)
        let box = Brand.markBox
        Canvas { ctx, size in
            let s = size.height / box.height
            let t = CGAffineTransform(scaleX: s, y: s).translatedBy(x: -box.minX, y: -box.minY)
            let line = Path(SVGPath.cgPath(Brand.markD)).applying(t)
            ctx.stroke(line, with: .color(isDark ? Brand.paper : Brand.ink),
                       style: StrokeStyle(lineWidth: Brand.markStroke * s, lineCap: .round, lineJoin: .round))
            let c = Brand.dot.center.applying(t), r = Brand.dot.radius * s
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)),
                     with: .color(isDark ? Brand.blueLight : Brand.blue))
        }
        .frame(width: height * box.width / box.height, height: height)
        .accessibilityElement()
        .accessibilityLabel("Pacenote")
    }
}

/// The Pacenote wordmark (outlines, never set in a font).
struct PacenoteWordmark: View {
    var height: CGFloat
    var dark: Bool? = nil
    @Environment(\.colorScheme) private var scheme
    private static let path = SVGPath.cgPath(Brand.wordmarkD)

    var body: some View {
        let isDark = dark ?? (scheme == .dark)
        let box = Brand.wordmarkBox
        Canvas { ctx, size in
            let s = size.height / box.height
            let t = CGAffineTransform(scaleX: s, y: s).translatedBy(x: -box.minX, y: -box.minY)
            ctx.fill(Path(Self.path).applying(t), with: .color(isDark ? Brand.paper : Brand.ink))
        }
        .frame(width: height * box.width / box.height, height: height)
        .accessibilityElement()
        .accessibilityLabel("Pacenote")
    }
}
