import AppKit
import SwiftUI
import LiveTipsCore

// Pacenote 0.8 (F2): Call settings, the window menu's "Call settings… ⌘,". Everything the old window kept in its
// settings sheet: the call (type, role, audience, language, microphone, proactive tips) goes to the recorder and
// the tips engine through the inbox, as before (the skill reads the same @@SET lines); the window part (title,
// opacity, always on top, screen sharing, interface language) is applied here.

@MainActor
final class CallSettingsModel: ObservableObject {
    struct Mic: Identifiable, Hashable { let id: String; let name: String }

    weak var tips: PrompterController?
    @Published var callType = "auto"
    @Published var hiringRole = ""
    @Published var audience = "auto"
    @Published var language = "en"
    @Published var mic = "default"
    @Published var mics: [Mic] = []
    @Published var proactive = false
    @Published var title = ""
    @Published var opacity = 1.0
    @Published var onTop = PrompterController.onTop
    @Published var hidden = true
    @Published var uiLang = L10n.lang

    /// The current values from the recorder status (the same fields the old window read).
    func load() {
        title = CallEngine.shared.renamed ?? (CallEngine.shared.callRequest["title"] as? String) ?? ""
        opacity = ((UserDefaults.standard.dictionary(forKey: "prompterPrefs") ?? [:])["opacity"] as? Double) ?? 1.0
        onTop = PrompterController.onTop
        hidden = tips?.hiddenFromSharing ?? true
        uiLang = L10n.lang
        let s = FileManager.default.contents(atPath: CallEngine.shared.statusPath)
            .flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } ?? [:]
        if let v = s["call_type"] as? String { callType = v == "presentation" || v == "interview" ? v : "auto" }
        if let v = s["hiring_role"] as? String { hiringRole = v }
        if let v = s["audience"] as? String, !v.isEmpty { audience = v } else if (s["call_type"] as? String) == "client" { audience = "client" }
        if let v = s["call_lang"] as? String, !v.isEmpty { language = v }
        else if let l = s["langs"] as? [String], l.count > 1 { language = "mix" }
        else if let v = s["me_lang"] as? String { language = v == "en" ? "en" : "uk" }
        if let v = s["mic_device"] as? String, !v.isEmpty { mic = v }
        if let p = s["proactive"] { proactive = (p as? Bool) ?? ["on", "true", "1"].contains("\(p)") }
        var list = [Mic(id: "default", name: L("callSettings.mic.default")), Mic(id: "builtin", name: L("callSettings.mic.builtin"))]
        for i in (s["mic_inputs"] as? [[String: Any]]) ?? [] where (i["builtin"] as? Bool) != true {
            if let uid = i["uid"] as? String, let name = i["name"] as? String { list.append(Mic(id: "uid:" + uid, name: name)) }
        }
        if !list.contains(where: { $0.id == mic }) { list.append(Mic(id: mic, name: mic.hasPrefix("uid:") ? String(mic.dropFirst(4)) : mic)) }
        mics = list
        sent = ["call_type": callType, "hiring_role": hiringRole, "audience": audience, "call_lang": language,
                "mic_device": mic, "proactive": proactive ? "on" : "off"]
    }

    /// The values as loaded: a picker that only shows the loaded value sends nothing.
    private var sent: [String: String] = [:]

    func send(_ key: String, _ value: Any) {
        let v = "\(value)"
        guard sent[key] != v else { return }
        sent[key] = v
        tips?.sendSetting(key, value)
    }
}

struct CallSettingsView: View {
    @ObservedObject var model: CallSettingsModel
    var close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Picker(L("callSettings.type"), selection: $model.callType) {
                        Text(L("callSettings.type.regular")).tag("auto")
                        Text(L("callSettings.type.presentation")).tag("presentation")
                        Text(L("callSettings.type.interview")).tag("interview")
                    }
                    .onChange(of: model.callType) { model.send("call_type", model.callType) }
                    if model.callType == "interview" {
                        Picker(L("callSettings.role"), selection: $model.hiringRole) {
                            Text(L("callSettings.role.none")).tag("")
                            Text(L("callSettings.role.observer")).tag("observer")
                            Text(L("callSettings.role.interviewer")).tag("interviewer")
                            Text(L("callSettings.role.coach")).tag("coach")
                        }
                        .onChange(of: model.hiringRole) { model.send("hiring_role", model.hiringRole) }
                    }
                    Picker(L("callSettings.audience"), selection: $model.audience) {
                        Text(L("callSettings.audience.auto")).tag("auto")
                        Text(L("callSettings.audience.client")).tag("client")
                        Text(L("callSettings.audience.team")).tag("team")
                    }
                    .onChange(of: model.audience) { model.send("audience", model.audience) }
                    Picker(L("callSettings.language"), selection: $model.language) {
                        Text("English").tag("en")
                        Text("Українська").tag("uk")
                        Text(L("callSettings.language.mixed")).tag("mix")
                    }
                    .onChange(of: model.language) { model.send("call_lang", model.language) }
                    Picker(L("callSettings.mic"), selection: $model.mic) {
                        ForEach(model.mics) { m in Text(m.name).tag(m.id) }
                    }
                    .onChange(of: model.mic) { model.send("mic_device", model.mic) }
                    Toggle(isOn: $model.proactive) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L("callSettings.proactive"))
                            Text(L("callSettings.proactive.hint")).font(PN.Font.caption).foregroundStyle(PN.C.text3)
                        }
                    }
                    .onChange(of: model.proactive) { model.send("proactive", model.proactive ? "on" : "off") }
                } header: { Text(L("callSettings.section.call")) }

                Section {
                    HStack {
                        TextField(L("callSettings.title"), text: $model.title)
                            .onSubmit { rename() }
                        Button(L("callSettings.rename")) { rename() }.buttonStyle(.pnTertiary)
                    }
                    Picker(L("callSettings.opacity"), selection: $model.opacity) {
                        Text("100%").tag(1.0)
                        Text("94%").tag(0.94)
                        Text("80%").tag(0.8)
                        Text("65%").tag(0.65)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: model.opacity) { model.tips?.setOpacity(model.opacity) }
                    Toggle(L("callSettings.onTop"), isOn: $model.onTop)
                        .onChange(of: model.onTop) { model.tips?.setOnTop(model.onTop) }
                    Toggle(isOn: $model.hidden) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L("callSettings.hidden"))
                            Text(L("callSettings.hidden.hint")).font(PN.Font.caption).foregroundStyle(PN.C.text3)
                        }
                    }
                    .onChange(of: model.hidden) { model.tips?.hiddenFromSharing = model.hidden }
                    Picker(L("callSettings.uiLang"), selection: $model.uiLang) {
                        Text("English").tag("en")
                        Text("Українська").tag("uk")
                    }
                    .onChange(of: model.uiLang) {
                        SettingsWindow.model.config.uiLanguage = model.uiLang      // one interface language for the whole app
                        model.tips?.setLanguage(model.uiLang)
                    }
                    Text(L("callSettings.textSize")).font(PN.Font.caption).foregroundStyle(PN.C.text3)
                } header: { Text(L("callSettings.section.window")) }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button(L("callSettings.done"), action: close).buttonStyle(.pnPrimary).keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20).padding(.bottom, 16)
        }
        .frame(width: 460)
    }

    private func rename() {
        let v = model.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !v.isEmpty else { return }
        model.tips?.handle("rename", v)
    }
}

@MainActor
enum CallSettingsWindow {
    static var window: NSWindow?
    static let model = CallSettingsModel()

    static func show(for tips: PrompterController) {
        model.tips = tips
        model.load()
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: Localized {
                CallSettingsView(model: model, close: { window?.close() })
            }))
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.level = .floating                 // above the tips window, which floats too
            w.sharingType = .none               // like the tips window: not in a screen share
            window = w
        }
        window?.title = L("callSettings.windowTitle")
        if let tw = tips.window, let w = window {
            let f = tw.frame
            w.setFrameTopLeftPoint(NSPoint(x: max(f.minX, (tw.screen?.visibleFrame.minX ?? 0) + 8), y: f.maxY - 28))
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
