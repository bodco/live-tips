import AppKit
import LiveTipsCore

// Pacenote 0.8.5 (rules/presentation.yaml > slide_sync A, app only): while the tips window presents, the current slide
// number is read from a running Keynote or PowerPoint slide show (Automation permission, asked by macOS the first time).
// Nothing is changed in the deck. When neither runs a show, access is refused or the deck is a PDF, the window stays on
// sync B (the recorder follows the PM's speech and asks before moving). Stop following turns A off for this call.

@MainActor
final class SlideSync {
    var stopped = false
    var denied = false
    var last: Int?
    var app: String?

    private static let keynote = "com.apple.iWork.Keynote", powerpoint = "com.microsoft.Powerpoint"

    /// The slide shown now, or nil (no show running, no access, stopped).
    func poll() -> (app: String, n: Int)? {
        guard !stopped, !denied else { return nil }
        for (bid, name, src) in [(Self.keynote, "Keynote", """
            tell application id "com.apple.iWork.Keynote"
              if playing then return slide number of current slide of front document
            end tell
            return 0
            """), (Self.powerpoint, "PowerPoint", """
            tell application id "com.microsoft.Powerpoint"
              if (count of slide show windows) > 0 then return slide index of slide of slide show view of slide show window 1
            end tell
            return 0
            """)] where !NSRunningApplication.runningApplications(withBundleIdentifier: bid).isEmpty {
            var err: NSDictionary?
            let r = NSAppleScript(source: src)?.executeAndReturnError(&err)
            if let e = err, (e[NSAppleScript.errorNumber] as? Int) == -1743 { denied = true; return nil }   // not allowed
            if let n = r.map({ Int($0.int32Value) }), n > 0 { return (name, n) }
        }
        return nil
    }
}

extension PrompterController {
    func pollSlides() {
        guard let r = slideSync.poll() else {
            if slideSync.app != nil { slideSync.app = nil; push("window.LiveTips && LiveTips.setFollow(null)") }
            return
        }
        guard r.n != slideSync.last || slideSync.app != r.app else { return }
        slideSync.last = r.n; slideSync.app = r.app
        // The page moves and tells the recorder (inbox slide = "<n>|keynote" / "<n>|powerpoint").
        push("window.LiveTips && LiveTips.setFollow({app: '\(r.app)', n: \(r.n)})")
    }

    /// The slide thumbnails of the deck read for this call (<stem>.deck.json, the PNGs next to it), once per call.
    func pushThumbs() {
        guard !transcriptPath.isEmpty, thumbsFor != stem else { return }
        guard let d = FileManager.default.contents(atPath: stem + ".deck.json"),
              let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any], let dir = o["dir"] as? String,
              let slides = o["slides"] as? [[String: Any]] else { return }
        thumbsFor = stem
        var map: [String: String] = [:]
        for s in slides {
            guard let n = TalkMerge.num(s) else { continue }
            let p = (dir as NSString).appendingPathComponent(String(format: "%02d.png", n))
            if let png = FileManager.default.contents(atPath: p) { map["\(n)"] = "data:image/png;base64," + png.base64EncodedString() }
        }
        if !map.isEmpty, let j = try? JSONSerialization.data(withJSONObject: map), let js = String(data: j, encoding: .utf8) {
            push("window.LiveTips && LiveTips.setThumbs(" + js + ")")
        }
    }

    /// P5 empty state, Attach presentation during the call: the deck is read and a plain talk (titles, the deck text,
    /// even budgets over the minutes left) is written as <stem>.slides.json; the recorder picks it up by itself.
    /// A full talk needs Prepare (before the next call or with Prepare again).
    func attachDeckLive() {
        guard !transcriptPath.isEmpty else { return }
        let p = NSOpenPanel()
        p.allowedContentTypes = DeckReader.types
        p.message = L("deck.formats")
        guard p.runModal() == .OK, let u = p.url else { return }
        let stem = self.stem
        let left = Self.minutesLeft() ?? 25
        Task { @MainActor in
            do {
                let info = try await DeckReader.read(u.path) { _, _ in }
                let sec = max(30, (left * 60) / max(1, info.slides.count))
                let slides: [[String: Any]] = info.slides.map { s in
                    ["n": s.n, "title": s.title, "who": "me", "sec": sec,
                     "body": s.text.split(separator: "\n").prefix(3).map { ["k": "p", "t": String($0)] }]
                }
                TalkFiles.save(["title": (u.lastPathComponent as NSString).deletingPathExtension, "slides": slides], stem + ".slides.json")
                try? FileManager.default.removeItem(atPath: stem + ".deck.json")
                try? FileManager.default.copyItem(atPath: info.jsonPath, toPath: stem + ".deck.json")
                self.thumbsFor = ""
                self.pushThumbs()
            } catch {
                let js = (try? JSONSerialization.data(withJSONObject: [L("deck.err.generic")])).flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
                self.push("window.toastMsg && window.toastMsg(" + js + "[0])")
            }
        }
    }
}
