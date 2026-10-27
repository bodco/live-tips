import SwiftUI
import Charts

/// 2026-10-27 (owner): Home's week: calls, time on calls, Claude spend, how many were prepared, minutes per
/// day by project, and a few facts (longest call, busiest day, average). From the call history (the app's and
/// the skill's transcripts) and the day ledger of Claude spend.
struct WeekStats: View {
    @ObservedObject var history = CallHistory.shared

    private struct Day: Identifiable { var id: String { day + project }; var day: String; var project: String; var minutes: Double }

    var body: some View {
        let cal = Calendar.current
        let now = Date()
        let weekStart = cal.dateInterval(of: .weekOfYear, for: now)?.start ?? cal.startOfDay(for: now)
        let lastStart = cal.date(byAdding: .day, value: -7, to: weekStart) ?? weekStart
        let all = history.records
        let this = all.filter { $0.start >= weekStart && $0.start <= now }
        let last = all.filter { $0.start >= lastStart && $0.start < weekStart }
        let mins = this.reduce(0) { $0 + ($1.minutes ?? 0) }
        let lastMins = last.reduce(0) { $0 + ($1.minutes ?? 0) }
        let spend = SpendDays.total(from: weekStart, to: now)
        let lastSpend = SpendDays.total(from: lastStart, to: weekStart)
        let prepared = this.filter { $0.prepared == true }.count
        let wd = DateFormatter(); wd.dateFormat = "EEE"
        let days: [Day] = Dictionary(grouping: this, by: { wd.string(from: $0.start) + "|" + $0.project })
            .map { k, v in let p = k.split(separator: "|", maxSplits: 1).map(String.init); return Day(day: p[0], project: p.count > 1 ? p[1] : "", minutes: v.reduce(0) { $0 + ($1.minutes ?? 0) }) }
        let order = (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: weekStart) }.map { wd.string(from: $0) }
        let longest = this.max { ($0.minutes ?? 0) < ($1.minutes ?? 0) }
        let busiest = Dictionary(grouping: this, by: { wd.string(from: $0.start) }).mapValues { $0.reduce(0) { $0 + ($1.minutes ?? 0) } }.max { $0.value < $1.value }

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("This week").font(.headline)
                Text(weekStart.formatted(.dateTime.day().month()) + " - " + now.formatted(.dateTime.day().month())).font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                tile("Calls", "\(this.count)", delta(Double(this.count), Double(last.count), fmt: { "\(Int($0))" }))
                tile("On calls", hm(mins), delta(mins, lastMins, fmt: hm))
                tile("Claude", String(format: "$%.2f", spend), lastSpend > 0 ? "last week " + String(format: "$%.2f", lastSpend) : "from 0.6.8 on")
                tile("Prepared", this.isEmpty ? "-" : "\(prepared) of \(this.count)", this.isEmpty ? "" : "\(Int(Double(prepared) / Double(max(1, this.count)) * 100))%")
            }
            if !days.isEmpty {
                Chart(days) { d in
                    BarMark(x: .value("Day", d.day), y: .value("Minutes", d.minutes))
                        .foregroundStyle(by: .value("Project", d.project))
                }
                .chartXScale(domain: order)
                .chartYAxisLabel("min")
                .chartLegend(position: .bottom, alignment: .leading)
                .frame(height: 150)
            }
            ViewThatFits(in: .horizontal) {
              HStack(spacing: 16) { facts(longest, busiest, this, mins, spend) }
              VStack(alignment: .leading, spacing: 4) { facts(longest, busiest, this, mins, spend) }
            }
            .font(.caption)
        }
        .ltCard(padding: 14)
        .onAppear { history.fillDetails() }
    }

    @ViewBuilder private func facts(_ longest: CallHistory.Record?, _ busiest: (key: String, value: Double)?, _ this: [CallHistory.Record], _ mins: Double, _ spend: Double) -> some View {
        if let l = longest, (l.minutes ?? 0) > 0 { fact("Longest", "\(l.title), \(hm(l.minutes ?? 0))") }
        if let b = busiest, b.value > 0 { fact("Busiest day", "\(b.key), \(hm(b.value))") }
        if !this.isEmpty { fact("Average call", hm(mins / Double(this.count)) + (spend > 0 ? String(format: ", $%.2f", spend / Double(this.count)) : "")) }
    }

    private func hm(_ m: Double) -> String {
        let t = Int(m.rounded())
        return t >= 60 ? "\(t / 60) h \(t % 60) min" : "\(t) min"
    }

    private func delta(_ a: Double, _ b: Double, fmt: (Double) -> String) -> String {
        guard b > 0 else { return a > 0 ? "new this week" : "" }
        let d = a - b
        return (d >= 0 ? "+" : "-") + fmt(abs(d)) + " vs last week"
    }

    private func tile(_ label: String, _ value: String, _ sub: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            Text(sub).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(10)
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
            VStack(alignment: .leading, spacing: 6) {
                Text("What matters on this call").font(.callout.weight(.medium))
                TextEditor(text: $model.context)
                    .font(.callout).scrollContentBackground(.hidden).padding(6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
                    .frame(height: 150)
                Text("The preparation reads what you write here (goal, people, questions, documents and links), the project folder\(model.folders.isEmpty ? "" : " and \(model.folders.count) added folder(s)"), the local Notion copy and earlier calls. It does not start the call.")
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
