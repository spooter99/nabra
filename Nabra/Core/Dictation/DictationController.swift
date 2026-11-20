import AppKit
import AVFoundation
import Observation

/// Runs one dictation from key press to inserted text.
///
/// press → record (transcribing in the background) → release → tidy → insert → save.
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
    /// Called when a dictation ended without the key gesture knowing (errors, time limit).
    @ObservationIgnored var onEndedExternally: (() -> Void)?

    @ObservationIgnored private let settings: Settings
    @ObservationIgnored private let recorder: AudioRecorder
    @ObservationIgnored private let transcription: TranscriptionService
    @ObservationIgnored private let history: HistoryStore
    @ObservationIgnored private let dictionary: DictionaryStore
    @ObservationIgnored private let cleanup: SmartCleanup
    @ObservationIgnored private let hud: HUDController
    @ObservationIgnored private let inserter = TextInserter()
    @ObservationIgnored private let sounds = SoundEffects()

    @ObservationIgnored private var live: LiveTranscription?
    @ObservationIgnored private var session = 0
    @ObservationIgnored private var startedAt: TimeInterval = 0
    @ObservationIgnored private var limitTimer: DispatchWorkItem?
    @ObservationIgnored private var lastRawText: String?

    private static let maximumSeconds: TimeInterval = 600
    private static let revealDelay: TimeInterval = 0.10

    init(settings: Settings, recorder: AudioRecorder, transcription: TranscriptionService, history: HistoryStore,
         dictionary: DictionaryStore, cleanup: SmartCleanup, hud: HUDController) {
        self.settings = settings
        self.recorder = recorder
        self.transcription = transcription
        self.history = history
        self.dictionary = dictionary
        self.cleanup = cleanup
        self.hud = hud
    }

    // MARK: - Input

    func handle(_ action: HotkeyGesture.Action) {
        switch action {
        case .start(let handsFree): begin(handsFree: handsFree)
        case .latch:
            guard phase == .listening else { return }
            isHandsFree = true
            hud.setHandsFree(true)
        case .stop: finish()
        case .cancel(let reason): cancel(silently: reason != .escape)
        }
    }

    /// Menu bar and remote control: start if idle, finish if listening.
    func toggle() {
        switch phase {
        case .idle: begin(handsFree: true)
        case .listening: finish()
        default: break
        }
    }

    // MARK: - Begin

    private func begin(handsFree: Bool) {
        guard phase == .idle else {
            onEndedExternally?()
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
            onEndedExternally?()
            return
        default:
            refuse("Microphone access is off")
            return
        }
        guard SpeechModel.bestInstalled(preferred: settings.modelID) != nil else {
            refuse("Speech model not installed")
            return
        }

        session += 1
        let current = session
        phase = .listening
        isHandsFree = handsFree
        startedAt = ProcessInfo.processInfo.systemUptime

        transcription.prepare(preferredModelID: settings.modelID)
        if settings.cleanupMode != .off { cleanup.rewriter?.prepare() }
        recorder.start(deviceUID: settings.inputDeviceUID) { [weak self] result in
            guard let self, self.session == current, case .failure(let error) = result else { return }
            self.fail(error.localizedDescription)
        }
        let language = LanguageChoice(mode: settings.languageMode, keyboardIsArabic: KeyboardLayout.currentInputIsArabic,
                                      ignoreBackgroundVoices: settings.ignoreBackgroundVoices)
        let live = transcription.startLive(recorder: recorder, language: language)
        if settings.showLiveText {
            live.onPartial = { [weak self] text in
                guard let self, self.session == current, self.phase == .listening else { return }
                self.hud.setLiveText(text)
            }
        }
        self.live = live

        // A quick tap is cancelled right away; waiting a moment avoids flashing the display for it.
        DispatchQueue.main.asyncAfter(deadline: .now() + DictationController.revealDelay) { [weak self] in
            guard let self, self.session == current, self.phase == .listening else { return }
            self.hud.showListening(handsFree: self.isHandsFree, meter: self.recorder.meter)
            self.playCue(.start)
        }

        let limit = DispatchWorkItem { [weak self] in
            guard let self, self.session == current, self.phase == .listening else { return }
            self.finish()
            self.onEndedExternally?()
        }
        limitTimer = limit
        DispatchQueue.main.asyncAfter(deadline: .now() + DictationController.maximumSeconds, execute: limit)
    }

    // MARK: - Finish

    private func finish() {
        guard phase == .listening, let live else { return }
        let current = session
        limitTimer?.cancel()
        phase = .transcribing
        hud.showProcessing(polishing: false)
        playCue(.stop)

        // If the last word is still being spoken, keep the microphone open for a moment longer.
        let meter = recorder.meter
        let recentLevels = meter.levels(endingAt: meter.sliceCount, count: 8)
        let stillSpeaking = (recentLevels.max() ?? 0) > 0.32
        let postRoll: TimeInterval = stillSpeaking ? 0.14 : 0

        // Read the focused field while transcription finishes.
        let contextBox = ContextBox()
        Accessibility.queue.async {
            contextBox.set(Accessibility.snapshot(readText: true))
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + postRoll) { [weak self] in
            guard let self, self.session == current else { return }
            let samples = self.recorder.finish()
            let recordedSeconds = Double(samples.count) / Double(SpeechEngine.sampleRate)
            live.finish(samples: samples) { [weak self] result in
                guard let self, self.session == current else { return }
                let context = contextBox.wait(upTo: 0.3)
                self.deliver(result, samples: samples, context: context, recordedSeconds: recordedSeconds, postRoll: postRoll)
            }
        }
    }

    private func deliver(_ result: TranscriptionResult, samples: [Float], context: FocusSnapshot,
                         recordedSeconds: Double, postRoll: TimeInterval) {
        live = nil
        transcription.scheduleUnload(afterMinutes: settings.modelIdleMinutes)

        if result.failed {
            fail("Couldn't transcribe that")
            return
        }
        let processed = TextPipeline.process(result.text, options: pipelineOptions())
        guard !result.noSpeech, !processed.text.isEmpty else {
            phase = .idle
            if recordedSeconds > 1.0 {
                hud.showNotice("Didn't catch that", symbol: "waveform.slash", isError: false)
            } else {
                hud.hide()
            }
            return
        }

        let latency = result.latencyMs + postRoll * 1000
        let rawText = result.text
        if cleanup.shouldPolish(processed.text, mode: settings.cleanupMode) {
            phase = .polishing
            hud.showProcessing(polishing: true)
            let current = session
            let started = Date()
            cleanup.polish(processed.text, vocabulary: dictionary.phrases) { [weak self] polished in
                guard let self, self.session == current else { return }
                let extra = Date().timeIntervalSince(started) * 1000
                self.complete(text: polished ?? processed.text, rawText: rawText, polished: polished != nil,
                              result: result, samples: samples, context: context, latencyMs: latency + extra)
            }
        } else {
            complete(text: processed.text, rawText: rawText, polished: false, result: result, samples: samples,
                     context: context, latencyMs: latency)
        }
    }

    private func complete(text: String, rawText: String, polished: Bool, result: TranscriptionResult,
                          samples: [Float], context: FocusSnapshot, latencyMs: Double) {
        phase = .idle
        lastText = text
        lastRawText = rawText

        var inserted = false
        var insertedText = text
        var note: String?
        if context.isSecureField {
            note = "Password field: not inserted"
        } else if !Accessibility.isTrusted {
            inserter.copy(text)
            note = "Copied. Allow Accessibility to insert"
            onNeedsSetup?()
        } else {
            let formatted = InsertionFormatter.format(text, context: context, enabled: settings.smartSpacing)
            insertedText = formatted.trimmingCharacters(in: .whitespaces)
            inserted = inserter.insert(formatted, method: settings.insertionMethod, restoreClipboard: settings.restoreClipboard)
            if !inserted {
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
        Log.info(String(format: "Dictation done: %.1fs audio, text after %.0f ms%@, %d chars, lang %@",
                        result.audioSeconds, latencyMs, result.wasReadyEarly ? " (ready early)" : "",
                        text.count, result.language))
        for note in result.languageNotes { Log.info("  language: \(note)") }

        if let note {
            hud.showNotice(note, symbol: "doc.on.clipboard", isError: false)
        } else {
            hud.showSuccess()
        }
        // A dictation that went all the way through proves setup is done.
        if inserted, !settings.onboardingCompleted { settings.onboardingCompleted = true }
        // Hand over exactly what landed in the field, so later corrections can be found there.
        if inserted { onInserted?(insertedText, context, transcriptID) }
    }

    // MARK: - Cancel and errors

    private func cancel(silently: Bool) {
        guard phase == .listening else { return }
        session += 1
        limitTimer?.cancel()
        live?.cancel()
        live = nil
        recorder.cancel()
        phase = .idle
        hud.hide()
        transcription.scheduleUnload(afterMinutes: settings.modelIdleMinutes)
    }

    /// Something prevented dictation from starting.
    private func refuse(_ message: String) {
        hud.showNotice(message, symbol: "exclamationmark.triangle.fill", isError: true)
        playCue(.error)
        onNeedsSetup?()
        onEndedExternally?()
    }

    private func fail(_ message: String) {
        session += 1
        limitTimer?.cancel()
        live?.cancel()
        live = nil
        recorder.cancel()
        phase = .idle
        hud.showNotice(message, symbol: "exclamationmark.triangle.fill", isError: true)
        playCue(.error)
        Log.error("Dictation failed: \(message)")
        onEndedExternally?()
    }

    // MARK: - Helpers

    private func playCue(_ cue: SoundEffects.Cue) {
        guard settings.playSounds else { return }
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
