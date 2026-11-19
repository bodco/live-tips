import Foundation
import CoreGraphics

/// Theme pass stage 4 (owner, 19.11): the compact tip card opens under the camera on every call. The top centre of the
/// built-in display (below the notch by its safe area, or below the menu bar without a notch); without a built-in
/// display, the main one. The card can be dragged, but its place is not remembered. Kept here so CoreChecks covers it.
public struct TipCardScreen: Equatable {
    public var frame: CGRect          // the whole display, in global screen coordinates (origin bottom left)
    public var visible: CGRect        // the display without the menu bar and the Dock
    public var safeTop: CGFloat       // the notch's height (NSScreen.safeAreaInsets.top), 0 without a notch
    public var builtin: Bool
    public var main: Bool
    public init(frame: CGRect, visible: CGRect, safeTop: CGFloat = 0, builtin: Bool = false, main: Bool = false) {
        self.frame = frame; self.visible = visible; self.safeTop = safeTop; self.builtin = builtin; self.main = main
    }
}

public enum TipCardPlacement {
    public static let width: CGFloat = 480       // the prototype's card ("During the call", Compact)
    public static let gap: CGFloat = 6           // below the camera line
    public static let minHeight: CGFloat = 96
    public static let maxShare: CGFloat = 0.6    // at most this part of the visible height

    /// The built-in display, else the main one, else the first.
    public static func pick(_ screens: [TipCardScreen]) -> TipCardScreen? {
        screens.first { $0.builtin } ?? screens.first { $0.main } ?? screens.first
    }

    /// The top edge the card hangs from: below the notch, else the top of the visible frame (below the menu bar).
    public static func topLine(_ s: TipCardScreen) -> CGFloat {
        let below = s.safeTop > 0 ? s.frame.maxY - s.safeTop : s.visible.maxY
        return min(below, s.visible.maxY) - gap
    }

    public static func clampHeight(_ h: CGFloat, _ s: TipCardScreen) -> CGFloat {
        let cap = max(minHeight, (s.visible.height * maxShare).rounded(.down))
        return min(max(h.rounded(.up), minHeight), cap)
    }

    /// The card's frame on a new call: centred on the display (the camera), hanging from topLine.
    public static func frame(on s: TipCardScreen, height: CGFloat, width: CGFloat = width) -> CGRect {
        let w = min(width, s.visible.width - gap * 2)
        let h = clampHeight(height, s)
        var x = (s.frame.midX - w / 2).rounded()
        x = min(max(x, s.visible.minX + gap), s.visible.maxX - gap - w)
        return CGRect(x: x, y: topLine(s) - h, width: w, height: h)
    }

    /// The page reported a new content height: the top edge stays where it is (the card may have been dragged),
    /// the card grows or shrinks downwards and stays on the visible frame.
    public static func resized(_ f: CGRect, height: CGFloat, on s: TipCardScreen) -> CGRect {
        let h = clampHeight(height, s)
        var y = f.maxY - h
        if y < s.visible.minY { y = s.visible.minY }
        return CGRect(x: f.minX, y: y, width: f.width, height: h)
    }
}

/// 0.26.0 (B, owner 19.11): the tips window that replaces the card (Expand, the end of a call) opens on the card's
/// display, not on the main one. Size: the saved frame's, else the default, never larger than the visible frame.
/// Place: the saved one only when it is on the card's display (its centre is there), otherwise top centre of it.
public enum ExpandedWindowPlacement {
    public static let gap: CGFloat = 6

    public static func frame(saved: CGRect?, defaultSize: CGSize, on s: TipCardScreen) -> CGRect {
        let v = s.visible
        var size = saved?.size ?? defaultSize
        size.width = min(size.width, v.width); size.height = min(size.height, v.height)
        if let saved, s.frame.contains(CGPoint(x: saved.midX, y: saved.midY)) {
            var f = CGRect(origin: saved.origin, size: size)
            f.origin.x = min(max(f.minX, v.minX), v.maxX - f.width)
            f.origin.y = min(max(f.minY, v.minY), v.maxY - f.height)
            return f
        }
        let x = (v.midX - size.width / 2).rounded()
        let y = max(v.minY, v.maxY - size.height - gap)
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }
}
