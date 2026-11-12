import AppKit
import LiveTipsCore
import SwiftUI

// 0.10.0 (Meeting Sheet, phase 4): Settings > Meeting Sheet. Which calls open in Quick or Expert (the rules of
// rules/meeting-sheet.yaml, each can be turned off or switched), My focus fields on top of every sheet, when a fact
// counts as old, the reminder before a call, and the user's own presets (rename, duplicate, delete with a
// confirmation; a deleted preset is moved aside by the sidecar, never erased).

struct MeetingSheetSettingsPane: View {
    @ObservedObject var prefs = SheetPrefs.shared
    @ObservedObject var lib = SheetLibrary.shared
    @State private var newField = ""
    @State private var renaming: String?
    @State private var newName = ""
    @State private var deleting: SheetPresetInfo?
    @State private var note = ""

    var body: some View {
        Form {
            Section {
                Picker(L("sheet.ui.set.default"), selection: $prefs.forced) {
                    Text(L("sheet.ui.set.byRules")).tag("")
                    Text(L("sheet.ui.set.alwaysQuick")).tag("quick")
                    Text(L("sheet.ui.set.alwaysExpert")).tag("expert")
                }
                if prefs.forced.isEmpty {
                    ForEach($prefs.rules) { $r in
                        HStack {
                            Toggle(isOn: Binding(get: { r.off != true }, set: { r.off = $0 ? nil : true })) {
                                Text(ruleText(r)).font(PN.Font.body)
                            }
                            .toggleStyle(.checkbox)
                            Spacer()
                            Picker("", selection: $r.mode) {
                                Text(L("sheet.ui.quick")).tag("quick")
                                Text(L("sheet.ui.expert")).tag("expert")
                            }
                            .labelsHidden().pickerStyle(.segmented).fixedSize().disabled(r.off == true)
                        }
                    }
                    Text(L("sheet.ui.set.rulesNote")).font(PN.Font.caption).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
                    Button(L("sheet.ui.set.resetRules")) { prefs.rules = SheetModeRule.defaults }.buttonStyle(.pnTertiary)
                }
            } header: { Text(L("sheet.ui.set.modeTitle")) }

            Section {
                ForEach(Array(prefs.focus.enumerated()), id: \.offset) { i, f in
                    HStack {
                        Text(f)
                        Spacer()
                        Button { if i > 0 { prefs.focus.swapAt(i, i - 1) } } label: { Image(systemName: "arrow.up") }.buttonStyle(.plain).disabled(i == 0)
                            .accessibilityLabel(L("sheet.ui.block.up"))
                        Button { prefs.focus.remove(at: i) } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel(L("call.remove"))
                    }
                }
                HStack {
                    TextField(L("sheet.ui.set.focusPh"), text: $newField).onSubmit(addField)
                    Button(L("sheet.ui.add"), action: addField).disabled(newField.trimmingCharacters(in: .whitespaces).isEmpty || prefs.focus.count >= 7)
                }
                Text(L("sheet.ui.set.focusNote")).font(PN.Font.caption).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
            } header: { Text(L("sheet.ui.myFocus")) }

            Section {
                Stepper(L("sheet.ui.set.stale", ["n": "\(prefs.staleMonths)"]), value: $prefs.staleMonths, in: 1...36)
                // 0.10.0 (Meeting Sheet, folders): the preparation's window of a folder source; the call searches all of it
                Stepper(L("sheet.ui.set.folderDays", ["n": "\(prefs.folderDays)"]), value: $prefs.folderDays, in: 1...90)
                Text(L("sheet.ui.set.folderDaysNote")).font(PN.Font.caption).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
                Picker(L("sheet.ui.set.remind"), selection: $prefs.remindMinutes) {
                    Text(L("sheet.ui.remind.off")).tag(0)
                    Text(L("sheet.ui.remind.n", ["n": "15"])).tag(15)
                    Text(L("sheet.ui.remind.30")).tag(30)
                    Text(L("sheet.ui.remind.60")).tag(60)
                    Text(L("sheet.ui.remind.n", ["n": "120"])).tag(120)
                }
                Text(L("sheet.ui.set.remindNote")).font(PN.Font.caption).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
            } header: { Text(L("sheet.ui.set.timing")) }

            Section {
                let mine = lib.presets.filter(\.mine)
                if mine.isEmpty { Text(L("sheet.ui.set.noPresets")).font(PN.Font.caption).foregroundStyle(PN.C.text3) }
                ForEach(mine) { p in
                    HStack {
                        if renaming == p.id {
                            TextField("", text: $newName).onSubmit { rename(p) }
                            Button(L("common.save")) { rename(p) }
                            Button(L("common.cancel")) { renaming = nil }
                        } else {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(p.name)
                                Text(L("sheet.ui.s1.blocks", ["n": "\(p.blocks.count)"]) + (p.base.map { " · " + (lib.preset($0)?.name ?? $0) } ?? ""))
                                    .font(PN.Font.caption).foregroundStyle(PN.C.text3)
                            }
                            Spacer()
                            Button(L("sheet.ui.set.rename")) { renaming = p.id; newName = p.name }.buttonStyle(.pnTertiary)
                            Button(L("sheet.ui.set.duplicate")) { lib.change(["action": "duplicate", "id": p.id]) { note = $0 ?? "" } }.buttonStyle(.pnTertiary)
                            Button(L("sheet.ui.set.delete")) { deleting = p }.buttonStyle(.pnTertiary)
                        }
                    }
                }
                Text(L("sheet.ui.set.presetsNote")).font(PN.Font.caption).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
                if !note.isEmpty { Text(note).font(PN.Font.caption).foregroundStyle(PN.C.pending) }
            } header: { Text(L("sheet.ui.set.presets")) }
        }
        .formStyle(.grouped)
        .onAppear { lib.reload() }
        .confirmationDialog(L("sheet.ui.set.deleteQ", ["name": deleting?.name ?? ""]), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button(L("sheet.ui.set.delete"), role: .destructive) {
                if let p = deleting { lib.change(["action": "delete", "id": p.id]) { note = $0 ?? "" } }
                deleting = nil
            }
            Button(L("common.cancel"), role: .cancel) { deleting = nil }
        } message: { Text(L("sheet.ui.set.deleteBody")) }
    }

    private func addField() {
        let t = newField.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, !prefs.focus.contains(t), prefs.focus.count < 7 else { return }
        prefs.focus.append(t); newField = ""
    }

    private func rename(_ p: SheetPresetInfo) {
        let n = newName.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        lib.change(["action": "rename", "id": p.id, "name": n]) { note = $0 ?? "" }
        renaming = nil
    }

    private func ruleText(_ r: SheetModeRule) -> String {
        switch r.when {
        case "preset_in": return L("sheet.ui.set.rule.presets", ["list": (r.presets ?? []).map { lib.preset($0)?.name ?? $0 }.joined(separator: ", ")])
        default: return L("sheet.ui.set.rule." + r.when)
        }
    }
}
