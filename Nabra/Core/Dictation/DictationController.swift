import AppKit
import AVFoundation
import Observation

/// Runs dictations from key press to inserted text.
///
/// press → record (transcribing in the background) → release → tidy → insert → save.
///
/// Each press is its own `Session` with its own audio. The microphone opens the moment the key
/// goes down, before it is known whether the press is a dictation, and a new press is accepted
/// while the previous dictation is still being transcribed: recording starts at once and the
/// texts are inserted in the order they were spoken.
@Observable
final class DictationController {
    enum Phase: Equatable {
        case idle
        case listening
        case transcribing
        case polishing
    }

    private(set) var phase: Phase = .idle
    private(set) var isHandsFree = false
    /// The most recent result, for the menu bar and "paste last".
    private(set) var lastText: String?

    /// Called when something needs the user's attention in the main window (missing permission or model).
    @ObservationIgnored var onNeedsSetup: (() -> Void)?
    /// Called after text was inserted, so the correction watcher can start.
    @ObservationIgnored var onInserted: ((_ inserted: String, _ context: FocusSnapshot, _ transcriptID: Int64?) -> Void)?
    /// Called when a dictation ended without the key gesture knowing (errors, time limit), with the
    /// mode whose key should be told.
    @ObservationIgnored var onEndedExternally: ((DictationMode) -> Void)?
    /// The local language model behind Scribe. Nil until it is set up.
    @ObservationIgnored var writer: TextWriter?

    /// Test switches: recognise and log, but never touch the clipboard or other apps, and stay silent.
    @ObservationIgnored var dryRun = false
    @ObservationIgnored var onDryRunText: ((_ sessionID: Int, _ text: String) -> Void)?

    @ObservationIgnored private let settings: Settings
    @ObservationIgnored private let recorder: AudioRecorder
    @ObservationIgnored private let transcription: TranscriptionService
    @ObservationIgnored private let history: HistoryStore
    @ObservationIgnored private let dictionary: DictionaryStore
    @ObservationIgnored private let cleanup: SmartCleanup
    @ObservationIgnored private let hud: HUDController
    @ObservationIgnored private let inserter = TextInserter()
    @ObservationIgnored private let sounds = SoundEffects()

    /// One press of the dictation key, from open microphone to inserted text.
    private final class Session {
        let id: Int
        let mode: DictationMode
        let take: Take
        /// When the key went down (`Uptime`), or 0 when not started from the keyboard.
        let keyDownAt: UInt64
        /// False while the microphone is open only in case this press becomes a dictation.
        var committed = false
        var committedAt: UInt64 = 0
        var handsFree = false
        var live: LiveTranscription?
        var revealed = false
        var revealedAt: UInt64 = 0
        var cuePlayed = false
        var limitTimer: DispatchWorkItem?
        var armTimeout: DispatchWorkItem?

        // After release.
        /// How long the microphone stayed on after the key came up.
        var postRoll: TimeInterval = 0
        var contextBox: ContextBox?
        var contextRequestedAt: UInt64 = 0
        var isPolishing = false
        var outcome: Outcome?
        /// The finished recording, kept so a dictation that produced nothing can be tried again.
        var samples: [Float] = []
        /// A second attempt on the same audio: it decodes even what the voice detector called silence.
        var isRetry = false

        /// Scribe is writing this one's text.
        var isWriting = false
        var writtenSoFar = ""
        /// Shown instead of the tick once the text is in.
        var pendingNote: String?

        init(id: Int, mode: DictationMode = .dictate, take: Take, keyDownAt: UInt64) {
            self.id = id
            self.mode = mode
            self.take = take
            self.keyDownAt = keyDownAt
        }
    }

    private enum Outcome {
        case text(String, rawText: String, polished: Bool, result: TranscriptionResult, samples: [Float], latencyMs: Double)
        case nothing(recordedSeconds: Double)
        case failed(String)
    }

    /// The press being recorded (or only armed). At most one.
    @ObservationIgnored private var recording: Session?
    /// Released dictations waiting for their text, oldest first.
    @ObservationIgnored private var finishing: [Session] = []
    /// Live transcriptions of cancelled presses whose shutdown must wait (see `stopLive`).
    @ObservationIgnored private var deferredCancels: [LiveTranscription] = []
    @ObservationIgnored private var nextSessionID = 1
    @ObservationIgnored private var lastInsertAt: UInt64 = 0
    @ObservationIgnored private var pumpScheduled = false
    /// When the last result was confirmed on the indicator (`Uptime`).
    @ObservationIgnored private var resultShownAt: UInt64 = 0
    @ObservationIgnored private var microphoneRelease: DispatchWorkItem?
    @ObservationIgnored private var lastRawText: String?
    /// Presses that never became a dictation since the last log line (shortcuts, quick taps).
    @ObservationIgnored private var quietPresses = 0
    /// The audio of the last dictation that produced no text, and when it ended.
    @ObservationIgnored private var retryable: (samples: [Float], at: Date)?
    private static let retryWindow: TimeInterval = 600
    /// What the last dictation was in ("en" or "ar") and when, to tip an otherwise open language decision.
    @ObservationIgnored private var lastLanguage: (tag: String, at: Date)?
    private static let languageMemory: TimeInterval = 120

    private static let maximumSeconds: TimeInterval = 600
    /// A key that starts instantly waits this long (from key-down) before the indicator appears,
    /// so a quick tap does not flash it.
    private static let antiFlashDelay: TimeInterval = 0.10
    /// After the key comes up, the microphone stays on until the speaker has gone quiet, for at most
    /// this long: a third of the recordings in real use ended while the last word was still being said.
    private static let longestTail: TimeInterval = 0.5
    /// This much quiet in a row means the speaker has finished. A dictation whose last moments before
    /// the release were already quiet therefore finishes at once.
    private static let quietToFinish: TimeInterval = 0.2
    /// The AVAudioEngine path hands audio over in tenth-of-a-second blocks; the last one must have
    /// arrived before the end of the recording can be judged. (The fast path loses under 12 ms.)
    private static let bufferedAudioDelay: TimeInterval = 0.12
    /// How long the indicator stays up after a result (its tick, then fading out). The microphone is
    /// closed when the indicator is gone, so a press during that moment finds it still open.
    private static let indicatorAfterglow: TimeInterval = 0.9
    /// Two pastes are kept this far apart, so the first has landed before the clipboard changes again.
    private static let minimumInsertGap: TimeInterval = 0.3

    init(settings: Settings, recorder: AudioRecorder, transcription: TranscriptionService, history: HistoryStore,
         dictionary: DictionaryStore, cleanup: SmartCleanup, hud: HUDController) {
        self.settings = settings
        self.recorder = recorder
        self.transcription = transcription
        self.history = history
        self.dictionary = dictionary
        self.cleanup = cleanup
        self.hud = hud
        recorder.onSoundStarted = { [weak self] take in self?.soundStarted(take) }
        recorder.onFailure = { [weak self] take, error in self?.captureFailed(take, error) }
    }

    // MARK: - Input

    /// `keyDownAt` is when the key of this press went down (`Uptime`), 0 when unknown.
    func handle(_ action: HotkeyGesture.Action, keyDownAt: UInt64 = 0, mode: DictationMode = .dictate) {
        // Each key only ends what it started: Scribe's key never stops a dictation, or the other way round.
        switch action {
        case .arm, .start: break
        default: if let recording, recording.mode != mode { return }
        }
        switch action {
        case .arm: arm(keyDownAt: keyDownAt, mode: mode)
        case .disarm: disarm()
        case .start(let handsFree): start(handsFree: handsFree, keyDownAt: keyDownAt, mode: mode)
        case .latch:
            guard let session = recording, session.committed else { return }
            session.handsFree = true
            isHandsFree = true
            hud.setHandsFree(true)
        case .stop: release()
        case .cancel(let reason): cancel(reason)
        }
    }

    /// Menu bar and remote control: start if nothing is being recorded, finish if listening.
    func toggle() {
        if let session = recording {
            if session.committed { release() }
        } else {
            start(handsFree: true, keyDownAt: 0, mode: .dictate)
        }
    }

    // MARK: - Opening the microphone

    /// The key went down. Open the microphone now so nothing said is lost; show nothing yet.
    private func arm(keyDownAt: UInt64, mode: DictationMode) {
        guard recording == nil, recorder.canStartEarly,
              AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
              SpeechModel.bestInstalled(preferred: settings.modelID) != nil
        else { return }
        let session = makeSession(keyDownAt: keyDownAt, mode: mode)
        recording = session
        // The gesture always follows up within a fraction of a second. If it somehow does not, close the microphone.
        let timeout = DispatchWorkItem { [weak self, weak session] in
            guard let self, let session, self.recording === session, !session.committed else { return }
            Log.info("Press #\(session.id): no decision after key-down, microphone closed")
            self.recording = nil
            self.recorder.discard(session.take)
        }
        session.armTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: timeout)
    }

    /// The press was a shortcut or a quick tap: forget it.
    private func disarm() {
        guard let session = recording, !session.committed else { return }
        session.armTimeout?.cancel()
        recording = nil
        recorder.discard(session.take)
        quietPresses += 1
    }

    private func makeSession(keyDownAt: UInt64, mode: DictationMode) -> Session {
        let take = recorder.begin(deviceUID: settings.inputDeviceUID)
        let session = Session(id: nextSessionID, mode: mode, take: take, keyDownAt: keyDownAt)
        nextSessionID += 1
        return session
    }

    // MARK: - Begin

    private func start(handsFree: Bool, keyDownAt: UInt64, mode: DictationMode) {
        if let session = recording {
            guard !session.committed, session.mode == mode else {
                Log.info("Press ignored: dictation #\(session.id) is already listening")
                onEndedExternally?(mode)
                return
            }
            // The microphone has been open since the key went down: this press is that dictation.
            session.armTimeout?.cancel()
            guard readyToDictate(mode) else {
                recording = nil
                recorder.discard(session.take)
                return
            }
            commit(session, handsFree: handsFree)
            return
        }
        guard readyToDictate(mode) else { return }
        let session = makeSession(keyDownAt: keyDownAt, mode: mode)
        recording = session
        commit(session, handsFree: handsFree)
    }

    /// Checks what dictation needs. Explains on screen when something is missing.
    private func readyToDictate(_ mode: DictationMode = .dictate) -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
            Log.info("Press ignored: microphone permission has not been answered yet")
            onEndedExternally?(mode)
            return false
        default:
            refuse("Microphone access is off", mode)
            return false
        }
        guard SpeechModel.bestInstalled(preferred: settings.modelID) != nil else {
            refuse("Speech model not installed", mode)
            return false
        }
        return true
    }

    private func commit(_ session: Session, handsFree: Bool) {
        session.committed = true
        session.committedAt = Uptime.now
        session.handsFree = handsFree
        isHandsFree = handsFree
        refreshPhase()

        transcription.prepare(preferredModelID: settings.modelID)
        // Scribe's model loads while you talk.
        if session.mode == .scribe { writer?.prepare() }
        if settings.cleanupMode != .off, let rewriter = cleanup.rewriter {
            // Warming the system language model can take a moment; it must not hold up the indicator.
            DispatchQueue.global(qos: .userInitiated).async { rewriter.prepare() }
        }
        let language = LanguageChoice(mode: settings.languageMode, keyboardIsArabic: KeyboardLayout.currentInputIsArabic,
                                      ignoreBackgroundVoices: settings.ignoreBackgroundVoices,
                                      recentLanguage: recentLanguage())
        let live = transcription.startLive(recorder: session.take, language: language)
        if settings.showLiveText {
            live.onPartial = { [weak self, weak session] text in
                guard let self, let session, self.recording === session else { return }
                self.hud.setLiveText(text)
            }
        }
        session.live = live

        // A key that waited before committing has already filtered out quick taps: show the indicator
        // now. One that starts instantly waits a moment, so a tap does not flash it.
        let sinceKeyDown = session.keyDownAt == 0
            ? DictationController.antiFlashDelay
            : Uptime.milliseconds(from: session.keyDownAt, to: Uptime.now) / 1000
        let delay = DictationController.antiFlashDelay - sinceKeyDown
        if delay <= 0.002 {
            reveal(session)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak session] in
                guard let self, let session, self.recording === session else { return }
                self.reveal(session)
            }
        }

        let limit = DispatchWorkItem { [weak self, weak session] in
            guard let self, let session, self.recording === session else { return }
            Log.info("Dictation #\(session.id) reached the time limit")
            self.release()
            self.onEndedExternally?(session.mode)
        }
        session.limitTimer = limit
        DispatchQueue.main.asyncAfter(deadline: .now() + DictationController.maximumSeconds, execute: limit)
    }

    /// Shows the indicator. It only comes alive, and the start cue only plays, once the microphone
    /// is really being heard.
    private func reveal(_ session: Session) {
        session.revealed = true
        session.revealedAt = Uptime.now
        hud.showListening(handsFree: session.handsFree, meter: recorder.meter, live: session.take.hasSound)
        cueIfHearing(session)
    }

    private func soundStarted(_ take: Take) {
        guard let session = recording, session.take === take else { return }
        if session.revealed { hud.setLive(true) }
        cueIfHearing(session)
    }

    private func cueIfHearing(_ session: Session) {
        guard session.committed, session.revealed, session.take.hasSound, !session.cuePlayed else { return }
        session.cuePlayed = true
        playCue(.start)
        Log.info("Listening #\(session.id): \(DictationController.describeStart(of: session))")
    }

    /// "microphone opened 2 ms after key-down, hearing from 229 ms, shown at 161 ms (direct)".
    private static func describeStart(of session: Session) -> String {
        let timing = session.take.timing
        let origin = session.keyDownAt != 0 ? session.keyDownAt : session.take.requestedAt
        let after = session.keyDownAt != 0 ? "after key-down" : "after the request"
        func ms(_ time: UInt64) -> String { String(format: "%.0f ms", max(0, Uptime.milliseconds(from: origin, to: time))) }
        var parts: [String] = []
        if timing.backend.hasSuffix("already open") {
            parts.append(timing.prefilled > 0
                ? String(format: "microphone was open, includes %.0f ms from before the key",
                         Double(timing.prefilled) / Double(SpeechEngine.sampleRate) * 1000)
                : "microphone was already open")
        } else {
            parts.append("microphone opened \(ms(timing.captureStarted)) \(after)")
            if timing.firstSample != 0 { parts.append("first audio at \(ms(timing.firstSample))") }
            if timing.stillSilent {
                parts.append("no sound in its first 0.4 s")
            } else if timing.soundStarted != 0 {
                parts.append("hearing from \(ms(timing.soundStarted))")
            }
        }
        parts.append("shown at \(ms(session.revealedAt))")
        return parts.joined(separator: ", ") + " (\(timing.backend))"
    }

    // MARK: - Finish

    private func release() {
        guard let session = recording, session.committed else { return }
        recording = nil
        session.limitTimer?.cancel()
        finishing.append(session)
        refreshPhase()

        // Read the focused field while the recording winds down and is transcribed.
        let contextBox = ContextBox()
        session.contextBox = contextBox
        session.contextRequestedAt = Uptime.now
        Accessibility.queue.async {
            contextBox.set(Accessibility.snapshot(readText: true))
        }

        // Keep listening until the last word is finished. The indicator keeps showing the waveform
        // meanwhile, and the stop sound plays when the microphone really stops for this dictation:
        // played earlier, it would be recorded, and would sound like the end while it was not.
        let releasedAt = Uptime.now
        let earliestJudgement = recorder.deliversPromptly ? 0 : DictationController.bufferedAudioDelay
        func waitForQuiet() {
            let elapsed = Uptime.milliseconds(from: releasedAt, to: Uptime.now) / 1000
            // A new press takes the microphone over, which ends this recording where it is. Typing
            // (Enter to send, say) means the speaker has moved on.
            let done = session.take.isSealed || elapsed >= DictationController.longestTail
                || DictationController.keyPressed(withinLast: elapsed)
                || (elapsed >= earliestJudgement && speakerHasGoneQuiet())
            guard done else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { waitForQuiet() }
                return
            }
            session.postRoll = elapsed
            if elapsed >= 0.05 {
                Log.info(String(format: "Dictation #%d: kept listening %.2f s after the key came up%@", session.id, elapsed,
                                session.take.isSealed ? " (a new press took over)"
                                    : elapsed >= DictationController.longestTail ? " (the longest it waits)" : ""))
            }
            if !(recording?.committed ?? false) {
                hud.showProcessing(polishing: false)
                playCue(.stop)
            }
            conclude(session)
        }
        waitForQuiet()
    }

    /// Stops recording `session` and has its text worked out.
    private func conclude(_ session: Session) {
        recorder.finish(session.take) { [weak self] samples in
            guard let self, let live = session.live else { return }
            let recordedSeconds = Double(samples.count) / Double(SpeechEngine.sampleRate)
            live.finish(samples: samples) { [weak self] result in
                self?.transcribed(session, result: result, samples: samples, recordedSeconds: recordedSeconds)
            }
        }
    }

    /// True when the most recent `quietToFinish` of the recording is quiet. "Quiet" is judged against
    /// this recording's own background level, within limits, so that neither a silent room nor a
    /// noisy one fools it; in a room too loud to tell, the recording simply runs its full tail.
    private func speakerHasGoneQuiet() -> Bool {
        let meter = recorder.meter
        let count = meter.sliceCount
        let needed = Int((DictationController.quietToFinish * LevelMeter.slicesPerSecond).rounded())
        return DictationController.endsQuietly(meter.levels(endingAt: count, count: min(max(count, needed), 500)),
                                               recent: needed)
    }

    /// Whether the newest `recent` values of `levels` (level-meter scale, 20 ms each, oldest first)
    /// are quiet. A click (a key, a tap on the desk) is one or two loud slices; a spoken sound lasts
    /// longer, so only three loud slices in a row, or a loud newest slice, count as still speaking.
    static func endsQuietly(_ levels: [Float], recent: Int) -> Bool {
        guard recent > 0 else { return true }
        // The background is what the pauses between words sound like: a low percentile of the whole
        // recording (low enough that a recording which is nearly all speech still finds its pauses).
        let sorted = levels.sorted()
        let background = sorted.isEmpty ? 0 : sorted[sorted.count / 10]
        // The meter maps -52…-12 dBFS to 0…1: 0.25 is about -42 dBFS, 0.35 about -38 dBFS.
        let threshold = min(0.35, max(0.25, background + 0.12))
        let window = levels.suffix(recent)
        if let newest = window.last, newest >= threshold { return false }
        var run = 0
        for level in window {
            run = level >= threshold ? run + 1 : 0
            if run >= 3 { return false }
        }
        return true
    }

    /// True when a key was pressed on the keyboard in the last `seconds`. Reads the hardware event
    /// state, so text Nabra itself pastes does not count.
    private static func keyPressed(withinLast seconds: TimeInterval) -> Bool {
        CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .keyDown) < seconds
    }

    private func transcribed(_ session: Session, result: TranscriptionResult, samples: [Float], recordedSeconds: Double) {
        session.live = nil
        session.samples = samples
        transcription.scheduleUnload(afterMinutes: settings.modelIdleMinutes)
        flushDeferredCancels()

        if result.failed {
            session.outcome = .failed("Couldn't transcribe that")
            pump()
            return
        }
        let processed = TextPipeline.process(result.text, options: pipelineOptions())
        guard !result.noSpeech, !processed.text.isEmpty else {
            session.outcome = .nothing(recordedSeconds: recordedSeconds)
            pump()
            return
        }

        let latency = result.latencyMs + session.postRoll * 1000
        let rawText = result.text
        if session.mode == .scribe {
            scribe(session, transcript: processed.text, rawText: rawText, result: result, samples: samples, latencyMs: latency)
            return
        }
        if cleanup.shouldPolish(processed.text, mode: settings.cleanupMode) {
            session.isPolishing = true
            refreshPhase()
            refreshIndicator()
            let started = Date()
            cleanup.polish(processed.text, vocabulary: dictionary.phrases) { [weak self] polished in
                guard let self else { return }
                let extra = Date().timeIntervalSince(started) * 1000
                session.isPolishing = false
                session.outcome = .text(polished ?? processed.text, rawText: rawText, polished: polished != nil,
                                        result: result, samples: samples, latencyMs: latency + extra)
                self.pump()
            }
        } else {
            session.outcome = .text(processed.text, rawText: rawText, polished: false, result: result, samples: samples,
                                    latencyMs: latency)
            pump()
        }
    }

    /// Delivers finished dictations strictly in the order they were spoken.
    private func pump() {
        while let head = finishing.first, let outcome = head.outcome {
            if case .text = outcome {
                let sinceLast = lastInsertAt == 0 ? 10 : Uptime.milliseconds(from: lastInsertAt, to: Uptime.now) / 1000
                let wait = DictationController.minimumInsertGap - sinceLast
                if wait > 0 {
                    if !pumpScheduled {
                        pumpScheduled = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
                            self?.pumpScheduled = false
                            self?.pump()
                        }
                    }
                    break
                }
            }
            finishing.removeFirst()
            deliver(head, outcome)
        }
        refreshPhase()
        refreshIndicator()
    }

    /// True when the indicator belongs to a dictation in progress and must not be replaced by the
    /// result of an earlier one.
    private var indicatorIsBusy: Bool {
        if let recording, recording.committed { return true }
        return !finishing.isEmpty
    }

    /// While earlier dictations are still being worked on and nothing is recording, show that.
    private func refreshIndicator() {
        if let recording, recording.committed { return }
        guard let head = finishing.first else { return }
        if head.isWriting {
            if hud.model.mode != .writing { hud.showWriting() }
            hud.setWritingText(head.writtenSoFar)
        } else {
            hud.showProcessing(polishing: head.isPolishing)
        }
    }

    private func deliver(_ session: Session, _ outcome: Outcome) {
        switch outcome {
        case .failed(let message):
            Log.error("Dictation #\(session.id) failed: \(message)")
            keepForRetry(session)
            guard !indicatorIsBusy else { return }
            hud.showNotice(message, symbol: "exclamationmark.triangle.fill", isError: true, action: retryAction(session))
            playCue(.error)

        case .nothing(let recordedSeconds):
            let silent = session.take.isDigitalSilence
            Log.info(String(format: "Dictation #%d: nothing recognised in %.1f s of audio%@%@", session.id, recordedSeconds,
                            silent ? ": the microphone sent only silence (is it muted, or the lid closed?)" : "",
                            session.take.hasSound ? "" : " [" + DictationController.describeStart(of: session) + "]"))
            if !silent { keepForRetry(session) }
            guard !indicatorIsBusy else { return }
            if silent, recordedSeconds > 0.5 {
                // Not "didn't catch that": nothing could have been caught.
                hud.showNotice("Microphone is silent", symbol: "mic.slash.fill", isError: true)
                playCue(.error)
            } else if recordedSeconds > 1.0 {
                hud.showNotice(session.isRetry ? "Still nothing there" : "Didn't catch that", symbol: "waveform.slash",
                               isError: false, action: retryAction(session))
            } else {
                hud.hide()
            }

        case .text(let text, let rawText, let polished, let result, let samples, let latencyMs):
            complete(session, text: text, rawText: rawText, polished: polished, result: result, samples: samples,
                     latencyMs: latencyMs)
        }
    }

    private func complete(_ session: Session, text: String, rawText: String, polished: Bool, result: TranscriptionResult,
                          samples: [Float], latencyMs: Double) {
        lastText = text
        lastRawText = rawText
        if result.language == "en" || result.language == "ar" { lastLanguage = (result.language, Date()) }

        var context = session.contextBox?.wait(upTo: 0.3) ?? FocusSnapshot()
        if lastInsertAt > session.contextRequestedAt {
            // An earlier dictation was inserted after this field was read: read it again so spacing is right.
            let fresh = ContextBox()
            Accessibility.queue.async { fresh.set(Accessibility.snapshot(readText: true)) }
            context = fresh.wait(upTo: 0.3)
        }

        var inserted = false
        var insertedText = text
        var note: String?
        if dryRun {
            lastInsertAt = Uptime.now
            onDryRunText?(session.id, text)
        } else if context.isSecureField {
            note = "Password field: not inserted"
        } else if !Accessibility.isTrusted {
            inserter.copy(text)
            note = "Copied. Allow Accessibility to insert"
            onNeedsSetup?()
        } else if InsertionCheck.cannotTakeText(context) {
            // Nothing that takes text has the focus (the desktop, a list, a page with no text box
            // selected): a paste would go nowhere, so the text waits on the clipboard instead.
            inserter.copy(text)
            note = InsertionCheck.copiedNote
            Log.info("Dictation #\(session.id): no text field has the focus (\(context.role ?? "nothing focused") in "
                + "\(context.appName ?? "?")); copied to the clipboard")
        } else {
            let formatted = InsertionFormatter.format(text, context: context, enabled: settings.smartSpacing)
            insertedText = formatted.trimmingCharacters(in: .whitespaces)
            inserted = inserter.insert(formatted, method: settings.insertionMethod, restoreClipboard: settings.restoreClipboard)
            if inserted {
                lastInsertAt = Uptime.now
                confirmLanding(of: text, before: context, sessionID: session.id)
            } else {
                inserter.copy(text)
                note = "Copied to clipboard"
            }
        }

        var transcriptID: Int64?
        if settings.saveHistory {
            let audioFile = saveAudio(samples)
            transcriptID = history.add(text: text, rawText: rawText, language: result.language,
                                       duration: result.speechSeconds > 0 ? result.speechSeconds : result.audioSeconds,
                                       appName: context.appName, appBundleID: context.bundleID, audioFile: audioFile,
                                       processingMs: latencyMs, polished: polished)?.id
        }
        Log.info(String(format: "Dictation done: %.1fs audio, text after %.0f ms%@, %d chars, lang %@ (#%d%@), into %@%@",
                        result.audioSeconds, latencyMs, result.wasReadyEarly ? " (ready early)" : "",
                        text.count, result.language, session.id, session.isRetry ? ", second try" : "",
                        context.role ?? "?", quietPressNote()))
        for note in result.languageNotes { Log.info("  language: \(note)") }

        // A dictation that went all the way through proves setup is done.
        if inserted, !settings.onboardingCompleted { settings.onboardingCompleted = true }
        // Hand over exactly what landed in the field, so later corrections can be found there.
        // Scribe's text is the model's wording, so editing it says nothing about what was heard.
        if inserted, session.mode == .dictate { onInserted?(insertedText, context, transcriptID) }

        // The indicator shows the newest dictation; an older one finishing must not disturb it.
        guard !indicatorIsBusy else { return }
        resultShownAt = Uptime.now
        if let note {
            hud.showNotice(note, symbol: "doc.on.clipboard", isError: false)
        } else if let pending = session.pendingNote {
            hud.showNotice(pending, symbol: "sparkles", isError: false)
        } else {
            hud.showSuccess()
        }
    }

    // MARK: - Scribe

    /// Hands the transcript to the writing model and streams what it writes into the indicator.
    private func scribe(_ session: Session, transcript: String, rawText: String, result: TranscriptionResult,
                        samples: [Float], latencyMs: Double) {
        guard let writer, writer.isInstalled else {
            // No model yet: the words still go in, as a normal dictation.
            session.pendingNote = "Scribe needs its model: see Settings"
            session.outcome = .text(transcript, rawText: rawText, polished: false, result: result, samples: samples,
                                    latencyMs: latencyMs)
            onNeedsSetup?()
            pump()
            return
        }
        var request = WritingRequest(transcript: transcript)
        let context = session.contextBox?.wait(upTo: 0.2)
        request.bundleID = context?.bundleID
        let job = ScribeRouter.job(for: transcript, bundleID: context?.bundleID)
        if settings.scribeUsesContext, let context {
            request.appName = context.appName
            if let value = context.value as NSString?, let selection = context.selection, selection.location <= value.length {
                let start = max(0, selection.location - 800)
                request.textBefore = value.substring(with: NSRange(location: start, length: selection.location - start))
            }
        }
        session.isWriting = true
        refreshIndicator()
        let started = Date()
        var firstTextAt: Date?
        writer.write(request, job: job, onText: { [weak self] text in
            guard let self else { return }
            if firstTextAt == nil { firstTextAt = Date() }
            session.writtenSoFar = text
            if self.recording?.committed != true, self.finishing.first === session { self.hud.setWritingText(text) }
        }, completion: { [weak self] written in
            guard let self else { return }
            session.isWriting = false
            let ms = Date().timeIntervalSince(started) * 1000
            var text = written?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let what: String
            switch job {
            case .compose(let rule):
                what = "composed (\(rule))"
                text = ScribeRouter.tidyComposed(text)
            case .polish:
                what = "polished"
                // Anything that drifts from what was said goes in as said.
                if !text.isEmpty, let problem = ScribeRouter.problem(polished: text, from: transcript) {
                    Log.info("Scribe #\(session.id): kept the words as said, the rewrite \(problem)")
                    session.pendingNote = "Kept as said"
                    text = ""
                }
            }
            if text.isEmpty {
                if session.pendingNote == nil {
                    Log.error(String(format: "Scribe #%d: the model wrote nothing (%.0f ms); inserting the dictation", session.id, ms))
                    session.pendingNote = "Scribe could not write this: inserted as said"
                }
            } else {
                Log.info(String(format: "Scribe #%d: %@, %d chars from %d, first text after %.0f ms, done after %.0f ms",
                                session.id, what, text.count, transcript.count,
                                (firstTextAt ?? Date()).timeIntervalSince(started) * 1000, ms))
            }
            session.outcome = .text(text.isEmpty ? transcript : text, rawText: rawText, polished: !text.isEmpty,
                                    result: result, samples: samples, latencyMs: latencyMs + ms)
            self.pump()
        })
    }

    // MARK: - Trying again

    /// Whether there is a recording that produced nothing and can be transcribed again.
    var canRetry: Bool {
        guard let retryable else { return false }
        return Date().timeIntervalSince(retryable.at) < DictationController.retryWindow
    }

    private func keepForRetry(_ session: Session) {
        guard session.samples.count > SpeechEngine.sampleRate / 2 else { return }
        retryable = (session.samples, Date())
    }

    private func retryAction(_ session: Session) -> (title: String, run: () -> Void)? {
        guard !session.isRetry, canRetry else { return nil }
        return ("Try again", { [weak self] in self?.retryLast() })
    }

    /// Transcribes the last recording that produced nothing once more, from exactly the same audio,
    /// and inserts the result where the cursor is now. This time even audio the voice detector
    /// took for silence is decoded.
    func retryLast() {
        guard canRetry, let retryable, recording == nil else { return }
        self.retryable = nil
        let session = Session(id: nextSessionID, take: Take(id: 0), keyDownAt: 0)
        nextSessionID += 1
        session.isRetry = true
        session.samples = retryable.samples
        let contextBox = ContextBox()
        session.contextBox = contextBox
        session.contextRequestedAt = Uptime.now
        Accessibility.queue.async { contextBox.set(Accessibility.snapshot(readText: true)) }
        finishing.append(session)
        refreshPhase()
        hud.showProcessing(polishing: false)
        Log.info("Dictation #\(session.id): trying the last recording again")

        let language = LanguageChoice(mode: settings.languageMode, keyboardIsArabic: KeyboardLayout.currentInputIsArabic,
                                      ignoreBackgroundVoices: settings.ignoreBackgroundVoices,
                                      recentLanguage: recentLanguage())
        let samples = retryable.samples
        transcription.transcribe(samples: samples, language: language, preferredModelID: settings.modelID,
                                 requireSpeech: false) { [weak self] result in
            self?.transcribed(session, result: result, samples: samples,
                              recordedSeconds: Double(samples.count) / Double(SpeechEngine.sampleRate))
        }
    }

    // MARK: - Checking that text landed

    /// Looks at the field again shortly after pasting. If the text clearly did not arrive (nothing
    /// took it, or the field's text is unchanged), it is put on the clipboard so it is not lost.
    private func confirmLanding(of text: String, before: FocusSnapshot, sessionID: Int) {
        guard !dryRun else { return }
        let started = Uptime.now
        func check(attempt: Int) {
            let delay: TimeInterval = attempt == 0 ? 0.3 : 0.5
            Accessibility.queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                let after = Accessibility.snapshot(readText: true)
                let verdict = InsertionCheck.judge(before: before, after: after)
                DispatchQueue.main.async {
                    guard let self else { return }
                    switch verdict {
                    case .landed, .unknown:
                        return
                    case .unchanged where attempt == 0:
                        // Some apps take a moment to show pasted text: look once more.
                        check(attempt: 1)
                    case .unchanged, .missed:
                        // Something newer may have been put on the clipboard or pasted meanwhile.
                        guard self.lastInsertAt <= started else { return }
                        self.inserter.copy(text)
                        Log.info("Dictation #\(sessionID): the text did not arrive (\(verdict == .missed ? "no text field" : "field unchanged")"
                            + " in \(after.appName ?? "?")); copied to the clipboard")
                        guard !self.indicatorIsBusy else { return }
                        self.hud.showNotice(InsertionCheck.copiedNote, symbol: "doc.on.clipboard", isError: false)
                    }
                }
            }
        }
        check(attempt: 0)
    }

    /// The language of the previous dictation, while it is recent enough to say something about this one.
    private func recentLanguage() -> String? {
        guard let last = lastLanguage, Date().timeIntervalSince(last.at) < DictationController.languageMemory else { return nil }
        return last.tag
    }

    /// " · 3 other presses were shortcuts or taps" for the log, then resets the count.
    private func quietPressNote() -> String {
        guard quietPresses > 0 else { return "" }
        defer { quietPresses = 0 }
        return quietPresses == 1 ? ", 1 other press was a shortcut or tap" : ", \(quietPresses) other presses were shortcuts or taps"
    }

    // MARK: - Cancel and errors

    private func cancel(_ reason: HotkeyGesture.CancelReason) {
        guard let session = recording else { return }
        recording = nil
        session.limitTimer?.cancel()
        session.armTimeout?.cancel()
        recorder.discard(session.take)
        guard session.committed else {
            quietPresses += 1
            return
        }
        stopLive(session)
        if session.revealed {
            let held = Uptime.milliseconds(from: session.keyDownAt != 0 ? session.keyDownAt : session.committedAt, to: Uptime.now)
            let why: String
            switch reason {
            case .escape: why = "Esc"
            case .shortcut: why = "another key or a click arrived, so the press was a shortcut"
            case .tooShort: why = "released too quickly"
            }
            Log.info(String(format: "Dictation #%d cancelled after %.0f ms: %@", session.id, held, why))
        } else {
            quietPresses += 1
        }
        refreshPhase()
        if finishing.isEmpty {
            hud.hide()
        } else {
            refreshIndicator()
        }
        transcription.scheduleUnload(afterMinutes: settings.modelIdleMinutes)
    }

    /// Ends the background transcription of a press that was abandoned.
    private func stopLive(_ session: Session) {
        guard let live = session.live else { return }
        session.live = nil
        // Cancelling interrupts whatever the recogniser is decoding. If that is an earlier dictation
        // still being transcribed, wait until it is done.
        if finishing.contains(where: { $0.outcome == nil && !$0.isPolishing }) {
            deferredCancels.append(live)
        } else {
            live.cancel()
        }
    }

    private func flushDeferredCancels() {
        guard !deferredCancels.isEmpty,
              !finishing.contains(where: { $0.live != nil && $0.outcome == nil })
        else { return }
        deferredCancels.forEach { $0.cancel() }
        deferredCancels.removeAll()
    }

    /// Something prevented dictation from starting.
    private func refuse(_ message: String, _ mode: DictationMode = .dictate) {
        Log.info("Press ignored: \(message)")
        hud.showNotice(message, symbol: "exclamationmark.triangle.fill", isError: true)
        playCue(.error)
        onNeedsSetup?()
        onEndedExternally?(mode)
    }

    /// The microphone could not be opened, or went silent for good.
    private func captureFailed(_ take: Take, _ error: Error) {
        guard let session = recording, session.take === take else { return }
        recording = nil
        session.limitTimer?.cancel()
        session.armTimeout?.cancel()
        // A press that was only armed fails quietly: if it becomes a dictation, that tries again and reports.
        guard session.committed else { return }
        stopLive(session)
        refreshPhase()
        hud.showNotice(error.localizedDescription, symbol: "exclamationmark.triangle.fill", isError: true)
        playCue(.error)
        Log.error("Dictation #\(session.id) failed: \(error.localizedDescription)")
        onEndedExternally?(session.mode)
    }

    private func refreshPhase() {
        let current: Phase
        if let recording, recording.committed {
            current = .listening
        } else if let head = finishing.first {
            current = head.isPolishing ? .polishing : .transcribing
        } else {
            current = .idle
        }
        if current != phase { phase = current }

        // The microphone is not closed while a dictation is still being turned into text, nor while its
        // result is still shown on the indicator: a press that comes in that moment starts with the
        // microphone already hearing, instead of waiting for it to start up again.
        microphoneRelease?.cancel()
        microphoneRelease = nil
        if !finishing.isEmpty {
            recorder.keepOpenWhileBusy(true)
            return
        }
        let sinceResult = resultShownAt == 0 ? 10 : Uptime.milliseconds(from: resultShownAt, to: Uptime.now) / 1000
        let afterglow = DictationController.indicatorAfterglow - sinceResult
        guard afterglow > 0, recording == nil else {
            recorder.keepOpenWhileBusy(false)
            return
        }
        let release = DispatchWorkItem { [weak self] in
            guard let self, self.finishing.isEmpty else { return }
            self.recorder.keepOpenWhileBusy(false)
        }
        microphoneRelease = release
        DispatchQueue.main.asyncAfter(deadline: .now() + afterglow, execute: release)
    }

    // MARK: - Helpers

    private func playCue(_ cue: SoundEffects.Cue) {
        guard settings.playSounds, !dryRun else { return }
        sounds.play(cue, volume: settings.soundVolume)
    }

    /// Plays the start cue at the current volume, for the settings slider.
    func previewSound() {
        sounds.play(.start, volume: settings.soundVolume)
    }

    /// Inserts the previous result again.
    func pasteLast() {
        guard let lastText else { return }
        inserter.insert(lastText, method: .paste, restoreClipboard: settings.restoreClipboard)
    }

    func copyLast() {
        guard let lastText else { return }
        inserter.copy(lastText)
    }

    private func pipelineOptions() -> TextPipeline.Options {
        var options = TextPipeline.Options()
        options.removeFillers = settings.removeFillers
        options.voiceCommands = settings.voiceCommands
        options.formatLists = settings.formatLists
        options.paragraphs = settings.formatParagraphs
        options.replacements = dictionary.replacements.compactMap { entry in
            entry.heard.map { (heard: $0, phrase: entry.phrase) }
        }
        options.vocabulary = dictionary.phrases
        options.isRealWord = SpellingOracle.isRealWord
        return options
    }

    private func saveAudio(_ samples: [Float]) -> String? {
        guard settings.audioRetention != .never, samples.count > SpeechEngine.sampleRate / 4 else { return nil }
        let name = UUID().uuidString + ".m4a"
        let url = AppPaths.audioDirectory.appendingPathComponent(name)
        DispatchQueue.global(qos: .utility).async {
            do {
                try AudioFileIO.writeCompressed(samples, to: url)
            } catch {
                Log.error("Could not save audio: \(error.localizedDescription)")
            }
        }
        return name
    }
}

/// Hands a value from a background queue to the main thread, with a bounded wait.
private final class ContextBox {
    private let lock = NSLock()
    private let ready = DispatchSemaphore(value: 0)
    private var value = FocusSnapshot()

    func set(_ newValue: FocusSnapshot) {
        lock.lock()
        value = newValue
        lock.unlock()
        ready.signal()
    }

    func wait(upTo seconds: TimeInterval) -> FocusSnapshot {
        _ = ready.wait(timeout: .now() + seconds)
        lock.lock(); defer { lock.unlock() }
        return value
    }
}

/// Answers "is this an ordinary dictionary word?" using the system spell checker. Main thread only.
enum SpellingOracle {
    private static var cache: [String: Bool] = [:]

    static func isRealWord(_ word: String) -> Bool {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(" ") else { return false }
        if let cached = cache[trimmed] { return cached }
        let checker = NSSpellChecker.shared
        let language = TextScript.containsArabic(trimmed) ? "ar" : "en"
        let range = checker.checkSpelling(of: trimmed.lowercased(), startingAt: 0, language: language, wrap: false,
                                          inSpellDocumentWithTag: 0, wordCount: nil)
        let known = range.location == NSNotFound
        cache[trimmed] = known
        return known
    }
}

/// Decides whether the focused element can take text, before and after pasting.
enum InsertionCheck {
    enum Verdict: Equatable {
        case landed
        /// Nothing that takes text has the focus.
        case missed
        /// A readable text field kept exactly the text it had.
        case unchanged
        /// Cannot be told (an editor that does not expose its text): assume it worked.
        case unknown
    }

    static let copiedNote = "Copied. Press ⌘V to paste"

    /// Roles that are certainly not somewhere to type.
    private static let nonTextRoles: Set<String> = [
        "AXWindow", "AXScrollArea", "AXList", "AXOutline", "AXTable", "AXBrowser", "AXButton", "AXImage", "AXStaticText",
        "AXRow", "AXCell", "AXMenu", "AXMenuItem", "AXMenuBar", "AXMenuBarItem", "AXCheckBox", "AXRadioButton", "AXSlider",
        "AXSplitGroup", "AXToolbar", "AXTabGroup", "AXGrid", "AXLink", "AXPopUpButton", "AXDisclosureTriangle", "AXSheet",
        "AXDrawer", "AXApplication", "AXDockItem", "AXLevelIndicator", "AXProgressIndicator", "AXColorWell",
    ]

    /// True when the focused element is known not to take typing. An app that reports no focused
    /// element at all is not judged here: Chromium-based apps report nothing until asked once.
    static func cannotTakeText(_ snapshot: FocusSnapshot) -> Bool {
        guard snapshot.element != nil, let role = snapshot.role else { return false }
        if nonTextRoles.contains(role) { return snapshot.selection == nil }
        // A web page that has the focus itself, with no text box in it selected.
        return role == "AXWebArea" && snapshot.selection == nil && snapshot.value == nil
    }

    static func judge(before: FocusSnapshot, after: FocusSnapshot) -> Verdict {
        guard let element = after.element else { return .missed }
        if cannotTakeText(after) { return .missed }
        if let beforeValue = before.value, let afterValue = after.value, let beforeElement = before.element,
           CFEqual(beforeElement, element) {
            return beforeValue == afterValue ? .unchanged : .landed
        }
        return .unknown
    }
}
