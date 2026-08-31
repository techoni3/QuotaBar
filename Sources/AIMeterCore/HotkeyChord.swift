import Carbon.HIToolbox
import Foundation

/// A user-configurable global hotkey as Carbon key code + modifiers.
///
/// The same integers drive both registration (`RegisterEventHotKey`) and the
/// display label, so a relaunch shows exactly the chord the user recorded.
public struct HotkeyChord: Equatable, Sendable, Codable {
    public var keyCode: UInt32
    public var modifiers: UInt32

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// Spec Decision 6 default: ⌘⇧U.
    public static let defaults = HotkeyChord(keyCode: UInt32(kVK_ANSI_U),
                                            modifiers: UInt32(cmdKey | shiftKey))

    public static let command = UInt32(cmdKey)
    public static let shift = UInt32(shiftKey)
    public static let option = UInt32(optionKey)
    public static let control = UInt32(controlKey)

    public var hasModifier: Bool { modifiers != 0 }

    /// Standard macOS display order: ⌃⌥⇧⌘.
    public var displayString: String {
        var out = ""
        if modifiers & Self.control != 0 { out += "⌃" }
        if modifiers & Self.option != 0 { out += "⌥" }
        if modifiers & Self.shift != 0 { out += "⇧" }
        if modifiers & Self.command != 0 { out += "⌘" }
        return out + KeyCodeNames.name(for: keyCode)
    }
}

/// Carbon virtual-key-code → human name. Letter codes follow the ANSI keyboard
/// LAYOUT positions (not alphabetical values — kVK_ANSI_Z is 0x06), so they map
/// explicitly; F-key codes are also non-sequential.
public enum KeyCodeNames {
    private static let letters: [UInt32: String] = [
        UInt32(kVK_ANSI_A): "A", UInt32(kVK_ANSI_S): "S", UInt32(kVK_ANSI_D): "D",
        UInt32(kVK_ANSI_F): "F", UInt32(kVK_ANSI_H): "H", UInt32(kVK_ANSI_G): "G",
        UInt32(kVK_ANSI_Z): "Z", UInt32(kVK_ANSI_X): "X", UInt32(kVK_ANSI_C): "C",
        UInt32(kVK_ANSI_V): "V", UInt32(kVK_ANSI_B): "B", UInt32(kVK_ANSI_Q): "Q",
        UInt32(kVK_ANSI_W): "W", UInt32(kVK_ANSI_E): "E", UInt32(kVK_ANSI_R): "R",
        UInt32(kVK_ANSI_Y): "Y", UInt32(kVK_ANSI_T): "T", UInt32(kVK_ANSI_O): "O",
        UInt32(kVK_ANSI_U): "U", UInt32(kVK_ANSI_I): "I", UInt32(kVK_ANSI_P): "P",
        UInt32(kVK_ANSI_L): "L", UInt32(kVK_ANSI_J): "J", UInt32(kVK_ANSI_K): "K",
        UInt32(kVK_ANSI_N): "N", UInt32(kVK_ANSI_M): "M",
    ]

    public static func name(for keyCode: UInt32) -> String {
        if let letter = letters[keyCode] { return letter }
        switch keyCode {
        case UInt32(kVK_ANSI_0): return "0"
        case UInt32(kVK_ANSI_1): return "1"
        case UInt32(kVK_ANSI_2): return "2"
        case UInt32(kVK_ANSI_3): return "3"
        case UInt32(kVK_ANSI_4): return "4"
        case UInt32(kVK_ANSI_5): return "5"
        case UInt32(kVK_ANSI_6): return "6"
        case UInt32(kVK_ANSI_7): return "7"
        case UInt32(kVK_ANSI_8): return "8"
        case UInt32(kVK_ANSI_9): return "9"
        case UInt32(kVK_Space): return "Space"
        case UInt32(kVK_Return): return "Return"
        case UInt32(kVK_Escape): return "Esc"
        case UInt32(kVK_Delete): return "Delete"
        case UInt32(kVK_ForwardDelete): return "Fn-Delete"
        case UInt32(kVK_Tab): return "Tab"
        case UInt32(kVK_UpArrow): return "↑"
        case UInt32(kVK_DownArrow): return "↓"
        case UInt32(kVK_LeftArrow): return "←"
        case UInt32(kVK_RightArrow): return "→"
        // F-keys: non-sequential Carbon values.
        case 0x7A: return "F1"
        case 0x78: return "F2"
        case 0x63: return "F3"
        case 0x76: return "F4"
        case 0x60: return "F5"
        case 0x61: return "F6"
        case 0x62: return "F7"
        case 0x64: return "F8"
        case 0x65: return "F9"
        case 0x6D: return "F10"
        case 0x67: return "F11"
        case 0x6F: return "F12"
        case 0x69: return "F13"
        case 0x6B: return "F14"
        case 0x71: return "F15"
        case 0x6A: return "F16"
        case 0x40: return "F17"
        case 0x4F: return "F18"
        case 0x50: return "F19"
        default:
            return "Key \(keyCode)"
        }
    }
}