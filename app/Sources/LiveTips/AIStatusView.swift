import AppKit
import LiveTipsCore
import SwiftUI
import UserNotifications

/// 0.10.0 (AI chain, owner 12.11): the limit status icon on Home (top bar) and in the tips window header. Red octagon:
/// an AI the current jobs chose or use is at a limit or out; orange triangle: >= 95% of an account used or <= $1 left
/// of an API's monthly spending limit; a neutral chip otherwise. The popover lists every connected AI with the jobs it
/// does now, its status and its usage (LiveTipsCore/AIChain.swift, AIStatus). Usage: the accounts' own reports
/// (state/ai-accounts.json from Claude Code's rate_limit_event and the rate_limits of each Codex run's own session log,
/// with the reset time of the last limit error; the newest rate_limits line of Codex's session logs of the last 6 hours
/// as a seed), the APIs from Settings > AI > Spending limits and the spend ledger. 0.10.0 (status fix): the healthy
/// state reads "OK", never "working" (the PM read it as a job in progress); the state is recomputed at launch and
/// every 3 minutes, so a reached limit shows from the start and clears itself at its reset time.
@MainActor
final class AIStatusModel: ObservableObject {
    static let shared = AIStatusModel()

    struct RowText: Identifiable, Equatable {
        var id: String
        var name: String
        var jobs: String
        var status: String
        var usage: String
        var state: String
    }

    @Published private(set) var level: AIStatus.Level = .ok
    @Published private(set) var rows: [RowText] = []
    @Published private(set) var recent: [String] = []          // switches of the last hour, newest first
    private var lastRefresh = Date.distantPast
    private var codexCache: (at: Date, usage: AIAccountUsage.Usage?)?
    static var shot: (level: AIStatus.Level, rows: [RowText], recent: [String])?   // offscreen pictures only

    private var timer: Timer?

    /// At launch: the status from the saved limit reports and out states, then every 3 minutes.
    func start() {
        refresh(force: true)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 180, repeats: true) { _ in
            MainActor.assumeIsolated { AIStatusModel.shared.refresh(force: true) }
        }
    }

    var title: String { L(level == .out ? "ai.status.title.out" : level == .warn ? "ai.status.title.warn" : "ai.status.title.ok") }

    /// A line with its variables localized: a value that is an i18n key ("ai.reason.limit") or a comma list of keys.
    static func text(_ l: AIStatus.Line) -> String {
        var vars: [String: String] = [:]
        for (k, v) in l.vars {
            vars[k] = v.hasPrefix("ai.") ? v.split(separator: ",").map { L(String($0)) }.joined(separator: ", ") : v
        }
        return L(l.key, vars)
    }

    func refresh(force: Bool = false) {
        if let s = Self.shot { level = s.level; rows = s.rows; recent = s.recent; return }
        guard force || Date().timeIntervalSince(lastRefresh) >= 4 else { return }
        lastRefresh = Date()
        let c = AIRoute.effective(AppConfig.load(from: AppPaths.config))
        let connectedSet = AIRoute.connected()
        let connected = AIChain.normalized(c.ai.chain).map { $0.route }.filter { connectedSet.contains($0) }
        var accounts: [String: AIAccountUsage.Usage] = [:]
        if let d = FileManager.default.contents(atPath: AIRoute.accountsPath),
           let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { accounts = AIAccountUsage.parseFile(o) }
        if let cx = codexSessionUsage(), (accounts["codex"]?.at ?? 0) < cx.at {
            accounts["codex"] = cx
            AIRoute.noteAccountUsage(AIRoute.codex, cx)      // a seed: known at the next launch too
        }
        var limits: [String: Double] = [:]
        for p in AIUsage.providers { limits[p] = c.providerBudgets[p].monthlyUSD }
        let input = AIStatus.Input(connected: connected, chosen: ["tips": c.ai.tips, "prep": c.ai.prep, "after": c.ai.after],
                                   chain: c.ai.chain, auto: c.ai.autoSwitch, out: AIRoute.outStates(), accounts: accounts,
                                   spend: SpendWatch.monthSpend(), limits: limits, now: Date().timeIntervalSince1970)
        let rs = AIStatus.rows(input)
        level = AIStatus.level(rs)
        let now = Date().timeIntervalSince1970
        rows = rs.map { r in
            // 0.10.0 (owner 12.11): the time of the account's last report, its own run or the usage probe
            let updated = r.updatedAt.map { L("ai.status.updated", ["time": AIStatus.when($0, now: now)]) }
            return RowText(id: r.route, name: AIRoute.name(r.route), jobs: AIStatus.jobsLines(r).map(Self.text).joined(separator: "; "),
                           status: Self.text(r.status), usage: ([r.usage] + r.usageMore).map(Self.text).joined(separator: "; ") + (updated.map { " · " + $0 } ?? ""),
                           state: "\(r.state)")
        }
        recent = recentSwitches()
    }

    /// The switches of the last hour from state/ai-switches.jsonl, and a notification for a new switch of an
    /// after-the-call job (the tips window shows the call's, the Meeting Sheet build its own with a banner).
    private func recentSwitches() -> [String] {
        guard let t = try? String(contentsOfFile: AIRoute.switchesPath, encoding: .utf8) else { return [] }
        let now = Date().timeIntervalSince1970
        let seenKey = "aiSwitchSeen"
        let seen = UserDefaults.standard.double(forKey: seenKey)
        var out: [String] = [], newest = seen
        for line in t.split(separator: "\n").suffix(30).reversed() {
            guard let o = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  let at = (o["at"] as? NSNumber)?.doubleValue, now - at < 3600 else { continue }
            let job = (o["job"] as? String) ?? ""
            let jobKey = job.hasPrefix("prep") ? "prep" : (job == "tips" || job == "live" || job == "agent") ? "tips" : "after"
            let text = L("ai.status.switched", ["job": L("ai.status.job." + jobKey), "from": AIRoute.name((o["from"] as? String) ?? ""),
                                                "to": AIRoute.name((o["to"] as? String) ?? ""), "reason": L("ai.reason." + ((o["reason"] as? String) ?? "error")),
                                                "time": AIStatus.hhmm(at)])
            out.append(text)
            if at > seen {
                newest = max(newest, at)
                // the tips window shows tips and typed questions, the build views and their banner the preparation
                if jobKey == "after" && seen > 0 { notify(text) }
            }
        }
        if newest > seen || seen == 0 { UserDefaults.standard.set(max(newest, now), forKey: seenKey) }
        return Array(out.prefix(5))
    }

    private func notify(_ text: String) {
        let n = UNMutableNotificationContent()
        n.title = L("ai.status.switchedTitle")
        n.body = text
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "pn-ai-switch-" + UUID().uuidString, content: n, trigger: nil))
    }

    /// Codex's own session logs (~/.codex/sessions) carry `rate_limits` in their token_count events; `codex exec
    /// --json` printed none in the check of 2026-11-12 (the app's own runs read their log and remove it, see
    /// codex_provider.run_usage). A seed from the PM's other Codex sessions: only the newest rate_limits object of the
    /// newest log of the last 6 hours is read (the tail of the file, nothing else is kept), at most once a minute.
    private func codexSessionUsage() -> AIAccountUsage.Usage? {
        if let c = codexCache, Date().timeIntervalSince(c.at) < 60 { return c.usage }
        var result: AIAccountUsage.Usage?
        let root = NSHomeDirectory() + "/.codex/sessions"
        let fm = FileManager.default
        var newest: (path: String, at: Date)?
        if let e = fm.enumerator(atPath: root) {
            for case let rel as String in e where rel.hasSuffix(".jsonl") {
                let p = root + "/" + rel
                if let m = (try? fm.attributesOfItem(atPath: p))?[.modificationDate] as? Date, Date().timeIntervalSince(m) < 6 * 3600,
                   newest == nil || m > newest!.at { newest = (p, m) }
            }
        }
        if let n = newest, let h = FileHandle(forReadingAtPath: n.path) {
            let size = (try? h.seekToEnd()) ?? 0
            try? h.seek(toOffset: size > 262_144 ? size - 262_144 : 0)
            let data = (try? h.readToEnd()) ?? Data()
            try? h.close()
            let text = String(decoding: data, as: UTF8.self)
            for line in text.split(separator: "\n").reversed() where line.contains("\"rate_limits\"") {
                guard let o = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                      let rl = ((o["payload"] as? [String: Any])?["rate_limits"] ?? o["rate_limits"]) as? [String: Any],
                      let u = AIAccountUsage.fromCodex(rl, now: n.at.timeIntervalSince1970) else { continue }
                result = u
                break
            }
        }
        codexCache = (Date(), result)
        return result
    }

    /// For the tips window (LiveTips.setState({ai: ...})).
    func windowState() -> [String: Any] {
        refresh()
        return ["level": level.rawValue, "title": title, "head": L("ai.status.head"),
                "rows": rows.map { ["name": $0.name, "jobs": $0.jobs, "status": $0.status, "usage": $0.usage, "state": $0.state] },
                "recent": recent]
    }
}

/// The icon and its popover (Home's top bar). Hover or click shows the list.
struct AIStatusIcon: View {
    @ObservedObject private var m = AIStatusModel.shared
    @State private var open = false
    @State private var hoverTask: DispatchWorkItem?

    static func color(_ l: AIStatus.Level) -> Color {
        l == .out ? PN.C.rec : l == .warn ? PN.C.pendingFill : PN.C.text2
    }

    var body: some View {
        Button { open.toggle() } label: {
            Image(systemName: AIStatus.symbol(m.level))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Self.color(m.level))
                .frame(width: 26, height: 26).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(m.title)
        .accessibilityLabel(m.title)
        .onHover { inside in
            hoverTask?.cancel()
            if inside {
                let t = DispatchWorkItem { open = true }
                hoverTask = t
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: t)
            }
        }
        .popover(isPresented: $open, arrowEdge: .bottom) { AIStatusList(m: m).frame(width: 380) }
        .onChange(of: open) { if open { AIUsageProbe.shared.popoverOpened() } }      // 0.10.0: numbers older than 10 min
        .onAppear { m.refresh(force: true) }
        .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in m.refresh() }
    }
}

struct AIStatusList: View {
    @ObservedObject var m: AIStatusModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: AIStatus.symbol(m.level)).foregroundStyle(AIStatusIcon.color(m.level))
                Text(m.title).font(PN.Font.section).foregroundStyle(PN.C.text)
            }
            if m.rows.isEmpty {
                Text(L("ai.status.none")).font(PN.Font.caption).foregroundStyle(PN.C.text3)
            }
            ForEach(m.rows) { r in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(r.name).font(PN.Font.body.weight(.semibold)).foregroundStyle(PN.C.text)
                        Spacer(minLength: 8)
                        Text(r.status).font(PN.Font.caption.weight(.medium))
                            .foregroundStyle(["limit", "out", "capped"].contains(r.state) ? PN.C.rec : r.state == "near" ? PN.C.pending : PN.C.text3)
                            .multilineTextAlignment(.trailing)
                    }
                    Text(r.jobs).font(PN.Font.caption).foregroundStyle(PN.C.text2)
                    Text(r.usage).font(PN.Font.caption).foregroundStyle(PN.C.text3)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            if !m.recent.isEmpty {
                Divider()
                ForEach(m.recent, id: \.self) { Text($0).font(PN.Font.caption).foregroundStyle(PN.C.text2).fixedSize(horizontal: false, vertical: true) }
            }
            Divider()
            Button(L("ai.status.settings")) { SettingsWindow.show(tab: "ai") }.buttonStyle(.link).font(PN.Font.caption)
        }
        .padding(14)
    }
}
