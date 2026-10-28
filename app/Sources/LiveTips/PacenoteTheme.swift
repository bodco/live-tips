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
    enum C {
        static let bg        = Color.pn(0xF5F5F7, 0x1E1E20)
        static let surface   = Color.pn(0xFFFFFF, 0x2C2C2E)
        static let surface2  = Color.pn(0xEEEEF1, 0x3A3A3C)
        static let text      = Color.pn(0x1D1D1F, 0xF5F5F7)
        static let text2     = Color.pn(0x3A3A3C, 0xC7C7CC)
        static let text3     = Color.pn(0x6E6E73, 0x98989D) // captions, never lighter
        static let accent    = Color.pn(0x0058B0, 0x4D9DFF) // Blue Deep / Blue Light: links, accent text (AA)
        static let accentFill = Color(red: 0x0A/255, green: 0x6C/255, blue: 0xFF/255) // Pacenote Blue: buttons, white text 4.6:1
        static let brand     = Color.pn(0x0A6CFF, 0x4D9DFF) // the mark's start dot, progress, selection
        static let ink       = Color(red: 0x1C/255, green: 0x1D/255, blue: 0x21/255)
        static let rec       = Color.pn(0xFF3B30, 0xFF453A)

        // Status / card kinds (text color). Soft backgrounds: same hue at 14-16% opacity in dark.
        static let answer    = Color.pn(0x0058B0, 0x64B5FF)
        static let turn      = Color.pn(0x1A7431, 0x4CD964)
        static let onMe      = Color.pn(0x9A4600, 0xFFB340)
        static let docs      = Color.pn(0x7D3C9E, 0xD29BF5)
        static let danger    = Color.pn(0xC4000F, 0xFF6961)
    }

    enum Radius { static let s: CGFloat = 6; static let m: CGFloat = 10; static let l: CGFloat = 14 }
    enum Space  { static let x1: CGFloat = 4; static let x2: CGFloat = 8; static let x3: CGFloat = 12
                  static let x4: CGFloat = 16; static let x5: CGFloat = 20; static let x6: CGFloat = 24 }

    enum Font {
        static let caption = SwiftUI.Font.system(size: 12)          // minimum size anywhere
        static let body    = SwiftUI.Font.system(size: 14)
        static let label   = SwiftUI.Font.system(size: 11, weight: .semibold) // UPPERCASE kind labels
        static let section = SwiftUI.Font.system(size: 13, weight: .semibold)
        static let title   = SwiftUI.Font.system(size: 26, weight: .bold)
    }
}

// MARK: - Buttons: exactly three levels (critique #11)

/// One per window. Bound to Return.
struct PNPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14).frame(height: 32)
            .background(PN.C.accentFill.opacity(configuration.isPressed ? 0.85 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .contentShape(RoundedRectangle(cornerRadius: 7))
            .opacity(isEnabled ? 1 : 0.45)
    }
}

/// Everything secondary: bordered, neutral.
struct PNSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13))
            .foregroundStyle(PN.C.text)
            .padding(.horizontal, 12).frame(height: 32)
            .background(PN.C.surface.opacity(configuration.isPressed ? 0.8 : 1))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.primary.opacity(0.18)))
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .contentShape(RoundedRectangle(cornerRadius: 7))
            .opacity(isEnabled ? 1 : 0.45)
    }
}

/// Inline actions in rows: plain accent text, no background.
struct PNTertiaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
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
    var body: some View {
        let (fg, bg): (Color, Color) = {
            switch kind {
            case .ready:       return (PN.C.turn, PN.C.turn.opacity(0.14))
            case .notPrepared: return (PN.C.onMe, PN.C.onMe.opacity(0.14))
            case .stale:       return (PN.C.text2, PN.C.surface2)
            case .live:        return (PN.C.danger, PN.C.danger.opacity(0.14))
            case .neutral:     return (PN.C.answer, PN.C.answer.opacity(0.14))
            }
        }()
        Text(text).font(.system(size: 12, weight: .semibold))
            .foregroundStyle(fg).padding(.horizontal, 8).padding(.vertical, 3)
            .background(bg).clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
