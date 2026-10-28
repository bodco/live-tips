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

    static let periods: [(String, String)] = [("today", "Today"), ("week", "This week"), ("lastweek", "Last week"),
                                               ("month", "This month"), ("30", "Last 30 days"), ("custom", "Dates…")]

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
        let longest = this.max { ($0.minutes ?? 0) < ($1.minutes ?? 0) }
        let busiest = Dictionary(grouping: this, by: { cal.startOfDay(for: $0.start) }).mapValues { $0.reduce(0) { $0 + ($1.minutes ?? 0) } }.max { $0.value < $1.value }
        let sc = scopes
        let df = DateFormatter(); df.dateFormat = "EEE d MMM"

        return VStack(alignment: .leading, spacing: 10) {
            // 2026-10-28: one line when there is room, the pickers under the title in a narrow column.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { Text("Insights").font(.headline).fixedSize(); Spacer(); pickers(sc) }
                VStack(alignment: .leading, spacing: 6) { Text("Insights").font(.headline); HStack(spacing: 8) { pickers(sc) } }
            }
            if period == "custom" && day == nil {
                HStack(spacing: 6) {
                    DatePicker("From", selection: $from, displayedComponents: .date).fixedSize()
                    DatePicker("to", selection: $to, displayedComponents: .date).fixedSize()
                }
                .font(.caption)
            }
            if let d = day {
                HStack(spacing: 6) {
                    Label(df.string(from: d), systemImage: "calendar").font(.caption.weight(.semibold))
                    Button { day = nil } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.borderless).foregroundStyle(.secondary)
                        .help("Back to the whole period")
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: compact ? 120 : 150), spacing: 10)], spacing: 10) {
                tile("Calls", "\(this.count)", delta(Double(this.count), Double(prev.count), fmt: { "\(Int($0))" }))
                tile("On calls", hm(mins), delta(mins, prevMins, fmt: hm))
                tile("Claude", String(format: "$%.2f", spend), prevSpend > 0 ? String(format: "before $%.2f", prevSpend) : (scope.isEmpty ? "counted from 0.6.8" : "calls with a cost"))
                tile("Prepared", this.isEmpty ? "-" : "\(prepared) of \(this.count)", this.isEmpty ? "" : "\(Int(Double(prepared) / Double(max(1, this.count)) * 100))%")
            }
            if !bars.isEmpty {
                Chart(bars) { b in
                    BarMark(x: .value("Day", b.date, unit: .day), y: .value("Minutes", b.minutes))
                        .foregroundStyle(by: .value("Project", b.project))
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
                .help("Click a day to see it; click it again to go back.")
            } else {
                Text("No calls in this period.").font(.callout).foregroundStyle(.secondary)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { facts(longest, busiest, this, mins, spend) }
                VStack(alignment: .leading, spacing: 4) { facts(longest, busiest, this, mins, spend) }
            }
            .font(.caption)
            if !this.isEmpty {
                DisclosureGroup(isExpanded: $showCalls) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(this) { r in
                            HStack(spacing: 6) {
                                Text(df.string(from: r.start) + " " + r.start.formatted(date: .omitted, time: .shortened)).monospacedDigit().foregroundStyle(.secondary)
                                Text(r.title).lineLimit(1)
                                Spacer()
                                Text(hm(r.minutes ?? 0)).monospacedDigit().foregroundStyle(.secondary)
                                if let c = r.costUSD, c > 0 { Text(String(format: "$%.2f", c)).monospacedDigit().foregroundStyle(.secondary) }
                            }
                            .font(.caption)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { NSWorkspace.shared.open(URL(fileURLWithPath: r.file)) }
                            .help("Double-click to open the transcript")
                        }
                    }
                    .padding(.top, 4)
                } label: { Text("Calls in this selection (\(this.count))").font(.caption.weight(.semibold)) }
            }
        }
        .ltCard(padding: 14)
        .onAppear { history.fillDetails() }
    }

    @ViewBuilder private func facts(_ longest: CallHistory.Record?, _ busiest: (key: Date, value: Double)?, _ this: [CallHistory.Record], _ mins: Double, _ spend: Double) -> some View {
        let wd = Self.dayFmt
        if let l = longest, (l.minutes ?? 0) > 0 { fact("Longest", "\(l.title), \(hm(l.minutes ?? 0))") }
        if day == nil, let b = busiest, b.value > 0 { fact("Busiest day", "\(wd.string(from: b.key)), \(hm(b.value))") }
        if !this.isEmpty { fact("Average call", hm(mins / Double(this.count)) + (spend > 0 ? String(format: ", $%.2f", spend / Double(this.count)) : "")) }
    }

    @ViewBuilder private func pickers(_ sc: (projects: [String], workspaces: [String])) -> some View {
        Picker("", selection: Binding(get: { period }, set: { period = $0; day = nil })) {
            ForEach(Self.periods, id: \.0) { Text($0.1).tag($0.0) }
        }
        .labelsHidden().fixedSize()
        Picker("", selection: $scope) {
            Text("All projects").tag("")
            if !sc.workspaces.isEmpty { Section("Workspaces") { ForEach(sc.workspaces, id: \.self) { Text($0).tag("w:" + $0) } } }
            Section("Projects") { ForEach(sc.projects, id: \.self) { Text($0).tag("p:" + $0) } }
        }
        .labelsHidden().fixedSize()
    }

    static let dayFmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "EEE d MMM"; return f }()

    private func hm(_ m: Double) -> String {
        let t = Int(m.rounded())
        return t >= 60 ? "\(t / 60) h \(t % 60) min" : "\(t) min"
    }

    private func delta(_ a: Double, _ b: Double, fmt: (Double) -> String) -> String {
        guard b > 0 else { return a > 0 ? "none before" : "" }
        let d = a - b
        return (d >= 0 ? "+" : "-") + fmt(abs(d)) + " vs before"
    }

    private func tile(_ label: String, _ value: String, _ sub: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(compact ? .headline : .title3.weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            Text(sub).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(compact ? 7 : 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
    }

    private func fact(_ label: String, _ value: String) -> some View {
        HStack(spacing: 4) { Text(label + ":").foregroundStyle(.secondary); Text(value).lineLimit(1) }
    }
}

/// 2026-10-27 (owner): Prepare from Home asks first what the preparation is based on: the project or workspace
/// and "What matters on this call" (a regular meeting comes with the text of its last call).
struct PrepareSheet: View {
    @ObservedObject var model: StartCallModel
    var onPrepare: () -> Void
    var onCancel: () -> Void
    var onMore: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                IconTile(symbol: "sparkles", size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Prepare \u{201C}\(model.effectiveTitle)\u{201D}").font(.title3.weight(.semibold)).lineLimit(2)
                    Text(model.callDate.formatted(date: .abbreviated, time: .shortened)).font(.callout).foregroundStyle(.secondary)
                }
            }
            if let a = model.appliedFrom { Label(a, systemImage: "arrow.uturn.backward.circle").font(.caption).foregroundStyle(.secondary) }
            Picker("Project or workspace", selection: $model.target) {
                if model.target.isEmpty { Text("Choose…").tag("") }
                Section("Projects") {
                    ForEach(model.registry.projects.filter { $0.status != "archived" }, id: \.slug) { p in Text(p.name).tag("project:" + p.slug) }
                }
                Section("Workspaces") {
                    ForEach(model.registry.workspaces, id: \.name) { w in Text(w.name).tag("workspace:" + w.name) }
                }
            }
            .onChange(of: model.target) { model.applyProjectDefaults(); model.scanPrep() }
            // 2026-10-28 (owner): the folders or single files this preparation reads first.
            HStack(spacing: 6) {
                Button { model.addFolders() } label: { Label("Add folder or file", systemImage: "folder.badge.plus") }
                    .buttonStyle(LTSoftButtonStyle(small: true))
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(model.folders, id: \.self) { f in
                            HStack(spacing: 4) {
                                Image(systemName: StartCallModel.isDir(f) ? "folder" : "doc").font(.caption)
                                Text((f as NSString).lastPathComponent).font(.caption).lineLimit(1)
                                Button { model.folders.removeAll { $0 == f } } label: { Image(systemName: "xmark").font(.caption2) }
                                    .buttonStyle(.plain).foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                            .help(f)
                        }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("What matters on this call").font(.callout.weight(.medium))
                TextEditor(text: $model.context)
                    .font(.callout).scrollContentBackground(.hidden).padding(6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
                    .frame(height: 150)
                Text("The preparation reads what you write here (goal, people, questions, documents and links), the added folders and files, the project folder, the local Notion copy and earlier calls. It does not start the call.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("More settings…", action: onMore).buttonStyle(.link)
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Prepare", action: onPrepare).keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).disabled(model.target.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear { model.refreshTemplate() }
    }
}
