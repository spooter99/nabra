import AppKit
import Carbon.HIToolbox

/// End-to-end checks of the whole dictation loop, run inside the real app.
///
/// The robot presses and releases the dictation key by handing events straight to the key monitor
/// (nothing is posted to the system, so other apps and another running Nabra never see them), lets
/// the controller, recorder, recogniser and indicator do their normal work, and writes down what
/// happened. Text is never inserted anywhere, no sounds are played and the indicator stays off screen.
///
///   open -n -g Nabra.app --env NABRA_SUPPORT_DIR=<scratch> --env NABRA_ROBOT=<report file> \
///        [--env NABRA_ROBOT_AUDIO=<speech file>] [--env NABRA_ROBOT_ONLY=hold,overlap]
///
/// With NABRA_ROBOT_AUDIO the file is played in place of the microphone, which makes the text
/// predictable. Without it the real microphone is used, which is how start-up timing is measured.
/// NABRA_SUPPORT_DIR is required so real history is never touched.
final class Robot {
    static let reportPath = ProcessInfo.processInfo.environment["NABRA_ROBOT"]
    static var isEnabled: Bool { reportPath != nil }

    private let state: AppState
    private let monitor: HotkeyMonitor
    private let scribeMonitor: HotkeyMonitor
    /// What the indicator showed, in order.
    private var hudModes: [String] = []
    private var lines: [String] = []
    private let started = Uptime.now
    private var failures = 0
    private var checks = 0

    // What the app did, as seen from outside. Main thread.
    private var actions: [(at: Double, action: String)] = []
    private var texts: [(at: Double, session: Int, text: String)] = []
    private var phases: [(at: Double, phase: String)] = []
    /// Whether the microphone was on at named moments of a scenario.
    private var microphoneOn: [String: Bool] = [:]

    // The pretend keyboard. Any thread.
    private let keyLock = NSLock()
    private var keysDown = Set<UInt16>()
    /// When set, the keyboard check always answers "down" (as if it could not see a release).
    private var probeStuckDown = false
    /// The key events of the scenario being played, run in order on one thread.
    private var script: [(at: Double, work: () -> Void)] = []

    private static let leftOption = UInt16(kVK_Option)
    private static let rightOption = UInt16(kVK_RightOption)
    private static let rightCommand = UInt16(kVK_RightCommand)

    init(state: AppState) {
        self.state = state
        monitor = state.hotkeyMonitor
        scribeMonitor = state.scribeHotkeyMonitor
    }

    /// Prepares the app for unattended use. Call before `AppState.start()`.
    static func configure(_ state: AppState) {
        state.dictation.dryRun = true
        state.hud.isSuppressed = true
        if let path = ProcessInfo.processInfo.environment["NABRA_ROBOT_AUDIO"],
           let samples = try? AudioFileIO.loadSamples(from: URL(fileURLWithPath: path)), !samples.isEmpty {
            state.recorder.simulatedInput = samples
        }
    }

    func run() {
        guard ProcessInfo.processInfo.environment["NABRA_SUPPORT_DIR"] != nil else {
            emit("refusing to run without NABRA_SUPPORT_DIR")
            finish()
            return
        }
        monitor.update(hotkey: .eitherOption, config: HotkeyGesture.Config())
        monitor.physicalProbe = { [weak self] _ in
            guard let self else { return false }
            self.keyLock.lock(); defer { self.keyLock.unlock() }
            return self.probeStuckDown || !self.keysDown.isEmpty
        }
        let forward = monitor.onAction
        monitor.onAction = { [weak self] action, keyDownAt in
            self?.actions.append((self?.now ?? 0, "\(action)"))
            forward?(action, keyDownAt)
        }
        scribeMonitor.update(hotkey: .rightCommand, config: HotkeyGesture.Config())
        scribeMonitor.physicalProbe = monitor.physicalProbe
        let forwardScribe = scribeMonitor.onAction
        scribeMonitor.onAction = { [weak self] action, keyDownAt in
            self?.actions.append((self?.now ?? 0, "scribe \(action)"))
            forwardScribe?(action, keyDownAt)
        }
        observeChanges(of: { [weak state] in state?.hud.model.mode }) { [weak self] mode in
            guard let self, let mode, self.hudModes.last != "\(mode)" else { return }
            self.hudModes.append("\(mode)")
        }
        state.dictation.onDryRunText = { [weak self] session, text in
            guard let self else { return }
            self.texts.append((self.now, session, text))
        }
        observeChanges(of: { [weak state] in state?.dictation.phase }) { [weak self] phase in
            guard let self, let phase else { return }
            self.phases.append((self.now, "\(phase)"))
        }
        emit("robot: input is \(state.recorder.simulatedInput == nil ? "the microphone" : "a recorded clip")")

        // Wait for the speech model and the microphone to be ready, then run the scenarios one by one.
        waitUntil(timeout: 30, { [state] in state.transcription.state == .ready && state.recorder.canStartEarly }) { [self] ready in
            emit("robot: model \(state.transcription.state), microphone prepared: \(state.recorder.canStartEarly)")
            guard ready || state.transcription.state == .ready else {
                emit("FAIL  setup: the speech model did not load")
                finish()
                return
            }
            runNext(scenarios())
        }
    }

    // MARK: - Scenarios

    private struct Scenario {
        var name: String
        /// Schedules key events; returns how long to wait before judging (seconds).
        var play: () -> Double
        var judge: () -> Void
    }

    private func scenarios() -> [Scenario] {
        let simulated = state.recorder.simulatedInput != nil
        var list: [Scenario] = []

        list.append(Scenario(name: "hold", play: { [self] in
            press(Robot.leftOption, at: 0)
            release(Robot.leftOption, at: 2.6)
            return 5.5
        }, judge: { [self] in
            expect(actionNames, ["arm", "start(handsFree: false)", "stop"], "left option: armed at key-down, started, stopped")
            expect(texts.count, simulated ? 1 : texts.count, "one dictation came out")
            if simulated { expect(texts.first?.text.isEmpty, false, "it has text") }
            expect(phaseNames.first, "listening", "phase went to listening")
            expect(phaseNames.last, "idle", "and back to idle")
            expect(state.recorder.isMicrophoneOpen, false, "microphone closed afterwards")
        }))

        if state.writer.isInstalled {
            list.append(Scenario(name: "scribe", play: { [self] in
                press(Robot.rightCommand, at: 0, on: scribeMonitor)
                release(Robot.rightCommand, at: 2.6, on: scribeMonitor)
                return 14
            }, judge: { [self] in
                expect(actionNames, ["scribe arm", "scribe start(handsFree: false)", "scribe stop"],
                       "the Scribe key opens the microphone at once, then starts and stops a dictation")
                expect(texts.count, simulated ? 1 : texts.count, "one text came out")
                if simulated { expect(texts.first?.text.isEmpty, false, "it has text") }
                expect(hudModes.contains("writing"), true, "the indicator opened up while writing")
                expect(phaseNames.last, "idle", "idle at the end")
            }))
        }

        list.append(Scenario(name: "right-hold", play: { [self] in
            press(Robot.rightOption, at: 0)
            release(Robot.rightOption, at: 2.6)
            return 5.5
        }, judge: { [self] in
            expect(actionNames, ["start(handsFree: false)", "stop"], "right option starts at once")
            expect(texts.count, simulated ? 1 : texts.count, "one dictation came out")
        }))

        list.append(Scenario(name: "after-idle", play: { [self] in
            // As after a long pause: the speech model has been released and must load while recording starts.
            state.transcription.unloadNow()
            press(Robot.rightOption, at: 0.6)
            release(Robot.rightOption, at: 3.2)
            return 7.0
        }, judge: { [self] in
            expect(actionNames, ["start(handsFree: false)", "stop"], "a press with the model unloaded starts at once")
            expect(texts.count, simulated ? 1 : texts.count, "and the dictation comes out once the model is back")
            expect(phaseNames.last, "idle", "idle at the end")
        }))

        list.append(Scenario(name: "shortcut", play: { [self] in
            press(Robot.leftOption, at: 0)
            otherKey(at: 0.08)
            release(Robot.leftOption, at: 0.25)
            return 1.2
        }, judge: { [self] in
            expect(actionNames, ["arm", "disarm"], "a shortcut opens the microphone and drops it again")
            expect(texts.count, 0, "nothing was dictated")
            expect(phaseNames, [], "the app never showed listening")
            expect(state.recorder.isMicrophoneOpen, false, "microphone closed after the shortcut")
        }))

        list.append(Scenario(name: "overlap", play: { [self] in
            press(Robot.leftOption, at: 0)
            release(Robot.leftOption, at: 2.6)
            // Pressed again while the first is still being transcribed.
            press(Robot.leftOption, at: 2.7)
            release(Robot.leftOption, at: 5.4)
            return 9.0
        }, judge: { [self] in
            expect(actionNames, ["arm", "start(handsFree: false)", "stop", "arm", "start(handsFree: false)", "stop"],
                   "second press accepted right after the first release")
            if simulated {
                expect(texts.count, 2, "both dictations came out")
                expect(texts.map(\.session) == texts.map(\.session).sorted(), true, "in the order they were spoken")
                expect(texts.allSatisfy { !$0.text.isEmpty }, true, "both have text")
                if texts.count == 2 {
                    expect(texts[1].at - texts[0].at >= 0.29, true, "two insertions are kept apart")
                }
            }
            expect(state.recorder.isMicrophoneOpen, false, "microphone closed afterwards")
        }))

        list.append(Scenario(name: "afterglow", play: { [self] in
            press(Robot.rightOption, at: 0)
            release(Robot.rightOption, at: 2.6)
            noteMicrophone("while-result-is-shown", at: 3.4)
            noteMicrophone("once-indicator-is-gone", at: 4.8)
            return 5.6
        }, judge: { [self] in
            guard simulated else { return }
            expect(microphoneOn["while-result-is-shown"], true, "the microphone stays open while the result is on the indicator")
            expect(microphoneOn["once-indicator-is-gone"], false, "and is closed once the indicator has gone")
        }))

        list.append(Scenario(name: "three-in-a-row", play: { [self] in
            for index in 0..<3 {
                let base = Double(index) * 2.3
                press(Robot.rightOption, at: base)
                release(Robot.rightOption, at: base + 2.2)
            }
            return 11.0
        }, judge: { [self] in
            if simulated {
                expect(texts.count, 3, "three dictations in quick succession all came out")
                expect(texts.map(\.session) == texts.map(\.session).sorted(), true, "in order")
            }
            expect(phaseNames.last, "idle", "idle at the end")
        }))

        list.append(Scenario(name: "cancel-does-not-hurt-previous", play: { [self] in
            press(Robot.leftOption, at: 0)
            release(Robot.leftOption, at: 2.6)
            // A new press right away, cancelled with Esc while the first is being transcribed.
            press(Robot.leftOption, at: 2.65)
            escape(at: 3.0)
            release(Robot.leftOption, at: 3.3)
            return 7.0
        }, judge: { [self] in
            if simulated {
                expect(texts.count, 1, "the first dictation survived the second one being cancelled")
                expect(texts.first?.text.isEmpty, false, "and has its text")
            }
            expect(actionNames.contains("cancel(Nabra.HotkeyGesture.CancelReason.escape)"), true, "escape cancelled the second")
            expect(state.recorder.isMicrophoneOpen, false, "microphone closed afterwards")
        }))

        list.append(Scenario(name: "stress", play: { [self] in
            // Forty presses with awkward timing: taps, short holds, shortcuts, both keys, overlaps.
            var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
            func random(_ range: ClosedRange<Double>) -> Double {
                seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                let unit = Double(seed >> 33) / Double(UInt64(1) << 31)
                return range.lowerBound + (range.upperBound - range.lowerBound) * unit
            }
            var time = 0.0
            for index in 0..<40 {
                let key = index % 3 == 0 ? Robot.rightOption : Robot.leftOption
                let held = index % 7 == 0 ? random(0.6...1.3) : random(0.02...0.4)
                press(key, at: time)
                if index % 5 == 2 { otherKey(at: time + min(held * 0.5, 0.2)) }
                if index % 11 == 5 { escape(at: time + held * 0.8) }
                release(key, at: time + held)
                time += held + random(0.02...0.3)
            }
            // One last tap ends a hands-free dictation, should the sequence have started one.
            press(Robot.leftOption, at: time + 1.0)
            release(Robot.leftOption, at: time + 1.06)
            return time + 8.0
        }, judge: { [self] in
            expect(phaseNames.last ?? "idle", "idle", "everything settled back to idle")
            expect(state.recorder.isMicrophoneOpen, false, "microphone closed after a burst of awkward presses")
            let starts = actionNames.filter { $0.hasPrefix("start") }.count
            let ends = actionNames.filter { $0 == "stop" || $0.hasPrefix("cancel") }.count
            expect(starts - ends <= 1, true, "every start was ended (a latched hands-free one may remain)")
        }))

        list.append(Scenario(name: "hands-free", play: { [self] in
            press(Robot.leftOption, at: 0)
            release(Robot.leftOption, at: 0.07)
            press(Robot.leftOption, at: 0.22)
            release(Robot.leftOption, at: 0.29)
            press(Robot.leftOption, at: 3.0)
            release(Robot.leftOption, at: 3.07)
            return 6.0
        }, judge: { [self] in
            expect(actionNames, ["arm", "disarm", "start(handsFree: true)", "latch", "stop"], "double-tap, then a tap to finish")
            expect(texts.count, simulated ? 1 : texts.count, "one dictation came out")
        }))

        list.append(Scenario(name: "missed-release", play: { [self] in
            press(Robot.rightOption, at: 0)
            // The key goes up, but the event never arrives.
            releaseSilently(Robot.rightOption, at: 2.0)
            return 6.0
        }, judge: { [self] in
            expect(actionNames, ["start(handsFree: false)", "stop"], "the keyboard check noticed the key was up and finished")
            expect(texts.count, simulated ? 1 : texts.count, "the dictation was not lost")
            expect(state.recorder.isMicrophoneOpen, false, "microphone closed afterwards")
        }))

        list.append(Scenario(name: "press-after-missed-release", play: { [self] in
            press(Robot.leftOption, at: 0)
            // Its release is lost and so is the keyboard check (as if the key state could not be read).
            forgetKey(Robot.leftOption, at: 0.4, keepProbeDown: true)
            press(Robot.leftOption, at: 2.2)
            release(Robot.leftOption, at: 4.6)
            return 8.0
        }, judge: { [self] in
            expect(actionNames, ["arm", "start(handsFree: false)", "stop", "arm", "start(handsFree: false)", "stop"],
                   "the next press ends the stuck dictation and starts a new one")
            expect(texts.count, simulated ? 2 : texts.count, "both came out")
        }))

        // With the microphone set to stay on (NABRA_STANDBY), check exactly that instead.
        if let standby = ProcessInfo.processInfo.environment["NABRA_STANDBY"] {
            list.removeAll()
            if standby == "always" {
                list.append(Scenario(name: "kept-open", play: { [self] in
                    noteMicrophone("before", at: 0.6)
                    press(Robot.rightOption, at: 1.0)
                    release(Robot.rightOption, at: 3.6)
                    press(Robot.leftOption, at: 5.0)
                    release(Robot.leftOption, at: 7.6)
                    return 10.5
                }, judge: { [self] in
                    expect(microphoneOn["before"], true, "the microphone is on before any key is pressed")
                    expect(texts.count, simulated ? 2 : texts.count, "both dictations came out")
                    expect(state.recorder.isMicrophoneOpen, true, "and it stays on afterwards")
                }))
            } else if let seconds = Double(standby) {
                list.append(Scenario(name: "linger", play: { [self] in
                    noteMicrophone("before", at: 0.3)
                    press(Robot.rightOption, at: 0.5)
                    release(Robot.rightOption, at: 3.1)
                    noteMicrophone("after-first", at: 4.1)
                    // A shortcut while it lingers must not extend the time it stays on.
                    press(Robot.leftOption, at: 4.3)
                    otherKey(at: 4.36)
                    release(Robot.leftOption, at: 4.5)
                    noteMicrophone("just-before-the-end", at: 3.1 + seconds - 0.4)
                    return 3.1 + seconds + 1.2
                }, judge: { [self] in
                    expect(microphoneOn["before"], false, "the microphone is off until the first dictation")
                    expect(microphoneOn["after-first"], true, "it stays on after a dictation")
                    expect(microphoneOn["just-before-the-end"], true, "for the whole of the chosen time")
                    expect(state.recorder.isMicrophoneOpen, false, "and is switched off once that time is over")
                }))
                list.append(Scenario(name: "linger-next-press", play: { [self] in
                    press(Robot.rightOption, at: 0.2)
                    release(Robot.rightOption, at: 2.8)
                    press(Robot.leftOption, at: 4.0)
                    release(Robot.leftOption, at: 6.6)
                    return 6.6 + seconds + 1.2
                }, judge: { [self] in
                    expect(texts.count, simulated ? 2 : texts.count, "both dictations came out")
                    expect(state.recorder.isMicrophoneOpen, false, "off again after the last one's time is over")
                }))
            }
        }

        if let only = ProcessInfo.processInfo.environment["NABRA_ROBOT_ONLY"] {
            let wanted = Set(only.split(separator: ",").map(String.init))
            list = list.filter { wanted.contains($0.name) }
        }
        let repeats = Int(ProcessInfo.processInfo.environment["NABRA_ROBOT_REPEAT"] ?? "1") ?? 1
        return (0..<max(1, repeats)).flatMap { _ in list }
    }

    private func runNext(_ remaining: [Scenario]) {
        guard let scenario = remaining.first else {
            emit(failures == 0 ? "PASS  \(checks) checks" : "FAILED \(failures) of \(checks) checks")
            finish()
            return
        }
        actions.removeAll()
        texts.removeAll()
        phases.removeAll()
        microphoneOn.removeAll()
        keyLock.lock()
        keysDown.removeAll()
        probeStuckDown = false
        keyLock.unlock()
        let origin = now
        emit("--- \(scenario.name)")
        script.removeAll()
        let wait = scenario.play()
        playScript()
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [self] in
            for entry in actions { emit(String(format: "    %6.3f  %@", entry.at - origin, entry.action)) }
            for entry in phases { emit(String(format: "    %6.3f  phase %@", entry.at - origin, entry.phase)) }
            for entry in texts { emit(String(format: "    %6.3f  text #%d: %@", entry.at - origin, entry.session, entry.text)) }
            scenario.judge()
            // A short breath so each scenario starts from rest.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [self] in runNext(Array(remaining.dropFirst())) }
        }
    }

    // MARK: - The pretend keyboard

    private func flags() -> CGEventFlags {
        keyLock.lock(); defer { keyLock.unlock() }
        var raw: UInt64 = 0
        if keysDown.contains(Robot.leftOption) { raw |= CGEventFlags.maskAlternate.rawValue | 0x20 }
        if keysDown.contains(Robot.rightOption) { raw |= CGEventFlags.maskAlternate.rawValue | 0x40 }
        if keysDown.contains(Robot.rightCommand) { raw |= CGEventFlags.maskCommand.rawValue | 0x10 }
        return CGEventFlags(rawValue: raw)
    }

    private func after(_ seconds: Double, _ work: @escaping () -> Void) {
        script.append((seconds, work))
    }

    /// Plays the collected events at their times, strictly in order, like a keyboard would.
    private func playScript() {
        let events = script.enumerated().sorted { ($0.element.at, $0.offset) < ($1.element.at, $1.offset) }.map(\.element)
        let began = Date()
        let thread = Thread {
            for event in events {
                let wait = event.at - Date().timeIntervalSince(began)
                if wait > 0 { Thread.sleep(forTimeInterval: wait) }
                event.work()
            }
        }
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    private func press(_ key: UInt16, at seconds: Double, on target: HotkeyMonitor? = nil) {
        after(seconds) { [self] in
            keyLock.lock(); keysDown.insert(key); keyLock.unlock()
            // Every monitor sees every key, as with the real event taps.
            monitor.inject(type: .flagsChanged, keyCode: key, flags: flags())
            scribeMonitor.inject(type: .flagsChanged, keyCode: key, flags: flags())
        }
    }

    private func release(_ key: UInt16, at seconds: Double, on target: HotkeyMonitor? = nil) {
        after(seconds) { [self] in
            keyLock.lock(); keysDown.remove(key); keyLock.unlock()
            monitor.inject(type: .flagsChanged, keyCode: key, flags: flags())
            scribeMonitor.inject(type: .flagsChanged, keyCode: key, flags: flags())
        }
    }

    /// The key goes up physically, but no event reaches the monitor.
    private func releaseSilently(_ key: UInt16, at seconds: Double) {
        after(seconds) { [self] in
            keyLock.lock(); keysDown.remove(key); keyLock.unlock()
        }
    }

    /// Makes the pretend keyboard forget a key without telling anyone. With `keepProbeDown` the
    /// keyboard check keeps answering "down", so only the next press can reveal the missed release.
    private func forgetKey(_ key: UInt16, at seconds: Double, keepProbeDown: Bool) {
        after(seconds) { [self] in
            keyLock.lock()
            if keepProbeDown {
                probeStuckDown = true
            } else {
                keysDown.remove(key)
            }
            keyLock.unlock()
        }
    }

    /// Records whether the microphone is on at this moment of the scenario.
    private func noteMicrophone(_ name: String, at seconds: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [self] in
            microphoneOn[name] = state.recorder.isMicrophoneOpen
        }
    }

    private func otherKey(at seconds: Double) {
        after(seconds) { [self] in
            monitor.inject(type: .keyDown, keyCode: UInt16(kVK_LeftArrow), flags: flags())
        }
    }

    private func escape(at seconds: Double) {
        after(seconds) { [self] in
            monitor.inject(type: .keyDown, keyCode: UInt16(kVK_Escape), flags: flags())
        }
    }

    // MARK: - Reporting

    private var now: Double { Double(Uptime.now - started) / 1_000_000_000 }
    private var actionNames: [String] { actions.map(\.action) }
    private var phaseNames: [String] { phases.map(\.phase) }

    private func expect<T: Equatable>(_ actual: T, _ expected: T, _ name: String) {
        checks += 1
        if actual == expected {
            emit("    ok    \(name)")
        } else {
            failures += 1
            emit("    FAIL  \(name)\n          expected: \(expected)\n          actual:   \(actual)")
        }
    }

    private func emit(_ line: String) {
        lines.append(line)
        guard let path = Robot.reportPath else { return }
        try? (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }

    private func waitUntil(timeout: Double, _ condition: @escaping () -> Bool, then: @escaping (Bool) -> Void) {
        let deadline = Date().addingTimeInterval(timeout)
        func poll() {
            if condition() {
                then(true)
            } else if Date() > deadline {
                then(false)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { poll() }
            }
        }
        poll()
    }

    private func finish() {
        emit("done")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }
    }
}
