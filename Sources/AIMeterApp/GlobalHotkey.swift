import AIMeterCore
import Carbon.HIToolbox
import Foundation

/// Registers one global hotkey via Carbon `RegisterEventHotKey`.
///
/// Chosen over an NSEvent global monitor (documented per PER-6 scope): a
/// Carbon hotkey fires from any application without the process being trusted
/// for accessibility or input monitoring, so ⌘⇧U works with zero permission
/// prompts. No third-party dependency. One chord at a time; call `register`
/// again to swap the chord.
final class GlobalHotkeyController {
    private static let signature: OSType = 0x41494D54 // 'AIMT'

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var currentChord: HotkeyChord?
    private let action: () -> Void
    private var pendingError: String?

    /// Last registration failure surfaced to Settings (e.g. chord already in
    /// use elsewhere on the system). `nil` when the last register succeeded.
    var lastError: String? { pendingError }

    init(action: @escaping () -> Void) {
        self.action = action
    }

    /// (Re)registers the chord. Returns false on system refusal (hotkey in use).
    @discardableResult
    func register(_ chord: HotkeyChord) -> Bool {
        guard chord.keyCode != 0 else { return false }
        if currentChord == chord, hotKeyRef != nil {
            pendingError = nil
            return true
        }
        unregister()

        guard installEventHandler() else {
            pendingError = "Couldn't install the hotkey event handler."
            return false
        }

        var hotKeyID = EventHotKeyID(signature: Self.signature, id: 1)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(chord.keyCode, chord.modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr else {
            pendingError = status == eventHotKeyExistsErr
                ? "Hotkey \(chord.displayString) is already in use."
                : "The system refused hotkey \(chord.displayString) (error \(status))."
            return false
        }
        hotKeyRef = ref
        currentChord = chord
        pendingError = nil
        return true
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        hotKeyRef = nil
        currentChord = nil
    }

    private func installEventHandler() -> Bool {
        guard eventHandlerRef == nil else { return true }

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: EventHandlerUPP = { _, event, userData in
            guard let userData else { return noErr }
            let controller = Unmanaged<GlobalHotkeyController>.fromOpaque(userData).takeUnretainedValue()
            // Ignore our own ID/signature mismatch defensively.
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event,
                                           EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID),
                                           nil,
                                           MemoryLayout<EventHotKeyID>.size,
                                           nil,
                                           &hotKeyID)
            if status == noErr, hotKeyID.id == 1, hotKeyID.signature == GlobalHotkeyController.signature {
                controller.action()
            }
            return noErr
        }
        let status = InstallEventHandler(GetApplicationEventTarget(), callback,
                                         1, &eventType, context, &eventHandlerRef)
        return status == noErr
    }

    deinit {
        if let eventHandlerRef { RemoveEventHandler(eventHandlerRef) }
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
    }
}