import AppKit
import ApplicationServices
import Observation

/// Learns spellings from the corrections you make.
///
/// After a dictation is inserted, the text field it went into is watched for a short while. If a word
/// of the dictation is replaced with a similar one (a name, a term), the new spelling is added to the
/// dictionary. Edits made to a transcript inside Nabra are learned the same way.
@Observable
final class CorrectionLearner {
    /// Spellings learned recently, newest first.
    private(set) var recentlyLearned: [String] = []

    @ObservationIgnored private let dictionary: DictionaryStore
    @ObservationIgnored private let history: HistoryStore
    @ObservationIgnored private let settings: Settings
    @ObservationIgnored private let hud: HUDController

    /// One watched insertion. Touched only on `Accessibility.queue`, except where noted.
    private final class Watch {
        let element: AXUIElement
        let pid: pid_t
        let inserted: String
        let transcriptID: Int64?
        var baseline: NSString = ""
        var insertRange = NSRange(location: 0, length: 0)
        var lastValue: NSString = ""
        var lastChange = Date()
        var analyzedValue: NSString?
        let started = Date()
        var anchored = false
        /// heard → ids of the dictionary entries created for it during this watch (main thread).
        var learned: [String: (corrected: String, ids: [Int64])] = [:]

        init(element: AXUIElement, pid: pid_t, inserted: String, transcriptID: Int64?) {
            self.element = element
            self.pid = pid
            self.inserted = inserted
            self.transcriptID = transcriptID
        }
    }

    @ObservationIgnored private var current: Watch?
    @ObservationIgnored private var timer: DispatchSourceTimer?

    private static let watchSeconds: TimeInterval = 75
    private static let settleSeconds: TimeInterval = 1.8
    /// Terminals expose their whole scrollback as one value; nothing useful can be learned there.
    private static let ignoredApps: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.mitchellh.ghostty",
        "net.kovidgoyal.kitty", "co.zeit.hyper", "org.alacritty", "com.github.wez.wezterm",
    ]

    init(dictionary: DictionaryStore, history: HistoryStore, settings: Settings, hud: HUDController) {
        self.dictionary = dictionary
        self.history = history
        self.settings = settings
        self.hud = hud
    }

    // MARK: - Watching the field after insertion

    func watch(inserted: String, context: FocusSnapshot, transcriptID: Int64?) {
        stopWatching(finalize: true)
        guard settings.learnFromCorrections, Accessibility.isTrusted,
              let element = context.element, context.value != nil,
              !CorrectionLearner.ignoredApps.contains(context.bundleID ?? ""),
              TextScript.wordCount(inserted) >= 1
        else { return }

        let watch = Watch(element: element, pid: context.processID, inserted: inserted, transcriptID: transcriptID)
        current = watch
        let expectedLocation = context.selection?.location ?? 0

        let timer = DispatchSource.makeTimerSource(queue: Accessibility.queue)
        // Give the paste a moment to land before taking the baseline.
        timer.schedule(deadline: .now() + .milliseconds(700), repeating: .milliseconds(900), leeway: .milliseconds(150))
        timer.setEventHandler { [weak self, weak watch] in
            guard let self, let watch else { return }
            self.poll(watch, expectedLocation: expectedLocation)
        }
        timer.resume()
        self.timer = timer
    }

    private func stopWatching(finalize: Bool) {
        timer?.cancel()
        timer = nil
        guard let watch = current else { return }
        current = nil
        if finalize {
            Accessibility.queue.async { [weak self] in
                guard let self, watch.anchored, let text = Accessibility.currentText(of: watch.element) else { return }
                self.analyze(watch, value: text.value as NSString, final: true)
            }
        }
    }

    /// Runs on `Accessibility.queue`.
    private func poll(_ watch: Watch, expectedLocation: Int) {
        guard Date().timeIntervalSince(watch.started) < CorrectionLearner.watchSeconds,
              Accessibility.isStillFocused(watch.element, pid: watch.pid),
              let text = Accessibility.currentText(of: watch.element)
        else {
            DispatchQueue.main.async { [weak self] in
                if self?.current === watch { self?.stopWatching(finalize: true) }
            }
            return
        }
        let value = text.value as NSString

        if !watch.anchored {
            // Find where the dictation landed.
            guard let range = CorrectionLearner.locate(watch.inserted, in: value, near: expectedLocation) else {
                DispatchQueue.main.async { [weak self] in
                    if self?.current === watch { self?.stopWatching(finalize: false) }
                }
                return
            }
            watch.anchored = true
            watch.baseline = value
            watch.insertRange = range
            watch.lastValue = value
            watch.lastChange = Date()
            return
        }

        if !value.isEqual(to: watch.lastValue as String) {
            watch.lastValue = value
            watch.lastChange = Date()
            return
        }
        guard !value.isEqual(to: watch.baseline as String),
              Date().timeIntervalSince(watch.lastChange) >= CorrectionLearner.settleSeconds,
              watch.analyzedValue.map({ !$0.isEqual(to: value as String) }) ?? true
        else { return }
        watch.analyzedValue = value
        analyze(watch, value: value, final: false)
    }

    /// Runs on `Accessibility.queue`. Extracts what the dictated text looks like now and hands it to the main thread.
    private func analyze(_ watch: Watch, value: NSString, final: Bool) {
        let baseline = watch.baseline
        let start = watch.insertRange.location
        let end = watch.insertRange.location + watch.insertRange.length
        guard start <= baseline.length, end <= baseline.length, start <= value.length else { return }
        // Text before and after the dictation must still be there, or we cannot tell what was edited.
        let prefix = baseline.substring(to: start)
        let suffix = baseline.substring(from: end)
        guard value.hasPrefix(prefix) else { return }
        let tailLength = (suffix as NSString).length
        guard value.length >= start + tailLength, value.hasSuffix(suffix) else { return }
        let edited = value.substring(with: NSRange(location: start, length: value.length - start - tailLength))
        let original = watch.inserted
        DispatchQueue.main.async { [weak self] in
            self?.apply(original: original, edited: edited, watch: watch)
        }
    }

    /// Main thread: learn new corrections, and withdraw ones that were edited again.
    private func apply(original: String, edited: String, watch: Watch) {
        let corrections = CorrectionAnalyzer.corrections(original: original, edited: edited,
                                                         isRealWord: SpellingOracle.isRealWord)
        let wanted = Dictionary(corrections.map { ($0.heard, $0) }, uniquingKeysWith: { first, _ in first })

        for (heard, record) in watch.learned where wanted[heard]?.corrected != record.corrected {
            record.ids.forEach { dictionary.delete(id: $0) }
            watch.learned[heard] = nil
            recentlyLearned.removeAll { $0 == record.corrected }
        }
        var announced: [String] = []
        for correction in corrections where watch.learned[correction.heard] == nil {
            let ids = store(correction)
            guard !ids.isEmpty else { continue }
            watch.learned[correction.heard] = (correction.corrected, ids)
            announced.append(correction.corrected)
        }
        if let id = watch.transcriptID, edited != original, !corrections.isEmpty {
            history.updateText(id: id, text: edited.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        announce(announced)
    }

    // MARK: - Learning from edits inside the app

    /// Learns from a transcript edited in the history view. Returns the spellings that were added.
    @discardableResult
    func learn(original: String, edited: String) -> [String] {
        guard settings.learnFromCorrections else { return [] }
        let corrections = CorrectionAnalyzer.corrections(original: original, edited: edited,
                                                         isRealWord: SpellingOracle.isRealWord)
        var added: [String] = []
        for correction in corrections where !store(correction).isEmpty {
            added.append(correction.corrected)
        }
        if !added.isEmpty {
            recentlyLearned = (added + recentlyLearned).prefix(8).map { $0 }
        }
        return added
    }

    // MARK: - Helpers

    /// Saves one correction. Returns the ids of the dictionary entries created.
    private func store(_ correction: LearnedCorrection) -> [Int64] {
        var ids: [Int64] = []
        let corrected = correction.corrected
        // Names and terms go into the vocabulary; ordinary words only need the fix itself.
        let isVocabulary = corrected.contains(" ") || !SpellingOracle.isRealWord(corrected)
            || corrected != corrected.lowercased()
        if isVocabulary, let id = dictionary.addTerm(corrected, source: .learned) { ids.append(id) }
        if correction.createReplacement,
           let id = dictionary.addReplacement(heard: correction.heard, phrase: corrected, source: .learned) {
            ids.append(id)
        }
        return ids
    }

    private func announce(_ learned: [String]) {
        guard let first = learned.first else { return }
        recentlyLearned = (learned + recentlyLearned).prefix(8).map { $0 }
        let label = learned.count == 1 ? "Learned “\(first)”" : "Learned \(learned.count) spellings"
        hud.showNotice(label, symbol: "character.book.closed.fill", isError: false)
        Log.info("Learned from correction: \(learned.joined(separator: ", "))")
    }

    /// Finds the dictated text in the field, preferring the spot where the cursor was.
    static func locate(_ inserted: String, in value: NSString, near expected: Int) -> NSRange? {
        let needle = inserted.trimmingCharacters(in: .whitespacesAndNewlines) as NSString
        guard needle.length > 0, value.length >= needle.length else { return nil }
        let windowStart = max(0, min(expected - 2, value.length))
        let window = NSRange(location: windowStart, length: min(value.length - windowStart, needle.length + 6))
        let nearby = value.range(of: needle as String, options: [], range: window)
        if nearby.location != NSNotFound { return nearby }
        let anywhere = value.range(of: needle as String, options: .backwards)
        return anywhere.location == NSNotFound ? nil : anywhere
    }
}
