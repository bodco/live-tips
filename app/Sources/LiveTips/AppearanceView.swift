// Settings > General > Appearance (redesign, block 1, 2026-11-18; board SG-General r11, Settings-Appearance r3).
// Three style cards (Classic, Roadbook, Broadsheet) drawn in the current mode, and the mode: Same as the Mac, Light, Dark.
// Both apply at once in every window (PNThemeModel for the style, NSApp.appearance for the mode).

import SwiftUI
import AppKit

struct AppearanceBlock: View {
    @Binding var style: String
    @Binding var mode: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("set.appearance.style")).pnSection().foregroundStyle(PN.C.text)
            HStack(alignment: .top, spacing: 10) {
                ForEach(PNStyle.allCases) { s in
                    StyleCard(style: s, selected: PNStyle(config: style) == s) { style = s.rawValue }
                }
            }
            Picker(L("set.appearance.mode"), selection: $mode) {
                Text(L("set.theme.system")).tag("system")
                Text(L("set.theme.light")).tag("light")
                Text(L("set.theme.dark")).tag("dark")
            }
            .pickerStyle(.segmented)
            Text(L("set.appearance.hint")).font(PN.Font.caption).foregroundStyle(PN.C.text3)
        }
        .padding(.vertical, 4)
    }
}

/// One style, drawn with ITS tokens in the mode the app is in now. Selected: a 2 px frame in the text colour; in Roadbook
/// Light the card is filled yellow as well (the rule of the Settings-Appearance board).
struct StyleCard: View {
    let style: PNStyle
    let selected: Bool
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme
    @Environment(\.pnTheme) private var current

    private var name: String { L("set.appearance." + style.rawValue) }
    private var detail: String { L("set.appearance." + style.rawValue + "Desc") }

    var body: some View {
        let t = PNTheme.resolve(style, dark: scheme == .dark)
        let yellow = selected && current.style == .roadbook && !current.dark
        let corner = current.radiusCard > 0 ? 8.0 : 0.0
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                preview(t)
                HStack(spacing: 6) {
                    Text(name).font(.system(size: 13, weight: .semibold)).foregroundStyle(yellow ? Color(pnHex: 0x0D0D0B) : PN.C.text)
                    if style == PNStyle.buildDefault {
                        Text(L("set.appearance.default")).font(.system(size: 11)).foregroundStyle(yellow ? Color(pnHex: 0x0D0D0B) : PN.C.text3)
                    }
                }
                Text(detail).font(PN.Font.caption).foregroundStyle(yellow ? Color(pnHex: 0x0D0D0B) : PN.C.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(yellow ? Color(pnHex: 0xFFD60A) : PN.C.surface, in: RoundedRectangle(cornerRadius: corner))
            .overlay(RoundedRectangle(cornerRadius: corner).stroke(selected ? PN.C.text : PN.C.rule, lineWidth: selected ? 2 : 1))
            .contentShape(RoundedRectangle(cornerRadius: corner))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name + ". " + detail)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    /// A small page in the style: the mark, the name in its display face, a heavy rule, a text line, a main button.
    private func preview(_ t: PNTheme) -> some View {
        let r: CGFloat = t.radiusButton
        return ZStack(alignment: .topLeading) {
            Rectangle().fill(Color(pnHex: t.bg))
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    miniMark(t)
                    Text(t.cased("Pacenote")).font(t.font(.display, 15, .heavy)).tracking(t.dTrack * 15)
                        .foregroundStyle(Color(pnHex: t.ink))
                }
                Rectangle().fill(Color(pnHex: t.ruleStrong)).frame(height: t.ruleHeavy)
                Text("Orbit weekly, 10:30").font(t.font(.text, 11)).foregroundStyle(Color(pnHex: t.ink2)).lineLimit(1)
                Text(t.cased("Start a call")).font(t.font(.display, 11, .heavy)).tracking(t.bTrack * 11)
                    .foregroundStyle(Color(pnHex: t.onAccent))
                    .padding(.horizontal, 8).frame(height: 20)
                    .background(Color(pnHex: t.accent), in: RoundedRectangle(cornerRadius: r > 0 ? 4 : 0))
            }
            .padding(9)
        }
        .frame(height: 96)
        .clipShape(RoundedRectangle(cornerRadius: t.radiusCard > 0 ? 6 : 0))
        .overlay(RoundedRectangle(cornerRadius: t.radiusCard > 0 ? 6 : 0).stroke(Color(pnHex: t.rule), lineWidth: 1))
        .accessibilityHidden(true)
    }

    /// The mark in the card's own tokens (a plate in Roadbook), not in the tokens of the style in use.
    private func miniMark(_ t: PNTheme) -> some View {
        Canvas { ctx, sz in
            let h = sz.height * 0.74, s = h / Brand.markBox.height
            let tf = RouteGeometry.transform(height: h, x: (sz.width - Brand.markBox.width * s) / 2, y: sz.height * 0.13)
            ctx.stroke(RouteGeometry.path.applying(tf), with: .color(Color(pnHex: t.markFg)),
                       style: StrokeStyle(lineWidth: Brand.markStroke * s, lineCap: .round, lineJoin: .round))
            let c = Brand.dot.center.applying(tf), rr = Brand.dot.radius * s
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - rr, y: c.y - rr, width: 2 * rr, height: 2 * rr)), with: .color(Color(pnHex: t.markDot)))
        }
        .frame(width: 22, height: 22)
        .background(t.markBg.map { Color(pnHex: $0) } ?? .clear)
    }
}
