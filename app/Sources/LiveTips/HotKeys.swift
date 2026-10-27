import AppKit
import Carbon.HIToolbox
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

    enum Action: UInt32, CaseIterable { case help = 1, pause = 2
        var title: String { self == .help ? "HELP NOW" : "Pause or resume" }
        var defaultCombo: Combo {
            self == .help ? Combo(key: UInt32(kVK_ANSI_H), mods: UInt32(controlKey | optionKey), char: "h")
                          : Combo(key: UInt32(kVK_ANSI_P), mods: UInt32(controlKey | optionKey), char: "p")
        }
        var prefix: String { self == .help ? "hk.help" : "hk.pause" }
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

    func install(help: @escaping () -> Void, pause: @escaping () -> Void) {
        guard handler == nil else { return }
        actions = [Action.help.rawValue: help, Action.pause.rawValue: pause]
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            let action = HotKeys.shared.actions[id.id]
            DispatchQueue.main.async { action?() }
            return noErr
        }, 1, &spec, nil, &handler)
        for a in Action.allCases { register(a) }
    }

    private func register(_ a: Action) {
        if let old = refs[a.rawValue] { UnregisterEventHotKey(old); refs[a.rawValue] = nil }
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
                Text(recording ? "Press the new keys…" : combo.display)
                    .font(.callout.monospaced())
                    .foregroundStyle(recording ? Color.accentColor : .primary)
                    .frame(minWidth: 90, alignment: .trailing)
                Button(recording ? "Cancel" : "Change") { recording ? stop() : start() }
                    .buttonStyle(LTSoftButtonStyle(small: true))
                if combo != action.defaultCombo && !recording {
                    Button("Reset") { HotKeys.shared.set(action, nil); combo = HotKeys.shared.combo(action) }
                        .buttonStyle(.borderless).foregroundStyle(.secondary)
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
                if other == nil { HotKeys.shared.set(action, c); combo = c; note = "" } else { note = "Already used by " + (other?.title ?? "") }
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
