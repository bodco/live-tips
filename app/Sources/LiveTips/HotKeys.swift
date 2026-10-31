import AppKit
import Carbon.HIToolbox
import LiveTipsCore
import Foundation
import SwiftUI

/// Global shortcuts that work while the meeting app has the focus (no Accessibility permission:
/// Carbon hot keys are registered for this app only and do not read other keystrokes).
/// Defaults: Control-Option-H for HELP NOW, Control-Option-P to pause or resume.
/// 2026-10-27 (owner): both can be changed in Settings > General > Shortcuts.
final class HotKeys: @unchecked Sendable {
    nonisolated(unsafe) static let shared = HotKeys()
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var actions: [UInt32: () -> Void] = [:]
    private var handler: EventHandlerRef?

    struct Combo: Equatable {
        var key: UInt32          // virtual key code
        var mods: UInt32         // Carbon modifiers (controlKey, optionKey, cmdKey, shiftKey)
        var char: String         // the key's character, for display

        var display: String {
            var s = ""
            if mods & UInt32(controlKey) != 0 { s += "⌃" }
            if mods & UInt32(optionKey) != 0 { s += "⌥" }
            if mods & UInt32(shiftKey) != 0 { s += "⇧" }
            if mods & UInt32(cmdKey) != 0 { s += "⌘" }
            return s + char.uppercased()
        }
        var menuMask: NSEvent.ModifierFlags {
            var m: NSEvent.ModifierFlags = []
            if mods & UInt32(controlKey) != 0 { m.insert(.control) }
            if mods & UInt32(optionKey) != 0 { m.insert(.option) }
            if mods & UInt32(shiftKey) != 0 { m.insert(.shift) }
            if mods & UInt32(cmdKey) != 0 { m.insert(.command) }
            return m
        }
    }

    // Pacenote 0.8 (F2): Control-Option-M turns the microphone off or on, Control-Option-T the compact tips window,
    // Control-Option-L proactive tips.
    // 0.8.5 (PRESENTATION-SPEC 3.3): Control-Option-S presentation mode; Control-Option-Left/Right the previous and next
    // slide and Control-Option-= +30 s on the slide. The last three are registered only while the window presents, so
    // they never take the keys from a window manager the rest of the time. Compact (T) and proactive (L) keep their keys.
    enum Action: UInt32, CaseIterable { case help = 1, pause = 2, mute = 3, compact = 4, proactive = 5,
                                            presentation = 6, prevSlide = 7, nextSlide = 8, add30 = 9
        var title: String {
            switch self {
            case .help: return L("menubar.helpNow")
            case .pause: return L("menubar.pause")
            case .mute: return L("hotkey.mute")
            case .compact: return L("menubar.compact")
            case .proactive: return L("hotkey.proactive")
            case .presentation: return L("hotkey.presentation")
            case .prevSlide: return L("hotkey.prevSlide")
            case .nextSlide: return L("hotkey.nextSlide")
            case .add30: return L("hotkey.add30")
            }
        }
        var onlyWhilePresenting: Bool { [.prevSlide, .nextSlide, .add30].contains(self) }
        var defaultCombo: Combo {
            let mods = UInt32(controlKey | optionKey)
            switch self {
            case .help: return Combo(key: UInt32(kVK_ANSI_H), mods: mods, char: "h")
            case .pause: return Combo(key: UInt32(kVK_ANSI_P), mods: mods, char: "p")
            case .mute: return Combo(key: UInt32(kVK_ANSI_M), mods: mods, char: "m")
            case .compact: return Combo(key: UInt32(kVK_ANSI_T), mods: mods, char: "t")
            case .proactive: return Combo(key: UInt32(kVK_ANSI_L), mods: mods, char: "l")
            case .presentation: return Combo(key: UInt32(kVK_ANSI_S), mods: mods, char: "s")
            case .prevSlide: return Combo(key: UInt32(kVK_LeftArrow), mods: mods, char: "←")
            case .nextSlide: return Combo(key: UInt32(kVK_RightArrow), mods: mods, char: "→")
            case .add30: return Combo(key: UInt32(kVK_ANSI_Equal), mods: mods, char: "=")
            }
        }
        var prefix: String { ["hk.help", "hk.pause", "hk.mute", "hk.compact", "hk.proactive",
                              "hk.presentation", "hk.prevSlide", "hk.nextSlide", "hk.add30"][Int(rawValue) - 1] }
    }

    func combo(_ a: Action) -> Combo {
        let d = UserDefaults.standard
        guard d.object(forKey: a.prefix + ".key") != nil else { return a.defaultCombo }
        return Combo(key: UInt32(d.integer(forKey: a.prefix + ".key")), mods: UInt32(d.integer(forKey: a.prefix + ".mods")),
                     char: d.string(forKey: a.prefix + ".char") ?? "?")
    }

    func set(_ a: Action, _ c: Combo?) {
        let d = UserDefaults.standard
        if let c = c {
            d.set(Int(c.key), forKey: a.prefix + ".key"); d.set(Int(c.mods), forKey: a.prefix + ".mods"); d.set(c.char, forKey: a.prefix + ".char")
        } else {
            for k in [".key", ".mods", ".char"] { d.removeObject(forKey: a.prefix + k) }
        }
        register(a)
    }

    func install(help: @escaping () -> Void, pause: @escaping () -> Void,
                 mute: @escaping () -> Void = {}, compact: @escaping () -> Void = {},
                 proactive: @escaping () -> Void = {}, present: @escaping (String) -> Void = { _ in }) {
        guard handler == nil else { return }
        actions = [Action.help.rawValue: help, Action.pause.rawValue: pause, Action.mute.rawValue: mute, Action.compact.rawValue: compact,
                   Action.proactive.rawValue: proactive, Action.presentation.rawValue: { present("mode") },
                   Action.prevSlide.rawValue: { present("prev") }, Action.nextSlide.rawValue: { present("next") },
                   Action.add30.rawValue: { present("add30") }]
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            let action = HotKeys.shared.actions[id.id]
            let name = Action(rawValue: id.id).map { "\($0)" } ?? "other"
            DispatchQueue.main.async { UsageLog.log("hotkey", ["name": String(name.prefix(20))]); action?() }
            return noErr
        }, 1, &spec, nil, &handler)
        for a in Action.allCases where !a.onlyWhilePresenting { register(a) }
    }

    private var presenting = false
    /// The tips window started or stopped presenting: the slide keys are taken only meanwhile.
    func setPresenting(_ on: Bool) {
        guard on != presenting else { return }
        presenting = on
        if on { UsageLog.log("presentation_mode_on") }
        for a in Action.allCases where a.onlyWhilePresenting {
            if on { register(a) } else if let old = refs[a.rawValue] { UnregisterEventHotKey(old); refs[a.rawValue] = nil }
        }
    }

    private func register(_ a: Action) {
        if let old = refs[a.rawValue] { UnregisterEventHotKey(old); refs[a.rawValue] = nil }
        if a.onlyWhilePresenting && !presenting { return }
        let c = combo(a)
        var ref: EventHotKeyRef?
        let hid = EventHotKeyID(signature: OSType(0x4C544950), id: a.rawValue)   // "LTIP"
        if RegisterEventHotKey(c.key, c.mods, hid, GetApplicationEventTarget(), 0, &ref) == noErr, let r = ref { refs[a.rawValue] = r }
    }

    /// Turns a pressed key into a combo; at least Control, Option or Command is required.
    static func combo(from e: NSEvent) -> Combo? {
        var mods: UInt32 = 0
        if e.modifierFlags.contains(.control) { mods |= UInt32(controlKey) }
        if e.modifierFlags.contains(.option) { mods |= UInt32(optionKey) }
        if e.modifierFlags.contains(.command) { mods |= UInt32(cmdKey) }
        if e.modifierFlags.contains(.shift) { mods |= UInt32(shiftKey) }
        guard mods & UInt32(controlKey | optionKey | cmdKey) != 0 else { return nil }
        let ch = (e.charactersIgnoringModifiers ?? "").trimmingCharacters(in: .whitespaces)
        guard !ch.isEmpty else { return nil }
        return Combo(key: UInt32(e.keyCode), mods: mods, char: ch)
    }
}

/// One row in Settings: the action, its shortcut, Change (press the new keys) and Reset.
struct ShortcutRow: View {
    let action: HotKeys.Action
    @State private var combo: HotKeys.Combo = HotKeys.Action.help.defaultCombo
    @State private var recording = false
    @State private var monitor: Any?
    @State private var note = ""

    var body: some View {
        LabeledContent(action.title) {
            HStack(spacing: 8) {
                Text(recording ? L("hk.pressNew") : combo.display)
                    .font(.callout.monospaced())
                    .foregroundStyle(recording ? Color.accentColor : .primary)
                    .frame(minWidth: 90, alignment: .trailing)
                Button(recording ? L("hk.cancel") : L("nset.change")) { recording ? stop() : start() }
                    .buttonStyle(.pnTertiary)
                if combo != action.defaultCombo && !recording {
                    Button(L("hk.reset")) { HotKeys.shared.set(action, nil); combo = HotKeys.shared.combo(action) }
                        .buttonStyle(.pnTertiary).foregroundStyle(PN.C.text3)
                }
            }
        }
        .onAppear { combo = HotKeys.shared.combo(action) }
        .onDisappear { stop() }
        .help(note)
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if e.keyCode == UInt16(kVK_Escape) { stop(); return nil }
            if let c = HotKeys.combo(from: e) {
                let other = HotKeys.Action.allCases.first { $0 != action && HotKeys.shared.combo($0) == c }
                if other == nil { HotKeys.shared.set(action, c); combo = c; note = "" } else { note = L("hk.usedBy", ["name": other?.title ?? ""]) }
                stop()
            }
            return nil
        }
    }

    private func stop() {
        recording = false
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }
}
