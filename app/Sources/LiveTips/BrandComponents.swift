// Pacenote brand components (redesign, block 2, 2026-11-18): Route P in the three styles, the brand spinner, the
// "listening" dot and the level bars. Geometry and motion are the ones of the canvas boards RM-RouteMark and MO-Motion
// (research/redesign-src) and of research/pacenote-redesign-handoff-2026-11-18.md, sections 1.3 and 2.
//  - RouteMark: the Classic geometry (Brand.markD, stroke 92 of 626, dot r 70) in a square box, the line 74% high with
//    13% above it. Roadbook puts it on its yellow plate, the others have no plate. The dot is the Classic blue.
//  - PNSpinner: the P drawn over a quiet track in 1.6 s (drawn 0-60%, held to 85%, cleared to 100%). Roadbook in 6 steps.
//  - ListeningDot: a dot with a ring that leaves it (scale 1 to 2.4, opacity .6 to 0 in the first 70% of 1.6 s).
//  - LevelBars: five bars, quarter to full height, 0.9 to 1.3 s each, out of step; live from the sound level when given.
// Reduce Motion: nothing loops. The spinner stands at 60% drawn, the ring and the bars stand still.

import SwiftUI

/// Easing and cycle maths of the three loops (the same numbers as the CSS keyframes in tokens.css).
enum PNMotion {
    static let cycle: Double = 1.6

    /// CSS cubic-bezier(x1, y1, x2, y2) at progress x.
    static func bezier(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, _ x: Double) -> Double {
        if x <= 0 { return 0 }
        if x >= 1 { return 1 }
        func cx(_ t: Double) -> Double { 3 * (1 - t) * (1 - t) * t * x1 + 3 * (1 - t) * t * t * x2 + t * t * t }
        func cy(_ t: Double) -> Double { 3 * (1 - t) * (1 - t) * t * y1 + 3 * (1 - t) * t * t * y2 + t * t * t }
        var lo = 0.0, hi = 1.0, t = x
        for _ in 0..<32 {
            let v = cx(t)
            if abs(v - x) < 1e-5 { break }
            if v < x { lo = t } else { hi = t }
            t = (lo + hi) / 2
        }
        return cy(t)
    }

    /// steps(n, end) at progress u, or the curve when n is nil.
    static func stepped(_ u: Double, _ n: Int?, _ curve: (Double) -> Double) -> Double {
        guard let n else { return curve(u) }
        return u >= 1 ? 1 : (u * Double(n)).rounded(.down) / Double(n)
    }

    /// Phase 0..<1 of the 1.6 s loop at a date.
    static func phase(_ date: Date) -> Double {
        date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: cycle) / cycle
    }

    /// The ring leaving a dot: scale 1 -> 2.4 and opacity .6 -> 0 over the first 70% of the loop, then at rest.
    static func ring(_ date: Date, steps: Int?) -> (scale: CGFloat, opacity: Double) {
        let u = min(1, phase(date) / 0.7)
        let e = stepped(u, steps) { bezier(0.3, 0, 0.2, 1, $0) }
        return (CGFloat(1 + 1.4 * e), 0.6 * (1 - e))
    }

    /// The spinner's line: how much of the P is drawn and its opacity.
    static func draw(_ date: Date, steps: Int?) -> (drawn: Double, opacity: Double) {
        let t = phase(date)
        if t < 0.6 { return (stepped(t / 0.6, steps) { bezier(0.45, 0, 0.2, 1, $0) }, 1) }
        if t < 0.85 { return (1, 1) }
        return (1, max(0, 1 - (t - 0.85) / 0.15))
    }

    static let barSeconds: [Double] = [0.9, 1.1, 1.3, 1.0, 1.2]
    static let barRest: [Double] = [0.5, 0.9, 0.35, 0.75, 0.55]

    /// Height (0.25...1) of bar i at a date: a triangle wave through ease-in-out, or steps(3) in Roadbook.
    static func bar(_ i: Int, _ date: Date, steps: Int?) -> Double {
        let d = barSeconds[i]
        let u = (date.timeIntervalSinceReferenceDate + 0.17 * Double(i)).truncatingRemainder(dividingBy: d) / d
        let tri = u < 0.5 ? u * 2 : (1 - u) * 2
        let e = stepped(tri, steps) { bezier(0.42, 0, 0.58, 1, $0) }
        return 0.25 + 0.75 * e
    }
}

/// The geometry of Route P, parsed once.
enum RouteGeometry {
    static let path = Path(SVGPath.cgPath(Brand.markD))

    /// Maps the mark's viewBox (320 206 460 626) to a mark of the given height whose top-left is at (x, y).
    static func transform(height h: CGFloat, x: CGFloat, y: CGFloat) -> CGAffineTransform {
        let s = h / Brand.markBox.height
        return CGAffineTransform(translationX: x, y: y).scaledBy(x: s, y: s).translatedBy(x: -Brand.markBox.minX, y: -Brand.markBox.minY)
    }
}

/// Route P in a square box. Roadbook: black line on its yellow plate; Broadsheet and Classic: no plate.
/// The line is never rotated, thinned or put in a shape. `dot` overrides the start dot (a call state), `ring` adds the
/// listening ring around it.
struct RouteMark: View {
    var size: CGFloat
    var dot: Color? = nil
    var ring = false
    var ringColor: Color? = nil
    @Environment(\.pnTheme) private var t
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        let plate = t.markBg.map { Color(pnHex: $0) }
        let line = Color(pnHex: t.markFg)
        let dotColor = dot ?? Color(pnHex: t.markDot)
        let animated = ring && !reduce
        TimelineView(.animation(paused: !animated)) { tl in
            Canvas { ctx, sz in
                let h = sz.height * 0.74
                let tf = RouteGeometry.transform(height: h, x: (sz.width - Brand.markBox.width * h / Brand.markBox.height) / 2, y: sz.height * 0.13)
                let s = h / Brand.markBox.height
                ctx.stroke(RouteGeometry.path.applying(tf), with: .color(line),
                           style: StrokeStyle(lineWidth: Brand.markStroke * s, lineCap: .round, lineJoin: .round))
                let c = Brand.dot.center.applying(tf), r = Brand.dot.radius * s
                if animated {
                    let g = PNMotion.ring(tl.date, steps: t.ringSteps), rr = r * g.scale
                    ctx.fill(Path(ellipseIn: CGRect(x: c.x - rr, y: c.y - rr, width: 2 * rr, height: 2 * rr)),
                             with: .color((ringColor ?? dotColor).opacity(g.opacity)))
                }
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)), with: .color(dotColor))
            }
        }
        .frame(width: size, height: size)
        .background(plate ?? .clear)
        .accessibilityElement()
        .accessibilityLabel("Pacenote")
    }
}

/// The brand spinner. 16 in buttons and rows, 24 in lists, 40 for a whole panel, 96 for a window. Never under 16.
/// `line` is the ink (onAccent inside the main button), `track` the quiet whole P, `dot` the blue start dot.
struct PNSpinner: View {
    var size: CGFloat = 16
    var line: Color? = nil
    var dot: Color? = nil
    var track: Color? = nil
    @Environment(\.pnTheme) private var t
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        let lineC = line ?? Color(pnHex: t.ink), trackC = track ?? Color(pnHex: t.rule), dotC = dot ?? Color(pnHex: t.spDot)
        TimelineView(.animation(paused: reduce)) { tl in
            Canvas { ctx, sz in
                let g = reduce ? (drawn: 0.6, opacity: 1.0) : PNMotion.draw(tl.date, steps: t.drawSteps)
                let s = sz.height / Brand.markBox.height
                let tf = RouteGeometry.transform(height: sz.height, x: (sz.width - Brand.markBox.width * s) / 2, y: 0)
                let style = StrokeStyle(lineWidth: Brand.markStroke * s, lineCap: .round, lineJoin: .round)
                let whole = RouteGeometry.path.applying(tf)
                ctx.stroke(whole, with: .color(trackC), style: style)
                if g.drawn > 0 {
                    ctx.stroke(RouteGeometry.path.trimmedPath(from: 0, to: CGFloat(g.drawn)).applying(tf), with: .color(lineC.opacity(g.opacity)), style: style)
                }
                let c = Brand.dot.center.applying(tf), r = Brand.dot.radius * s
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)), with: .color(dotC))
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement()
        .accessibilityLabel(L("common.working"))
    }
}

/// The dot of "listening": recording red with a ring that leaves it. No ring when paused or on Reduce Motion.
struct ListeningDot: View {
    var size: CGFloat = 10
    var color: Color? = nil
    var ring = true
    @Environment(\.pnTheme) private var t
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        let c = color ?? Color(pnHex: t.rec)
        let animated = ring && !reduce
        TimelineView(.animation(paused: !animated)) { tl in
            let g = animated ? PNMotion.ring(tl.date, steps: t.ringSteps) : (scale: CGFloat(1), opacity: 0.0)
            ZStack {
                Circle().fill(c).scaleEffect(g.scale).opacity(g.opacity)
                Circle().fill(c)
            }
            .frame(width: size, height: size)
        }
        .accessibilityHidden(true)
    }
}

/// Five level bars in recording red. `level` (0...1, the sound level of the mic and the call) drives them live;
/// without it they loop on their own. Square bars in Roadbook, round in the others.
struct LevelBars: View {
    var height: CGFloat = 14
    var color: Color? = nil
    var level: Double? = nil
    @Environment(\.pnTheme) private var t
    @Environment(\.accessibilityReduceMotion) private var reduce

    /// 3 px bars with a 2 px gap at 14, 6 and 4 at 40, 12 and 8 at 64 (the sizes of the boards).
    private var barWidth: CGFloat { height <= 20 ? 3 : (height <= 48 ? 6 : 12) }
    private var gap: CGFloat { height <= 20 ? 2 : (height <= 48 ? 4 : 8) }

    var body: some View {
        let c = color ?? Color(pnHex: t.rec)
        TimelineView(.animation(paused: reduce)) { tl in
            HStack(alignment: .bottom, spacing: gap) {
                ForEach(0..<5, id: \.self) { i in
                    RoundedRectangle(cornerRadius: t.barRound ? barWidth / 2 : 0)
                        .fill(c)
                        .frame(width: barWidth, height: height)
                        .scaleEffect(y: scale(i, tl.date), anchor: .bottom)
                }
            }
            .frame(height: height, alignment: .bottom)
        }
        .accessibilityHidden(true)
    }

    private func scale(_ i: Int, _ date: Date) -> CGFloat {
        if reduce && level == nil { return CGFloat(PNMotion.barRest[i]) }
        if let level {
            let l = max(0, min(1, level))
            return CGFloat(0.2 + 0.8 * min(1, l * PNMotion.barRest[i] * 1.6))
        }
        return CGFloat(PNMotion.bar(i, date, steps: t.barSteps))
    }
}

/// The empty "Listening" state: the mark with a ring, the level bars next to it (52 pt mark, 40 pt bars).
struct ListeningMark: View {
    var size: CGFloat = 52
    var level: Double? = nil
    @Environment(\.pnTheme) private var t
    var body: some View {
        HStack(spacing: 14) {
            RouteMark(size: size, dot: Color(pnHex: t.rec), ring: true)
            LevelBars(height: 40, level: level)
        }
    }
}
