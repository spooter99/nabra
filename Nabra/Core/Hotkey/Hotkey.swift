import AppKit
import Carbon.HIToolbox

/// The key (or key combination) that starts dictation.
struct Hotkey: Codable, Equatable, Hashable {
    enum Kind: String, Codable {
        /// One or more modifier keys pressed on their own, e.g. Right Option.
        case modifier
        /// A regular key, optionally with modifiers, e.g. F5 or ⌃Space.
        case key
    }

    var kind: Kind
    /// Virtual key codes. For `.modifier` any of them triggers; for `.key` there is exactly one.
    var keyCodes: [UInt16]
    /// Required modifiers for `.key` hotkeys (device-independent `NSEvent.ModifierFlags` raw value).
    var modifiers: UInt = 0

    static let rightOption = Hotkey(kind: .modifier, keyCodes: [UInt16(kVK_RightOption)])
    static let leftOption = Hotkey(kind: .modifier, keyCodes: [UInt16(kVK_Option)])
    static let eitherOption = Hotkey(kind: .modifier, keyCodes: [UInt16(kVK_Option), UInt16(kVK_RightOption)])
    static let function = Hotkey(kind: .modifier, keyCodes: [UInt16(kVK_Function)])
    static let rightCommand = Hotkey(kind: .modifier, keyCodes: [UInt16(kVK_RightCommand)])
    static let rightControl = Hotkey(kind: .modifier, keyCodes: [UInt16(kVK_RightControl)])

    static let presets: [Hotkey] = [.eitherOption, .rightOption, .leftOption, .function, .rightCommand]
    static let `default` = Hotkey.eitherOption

    /// Short symbol-style name, e.g. "⌥" or "Right ⌥" or "⌃Space".
    var displayName: String {
        switch kind {
        case .modifier:
            if self == .eitherOption { return "⌥ Option" }
            return keyCodes.map { Hotkey.modifierName(for: $0) }.joined(separator: " or ")
        case .key:
            return Hotkey.modifierSymbols(for: modifiers) + Hotkey.keyName(for: keyCodes.first ?? 0)
        }
    }

    /// Longer description for settings, e.g. "Either Option key".
    var longName: String {
        if self == .eitherOption { return "Either Option key" }
        if self == .rightOption { return "Right Option key" }
        if self == .leftOption { return "Left Option key" }
        if self == .function { return "Fn (Globe) key" }
        if self == .rightCommand { return "Right Command key" }
        if self == .rightControl { return "Right Control key" }
        return displayName
    }

    /// Glyph shown inside key caps.
    var keyCapSymbol: String {
        switch kind {
        case .modifier:
            switch Int(keyCodes.first ?? 0) {
            case kVK_Option, kVK_RightOption: return "⌥"
            case kVK_Command, kVK_RightCommand: return "⌘"
            case kVK_Control, kVK_RightControl: return "⌃"
            case kVK_Shift, kVK_RightShift: return "⇧"
            case kVK_Function: return "🌐"
            default: return "?"
            }
        case .key:
            return displayName
        }
    }

    var isFunctionKey: Bool { kind == .modifier && keyCodes == [UInt16(kVK_Function)] }

    /// How long a modifier must be held alone before recording starts.
    /// Left-hand modifiers are used in shortcuts all day (⌥←, ⌥⌫), so they wait briefly;
    /// right-hand ones start instantly.
    static func activationDelay(forModifier keyCode: UInt16) -> TimeInterval {
        switch Int(keyCode) {
        case kVK_Option, kVK_Command, kVK_Control, kVK_Shift: return 0.16
        default: return 0
        }
    }

    static func isModifierKeyCode(_ keyCode: UInt16) -> Bool {
        switch Int(keyCode) {
        case kVK_Option, kVK_RightOption, kVK_Command, kVK_RightCommand, kVK_Control, kVK_RightControl,
             kVK_Shift, kVK_RightShift, kVK_Function, kVK_CapsLock:
            return true
        default:
            return false
        }
    }

    static func modifierName(for keyCode: UInt16) -> String {
        switch Int(keyCode) {
        case kVK_Option: return "Left ⌥"
        case kVK_RightOption: return "Right ⌥"
        case kVK_Command: return "Left ⌘"
        case kVK_RightCommand: return "Right ⌘"
        case kVK_Control: return "Left ⌃"
        case kVK_RightControl: return "Right ⌃"
        case kVK_Shift: return "Left ⇧"
        case kVK_RightShift: return "Right ⇧"
        case kVK_Function: return "Fn 🌐"
        default: return "Key \(keyCode)"
        }
    }

    static func modifierSymbols(for rawFlags: UInt) -> String {
        let flags = NSEvent.ModifierFlags(rawValue: rawFlags)
        var text = ""
        if flags.contains(.control) { text += "⌃" }
        if flags.contains(.option) { text += "⌥" }
        if flags.contains(.shift) { text += "⇧" }
        if flags.contains(.command) { text += "⌘" }
        return text
    }

    static func keyName(for keyCode: UInt16) -> String {
        let special: [Int: String] = [
            kVK_Space: "Space", kVK_Return: "Return", kVK_Tab: "Tab", kVK_Escape: "Esc", kVK_Delete: "Delete",
            kVK_ForwardDelete: "Fwd Delete", kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑",
            kVK_DownArrow: "↓", kVK_Home: "Home", kVK_End: "End", kVK_PageUp: "Page Up", kVK_PageDown: "Page Down",
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7",
            kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12", kVK_F13: "F13",
            kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19",
            kVK_F20: "F20", kVK_ANSI_KeypadEnter: "Enter",
        ]
        if let name = special[Int(keyCode)] { return name }
        return KeyboardLayout.character(forKeyCode: keyCode)?.uppercased() ?? "Key \(keyCode)"
    }
}

/// Lookups against the current keyboard layout. Call from the main thread only (Text Input Sources requirement).
enum KeyboardLayout {
    /// True when the keyboard layout currently selected types Arabic.
    static var currentInputIsArabic: Bool {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages)
        else { return false }
        let languages = Unmanaged<CFArray>.fromOpaque(pointer).takeUnretainedValue() as? [String] ?? []
        return languages.first?.hasPrefix("ar") ?? false
    }

    private static func layoutData() -> Data? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        return Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
    }

    /// The character a key produces without modifiers in the current ASCII-capable layout.
    static func character(forKeyCode keyCode: UInt16) -> String? {
        guard let data = layoutData() else { return nil }
        return data.withUnsafeBytes { raw -> String? in
            guard let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return nil }
            var deadKeyState: UInt32 = 0
            var length = 0
            var characters = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                        OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeyState, 4, &length, &characters)
            guard status == noErr, length > 0 else { return nil }
            return String(utf16CodeUnits: characters, count: length)
        }
    }

    /// The key code that types `character` in the current layout (QWERTY position as a fallback).
    static func keyCode(for character: Character, fallback: UInt16) -> UInt16 {
        let wanted = String(character).lowercased()
        for keyCode in UInt16(0)..<UInt16(127) where !Hotkey.isModifierKeyCode(keyCode) {
            if self.character(forKeyCode: keyCode)?.lowercased() == wanted { return keyCode }
        }
        return fallback
    }
}
