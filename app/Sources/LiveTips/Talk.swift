import AppKit
import SwiftUI
import LiveTipsCore

// Pacenote 0.8.5 (PRESENTATION-SPEC P3, P4): the talk slide by slide after Prepare, editable in place, and Prepare
// again. The file is <base>.slides.json (rules/presentation.yaml > slides_json); every edit marks the slide
// "edited", saves as you type and goes to the corrections log (EditLog, kind talk_edit) so the next preparations
// learn from it. The tips window and rehearsal read the same file.

struct TalkSlide: Identifiable, Equatable {
    var id: Int { n }
    var n: Int
    var title: String
    var who: String
    var speaker: String
    var sec: Int
    var say: String
    var numbers: [String]
    var qa: [QA]
    var skip: Bool
    var short: String
    var edited: Bool
    var other: [[String: String]]          // body lines that are not "say" (s, h, c), kept as they are
    struct QA: Equatable, Hashable { var q: String; var a: String }

    init(_ d: [String: Any], index: Int) {
        n = TalkMerge.num(d) ?? index + 1
        title = d["title"] as? String ?? ""
        who = d["who"] as? String ?? "me"
        speaker = d["speaker"] as? String ?? ""
        sec = d["sec"] as? Int ?? Int((d["sec"] as? Double) ?? 60)
        let body = (d["body"] as? [Any]) ?? []
        var says: [String] = [], rest: [[String: String]] = []
        for b in body {
            if let s = b as? String { says.append(s) }
            else if let o = b as? [String: Any], let t = o["t"] as? String {
                let k = o["k"] as? String ?? "p"
                if k == "p" { says.append(t) } else { rest.append(["k": k, "t": t]) }
            }
        }
        say = says.joined(separator: "\n")
        other = rest
        numbers = (d["numbers"] as? [Any])?.compactMap { $0 as? String } ?? []
        qa = ((d["qa"] as? [Any]) ?? []).compactMap { x in
            if let o = x as? [String: Any], let q = o["q"] as? String { return QA(q: q, a: o["a"] as? String ?? "") }
            return nil
        }
        skip = d["skip"] as? Bool ?? false
        short = d["short"] as? String ?? ""
        edited = d["edited"] as? Bool ?? false
    }

    func merged(into d: [String: Any]) -> [String: Any] {
        var m = d
        m["n"] = n; m["title"] = title; m["sec"] = sec; m["skip"] = skip; m["short"] = short; m["edited"] = edited
        m["numbers"] = numbers.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let says = say.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        m["body"] = says.map { ["k": "p", "t": $0] } + other
        let old = (d["qa"] as? [[String: Any]]) ?? []
        m["qa"] = qa.filter { !$0.q.isEmpty }.map { x -> [String: Any] in
            var o = old.first { ($0["q"] as? String) == x.q } ?? [:]
            o["q"] = x.q; o["a"] = x.a
            // A question the PM added needs trigger words, or the recorder drops it (parse_qa).
            if (o["keywords"] as? [String])?.isEmpty ?? true {
                let words = x.q.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count >= 4 }
                o["keywords"] = Array(NSOrderedSet(array: words).array.compactMap { $0 as? String }.prefix(5))
            }
            return o
        }
        return m
    }
    var mine: Bool { who != "other" }
}

@MainActor
final class TalkModel: ObservableObject {
    let base: String
    let title: String
    var call: StartCallModel?          // strong: Prepare again works after Start call is closed
    @Published var slides: [TalkSlide] = []
    @Published var top: [String: Any] = [:]
    private var raw: [[String: Any]] = []
    private var original: [Int: TalkSlide] = [:]
    private var saveWork: DispatchWorkItem?
    @Published var mtime: Date?
    /// Changes offered by a rehearsal; saved only when the PM saves them (rules/rehearsal.yaml > apply_to_talk).
    @Published var proposal: TalkProposal?
    /// Opened from Start call's Prepare again: the sheet shows at once.
    @Published var askAgain = false

    func applyProposal() {
        guard let p = proposal else { return }
        for i in slides.indices {
            let n = slides[i].n
            if let say = p.say[n] { slides[i].say = say; slides[i].edited = true }
            if let qa = p.qa[n] {
                for x in qa {
                    if let j = slides[i].qa.firstIndex(where: { $0.q == x.q }) { slides[i].qa[j].a = x.a } else { slides[i].qa.append(x) }
                }
                slides[i].edited = true
            }
        }
        save()
        EditLog.add(kind: "rehearsal_apply", title: title, project: ((base as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent.components(separatedBy: "/").last ?? "",
                    file: path, fields: ["slides": p.slides, "shortened": p.say.keys.sorted(), "answers": p.qa.values.reduce(0) { $0 + $1.count }])
        proposal = nil
    }

    init(base: String, title: String, call: StartCallModel?) {
        self.base = base; self.title = title; self.call = call
        load()
    }

    var path: String { base + ".slides.json" }

    func load() {
        top = TalkFiles.load(path) ?? [:]
        raw = (top["slides"] as? [[String: Any]]) ?? []
        slides = raw.enumerated().map { TalkSlide($0.element, index: $0.offset) }
        if original.isEmpty { original = Dictionary(uniqueKeysWithValues: slides.map { ($0.n, $0) }) }
        mtime = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    var planSec: Int { (top["talk_min"] as? Int).map { $0 * 60 } ?? TalkTime.total(raw) }
    var totalSec: Int { slides.reduce(0) { $0 + $1.sec } }
    var speakerName: String { slides.first { $0.who == "other" }?.speaker ?? "" }

    func update(_ s: TalkSlide) {
        guard let i = slides.firstIndex(where: { $0.n == s.n }) else { return }
        var v = s
        v.edited = true
        slides[i] = v
        saveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.save() } }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: w)
    }

    func save() {
        var out = raw
        for (i, d) in out.enumerated() {
            let n = TalkMerge.num(d) ?? i + 1
            if let s = slides.first(where: { $0.n == n }) { out[i] = s.merged(into: d) }
        }
        raw = out
        top["slides"] = out
        TalkFiles.save(top, path)
        mtime = Date()
    }

    /// One record per slide the PM changed in this window (rules: every edit is logged for learning).
    func logEdits() {
        save()
        let project = call?.project?.slug ?? ((base as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
        for s in slides {
            guard let o = original[s.n], o != s else { continue }
            var f: [String: Any] = ["slide": s.n]
            if o.say != s.say { f["say_before"] = String(o.say.prefix(600)); f["say_after"] = String(s.say.prefix(600)) }
            if o.title != s.title { f["title_before"] = o.title; f["title_after"] = s.title }
            if o.sec != s.sec { f["sec_before"] = o.sec; f["sec_after"] = s.sec }
            if o.skip != s.skip { f["skip"] = s.skip }
            if o.numbers != s.numbers { f["numbers_after"] = s.numbers }
            if o.qa != s.qa { f["qa_after"] = s.qa.map { ["q": $0.q, "a": $0.a] } }
            if o.short != s.short { f["short_after"] = s.short }
            EditLog.add(kind: "talk_edit", title: title, project: (project as NSString).lastPathComponent, file: path, fields: f)
        }
        original = Dictionary(uniqueKeysWithValues: slides.map { ($0.n, $0) })
    }

    /// One advice for the banner when the talk runs over: shorten the longest unedited slide of the PM, or mark the
    /// smallest-impact slide (a PM slide not marked yet, the latest) as can skip.
    var advice: String {
        let mine = slides.filter { $0.mine && $0.who == "me" }
        guard let long = mine.max(by: { $0.sec < $1.sec }) else { return "" }
        if let s = mine.last(where: { !$0.skip && $0.n != long.n }) { return L("talk.adv", ["n": "\(long.n)", "m": "\(s.n)"]) }
        return L("talk.advShort", ["n": "\(long.n)"])
    }
}

@MainActor
enum TalkWindow {
    static var windows: [String: NSWindow] = [:]
    static var models: [String: TalkModel] = [:]

    static func show(base: String, title: String, call: StartCallModel?, proposal: TalkProposal? = nil, openAgain: Bool = false) {
        if let w = windows[base] {
            if let p = proposal, !p.isEmpty { models[base]?.proposal = p }
            if openAgain { models[base]?.askAgain = true }
            w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return
        }
        let model = TalkModel(base: base, title: title, call: call)
        if let p = proposal, !p.isEmpty { model.proposal = p }
        model.askAgain = openAgain
        models[base] = model
        let w = NSWindow(contentViewController: NSHostingController(rootView: Localized { TalkView(model: model).frame(minWidth: 720, minHeight: 640) }))
        w.tabbingMode = .disallowed      // 0.8.7 (A1): never tabs
        w.styleMask.insert(.resizable)
        w.isReleasedWhenClosed = false
        w.title = L("talk.window", ["call": title])
        w.setContentSize(NSSize(width: 760, height: 780))
        w.center()
        windows[base] = w
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            MainActor.assumeIsolated { model.logEdits(); windows[base] = nil; models[base] = nil }
        }
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// The talk exists for this preparation.
    static func available(base: String) -> Bool { FileManager.default.fileExists(atPath: base + ".slides.json") }
}

struct TalkView: View {
    @ObservedObject var model: TalkModel
    @ObservedObject var runner = PrepRunner.shared
    @State private var mineOnly = false
    @State private var longFirst = false
    @State private var open: Set<Int> = []
    @State private var again = false
    @State private var review = false
    @State private var note = ""
    @State private var wasRunning = false

    private var updating: Bool { runner.running && runner.callID == model.call?.id && model.call != nil }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    if let p = model.proposal { proposalBanner(p) }
                    if updating { workingBanner } else if let r = runner.lastTalk, wasRunning { doneBanner(r) } else { timeBanner }
                    if review { reviewList }
                    ForEach(groups, id: \.first!.n) { g in
                        if g.first!.who == "other" { colleagueGroup(g) } else { ForEach(g) { s in card(s) } }
                    }
                    if !note.isEmpty { Text(note).font(PN.Font.caption).foregroundStyle(PN.C.text3) }
                }
                .padding(24)
            }
            Divider()
            HStack(spacing: 10) {
                Text(L("talk.saveHint")).font(PN.Font.caption).foregroundStyle(PN.C.text3)
                Spacer()
                if model.call != nil { Button(L("talk.prepareAgain")) { again = true }.buttonStyle(.pnSecondary).disabled(updating) }
                Button(L("talk.rehearse")) { model.save(); RehearsalWindow.show(base: model.base, title: model.title) }.buttonStyle(.pnSecondary)
                Button(L("talk.done")) { model.logEdits(); NSApp.keyWindow?.close() }.buttonStyle(.pnPrimary).keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 24).padding(.vertical, 14)
        }
        .background(PN.C.bg)
        .onAppear { if model.askAgain { model.askAgain = false; again = true } }
        .onChange(of: model.askAgain) { if model.askAgain { model.askAgain = false; again = true } }
        .sheet(isPresented: $again) { PrepareAgainSheet(model: model, onStart: { wasRunning = true; review = false }) }
        .onChange(of: runner.running) { if !runner.running && wasRunning { model.load() } }
    }

    private var header: some View {
        let mine = model.slides.filter { $0.who == "me" }.count, shared = model.slides.filter { $0.who == "shared" }.count
        let other = model.slides.filter { $0.who == "other" }.count
        let made = model.mtime.map { $0.formatted(date: Calendar.current.isDateInToday($0) ? .omitted : .abbreviated, time: .shortened) } ?? ""
        return VStack(alignment: .leading, spacing: 8) {
            Text(L("talk.title")).font(.system(size: 22, weight: .bold)).foregroundStyle(PN.C.text)
            Text(L("talk.meta", ["n": "\(model.slides.count)", "m": "\(mine)", "name": model.speakerName.isEmpty ? L("deck.colleague") : model.speakerName,
                                 "k": "\(other)", "s": "\(shared)", "time": made]))
                .font(PN.Font.caption).foregroundStyle(PN.C.text3)
            Picker("", selection: $mineOnly) {
                Text(L("talk.allSlides")).tag(false)
                Text(L("talk.mine")).tag(true)
            }.labelsHidden().pickerStyle(.segmented).fixedSize()
        }
    }

    private var timeBanner: some View {
        let over = model.totalSec - model.planSec
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: over > 0 ? "clock.badge.exclamationmark" : "checkmark.circle").foregroundStyle(over > 0 ? PN.C.onMe : PN.C.turn)
            Text(over > 0 ? L("talk.over", ["total": TalkTime.clock(model.totalSec), "plan": TalkTime.clock(model.planSec), "diff": TalkTime.clock(over)]) + " " + model.advice
                          : L("talk.fits", ["total": TalkTime.clock(model.totalSec), "plan": TalkTime.clock(model.planSec)]))
                .font(PN.Font.body).foregroundStyle(PN.C.text).fixedSize(horizontal: false, vertical: true)
            Spacer()
            if over > 0 { Button(longFirst ? L("talk.allSlides") : L("talk.showLong")) { longFirst.toggle() }.buttonStyle(.pnTertiary) }
        }
        .padding(12)
        .background((over > 0 ? PN.C.onMe : PN.C.turn).opacity(0.10), in: RoundedRectangle(cornerRadius: PN.Radius.m))
    }

    /// Groups: a colleague's run of slides is one group; the PM's and shared slides are one card each.
    private var groups: [[TalkSlide]] {
        var list = model.slides
        if mineOnly { list = list.filter { $0.mine } }
        if longFirst { return list.filter { $0.mine }.sorted { $0.sec > $1.sec }.map { [$0] } }
        var out: [[TalkSlide]] = []
        for s in list {
            if s.who == "other", let last = out.last, last.first!.who == "other", last.last!.n == s.n - 1, last.first!.speaker == s.speaker { out[out.count - 1].append(s) }
            else { out.append([s]) }
        }
        return out
    }

    private func ownerTag(_ s: TalkSlide) -> some View {
        Text(s.who == "me" ? L("deck.me") : s.who == "shared" ? L("deck.all") : s.speaker)
            .font(PN.Font.caption.weight(.medium)).foregroundStyle(s.who == "me" ? PN.C.accent : PN.C.text2)
            .padding(.horizontal, 6).padding(.vertical, 2).background(RoundedRectangle(cornerRadius: 4).fill(PN.C.surface2))
    }

    private func card(_ s: TalkSlide) -> some View {
        let longest = model.slides.filter { $0.mine }.max { $0.sec < $1.sec }?.n == s.n
        let isOpen = open.contains(s.n)
        let locked = updating && s.edited && (model.call?.deck.keepEdits ?? true)
        return VStack(alignment: .leading, spacing: 10) {
            Button { if isOpen { open.remove(s.n) } else { open.insert(s.n) } } label: {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("\(s.n)").font(PN.Font.body.weight(.semibold).monospacedDigit()).frame(width: 24, alignment: .trailing)
                    ownerTag(s)
                    Text(s.title).font(PN.Font.body.weight(.medium)).foregroundStyle(PN.C.text).lineLimit(1)
                    if !isOpen, let first = s.say.split(separator: "\n").first {
                        Text("· \"" + String(first.prefix(60)) + (first.count > 60 ? "..." : "") + "\"").font(PN.Font.caption).foregroundStyle(PN.C.text3).lineLimit(1)
                    }
                    if s.edited { Text(L("talk.edited")).font(PN.Font.caption).foregroundStyle(PN.C.accent) }
                    if s.skip { Text(L("talk.canSkip")).font(PN.Font.caption).foregroundStyle(PN.C.text3) }
                    Spacer()
                    Text(TalkTime.clock(s.sec) + (longest ? " · " + L("talk.longest") : "")).font(PN.Font.caption.monospacedDigit()).foregroundStyle(longest ? PN.C.onMe : PN.C.text3)
                    Image(systemName: isOpen ? "chevron.up" : "chevron.down").foregroundStyle(PN.C.text3)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if let p = model.proposal, p.say[s.n] != nil || p.qa[s.n] != nil {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("talk.proposed")).font(PN.Font.caption.weight(.semibold)).foregroundStyle(PN.C.accent)
                    if let say = p.say[s.n] { Text(say).font(PN.Font.body).fixedSize(horizontal: false, vertical: true) }
                    ForEach(p.qa[s.n] ?? [], id: \.self) { x in Text("Q: \(x.q)\nA: \(x.a)").font(PN.Font.caption).foregroundStyle(PN.C.text2) }
                }
                .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                .background(PN.C.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: PN.Radius.s))
            }
            if isOpen { editor(s).disabled(locked) }
        }
        .padding(12)
        .background(PN.C.surface, in: RoundedRectangle(cornerRadius: PN.Radius.m))
    }

    private func binding(_ s: TalkSlide) -> Binding<TalkSlide> {
        Binding(get: { model.slides.first { $0.n == s.n } ?? s }, set: { model.update($0) })
    }

    private func editor(_ s0: TalkSlide) -> some View {
        let b = binding(s0)
        return VStack(alignment: .leading, spacing: 10) {
            TextField("", text: b.title).textFieldStyle(.roundedBorder).font(PN.Font.body.weight(.medium))
            label(L("talk.say"))
            TextEditor(text: b.say).font(PN.Font.body).scrollContentBackground(.hidden).padding(6).frame(minHeight: 90)
                .background(PN.C.bg, in: RoundedRectangle(cornerRadius: PN.Radius.s))
                .overlay(RoundedRectangle(cornerRadius: PN.Radius.s).stroke(Color.primary.opacity(0.12)))
            label(L("talk.numbers"))
            TextField("", text: Binding(get: { b.wrappedValue.numbers.joined(separator: " · ") },
                                        set: { b.wrappedValue.numbers = $0.components(separatedBy: "·").map { $0.trimmingCharacters(in: .whitespaces) } }))
                .textFieldStyle(.roundedBorder)
            label(L("deck.questions"))
            ForEach(Array(b.wrappedValue.qa.enumerated()), id: \.offset) { i, _ in
                HStack(spacing: 6) {
                    TextField("", text: Binding(get: { b.wrappedValue.qa[safe: i]?.q ?? "" }, set: { if i < b.wrappedValue.qa.count { b.wrappedValue.qa[i].q = $0 } }))
                        .textFieldStyle(.roundedBorder)
                    TextField("", text: Binding(get: { b.wrappedValue.qa[safe: i]?.a ?? "" }, set: { if i < b.wrappedValue.qa.count { b.wrappedValue.qa[i].a = $0 } }))
                        .textFieldStyle(.roundedBorder)
                    Button { b.wrappedValue.qa.remove(at: i) } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel(L("call.remove"))
                }
            }
            if b.wrappedValue.qa.count < 3 {
                Button(L("talk.addQuestion")) { b.wrappedValue.qa.append(.init(q: "", a: "")) }.buttonStyle(.pnTertiary)
            }
            label(L("talk.short"))
            TextField("", text: b.short).textFieldStyle(.roundedBorder)
            HStack(spacing: 16) {
                Toggle(L("talk.canSkip"), isOn: b.skip).toggleStyle(.checkbox)
                Stepper(value: b.sec, in: 10...1800, step: 15) { Text(L("talk.budget") + " " + TalkTime.clock(b.wrappedValue.sec)).monospacedDigit() }.fixedSize()
            }
        }
    }

    private func colleagueGroup(_ g: [TalkSlide]) -> some View {
        let name = g.first!.speaker, next = (g.last!.n) + 1
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(g.count == 1 ? "\(g[0].n)" : "\(g[0].n)-\(g.last!.n)").font(PN.Font.body.weight(.semibold).monospacedDigit())
            ownerTag(g[0])
            Text(L("talk.colleague", ["name": name, "n": "\(next)"])).font(PN.Font.caption).foregroundStyle(PN.C.text2).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Text(TalkTime.clock(g.reduce(0) { $0 + $1.sec })).font(PN.Font.caption.monospacedDigit()).foregroundStyle(PN.C.text3)
        }
        .padding(12)
        .background(PN.C.surface2.opacity(0.6), in: RoundedRectangle(cornerRadius: PN.Radius.m))
    }

    private func proposalBanner(_ p: TalkProposal) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(L("talk.proposal", ["list": p.say.isEmpty ? "-" : TalkMerge.list(Array(p.say.keys)), "k": "\(p.qa.values.reduce(0) { $0 + $1.count })"]))
                .font(PN.Font.body).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(L("talk.proposalDiscard")) { model.proposal = nil }.buttonStyle(.pnTertiary)
            Button(L("talk.proposalSave")) { model.applyProposal() }.buttonStyle(.pnPrimary)
        }
        .padding(12)
        .background(PN.C.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: PN.Radius.m))
    }

    // MARK: P4 working and done

    private var workingBanner: some View {
        let n = max(1, model.slides.count), i = min(n, max(1, Int(runner.progress * Double(n))))
        let kept = TalkMerge.edited(model.slides.map { ["n": $0.n, "edited": $0.edited] })
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                ProgressView(value: runner.progress).frame(width: 80)
                Text(L("again.working", ["i": "\(i)", "n": "\(n)"])).font(PN.Font.body.weight(.medium))
                Spacer()
                Button(L("again.stop")) { runner.cancel() }.buttonStyle(.pnTertiary)
            }
            if !kept.isEmpty && (model.call?.deck.keepEdits ?? true) {
                Text(L("again.workingHint", ["list": TalkMerge.list(kept)])).font(PN.Font.caption).foregroundStyle(PN.C.text3)
            }
            ForEach(model.slides.filter { $0.mine }) { s in
                HStack {
                    Text("\(s.n)").monospacedDigit().frame(width: 24, alignment: .trailing)
                    Text(s.title).lineLimit(1)
                    Spacer()
                    Text(s.edited && (model.call?.deck.keepEdits ?? true) ? L("again.yours") : s.n < i ? L("again.updated") : s.n == i ? L("again.writing") : L("again.queued"))
                        .foregroundStyle(s.edited ? PN.C.accent : PN.C.text3)
                }
                .font(PN.Font.caption)
            }
        }
        .padding(12)
        .background(PN.C.surface, in: RoundedRectangle(cornerRadius: PN.Radius.m))
    }

    private func doneBanner(_ r: (rewritten: Int, kept: [Int])) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("again.done", ["n": "\(r.rewritten)", "k": "\(r.kept.count)"])).font(PN.Font.body.weight(.medium))
            Text(model.totalSec > model.planSec
                 ? L("talk.over", ["total": TalkTime.clock(model.totalSec), "plan": TalkTime.clock(model.planSec), "diff": TalkTime.clock(model.totalSec - model.planSec)])
                 : L("talk.fits", ["total": TalkTime.clock(model.totalSec), "plan": TalkTime.clock(model.planSec)]))
                .font(PN.Font.caption).foregroundStyle(PN.C.text2)
            HStack(spacing: 10) {
                Button(L("again.review")) { review.toggle() }.buttonStyle(.pnSecondary)
                Button(L("again.restore")) {
                    if TalkFiles.restore(base: model.base) { model.load(); wasRunning = false; review = false }
                }.buttonStyle(.pnTertiary)
            }
        }
        .padding(12)
        .background(PN.C.turn.opacity(0.10), in: RoundedRectangle(cornerRadius: PN.Radius.m))
    }

    /// What changed against the previous version: new text, or the PM's edits kept.
    private var reviewList: some View {
        let prev = Dictionary(uniqueKeysWithValues: TalkFiles.slides(model.base, prev: true).enumerated().map { (TalkMerge.num($0.element) ?? $0.offset + 1, TalkSlide($0.element, index: $0.offset)) })
        let kept = Set(runner.lastTalk?.kept ?? [])
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(model.slides.filter { s in s.mine && (kept.contains(s.n) || prev[s.n].map { $0.say != s.say || $0.title != s.title } ?? true) }) { s in
                HStack {
                    Text("\(s.n)").monospacedDigit().frame(width: 24, alignment: .trailing)
                    Text(s.title).lineLimit(1)
                    Spacer()
                    Text(kept.contains(s.n) ? L("again.kept") : L("again.newText")).foregroundStyle(kept.contains(s.n) ? PN.C.accent : PN.C.text2)
                }
                .font(PN.Font.caption)
            }
        }
        .padding(12)
        .background(PN.C.surface, in: RoundedRectangle(cornerRadius: PN.Radius.m))
    }

    private func label(_ s: String) -> some View { Text(s).font(PN.Font.caption.weight(.semibold)).foregroundStyle(PN.C.text2) }
}

extension Array {
    subscript(safe i: Int) -> Element? { i >= 0 && i < count ? self[i] : nil }
}

// MARK: - P4 ask

struct PrepareAgainSheet: View {
    @ObservedObject var model: TalkModel
    var onStart: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var keep = true
    @State private var err = ""

    private var call: StartCallModel? { model.call }
    private var edited: [Int] { TalkMerge.edited(model.slides.map { ["n": $0.n, "edited": $0.edited] }) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("again.title")).font(.system(size: 18, weight: .bold))
            reasons
            if let c = call, c.callType == "presentation" { DeckLine(model: c) }
            VStack(alignment: .leading, spacing: 10) {
                choice(true, L("again.keep"), edited.isEmpty ? "" : L("again.keepHint", ["list": TalkMerge.list(edited)]))
                choice(false, L("again.rewrite"), edited.isEmpty ? "" : L("again.rewriteHint", ["n": "\(edited.count)"]))
            }
            if !err.isEmpty { Text(err).font(PN.Font.caption).foregroundStyle(PN.C.danger) }
            HStack {
                Spacer()
                Button(L("common.cancel")) { dismiss() }.buttonStyle(.pnTertiary).keyboardShortcut(.cancelAction)
                Button(L("talk.prepareAgain")) { start() }.buttonStyle(.pnPrimary).keyboardShortcut(.defaultAction)
                    .disabled(call == nil || { if case .reading = call!.deck.phase { return true }; return false }())
            }
        }
        .padding(22).frame(width: 520)
        .onAppear { keep = call?.deck.keepEdits ?? true }
    }

    @ViewBuilder private var reasons: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let c = call, let fr = Freshness.check(c), let made = Freshness.preparedAt(brief: model.base + ".brief.md") {
                reason(L("again.age", ["d": "\(max(0, Calendar.current.dateComponents([.day], from: made, to: Date()).day ?? 0))", "n": "\(fr.changes.count)"]), nil)
            }
            if let c = call, let info = c.deck.info, let m = (try? FileManager.default.attributesOfItem(atPath: info.file))?[.modificationDate] as? Date, m > info.readAt {
                reason(L("again.deckChanged"), nil)
            }
            if let c = call, let mins = c.calendarMinutes, let was = model.top["talk_min"] as? Int, mins != c.deck.duration || (was + ((model.top["qa_min"] as? Int) ?? 0)) != mins {
                reason(L("again.callLonger", ["d": "\(mins) " + L("deck.min")]), nil)
            }
        }
    }

    private func reason(_ t: String, _ sub: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(t, systemImage: "arrow.triangle.2.circlepath").font(PN.Font.body)
            if let s = sub { Text(s).font(PN.Font.caption).foregroundStyle(PN.C.text3) }
        }
    }

    private func choice(_ v: Bool, _ title: String, _ hint: String) -> some View {
        Button { keep = v } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: keep == v ? "largecircle.fill.circle" : "circle").foregroundStyle(PN.C.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(PN.Font.body.weight(.medium)).foregroundStyle(PN.C.text)
                    if !hint.isEmpty { Text(hint).font(PN.Font.caption).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true) }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func start() {
        guard let c = call else { return }
        model.logEdits()
        c.deck.keepEdits = keep
        if let mins = c.calendarMinutes, c.deck.durationFromCalendar { c.deck.duration = mins }
        if let e = UpNext.shared.prepare(c) { err = e; return }
        UpNext.shared.touch(c)
        onStart()
        dismiss()
    }
}

/// The deck in the Prepare again sheet: which file, Replace (read first, then the talk is rewritten).
struct DeckLine: View {
    @ObservedObject var model: StartCallModel
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.richtext").foregroundStyle(PN.C.accent)
            switch model.deck.phase {
            case .reading(let i, let n): Text(n > 0 ? L("deck.reading", ["i": "\(i)", "n": "\(n)"]) : L("deck.readingStart")).font(PN.Font.caption)
            case .failed(let why): Text(why).font(PN.Font.caption).foregroundStyle(PN.C.danger).lineLimit(2)
            default: Text(((model.deck.path ?? L("pm.empty.title")) as NSString).lastPathComponent).font(PN.Font.caption).lineLimit(1)
            }
            Spacer()
            Button(model.deck.info == nil ? L("deck.attach") : L("deck.replace")) { model.pickDeck() }.buttonStyle(.pnTertiary)
        }
        .padding(10)
        .background(PN.C.surface, in: RoundedRectangle(cornerRadius: PN.Radius.s))
    }
}
