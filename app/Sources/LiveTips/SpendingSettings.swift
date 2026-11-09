import SwiftUI
import LiveTipsCore

/// 0.9.6 (owner, 2026-11-06): Settings > AI. A monthly limit and an alert share per provider with a key (Claude,
/// OpenAI, Gemini apart; a provider without a key is not shown), and the call agent with economy mode.
struct ProviderLimitsSection: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        let keyed = MainActor.assumeIsolated { SpendWatch.connected }
        if !keyed.isEmpty {
            Section {
                ForEach(keyed, id: \.self) { p in row(p) }
            } header: { Text(L("limit.header")) } footer: {
                Text(L("limit.footer")).font(PN.Font.caption).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private func row(_ p: String) -> some View {
        let spent = MainActor.assumeIsolated { SpendWatch.monthSpend()[p] ?? 0 }
        let b = model.config.providerBudgets[p]
        let lv = ProviderLimits.level(spent: spent, budget: b)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(AIUsageView.name(p)).font(PN.Font.body.weight(.semibold))
                Spacer()
                Text(b.monthlyUSD > 0 ? String(format: "$%.2f / $%.0f", spent, b.monthlyUSD) : String(format: "$%.2f", spent) + " " + L("limit.noLimit"))
                    .monospacedDigit().font(PN.Font.caption)
                    .foregroundStyle(lv == .capped ? PN.C.danger : lv == .alert ? PN.C.onMe : PN.C.text3)
            }
            HStack(spacing: 12) {
                TextField(L("limit.monthly"), value: $model.config.providerBudgets[p].monthlyUSD, format: .currency(code: "USD"))
                    .frame(maxWidth: 220).help(L("limit.monthly.help"))
                TextField(L("limit.alertAt"), value: $model.config.providerBudgets[p].alertPercent, format: .number)
                    .frame(maxWidth: 150).help(L("limit.alertAt.help"))
                Text("%").foregroundStyle(PN.C.text3)
            }
            if lv == .capped {
                Text(L("limit.cappedNow", ["provider": AIUsageView.name(p)])).font(PN.Font.caption).foregroundStyle(PN.C.danger)
            } else if lv == .alert {
                Text(L("limit.alertNow", ["pct": String(format: "%.0f", b.alertPercent)])).font(PN.Font.caption).foregroundStyle(PN.C.onMe)
            }
        }
        .padding(.vertical, 2)
    }
}

struct CallAgentSection: View {
    @ObservedObject var model: SettingsModel

    static let models = ["claude-sonnet-5-5", "claude-haiku-5-5"]

    var body: some View {
        Section {
            Toggle(isOn: $model.config.callAgent.enabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("agent.enabled"))
                    Text(L("agent.enabled.sub")).font(PN.Font.caption).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
                }
            }
            .disabled(!model.isSet(.claudeAPIKey))
            if !model.isSet(.claudeAPIKey) {
                Text(L("agent.needsKey")).font(PN.Font.caption).foregroundStyle(PN.C.text3)
            }
            if model.config.callAgent.enabled {
                NeedsComponent(id: "agent")
                Toggle(isOn: $model.config.callAgent.tools) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("agent.tools"))
                        Text(L("agent.tools.sub")).font(PN.Font.caption).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
                    }
                }
                ModelPicker(title: L("set.model"), selection: $model.config.callAgent.model, choices: Self.models)
                    .help(L("agent.model.help"))
                TextField(L("agent.perCall"), value: $model.config.callAgent.maxUSDPerCall, format: .currency(code: "USD"))
                    .help(L("agent.perCall.help"))
                // 0.9.6 point 2 (owner): background searches, their own flag and their own share of the call
                Toggle(isOn: $model.config.callAgent.proactive) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("agent.proactive"))
                        Text(L("agent.proactive.sub")).font(PN.Font.caption).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if model.config.callAgent.proactive {
                    TextField(L("agent.proactivePerCall"), value: $model.config.callAgent.proactiveUSDPerCall, format: .currency(code: "USD"))
                        .help(L("agent.proactivePerCall.help"))
                }
            }
        } header: { Text(L("agent.header")) } footer: {
            Text(L("agent.footer")).font(PN.Font.caption).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// 0.9.6 Б3 (owner, point 4; rules/prep.yaml): the research preparation, its own section (not the agent's, not the
/// economy's). The tools on by default, the check and the parallel research off (owner, Б4); only the Claude ways of
/// the preparation use them (PrepAgent.plan).
struct PrepAgentSection: View {
    @ObservedObject var model: SettingsModel

    private func row(_ on: Binding<Bool>, _ key: String) -> some View {
        Toggle(isOn: on) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L(key))
                Text(L(key + ".sub")).font(PN.Font.caption).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    var body: some View {
        Section {
            row($model.config.prepAgent.tools, "prepAgent.tools")
            row($model.config.prepAgent.verify, "prepAgent.verify")
            row($model.config.prepAgent.parallel, "prepAgent.parallel")
            if model.config.prepAgent.tools || model.config.prepAgent.parallel {
                TextField(L("prepAgent.budget"), value: $model.config.prepAgent.budgetUSD, format: .currency(code: "USD"))
                    .help(L("prepAgent.budget.help"))
            }
            if SpendWatch.economyOn, model.config.prepAgent.tools || model.config.prepAgent.verify || model.config.prepAgent.parallel {
                Text(L("prepAgent.economy")).font(PN.Font.caption).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
            }
        } header: { Text(L("prepAgent.header")) } footer: {
            Text(L("prepAgent.footer")).font(PN.Font.caption).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// 0.9.6 Б1 (owner): economy mode has its own section, it is about more than the agent. Switched by hand, also during
/// a call; the list says what changes now and from the next call (EconomyPlan, livetips_m0.agent.ECONOMY).
struct EconomySection: View {
    @State private var economy = false

    var body: some View {
        Section {
            Toggle(isOn: Binding(get: { economy }, set: { v in economy = v; MainActor.assumeIsolated { SpendWatch.setEconomy(v) } })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("economy.title"))
                    Text(L("economy.help")).font(PN.Font.caption).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                ForEach(EconomyPlan.changes, id: \.self) { k in
                    Label(L(k), systemImage: "leaf").font(PN.Font.caption).foregroundStyle(PN.C.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } header: { Text(L("economy.header")) } footer: {
            Text(L("economy.footer")).font(PN.Font.caption).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { economy = MainActor.assumeIsolated { SpendWatch.economyOn } }
    }
}
