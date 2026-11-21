import AppKit
import Carbon.HIToolbox

/// Watches the keyboard system-wide through an event tap and reports dictation gestures.
///
/// The tap runs on its own thread so a busy main thread can never delay the user's typing.
/// Requires the Accessibility permission.
///
/// Which trigger keys are down is read from each event rather than remembered from earlier ones,
/// and a watchdog compares the gesture with the real keyboard while a key is believed to be held.
/// A key event that never arrives (password fields hide them, the system can pause a tap) therefore
/// costs nothing: the next event, or the watchdog, puts things right.
final class HotkeyMonitor {
    /// Marks events Nabra posts itself (paste, typing) so the monitor ignores them.
    static let syntheticEventMarker: Int64 = 0x4E41_4252

    /// Delivered on the main queue, in the order the gestures happened. `keyDownAt` is the uptime
    /// (`Uptime.now`) at which the trigger of this press went down.
    var onAction: ((HotkeyGesture.Action, _ keyDownAt: UInt64) -> Void)?

    /// Whether the trigger is physically down right now. Replaceable for tests.
    var physicalProbe: (Hotkey) -> Bool = HotkeyMonitor.triggerIsPhysicallyDown
    /// Where unusual events are reported. Replaceable for tests.
    var report: (String) -> Void = { Log.info($0) }

    private let lock = NSLock()
    private var gesture: HotkeyGesture
    private var hotkey: Hotkey
    private var triggerKeysDown = Set<UInt16>()
    private var keyTriggerIsDown = false
    private var pressStartedAt: UInt64 = 0

    private var tap: CFMachPort?
    private var tapRunLoop: CFRunLoop?
    private let timerQueue = DispatchQueue(label: "app.nabra.hotkey.timer", qos: .userInteractive)

    // Watchdog state, under `lock`.
    private var holdWatch: DispatchSourceTimer?
    private var probeTrusted = false
    private var probeMisses = 0
    private var healthTimer: DispatchSourceTimer?
    private var lastAnomalyLog: [String: UInt64] = [:]

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
            updateHoldWatch()
        }
        lock.unlock()
    }

    /// Tells the gesture recogniser that dictation ended on its own (error, time limit, ...).
    func dictationEndedExternally() {
        lock.lock()
        gesture.reset(triggerStillDown: !triggerKeysDown.isEmpty || keyTriggerIsDown)
        updateHoldWatch()
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
        startHealthCheck()
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
        updateHoldWatch()
        healthTimer?.cancel()
        healthTimer = nil
        lock.unlock()
        if let port {
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
        }
        if let runLoop { CFRunLoopStop(runLoop) }
    }

    // MARK: - Event handling (tap thread)

    /// Feeds one keyboard or mouse event through the same logic as the system tap, without posting
    /// anything. Used by the built-in end-to-end tests. Returns true when the event would be swallowed.
    @discardableResult
    func inject(type: CGEventType, keyCode: UInt16 = 0, flags: CGEventFlags = []) -> Bool {
        guard let event = CGEvent(source: nil) else { return false }
        event.type = type
        event.flags = flags
        event.setIntegerValueField(.keyboardEventKeycode, value: Int64(keyCode))
        return process(type: type, event: event)
    }

    /// Returns true when the event must not reach other apps.
    fileprivate func process(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            lock.lock()
            let port = tap
            logAnomaly("tap-paused", "The system paused key monitoring (\(type == .tapDisabledByTimeout ? "timeout" : "user input")); resumed")
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
        defer { lock.unlock() }
        var gestureEvents: [HotkeyGesture.Event] = []
        var swallow = false

        switch type {
        case .flagsChanged:
            if hotkey.kind == .chord {
                gestureEvents = chordEvents(flags: flags)
            } else if hotkey.kind == .modifier {
                gestureEvents = modifierEvents(keyCode: keyCode, flags: flags)
            } else if Hotkey.isModifierKeyCode(keyCode), Int(keyCode) != kVK_CapsLock,
                      HotkeyMonitor.modifierIsDown(keyCode: keyCode, flags: flags, wasDown: false) {
                gestureEvents = [.otherModifierDown]
            }

        case .keyDown:
            if hotkey.kind == .key, hotkey.keyCodes.first == keyCode,
               HotkeyMonitor.standardModifiers(flags) == hotkey.modifiers {
                swallow = true
                let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                if !isRepeat {
                    if keyTriggerIsDown {
                        // A fresh press of a key believed to be down: its release never arrived.
                        logAnomaly("missed-release", "A key release was missed; recovered on the next press")
                        gestureEvents = [.triggerUp]
                    }
                    keyTriggerIsDown = true
                    gestureEvents.append(.triggerDown(activationDelay: 0))
                }
            } else if Int(keyCode) == kVK_Escape {
                gestureEvents = [.escapeDown]
            } else {
                gestureEvents = [.otherKeyDown]
            }

        case .keyUp:
            if hotkey.kind == .key, hotkey.keyCodes.first == keyCode, keyTriggerIsDown {
                keyTriggerIsDown = false
                swallow = true
                gestureEvents = [.triggerUp]
            }

        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            gestureEvents = [.mouseDown]

        default:
            break
        }

        for gestureEvent in gestureEvents {
            if case .triggerDown = gestureEvent {
                pressStartedAt = Uptime.now
                // The key has just gone down, so a working probe must agree. If it does not, it is not
                // trusted to end this press.
                probeTrusted = physicalProbe(hotkey)
                probeMisses = 0
                if !probeTrusted { logAnomaly("probe", "Keyboard state could not be confirmed at key-down; release watchdog off for this press") }
            }
            let output = gesture.handle(gestureEvent, at: now)
            deliver(output)
            swallow = swallow || output.swallow
        }
        if !gestureEvents.isEmpty { updateHoldWatch() }
        return swallow
    }

    /// Works out what a modifier event means for a chord (⌃⌥ held together). The press counts from
    /// the moment exactly the chord's modifiers are held; adding another one makes it a shortcut, and
    /// letting go of any of them ends it. Caller holds `lock`.
    private func chordEvents(flags: CGEventFlags) -> [HotkeyGesture.Event] {
        let held = HotkeyMonitor.heldModifiers(flags)
        let wanted = hotkey.chordFlags
        let wasDown = keyTriggerIsDown
        if held == wanted {
            guard !wasDown else { return [] }
            keyTriggerIsDown = true
            // Chords are used in shortcuts (⌃⌥←), so they wait like the left-hand keys do.
            return [.triggerDown(activationDelay: 0.16)]
        }
        guard wasDown else { return [] }
        if held.isSuperset(of: wanted) { return [.otherModifierDown] }
        keyTriggerIsDown = false
        return [.triggerUp]
    }

    /// The modifiers held according to an event's flags, as `NSEvent.ModifierFlags`.
    static func heldModifiers(_ flags: CGEventFlags) -> NSEvent.ModifierFlags {
        var result: NSEvent.ModifierFlags = []
        if flags.contains(.maskControl) { result.insert(.control) }
        if flags.contains(.maskAlternate) { result.insert(.option) }
        if flags.contains(.maskShift) { result.insert(.shift) }
        if flags.contains(.maskCommand) { result.insert(.command) }
        if flags.contains(.maskSecondaryFn) { result.insert(.function) }
        return result
    }

    /// Works out what a modifier event means for a modifier-key trigger. Caller holds `lock`.
    private func modifierEvents(keyCode: UInt16, flags: CGEventFlags) -> [HotkeyGesture.Event] {
        let previous = triggerKeysDown
        let isTriggerKey = hotkey.keyCodes.contains(keyCode)
        var current = previous
        var missedRelease = false

        if let held = HotkeyMonitor.triggerKeys(heldIn: flags, hotkey: hotkey) {
            // The event itself says which trigger keys are down: nothing remembered can go stale.
            current = held
            if isTriggerKey, held.contains(keyCode), previous.contains(keyCode) {
                // This key changed and is down, yet it was believed to be down already.
                missedRelease = true
            } else if !previous.isEmpty, !held.isEmpty, previous.isDisjoint(with: held) {
                missedRelease = true
            }
        } else if isTriggerKey {
            // No per-key information (remapped or synthetic events): follow the transitions.
            if HotkeyMonitor.modifierIsDown(keyCode: keyCode, flags: flags, wasDown: previous.contains(keyCode)) {
                current.insert(keyCode)
            } else {
                current.remove(keyCode)
            }
        }
        triggerKeysDown = current

        var events: [HotkeyGesture.Event] = []
        let press: HotkeyGesture.Event = HotkeyMonitor.hasOtherModifiers(flags, besides: hotkey)
            ? .otherModifierDown
            : .triggerDown(activationDelay: Hotkey.activationDelay(forModifier: current.contains(keyCode) ? keyCode : (current.first ?? keyCode)))
        if missedRelease {
            logAnomaly("missed-release", "A key release was missed; recovered on the next press")
            events = [.triggerUp, press]
        } else if previous.isEmpty, !current.isEmpty {
            events = [press]
        } else if !previous.isEmpty, current.isEmpty {
            events = [.triggerUp]
        }
        if !isTriggerKey, Hotkey.isModifierKeyCode(keyCode), Int(keyCode) != kVK_CapsLock,
           HotkeyMonitor.modifierIsDown(keyCode: keyCode, flags: flags, wasDown: false) {
            events.append(.otherModifierDown)
        }
        return events
    }

    /// Schedules timers and hands actions to the main queue. Caller holds `lock`, which is what keeps
    /// actions from the tap thread and from timers in the order the gesture produced them.
    private func deliver(_ output: HotkeyGesture.Output) {
        if let timer = output.timer {
            timerQueue.asyncAfter(deadline: .now() + timer.delay) { [weak self] in
                guard let self else { return }
                self.lock.lock()
                let result = self.gesture.handle(.timer(id: timer.id), at: ProcessInfo.processInfo.systemUptime)
                self.deliver(result)
                self.updateHoldWatch()
                self.lock.unlock()
            }
        }
        guard !output.actions.isEmpty else { return }
        let actions = output.actions
        let keyDownAt = pressStartedAt
        DispatchQueue.main.async { [weak self] in
            for action in actions { self?.onAction?(action, keyDownAt) }
        }
    }

    // MARK: - Watchdogs

    /// While the gesture believes the trigger is held, compare with the real keyboard a few times a
    /// second. Caller holds `lock`.
    private func updateHoldWatch() {
        let needed = gesture.expectsTriggerHeld
        if needed, holdWatch == nil {
            let timer = DispatchSource.makeTimerSource(queue: timerQueue)
            timer.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(250), leeway: .milliseconds(40))
            timer.setEventHandler { [weak self] in self?.checkHold() }
            timer.resume()
            holdWatch = timer
        } else if !needed, let timer = holdWatch {
            timer.cancel()
            holdWatch = nil
        }
    }

    private func checkHold() {
        lock.lock()
        defer { lock.unlock() }
        guard gesture.expectsTriggerHeld else {
            updateHoldWatch()
            return
        }
        guard probeTrusted else { return }
        if physicalProbe(hotkey) {
            probeMisses = 0
            return
        }
        probeMisses += 1
        // Three readings in a row (about 0.75 s): the key is up and its release was never reported.
        guard probeMisses >= 3 else { return }
        probeMisses = 0
        triggerKeysDown.removeAll()
        keyTriggerIsDown = false
        logAnomaly("missed-release", "A key release was missed; the dictation key is up, finishing")
        let output = gesture.handle(.triggerUp, at: ProcessInfo.processInfo.systemUptime)
        deliver(output)
        updateHoldWatch()
    }

    /// The system can stop an event tap without telling it. Check now and then, and switch it back on.
    private func startHealthCheck() {
        let timer = DispatchSource.makeTimerSource(queue: timerQueue)
        timer.schedule(deadline: .now() + .seconds(10), repeating: .seconds(10), leeway: .seconds(3))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let port = self.tap
            if let port, !CGEvent.tapIsEnabled(tap: port) {
                CGEvent.tapEnable(tap: port, enable: true)
                self.logAnomaly("tap-off", "Key monitoring had been switched off by the system; switched back on")
            }
            self.lock.unlock()
        }
        timer.resume()
        lock.lock()
        healthTimer?.cancel()
        healthTimer = timer
        lock.unlock()
    }

    /// Logs an unusual event, at most once every few seconds per kind. Caller holds `lock`.
    private func logAnomaly(_ kind: String, _ message: String) {
        let now = Uptime.now
        if let last = lastAnomalyLog[kind], now - last < 5_000_000_000 { return }
        lastAnomalyLog[kind] = now
        report(message)
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

    /// The trigger keys of `hotkey` that `flags` shows as held, or nil when the flags cannot tell
    /// (a left/right pair without device-specific bits, as in remapped or synthetic events).
    static func triggerKeys(heldIn flags: CGEventFlags, hotkey: Hotkey) -> Set<UInt16>? {
        var held = Set<UInt16>()
        let hasDeviceBits = flags.rawValue & allDeviceBits != 0
        for keyCode in hotkey.keyCodes {
            guard let generic = genericFlag(for: keyCode) else { return nil }
            // Without its generic flag a key is certainly up.
            guard flags.contains(generic) else { continue }
            if let mask = deviceMask(for: keyCode) {
                guard hasDeviceBits else { return nil }
                if flags.rawValue & mask != 0 { held.insert(keyCode) }
            } else {
                held.insert(keyCode)
            }
        }
        return held
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

    /// Whether the trigger is down, read from the system rather than remembered. The hardware state
    /// is not affected by events Nabra posts (its own paste); the session state is asked as well, and
    /// the key counts as down if either says so, so that a dictation is only ever ended on agreement.
    static func triggerIsPhysicallyDown(_ hotkey: Hotkey) -> Bool {
        for state in [CGEventSourceStateID.hidSystemState, .combinedSessionState] {
            switch hotkey.kind {
            case .modifier:
                let flags = CGEventSource.flagsState(state)
                if hotkey.keyCodes.contains(where: { genericFlag(for: $0).map { flags.contains($0) } ?? false }) { return true }
            case .key:
                if let keyCode = hotkey.keyCodes.first, CGEventSource.keyState(state, key: CGKeyCode(keyCode)) { return true }
            case .chord:
                if heldModifiers(CGEventSource.flagsState(state)).isSuperset(of: hotkey.chordFlags) { return true }
            }
        }
        return false
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
