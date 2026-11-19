// Pacenote design tokens for SwiftUI, v0.8 (brand v1).
// Mirrors tokens/tokens.css. Every color resolves for light and dark automatically.
// App copy of design/pacenote-0.8/swift/PacenoteTheme.swift: same tokens; the button styles also dim when
// disabled and have a full click area (F1).

import SwiftUI
import AppKit

extension Color {
    /// Builds a color that switches between light and dark appearance.
    static func pn(_ light: UInt32, _ dark: UInt32, darkAlpha: Double = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let hex = isDark ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                           green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255,
                           alpha: isDark ? darkAlpha : 1)
        })
    }
}

enum PN {
    /// Colours. 2026-11-18 (redesign, block 1): the facade over the theme (PNTheme.swift). The names stay, so the ~1500 uses
    /// do not change; each value comes from the current style (Settings > General > Appearance) and the appearance of the
    /// view that draws it. Classic keeps the values the app had (PNTheme.classic); Roadbook and Broadsheet are generated.
    /// The "not ready" orange of Classic must stay BRIGHT (owner, 2026-11-10; tools/tests/test_theme_pending.py).
    enum C {
        static var bg: Color         { .pnRole { $0.bg } }
        static var surface: Color    { .pnRole { $0.surface } }
        static var surface2: Color   { .pnRole { $0.surface2 } }
        static var text: Color       { .pnRole { $0.ink } }
        static var text2: Color      { .pnRole { $0.ink2 } }
        static var text3: Color      { .pnRole { $0.ink3 } }            // captions, never lighter
        static var accent: Color     { .pnRole { $0.link } }            // links, the selected tab
        static var accentFill: Color { .pnRole { $0.accent } }          // the fill of the main button (text on it: onAccent)
        static var onAccent: Color   { .pnRole { $0.onAccent } }
        static var actEdge: Color    { .pnRole { $0.actEdge } }         // the frame of the main button (theme pass)
        static var focus: Color      { .pnRole { $0.focus } }           // the surface of what has the attention (theme pass)
        static var onLink: Color     { .pnRole { $0.onLink } }
        static var brand: Color      { .pnRole { $0.markDot } }         // the mark's start dot, progress, selection
        static let ink       = Color(red: 0x1C/255, green: 0x1D/255, blue: 0x21/255)
        static var rec: Color        { .pnRole { $0.rec } }
        static var recText: Color    { .pnRole { $0.recText } }

        // New tokens (redesign)
        static var frame: Color      { .pnRole { $0.frame } }
        static var rule: Color       { .pnRole { $0.rule } }            // a 1 px row line
        static var ruleStrong: Color { .pnRole { $0.ruleStrong } }      // a section line (3 px in Roadbook and Broadsheet)
        static var field: Color      { .pnRole { $0.field } }           // the frame of an input
        static var ready: Color      { .pnRole { $0.ready } }
        static var readyText: Color  { .pnRole { $0.readyText } }
        static var notready: Color   { .pnRole { $0.notready } }
        static var notreadyText: Color { .pnRole { $0.notreadyText } }
        static var notreadyPlate: Color { .pnRole(optional: { $0.nrBg }) }   // clear when the style has no plate
        static var edge: Color       { .pnRole { $0.edge } }
        static var markBg: Color     { .pnRole(optional: { $0.markBg }) }
        static var markFg: Color     { .pnRole { $0.markFg } }
        static var markDot: Color    { .pnRole { $0.markDot } }
        static var highlight: Color  { .pnRole(optional: { $0.hlBg }) }
        static var onHighlight: Color { .pnRole { $0.hlFg } }

        // Status / card kinds (text color). Soft backgrounds: same hue at 14-16% opacity in dark.
        static var answer: Color     { .pnRole { $0.answer } }
        static var turn: Color       { .pnRole { $0.turn } }
        static var onMe: Color       { .pnRole { $0.onMe } }
        // 2026-11-10 (owner): "not ready" orange must stay BRIGHT in both themes. It went brown twice (C2410C -> B45309
        // "for contrast") and the owner asked for it back; do not darken it again. tools/tests/test_theme_pending.py
        // fails when either Classic value (PNTheme.classic: pending, pendingFill) turns dull. Text uses `pending`,
        // dots, pills and fills use the brighter `pendingFill`.
        static var pending: Color    { .pnRole { $0.pending } }
        static var pendingFill: Color { .pnRole { $0.pendingFill } }
        static var docs: Color       { .pnRole { $0.docs } }
        static var danger: Color     { .pnRole { $0.danger } }
    }

    // Redesign blocks 4-7: radii, depth and type follow the style (Classic as before; Roadbook and Broadsheet are square,
    // with lines instead of shadows, and the style's faces). Read inside a body, so a style change redraws.
    private static var theme: PNTheme { PNTheme.resolve(PNThemeModel.shared.style, dark: false) }
    private static var classicLook: Bool { PNThemeModel.shared.style == .classic }
    enum Radius {
        static var s: CGFloat { PN.classicLook ? 6 : 0 }
        static var m: CGFloat { PN.classicLook ? 10 : 0 }
        static var l: CGFloat { PN.classicLook ? 14 : 0 }
    }
    /// A corner radius written as a number in a view: as written in Classic, square in Roadbook and Broadsheet.
    static func r(_ v: CGFloat) -> CGFloat { classicLook ? v : 0 }
    /// Shadows are Classic's depth; the other two styles have lines only (multiply a shadow's opacity by this).
    static var depth: Double { classicLook ? 1 : 0 }
    enum Space  { static let x1: CGFloat = 4; static let x2: CGFloat = 8; static let x3: CGFloat = 12
                  static let x4: CGFloat = 16; static let x5: CGFloat = 20; static let x6: CGFloat = 24 }

    /// Redesign review (18.11): a literal size and weight that follows the style. Classic: exactly the system font it
    /// replaced. Roadbook and Broadsheet: the style's text face (mono for monospaced), the display face for big bold titles.
    static func sys(_ size: CGFloat, _ weight: SwiftUI.Font.Weight = .regular, mono: Bool = false) -> SwiftUI.Font {
        if classicLook { return mono ? .system(size: size, weight: weight, design: .monospaced) : .system(size: size, weight: weight) }
        if mono { return theme.font(.mono, size, weight) }
        let heavy = weight == .bold || weight == .heavy || weight == .black
        return theme.font(size >= 20 && heavy ? .display : .text, size, weight)
    }
    /// The same for a text style (.headline, .callout): Classic keeps the text style itself.
    static func sys(_ classic: SwiftUI.Font, _ size: CGFloat, _ weight: SwiftUI.Font.Weight = .regular) -> SwiftUI.Font {
        classicLook ? classic : sys(size, weight)
    }

    enum Font {
        static var caption: SwiftUI.Font { PN.classicLook ? .system(size: 12) : PN.theme.font(.text, 12) }          // minimum size anywhere
        static var body: SwiftUI.Font    { PN.classicLook ? .system(size: 14) : PN.theme.font(.text, 14) }
        static var label: SwiftUI.Font   { PN.classicLook ? .system(size: 11, weight: .semibold) : PN.theme.font(.mono, 11, .semibold) } // UPPERCASE kind labels
        static var section: SwiftUI.Font { PN.classicLook ? .system(size: 13, weight: .semibold) : PN.theme.font(.display, PN.theme.secSize, .heavy) }
        static var title: SwiftUI.Font   { PN.classicLook ? .system(size: 26, weight: .bold) : PN.theme.font(.display, PN.theme.titleSize, .heavy) }
    }
}

// MARK: - Buttons: exactly three levels (critique #11)
// Redesign block 1: the three levels take shape, type and colour from the theme (Classic as before; Roadbook and
// Broadsheet have square corners, a display face, capitals in Roadbook, and text on the accent in `onAccent`).

extension PNTheme {
    /// Text of a button (13 pt semibold system in Classic, the style's display face otherwise).
    var buttonFont: Font { style == .classic ? .system(size: 13, weight: .semibold) : font(.display, bSize, .heavy) }
    var buttonTracking: CGFloat { style == .classic ? 0 : bTrack * bSize }
    var heroFont: Font { style == .classic ? .system(size: 16, weight: .semibold) : font(.display, bigBtn, .heavy) }
    var heroRadius: CGFloat { style == .classic ? 12 : 0 }
    var badgeRadius: CGFloat { style == .classic ? 6 : 0 }
    /// Text on a solid status colour: white in Classic, the dark of the style otherwise.
    var onSolid: Color { style == .classic ? .white : Color(pnHex: dark ? edge : ink) }
}

/// One per window. Bound to Return.
struct PNPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.pnTheme) private var t
    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: t.radiusButton)
        configuration.label
            .font(t.buttonFont).tracking(t.buttonTracking).textCase(t.caps ? .uppercase : nil)
            .foregroundStyle(PN.C.onAccent)
            .padding(.horizontal, 14).frame(height: 32)
            .background(PN.C.accentFill.opacity(configuration.isPressed ? 0.85 : 1))
            .overlay(shape.strokeBorder(t.framedAccent ? PN.C.actEdge : Color.clear, lineWidth: 2))
            .clipShape(shape)
            .contentShape(shape)
            .opacity(isEnabled ? 1 : 0.45)
    }
}

/// Everything secondary: bordered, neutral.
struct PNSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.pnTheme) private var t
    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: t.radiusButton)
        configuration.label
            .font(t.style == .classic ? .system(size: 13) : t.buttonFont).tracking(t.buttonTracking).textCase(t.caps ? .uppercase : nil)
            .foregroundStyle(PN.C.text)
            .padding(.horizontal, 12).frame(height: 32)
            // 0.26.0 (owner 19.11): in Roadbook and Broadsheet a framed button sits on the page's own background (no fill
            // of its own), like Start without prep; only the frame draws it.
            .background(t.style == .classic ? PN.C.surface.opacity(configuration.isPressed ? 0.8 : 1)
                                            : PN.C.text.opacity(configuration.isPressed ? 0.08 : 0))
            .overlay(shape.strokeBorder(t.style == .classic ? Color.primary.opacity(0.18) : PN.C.ruleStrong, lineWidth: t.style == .classic ? 1 : 1.5))
            .clipShape(shape)
            .contentShape(shape)
            .opacity(isEnabled ? 1 : 0.45)
    }
}

/// Inline actions in rows: plain accent text, no background.
struct PNTertiaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.pnTheme) private var t
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(t.style == .classic ? .system(size: 13, weight: .medium) : t.font(.text, 13, .semibold))
            .foregroundStyle(PN.C.accent.opacity(configuration.isPressed ? 0.7 : 1))
            .padding(.horizontal, 6).frame(height: 28)
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.45)
    }
}

extension ButtonStyle where Self == PNPrimaryButtonStyle { static var pnPrimary: PNPrimaryButtonStyle { .init() } }
extension ButtonStyle where Self == PNSecondaryButtonStyle { static var pnSecondary: PNSecondaryButtonStyle { .init() } }
extension ButtonStyle where Self == PNTertiaryButtonStyle { static var pnTertiary: PNTertiaryButtonStyle { .init() } }

// MARK: - Status badge (Home rows, readiness)

struct PNBadge: View {
    enum Kind { case ready, notPrepared, stale, live, neutral }
    let text: String
    let kind: Kind
    @Environment(\.pnTheme) private var t
    var body: some View {
        let on = t.onSolid
        let (fg, bg): (Color, Color) = {
            switch kind {
            // 0.8.5 (owner: "make the greens and oranges bright"): status badges are solid. Classic: white text.
            case .ready:       return (on, t.style == .classic ? Color(red: 0x16/255, green: 0xA3/255, blue: 0x4A/255) : PN.C.ready)
            case .notPrepared: return (on, t.style == .classic ? Color(red: 0xF0/255, green: 0x6E/255, blue: 0x00/255) : PN.C.notready)
            case .stale:       return (on, Color(red: 0xE8/255, green: 0x9B/255, blue: 0x00/255))
            case .live:        return (on, t.style == .classic ? Color(red: 0xFF/255, green: 0x3B/255, blue: 0x30/255) : PN.C.rec)
            case .neutral:     return (PN.C.answer, PN.C.answer.opacity(0.14))
            }
        }()
        Text(t.cased(text)).font(t.style == .classic ? .system(size: 12, weight: .semibold) : t.font(.mono, 11, .semibold))
            .tracking(t.style == .classic ? 0 : t.lblTrack * 11)
            .foregroundStyle(fg).padding(.horizontal, 8).padding(.vertical, 3)
            .background(bg).clipShape(RoundedRectangle(cornerRadius: t.badgeRadius))
    }
}


/// 0.9.0 (mockup "Home"): the one big action of a call card: 48 pt high, accent fill, text in onAccent.
struct PNHeroButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.pnTheme) private var t
    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: t.heroRadius)
        configuration.label
            .font(t.heroFont).tracking(t.style == .classic ? 0 : t.bTrack * t.bigBtn).textCase(t.caps ? .uppercase : nil)
            .foregroundStyle(PN.C.onAccent)
            .padding(.horizontal, 26).frame(height: 48)
            .background(PN.C.accentFill.opacity(enabled ? (configuration.isPressed ? 0.85 : 1) : 0.4), in: shape)
            .overlay(shape.strokeBorder(t.framedAccent ? PN.C.actEdge.opacity(enabled ? 1 : 0.4) : Color.clear, lineWidth: 2))
            .contentShape(shape)
    }
}


// MARK: - Text roles (redesign blocks 4-7)
// A section head, a mono label and a page title: the font plus the style's letter case and tracking
// (Roadbook: capitals with tracking; Broadsheet: section heads in capitals, labels as written; Classic: unchanged).
extension View {
    func pnSection() -> some View { modifier(PNTextRole(role: .section)) }
    func pnLabel() -> some View { modifier(PNTextRole(role: .label)) }
    func pnTitle() -> some View { modifier(PNTextRole(role: .title)) }
}

struct PNTextRole: ViewModifier {
    enum Role { case section, label, title }
    let role: Role
    @Environment(\.pnTheme) private var t
    func body(content: Content) -> some View {
        switch role {
        case .section:
            content.font(PN.Font.section).textCase(t.style == .classic ? nil : .uppercase).tracking(t.secTrack * t.secSize)
        case .label:
            content.font(PN.Font.label).textCase(t.caps ? .uppercase : nil).tracking(t.lblTrack * 11)
        case .title:
            content.font(PN.Font.title).textCase(t.caps ? .uppercase : nil).tracking(t.dTrack * t.titleSize)
        }
    }
}
