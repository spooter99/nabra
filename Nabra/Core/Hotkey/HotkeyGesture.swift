import Foundation

/// Turns raw key transitions into dictation intents. Pure logic with no system dependencies,
/// so every timing rule here is covered by the self-test.
///
/// Gestures:
/// - Hold the trigger alone: push-to-talk. Release to finish.
/// - Double-tap the trigger: hands-free. Tap once more to finish.
/// - Esc cancels. Using the trigger as part of a shortcut (⌥←, ⌥-click) never starts dictation.
struct HotkeyGesture {
    struct Config: Equatable {
        var handsFreeEnabled = true
        /// A press shorter than this is a tap, not dictation.
        var tapMaxDuration: TimeInterval = 0.30
        /// Longest gap between the two taps of a double-tap.
        var doubleTapWindow: TimeInterval = 0.40
        /// Another key within this time of the trigger going down means "this is a shortcut".
        var comboGrace: TimeInterval = 0.70
        /// If the second press of a double-tap is held longer than this, it acts as push-to-talk.
        var latchHoldThreshold: TimeInterval = 0.45
    }

    enum Event: Equatable {
        case triggerDown(activationDelay: TimeInterval)
        case triggerUp
        case otherKeyDown
        case escapeDown
        case otherModifierDown
        case mouseDown
        case timer(id: Int)
    }

    enum CancelReason: Equatable {
        case escape
        case shortcut
        case tooShort
    }

    enum Action: Equatable {
        /// Start capturing. `handsFree` is true when started by a double-tap.
        case start(handsFree: Bool)
        /// Recording continues without the key held.
        case latch
        /// Finish and transcribe.
        case stop
        /// Throw the recording away.
        case cancel(CancelReason)
    }

    struct Output: Equatable {
        var actions: [Action] = []
        /// The event that caused this output should not reach other apps.
        var swallow = false
        var timer: TimerRequest?
    }

    struct TimerRequest: Equatable {
        var id: Int
        var delay: TimeInterval
    }

    enum State: Equatable {
        case idle
        case pending(downAt: TimeInterval, timer: Int)
        case holding(downAt: TimeInterval)
        case tapWait(timer: Int)
        case secondPress(downAt: TimeInterval)
        case latched
        /// Ignore everything until the trigger is released.
        case suppressed
    }

    var config: Config
    private(set) var state: State = .idle
    private var nextTimerID = 1

    init(config: Config = Config()) {
        self.config = config
    }

    var isRecording: Bool {
        switch state {
        case .holding, .secondPress, .latched: return true
        default: return false
        }
    }

    /// Called when dictation ended for a reason the gesture did not cause (error, time limit, UI button).
    mutating func reset(triggerStillDown: Bool) {
        state = triggerStillDown ? .suppressed : .idle
    }

    mutating func handle(_ event: Event, at time: TimeInterval) -> Output {
        var output = Output()
        switch state {
        case .idle:
            if case .triggerDown(let delay) = event {
                if delay <= 0 {
                    state = .holding(downAt: time)
                    output.actions = [.start(handsFree: false)]
                } else {
                    let id = makeTimer()
                    state = .pending(downAt: time, timer: id)
                    output.timer = TimerRequest(id: id, delay: delay)
                }
            }

        case .pending(let downAt, let timer):
            switch event {
            case .timer(let id) where id == timer:
                state = .holding(downAt: downAt)
                output.actions = [.start(handsFree: false)]
            case .triggerUp:
                output.timer = enterTapWaitOrIdle()
            case .otherKeyDown, .escapeDown, .otherModifierDown, .mouseDown:
                state = .suppressed
            default:
                break
            }

        case .holding(let downAt):
            switch event {
            case .triggerUp:
                if time - downAt < config.tapMaxDuration {
                    output.actions = [.cancel(.tooShort)]
                    output.timer = enterTapWaitOrIdle()
                } else {
                    output.actions = [.stop]
                    state = .idle
                }
            case .escapeDown:
                output.actions = [.cancel(.escape)]
                output.swallow = true
                state = .suppressed
            case .otherKeyDown, .otherModifierDown, .mouseDown:
                if time - downAt < config.comboGrace {
                    output.actions = [.cancel(.shortcut)]
                    state = .suppressed
                }
            default:
                break
            }

        case .tapWait(let timer):
            switch event {
            case .timer(let id) where id == timer:
                state = .idle
            case .triggerDown:
                state = .secondPress(downAt: time)
                output.actions = [.start(handsFree: true)]
            case .otherKeyDown, .escapeDown, .otherModifierDown, .mouseDown:
                state = .idle
            default:
                break
            }

        case .secondPress(let downAt):
            switch event {
            case .triggerUp:
                if time - downAt <= config.latchHoldThreshold {
                    state = .latched
                    output.actions = [.latch]
                } else {
                    state = .idle
                    output.actions = [.stop]
                }
            case .escapeDown:
                output.actions = [.cancel(.escape)]
                output.swallow = true
                state = .suppressed
            case .otherKeyDown, .otherModifierDown, .mouseDown:
                if time - downAt < config.comboGrace {
                    output.actions = [.cancel(.shortcut)]
                    state = .suppressed
                }
            default:
                break
            }

        case .latched:
            switch event {
            case .triggerDown:
                output.actions = [.stop]
                state = .suppressed
            case .escapeDown:
                output.actions = [.cancel(.escape)]
                output.swallow = true
                state = .idle
            default:
                break
            }

        case .suppressed:
            if event == .triggerUp {
                state = .idle
            }
        }
        return output
    }

    private mutating func makeTimer() -> Int {
        defer { nextTimerID += 1 }
        return nextTimerID
    }

    private mutating func enterTapWaitOrIdle() -> TimerRequest? {
        guard config.handsFreeEnabled else {
            state = .idle
            return nil
        }
        let id = makeTimer()
        state = .tapWait(timer: id)
        return TimerRequest(id: id, delay: config.doubleTapWindow)
    }
}
