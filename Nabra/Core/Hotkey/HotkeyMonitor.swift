import AppKit
import Carbon.HIToolbox

/// Watches the keyboard system-wide through an event tap and reports dictation gestures.
///
/// The tap runs on its own thread so a busy main thread can never delay the user's typing.
/// Requires the Accessibility permission.
final class HotkeyMonitor {
    /// Marks events Nabra posts itself (paste, typing) so the monitor ignores them.
    static let syntheticEventMarker: Int64 = 0x4E41_4252

    /// Delivered on the main queue, in order.
    var onAction: ((HotkeyGesture.Action) -> Void)?

    private let lock = NSLock()
    private var gesture: HotkeyGesture
    private var hotkey: Hotkey
    private var triggerKeysDown = Set<UInt16>()
    private var keyTriggerIsDown = false

    private var tap: CFMachPort?
    private var tapRunLoop: CFRunLoop?
    private let timerQueue = DispatchQueue(label: "app.nabra.hotkey.timer", qos: .userInteractive)

    init(hotkey: Hotkey, config: HotkeyGesture.Config) {
        self.hotkey = hotkey
        self.gesture = HotkeyGesture(config: config)
    }

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return tap != nil
    }

    func update(hotkey: Hotkey, config: HotkeyGesture.Config) {
        lock.lock()
        let changedKey = hotkey != self.hotkey
        self.hotkey = hotkey
        gesture.config = config
        if changedKey {
            triggerKeysDown.removeAll()
            keyTriggerIsDown = false
            gesture.reset(triggerStillDown: false)
        }
        lock.unlock()
    }

    /// Tells the gesture recogniser that dictation ended on its own (error, time limit, ...).
    func dictationEndedExternally() {
        lock.lock()
        gesture.reset(triggerStillDown: !triggerKeysDown.isEmpty || keyTriggerIsDown)
        lock.unlock()
    }

    @discardableResult
    func start() -> Bool {
        lock.lock()
        if tap != nil {
            lock.unlock()
            return true
        }
        lock.unlock()

        let types: [CGEventType] = [.flagsChanged, .keyDown, .keyUp, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1.rawValue)) }
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                           place: .headInsertEventTap,
                                           options: .defaultTap,
                                           eventsOfInterest: mask,
                                           callback: hotkeyTapCallback,
                                           userInfo: Unmanaged.passUnretained(self).toOpaque())
        else {
            return false
        }
        lock.lock()
        tap = port
        lock.unlock()

        let thread = Thread { [weak self] in
            guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else { return }
            let runLoop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(runLoop, source, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            self?.lock.lock()
            self?.tapRunLoop = runLoop
            self?.lock.unlock()
            CFRunLoopRun()
        }
        thread.name = "app.nabra.hotkey"
        thread.qualityOfService = .userInteractive
        thread.start()
        Log.info("Hotkey monitor started")
        return true
    }

    func stop() {
        lock.lock()
        let port = tap
        let runLoop = tapRunLoop
        tap = nil
        tapRunLoop = nil
        triggerKeysDown.removeAll()
        keyTriggerIsDown = false
        gesture.reset(triggerStillDown: false)
        lock.unlock()
        if let port {
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
        }
        if let runLoop { CFRunLoopStop(runLoop) }
    }

    // MARK: - Event handling (tap thread)

    /// Returns true when the event must not reach other apps.
    fileprivate func process(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            lock.lock()
            let port = tap
            lock.unlock()
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
            return false
        }
        if event.getIntegerValueField(.eventSourceUserData) == HotkeyMonitor.syntheticEventMarker {
            return false
        }

        let now = ProcessInfo.processInfo.systemUptime
        let keyCode = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags

        lock.lock()
        var gestureEvent: HotkeyGesture.Event?
        var swallow = false

        switch type {
        case .flagsChanged:
            if hotkey.kind == .modifier, hotkey.keyCodes.contains(keyCode) {
                let isDown = HotkeyMonitor.modifierIsDown(keyCode: keyCode, flags: flags,
                                                         wasDown: triggerKeysDown.contains(keyCode))
                if isDown {
                    let first = triggerKeysDown.isEmpty
                    triggerKeysDown.insert(keyCode)
                    if first {
                        if HotkeyMonitor.hasOtherModifiers(flags, besides: hotkey) {
                            gestureEvent = .otherModifierDown
                        } else {
                            gestureEvent = .triggerDown(activationDelay: Hotkey.activationDelay(forModifier: keyCode))
                        }
                    }
                } else {
                    triggerKeysDown.remove(keyCode)
                    if triggerKeysDown.isEmpty { gestureEvent = .triggerUp }
                }
            } else if Hotkey.isModifierKeyCode(keyCode), Int(keyCode) != kVK_CapsLock {
                if HotkeyMonitor.modifierIsDown(keyCode: keyCode, flags: flags, wasDown: false) {
                    gestureEvent = .otherModifierDown
                }
            }

        case .keyDown:
            if hotkey.kind == .key, hotkey.keyCodes.first == keyCode,
               HotkeyMonitor.standardModifiers(flags) == hotkey.modifiers {
                swallow = true
                let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                if !isRepeat, !keyTriggerIsDown {
                    keyTriggerIsDown = true
                    gestureEvent = .triggerDown(activationDelay: 0)
                }
            } else if Int(keyCode) == kVK_Escape {
                gestureEvent = .escapeDown
            } else {
                gestureEvent = .otherKeyDown
            }

        case .keyUp:
            if hotkey.kind == .key, hotkey.keyCodes.first == keyCode, keyTriggerIsDown {
                keyTriggerIsDown = false
                swallow = true
                gestureEvent = .triggerUp
            }

        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            gestureEvent = .mouseDown

        default:
            break
        }

        var output = HotkeyGesture.Output()
        if let gestureEvent {
            output = gesture.handle(gestureEvent, at: now)
        }
        lock.unlock()

        deliver(output)
        return swallow || output.swallow
    }

    private func deliver(_ output: HotkeyGesture.Output) {
        if let timer = output.timer {
            timerQueue.asyncAfter(deadline: .now() + timer.delay) { [weak self] in
                guard let self else { return }
                self.lock.lock()
                let result = self.gesture.handle(.timer(id: timer.id), at: ProcessInfo.processInfo.systemUptime)
                self.lock.unlock()
                self.deliver(result)
            }
        }
        guard !output.actions.isEmpty else { return }
        let actions = output.actions
        DispatchQueue.main.async { [weak self] in
            for action in actions { self?.onAction?(action) }
        }
    }

    // MARK: - Modifier helpers

    /// Device-specific modifier bits found in the low word of `CGEventFlags` for hardware events.
    private static func deviceMask(for keyCode: UInt16) -> UInt64? {
        switch Int(keyCode) {
        case kVK_Control: return 0x0001
        case kVK_Shift: return 0x0002
        case kVK_RightShift: return 0x0004
        case kVK_Command: return 0x0008
        case kVK_RightCommand: return 0x0010
        case kVK_Option: return 0x0020
        case kVK_RightOption: return 0x0040
        case kVK_RightControl: return 0x2000
        default: return nil
        }
    }

    private static let allDeviceBits: UInt64 = 0x207F

    private static func genericFlag(for keyCode: UInt16) -> CGEventFlags? {
        switch Int(keyCode) {
        case kVK_Control, kVK_RightControl: return .maskControl
        case kVK_Shift, kVK_RightShift: return .maskShift
        case kVK_Command, kVK_RightCommand: return .maskCommand
        case kVK_Option, kVK_RightOption: return .maskAlternate
        case kVK_Function: return .maskSecondaryFn
        case kVK_CapsLock: return .maskAlphaShift
        default: return nil
        }
    }

    static func modifierIsDown(keyCode: UInt16, flags: CGEventFlags, wasDown: Bool) -> Bool {
        guard let generic = genericFlag(for: keyCode) else { return false }
        guard flags.contains(generic) else { return false }
        if let mask = deviceMask(for: keyCode), flags.rawValue & allDeviceBits != 0 {
            return flags.rawValue & mask != 0
        }
        // No device-specific bits (synthetic or remapped events): the generic flag is set,
        // so this key went down unless we already thought it was down (then its twin is still held).
        return !wasDown
    }

    static func standardModifiers(_ flags: CGEventFlags) -> UInt {
        var result: NSEvent.ModifierFlags = []
        if flags.contains(.maskCommand) { result.insert(.command) }
        if flags.contains(.maskAlternate) { result.insert(.option) }
        if flags.contains(.maskControl) { result.insert(.control) }
        if flags.contains(.maskShift) { result.insert(.shift) }
        return result.rawValue
    }

    private static func hasOtherModifiers(_ flags: CGEventFlags, besides hotkey: Hotkey) -> Bool {
        var others: [CGEventFlags] = [.maskCommand, .maskAlternate, .maskControl, .maskShift, .maskSecondaryFn]
        let own = Set(hotkey.keyCodes.compactMap { genericFlag(for: $0)?.rawValue })
        others.removeAll { own.contains($0.rawValue) }
        return others.contains { flags.contains($0) }
    }
}

private func hotkeyTapCallback(proxy: CGEventTapProxy,
                               type: CGEventType,
                               event: CGEvent,
                               userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
    return monitor.process(type: type, event: event) ? nil : Unmanaged.passUnretained(event)
}
