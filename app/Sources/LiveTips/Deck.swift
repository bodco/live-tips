import AppKit
import CryptoKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers
import LiveTipsCore

// Pacenote 0.8.5 (PRESENTATION-SPEC P1, P2; rules/presentation.yaml): the deck attached to a Presentation call.
// The deck is read once when attached (text and a thumbnail per slide) into Application Support/LiveTips/decks/<id>/;
// Prepare gets the slide texts and writes <base>.slides.json, the app then sets who presents each slide from the
// owners chosen here. Nothing about the deck is sent anywhere but to Prepare.

struct DeckSlide: Codable, Hashable { var n: Int; var title: String; var text: String }

struct DeckInfo: Codable, Equatable {
    var file: String
    var format: String            // PDF | PowerPoint | Keynote | Text
    var slides: [DeckSlide]
    var readAt: Date
    var dir: String               // where deck.json and the thumbnails (NN.png) are
    func thumb(_ n: Int) -> String { (dir as NSString).appendingPathComponent(String(format: "%02d.png", n)) }
    var jsonPath: String { (dir as NSString).appendingPathComponent("deck.json") }
    var texts: [Int: String] { Dictionary(uniqueKeysWithValues: slides.map { ($0.n, $0.title + "\n" + $0.text) }) }
}

/// What the Presentation block holds for one call (saved with Up next).
struct DeckSetup: Codable, Equatable {
    enum Phase: Equatable, Codable { case none, reading(Int, Int), ready, failed(String) }
    var path: String?
    var info: DeckInfo?
    var phase: Phase = .none
    var speakers: [String] = []            // colleagues who present; the PM is always "Me"
    var owners: [Int: String] = [:]        // slide -> "me" | "all" | a speaker; missing = me
    var duration = 30                      // minutes
    var durationFromCalendar = true
    var qaOn = true
    var qaMin = 5
    var keepEdits = true                   // Prepare again: rules/presentation.yaml > prepare_again.default

    var count: Int { info?.slides.count ?? 0 }
    var talkMin: Int { TalkTime.talkMinutes(duration: duration, qa: qaMin, qaOn: qaOn) }
    func owner(_ n: Int) -> String { owners[n] ?? DeckOwners.me }

    /// "All: 1, 14 · Me: 2-4, 10-13 · Ann: 5-9"
    var summary: String {
        var by: [String: [Int]] = [:], order: [String] = []
        for n in stride(from: 1, through: count, by: 1) {
            let o = owner(n)
            if by[o] == nil { order.append(o) }
            by[o, default: []].append(n)
        }
        return order.map { "\(Self.label($0)): \(TalkMerge.list(by[$0]!))" }.joined(separator: " · ")
    }
    static func label(_ o: String) -> String { o == DeckOwners.me ? L("deck.me") : o == DeckOwners.all ? L("deck.all") : o }

    /// The slides.json top level and per-slide owners (rules/presentation.yaml > slides_json).
    func apply(to slides: [[String: Any]]) -> [[String: Any]] {
        slides.map { s in
            var m = s
            if let n = TalkMerge.num(s) { let w = DeckOwners.who(owner(n)); m["who"] = w.who; m["speaker"] = w.speaker }
            return m
        }
    }
}

enum DeckError: Error { case unreadable(String), needsKeynote, empty }

enum DeckReader {
    static let types: [UTType] = [.pdf, .plainText, .text] + ["pptx", "key", "md"].compactMap { UTType(filenameExtension: $0) }
    static var keynoteInstalled: Bool { NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iWork.Keynote") != nil }

    static func format(_ path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "pdf": return "PDF"
        case "pptx", "ppt": return "PowerPoint"
        case "key": return "Keynote"
        default: return L("deck.formatText")
        }
    }

    /// Reads the deck into decks/<id>/; progress(i, n) on the main actor. Throws DeckError.
    static func read(_ path: String, progress: @escaping @MainActor (Int, Int) -> Void) async throws -> DeckInfo {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let stamp = "\(path)|\((attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)|\(attrs?[.size] ?? 0)"
        let id = Insecure.SHA1.hash(data: Data(stamp.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16)
        let dir = AppPaths.support.appendingPathComponent("decks/\(id)").path
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let ext = (path as NSString).pathExtension.lowercased()
        var slides: [DeckSlide] = []
        switch ext {
        case "pdf":
            slides = try await readPDF(path, dir: dir, progress: progress)
        case "pptx":
            slides = try pptxText(path)
            // Thumbnails through Keynote when it is installed; the text alone is enough for Prepare.
            if keynoteInstalled, let pdf = exportWithKeynote(path, dir: dir) { _ = try? await readPDF(pdf, dir: dir, progress: progress) }
        case "key":
            guard keynoteInstalled else { throw DeckError.needsKeynote }
            guard let pdf = exportWithKeynote(path, dir: dir) else { throw DeckError.unreadable(path) }
            slides = try await readPDF(pdf, dir: dir, progress: progress)
        default:
            guard let t = try? String(contentsOfFile: path, encoding: .utf8) else { throw DeckError.unreadable(path) }
            slides = outline(t)
        }
        guard !slides.isEmpty else { throw DeckError.empty }
        let info = DeckInfo(file: path, format: format(path), slides: slides, readAt: Date(), dir: dir)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted]; enc.dateEncodingStrategy = .iso8601
        try? enc.encode(info).write(to: URL(fileURLWithPath: info.jsonPath))
        return info
    }

    static func readPDF(_ path: String, dir: String, progress: @escaping @MainActor (Int, Int) -> Void) async throws -> [DeckSlide] {
        guard let doc = PDFDocument(url: URL(fileURLWithPath: path)) else { throw DeckError.unreadable(path) }
        var out: [DeckSlide] = []
        for i in 0..<doc.pageCount {
            await progress(i + 1, doc.pageCount)
            guard let page = doc.page(at: i) else { continue }
            let text = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            out.append(DeckSlide(n: i + 1, title: String((lines.first ?? "").prefix(120)), text: lines.dropFirst().joined(separator: "\n")))
            let img = page.thumbnail(of: NSSize(width: 320, height: 200), for: .cropBox)
            if let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: (dir as NSString).appendingPathComponent(String(format: "%02d.png", i + 1))))
            }
        }
        return out
    }

    /// PowerPoint text without PowerPoint: the slide XML inside the .pptx (a zip).
    static func pptxText(_ path: String) throws -> [DeckSlide] {
        func unzip(_ args: [String]) -> String {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip"); p.arguments = args
            let o = Pipe(); p.standardOutput = o; p.standardError = Pipe()
            guard (try? p.run()) != nil else { return "" }
            let d = o.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
            return String(data: d, encoding: .utf8) ?? ""
        }
        func num(_ s: String) -> Int { Int(s.filter { $0.isNumber }) ?? 0 }
        let all: [String] = unzip(["-Z1", path]).split(separator: "\n").map { String($0) }
        let found: [String] = all.filter { $0.range(of: "^ppt/slides/slide[0-9]+\\.xml$", options: .regularExpression) != nil }
        let names: [String] = found.sorted { num($0) < num($1) }
        guard !names.isEmpty else { throw DeckError.unreadable(path) }
        return names.enumerated().map { i, name in
            let xml = unzip(["-p", path, name])
            let paras = xml.components(separatedBy: "</a:p>").map { p -> String in
                var t = "", rest = Substring(p)
                while let a = rest.range(of: "<a:t>"), let b = rest[a.upperBound...].range(of: "</a:t>") {
                    t += rest[a.upperBound..<b.lowerBound]; rest = rest[b.upperBound...]
                }
                return t.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&lt;", with: "<")
                    .replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&quot;", with: "\"").trimmingCharacters(in: .whitespaces)
            }.filter { !$0.isEmpty }
            return DeckSlide(n: i + 1, title: String((paras.first ?? "").prefix(120)), text: paras.dropFirst().joined(separator: "\n"))
        }
    }

    /// Keynote opens .key and .pptx and exports a PDF (Automation permission is asked the first time).
    static func exportWithKeynote(_ path: String, dir: String) -> String? {
        let out = (dir as NSString).appendingPathComponent("deck.pdf")
        try? FileManager.default.removeItem(atPath: out)
        let esc = { (s: String) in s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
        let src = """
        tell application "Keynote"
          set d to open POSIX file "\(esc(path))"
          export d to POSIX file "\(esc(out))" as PDF
          close d saving no
        end tell
        """
        var err: NSDictionary?
        _ = NSAppleScript(source: src)?.executeAndReturnError(&err)
        return FileManager.default.fileExists(atPath: out) ? out : nil
    }

    /// A text outline or a pasted talk: "# Title" / "## Title" / "Slide 3: Title" lines or "---" start a slide;
    /// without any of them, blank lines do.
    static func outline(_ text: String) -> [DeckSlide] {
        let lines = text.components(separatedBy: .newlines)
        let head = "^(#{1,3}\\s+|(slide|слайд)\\s*[0-9]+[:.)]?\\s*)"
        let marked = lines.contains { $0.range(of: head, options: [.regularExpression, .caseInsensitive]) != nil || $0.trimmingCharacters(in: .whitespaces) == "---" }
        var blocks: [[String]] = [], cur: [String] = []
        for l in lines {
            let t = l.trimmingCharacters(in: .whitespaces)
            let starts = marked ? (t == "---" || t.range(of: head, options: [.regularExpression, .caseInsensitive]) != nil) : t.isEmpty
            if starts { if !cur.isEmpty { blocks.append(cur) }; cur = [] }
            if t == "---" || t.isEmpty { continue }
            cur.append(t.replacingOccurrences(of: head, with: "", options: [.regularExpression, .caseInsensitive]))
        }
        if !cur.isEmpty { blocks.append(cur) }
        return blocks.enumerated().map { DeckSlide(n: $0.offset + 1, title: String($0.element[0].prefix(120)), text: $0.element.dropFirst().joined(separator: "\n")) }
    }
}

extension StartCallModel {
    /// Attach (or replace) the deck: read it in the background, the form stays usable (P2 C).
    func attachDeck(_ path: String) {
        deck.path = path; deck.info = nil; deck.phase = .reading(0, 0)
        let me = self
        Task {
            do {
                let info = try await DeckReader.read(path) { i, n in if me.deck.path == path { me.deck.phase = .reading(i, n) } }
                guard me.deck.path == path else { return }
                me.deck.info = info
                me.deck.owners = me.deck.owners.filter { $0.key <= info.slides.count }
                me.deck.phase = .ready
            } catch DeckError.needsKeynote {
                if me.deck.path == path { me.deck.phase = .failed(L("deck.err.keynote")) }
            } catch {
                if me.deck.path == path { me.deck.phase = .failed(L("deck.err.generic")) }
            }
            UpNext.shared.touch(me)
        }
    }

    func pickDeck() {
        let p = NSOpenPanel()
        p.allowedContentTypes = DeckReader.types
        p.canChooseDirectories = false
        p.message = L("deck.formats")
        guard p.runModal() == .OK, let u = p.url else { return }
        attachDeck(u.path)
    }

    /// "Paste the talk as text": saved as a text outline next to the decks and read like one.
    func pasteTalk(_ text: String) {
        let dir = AppPaths.support.appendingPathComponent("decks/pasted")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = dir.appendingPathComponent("\(StartCallModel.slugify(effectiveTitle))-\(Int(Date().timeIntervalSince1970)).md")
        try? text.write(to: f, atomically: true, encoding: .utf8)
        attachDeck(f.path)
    }

    /// The call's length from its calendar event, when there is one.
    var calendarMinutes: Int? {
        guard let id = calEventID, let e = CalendarService.shared.event(id) else { return nil }
        return max(5, Int(e.end.timeIntervalSince(e.start) / 60))
    }
    var calendarApp: String? {
        guard let id = calEventID, let e = CalendarService.shared.event(id) else { return nil }
        if let l = e.link { return l.contains("zoom") ? "Zoom" : l.contains("teams") ? "Teams" : "Google Meet" }
        return e.calendar
    }
}

// MARK: - The Presentation block (P2: not attached, reading, attached, error)

struct DeckBlock: View {
    @ObservedObject var model: StartCallModel
    @State private var newSpeaker = ""
    @State private var adding = false
    @State private var assign = ""
    @State private var assignNote = ""
    @State private var pasting = false
    @State private var pasted = ""
    @State private var dropping = false

    private var d: DeckSetup { model.deck }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L("deck.title")).font(PN.Font.section).foregroundStyle(PN.C.text)
                if d.phase == .ready { Text(L("deck.ready")).font(PN.Font.caption).foregroundStyle(PN.C.turn) }
                Spacer()
            }
            switch d.phase {
            case .none: notAttached
            case .reading(let i, let n): reading(i, n)
            case .failed(let why): failed(why)
            case .ready: attached
            }
        }
        .padding(14)
        .background(PN.C.surface, in: RoundedRectangle(cornerRadius: PN.Radius.m))
        .overlay(RoundedRectangle(cornerRadius: PN.Radius.m).stroke(dropping ? PN.C.accent : Color.primary.opacity(0.10), lineWidth: dropping ? 2 : 1))
        .onDrop(of: [.fileURL], isTargeted: $dropping) { items in
            guard let item = items.first else { return false }
            _ = item.loadObject(ofClass: URL.self) { url, _ in
                if let u = url { DispatchQueue.main.async { model.attachDeck(u.path) } }
            }
            return true
        }
        .sheet(isPresented: $pasting) { pasteSheet }
    }

    private var fileName: String { ((d.path ?? "") as NSString).lastPathComponent }

    private var notAttached: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { model.pickDeck() } label: { Label(L("deck.attach"), systemImage: "paperclip") }.buttonStyle(.pnSecondary)
            Text(L("deck.formats")).font(PN.Font.caption).foregroundStyle(PN.C.text3)
            Text(L("deck.promise")).font(PN.Font.caption).foregroundStyle(PN.C.text2).fixedSize(horizontal: false, vertical: true)
            Button(L("deck.pasteText")) { pasting = true }.buttonStyle(.pnTertiary)
        }
    }

    private func reading(_ i: Int, _ n: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "doc.richtext").foregroundStyle(PN.C.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(fileName).font(PN.Font.body.weight(.medium)).lineLimit(1)
                    Text(n > 0 ? L("deck.reading", ["i": "\(i)", "n": "\(n)"]) : L("deck.readingStart")).font(PN.Font.caption).foregroundStyle(PN.C.text3)
                }
                Spacer()
                Button(L("common.cancel")) { model.deck = DeckSetup(speakers: d.speakers, duration: d.duration, durationFromCalendar: d.durationFromCalendar, qaOn: d.qaOn, qaMin: d.qaMin) }
                    .buttonStyle(.pnTertiary)
            }
            if n > 0 { ProgressView(value: Double(i), total: Double(n)) } else { ProgressView().controlSize(.small) }
            Text(L("deck.readingHint")).font(PN.Font.caption).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func failed(_ why: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.circle").foregroundStyle(PN.C.rec)
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("deck.err.title", ["file": fileName])).font(PN.Font.body.weight(.medium))
                    Text(why).font(PN.Font.caption).foregroundStyle(PN.C.text2).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 10) {
                Button(L("deck.err.choose")) { model.pickDeck() }.buttonStyle(.pnSecondary)
                Button(L("deck.pasteText")) { pasting = true }.buttonStyle(.pnTertiary)
            }
        }
    }

    private var attached: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "doc.richtext").foregroundStyle(PN.C.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(fileName).font(PN.Font.body.weight(.medium)).lineLimit(1)
                    Text(L("deck.meta", ["n": "\(d.count)", "format": d.info?.format ?? "",
                                         "time": RelativeDateTimeFormatter().localizedString(for: d.info?.readAt ?? Date(), relativeTo: Date())]))
                        .font(PN.Font.caption).foregroundStyle(PN.C.text3)
                }
                Spacer()
                Button(L("deck.replace")) { model.pickDeck() }.buttonStyle(.pnTertiary)
                Button(L("deck.remove")) { model.deck = DeckSetup(speakers: d.speakers, duration: d.duration, durationFromCalendar: d.durationFromCalendar, qaOn: d.qaOn, qaMin: d.qaMin) }
                    .buttonStyle(.pnTertiary)
            }
            Text(L("deck.promise")).font(PN.Font.caption).foregroundStyle(PN.C.text2).fixedSize(horizontal: false, vertical: true)
            speakers
            owners
            timing
            rehearsalRow
        }
    }

    /// 0.8.5 (P6, entry 3): the last rehearsal, so the PM sees if one more run is worth it.
    @ViewBuilder private var rehearsalRow: some View {
        if let path = PrepDocWindow.path(for: model), TalkWindow.available(base: String(path.dropLast(9))) {
            let base = String(path.dropLast(9)), e = RehearsalWindow.entryLine(base: base)
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(e.title).font(PN.Font.caption).foregroundStyle(PN.C.text2)
                    if !e.sub.isEmpty { Text(e.sub).font(PN.Font.caption).foregroundStyle(PN.C.text3) }
                }
                Spacer()
                Button(RehearsalWindow.last(base: base) == nil ? L("rehearse.button") : L("reh.again")) {
                    RehearsalWindow.show(base: base, title: model.effectiveTitle, call: model)
                }.buttonStyle(.pnTertiary)
            }
        }
    }

    private var speakers: some View {
        VStack(alignment: .leading, spacing: 6) {
            label(L("deck.speakers"))
            HStack(spacing: 6) {
                pill(L("deck.me"), removable: false) {}
                ForEach(d.speakers, id: \.self) { s in pill(s, removable: true) { model.deck.speakers.removeAll { $0 == s }; model.deck.owners = model.deck.owners.filter { $0.value != s } } }
                if adding {
                    TextField("", text: $newSpeaker, prompt: Text(L("deck.speakerName"))).textFieldStyle(.roundedBorder).frame(width: 140)
                        .onSubmit { addSpeaker() }
                } else {
                    Menu {
                        ForEach(model.participants.filter { !d.speakers.contains($0) }, id: \.self) { p in Button(p) { model.deck.speakers.append(p) } }
                        Button(L("deck.otherName")) { adding = true }
                    } label: { Label(L("deck.addSpeaker"), systemImage: "plus") }
                    .menuStyle(.borderlessButton).fixedSize()
                }
            }
        }
    }

    private func addSpeaker() {
        let n = newSpeaker.trimmingCharacters(in: .whitespaces)
        if !n.isEmpty && !d.speakers.contains(n) { model.deck.speakers.append(n) }
        newSpeaker = ""; adding = false
    }

    private func pill(_ s: String, removable: Bool, remove: @escaping () -> Void) -> some View {
        HStack(spacing: 4) {
            Text(s)
            if removable { Button(action: remove) { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel(L("call.remove")) }
        }
        .font(PN.Font.caption).padding(.horizontal, 8).padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: PN.Radius.s).fill(PN.C.accent.opacity(0.12)))
        .foregroundStyle(PN.C.accent)
    }

    private var choices: [String] { [DeckOwners.me] + d.speakers + [DeckOwners.all] }

    private var owners: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                label(L("deck.owners"))
                Text(L("deck.ownersHint")).font(PN.Font.caption).foregroundStyle(PN.C.text3)
            }
            ScrollView(.horizontal, showsIndicators: true) {
                HStack(spacing: 6) {
                    ForEach(1...max(1, d.count), id: \.self) { n in slideChip(n) }
                }
                .padding(.bottom, 4)
            }
            HStack(spacing: 8) {
                Text(L("deck.assign")).font(PN.Font.caption).foregroundStyle(PN.C.text2)
                TextField("", text: $assign, prompt: Text(d.speakers.first.map { "5-9 \($0.split(separator: " ").first ?? "")" } ?? "10-13 me"))
                    .textFieldStyle(.roundedBorder).frame(width: 180).onSubmit { applyAssign() }
                Button(L("deck.apply")) { applyAssign() }.buttonStyle(.pnSecondary).disabled(assign.isEmpty)
                Text(assignNote.isEmpty ? L("deck.assignExamples") : assignNote).font(PN.Font.caption).foregroundStyle(assignNote.isEmpty ? PN.C.text3 : PN.C.onMe)
            }
            Text(L("deck.allHint", ["name": d.speakers.first ?? L("deck.colleague")])).font(PN.Font.caption).foregroundStyle(PN.C.text3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func applyAssign() {
        guard let r = DeckOwners.parse(assign, speakers: d.speakers, count: d.count) else { assignNote = L("deck.assignUnknown"); return }
        if r.owner != DeckOwners.me && r.owner != DeckOwners.all && !d.speakers.contains(r.owner) { model.deck.speakers.append(r.owner) }
        for n in r.slides { model.deck.owners[n] = r.owner }
        assign = ""; assignNote = ""
    }

    private func slideChip(_ n: Int) -> some View {
        let o = d.owner(n)
        let tint = o == DeckOwners.me ? PN.C.accent : o == DeckOwners.all ? PN.C.turn : PN.C.text3
        return Button {
            let i = choices.firstIndex(of: o) ?? 0
            model.deck.owners[n] = choices[(i + 1) % choices.count]
        } label: {
            VStack(spacing: 3) {
                ZStack(alignment: .topLeading) {
                    if let info = d.info, let img = NSImage(contentsOfFile: info.thumb(n)) {
                        Image(nsImage: img).resizable().aspectRatio(16 / 10, contentMode: .fill).frame(width: 64, height: 40).clipped()
                    } else {
                        RoundedRectangle(cornerRadius: 4).fill(PN.C.surface2).frame(width: 64, height: 40)
                    }
                    Text("\(n)").font(.system(size: 10, weight: .semibold)).padding(.horizontal, 4).background(PN.C.bg.opacity(0.85), in: RoundedRectangle(cornerRadius: 3)).padding(2)
                }
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(tint, lineWidth: 1.5))
                Text(DeckSetup.label(o).split(separator: " ").first.map(String.init) ?? "").font(.system(size: 10, weight: .medium)).foregroundStyle(tint).lineLimit(1)
            }
            .frame(width: 66)
        }
        .buttonStyle(.plain)
        .help(d.info?.slides.first { $0.n == n }?.title ?? "")
        .accessibilityLabel(L("pm.slideOf", ["i": "\(n)", "n": "\(d.count)"]) + ", " + DeckSetup.label(o))
    }

    private var timing: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                label(L("deck.duration")).frame(width: 90, alignment: .leading)
                Picker("", selection: Binding(get: { d.durationFromCalendar && model.calendarMinutes != nil },
                                              set: { model.deck.durationFromCalendar = $0; if $0, let m = model.calendarMinutes { model.deck.duration = m } })) {
                    if let m = model.calendarMinutes { Text(L("start.fromCalendar", ["app": model.calendarApp ?? ""]) + " · \(m) " + L("deck.min")).tag(true) }
                    Text(L("deck.custom")).tag(false)
                }
                .labelsHidden().pickerStyle(.segmented).fixedSize()
                if !(d.durationFromCalendar && model.calendarMinutes != nil) {
                    Stepper(value: $model.deck.duration, in: 5...240, step: 5) { Text("\(d.duration) " + L("deck.min")).monospacedDigit() }.fixedSize()
                }
            }
            HStack(spacing: 12) {
                label(L("deck.questions")).frame(width: 90, alignment: .leading)
                Toggle(L("deck.qaEnd"), isOn: $model.deck.qaOn).toggleStyle(.checkbox)
                if d.qaOn { Stepper(value: $model.deck.qaMin, in: 1...60) { Text("\(d.qaMin) " + L("deck.min")).monospacedDigit() }.fixedSize() }
            }
            Text(L("deck.talkTime", ["t": "\(d.talkMin) " + L("deck.min"), "d": "\(d.duration) " + L("deck.min"), "q": "\(d.qaOn ? d.qaMin : 0) " + L("deck.min")]))
                .font(PN.Font.caption).foregroundStyle(PN.C.text2).fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { if d.durationFromCalendar, let m = model.calendarMinutes { model.deck.duration = m } }
    }

    private func label(_ s: String) -> some View { Text(s).font(PN.Font.caption.weight(.semibold)).foregroundStyle(PN.C.text2) }

    private var pasteSheet: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("deck.pasteText")).font(PN.Font.section)
            Text(L("deck.pasteHint")).font(PN.Font.caption).foregroundStyle(PN.C.text3)
            TextEditor(text: $pasted).font(PN.Font.body).frame(minHeight: 260)
                .overlay(RoundedRectangle(cornerRadius: PN.Radius.s).stroke(Color.primary.opacity(0.12)))
            HStack {
                Spacer()
                Button(L("common.cancel")) { pasting = false }.buttonStyle(.pnTertiary).keyboardShortcut(.cancelAction)
                Button(L("deck.apply")) { model.pasteTalk(pasted); pasted = ""; pasting = false }
                    .buttonStyle(.pnPrimary).disabled(pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20).frame(width: 520)
    }
}

// MARK: - The talk files around a preparation (rules/presentation.yaml > prepare_again)

enum TalkFiles {
    static func load(_ path: String) -> [String: Any]? {
        guard let d = FileManager.default.contents(atPath: path) else { return nil }
        if let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] { return o }
        if let a = (try? JSONSerialization.jsonObject(with: d)) as? [[String: Any]] { return ["slides": a] }
        return nil
    }
    static func save(_ o: [String: Any], _ path: String) {
        if let d = try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys]) {
            try? d.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }
    static func slides(_ base: String, prev: Bool = false) -> [[String: Any]] {
        (load(base + (prev ? ".slides.prev.json" : ".slides.json"))?["slides"] as? [[String: Any]]) ?? []
    }

    /// Before Prepare: one previous version is kept (.slides.prev.json, .outline.prev.json) and the deck read for
    /// this preparation is copied to <base>.deck.json. Returns the deck texts of the previous preparation.
    static func before(base: String, deck: DeckSetup?) -> [Int: String] {
        let fm = FileManager.default
        for ext in ["slides", "outline"] where fm.fileExists(atPath: "\(base).\(ext).json") {
            try? fm.removeItem(atPath: "\(base).\(ext).prev.json")
            try? fm.copyItem(atPath: "\(base).\(ext).json", toPath: "\(base).\(ext).prev.json")
        }
        // 2026-10-29 (owner): Prepare again for any call keeps the previous brief too (<base>.brief.prev.md).
        if fm.fileExists(atPath: base + ".brief.md") {
            try? fm.removeItem(atPath: base + ".brief.prev.md")
            try? fm.copyItem(atPath: base + ".brief.md", toPath: base + ".brief.prev.md")
        }
        var old: [Int: String] = [:]
        if let o = load(base + ".deck.json"), let s = o["slides"] as? [[String: Any]] {
            for x in s { if let n = TalkMerge.num(x) { old[n] = "\(x["title"] ?? "")\n\(x["text"] ?? "")" } }
        }
        if let info = deck?.info {
            try? fm.removeItem(atPath: base + ".deck.json")
            try? fm.copyItem(atPath: info.jsonPath, toPath: base + ".deck.json")
        }
        return old
    }

    /// After Prepare: Keep my edits (or not), the owners from Start call, talk_min, qa_min, speakers.
    /// Returns (rewritten, kept) for "Talk updated · {n} slides rewritten, {k} kept with your edits".
    @discardableResult
    static func after(base: String, deck: DeckSetup?, oldTexts: [Int: String]) -> (rewritten: Int, kept: [Int])? {
        guard var o = load(base + ".slides.json"), let new = o["slides"] as? [[String: Any]] else { return nil }
        let prev = slides(base, prev: true)
        let changed = (deck?.info).map { oldTexts.isEmpty ? Set<Int>() : TalkMerge.deckChanges(old: oldTexts, new: $0.texts) } ?? []
        var (merged, kept) = TalkMerge.merge(old: prev, new: new, keepEdits: deck?.keepEdits ?? true, deckChanged: changed)
        if let d = deck, d.info != nil {
            merged = d.apply(to: merged)
            o["talk_min"] = d.talkMin
            o["qa_min"] = d.qaOn ? d.qaMin : 0
            o["speakers"] = [AppConfig.load(from: AppPaths.config).nameAliases.first ?? "me"] + d.speakers
        }
        o["slides"] = merged
        save(o, base + ".slides.json")
        return (merged.count - kept.count, kept)
    }

    /// Restore previous version: the previous talk comes back, the current one becomes the previous.
    static func restore(base: String) -> Bool {
        let fm = FileManager.default
        var ok = false
        for ext in ["slides", "outline"] where fm.fileExists(atPath: "\(base).\(ext).prev.json") {
            let cur = "\(base).\(ext).json", prev = "\(base).\(ext).prev.json", tmp = cur + ".swap"
            try? fm.removeItem(atPath: tmp)
            try? fm.moveItem(atPath: cur, toPath: tmp)
            try? fm.moveItem(atPath: prev, toPath: cur)
            try? fm.moveItem(atPath: tmp, toPath: prev)
            ok = true
        }
        return ok
    }

    /// The prompt lines for Prepare when a deck is attached (skill/references/presentation.md 8, 8a).
    static func prompt(base: String, deck d: DeckSetup) -> String {
        guard let info = d.info else { return "" }
        let owners = DeckOwners.runs(d.owners, count: d.count).map { r -> String in
            let w = DeckOwners.who(r.owner)
            return "slides \(r.from == r.to ? "\(r.from)" : "\(r.from)-\(r.to)"): who \(w.who)\(w.speaker.isEmpty ? "" : ", speaker \(w.speaker)")"
        }.joined(separator: "; ")
        let prev = slides(base)
        let edited = TalkMerge.edited(prev)
        return """
        The PM attached the deck \(info.file) (\(info.format), \(info.slides.count) slides). Its slide texts are in \
        \(base).deck.json: read that file, not the deck itself. Also write \(base).slides.json as \
        references/presentation.md says (items 8 and 8a): one entry per deck slide, n = the deck slide number, the title \
        from the deck. Who presents (set by the PM, keep it): \(owners). Slide budgets `sec`: all slides together fit the \
        talk time of \(d.talkMin) min (a \(d.duration) min call minus \(d.qaOn ? d.qaMin : 0) min of Q&A at the end); a \
        colleague's slides get a budget and no talk text. On the PM's slides: what to say, the numbers, 1-2 likely \
        questions with answers, a `short` one sentence each, and `"skip": true` on the 1-3 slides that matter least for \
        the goal of the call. Top level: "talk_min": \(d.talkMin), "qa_min": \(d.qaOn ? d.qaMin : 0).
        \(edited.isEmpty || !d.keepEdits ? "" : "The PM edited slides \(TalkMerge.list(edited)) in the previous talk (\(base).slides.prev.json): they stay as they are, write the others.")
        """
    }
}
