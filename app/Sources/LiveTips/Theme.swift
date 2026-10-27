import AppKit
import SwiftUI

/// One look for every window (2026-10-26, owner: "the same design as the welcome tour"): an icon tile and a
/// title on top, soft rounded cards without borders, one big blue capsule button for the main action.
enum LT {
    static let radius: CGFloat = 10
    static let cardFill = Color.secondary.opacity(0.08)
    static let tileFill = Color.secondary.opacity(0.12)
}

/// The rounded square with a symbol (or an app's own icon) used by the tour, the window headers and the sidebar.
struct IconTile: View {
    var symbol: String
    var image: NSImage? = nil
    var size: CGFloat = 64
    var tint: Color = .accentColor

    var body: some View {
        if let image = image {
            Image(nsImage: image).resizable().interpolation(.high).frame(width: size, height: size)
        } else {
            Image(systemName: symbol)
                .font(.system(size: size * 0.5, weight: .regular))
                .foregroundStyle(tint)
                .frame(width: size, height: size)
                .background(RoundedRectangle(cornerRadius: size * 0.25).fill(LT.tileFill))
        }
    }
}

/// Window header: centered like the tour, or compact (tile on the left) for working windows.
struct WindowHeader: View {
    var symbol: String
    var title: String
    var subtitle: String = ""
    var image: NSImage? = nil
    var compact = true

    var body: some View {
        if compact {
            HStack(alignment: .center, spacing: 14) {
                IconTile(symbol: symbol, image: image, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.title2.weight(.semibold))
                    if !subtitle.isEmpty {
                        Text(subtitle).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
        } else {
            VStack(spacing: 14) {
                IconTile(symbol: symbol, image: image)
                Text(title).font(.title.weight(.semibold)).multilineTextAlignment(.center)
                if !subtitle.isEmpty {
                    Text(subtitle).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 520)
                }
            }
        }
    }
}

struct LTCard: ViewModifier {
    var padding: CGFloat = 12
    func body(content: Content) -> some View {
        content.padding(padding).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: LT.radius).fill(LT.cardFill))
    }
}

extension View {
    func ltCard(padding: CGFloat = 12) -> some View { modifier(LTCard(padding: padding)) }
}

/// The main action of a window: blue, large, a capsule, with an arrow like Continue in the tour.
struct LTPrimaryButton: View {
    var title: String
    var symbol: String? = "arrow.right"
    var minWidth: CGFloat = 220
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title)
                if let s = symbol { Image(systemName: s) }
            }
            .frame(minWidth: minWidth)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .controlSize(.large)
    }
}

/// A secondary action: accent text on a soft accent fill (2026-10-27, owner: clickable things get color).
struct LTSoftButtonStyle: ButtonStyle {
    var small = false
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(small ? .callout : .body)
            .padding(.horizontal, small ? 10 : 12).padding(.vertical, small ? 4 : 6)
            .foregroundStyle(enabled ? Color.accentColor : Color.secondary)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(configuration.isPressed ? 0.25 : (enabled ? 0.15 : 0.06))))
            .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}
