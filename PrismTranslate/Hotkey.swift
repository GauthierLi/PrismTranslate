import AppKit
import Carbon.HIToolbox

/// Registers a single global hotkey (default: Cmd+Shift+T) using Carbon.
/// Fires `onFire` on the main thread when pressed.
final class HotkeyManager {
    static let shared = HotkeyManager()

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    var onFire: (() -> Void)?

    private let signature: OSType = 0x43_4C_54_52 // 'CLTR'
    private let hotkeyID: UInt32 = 1

    func register() {
        unregister()

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: OSType(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { (_, eventRef, userData) -> OSStatus in
            guard let userData else { return noErr }
            let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
            var hkID = EventHotKeyID()
            GetEventParameter(eventRef, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            if hkID.id == manager.hotkeyID {
                DispatchQueue.main.async { manager.onFire?() }
            }
            return noErr
        }, 1, &eventType, selfPtr, &eventHandler)

        let hkID = EventHotKeyID(signature: signature, id: hotkeyID)
        // Cmd+Shift+T
        let keyCode = UInt32(kVK_ANSI_T)
        let modifiers = UInt32(cmdKey | shiftKey)
        RegisterEventHotKey(keyCode, modifiers, hkID, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
    }
}
