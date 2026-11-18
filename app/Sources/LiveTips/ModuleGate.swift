import AppKit
import SwiftUI
import LiveTipsCore

/// 0.18.0 (B3, spec 7): what a closed module shows. A closed module is never hidden: its entry stays, and opening it
/// shows why it is closed and what to do. Local modules ask the organization new calls go to (`defaultOrg`); all of
/// them are open on every plan for now (D41.1), so these gates matter once staff close something in the console.
@MainActor
enum ModuleGate {
    /// The organization a local module is judged by: where new calls go, else the first one (Entitlements.Rights).
    static var org: String? { PacenoteAccount.shared.me?.defaultOrg?.id }

    static func state(_ module: String, _ level: String? = nil, org: String? = nil) -> Entitlements.State {
        EntitlementsStore.shared.rights.state(module, level, org: org ?? Self.org)
    }

    /// True: go on (open, or a quota close to its limit). Otherwise the reason is shown and nothing starts.
    @discardableResult
    static func allow(_ module: String, _ level: String? = nil, org: String? = nil) -> Bool {
        let o = org ?? Self.org
        let s = state(module, level, org: o)
        switch s {
        case .open, .quotaWarn: return true
        default:
            UsageLog.log("module_locked", ["module": module, "state": key(s)])
            LockedModuleWindow.show(module: module, state: s, org: o)
            return false
        }
    }

    static func key(_ s: Entitlements.State) -> String {
        switch s {
        case .open: return "open"
        case .lockedPlan: return "plan"
        case .quotaWarn: return "warn"
        case .quotaExhausted: return "quota"
        case .policyOff: return "policy"
        }
    }

    /// "Team" for "team"; a plan the app does not know reads as it came.
    static func planName(_ id: String?) -> String? {
        guard let id, !id.isEmpty else { return nil }
        return id.prefix(1).uppercased() + id.dropFirst()
    }
}

/// Words for a quota: "9 h 40 min of 10 h used this month. Resets Dec 1."
enum QuotaText {
    static func amount(_ id: String, _ v: Double) -> String {
        switch id {
        case "tip_minutes":
            let m = Int(v.rounded()), h = m / 60, r = m % 60
            if h == 0 { return L("quota.min", ["m": "\(r)"]) }
            return r == 0 ? L("quota.h", ["h": "\(h)"]) : L("quota.hmin", ["h": "\(h)", "m": "\(r)"])
        case "storage_mb":
            return v >= 1000 ? String(format: "%.1f GB", v / 1000) : "\(Int(v.rounded())) MB"
        default:
            return v == v.rounded() ? "\(Int(v))" : String(format: "%.1f", v)
        }
    }

    static func line(_ id: String, _ q: Entitlements.Quota) -> String {
        let name = L("quota." + id)
        guard let limit = q.limit else { return L("quota.unlimited", ["name": name, "used": amount(id, q.used)]) }
        var s = L(q.period == "month" ? "quota.usedMonth" : "quota.used",
                  ["name": name, "used": amount(id, q.used), "limit": amount(id, limit)])
        if let r = q.resetsAt {
            let f = DateFormatter(); f.locale = Locale(identifier: L10n.lang); f.setLocalizedDateFormatFromTemplate("MMMd")
            s += " " + L("quota.resets", ["date": f.string(from: r)])
        }
        return s
    }
}

/// The four states (spec 7), as one block: in the panel that opens on a closed entry, and in lists.
struct LockedModuleView: View {
    let module: String
    let state: Entitlements.State
    let org: String?
    var onClose: (() -> Void)? = nil
    @ObservedObject private var acct = PacenoteAccount.shared

    var body: some View {
        Group {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: icon).foregroundStyle(tint)
                Text(L("module." + module)).pnSection().foregroundStyle(PN.C.text)
            }
            Text(L("module." + module + ".what")).font(PN.Font.caption).foregroundStyle(PN.C.text2).fixedSize(horizontal: false, vertical: true)
            switch state {
            case .lockedPlan(let plan, let canRequest):
                let name = ModuleGate.planName(plan)
                Text(name.map { L("lock.plan", ["plan": $0]) } ?? L("lock.planHigher")).font(PN.Font.body.weight(.semibold)).foregroundStyle(PN.C.text)
                HStack(spacing: 10) {
                    if !acct.signedIn {
                        Button(L("lock.signIn")) { SettingsWindow.show(tab: "account"); onClose?() }.buttonStyle(.pnPrimary)
                    } else if let o = org {
                        // 0.19.0: the plans, in the app (an owner or admin switches there; Solo starts a team)
                        if canRequest {
                            Button(name.map { L("lock.request", ["plan": $0]) } ?? L("lock.requestAny")) {
                                PlansWindow.show(org: o, from: "lock"); onClose?()
                            }.buttonStyle(.pnPrimary)
                        } else {
                            Button(L("plans.compare")) { PlansWindow.show(org: o, from: "lock"); onClose?() }.buttonStyle(.pnSecondary)
                            Text(L("lock.askOwner")).font(PN.Font.caption).foregroundStyle(PN.C.text3)
                        }
                    } else {
                        Text(L("lock.askOwner")).font(PN.Font.caption).foregroundStyle(PN.C.text3)
                    }
                }
            case .quotaExhausted(let id, let q), .quotaWarn(let id, let q):
                Text(QuotaText.line(id, q)).font(PN.Font.body).foregroundStyle(PN.C.text).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    if id == "tip_minutes" {
                        Button(L("lock.ownKey")) { SettingsWindow.show(tab: "ai"); onClose?() }.buttonStyle(.pnSecondary)
                    }
                    if let o = org, EntitlementsStore.shared.rights.record(o)?.canRequestPlan == true {
                        Button(L("lock.askMore")) { PlansWindow.show(org: o, from: "quota"); onClose?() }
                            .buttonStyle(.pnTertiary)
                    }
                }
            case .policyOff:
                Text(L("lock.policy")).font(PN.Font.body).foregroundStyle(PN.C.text)
            case .open:
                EmptyView()
            }
        }
    }
        .trackScreen("module_lock")
    }

    private var icon: String {
        switch state {
        case .lockedPlan: return "lock.fill"
        case .quotaExhausted, .quotaWarn: return "gauge.with.dots.needle.67percent"
        case .policyOff: return "building.2"
        case .open: return "checkmark.circle"
        }
    }
    private var tint: Color {
        switch state {
        case .quotaWarn: return PN.C.pending
        case .quotaExhausted: return PN.C.danger
        default: return PN.C.text2
        }
    }
}

/// A small mark beside an entry in a list: a lock with the plan, a quota, or "Organization".
struct ModuleBadge: View {
    let state: Entitlements.State
    var body: some View {
        switch state {
        case .open: EmptyView()
        case .lockedPlan(let plan, _):
            Label(ModuleGate.planName(plan).map { L("lock.badge", ["plan": $0]) } ?? L("lock.badgeAny"), systemImage: "lock.fill")
                .font(PN.Font.caption).foregroundStyle(PN.C.text3)
        case .quotaWarn: Label(L("lock.badgeWarn"), systemImage: "gauge.with.dots.needle.67percent").font(PN.Font.caption).foregroundStyle(PN.C.pending)
        case .quotaExhausted: Label(L("lock.badgeQuota"), systemImage: "gauge.with.dots.needle.100percent").font(PN.Font.caption).foregroundStyle(PN.C.danger)
        case .policyOff: Label(L("lock.badgePolicy"), systemImage: "building.2").font(PN.Font.caption).foregroundStyle(PN.C.text3)
        }
    }
}

@MainActor
enum LockedModuleWindow {
    static var window: NSWindow?
    static func show(module: String, state: Entitlements.State, org: String?) {
        window?.close()
        let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.contentViewController = NSHostingController(rootView: Localized {
            LockedModuleView(module: module, state: state, org: org) { LockedModuleWindow.window?.close() }
                .padding(20).frame(width: 400)
        })
        w.title = L("lock.window")
        w.tabbingMode = .disallowed
        w.isReleasedWhenClosed = false
        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
