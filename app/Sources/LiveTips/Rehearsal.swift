import AppKit
import SwiftUI
import LiveTipsCore

/// Pacenote 0.8 (F6, idea 10; rules/rehearsal.yaml): rehearse a presentation. Nothing is recorded: the steps of
/// the preparation run with their timers, then Claude asks 4 hard questions as the client, the PM answers in writing
/// (owner 2026-10-28: text, not voice) and gets a short assessment.
@MainActor
enum RehearsalWindow {
    static func show(base: String, title: String) {
        let w = NSWindow(contentViewController: NSHostingController(rootView: Localized { RehearsalView(base: base).frame(minWidth: 600, minHeight: 560) }))
        w.styleMask.insert(.resizable)
        w.isReleasedWhenClosed = false
        w.title = L("rehearse.title", ["title": title])
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    struct Step { var title: String; var say: String; var secs: Int }

    /// The steps of the presentation: the slides (<base>.slides.json) or the outline (<base>.outline.json).
    static func steps(base: String) -> [Step] {
        func load(_ ext: String) -> Any? {
            (try? Data(contentsOf: URL(fileURLWithPath: base + ext))).flatMap { try? JSONSerialization.jsonObject(with: $0) }
        }
        if let o = load(".slides.json") {
            let list = (o as? [String: Any])?["slides"] as? [[String: Any]] ?? (o as? [[String: Any]]) ?? []
            let s = list.map { sl -> Step in
                let body = (sl["body"] as? [[String: Any]]) ?? []
                let say = body.filter { ($0["k"] as? String) == "p" }.compactMap { $0["t"] as? String }.joined(separator: " ")
                return Step(title: sl["title"] as? String ?? "", say: say, secs: (sl["sec"] as? Int) ?? Int((sl["sec"] as? Double) ?? 60))
            }
            if !s.isEmpty { return s }
        }
        if let o = load(".outline.json") {
            let list = (o as? [String: Any])?["sections"] as? [[String: Any]] ?? (o as? [[String: Any]]) ?? []
            return list.map { sec in
                Step(title: sec["title"] as? String ?? "", say: ((sec["points"] as? [String]) ?? []).prefix(3).joined(separator: ". "),
                     secs: (sec["sec"] as? Int) ?? Int((sec["sec"] as? Double) ?? 60))
            }
        }
        return []
    }
}

struct RehearsalView: View {
    let base: String
    enum Phase { case steps, questions, result }
    @State private var phase: Phase = .steps
    @State private var steps: [RehearsalWindow.Step] = []
    @State private var index = 0
    @State private var stepStart = Date()
    @State private var started = Date()
    @State private var actual: [Int] = []
    @State private var now = Date()
    @State private var questions: [String] = []
    @State private var answers: [String] = []
    @State private var scored: [[String: Any]] = []
    @State private var overall = ""
    @State private var busy = false
    @State private var error = ""

    private var lang: String { FollowUpWindow.language(of: base + ".brief.md") }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("rehearse.note")).font(PN.Font.caption).foregroundStyle(PN.C.text3)
            switch phase {
            case .steps: stepsView
            case .questions: questionsView
            case .result: resultView
            }
            if !error.isEmpty { Text(error).font(PN.Font.caption).foregroundStyle(PN.C.danger) }
            Spacer(minLength: 0)
        }
        .padding(22)
        .background(PN.C.bg)
        .onAppear { steps = RehearsalWindow.steps(base: base); stepStart = Date(); started = Date() }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { now = $0 }
    }

    @ViewBuilder private var stepsView: some View {
        if steps.isEmpty {
            Text(L("rehearse.noSteps")).font(PN.Font.body).foregroundStyle(PN.C.text2)
            Button(L("rehearse.toQuestions")) { toQuestions() }.buttonStyle(.pnPrimary)
        } else {
            let st = steps[min(index, steps.count - 1)]
            let left = st.secs - Int(now.timeIntervalSince(stepStart))
            HStack {
                Text(L("rehearse.step", ["i": "\(index + 1)", "n": "\(steps.count)"])).font(PN.Font.section).foregroundStyle(PN.C.text2)
                Spacer()
                Text(Self.mmss(left)).font(.system(size: 28, weight: .semibold).monospacedDigit()).foregroundStyle(left < 0 ? PN.C.danger : PN.C.text)
            }
            Text(st.title).font(PN.Font.title).foregroundStyle(PN.C.text)
            ScrollView { Text(st.say).font(.system(size: 18)).foregroundStyle(PN.C.text).frame(maxWidth: .infinity, alignment: .leading) }
            HStack(spacing: 8) {
                Button(L("present.back")) { move(-1) }.buttonStyle(.pnSecondary).disabled(index == 0)
                Spacer()
                Text(L("rehearse.total", ["t": Self.mmss(Int(now.timeIntervalSince(started)))])).font(PN.Font.caption).foregroundStyle(PN.C.text3)
                if index < steps.count - 1 {
                    Button(L("present.next")) { move(1) }.buttonStyle(.pnPrimary).keyboardShortcut(.rightArrow, modifiers: [])
                } else {
                    Button(L("rehearse.toQuestions")) { record(); toQuestions() }.buttonStyle(.pnPrimary)
                }
            }
        }
    }

    @ViewBuilder private var questionsView: some View {
        if busy && questions.isEmpty {
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text(L("rehearse.thinking")).foregroundStyle(PN.C.text2) }
        }
        if !actual.isEmpty {
            Text(L("rehearse.timing", ["plan": Self.mmss(steps.reduce(0) { $0 + $1.secs }), "real": Self.mmss(actual.reduce(0, +))]))
                .font(PN.Font.caption).foregroundStyle(PN.C.text3)
        }
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(questions.enumerated()), id: \.offset) { i, q in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(i + 1). " + q).font(PN.Font.body.weight(.semibold)).foregroundStyle(PN.C.text).fixedSize(horizontal: false, vertical: true)
                        TextEditor(text: Binding(get: { i < answers.count ? answers[i] : "" }, set: { if i < answers.count { answers[i] = $0 } }))
                            .font(PN.Font.body).frame(minHeight: 60)
                            .overlay(RoundedRectangle(cornerRadius: PN.Radius.s).stroke(PN.C.text3.opacity(0.3)))
                    }
                }
            }
        }
        if !questions.isEmpty {
            HStack {
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button(L("rehearse.score")) { score() }.buttonStyle(.pnPrimary).disabled(busy)
            }
        }
    }

    @ViewBuilder private var resultView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if !overall.isEmpty { Text(overall).font(PN.Font.body.weight(.semibold)).foregroundStyle(PN.C.text).fixedSize(horizontal: false, vertical: true) }
                ForEach(Array(scored.enumerated()), id: \.offset) { i, a in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text("\(i + 1). " + (a["q"] as? String ?? "")).font(PN.Font.body.weight(.semibold)).foregroundStyle(PN.C.text).fixedSize(horizontal: false, vertical: true)
                            Spacer()
                            Text(L("rehearse.scoreOf", ["n": "\(a["score"] as? Int ?? 0)"])).font(PN.Font.section).foregroundStyle((a["score"] as? Int ?? 0) >= 4 ? PN.C.turn : PN.C.onMe)
                        }
                        if let f = a["feedback"] as? String, !f.isEmpty { Text(f).font(PN.Font.body).foregroundStyle(PN.C.text2).fixedSize(horizontal: false, vertical: true) }
                        if let b = a["better"] as? String, !b.isEmpty { Text(L("rehearse.better", ["text": b])).font(PN.Font.caption).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true) }
                    }
                }
            }
        }
        HStack {
            Spacer()
            Button(L("rehearse.again")) { phase = .steps; index = 0; actual = []; questions = []; answers = []; scored = []; overall = ""; stepStart = Date(); started = Date() }
                .buttonStyle(.pnSecondary)
        }
    }

    static func mmss(_ s: Int) -> String { (s < 0 ? "+" : "") + String(format: "%d:%02d", abs(s) / 60, abs(s) % 60) }

    private func record() { actual.append(Int(Date().timeIntervalSince(stepStart))) }

    private func move(_ d: Int) {
        if d > 0 { record() } else if !actual.isEmpty { actual.removeLast() }
        index = max(0, min(steps.count - 1, index + d)); stepStart = Date()
    }

    private func toQuestions() {
        phase = .questions; busy = true; error = ""
        let c = AppConfig.load(from: AppPaths.config)
        PyTool.run("rehearse", ["questions", "--base", base, "--lang", lang, "--model", c.models.tip]) { r in
            busy = false
            if (r["ok"] as? Bool) == true {
                questions = (r["questions"] as? [String]) ?? []; answers = Array(repeating: "", count: questions.count)
            } else { error = L("rehearse.failed", ["err": r["error"] as? String ?? ""]) }
        }
    }

    private func score() {
        busy = true; error = ""
        let c = AppConfig.load(from: AppPaths.config)
        let tmp = (NSTemporaryDirectory() as NSString).appendingPathComponent("pacenote-rehearsal-\(UUID().uuidString).json")
        let list = zip(questions, answers).map { ["q": $0.0, "a": $0.1] }
        if let d = try? JSONSerialization.data(withJSONObject: list) { try? d.write(to: URL(fileURLWithPath: tmp)) }
        PyTool.run("rehearse", ["score", "--base", base, "--answers", tmp, "--lang", L10n.lang, "--model", c.models.tip]) { r in
            busy = false
            try? FileManager.default.removeItem(atPath: tmp)
            if (r["ok"] as? Bool) == true {
                scored = (r["answers"] as? [[String: Any]]) ?? []; overall = r["overall"] as? String ?? ""; phase = .result
            } else { error = L("rehearse.failed", ["err": r["error"] as? String ?? ""]) }
        }
    }
}
