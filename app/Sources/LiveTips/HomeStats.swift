import SwiftUI
import Charts
import LiveTipsCore

/// 2026-10-28 (owner): Home's dashboard, interactive: a period (today, this or last week, this month, 30 days,
/// your own dates), a project or workspace, and a click on a day to see that day. Calls, time on calls, Claude
/// spend and prepared calls against the period before; minutes per day by project; the calls of the selection.
/// From the call history (the app's and the skill's transcripts) and the day ledger of Claude spend.
struct WeekStats: View {
    @ObservedObject var history = CallHistory.shared
    var compact = false                                           // a narrow Home: lower chart, tiles in one row
    @AppStorage("statsPeriod") private var period = "week"
    @AppStorage("statsScope") private var scope = ""            // "" = all, "p:<name>", "w:<name>"
    @State private var from = Calendar.current.date(byAdding: .day, value: -13, to: Date()) ?? Date()
    @State private var to = Date()
    @State private var day: Date?                                 // a clicked bar
    @State private var showCalls = false

    private struct Bar: Identifiable { var id: String { "\(date.timeIntervalSince1970)" + project }; var date: Date; var project: String; var minutes: Double }

    static var periods: [(String, String)] { ["today", "week", "lastweek", "month", "30", "custom"].map { ($0, L("stats.period." + $0)) } }

    /// [start, end) of the chosen period.
    private func range(_ now: Date = Date()) -> (Date, Date) {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        let tomorrow = cal.date(byAdding: .day, value: 1, to: today) ?? now
        switch period {
        case "today": return (today, tomorrow)
        case "lastweek":
            let ws = cal.dateInterval(of: .weekOfYear, for: now)?.start ?? today
            return (cal.date(byAdding: .day, value: -7, to: ws) ?? ws, ws)
        case "month": return (cal.dateInterval(of: .month, for: now)?.start ?? today, tomorrow)
        case "30": return (cal.date(byAdding: .day, value: -29, to: today) ?? today, tomorrow)
        case "custom":
            let a = cal.startOfDay(for: min(from, to)), b = cal.startOfDay(for: max(from, to))
            return (a, cal.date(byAdding: .day, value: 1, to: b) ?? b)
        default: return (cal.dateInterval(of: .weekOfYear, for: now)?.start ?? today, tomorrow)
        }
    }

    /// Project names a scope covers (a workspace: its projects and its own general calls).
    private func inScope(_ r: CallHistory.Record) -> Bool {
        if scope.isEmpty { return true }
        if scope.hasPrefix("p:") { return r.project == String(scope.dropFirst(2)) }
        let w = String(scope.dropFirst(2))
        let reg = ProjectRegistry.load(from: AppPaths.projects)
        guard let ws = reg.workspaces.first(where: { $0.name == w }) else { return r.project == w }
        let names = Set(reg.projects.filter { ws.projects.contains($0.slug) }.map(\.name) + [ws.name])
        return names.contains(r.project)
    }

    private var scopes: (projects: [String], workspaces: [String]) {
        let reg = ProjectRegistry.load(from: AppPaths.projects)
        let seen = Set(history.records.map(\.project))
        let ps = Set(reg.projects.filter { $0.status != "archived" }.map(\.name)).union(seen.subtracting(reg.workspaces.map(\.name)))
        return (ps.sorted(), reg.workspaces.map(\.name).sorted())
    }

    var body: some View {
        let cal = Calendar.current
        let (start, end) = day.map { (cal.startOfDay(for: $0), cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: $0)) ?? $0) } ?? range()
        let span = end.timeIntervalSince(start)
        let prevStart = start.addingTimeInterval(-span)
        let recs = history.records.filter { inScope($0) }
        let this = recs.filter { $0.start >= start && $0.start < end }.sorted { $0.start > $1.start }
        let prev = recs.filter { $0.start >= prevStart && $0.start < start }
        let mins = this.reduce(0) { $0 + ($1.minutes ?? 0) }
        let prevMins = prev.reduce(0) { $0 + ($1.minutes ?? 0) }
        // Spend: the day ledger for everything; per call (tips and Notion summary) when a project is chosen.
        let spend = scope.isEmpty ? SpendDays.total(from: start, to: min(end, Date().addingTimeInterval(1))) : this.reduce(0) { $0 + ($1.costUSD ?? 0) }
        let prevSpend = scope.isEmpty ? SpendDays.total(from: prevStart, to: start) : prev.reduce(0) { $0 + ($1.costUSD ?? 0) }
        let prepared = this.filter { $0.prepared == true }.count
        let (rs, re) = range()
        let bars: [Bar] = Dictionary(grouping: recs.filter { $0.start >= rs && $0.start < re }, by: { "\(cal.startOfDay(for: $0.start).timeIntervalSince1970)|" + $0.project })
            .map { k, v in Bar(date: cal.startOfDay(for: v[0].start), project: v[0].project, minutes: v.reduce(0) { $0 + ($1.minutes ?? 0) }) }
            .sorted { ($0.date, $0.project) < ($1.date, $1.project) }      // QA: the same stack order every day
        let longest = this.max { ($0.minutes ?? 0) < ($1.minutes ?? 0) }
        let busiest = Dictionary(grouping: this, by: { cal.startOfDay(for: $0.start) }).mapValues { $0.reduce(0) { $0 + ($1.minutes ?? 0) } }.max { $0.value < $1.value }
        let sc = scopes
        let df = DateFormatter(); df.dateFormat = "EEE d MMM"

        return VStack(alignment: .leading, spacing: 10) {
            // 2026-10-28: one line when there is room, the pickers under the title in a narrow column.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { Text(L("stats.title")).font(.headline).fixedSize(); Spacer(); pickers(sc) }
                VStack(alignment: .leading, spacing: 6) { Text(L("stats.title")).font(.headline); HStack(spacing: 8) { pickers(sc) } }
            }
            if period == "custom" && day == nil {
                HStack(spacing: 6) {
                    DatePicker(L("stats.from"), selection: $from, displayedComponents: .date).fixedSize()
                    DatePicker(L("stats.to"), selection: $to, displayedComponents: .date).fixedSize()
                }
                .font(PN.Font.caption)
            }
            if let d = day {
                HStack(spacing: 6) {
                    Label(df.string(from: d), systemImage: "calendar").font(PN.Font.caption.weight(.semibold))
                    Button { day = nil } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.borderless).accessibilityLabel(L("stats.clear")).foregroundStyle(PN.C.text3)
                        .help(L("stats.backToTheWhole"))
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: compact ? 120 : 150), spacing: 10)], spacing: 10) {
                // Pacenote 0.8 (F3): no dollars here, they live in Settings > AI.
                tile(L("stats.calls"), "\(this.count)", delta(Double(this.count), Double(prev.count), fmt: { "\(Int($0))" }))
                tile(L("stats.onCalls"), hm(mins), delta(mins, prevMins, fmt: hm))
                tile(L("stats.prepared"), this.isEmpty ? "-" : L("home.week.preparedOf", ["x": "\(prepared)", "y": "\(this.count)"]), this.isEmpty ? "" : "\(Int((Double(prepared) / Double(max(1, this.count)) * 100).rounded()))%")
            }
            if !compact && !this.isEmpty { quality(this) }
            if !bars.isEmpty {
                Chart(bars) { b in
                    BarMark(x: .value(LocalizedStringKey(L("stats.axisDay")), b.date, unit: .day), y: .value(LocalizedStringKey(L("stats.axisMinutes")), b.minutes))
                        .foregroundStyle(by: .value(LocalizedStringKey(L("stats.axisProject")), b.project))
                        .opacity(day == nil || cal.isDate(b.date, inSameDayAs: day!) ? 1 : 0.35)
                }
                .chartXScale(domain: rs...re.addingTimeInterval(-1))
                .chartXAxis { AxisMarks(values: .stride(by: .day, count: re.timeIntervalSince(rs) > 9 * 86400 ? 5 : 1)) { _ in AxisGridLine(); AxisValueLabel(format: re.timeIntervalSince(rs) > 9 * 86400 ? .dateTime.day().month() : .dateTime.weekday(.abbreviated)) } }
                .chartYAxisLabel("min")
                .chartYAxis { AxisMarks(position: .trailing, values: .automatic(desiredCount: compact ? 2 : 4)) }
                .chartLegend(position: .bottom, alignment: .leading)
                .chartOverlay { proxy in
                    GeometryReader { geo in
                        Rectangle().fill(.clear).contentShape(Rectangle())
                            .onTapGesture { p in
                                guard let f = proxy.plotFrame else { return }
                                let x = p.x - geo[f].origin.x
                                if let d: Date = proxy.value(atX: x) {
                                    let dd = cal.startOfDay(for: d)
                                    day = (day.map { cal.isDate($0, inSameDayAs: dd) } ?? false) ? nil : dd
                                }
                            }
                    }
                }
                .frame(height: compact ? 96 : 160)
                .help(L("stats.clickDay"))
            } else {
                Text(L("stats.empty")).font(.callout).foregroundStyle(PN.C.text3)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { facts(longest, busiest, this, mins, spend) }
                VStack(alignment: .leading, spacing: 4) { facts(longest, busiest, this, mins, spend) }
            }
            .font(PN.Font.caption)
            if !this.isEmpty {
                DisclosureGroup(isExpanded: $showCalls) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(this) { r in
                            HStack(spacing: 6) {
                                Text(df.string(from: r.start) + " " + r.start.formatted(date: .omitted, time: .shortened)).monospacedDigit().foregroundStyle(PN.C.text3)
                                Text(r.title).lineLimit(1)
                                Spacer()
                                Text(hm(r.minutes ?? 0)).monospacedDigit().foregroundStyle(PN.C.text3)
                                if let c = r.costUSD, c > 0 { Text(String(format: "$%.2f", c)).monospacedDigit().foregroundStyle(PN.C.text3) }
                            }
                            .font(PN.Font.caption)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { NSWorkspace.shared.open(URL(fileURLWithPath: r.file)) }
                            .help(L("stats.doubleClickToOpen"))
                        }
                    }
                    .padding(.top, 4)
                } label: { Text(L("stats.selection", ["n": "\(this.count)"])).font(PN.Font.caption.weight(.semibold)) }
            }
        }
        .ltCard(padding: 14)
        .onAppear { history.fillDetails() }
    }

    /// Pacenote 0.8 (idea 07): how the calls went, from their own files. No dollars (they live in Settings > AI).
    @ViewBuilder private func quality(_ calls: [CallHistory.Record]) -> some View {
        let ms = calls.map { ($0, CallMetrics.shared.of($0.file)) }
        let shares = ms.compactMap { $0.1.talkShare }
        let open = ms.reduce(0) { $0 + $1.1.unanswered }
        let noDecision = ms.filter { $0.1.hasPicture && $0.1.decisions == 0 }.count
        let prep = ms.filter { $0.0.prepared == true }, noPrep = ms.filter { $0.0.prepared != true }
        VStack(alignment: .leading, spacing: 6) {
            Text(L("stats.quality")).font(PN.Font.caption.weight(.semibold)).foregroundStyle(PN.C.text2)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                tile(L("stats.talkShare"), shares.isEmpty ? "-" : "\(Int((shares.reduce(0, +) / Double(shares.count) * 100).rounded()))%", L("stats.talkShare.sub"))
                tile(L("stats.unanswered"), "\(open)", L("stats.unanswered.sub"))
                tile(L("stats.noDecision"), "\(noDecision)", L("stats.noDecision.sub", ["n": "\(calls.count)"]))
            }
            Text(L("stats.prepVsNot", ["a": Self.perCall(prep), "b": Self.perCall(noPrep)])).font(PN.Font.caption).foregroundStyle(PN.C.text3)
        }
    }

    private static func perCall(_ xs: [(CallHistory.Record, CallMetrics.Result)]) -> String {
        xs.isEmpty ? "-" : String(format: "%.1f", Double(xs.reduce(0) { $0 + $1.1.decisions }) / Double(xs.count))
    }

    @ViewBuilder private func facts(_ longest: CallHistory.Record?, _ busiest: (key: Date, value: Double)?, _ this: [CallHistory.Record], _ mins: Double, _ spend: Double) -> some View {
        let wd = Self.dayFmt
        if let l = longest, (l.minutes ?? 0) > 0 { fact(L("stats.longest"), "\(l.title), \(hm(l.minutes ?? 0))") }
        if day == nil, let b = busiest, b.value > 0 { fact(L("stats.busiest"), "\(wd.string(from: b.key)), \(hm(b.value))") }
        if !this.isEmpty { fact(L("stats.average"), hm(mins / Double(this.count))) }
    }

    @ViewBuilder private func pickers(_ sc: (projects: [String], workspaces: [String])) -> some View {
        Picker("", selection: Binding(get: { period }, set: { period = $0; day = nil })) {
            ForEach(Self.periods, id: \.0) { Text($0.1).tag($0.0) }
        }
        .labelsHidden().fixedSize()
        Picker("", selection: $scope) {
            Text(L("stats.allProjects")).tag("")
            if !sc.workspaces.isEmpty { Section(L("stats.workspaces")) { ForEach(sc.workspaces, id: \.self) { Text($0).tag("w:" + $0) } } }
            Section(L("stats.projects")) { ForEach(sc.projects, id: \.self) { Text($0).tag("p:" + $0) } }
        }
        .labelsHidden().fixedSize()
    }

    static let dayFmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "EEE d MMM"; return f }()

    private func hm(_ m: Double) -> String { HomeView.hm(m) }

    private func delta(_ a: Double, _ b: Double, fmt: (Double) -> String) -> String {
        guard b > 0 else { return a > 0 ? L("stats.noneBefore") : "" }
        let d = a - b
        return L("stats.vsBefore", ["d": (d >= 0 ? "+" : "-") + fmt(abs(d))])
    }

    private func tile(_ label: String, _ value: String, _ sub: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(PN.Font.caption).foregroundStyle(PN.C.text3)
            Text(value).font(compact ? .headline : .title3.weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            Text(sub).font(PN.Font.caption).foregroundStyle(PN.C.text3).lineLimit(1)
        }
        .padding(compact ? 7 : 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
    }

    private func fact(_ label: String, _ value: String) -> some View {
        HStack(spacing: 4) { Text(label + ":").foregroundStyle(PN.C.text3); Text(value).lineLimit(1) }
    }
}

/// Pacenote 0.8 (idea 07): what a held call says about itself, read once per file version.
@MainActor
final class CallMetrics {
    static let shared = CallMetrics()
    struct Result { var talkShare: Double?; var unanswered = 0; var decisions = 0; var hasPicture = false }
    private var cache: [String: (Date, Result)] = [:]
    private lazy var me = PyTool.meLabel

    func of(_ file: String) -> Result {
        let m = ((try? FileManager.default.attributesOfItem(atPath: file))?[.modificationDate] as? Date) ?? .distantPast
        if let c = cache[file], c.0 == m { return c.1 }
        var r = Result()
        let lines = TranscriptLine.read(file, me: me)
        let words = { (l: TranscriptLine) in l.text.split(separator: " ").count }
        let all = lines.reduce(0) { $0 + words($1) }, mine = lines.filter { $0.me }.reduce(0) { $0 + words($1) }
        if all > 50 { r.talkShare = Double(mine) / Double(all) }
        if let o = CallOutcome.read(transcript: file) {
            r.hasPicture = true; r.decisions = o.decisions.count; r.unanswered = o.openQuestions.count
        }
        cache[file] = (m, r)
        return r
    }
}
