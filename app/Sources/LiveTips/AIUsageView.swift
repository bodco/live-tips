import SwiftUI
import LiveTipsCore

/// 0.9.3 (owner, 2026-11-04): Settings > Usage, AI through API keys. Every provider with a key (Claude, OpenAI, Gemini;
/// also one without a key that has spend in the period), spend by stage (preparation, live tips, after the call, total)
/// and by model, for a day, the last 7 days (the default), this month or chosen dates. From state/spend-ledger.jsonl
/// (AIUsage); the Claude and ChatGPT accounts are paid by their plans and are not here.
struct AIUsageView: View {
    @AppStorage("aiUsagePeriod") private var period = "week"
    @State private var from = Calendar.current.date(byAdding: .day, value: -6, to: Date()) ?? Date()
    @State private var to = Date()
    @State private var rows: [AIUsage.Row] = []

    static let periods = ["day", "week", "month", "custom"]

    static var ledgerPath: String {
        ((AIRoute.statePath as NSString).deletingLastPathComponent as NSString).appendingPathComponent("spend-ledger.jsonl")
    }

    private static func day(_ d: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    /// The first and the last day of the period, both included.
    private var range: (String, String) {
        let cal = Calendar.current, now = Date()
        switch period {
        case "day": return (Self.day(now), Self.day(now))
        case "month": return (Self.day(cal.dateInterval(of: .month, for: now)?.start ?? now), Self.day(now))
        case "custom": return (Self.day(min(from, to)), Self.day(max(from, to)))
        default: return (Self.day(cal.date(byAdding: .day, value: -6, to: now) ?? now), Self.day(now))
        }
    }

    private var connected: [String] {
        let s = SecretStore(service: Bundle.main.bundleIdentifier ?? "io.github.example.livetips")
        return AIUsage.providers.filter { p in
            s.has(p == "claude" ? .claudeAPIKey : p == "openai" ? .openaiAPIKey : .geminiAPIKey)     // presence only
        }
    }

    static func name(_ p: String) -> String { p == "claude" ? "Claude" : p == "openai" ? "OpenAI" : "Gemini" }
    static func usd(_ v: Double) -> String { v <= 0 ? "$0" : v < 0.01 ? "<$0.01" : String(format: "$%.2f", v) }
    static func tok(_ n: Int) -> String {
        n >= 1_000_000 ? String(format: "%.1fM", Double(n) / 1_000_000) : n >= 1000 ? String(format: "%.0fK", Double(n) / 1000) : "\(n)"
    }

    var body: some View {
        let (a, b) = range
        let sel = AIUsage.filter(rows, from: a, to: b)
        let keyed = connected
        let shown = AIUsage.providers.filter { p in keyed.contains(p) || sel.contains { $0.provider == p } }
        let models = AIUsage.byModel(sel)
        let stages = AIUsage.byStage(sel)
        let total = AIUsage.total(sel)
        VStack(alignment: .leading, spacing: 12) {
            Text(L("aiusage.title")).font(PN.Font.section)
            Text(L("aiusage.sub")).font(PN.Font.caption).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
            Picker("", selection: $period) {
                ForEach(Self.periods, id: \.self) { p in Text(L("aiusage.period." + p)).tag(p) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 420)
            if period == "custom" {
                HStack(spacing: 12) {
                    DatePicker(L("aiusage.from"), selection: $from, displayedComponents: .date)
                    DatePicker(L("aiusage.to"), selection: $to, displayedComponents: .date)
                }
                .frame(maxWidth: 420)
            }
            if shown.isEmpty {
                Text(L("aiusage.noKeys")).font(PN.Font.caption).foregroundStyle(PN.C.text3)
            } else {
                Text(L("aiusage.totalLine", ["usd": Self.usd(total.usd), "n": "\(total.requests)",
                                             "in": Self.tok(total.input), "out": Self.tok(total.output)]))
                    .font(PN.Font.body.weight(.semibold)).monospacedDigit()
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("aiusage.byStage")).font(PN.Font.label).foregroundStyle(PN.C.text3)
                    cells(Self.headCells(shown), header: true)
                    ForEach(AIUsage.stages, id: \.self) { s in
                        cells(Self.stageCells(s, stages[s] ?? [:], shown))
                    }
                    cells(Self.totalCells(sel, shown, total), header: true)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("aiusage.byModel")).font(PN.Font.label).foregroundStyle(PN.C.text3)
                    cells([L("aiusage.model"), L("aiusage.requests"), L("aiusage.input"), L("aiusage.output"), "$"], header: true)
                    if models.isEmpty {
                        Text(L("aiusage.none")).font(PN.Font.caption).foregroundStyle(PN.C.text3)
                    }
                    ForEach(models.indices, id: \.self) { i in
                        cells(Self.modelCells(models[i].provider, models[i].model, models[i].total))
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
        .task { await reload() }
    }

    // The table rows as plain text cells (kept out of the view builder so the type checker stays fast).
    static func headCells(_ shown: [String]) -> [String] {
        var out = [L("aiusage.stage")]
        for p in shown { out.append(name(p)) }
        out.append(L("aiusage.total"))
        return out
    }

    static func stageCells(_ stage: String, _ per: [String: AIUsage.Total], _ shown: [String]) -> [String] {
        var out = [L("aiusage.stage." + stage)]
        var sum = 0.0
        for p in shown {
            let v = per[p]?.usd ?? 0
            sum += v
            out.append(usd(v))
        }
        out.append(usd(sum))
        return out
    }

    static func totalCells(_ rows: [AIUsage.Row], _ shown: [String], _ total: AIUsage.Total) -> [String] {
        var out = [L("aiusage.total")]
        for p in shown {
            var v = 0.0
            for r in rows where r.provider == p { v += r.usd }
            out.append(usd(v))
        }
        out.append(usd(total.usd))
        return out
    }

    static func modelCells(_ provider: String, _ model: String, _ t: AIUsage.Total) -> [String] {
        [name(provider) + " · " + model, String(t.requests), tok(t.input), tok(t.output), usd(t.usd)]
    }

    private func cells(_ values: [String], header: Bool = false) -> some View {
        HStack(spacing: 8) {
            ForEach(values.indices, id: \.self) { i in
                Text(values[i])
                    .font(header ? PN.Font.caption.weight(.semibold) : PN.Font.caption)
                    .monospacedDigit()
                    .lineLimit(1)
                    .frame(width: i == 0 ? 240 : 90, alignment: i == 0 ? .leading : .trailing)
            }
        }
    }

    private func reload() async {
        let path = Self.ledgerPath
        rows = await Task.detached(priority: .utility) { AIUsage.load(path: path) }.value
    }
}
