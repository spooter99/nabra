import Foundation
import Observation

/// What came out of one dictation.
struct TranscriptionResult {
    /// Recognised text before any clean-up.
    var text: String = ""
    /// "ar", "en" or "mixed", judged from the text that was produced.
    var language: String = ""
    var audioSeconds: Double = 0
    var speechSeconds: Double = 0
    /// Time between the end of recording and this result being ready.
    var latencyMs: Double = 0
    /// Total compute spent decoding, including work done while still recording.
    var computeMs: Double = 0
    /// How the language was chosen for each stretch of speech (for the log).
    var languageNotes: [String] = []
    /// Nothing that sounded like speech was captured.
    var noSpeech = false
    /// The result was already finished before recording ended.
    var wasReadyEarly = false
    var failed = false
}

/// Audio that is still arriving. Implemented by the microphone recorder and by test sources.
protocol SampleSource: AnyObject {
    /// Number of 16 kHz samples available so far. Thread-safe.
    var sampleCount: Int { get }
    /// Copies the samples in `range` (clamped to what is available). Thread-safe.
    func copySamples(in range: Range<Int>) -> [Float]
}

extension AudioRecorder: SampleSource {}

/// How to choose the language for a dictation.
struct LanguageChoice {
    var mode: LanguageMode
    /// Whether the active keyboard layout is Arabic. Only used when a clip is too short to identify.
    var keyboardIsArabic = false
    /// Mute sustained speech that is far quieter than the person dictating. Off by default: the
    /// recogniser already follows the loudest voice, and muting risks dropping a softly spoken sentence.
    var ignoreBackgroundVoices = false
    /// The language of what was dictated just before ("en" or "ar"), when recent enough to matter.
    /// Tips the decision only when the audio itself leaves it open.
    var recentLanguage: String?
}

/// Owns the speech models and runs all recognition on one serial queue.
///
/// Models load on demand (about 130 ms once the system has cached them) and are released after a
/// period without use, so an idle Nabra holds almost no memory.
@Observable
final class TranscriptionService {
    enum EngineState: Equatable {
        case missingModel
        case unloaded
        case loading
        case ready
        case failed(String)
    }

    /// Main-thread view of the engine, for the UI.
    private(set) var state: EngineState = .unloaded
    private(set) var loadedModelID: String?

    @ObservationIgnored fileprivate let queue = DispatchQueue(label: "app.nabra.asr", qos: .userInitiated)
    @ObservationIgnored fileprivate var engine: SpeechEngine?
    @ObservationIgnored fileprivate var voiceDetector: VoiceActivityDetector?
    @ObservationIgnored private var engineModelID: String?
    @ObservationIgnored private var unloadWork: DispatchWorkItem?
    @ObservationIgnored private let abortLock = NSLock()
    @ObservationIgnored private weak var decodingFor: AnyObject?

    init() {
        if SpeechModel.all.allSatisfy({ !$0.isInstalled }) { state = .missingModel }
    }

    // MARK: - Lifecycle

    /// Loads the models if needed. Safe to call often; `completion` runs on the main queue.
    func prepare(preferredModelID: String, completion: ((Bool) -> Void)? = nil) {
        queue.async { [self] in
            let ok = loadEngineIfNeeded(preferredModelID: preferredModelID)
            DispatchQueue.main.async { completion?(ok) }
        }
    }

    /// Runs on `queue`. Returns true when a speech model is loaded.
    private func loadEngineIfNeeded(preferredModelID: String) -> Bool {
        unloadWork?.cancel()
        unloadWork = nil
        loadHelpersIfNeeded()
        guard let model = SpeechModel.bestInstalled(preferred: preferredModelID) else {
            setEngine(nil, modelID: nil)
            setState(.missingModel)
            return false
        }
        if engine != nil, engineModelID == model.id { return true }
        setEngine(nil, modelID: nil)
        setState(.loading)
        let started = Date()
        do {
            let loaded = try SpeechEngine(modelPath: model.localURL.path)
            loaded.warmUp()
            setEngine(loaded, modelID: model.id)
            Log.info(String(format: "Speech model %@ ready in %.0f ms", model.id, Date().timeIntervalSince(started) * 1000))
            setState(.ready, modelID: model.id)
            return true
        } catch {
            Log.error("Speech model failed to load: \(error.localizedDescription)")
            setState(.failed(error.localizedDescription))
            return false
        }
    }

    private func setEngine(_ newEngine: SpeechEngine?, modelID: String?) {
        abortLock.lock()
        engine = newEngine
        abortLock.unlock()
        engineModelID = modelID
    }

    /// Interrupts the decode that is running, if it is being done for `owner` (nil: whoever it is for).
    /// Several dictations can be in flight at once, and cancelling one must not cut another short.
    /// Safe from any thread.
    func abortCurrentDecode(for owner: AnyObject? = nil) {
        abortLock.lock()
        let current = engine
        let mine = owner == nil || decodingFor === owner
        abortLock.unlock()
        if mine { current?.requestAbort() }
    }

    /// Records on whose behalf the recogniser is working, for `abortCurrentDecode(for:)`. Call on `queue`.
    fileprivate func setDecodingOwner(_ owner: AnyObject?) {
        abortLock.lock()
        decodingFor = owner
        abortLock.unlock()
    }

    /// Releases the speech model after `minutes` without use. 0 keeps it loaded.
    func scheduleUnload(afterMinutes minutes: Int) {
        queue.async { [self] in
            unloadWork?.cancel()
            unloadWork = nil
            guard minutes > 0, engine != nil else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.engine != nil else { return }
                self.setEngine(nil, modelID: nil)
                Log.info("Speech model released after idle period")
                self.setState(.unloaded)
            }
            unloadWork = work
            queue.asyncAfter(deadline: .now() + .seconds(minutes * 60), execute: work)
        }
    }

    /// Frees the models before the app quits, so no GPU memory is still in use when the process exits.
    func shutdown() {
        queue.sync { [self] in
            unloadWork?.cancel()
            unloadWork = nil
            setEngine(nil, modelID: nil)
            voiceDetector = nil
        }
    }

    func unloadNow() {
        queue.async { [self] in
            unloadWork?.cancel()
            unloadWork = nil
            setEngine(nil, modelID: nil)
            setState(SpeechModel.all.contains { $0.isInstalled } ? .unloaded : .missingModel)
        }
    }

    /// Re-reads which models are installed (after a download or deletion).
    func refreshInstalledState() {
        queue.async { [self] in
            if engine == nil {
                setState(SpeechModel.all.contains { $0.isInstalled } ? .unloaded : .missingModel)
            }
        }
    }

    private func loadHelpersIfNeeded() {
        SpeechEngine.silenceLibraryLogs()
        if voiceDetector == nil, let path = VoiceActivityDetector.bundledModelPath {
            voiceDetector = VoiceActivityDetector(modelPath: path)
            if voiceDetector == nil { Log.error("Voice activity model failed to load") }
        }
    }

    private func setState(_ newState: EngineState, modelID: String? = nil) {
        DispatchQueue.main.async {
            self.state = newState
            self.loadedModelID = newState == .ready ? modelID : nil
        }
    }

    // MARK: - Recognition

    /// Starts transcribing a recording while it is still being made.
    func startLive(recorder: SampleSource, language: LanguageChoice) -> LiveTranscription {
        let live = LiveTranscription(service: self, recorder: recorder, mode: language)
        live.start()
        return live
    }

    /// Transcribes a finished clip (saved recordings, files).
    /// With `requireSpeech` false the whole clip is decoded even where the voice detector heard no
    /// speech (a second attempt the user asked for).
    func transcribe(samples: [Float],
                    language mode: LanguageChoice,
                    preferredModelID: String,
                    requireSpeech: Bool = true,
                    completion: @escaping (TranscriptionResult) -> Void) {
        let started = DispatchTime.now().uptimeNanoseconds
        queue.async { [self] in
            var result = TranscriptionResult()
            result.audioSeconds = Double(samples.count) / Double(SpeechEngine.sampleRate)
            guard loadEngineIfNeeded(preferredModelID: preferredModelID) else {
                result.failed = true
                DispatchQueue.main.async { completion(result) }
                return
            }
            var probabilities = voiceDetector?.probabilities(for: samples) ?? []
            var background: [Bool] = []
            if mode.ignoreBackgroundVoices, !probabilities.isEmpty {
                let levels = samples.withUnsafeBufferPointer { SpeechActivity.frameLevels($0) }
                (probabilities, background) = SpeechActivity.separateBackground(probabilities: probabilities, levels: levels)
            }
            result.speechSeconds = SpeechActivity.speechSeconds(probabilities)
            if !requireSpeech, result.speechSeconds < SpeechActivity.minimumSpeechSeconds {
                // Asked to try anyway: decode it all, without trimming to what sounded like speech.
                probabilities = []
                background = []
            }
            if requireSpeech, !probabilities.isEmpty, result.speechSeconds < SpeechActivity.minimumSpeechSeconds {
                result.noSpeech = true
            } else {
                let decoded = decode(samples: samples, range: 0..<samples.count, probabilities: probabilities,
                                     background: background, mode: mode)
                result.text = decoded.text
                result.computeMs = decoded.ms
                result.failed = decoded.failed
                result.languageNotes = decoded.notes
                result.language = TranscriptionService.languageLabel(for: decoded.text)
                result.noSpeech = decoded.text.isEmpty && !decoded.failed
            }
            result.latencyMs = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Decodes `range` of `samples`, splitting long stretches at pauses. Runs on `queue`.
    fileprivate func decode(samples: [Float],
                            range: Range<Int>,
                            probabilities: [Float],
                            background: [Bool] = [],
                            mode: LanguageChoice) -> (text: String, ms: Double, failed: Bool, notes: [String]) {
        guard let engine else { return ("", 0, true, []) }
        var parts: [String] = []
        var notes: [String] = []
        var total = 0.0
        var failed = false
        var mode = mode
        for piece in SpeechActivity.split(range: range, probabilities: probabilities) {
            let trimmed = SpeechActivity.trim(range: piece, probabilities: probabilities, limit: samples.count)
            guard trimmed.count >= SpeechEngine.sampleRate / 5 else { continue }
            var note = ""
            let firstFrame = trimmed.lowerBound / SpeechActivity.frameSamples
            let lastFrame = min(background.count, trimmed.upperBound / SpeechActivity.frameSamples + 1)
            let hasBackground = firstFrame < lastFrame && background[firstFrame..<lastFrame].contains(true)
            let result: SpeechEngine.Result
            if hasBackground {
                var audio = Array(samples[trimmed])
                SpeechActivity.mute(&audio, offset: trimmed.lowerBound, background: background)
                result = audio.withUnsafeBufferPointer {
                    recognise($0, engine: engine, choice: mode, spentMs: &total, note: &note)
                }
                note += " (background voices muted)"
            } else {
                result = samples.withUnsafeBufferPointer { buffer in
                    recognise(UnsafeBufferPointer(rebasing: buffer[trimmed]), engine: engine, choice: mode,
                              spentMs: &total, note: &note)
                }
            }
            if !note.isEmpty { notes.append(note) }
            if result.aborted { break }
            if result.failed { failed = true; continue }
            if !result.text.isEmpty {
                parts.append(result.text)
                // What follows in the same breath is most likely in the same language.
                let label = TranscriptionService.languageLabel(for: result.text)
                if label == "en" || label == "ar" { mode.recentLanguage = label }
            }
        }
        return (TranscriptionService.join(parts), total, failed && parts.isEmpty, notes)
    }

    /// Puts separately recognised stretches back together.
    ///
    /// The recogniser closes every stretch it is given with a full stop, even when the speaker only
    /// paused for breath. When the next stretch starts in lower case it heard a continuation, so
    /// that stop is dropped ("…on GitHub." + "and make it…" becomes "…on GitHub and make it…").
    static func join(_ pieces: [String]) -> String {
        var result = ""
        for piece in pieces where !piece.isEmpty {
            guard !result.isEmpty else {
                result = piece
                continue
            }
            if result.hasSuffix("."), !result.hasSuffix(".."), let first = piece.first, first.isASCII, first.isLowercase {
                result.removeLast()
            }
            result += " " + piece
        }
        return result
    }

    /// Recognises one stretch of speech. Runs on `queue`.
    ///
    /// In Arabic + English mode the audio is decoded under both language hints (sharing one encoder
    /// pass) and `LanguageArbiter` works out what was said from the two: which one to build on, and
    /// whether single words should be taken from the other (an Arabic name in an English sentence).
    /// Judging the language from the sound alone proved unreliable: an accent, or someone talking
    /// nearby, easily fools an acoustic language detector.
    private func recognise(_ slice: UnsafeBufferPointer<Float>, engine: SpeechEngine, choice: LanguageChoice,
                           spentMs: inout Double, note: inout String) -> SpeechEngine.Result {
        switch choice.mode {
        case .arabic, .english:
            let result = engine.transcribe(slice, options: SpeechEngine.Options(language: choice.mode.engineLanguage))
            spentMs += result.totalMs
            return result
        case .auto:
            break
        }

        var spent = 0.0
        var passes = 0
        func run(_ options: SpeechEngine.Options) -> SpeechEngine.Result {
            let result = engine.transcribe(slice, options: options)
            spent += result.totalMs
            passes += 1
            return result
        }
        defer { spentMs += spent }

        let english = run(SpeechEngine.Options(language: "en", tokenTimes: true))
        if english.aborted || english.failed { return english }
        let arabic = run(SpeechEngine.Options(language: "ar", reuseEncoder: true, tokenTimes: true))
        if arabic.aborted { return arabic }
        if arabic.failed { return english }

        let outcome = LanguageArbiter.resolve(english: english, arabic: arabic, recentLanguage: choice.recentLanguage,
                                              keyboardIsArabic: choice.keyboardIsArabic) { ids, language, withTimes in
            run(SpeechEngine.Options(language: language, reuseEncoder: true, tokenTimes: withTimes, forcedTokens: ids))
        }
        note = outcome.note + String(format: " (%d passes, %.0f ms)", passes, spent)
        if ProcessInfo.processInfo.environment["NABRA_DEBUG_TIMING"] != nil {
            note += String(format: " [enc %.0f dec %.0f/%.0f]", english.encodeMs, english.decodeMs, arabic.decodeMs)
            note += " {en: \(english.text)} {ar: \(arabic.text)}"
        }
        return outcome.result
    }

    /// "ar", "en" or "mixed" from the letters in the text.
    static func languageLabel(for text: String) -> String {
        let counts = TextScript.letterCounts(text)
        let total = counts.arabic + counts.latin
        guard total > 0 else { return "" }
        let arabicShare = Double(counts.arabic) / Double(total)
        if arabicShare >= 0.85 { return "ar" }
        if arabicShare <= 0.15 { return "en" }
        return "mixed"
    }
}

/// Helpers that turn per-frame speech probabilities into decisions.
enum SpeechActivity {
    static let threshold: Float = 0.45
    static let minimumSpeechSeconds = 0.16
    /// Stretches longer than this are split at the quietest point, matching what the model was trained on.
    static let maximumChunkSeconds = 28.0

    static var frameSamples: Int { VoiceActivityDetector.frameSamples }

    static func speechSeconds(_ probabilities: [Float]) -> Double {
        Double(probabilities.reduce(0) { $0 + ($1 >= threshold ? 1 : 0) }) * VoiceActivityDetector.frameSeconds
    }

    /// Index of the last frame that contains speech, or nil.
    static func lastSpeechFrame(_ probabilities: [Float]) -> Int? {
        probabilities.lastIndex { $0 >= threshold }
    }

    /// Number of speech frames at or after `frame`.
    static func speechFrames(_ probabilities: [Float], from frame: Int) -> Int {
        guard frame < probabilities.count else { return 0 }
        return probabilities[max(0, frame)...].reduce(0) { $0 + ($1 >= threshold ? 1 : 0) }
    }

    // MARK: Background voices

    /// How far below the speaker's own level (in dB) sustained speech must be to count as someone else.
    /// Deliberately wide: a quiet word of your own must never be mistaken for someone across the room.
    static let backgroundMarginDecibels: Float = 18
    /// A quieter stretch must last this many frames (~0.65 s) before it is treated as background.
    static let backgroundMinimumFrames = 20

    /// Loudness of each 512-sample frame in dBFS.
    static func frameLevels(_ samples: UnsafeBufferPointer<Float>) -> [Float] {
        let count = samples.count / frameSamples
        guard count > 0, let base = samples.baseAddress else { return [] }
        var levels = [Float](repeating: -120, count: count)
        for frame in 0..<count {
            var sum: Float = 0
            let start = base + frame * frameSamples
            for index in 0..<frameSamples { sum += start[index] * start[index] }
            let rms = (sum / Float(frameSamples)).squareRoot()
            levels[frame] = rms > 0 ? max(-120, 20 * log10(rms)) : -120
        }
        return levels
    }

    /// Separates the person dictating from quieter voices around them.
    ///
    /// The dictating voice is close to the microphone and therefore much louder than anyone else in
    /// the room. Speech that stays well below that level for half a second or more is marked as
    /// background: its probability is set to zero and its frame is flagged so the audio can be muted
    /// before recognition. Brief dips (quiet syllables, trailing words) are left alone.
    static func separateBackground(probabilities: [Float], levels: [Float]) -> (probabilities: [Float], background: [Bool]) {
        let count = min(probabilities.count, levels.count)
        var background = [Bool](repeating: false, count: probabilities.count)
        guard count > 0 else { return (probabilities, background) }
        let speechLevels = (0..<count).filter { probabilities[$0] >= threshold }.map { levels[$0] }.sorted()
        guard speechLevels.count >= 12 else { return (probabilities, background) }
        // The dictating voice: the loud end of everything that sounded like speech.
        let reference = speechLevels[min(speechLevels.count - 1, Int(Double(speechLevels.count) * 0.9))]
        let floor = reference - backgroundMarginDecibels

        // A frame is "quiet" only if nothing within ~130 ms of it reaches the speaker's level.
        var quiet = [Bool](repeating: false, count: count)
        for frame in 0..<count where probabilities[frame] >= threshold {
            let lower = max(0, frame - 4)
            let upper = min(count - 1, frame + 4)
            var peak: Float = -120
            for neighbour in lower...upper { peak = max(peak, levels[neighbour]) }
            quiet[frame] = peak < floor
        }
        // Keep only sustained runs. Non-speech frames inside a run do not break it.
        var masked = probabilities
        var frame = 0
        while frame < count {
            guard quiet[frame] else { frame += 1; continue }
            var end = frame
            var gap = 0
            var cursor = frame
            while cursor < count, gap <= 6 {
                if quiet[cursor] {
                    end = cursor
                    gap = 0
                } else if probabilities[cursor] >= threshold {
                    break
                } else {
                    gap += 1
                }
                cursor += 1
            }
            if end - frame + 1 >= backgroundMinimumFrames {
                for index in frame...end {
                    masked[index] = 0
                    background[index] = true
                }
            }
            frame = end + 1
        }
        return (masked, background)
    }

    /// Mutes the frames flagged as background inside `audio`, which starts `offset` samples into the recording.
    static func mute(_ audio: inout [Float], offset: Int, background: [Bool]) {
        guard !background.isEmpty, !audio.isEmpty else { return }
        let ramp = 128 // 8 ms fades on either side avoid clicks
        var frame = max(0, offset / frameSamples)
        let lastFrame = min(background.count - 1, (offset + audio.count - 1) / frameSamples)
        while frame <= lastFrame {
            guard background[frame] else { frame += 1; continue }
            var end = frame
            while end + 1 <= lastFrame, background[end + 1] { end += 1 }
            let lower = max(0, frame * frameSamples - offset)
            let upper = min(audio.count, (end + 1) * frameSamples - offset)
            if upper > lower {
                for index in lower..<upper { audio[index] = 0 }
                for step in 0..<ramp {
                    let gain = Float(step + 1) / Float(ramp + 1)
                    if lower - 1 - step >= 0 { audio[lower - 1 - step] *= gain }
                    if upper + step < audio.count { audio[upper + step] *= gain }
                }
            }
            frame = end + 1
        }
    }

    /// Tightens `range` to the speech inside it, keeping a little room on both sides.
    /// Returns an empty range when it holds no speech. Without probabilities the range is returned as is.
    ///
    /// When `levels` are given, only genuinely quiet audio is cut: anything within 25 dB of the
    /// speaker's level is kept even if the voice detector did not flag it, so softly spoken words
    /// at the edges are never trimmed away.
    static func trim(range: Range<Int>, probabilities: [Float], levels: [Float] = [], limit: Int) -> Range<Int> {
        guard !probabilities.isEmpty else { return range }
        let firstFrame = range.lowerBound / frameSamples
        let endFrame = min(probabilities.count, (range.upperBound + frameSamples - 1) / frameSamples)
        guard firstFrame < endFrame else { return range.lowerBound..<range.lowerBound }
        guard var first = (firstFrame..<endFrame).first(where: { probabilities[$0] >= threshold }),
              var last = (firstFrame..<endFrame).last(where: { probabilities[$0] >= threshold })
        else { return range.lowerBound..<range.lowerBound }

        let levelEnd = min(endFrame, levels.count)
        if firstFrame < levelEnd {
            let speechLevels = (firstFrame..<levelEnd).filter { probabilities[$0] >= threshold }.map { levels[$0] }.sorted()
            if !speechLevels.isEmpty {
                let reference = speechLevels[min(speechLevels.count - 1, Int(Double(speechLevels.count) * 0.9))]
                let floor = reference - 25
                if let earliest = (firstFrame..<levelEnd).first(where: { levels[$0] >= floor }) { first = min(first, earliest) }
                if let latest = (firstFrame..<levelEnd).last(where: { levels[$0] >= floor }) { last = max(last, latest) }
            }
        }
        let lead = SpeechEngine.sampleRate * 3 / 10
        let tail = SpeechEngine.sampleRate * 4 / 10
        let lower = max(range.lowerBound, first * frameSamples - lead)
        let upper = min(range.upperBound, limit, (last + 1) * frameSamples + tail)
        return lower..<max(lower, upper)
    }

    /// Splits a long range into pieces of at most `maximumChunkSeconds`, cutting where speech is least likely.
    static func split(range: Range<Int>, probabilities: [Float]) -> [Range<Int>] {
        let maximum = Int(maximumChunkSeconds * Double(SpeechEngine.sampleRate))
        guard range.count > maximum else { return [range] }
        var pieces: [Range<Int>] = []
        var start = range.lowerBound
        while range.upperBound - start > maximum {
            // Look for the quietest frame in the last third of the allowed window.
            let windowStart = start + maximum * 2 / 3
            let windowEnd = start + maximum
            var cut = windowEnd
            if !probabilities.isEmpty {
                let firstFrame = windowStart / frameSamples
                let lastFrame = min(probabilities.count - 1, windowEnd / frameSamples)
                if firstFrame <= lastFrame,
                   let quietest = (firstFrame...lastFrame).min(by: { smoothed(probabilities, $0) < smoothed(probabilities, $1) }) {
                    cut = quietest * frameSamples + frameSamples / 2
                }
            }
            cut = min(max(cut, start + SpeechEngine.sampleRate), range.upperBound)
            pieces.append(start..<cut)
            start = cut
        }
        if start < range.upperBound { pieces.append(start..<range.upperBound) }
        return pieces
    }

    private static func smoothed(_ probabilities: [Float], _ index: Int) -> Float {
        let lower = max(0, index - 2)
        let upper = min(probabilities.count - 1, index + 2)
        return probabilities[lower...upper].reduce(0, +) / Float(upper - lower + 1)
    }
}

/// Transcribes a recording while it is in progress, so that the text is ready (or nearly ready)
/// the moment the key is released.
///
/// - Every time the speaker pauses, the audio so far is decoded in the background. If nothing more
///   is said before release, that result is used as is: zero wait.
/// - Long dictations are committed piece by piece at pauses, so only the last stretch is ever pending.
final class LiveTranscription {
    /// Text recognised so far (committed pieces plus the latest draft). Called on the main queue.
    var onPartial: ((String) -> Void)?

    private let service: TranscriptionService
    private let recorder: SampleSource
    /// Starts as given; `recentLanguage` then follows what this dictation has committed so far.
    private var mode: LanguageChoice
    private var timer: DispatchSourceTimer?

    // All state below is confined to `service.queue`.
    private var detectorCursor = 0
    /// What the voice detector reported, one value per 512-sample frame.
    private var rawProbabilities: [Float] = []
    /// Loudness of each frame in dBFS, aligned with `rawProbabilities`.
    private var levels: [Float] = []
    /// `rawProbabilities` with background voices removed. All decisions use this.
    private var probabilities: [Float] = []
    private var background: [Bool] = []
    private var committedEnd = 0
    private var committedText: [String] = []
    private var draft: (speechEndFrame: Int, text: String, notes: [String])?
    private var committedNotes: [String] = []
    private var computeMs = 0.0
    private var finished = false

    private static let pauseFramesForDraft = 5          // ~0.16 s of silence
    private static let pauseFramesForCommit = 14        // ~0.45 s
    private static let commitAfterSeconds = 12.0
    private static let forceCommitAfterSeconds = 30.0
    private static let framesThatCountAsNewSpeech = 3

    fileprivate init(service: TranscriptionService, recorder: SampleSource, mode: LanguageChoice) {
        self.service = service
        self.recorder = recorder
        self.mode = mode
    }

    fileprivate func start() {
        service.queue.async { [self] in
            service.voiceDetector?.reset()
            let timer = DispatchSource.makeTimerSource(queue: service.queue)
            timer.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(60), leeway: .milliseconds(15))
            timer.setEventHandler { [weak self] in self?.tick() }
            timer.resume()
            self.timer = timer
        }
    }

    /// Abandons the session. A decode in flight for it is interrupted.
    func cancel() {
        service.abortCurrentDecode(for: self)
        service.queue.async { [self] in
            finished = true
            timer?.cancel()
            timer = nil
        }
    }

    /// Ends the session with the complete recording. `completion` runs on the main queue.
    func finish(samples: [Float], completion: @escaping (TranscriptionResult) -> Void) {
        let releasedAt = DispatchTime.now().uptimeNanoseconds
        service.queue.async { [self] in
            finished = true
            timer?.cancel()
            timer = nil

            var result = TranscriptionResult()
            result.audioSeconds = Double(samples.count) / Double(SpeechEngine.sampleRate)
            updateDetector(upTo: samples.count, from: samples)
            result.speechSeconds = SpeechActivity.speechSeconds(probabilities)

            let lastSpeech = SpeechActivity.lastSpeechFrame(probabilities)
            let detectorWorked = !rawProbabilities.isEmpty
            if detectorWorked, committedText.isEmpty, result.speechSeconds < SpeechActivity.minimumSpeechSeconds {
                result.noSpeech = true
            } else if service.engine == nil {
                result.failed = true
            } else {
                var tail = ""
                let committedFrame = committedEnd / SpeechActivity.frameSamples
                let pendingSpeech = !detectorWorked || SpeechActivity.speechFrames(probabilities, from: committedFrame) > 0
                if pendingSpeech {
                    if let draft, let lastSpeech, lastSpeech >= committedFrame, covers(draft.speechEndFrame) {
                        tail = draft.text
                        committedNotes += draft.notes
                        result.wasReadyEarly = true
                    } else {
                        service.setDecodingOwner(self)
                        defer { service.setDecodingOwner(nil) }
                        let decoded = service.decode(samples: samples, range: min(committedEnd, samples.count)..<samples.count,
                                                     probabilities: probabilities, background: background, mode: mode)
                        tail = decoded.text
                        committedNotes += decoded.notes
                        computeMs += decoded.ms
                        result.failed = decoded.failed && committedText.isEmpty
                    }
                }
                result.text = TranscriptionService.join(committedText + [tail])
                result.language = TranscriptionService.languageLabel(for: result.text)
                result.noSpeech = result.text.isEmpty && !result.failed
            }
            result.computeMs = computeMs
            result.languageNotes = committedNotes
            result.latencyMs = Double(DispatchTime.now().uptimeNanoseconds - releasedAt) / 1_000_000
            DispatchQueue.main.async { completion(result) }
        }
    }

    // MARK: - Background work (service queue)

    private func tick() {
        guard !finished, service.engine != nil else { return }
        let total = recorder.sampleCount
        // The source only ever grows; anything else means it was replaced under us.
        guard total >= committedEnd else { return }
        updateDetector(upTo: total, from: nil)
        guard let lastSpeech = SpeechActivity.lastSpeechFrame(probabilities) else { return }

        let frameSamples = SpeechActivity.frameSamples
        let committedFrame = committedEnd / frameSamples
        guard lastSpeech >= committedFrame else { return }
        let trailingSilence = probabilities.count - 1 - lastSpeech
        let pendingSeconds = Double(total - committedEnd) / Double(SpeechEngine.sampleRate)
        let speechEnd = min(total, (lastSpeech + 1) * frameSamples)

        // Long dictation: lock in everything up to this pause.
        let longPause = trailingSilence >= LiveTranscription.pauseFramesForCommit
        if (pendingSeconds >= LiveTranscription.commitAfterSeconds && longPause)
            || pendingSeconds >= LiveTranscription.forceCommitAfterSeconds {
            var end = longPause ? min(total, speechEnd + SpeechEngine.sampleRate / 5) : forcedCut(total: total)
            end = max(committedEnd, end / frameSamples * frameSamples)   // keep cuts on the frame grid
            let (text, notes) = decodeLive(range: committedEnd..<end)
            guard !finished else { return }
            if !text.isEmpty {
                committedText.append(text)
                let label = TranscriptionService.languageLabel(for: text)
                if label == "en" || label == "ar" { mode.recentLanguage = label }
            }
            committedNotes += notes
            committedEnd = end
            draft = nil
            publish()
            return
        }

        // A pause: decode what we have so it is ready if the key is released now.
        if trailingSilence >= LiveTranscription.pauseFramesForDraft, !(draft.map { covers($0.speechEndFrame) } ?? false) {
            let (text, notes) = decodeLive(range: committedEnd..<total)
            guard !finished else { return }
            draft = (lastSpeech, text, notes)
            publish()
        }
    }

    /// True when no meaningful speech has arrived after `frame`.
    private func covers(_ frame: Int) -> Bool {
        SpeechActivity.speechFrames(probabilities, from: frame + 1) < LiveTranscription.framesThatCountAsNewSpeech
    }

    private func decodeLive(range: Range<Int>) -> (String, [String]) {
        let audio = recorder.copySamples(in: range)
        guard !audio.isEmpty else { return ("", []) }
        service.setDecodingOwner(self)
        defer { service.setDecodingOwner(nil) }
        // Activity is indexed from the start of the recording; shift it to this slice.
        let firstFrame = range.lowerBound / SpeechActivity.frameSamples
        let local = firstFrame < probabilities.count ? Array(probabilities[firstFrame...]) : []
        let localBackground = firstFrame < background.count ? Array(background[firstFrame...]) : []
        let decoded = service.decode(samples: audio, range: 0..<audio.count, probabilities: local,
                                     background: localBackground, mode: mode)
        computeMs += decoded.ms
        return (decoded.text, decoded.notes)
    }

    /// When someone talks for 30 s without a real pause, cut at the quietest recent moment.
    private func forcedCut(total: Int) -> Int {
        let frameSamples = SpeechActivity.frameSamples
        let lastFrame = min(probabilities.count - 1, total / frameSamples)
        let firstFrame = max(committedEnd / frameSamples + 1, lastFrame - Int(8 / VoiceActivityDetector.frameSeconds))
        guard firstFrame < lastFrame,
              let quietest = (firstFrame...lastFrame).min(by: { probabilities[$0] < probabilities[$1] })
        else { return total }
        return min(total, quietest * frameSamples + frameSamples / 2)
    }

    /// Feeds new audio to the voice detector, measures its loudness, and refreshes the speech map.
    private func updateDetector(upTo total: Int, from samples: [Float]?) {
        guard let detector = service.voiceDetector, total > detectorCursor else { return }
        let fresh = samples.map { Array($0[detectorCursor..<min(total, $0.count)]) }
            ?? recorder.copySamples(in: detectorCursor..<total)
        guard !fresh.isEmpty else { return }
        rawProbabilities += fresh.withUnsafeBufferPointer { detector.feed($0) }
        detectorCursor += fresh.count

        guard mode.ignoreBackgroundVoices else {
            probabilities = rawProbabilities
            return
        }
        // Loudness for every frame the detector has scored so far.
        let frameSamples = SpeechActivity.frameSamples
        if levels.count < rawProbabilities.count {
            let range = (levels.count * frameSamples)..<(rawProbabilities.count * frameSamples)
            let audio = samples.map { Array($0[range.lowerBound..<min(range.upperBound, $0.count)]) }
                ?? recorder.copySamples(in: range)
            levels += audio.withUnsafeBufferPointer { SpeechActivity.frameLevels($0) }
        }
        (probabilities, background) = SpeechActivity.separateBackground(probabilities: rawProbabilities, levels: levels)
    }

    private func publish() {
        guard let onPartial else { return }
        let text = TranscriptionService.join(committedText + [draft?.text ?? ""])
        DispatchQueue.main.async { onPartial(text) }
    }
}
