import AppKit
import LiveTipsCore
import SwiftUI

/// 0.25 (R4, board ST): the Statistics screen behind Home > This week > Statistics (route `.stats`).
/// The bar, a meta line with the period and what it is compared with, the 40 pt title with the period buttons and the
/// scope on the right; four big numbers under a heavy rule; minutes on calls by day as stacked bars by project (a click
/// on a day selects it, a second click goes back); the calls of the selection; on the right how the calls went, the
/// period in short and AI this month. The numbers come from CallStats (hidden calls never count), CallMetrics, the day
/// ledger of spend and the AI status. WeekStats (Settings > Usage) stays as it was.
struct StatsScreen: View {
    @ObservedObject var history = CallHistory.shared
    @ObservedObject var ai = AIStatusModel.shared
    @AppStorage("statsPeriod") private var period = "week"
    @AppStorage("statsScope2") private var scope = ""
    @AppStorage("statsSales") private var salesOnly = false
    @State private var from = Calendar.current.date(byAdding: .day, value: -13, to: Date()) ?? Date()
    @State private var to = Date()
    @State private var day: Date? = StatsScreen.shotDay
    @State private var allCalls = false
    @Environment(\.pnTheme) private var t
    @State private var width: CGFloat = 1280
    private var wide: Bool { width >= 900 }
    /// 0.25 (QA): the Ukrainian title and period buttons are longer; below this they go to their own row
    private var headWide: Bool { width >= (L10n.lang == "uk" ? 1180 : 900) }

    /// ShotMode: the day selected on the picture of a selected day.
    static var shotDay: Date?
    static let shotNote = Notification.Name("pnStatsShotDay")

    // MARK: data

    struct DayBar: Identifiable {
        var id: Date { date }
        let date: Date
        var parts: [(key: String, minutes: Double)]
        var calls: Int
        var total: Double { parts.reduce(0) { $0 + $1.minutes } }
    }

    struct Model {
        var start = Date(), end = Date()                  // the period (or the selected day)
        var rangeStart = Date(), rangeEnd = Date()        // the period of the bars
        var this: [CallHistory.Record] = []
        var prev: [CallHistory.Record] = []
        var bars: [DayBar] = []
        var legend: [(key: String, name: String)] = []    // the projects with a colour, most minutes first
    }

    private var cal: Calendar { CallStats.calendar }

    /// [start, end) of the chosen period; a week runs Monday to Sunday, a month to its last day (the bars show the
    /// whole period, the numbers count what has happened).
    private func range(_ now: Date = Date()) -> (Date, Date) {
        let today = cal.startOfDay(for: now)
        let tomorrow = cal.date(byAdding: .day, value: 1, to: today) ?? now
        switch period {
        case "today": return (today, tomorrow)
        case "lastweek":
            let ws = CallStats.weekStart(now)
            return (cal.date(byAdding: .day, value: -7, to: ws) ?? ws, ws)
        case "month":
            let m = cal.dateInterval(of: .month, for: now)
            return (m?.start ?? today, m?.end ?? tomorrow)
        case "30": return (cal.date(byAdding: .day, value: -29, to: today) ?? today, tomorrow)
        case "custom":
            let a = cal.startOfDay(for: min(from, to)), b = cal.startOfDay(for: max(from, to))
            return (a, cal.date(byAdding: .day, value: 1, to: b) ?? b)
        default:
            let ws = CallStats.weekStart(now)
            return (ws, cal.date(byAdding: .day, value: 7, to: ws) ?? tomorrow)
        }
    }

    private func model() -> Model {
        var m = Model()
        let (rs, re) = range()
        m.rangeStart = rs; m.rangeEnd = re
        if let d = day { m.start = cal.startOfDay(for: d); m.end = cal.date(byAdding: .day, value: 1, to: m.start) ?? d } else { (m.start, m.end) = (rs, re) }
        // The period before: the same days one period back (a week: the same days of the week before).
        let back: DateComponents = {
            if day != nil || period == "today" { return DateComponents(day: -1) }
            switch period {
            case "week", "lastweek": return DateComponents(day: -7)
            case "month": return DateComponents(month: -1)
            default: return DateComponents(second: -Int(m.end.timeIntervalSince(m.start)))
            }
        }()
        let recs = CallStats.calls(scope: scope, salesOnly: salesOnly)
        let now = Date()
        let shownEnd = min(m.end, now)
        m.this = recs.filter { $0.start >= m.start && $0.start < m.end }.sorted { $0.start < $1.start }
        let ps = cal.date(byAdding: back, to: m.start) ?? m.start, pe = cal.date(byAdding: back, to: max(shownEnd, m.start)) ?? m.start
        m.prev = recs.filter { $0.start >= ps && $0.start < pe }
        // The bars: every day of the period, the minutes of each project stacked.
        let inRange = recs.filter { $0.start >= rs && $0.start < re }
        var byKey: [String: Double] = [:]
        for r in inRange { byKey[CallStats.key(r), default: 0] += r.minutes ?? 0 }
        let ordered = byKey.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
        let colored = Array(ordered.prefix(ordered.count > 4 ? 3 : 4))
        m.legend = colored.map { k in (key: k, name: CallStats.name(ofKey: k, fallback: inRange.first { CallStats.key($0) == k }?.project ?? k)) }
        if ordered.count > colored.count { m.legend.append((key: "", name: L("stats.other"))) }
        var d = rs
        while d < re {
            let next = cal.date(byAdding: .day, value: 1, to: d) ?? re
            let rows = inRange.filter { $0.start >= d && $0.start < next }
            var parts: [String: Double] = [:]
            for r in rows { let k = CallStats.key(r); parts[colored.contains(k) ? k : "", default: 0] += r.minutes ?? 0 }
            m.bars.append(DayBar(date: d, parts: m.legend.compactMap { l in parts[l.key].map { (key: l.key, minutes: $0) } }, calls: rows.count))
            d = next
        }
        return m
    }

    /// The colours of the projects (board p1, p2, p3), then a quiet one for the rest.
    private var palette: [Color] {
        let hex: [UInt32]
        switch (t.style, t.dark) {
        case (.roadbook, true): hex = [0xFFD60A, 0xF1EDE3, 0x6B685F, 0x3A3A33]
        case (.roadbook, false): hex = [0x0D0D0B, 0xFFD60A, 0xA8A59C, 0xCFCDC5]
        case (.broadsheet, false): hex = [0x2B2BF0, 0x0B0B0C, 0xB8B8BE, 0xE3E3E6]
        case (.broadsheet, true): hex = [0x4F4BFF, 0xF4F4F5, 0x5A5A60, 0x2A2A2E]
        case (_, true): hex = [0x4D9DFF, 0x30D158, 0xFF9F0A, 0x636366]
        default: hex = [0x0A6CFF, 0x34C759, 0xFF9F0A, 0xC7C7CC]
        }
        return hex.map { Color(pnHex: $0) }
    }

    private func color(_ key: String, _ m: Model) -> Color {
        let p = palette
        guard !key.isEmpty, let i = m.legend.firstIndex(where: { $0.key == key }) else { return p[3] }
        return p[min(i, 3)]
    }

    // MARK: body

    var body: some View {
        let m = model()
        return VStack(spacing: 0) {
            PageBackBar(crumb: L("home.week.detailsTitle"))
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header(m)
                    if period == "custom" && day == nil { customDates }
                    kpis(m)
                    PageColumns(side: 380) {
                        VStack(alignment: .leading, spacing: 26) {
                            chartSection(m)
                            selectionSection(m)
                        }
                    } right: {
                        VStack(alignment: .leading, spacing: 26) {
                            qualitySection(m)
                            shortSection(m)
                            aiSection
                        }
                    }
                    .padding(.horizontal, PageMetrics.side).padding(.top, 26).padding(.bottom, 36)
                }
                .environment(\.pageFlat, true)
                .environment(\.pageWide, wide)
                .background(GeometryReader { g in
                    Color.clear.onAppear { width = g.size.width }.onChange(of: g.size.width) { _, w in width = w }
                })
            }
        }
        .background(PN.C.bg)
        .onAppear { history.fillDetails(); ai.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: StatsScreen.shotNote)) { _ in day = StatsScreen.shotDay; allCalls = false }
    }

    // MARK: head

    private func lbl(_ s: String, _ size: CGFloat = 11) -> some View {
        Text(t.caps ? s.uppercased() : s).font(t.homeMono(size, t.labelWeight))
            .tracking(t.style == .classic ? 0 : t.lblTrack * size).foregroundStyle(PN.C.text3)
    }

    private func short(_ d: Date, _ f: String) -> String { CallPageView.fmt(f).string(from: d) }

    /// A fixed pattern ("EEE d MMM"), so a range reads "Mon 16 - Sun 22 Nov" (the templates add a comma in English).
    private func pattern(_ d: Date, _ p: String) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: L10n.lang == "uk" ? "uk_UA" : "en_GB"); f.dateFormat = p
        return f.string(from: d)
    }

    /// "Mon 16 - Sun 22 Nov · compared with the week before".
    private func metaLine(_ m: Model) -> String {
        let last = cal.date(byAdding: .day, value: -1, to: m.end) ?? m.start
        let span: String
        if cal.isDate(m.start, inSameDayAs: last) { span = pattern(m.start, "EEE d MMM") }
        else if cal.isDate(m.start, equalTo: last, toGranularity: .month) { span = pattern(m.start, "EEE d") + " - " + pattern(last, "EEE d MMM") }
        else { span = pattern(m.start, "d MMM") + " - " + pattern(last, "d MMM") }
        let vs = day != nil || period == "today" ? "day" : period == "week" || period == "lastweek" ? "week" : period == "month" ? "month" : "period"
        return span + " · " + L("stats.compared." + vs)
    }

    @ViewBuilder private func header(_ m: Model) -> some View {
        HStack(alignment: .bottom, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                lbl(metaLine(m))
                Text(t.cased(L("home.week.detailsTitle"))).font(t.homeDisplay(t.style == .classic ? 32 : 40, t.titleWeight))
                    .tracking(t.dTrack * 40).foregroundStyle(PN.C.text).lineLimit(1).fixedSize()
            }
            Spacer(minLength: 8)
            if headWide { periodButtons; scopeMenu }
        }
        .padding(.horizontal, PageMetrics.side).padding(.top, 24).padding(.bottom, headWide ? 18 : 12)
        if !headWide {
            HStack(spacing: 10) { periodButtons; scopeMenu; Spacer(minLength: 0) }
                .padding(.horizontal, PageMetrics.side).padding(.bottom, 18)
        }
    }

    /// The period as one row of boxed buttons; the chosen one on the action fill.
    private var periodButtons: some View {
        let shape = RoundedRectangle(cornerRadius: t.style == .classic ? 6 : 0)
        return HStack(spacing: 0) {
            ForEach(Array(WeekStats.periods.enumerated()), id: \.element.0) { i, p in
                let on = period == p.0
                Button { period = p.0; day = nil; allCalls = false } label: {
                    Text(t.cased(p.1)).font(t.homeDisplay(t.bSize, .bold)).tracking(t.bTrack * t.bSize).lineLimit(1)
                        .foregroundStyle(on ? PN.C.onAccent : PN.C.text)
                        .padding(.horizontal, 11).frame(height: 30)
                        .background(on ? PN.C.accentFill : Color.clear)
                        .overlay(alignment: .leading) { if i > 0 { Rectangle().fill(PN.C.rule).frame(width: 1) } }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? [.isSelected] : [])
            }
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(PN.C.ruleStrong, lineWidth: 1.5))
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("stats.period"))
    }

    private var scopeName: String {
        if scope.hasPrefix("w:") { return String(scope.dropFirst(2)) }
        if scope.hasPrefix("p:") { return CallStats.name(ofKey: String(scope.dropFirst(2))) }
        return L("stats.allProjects")
    }

    private var scopeMenu: some View {
        let reg = ProjectRegistry.load(from: AppPaths.projects)
        let projects = reg.projects.filter { $0.status != "archived" }.map { ($0.slug, $0.name) }.sorted { $0.1.lowercased() < $1.1.lowercased() }
        let wss = reg.workspaces.map(\.name).sorted()
        return Menu {
            Button(L("stats.allProjects")) { scope = ""; day = nil }
            if !wss.isEmpty { Section(L("stats.workspaces")) { ForEach(wss, id: \.self) { w in Button(w) { scope = "w:" + w; day = nil } } } }
            Section(L("stats.projects")) { ForEach(projects, id: \.0) { p in Button(p.1) { scope = "p:" + p.0; day = nil } } }
            Divider()
            Toggle(L("stats.salesOnly"), isOn: $salesOnly)
        } label: {
            HomeField(text: scopeName + (salesOnly ? " · " + L("stats.salesOnly") : ""), height: 30)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .accessibilityLabel(L("stats.scope") + ": " + scopeName)
    }

    private var customDates: some View {
        HStack(spacing: 10) {
            DatePicker(L("stats.from"), selection: $from, displayedComponents: .date).fixedSize()
            DatePicker(L("stats.to"), selection: $to, displayedComponents: .date).fixedSize()
        }
        .font(t.homeText(13))
        .padding(.horizontal, PageMetrics.side).padding(.bottom, 14)
    }

    // MARK: the big numbers

    private struct KPI: Identifiable { var id: String { label }; let label: String; let n: String; let unit: String; let sub: String }

    private func hm(_ m: Double) -> (String, String) {
        let v = Int(m.rounded())
        return v >= 60 ? (String(format: "%d:%02d", v / 60, v % 60), " " + L("stats.unit.h")) : ("\(v)", " " + L("stats.unit.min"))
    }

    private func vs(_ d: String) -> String {
        let k = day != nil || period == "today" ? "day" : period == "week" || period == "lastweek" ? "week" : period == "month" ? "month" : "period"
        return L("stats.vs." + k, ["d": d])
    }

    private func kpiList(_ m: Model) -> [KPI] {
        let mins = m.this.reduce(0) { $0 + ($1.minutes ?? 0) }, prevMins = m.prev.reduce(0) { $0 + ($1.minutes ?? 0) }
        let dc = m.this.count - m.prev.count
        let none = m.prev.isEmpty ? (m.this.isEmpty ? "" : L("stats.noneBefore")) : nil      // nothing to compare with
        let callsSub = none ?? vs((dc >= 0 ? "+" : "-") + "\(abs(dc))")
        let dm = mins - prevMins
        let hmD = hm(abs(dm))
        let minsSub = none ?? vs((dm >= 0 ? "+" : "-") + hmD.0 + (hmD.1 == " " + L("stats.unit.min") ? " " + L("stats.unit.min") : ""))
        let prepared = m.this.filter { $0.prepared == true }.count
        let without = m.this.count - prepared
        let on = hm(mins)
        var out = [KPI(label: L("stats.calls"), n: "\(m.this.count)", unit: "", sub: callsSub),
                   KPI(label: L("stats.onCalls"), n: on.0, unit: on.1, sub: minsSub),
                   KPI(label: L("stats.prepared"), n: m.this.isEmpty ? "-" : "\(prepared)", unit: m.this.isEmpty ? "" : "/\(m.this.count)",
                       sub: without > 0 ? L("stats.withoutSheet", ["n": "\(without)"]) : (m.this.isEmpty ? "" : L("stats.allPrepared")))]
        let days = Dictionary(grouping: m.this, by: { cal.startOfDay(for: $0.start) })
        if day == nil && period != "today", let b = days.max(by: { a, b in a.value.reduce(0) { $0 + ($1.minutes ?? 0) } < b.value.reduce(0) { $0 + ($1.minutes ?? 0) } }) {
            let bm = Int(b.value.reduce(0) { $0 + ($1.minutes ?? 0) }.rounded())
            out.append(KPI(label: L("stats.busiest"), n: short(b.key, period == "week" || period == "lastweek" ? "EEE" : "dMMM"), unit: "",
                           sub: L("stats.busiestSub", ["min": "\(bm)", "n": "\(b.value.count)"])))
        } else {
            let avg = m.this.isEmpty ? (String("-"), "") : hm(mins / Double(m.this.count))
            out.append(KPI(label: L("stats.average"), n: avg.0, unit: avg.1, sub: ""))
        }
        return out
    }

    private var numWeight: Font.Weight { t.style == .broadsheet ? .black : .heavy }
    private var numTrack: CGFloat { t.style == .broadsheet ? -0.06 : 0 }

    private func kpiCell(_ k: KPI, last: Bool) -> some View {
        let size = t.style == .classic ? 48 : min(t.bigNum, 80)
        return VStack(alignment: .leading, spacing: 8) {
            lbl(k.label)
            (Text(k.n).font(t.homeDisplay(size, numWeight)).tracking(numTrack * size)
             + Text(k.unit).font(t.homeDisplay(size * 0.34, numWeight)))
                .foregroundStyle(PN.C.text).lineLimit(1).minimumScaleFactor(0.5)
            Text(k.sub).font(t.homeMono(12, .semibold)).foregroundStyle(PN.C.text2).lineLimit(1)
        }
        .padding(.top, 16).padding(.bottom, 18).padding(.trailing, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .trailing) { if !last { Rectangle().fill(PN.C.rule).frame(width: 1) } }
        .padding(.trailing, last ? 0 : 16)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func kpis(_ m: Model) -> some View {
        let ks = kpiList(m)
        Group {
            if wide {
                HStack(alignment: .top, spacing: 0) { ForEach(Array(ks.enumerated()), id: \.element.id) { i, k in kpiCell(k, last: i == ks.count - 1) } }
            } else {
                VStack(spacing: 0) {
                    HStack(alignment: .top, spacing: 0) { ForEach(Array(ks.prefix(2).enumerated()), id: \.element.id) { i, k in kpiCell(k, last: i == 1) } }
                    Rectangle().fill(PN.C.rule).frame(height: 1)
                    HStack(alignment: .top, spacing: 0) { ForEach(Array(ks.dropFirst(2).enumerated()), id: \.element.id) { i, k in kpiCell(k, last: i == 1) } }
                }
            }
        }
        .overlay(alignment: .top) { Rectangle().fill(PN.C.ruleStrong).frame(height: t.ruleHeavy) }
        .overlay(alignment: .bottom) { Rectangle().fill(PN.C.rule).frame(height: 1) }
        .padding(.horizontal, PageMetrics.side)
    }

    // MARK: the chart

    private func chartSection(_ m: Model) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            PageSectionHead(title: L("stats.byDay")) {
                HStack(spacing: 14) {
                    ForEach(m.legend, id: \.key) { l in
                        HStack(spacing: 6) {
                            swatch(color(l.key, m))
                            Text(l.name).font(t.homeText(13)).foregroundStyle(PN.C.text2).lineLimit(1)
                        }
                    }
                }
            }
            if m.bars.allSatisfy({ $0.total == 0 }) {
                Text(L("stats.empty")).font(t.homeText(15)).foregroundStyle(PN.C.text3).pageRow(12)
            } else {
                bars(m)
                Text(day.map { L("stats.dayNote", ["day": short($0, "EEEE")]) } ?? L("stats.clickDay"))
                    .font(t.homeText(13)).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
            }
        }
    }

    private func swatch(_ c: Color) -> some View {
        Rectangle().fill(c).frame(width: 12, height: 12).overlay(Rectangle().strokeBorder(PN.C.field, lineWidth: 1)).accessibilityHidden(true)
    }

    private func bars(_ m: Model) -> some View {
        let maxM = max(1, m.bars.map(\.total).max() ?? 1)
        let many = m.bars.count > 10
        let plot: CGFloat = 210
        return HStack(alignment: .bottom, spacing: many ? 4 : 14) {
            ForEach(Array(m.bars.enumerated()), id: \.element.id) { i, b in
                let sel = day.map { cal.isDate($0, inSameDayAs: b.date) } ?? false
                Button {
                    day = sel ? nil : b.date; allCalls = false
                } label: {
                    VStack(spacing: 6) {
                        Text(b.total > 0 && (!many || sel) ? "\(Int(b.total.rounded()))" : " ")
                            .font(t.homeMono(11, .semibold)).foregroundStyle(PN.C.text2).lineLimit(1).fixedSize()
                        VStack(spacing: 0) {
                            ForEach(Array(b.parts.reversed().enumerated()), id: \.offset) { _, p in
                                Rectangle().fill(color(p.key, m))
                                    .frame(height: max(2, CGFloat(p.minutes / maxM) * plot))
                                    .overlay(alignment: .top) { Rectangle().fill(PN.C.bg).frame(height: 1) }
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(3)
                        .overlay(Rectangle().strokeBorder(sel ? PN.C.ruleStrong : .clear, lineWidth: 2))
                        Text(barLabel(b.date, i, many)).font(t.homeMono(12, sel ? .heavy : .regular))
                            .foregroundStyle(sel ? PN.C.text : PN.C.text3).lineLimit(1).fixedSize()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(short(b.date, "EEEEdMMMM") + ": " + L("stats.barA11y", ["min": "\(Int(b.total.rounded()))", "n": "\(b.calls)"]))
                .accessibilityAddTraits(sel ? [.isSelected] : [])
            }
        }
        .frame(height: plot + 60)
        .padding(.top, 14)
        .overlay(alignment: .top) { Rectangle().fill(PN.C.rule).frame(height: 1) }
        .help(L("stats.clickDay"))
    }

    private func barLabel(_ d: Date, _ i: Int, _ many: Bool) -> String {
        guard many else { return t.caps ? short(d, "EEE").uppercased() : short(d, "EEE") }
        let n = cal.component(.day, from: d)
        return (i == 0 || n == 1 || n % 5 == 0) ? "\(n)" : " "
    }

    // MARK: the calls of the selection

    private func selectionSection(_ m: Model) -> some View {
        let rows = m.this.sorted { $0.start > $1.start }
        let oneDay = day != nil || period == "today"
        let shown = allCalls ? rows : Array(rows.prefix(12))
        return VStack(alignment: .leading, spacing: 0) {
            PageSectionHead(title: L("stats.inSelection"), count: "\(rows.count)" + (day.map { " · " + short($0, "EEEdMMM") } ?? "")) {
                if day != nil { HomeLink(L("stats.backToTheWhole")) { day = nil; allCalls = false } }
            }
            if rows.isEmpty { Text(L("stats.empty")).font(t.homeText(15)).foregroundStyle(PN.C.text3).pageRow(10) }
            ForEach(shown) { r in
                Button { HomeNav.shared.open(.call(r.file)) } label: {
                    HStack(spacing: 12) {
                        Text(oneDay ? r.start.formatted(date: .omitted, time: .shortened) : short(r.start, "EEEd") + " " + r.start.formatted(date: .omitted, time: .shortened))
                            .font(t.homeMono(12)).foregroundStyle(PN.C.text3).frame(width: oneDay ? 60 : 110, alignment: .leading).lineLimit(1)
                        swatch(color(m.legend.contains { $0.key == CallStats.key(r) } ? CallStats.key(r) : "", m))
                        Text(r.title).font(t.homeText(16, .semibold)).foregroundStyle(PN.C.text).lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(HomeView.hm(r.minutes ?? 0)).font(t.homeMono(12)).foregroundStyle(PN.C.text2).frame(width: 70, alignment: .trailing)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pageRow(10)
                .help(L("stats.openCall"))
            }
            if rows.count > shown.count {
                HomeLink(L("ntask.showAll", ["n": "\(rows.count)"])) { allCalls = true }.padding(.top, 10)
            }
        }
    }

    // MARK: the right column

    private func qualitySection(_ m: Model) -> some View {
        let ms = m.this.map { ($0, CallMetrics.shared.of($0.file)) }
        let shares = ms.compactMap { $0.1.talkShare }
        let open = ms.reduce(0) { $0 + $1.1.unanswered }
        let noDecision = ms.filter { $0.1.hasPicture && $0.1.decisions == 0 }.count
        let prep = ms.filter { $0.0.prepared == true }, noPrep = ms.filter { $0.0.prepared != true }
        func perCall(_ xs: [(CallHistory.Record, CallMetrics.Result)]) -> String {
            xs.isEmpty ? "-" : String(format: "%.1f", Double(xs.reduce(0) { $0 + $1.1.decisions }) / Double(xs.count)).replacingOccurrences(of: ".", with: L10n.lang == "uk" ? "," : ".")
        }
        let items: [(String, String, String)] = [
            (shares.isEmpty ? "-" : "\(Int((shares.reduce(0, +) / Double(shares.count) * 100).rounded()))%", L("stats.talkShare"), L("stats.talkShare.sub")),
            ("\(noDecision)", L("stats.noDecision"), L("stats.noDecision.sub", ["n": "\(m.this.count)"])),
            ("\(open)", L("stats.unanswered"), L("stats.unanswered.sub"))]
        return VStack(alignment: .leading, spacing: 0) {
            PageSectionHead(title: L("stats.quality"))
            if m.this.isEmpty { Text(L("stats.empty")).font(t.homeText(15)).foregroundStyle(PN.C.text3).pageRow(10) } else {
                ForEach(items, id: \.1) { n, label, sub in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(n).font(t.homeDisplay(40, numWeight)).tracking(numTrack * 40).foregroundStyle(PN.C.text)
                            .lineLimit(1).minimumScaleFactor(0.6).frame(width: 96, alignment: .leading)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(label).font(t.homeText(16, .semibold)).foregroundStyle(PN.C.text)
                            Text(sub).font(t.homeText(13)).foregroundStyle(PN.C.text3)
                        }
                    }
                    .pageRow(12)
                    .accessibilityElement(children: .combine)
                }
                Text(.init(L("stats.perCall", ["a": perCall(prep), "b": perCall(noPrep)]))).font(t.homeText(15)).foregroundStyle(PN.C.text)
                    .fixedSize(horizontal: false, vertical: true).pageRow(12)
            }
        }
    }

    /// The BANT (or other method) picture of a sales call: known criteria of all.
    private func salesKnown(_ calls: [CallHistory.Record]) -> (known: Int, total: Int, method: String)? {
        var k = 0, n = 0, method = ""
        for r in calls {
            let stem = r.file.hasSuffix(".md") ? String(r.file.dropLast(3)) : r.file
            guard let d = FileManager.default.contents(atPath: CallLayout.sidecar(stem, ".sales.json")),
                  let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
                  let cs = o["criteria"] as? [[String: Any]] else { continue }
            if method.isEmpty { method = (o["method"] as? String ?? "").uppercased() }
            n += cs.count; k += cs.filter { ($0["state"] as? String) == "known" }.count
        }
        return n > 0 ? (k, n, method) : nil
    }

    private func shortSection(_ m: Model) -> some View {
        let mins = m.this.reduce(0) { $0 + ($1.minutes ?? 0) }
        let longest = m.this.max { ($0.minutes ?? 0) < ($1.minutes ?? 0) }
        let sales = m.this.filter { CallStats.isSales($0) }
        var facts: [(String, String)] = []
        if !m.this.isEmpty { facts.append((L("stats.average"), HomeView.hm(mins / Double(m.this.count)))) }
        if let l = longest, (l.minutes ?? 0) > 0 { facts.append((L("stats.longest"), l.title + ", " + HomeView.hm(l.minutes ?? 0))) }
        if !sales.isEmpty {
            let s = salesKnown(sales)
            facts.append((L("stats.salesOnly"), "\(sales.count)" + (s.map { " · " + L("stats.salesKnown", ["method": $0.method.isEmpty ? "BANT" : $0.method, "k": "\($0.known)", "n": "\($0.total)"]) } ?? "")))
        }
        let k = day != nil || period == "today" ? "day" : period == "week" || period == "lastweek" ? "week" : period == "month" ? "month" : "period"
        return VStack(alignment: .leading, spacing: 0) {
            PageSectionHead(title: L("stats.short." + k))
            if facts.isEmpty { Text(L("stats.empty")).font(t.homeText(15)).foregroundStyle(PN.C.text3).pageRow(10) }
            ForEach(facts, id: \.0) { f in factRow(f.0, f.1, mono: false) }
        }
    }

    private func factRow(_ label: String, _ value: String, mono: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label).font(t.homeText(15)).foregroundStyle(PN.C.text2).lineLimit(1).fixedSize()
            Spacer(minLength: 8)
            Text(value).font(mono ? t.homeMono(13, .semibold) : t.homeText(15, .semibold)).foregroundStyle(PN.C.text)
                .multilineTextAlignment(.trailing).lineLimit(2).layoutPriority(1)
        }
        .pageRow(10)
        .accessibilityElement(children: .combine)
    }

    /// API spend of the month from the day ledger against the monthly limit, and the accounts' own usage reports.
    private var aiSection: some View {
        let cfg = AppConfig.load(from: AppPaths.config)
        let now = Date()
        let ms = cal.dateInterval(of: .month, for: now)?.start ?? now
        let spent = SpendDays.total(from: ms, to: now.addingTimeInterval(1))
        let cap = cfg.budget.monthlyHardUSD
        let accounts: [String] = ai.rows.compactMap { r in
            guard let m = r.usage.range(of: "^\\d+%", options: .regularExpression) else { return nil }
            return r.name + " " + r.usage[m]
        }
        return VStack(alignment: .leading, spacing: 0) {
            PageSectionHead(title: L("stats.aiMonth")) { HomeLink(L("stats.usage")) { SettingsWindow.show(tab: "usage") } }
            factRow(L("stats.apiSpend"), cap > 0 ? L("stats.spendOf", ["spent": String(format: "$%.2f", spent), "cap": String(format: "$%.0f", cap)]) : String(format: "$%.2f", spent), mono: true)
            if !accounts.isEmpty { factRow(L("stats.accounts"), accounts.joined(separator: " · "), mono: true) }
        }
    }
}
