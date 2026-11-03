import AppKit
import SwiftUI
import LiveTipsCore

/// 0.9.0 (redesign): the week's numbers, moved from Home to Settings > Usage (owner, 2026-11-03).
struct WeekSummaryView: View {
    @ObservedObject var history = CallHistory.shared
    @State private var now = Date()
    var body: some View { weekSection }

    private var weekSection: some View {
        let cal0 = CallStats.calendar
        let ws = CallStats.weekStart(now)
        let recs = CallStats.calls(from: ws, to: now.addingTimeInterval(1))      // 0.8.7 (B1): the same numbers as Statistics
        let mins = recs.reduce(0) { $0 + ($1.minutes ?? 0) }
        let prepared = recs.filter { $0.prepared == true }.count
        // 0.8.7 (B3): Monday to Sunday; the weekend shows when it has calls or today is a weekend day
        let weekend = recs.contains { cal0.isDateInWeekend($0.start) } || cal0.isDateInWeekend(now)
        let days: [(String, Double)] = (0..<(weekend ? 7 : 5)).map { i in
            let d = cal0.date(byAdding: .day, value: i, to: ws) ?? ws
            let f = DateFormatter(); f.locale = Locale(identifier: L10n.lang == "uk" ? "uk_UA" : "en_US"); f.setLocalizedDateFormatFromTemplate("EEEEE")
            return (f.string(from: d), recs.filter { cal0.isDate($0.start, inSameDayAs: d) }.reduce(0) { $0 + ($1.minutes ?? 0) })
        }
        let top = max(30, days.map(\.1).max() ?? 0)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L("home.week")).font(PN.Font.section).foregroundStyle(PN.C.text)
                Spacer()
            }
            HStack(alignment: .top, spacing: 12) {
                number("\(recs.count)", L("home.week.calls"))
                number(HomeView.hm(mins), L("home.week.onCalls"))
                number(L("home.week.preparedOf", ["x": "\(prepared)", "y": "\(recs.count)"]), L("home.week.prepared"))
            }
            HStack(alignment: .bottom, spacing: 8) {
                ForEach(Array(days.enumerated()), id: \.offset) { _, d in
                    VStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 3).fill(d.1 > 0 ? PN.C.brand : PN.C.surface2)
                            .frame(height: max(4, CGFloat(d.1 / top) * 44))
                        Text(d.0).font(PN.Font.caption).foregroundStyle(PN.C.text3)
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityElement().accessibilityLabel(d.0 + " " + HomeView.hm(d.1))
                }
            }
            .frame(height: 64, alignment: .bottom)
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(PN.C.surface, in: RoundedRectangle(cornerRadius: PN.Radius.m))
        .onAppear { history.fillDetails() }
    }

    private func number(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 17, weight: .semibold)).monospacedDigit().foregroundStyle(PN.C.text).lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(PN.Font.caption).foregroundStyle(PN.C.text3).lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

}
