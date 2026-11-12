// 0.10.0 (Meeting Sheet, phase 6): the pure part of the Pacenote browser. What a page is (LinkedIn profile, its
// detail page, a company page, any site), the capture plan the user sees before anything opens (one page, or a
// LinkedIn profile plus the detail pages the user ticks), the pause between pages (3-6 s), where a capture is saved
// (<project>/live/sources/<slug>-<yyyyMMdd-HHmmss>.html + .txt), and the contact scrubber: emails and phone numbers
// are never collected. The window itself is LiveTips/PacenoteBrowser.swift; the parsing is the sidecar's
// sheet/linkedin.py and sheet/web.py.
import Foundation

public enum BrowserPageKind: String, Codable, Sendable {
    case linkedinProfile = "linkedin_profile", linkedinDetail = "linkedin_detail", linkedinCompany = "linkedin_company"
    case linkedinOther = "linkedin_other", web
}

public enum BrowserURL {
    /// What the user typed in the address bar: "lumenfield.example" -> https://lumenfield.example. Only http(s).
    public static func fromInput(_ raw: String) -> URL? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, !s.contains(" ") else { return nil }
        let lower = s.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            guard let u = URL(string: s), let h = u.host, !h.isEmpty else { return nil }
            return u
        }
        if lower.contains("://") || lower.hasPrefix("mailto:") || lower.hasPrefix("javascript:") || lower.hasPrefix("file:") { return nil }
        guard s.contains("."), let u = URL(string: "https://" + s), let h = u.host, h.contains(".") else { return nil }
        return u
    }

    public static func isLinkedIn(_ u: URL) -> Bool {
        let h = (u.host ?? "").lowercased()
        return h == "linkedin.com" || h.hasSuffix(".linkedin.com")
    }

    static func segments(_ u: URL) -> [String] { u.path.split(separator: "/").map(String.init) }

    public static func kind(_ u: URL) -> BrowserPageKind {
        guard isLinkedIn(u) else { return .web }
        let seg = segments(u).map { $0.lowercased() }
        if seg.first == "in", seg.count >= 2 { return seg.count >= 4 && seg[2] == "details" ? .linkedinDetail : .linkedinProfile }
        if seg.first == "company" || seg.first == "school" { return .linkedinCompany }
        return .linkedinOther
    }

    /// https://www.linkedin.com/in/<id>/ for a profile or one of its detail pages.
    public static func profileBase(_ u: URL) -> URL? {
        let seg = segments(u)
        guard isLinkedIn(u), seg.count >= 2, seg[0].lowercased() == "in" else { return nil }
        return URL(string: "https://www.linkedin.com/in/\(seg[1])/")
    }

    public static func detailURL(_ profile: URL, section: String) -> URL? {
        guard let b = profileBase(profile) else { return nil }
        return URL(string: b.absoluteString + "details/\(section)/")
    }

    /// File-name part: the LinkedIn id for a profile, else host and path ("lumenfield-example-about").
    public static func slug(_ u: URL) -> String {
        let raw: String
        if let b = profileBase(u) { raw = segments(b)[1] }
        else { raw = ((u.host ?? "page").replacingOccurrences(of: "www.", with: "")) + "-" + u.path }
        var out = ""
        var dash = false
        for ch in raw.lowercased() {
            if (ch >= "a" && ch <= "z") || (ch >= "0" && ch <= "9") { out.append(ch); dash = false }
            else if !dash, !out.isEmpty { out.append("-"); dash = true }
        }
        while out.hasSuffix("-") { out.removeLast() }
        if out.count > 48 { out = String(out.prefix(48)); while out.hasSuffix("-") { out.removeLast() } }
        return out.isEmpty ? "page" : out
    }
}

/// LinkedIn profile sections that have their own detail page, in the order the capture opens them.
public enum LinkedInSection {
    public static let all = ["experience", "education", "skills", "certifications", "languages"]
    public static func title(_ id: String) -> String {
        ["experience": "Experience", "education": "Education", "skills": "Skills", "certifications": "Certifications",
         "languages": "Languages"][id] ?? id.capitalized
    }
}

public struct CaptureStep: Equatable, Sendable {
    public let url: URL
    public let section: String?          // nil = the page itself, else a LinkedIn detail section
    public init(url: URL, section: String?) { self.url = url; self.section = section }
}

/// The plan the user sees before the capture starts. One page for a site; for a LinkedIn profile the profile page and
/// then the detail pages of the sections the user ticked. Nothing else opens.
public struct CapturePlan: Equatable, Sendable {
    public let start: URL
    public let kind: BrowserPageKind
    public let steps: [CaptureStep]
    public static let pauseRange: ClosedRange<Double> = 3...6
    public static let maxScrolls = 40

    public init(start: URL, kind: BrowserPageKind, steps: [CaptureStep]) { self.start = start; self.kind = kind; self.steps = steps }

    public static func make(for url: URL, sections: [String] = LinkedInSection.all) -> CapturePlan {
        let k = BrowserURL.kind(url)
        guard k == .linkedinProfile, let base = BrowserURL.profileBase(url) else {
            return CapturePlan(start: url, kind: k, steps: [CaptureStep(url: url, section: nil)])
        }
        let chosen = LinkedInSection.all.filter { sections.contains($0) }
        var steps = [CaptureStep(url: base, section: nil)]
        for s in chosen { if let d = BrowserURL.detailURL(base, section: s) { steps.append(CaptureStep(url: d, section: s)) } }
        return CapturePlan(start: base, kind: k, steps: steps)
    }

    /// The offer of detail pages applies to a LinkedIn profile only.
    public var offersSections: Bool { kind == .linkedinProfile }
    public var detailSections: [String] { steps.compactMap { $0.section } }

    /// A pause between pages from a 0...1 random value (the app passes Double.random(in: 0...1)).
    public static func pause(_ unit: Double) -> Double {
        let u = min(max(unit, 0), 1)
        return pauseRange.lowerBound + (pauseRange.upperBound - pauseRange.lowerBound) * u
    }

    /// English summary (the window uses i18n keys sheet.browser.plan.*; this one is for logs and checks).
    public var summary: String {
        let d = detailSections
        if d.isEmpty { return "This page: scrolls to the end and opens \"see more\"." }
        let names = d.map(LinkedInSection.title).joined(separator: ", ")
        return "Profile page, then \(d.count) detail page\(d.count == 1 ? "" : "s") (\(names)). Scrolls each to the end and opens \"see more\". Pauses between pages."
    }
}

/// Emails and phone numbers are cut before anything is saved; only the count is kept.
public enum ContactScrubber {
    static let email = try! NSRegularExpression(pattern: "[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}")
    static let phone = try! NSRegularExpression(pattern: "(?<![\\w+])\\+?\\(?\\d(?:[\\d\\s()-]|\\.(?=\\d)){6,}\\d(?!\\w)")
    static let years = try! NSRegularExpression(pattern: "^\\(?\\d{4}\\)?\\s*[-.]?\\s*\\(?\\d{4}\\)?$")

    public static func scrub(_ s: String) -> (text: String, removed: Int) {
        var n = 0
        var out = replace(email, in: s) { _ in n += 1; return "[email removed]" }
        out = replace(phone, in: out) { m in
            let digits = m.filter { $0.isASCII && $0.isNumber }.count
            let trimmed = m.trimmingCharacters(in: .whitespaces)
            if digits < 9 || digits > 15 || years.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)) != nil { return nil }
            n += 1
            return "[phone removed]"
        }
        return (out, n)
    }

    /// The same, applied to the text between tags only, so attributes and markup stay intact.
    public static func scrubHTML(_ html: String) -> (html: String, removed: Int) {
        var out = ""
        var n = 0
        var buf = ""
        var inTag = false
        func flush() { if !buf.isEmpty { let r = scrub(buf); out += r.text; n += r.removed; buf = "" } }
        for ch in html {
            if inTag { out.append(ch); if ch == ">" { inTag = false } }
            else if ch == "<" { flush(); out.append(ch); inTag = true }
            else { buf.append(ch) }
        }
        flush()
        return (out, n)
    }

    static func replace(_ rx: NSRegularExpression, in s: String, with f: (String) -> String?) -> String {
        let ns = s as NSString
        var out = ""
        var last = 0
        for m in rx.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            let found = ns.substring(with: m.range)
            guard let rep = f(found) else { continue }
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last)) + rep
            last = m.range.location + m.range.length
        }
        return out + ns.substring(from: last)
    }
}

public struct CapturedSubpage: Codable, Equatable, Sendable {
    public let url: String
    public let title: String
    public let chars: Int
    public let section: String?
    public init(url: String, title: String, chars: Int, section: String?) { self.url = url; self.title = title; self.chars = chars; self.section = section }
}

/// What the Pacenote browser hands back after "Add this page to sources". The files are already saved.
public struct CapturedPage: Codable, Equatable, Sendable {
    public let url: String
    public let title: String
    public let capturedAt: String          // ISO 8601, UTC
    public let kind: BrowserPageKind
    public let text: String                // visible text, contacts removed
    public let html: String                // cleaned main content, one <article data-pacenote-page> per page
    public let htmlPath: String
    public let textPath: String
    public let pages: [CapturedSubpage]
    public let signedIn: Bool              // a LinkedIn session was open in the window
    public let contactsRemoved: Int

    enum CodingKeys: String, CodingKey {
        case url, title, kind, text, html, pages
        case capturedAt = "captured_at", htmlPath = "html_path", textPath = "text_path", signedIn = "signed_in", contactsRemoved = "contacts_removed"
    }

    public init(url: String, title: String, capturedAt: String, kind: BrowserPageKind, text: String, html: String, htmlPath: String,
                textPath: String, pages: [CapturedSubpage], signedIn: Bool, contactsRemoved: Int) {
        self.url = url; self.title = title; self.capturedAt = capturedAt; self.kind = kind; self.text = text; self.html = html
        self.htmlPath = htmlPath; self.textPath = textPath; self.pages = pages; self.signedIn = signedIn; self.contactsRemoved = contactsRemoved
    }

    /// The source the sidecar's `webfetch` takes in its `captured` list.
    public var sidecarItem: [String: String] { ["html": htmlPath, "txt": textPath, "url": url, "title": title, "captured_at": capturedAt] }
}

/// One page as read by the capture script, before it is saved.
public struct CapturedPart: Equatable, Sendable {
    public let url: String
    public let title: String
    public let html: String
    public let text: String
    public let section: String?
    public init(url: String, title: String, html: String, text: String, section: String?) {
        self.url = url; self.title = title; self.html = html; self.text = text; self.section = section
    }
}

public enum CaptureFiles {
    public static func folder(live: URL) -> URL { live.appendingPathComponent("sources", isDirectory: true) }

    public static func stamp(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: d)
    }

    public static func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: d)
    }

    public static func base(for url: URL, at d: Date) -> String { BrowserURL.slug(url) + "-" + stamp(d) }

    static func attr(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Builds the page from its parts (contacts removed) and the text file. Pure: the window writes the strings.
    public static func assemble(start: URL, kind: BrowserPageKind, parts: [CapturedPart], signedIn: Bool, at d: Date,
                                folder: URL) -> (page: CapturedPage, htmlDoc: String, textDoc: String) {
        let base = base(for: start, at: d)
        let htmlPath = folder.appendingPathComponent(base + ".html").path
        let textPath = folder.appendingPathComponent(base + ".txt").path
        var removed = 0
        var body = ""
        var text = ""
        var pages: [CapturedSubpage] = []
        for p in parts {
            let h = ContactScrubber.scrubHTML(p.html)
            let t = ContactScrubber.scrub(p.text)
            removed += t.removed
            body += "<article data-pacenote-page=\"\(attr(p.url))\" data-pacenote-title=\"\(attr(p.title))\""
                + (p.section.map { " data-pacenote-section=\"\(attr($0))\"" } ?? "") + ">\n" + h.html + "\n</article>\n"
            text += (text.isEmpty ? "" : "\n\n") + "=== \(p.title) (\(p.url))\n" + t.text
            pages.append(CapturedSubpage(url: p.url, title: p.title, chars: t.text.count, section: p.section))
        }
        let title = parts.first?.title ?? start.absoluteString
        let when = iso(d)
        let doc = """
        <!doctype html>
        <html><head><meta charset="utf-8"><title>\(attr(title))</title>
        <meta name="pacenote:url" content="\(attr(start.absoluteString))">
        <meta name="pacenote:captured_at" content="\(when)">
        <meta name="pacenote:kind" content="\(kind.rawValue)">
        <meta name="pacenote:pages" content="\(parts.count)">
        <meta name="pacenote:session" content="\(signedIn ? "signed_in" : "none")">
        </head><body>
        \(body)</body></html>

        """
        let textDoc = "\(title)\n\(start.absoluteString)\nCaptured \(when) in the Pacenote browser\n\n\(text)\n"
        let page = CapturedPage(url: start.absoluteString, title: title, capturedAt: when, kind: kind, text: text, html: doc,
                                htmlPath: htmlPath, textPath: textPath, pages: pages, signedIn: signedIn, contactsRemoved: removed)
        return (page, doc, textDoc)
    }
}
