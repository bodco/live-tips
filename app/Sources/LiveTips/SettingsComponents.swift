import AppKit
import LiveTipsCore
import SwiftUI

/// 0.16.0 (D3): Settings > Components. What Pacenote installed on this Mac, how much space it takes and what can be
/// removed. Optional parts: Remove… (with what follows) or Install. Required parts: locked, Check again, Repair….
/// Nothing is installed or removed during a call.
struct SettingsComponentsPane: View {
    @ObservedObject var oc = OptionalComponents.shared
    @ObservedObject var llm = LocalLLM.shared
    @ObservedObject var setup = SetupWindow.model
    @State private var confirm: String?

    var requiredBytes: Int64 { RequiredGroup.all.reduce(0) { $0 + ($1.bytes(oc) ?? 0) } }
    var optionalBytes: Int64 { ComponentCatalog.optional.filter { oc.isInstalled($0) }.reduce(0) { $0 + (oc.sizes[$1] ?? 0) } }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(L("cmp.uses", ["size": ComponentCatalog.format(requiredBytes + optionalBytes)])).font(PN.Font.section)
                        Spacer()
                        Text(L("cmp.free", ["size": ComponentCatalog.format(DiskSpace.free)])).font(PN.Font.caption).foregroundStyle(PN.C.text3)
                    }
                    GeometryReader { g in
                        // a 20 GB scale (or what Pacenote takes, if more), so the small parts stay visible
                        let scale = max(20e9, Double(requiredBytes + optionalBytes))
                        HStack(spacing: 0) {
                            Rectangle().fill(PN.C.text3).frame(width: g.size.width * Double(requiredBytes) / scale)
                            Rectangle().fill(PN.C.brand).frame(width: g.size.width * Double(optionalBytes) / scale)
                            Spacer(minLength: 0)
                        }
                        .background(PN.C.surface2).clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    .frame(height: 8).accessibilityHidden(true)
                    HStack(spacing: 16) {
                        legend(PN.C.text3, L("cmp.legend.req", ["size": ComponentCatalog.format(requiredBytes)]))
                        legend(PN.C.brand, L("cmp.legend.opt", ["size": ComponentCatalog.format(optionalBytes)]))
                    }
                }
                .padding(.vertical, 4)
                if let r = oc.removed {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(PN.C.turn).accessibilityHidden(true)
                        Text(r.id == "local_model" ? L("cmp.removed.model", ["size": ComponentCatalog.format(r.bytes)])
                             : L("cmp.removed", ["name": oc.title(r.id), "size": ComponentCatalog.format(r.bytes)]))
                            .font(PN.Font.body)
                        Spacer()
                        Button(L("cmp.installAgain")) { oc.install(r.id) }.buttonStyle(.pnTertiary).disabled(oc.duringCall)
                    }
                    .accessibilityElement(children: .combine)
                }
            } header: { Text(L("cmp.disk")).settingsAnchor("comp.disk") }

            Section {
                ForEach(oc.all) { c in optionalRow(c) }
            } header: { Text(L("cmp.optional")).settingsAnchor("comp.optional") } footer: {
                if oc.duringCall { Text(L("cmp.duringCall")).font(PN.Font.caption).foregroundStyle(PN.C.onMe) }
            }

            Section {
                ForEach(RequiredGroup.all) { g in
                    HStack(spacing: 10) {
                        Image(systemName: "lock").font(.system(size: 11)).foregroundStyle(PN.C.text3).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(g.title)
                            Text(g.why).font(PN.Font.caption).foregroundStyle(PN.C.text3).lineLimit(2)
                        }
                        Spacer()
                        Text(g.bytes(oc).map(ComponentCatalog.format) ?? "…").font(PN.Font.caption).foregroundStyle(PN.C.text2)
                            .frame(width: 80, alignment: .trailing)
                        ComponentStatePill(status: g.status(setup, checking: true)).frame(width: 100, alignment: .trailing)
                    }
                }
                // Claude Code: installed like the rest but optional; preparing a call needs it (2026-10-29, owner)
                if let cc = setup.steps.first(where: { $0.id == "claude" }), cc.state != .ok, cc.state != .unknown {
                    HStack {
                        Text(L("setup.step.claude.title")).foregroundStyle(PN.C.text2)
                        Spacer()
                        Button(L("onboarding.claude.install")) { Task { await setup.installOne("claude") } }.buttonStyle(.pnSecondary).disabled(setup.busy)
                    }
                }
                HStack {
                    Button(L("about.components.check")) { Task { await setup.checkAll(); await oc.measureAll() } }.buttonStyle(.pnTertiary).disabled(setup.busy)
                    Button(L("cmp.repair")) { SetupWindow.show() }.buttonStyle(.pnTertiary)
                }
            } header: { Text(L("cmp.required")).settingsAnchor("comp.required") } footer: {
                Text(L("cmp.required.foot")).font(PN.Font.caption).foregroundStyle(PN.C.text3)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            oc.refresh()
            Task {
                if setup.steps.allSatisfy({ $0.state == .unknown }) { await setup.checkAll() }
                await oc.measureAll()
            }
        }
        .alert(confirmTitle, isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } })) {
            Button(L("common.cancel"), role: .cancel) { confirm = nil }
            Button(confirmButton, role: .destructive) {
                if let id = confirm { Task { await oc.remove(id); await oc.measureAll() } }
                confirm = nil
            }
        } message: { Text(confirmMessage) }
    }

    func legend(_ c: Color, _ t: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(c).frame(width: 8, height: 8).accessibilityHidden(true)
            Text(t).font(PN.Font.caption).foregroundStyle(PN.C.text2)
        }
    }

    func optionalRow(_ c: OptionalComponents.Comp) -> some View {
        let installed = oc.isInstalled(c.id)
        return HStack(spacing: 10) {
            Circle().fill(installed ? PN.C.turn : PN.C.text3.opacity(0.4)).frame(width: 8, height: 8).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(c.title)
                Text(sub(c)).font(PN.Font.caption).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
                if !installed { ComponentStateLine(id: c.id) }
            }
            Spacer()
            Text(installed ? (oc.sizes[c.id].map(ComponentCatalog.format) ?? "…") : L("cmp.notInstalled"))
                .font(PN.Font.caption).foregroundStyle(PN.C.text2).lineLimit(1).fixedSize().frame(minWidth: 90, alignment: .trailing)
            Group {
                if case .removing = oc.state(c.id) { ProgressView().controlSize(.small) }
                else if installed {
                    Button(oc.duringCall ? L("comp.afterCall") : L("cmp.remove")) { confirm = c.id }
                        .buttonStyle(.pnSecondary).disabled(oc.duringCall)
                        .accessibilityLabel(L("cmp.remove.a11y", ["name": c.title]))
                } else { ComponentAction(id: c.id) }
            }
            .frame(width: 110, alignment: .trailing)
        }
    }

    func sub(_ c: OptionalComponents.Comp) -> String {
        switch c.id {
        case "local_model": return L("cmp.sub.model", ["model": LocalLLM.suggestedLabel])
        case "agent": return L("cmp.sub.agent")
        default: return L("cmp.sub.link")
        }
    }

    var confirmTitle: String { confirm.map { L("cmp.confirm.title", ["name": oc.title($0)]) } ?? "" }
    var confirmBytes: Int64 { confirm.flatMap { oc.sizes[$0] } ?? confirm.map(ComponentCatalog.estimate) ?? 0 }
    var confirmButton: String { L("cmp.confirm.button", ["size": ComponentCatalog.format(confirmBytes)]) }
    var confirmMessage: String {
        guard let id = confirm else { return "" }
        var parts = [L("cmp.confirm.body", ["size": ComponentCatalog.format(confirmBytes)]), L("cmp.impact." + id)]
        if id == "local_model" { parts.append(L("cmp.impact.ollama")) }
        return parts.joined(separator: "\n\n")
    }
}
