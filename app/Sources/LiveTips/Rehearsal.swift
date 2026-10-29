import AppKit
import SwiftUI
import LiveTipsCore

/// Pacenote 0.8.5 (P6; rules/rehearsal.yaml): rehearse a presentation. Nothing is recorded: the PM's own slides run with
/// their timers (a colleague's are skipped), then Claude plays the client and asks 4 hard questions, the PM answers in
/// writing and gets a short result. The last result is kept in Application Support/LiveTips/rehearsals/ (date, score,
/// seconds per slide) and "Apply to talk" proposes changes that the PM reviews in Your talk before they are saved.
@MainActor
enum RehearsalWindow {
    static func show(base: String, title: String, call: StartCallModel? = nil) {
        let w = NSWindow(contentViewController: NSHostingController(rootView: Localized {
            RehearsalView(base: base, title: title, call: call).frame(minWidth: 620, minHeight: 600)
        }))
        w.styleMask.insert(.resizable)
        w.isReleasedWhenClosed = false
        w.title = L("reh.window", ["call": title])
        w.setContentSize(NSSize(width: 660, height: 640))
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    struct Step { var n: Int; var title: String; var say: [String]; var secs: Int; var numbers: [String] }

    /// The PM's steps: the slides (<base>.slides.json, who me or shared) or the outline (<base>.outline.json).
    static func steps(base: String) -> [Step] {
        let slides = TalkFiles.slides(base)
        if !slides.isEmpty {
            return slides.enumerated().map { TalkSlide($0.element, index: $0.offset) }.filter { $0.mine }
                .map { Step(n: $0.n, title: $0.title, say: $0.say.split(separator: "\n").map(String.init), secs: $0.sec, numbers: $0.numbers) }
        }
        let o = TalkFiles.load(base + ".outline.json")
        let list = (o?["sections"] as? [[String: Any]]) ?? []
        return list.enumerated().filter { ($0.element["who"] as? String) != "other" }.map { i, sec in
            Step(n: i + 1, title: sec["title"] as? String ?? "", say: Array(((sec["points"] as? [String]) ?? []).prefix(3)),
                 secs: (sec["sec"] as? Int) ?? Int((sec["sec"] as? Double) ?? 60), numbers: (sec["numbers"] as? [String]) ?? [])
        }
    }

    // MARK: last result (rules/rehearsal.yaml > last_result)

    struct Last: Codable { var date: Date; var score: Double; var seconds: [String: Int]; var talkAt: Date? }
    static func lastPath(_ base: String) -> URL {
        AppPaths.support.appendingPathComponent("rehearsals/\((base as NSString).lastPathComponent).json")
    }
    static func last(base: String) -> Last? {
        guard let d = try? Data(contentsOf: lastPath(base)) else { return nil }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(Last.self, from: d)
    }
    static func save(base: String, _ l: Last) {
        let u = lastPath(base)
        try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try? enc.encode(l).write(to: u, options: .atomic)
    }
    static func talkModified(_ base: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: base + ".slides.json"))?[.modificationDate] as? Date
    }
    /// "Last rehearsal: 27 Oct · score 3.5 of 5" (+ "before update" after Prepare again), or "Not rehearsed yet".
    static func entryLine(base: String) -> (title: String, sub: String) {
        if let l = last(base: base) {
            let before = (talkModified(base).map { $0.timeIntervalSince(l.talkAt ?? l.date) > 60 } ?? false) ? " · " + L("reh.beforeUpdate") : ""
            return (L("reh.entry.last", ["date": l.date.formatted(.dateTime.day().month(.abbreviated)), "s": String(format: "%.1f", l.score)]) + before, "")
        }
        let mins = max(5, (steps(base: base).reduce(0) { $0 + $1.secs } + 4 * 60) / 60)
        return (L("reh.entry.notYet"), L("reh.entry.notYetHint", ["t": "\(mins) " + L("deck.min")]))
    }
}

struct RehearsalView: View {
    let base: String
    let title: String
    var call: StartCallModel?          // strong: Prepare again works after Start call is closed
    enum Phase { case intro, run, question, scoring, result }
    @State private var phase: Phase = .intro
    @State private var steps: [RehearsalWindow.Step] = []
    @State private var index = 0
    @State private var stepStart = Date()
    @State private var started = Date()
    @State private var actual: [Int: Int] = [:]
    @State private var now = Date()
    @State private var items: [[String: Any]] = []         // {q, why, slide}
    @State private var answers: [String] = []
    @State private var qi = 0
    @State private var who = ""
    @State private var scored: [[String: Any]] = []
    @State private var overall = ""
    @State private var busy = false
    @State private var error = ""

    private var lang: String { FollowUpWindow.language(of: base + ".brief.md") }
    private var plan: Int { steps.reduce(0) { $0 + $1.secs } }
    private var colleague: String { TalkFiles.slides(base).first { ($0["who"] as? String) == "other" }?["speaker"] as? String ?? "" }
    /// The client Claude plays: a named participant, else a client from the project config, else nobody named.
    private var client: String {
        if !who.isEmpty { return who }
        return call?.participants.first ?? call?.project?.people.first(where: { $0.side == "client" })?.name ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch phase {
            case .intro: intro
            case .run: run
            case .question: question
            case .scoring: HStack(spacing: 8) { ProgressView().controlSize(.small); Text(L("rehearse.thinking")).foregroundStyle(PN.C.text2) }
            case .result: result
            }
            if !error.isEmpty { Text(error).font(PN.Font.caption).foregroundStyle(PN.C.danger) }
            Spacer(minLength: 0)
        }
        .padding(24)
        .background(PN.C.bg)
        .onAppear { steps = RehearsalWindow.steps(base: base) }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { now = $0 }
    }

    // MARK: A. intro

    private var intro: some View {
        let mins = max(5, (plan + 4 * 60) / 60)
        return VStack(alignment: .leading, spacing: 16) {
            Text(L("reh.title")).font(.system(size: 22, weight: .bold))
            Text(L("reh.meta", ["t": "\(mins) " + L("deck.min")])).font(PN.Font.body).foregroundStyle(PN.C.text2)
            stepRow(1, L("reh.step1"), L("reh.step1Hint", ["n": "\(steps.count)", "name": colleague.isEmpty ? L("deck.colleague") : colleague]))
            stepRow(2, L("reh.step2"), client.isEmpty ? L("reh.step2Hint", ["name": "#"]).replacingOccurrences(of: ", #,", with: ",") : L("reh.step2Hint", ["name": client]))
            stepRow(3, L("reh.step3"), L("reh.step3Hint"))
            stepRow(4, L("reh.step4"), L("reh.step4Hint"))
            HStack {
                Text(L("reh.stopAny")).font(PN.Font.caption).foregroundStyle(PN.C.text3)
                Spacer()
                Button(L("reh.notNow")) { NSApp.keyWindow?.close() }.buttonStyle(.pnTertiary).keyboardShortcut(.cancelAction)
                Button(L("reh.start")) { begin() }.buttonStyle(.pnPrimary).keyboardShortcut(.defaultAction)
            }
        }
    }

    private func stepRow(_ n: Int, _ t: String, _ hint: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(n)").font(PN.Font.caption.weight(.semibold)).frame(width: 22, height: 22).background(Circle().fill(PN.C.surface2))
            VStack(alignment: .leading, spacing: 2) {
                Text(t).font(PN.Font.body.weight(.medium))
                Text(hint).font(PN.Font.caption).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func begin() {
        index = 0; actual = [:]; items = []; answers = []; scored = []; overall = ""; qi = 0
        started = Date(); stepStart = Date()
        phase = steps.isEmpty ? .question : .run
        fetchQuestions()      // ready by the time the slides are done
    }

    // MARK: B. run-through

    @ViewBuilder private var run: some View {
        let st = steps[min(index, steps.count - 1)]
        let el = Int(now.timeIntervalSince(stepStart))
        let total = actual.filter { $0.key != st.n }.values.reduce(0, +) + el
        HStack {
            Text(L("reh.stepOf", ["i": "1", "n": "4"])).font(PN.Font.caption).foregroundStyle(PN.C.text3)
            Spacer()
            Text(L("reh.slideCount", ["n": "\(st.n)", "k": "\(index + 1)", "m": "\(steps.count)"])).font(PN.Font.caption).foregroundStyle(PN.C.text2)
        }
        Text(st.title).font(.system(size: 22, weight: .bold))
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(TalkTime.clock(el)).font(.system(size: 30, weight: .semibold).monospacedDigit()).foregroundStyle(el > st.secs ? PN.C.danger : PN.C.text)
            Text(el > st.secs ? L("reh.overBy", ["plan": TalkTime.clock(st.secs), "diff": TalkTime.clock(el - st.secs)])
                              : L("reh.overBy", ["plan": TalkTime.clock(st.secs), "diff": "0:00"]).components(separatedBy: " · ").first ?? "")
                .font(PN.Font.body).foregroundStyle(PN.C.text2)
        }
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(st.say.enumerated()), id: \.offset) { _, line in Text(line).font(.system(size: 17)).fixedSize(horizontal: false, vertical: true) }
                if !st.numbers.isEmpty { Text(st.numbers.joined(separator: " · ")).font(PN.Font.body.weight(.semibold)) }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        Text(L("reh.outLoud")).font(PN.Font.caption).foregroundStyle(PN.C.text3)
        HStack(spacing: 10) {
            Button(L("again.stop")) { NSApp.keyWindow?.close() }.buttonStyle(.pnTertiary)
            Text(L("reh.total", ["t": TalkTime.clock(total), "plan": TalkTime.clock(plan)])).font(PN.Font.caption).foregroundStyle(PN.C.text3)
            Spacer()
            Button(L("pm.prev")) { move(-1) }.buttonStyle(.pnSecondary).disabled(index == 0)
            Button(L("reh.nextSlide")) { move(1) }.buttonStyle(.pnPrimary).keyboardShortcut(.rightArrow, modifiers: [])
        }
    }

    private func move(_ d: Int) {
        let st = steps[index]
        actual[st.n] = (actual[st.n] ?? 0) + Int(Date().timeIntervalSince(stepStart))
        stepStart = Date()
        if d > 0 && index == steps.count - 1 { phase = .question; return }
        index = max(0, min(steps.count - 1, index + d))
    }

    // MARK: C. questions, one at a time

    @ViewBuilder private var question: some View {
        if items.isEmpty {
            HStack(spacing: 8) { if busy { ProgressView().controlSize(.small) }; Text(L("rehearse.thinking")).foregroundStyle(PN.C.text2) }
        } else {
            let it = items[qi]
            HStack {
                Text(L("reh.qOf", ["i": "\(qi + 1)", "n": "\(items.count)"])).font(PN.Font.caption).foregroundStyle(PN.C.text3)
                Spacer()
                Text(L("reh.stepOf", ["i": "2", "n": "4"])).font(PN.Font.caption).foregroundStyle(PN.C.text3)
            }
            Text(L("reh.asks", ["name": client.isEmpty ? (L10n.lang == "uk" ? "Клієнт" : "The client") : client])).font(PN.Font.caption.weight(.semibold)).foregroundStyle(PN.C.accent)
            Text(it["q"] as? String ?? "").font(.system(size: 19, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
            if let why = it["why"] as? String, !why.isEmpty {
                Text(L("reh.why", ["reason": why])).font(PN.Font.caption).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
            }
            Text(L("reh.answer")).font(PN.Font.caption.weight(.semibold)).foregroundStyle(PN.C.text2)
            TextEditor(text: Binding(get: { answers[safe: qi] ?? "" }, set: { if qi < answers.count { answers[qi] = $0 } }))
                .font(PN.Font.body).scrollContentBackground(.hidden).padding(6).frame(minHeight: 120)
                .background(PN.C.surface, in: RoundedRectangle(cornerRadius: PN.Radius.s))
                .overlay(RoundedRectangle(cornerRadius: PN.Radius.s).stroke(Color.primary.opacity(0.12)))
            Text(L("reh.answerHint")).font(PN.Font.caption).foregroundStyle(PN.C.text3)
            HStack {
                Spacer()
                Button(L("reh.skip")) { nextQuestion() }.buttonStyle(.pnTertiary)
                Button(L("pm.nextBtn")) { nextQuestion() }.buttonStyle(.pnPrimary).keyboardShortcut(.defaultAction)
            }
        }
    }

    private func nextQuestion() {
        if qi < items.count - 1 { qi += 1 } else { score() }
    }

    private func fetchQuestions() {
        busy = true; error = ""
        let c = AppConfig.load(from: AppPaths.config)
        PyTool.run("rehearse", ["questions", "--base", base, "--lang", lang, "--model", c.models.tip, "--who", client.isEmpty ? "the client" : client]) { r in
            busy = false
            if (r["ok"] as? Bool) == true {
                items = (r["items"] as? [[String: Any]]) ?? ((r["questions"] as? [String]) ?? []).map { ["q": $0] }
                answers = Array(repeating: "", count: items.count)
            } else { error = L("rehearse.failed", ["err": r["error"] as? String ?? ""]) }
        }
    }

    private func score() {
        phase = .scoring; error = ""
        let c = AppConfig.load(from: AppPaths.config)
        let tmp = (NSTemporaryDirectory() as NSString).appendingPathComponent("pacenote-rehearsal-\(UUID().uuidString).json")
        let list = items.enumerated().map { i, it -> [String: Any] in ["q": it["q"] ?? "", "a": answers[safe: i] ?? "", "slide": it["slide"] ?? NSNull()] }
        if let d = try? JSONSerialization.data(withJSONObject: list) { try? d.write(to: URL(fileURLWithPath: tmp)) }
        PyTool.run("rehearse", ["score", "--base", base, "--answers", tmp, "--lang", L10n.lang, "--model", c.models.tip]) { r in
            try? FileManager.default.removeItem(atPath: tmp)
            if (r["ok"] as? Bool) == true {
                scored = (r["answers"] as? [[String: Any]]) ?? []; overall = r["overall"] as? String ?? ""
                RehearsalWindow.save(base: base, .init(date: Date(), score: avg, seconds: Dictionary(uniqueKeysWithValues: actual.map { ("\($0.key)", $0.value) }),
                                                     talkAt: RehearsalWindow.talkModified(base)))
                phase = .result
            } else { error = L("rehearse.failed", ["err": r["error"] as? String ?? ""]); phase = .question }
        }
    }

    // MARK: D. result

    private var avg: Double {
        let s = scored.compactMap { $0["score"] as? Int }.filter { $0 > 0 }
        return s.isEmpty ? 0 : (Double(s.reduce(0, +)) / Double(s.count) * 2).rounded() / 2
    }
    private var overSlides: [Int] { steps.filter { (actual[$0.n] ?? 0) > $0.secs + 15 }.sorted { (actual[$0.n] ?? 0) - $0.secs > (actual[$1.n] ?? 0) - $1.secs }.prefix(3).map(\.n).sorted() }
    private var ran: Int { actual.values.reduce(0, +) }

    @ViewBuilder private var result: some View {
        HStack {
            Text(L("reh.done", ["t": "\(max(1, Int(Date().timeIntervalSince(started) / 60))) " + L("deck.min")])).font(PN.Font.caption).foregroundStyle(PN.C.text3)
            Spacer()
        }
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(L("reh.score", ["s": String(format: avg == avg.rounded() ? "%.0f" : "%.1f", avg)])).font(.system(size: 28, weight: .bold))
            Text(overall).font(PN.Font.body).foregroundStyle(PN.C.text2).fixedSize(horizontal: false, vertical: true)
        }
        if ran > plan, !overSlides.isEmpty {
            HStack {
                Text(L("reh.overTalk", ["t": TalkTime.clock(ran - plan), "list": TalkMerge.list(overSlides)])).font(PN.Font.body).foregroundStyle(PN.C.onMe)
                Spacer()
            }
        }
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(scored.enumerated()), id: \.offset) { _, a in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text("\(a["score"] as? Int ?? 0)").font(PN.Font.body.weight(.bold).monospacedDigit())
                                .foregroundStyle((a["score"] as? Int ?? 0) >= 4 ? PN.C.turn : PN.C.onMe)
                            Text(a["q"] as? String ?? "").font(PN.Font.body.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                        }
                        if let f = a["feedback"] as? String, !f.isEmpty { Text(f).font(PN.Font.caption).foregroundStyle(PN.C.text2) }
                        if let b = a["better"] as? String, !b.isEmpty, (a["score"] as? Int ?? 5) < 4 {
                            Text(L("reh.better")).font(PN.Font.caption.weight(.semibold)).foregroundStyle(PN.C.text3)
                            Text("\"" + b + "\"").font(PN.Font.body).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(PN.C.surface, in: RoundedRectangle(cornerRadius: PN.Radius.m))
                }
            }
        }
        if TalkWindow.available(base: base) {
            Text(L("reh.applyHint", ["list": overSlides.isEmpty ? "-" : TalkMerge.list(overSlides)])).font(PN.Font.caption).foregroundStyle(PN.C.text3)
                .fixedSize(horizontal: false, vertical: true)
        }
        HStack(spacing: 10) {
            Button(L("reh.again")) { phase = .intro }.buttonStyle(.pnTertiary)
            if TalkWindow.available(base: base) { Button(L("reh.openTalk")) { TalkWindow.show(base: base, title: title, call: call) }.buttonStyle(.pnTertiary) }
            Spacer()
            if TalkWindow.available(base: base) { Button(L("reh.apply")) { apply() }.buttonStyle(.pnSecondary) }
            Button(L("talk.done")) { NSApp.keyWindow?.close() }.buttonStyle(.pnPrimary)
        }
    }

    /// Apply to talk: a proposal (shorter text on the slides that ran over, the better answers into their Q&A),
    /// shown in Your talk; nothing is saved until the PM saves it there.
    private func apply() {
        var p = TalkProposal()
        for st in steps where overSlides.contains(st.n) {
            let ratio = Double(st.secs) / Double(max(1, actual[st.n] ?? st.secs))
            let sentences = st.say.flatMap { $0.components(separatedBy: ". ").map { $0.trimmingCharacters(in: .whitespaces) } }.filter { !$0.isEmpty }
            let keep = max(1, Int((Double(sentences.count) * ratio).rounded(.down)))
            if keep < sentences.count {
                p.say[st.n] = sentences.prefix(keep).map { $0.hasSuffix(".") || $0.hasSuffix("?") ? $0 : $0 + "." }.joined(separator: "\n")
            }
        }
        for a in scored {
            guard let n = a["slide"] as? Int, let b = a["better"] as? String, !b.isEmpty, let q = a["q"] as? String, (a["score"] as? Int ?? 5) < 4 else { continue }
            p.qa[n, default: []].append(.init(q: q, a: b))
        }
        TalkWindow.show(base: base, title: title, call: call, proposal: p)
    }
}

/// Changes offered to the talk by a rehearsal (rules/rehearsal.yaml > apply_to_talk), reviewed in Your talk.
struct TalkProposal: Equatable {
    var say: [Int: String] = [:]
    var qa: [Int: [TalkSlide.QA]] = [:]
    var isEmpty: Bool { say.isEmpty && qa.isEmpty }
    var slides: [Int] { Array(Set(say.keys).union(qa.keys)).sorted() }
}
