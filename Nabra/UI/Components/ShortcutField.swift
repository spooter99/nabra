import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Shows a shortcut and records a new one. Click, press what you want, let go:
/// - one modifier on its own (Right ⌘, Fn …),
/// - several modifiers held together (⌃⌥),
/// - or a key with modifiers (⌃Space), or a function key on its own (F5).
/// Esc cancels. While recording, Nabra's own keys are switched off so they do not start dictating.
struct ShortcutField: View {
    @Environment(AppState.self) private var state
    @Binding var hotkey: Hotkey
    /// The other mode's key, which this one may not collide with.
    var other: Hotkey
    var otherName: String
    var presets: [Hotkey]

    @State private var recording = false
    @State private var monitor: Any?
    @State private var held = Set<UInt16>()
    @State private var peak = Set<UInt16>()
    @State private var message: String?

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 6) {
                Button(action: { recording ? stopRecording() : startRecording() }) {
                    Text(recording ? (peak.isEmpty ? "Press the keys…" : ShortcutField.describe(peak)) : hotkey.longName)
                        .frame(minWidth: 160)
                }
                .help(recording ? "Press the keys you want, then let go. Esc cancels." : "Click, then press the keys you want")
                Menu {
                    ForEach(presets, id: \.self) { preset in
                        Button(preset.longName) { choose(preset) }
                            .disabled(preset.overlaps(other))
                    }
                } label: {
                    Image(systemName: "chevron.down")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Common choices")
            }
            if let message {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }
        }
        .onDisappear(perform: stopRecording)
    }

    // MARK: - Recording

    private func startRecording() {
        message = nil
        held = []
        peak = []
        recording = true
        state.pauseHotkeys(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { event in
            handle(event)
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        guard recording else { return }
        recording = false
        held = []
        peak = []
        state.pauseHotkeys(false)
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .flagsChanged:
            let code = event.keyCode
            guard Hotkey.isModifierKeyCode(code), Int(code) != kVK_CapsLock else { return }
            let flags = CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue))
            if HotkeyMonitor.modifierIsDown(keyCode: code, flags: flags, wasDown: held.contains(code)) {
                held.insert(code)
                peak.formUnion(held)
            } else {
                held.remove(code)
            }
            // All let go: what was held at most is the shortcut.
            if held.isEmpty, !peak.isEmpty { finish(ShortcutField.hotkey(forModifiers: peak)) }
        case .keyDown:
            let code = event.keyCode
            if Int(code) == kVK_Escape, held.isEmpty {
                stopRecording()
                return
            }
            let modifiers = event.modifierFlags.intersection([.control, .option, .shift, .command])
            guard !modifiers.isEmpty || ShortcutField.functionKeys.contains(Int(code)) else {
                message = "Add ⌃, ⌥, ⌘ or ⇧ to that key, or use a function key like F5"
                return
            }
            finish(Hotkey(kind: .key, keyCodes: [code], modifiers: modifiers.rawValue))
        default:
            break
        }
    }

    private func finish(_ candidate: Hotkey) {
        stopRecording()
        choose(candidate)
    }

    private func choose(_ candidate: Hotkey) {
        guard !candidate.overlaps(other) else {
            message = "That is already \(otherName)"
            return
        }
        message = nil
        hotkey = candidate
    }

    // MARK: - Helpers

    private static let functionKeys: Set<Int> = [
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12,
        kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
    ]

    /// A single modifier keeps its side ("Right ⌘"); several held together become a chord.
    static func hotkey(forModifiers keys: Set<UInt16>) -> Hotkey {
        if keys == [UInt16(kVK_Option), UInt16(kVK_RightOption)] { return .eitherOption }
        if keys.count == 1, let key = keys.first { return Hotkey(kind: .modifier, keyCodes: [key]) }
        var flags: NSEvent.ModifierFlags = []
        for key in keys {
            switch Int(key) {
            case kVK_Control, kVK_RightControl: flags.insert(.control)
            case kVK_Option, kVK_RightOption: flags.insert(.option)
            case kVK_Shift, kVK_RightShift: flags.insert(.shift)
            case kVK_Command, kVK_RightCommand: flags.insert(.command)
            case kVK_Function: flags.insert(.function)
            default: break
            }
        }
        return .chord(flags)
    }

    static func describe(_ keys: Set<UInt16>) -> String {
        keys.sorted().map { Hotkey.modifierName(for: $0) }.joined(separator: " + ")
    }
}
