import Carbon.HIToolbox
import Foundation

/// Global shortcuts that work while the meeting app has the focus (no Accessibility permission:
/// Carbon hot keys are registered for this app only and do not read other keystrokes).
///   Control-Option-H  HELP NOW in the tips window
///   Control-Option-P  pause or resume tips
final class HotKeys: @unchecked Sendable {
    nonisolated(unsafe) static let shared = HotKeys()
    private var refs: [EventHotKeyRef?] = []
    private var actions: [UInt32: () -> Void] = [:]
    private var handler: EventHandlerRef?

    func install(help: @escaping () -> Void, pause: @escaping () -> Void) {
        guard handler == nil else { return }
        actions = [1: help, 2: pause]
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            let action = HotKeys.shared.actions[id.id]
            DispatchQueue.main.async { action?() }
            return noErr
        }, 1, &spec, nil, &handler)
        register(id: 1, key: UInt32(kVK_ANSI_H))
        register(id: 2, key: UInt32(kVK_ANSI_P))
    }

    private func register(id: UInt32, key: UInt32) {
        var ref: EventHotKeyRef?
        let hid = EventHotKeyID(signature: OSType(0x4C544950), id: id)   // "LTIP"
        let status = RegisterEventHotKey(key, UInt32(controlKey | optionKey), hid, GetApplicationEventTarget(), 0, &ref)
        if status == noErr { refs.append(ref) }
    }
}
