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
        var element: AXUIElement
        let pid: pid_t
        let inserted: String
        let transcriptID: Int64?
        var lastValue: NSString = ""
        var lastChange = Date()
        /// The dictation as it last appeared in the field, and where.
        var lastRegion: String?
        var lastRegionLocation = 0
        /// The version already handed over for learning.
        var analyzedRegion: String?
        var longestValue = 0
        let started = Date()
        /// heard → ids of the dictionary entries created for it during this watch (main thread).
        var learned: [String: (corrected: String, ids: [Int64])] = [:]
        // For the log.
        var appName = "this app"
        var role = "?"
        var unreadablePolls = 0

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
    private static let settleSeconds: TimeInterval = 0.9
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
              !CorrectionLearner.ignoredApps.contains(context.bundleID ?? ""),
              TextScript.wordCount(inserted) >= 1
        else { return }
        guard let element = context.element else {
            Log.info("Learning: no focused field to watch in \(context.appName ?? "this app")")
            return
        }
        // The field's text may only become readable a moment after the paste; the first polls retry.

        let watch = Watch(element: element, pid: context.processID, inserted: inserted, transcriptID: transcriptID)
        watch.appName = context.appName ?? "this app"
        watch.role = context.role ?? "?"
        current = watch
        let expectedLocation = context.selection?.location ?? 0

        let timer = DispatchSource.makeTimerSource(queue: Accessibility.queue)
        // Give the paste a moment to land before taking the baseline.
        timer.schedule(deadline: .now() + .milliseconds(500), repeating: .milliseconds(450), leeway: .milliseconds(100))
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
        guard finalize else { return }
        Accessibility.queue.async { [weak self] in
            guard let self else { return }
            // One last look, then judge the last version of the dictation that was seen (the field may
            // have been sent and cleared by now).
            if let text = Accessibility.currentText(of: watch.element) { self.observe(watch, value: CorrectionLearner.normalized(text.value as NSString)) }
            if watch.lastRegion == nil {
                Log.info("Learning: the dictation was never found in the field, corrections there are not learned "
                    + "(\(watch.appName), \(watch.role), \(watch.longestValue) characters)")
                return
            }
            self.analyzeLatest(watch, final: true)
        }
    }

    /// Runs on `Accessibility.queue`.
    private func poll(_ watch: Watch, expectedLocation: Int) {
        func stop(_ reason: String?) {
            if let reason { Log.info("Learning: \(reason) (\(watch.appName), \(watch.role))") }
            DispatchQueue.main.async { [weak self] in
                if self?.current === watch { self?.stopWatching(finalize: true) }
            }
        }
        guard Date().timeIntervalSince(watch.started) < CorrectionLearner.watchSeconds else { return stop(nil) }
        if !Accessibility.isStillFocused(watch.element, pid: watch.pid) {
            // Web pages often replace the element that has the focus while you type. If the field that
            // has the focus now still holds the dictation, follow it.
            guard let replacement = Accessibility.focusedElement(pid: watch.pid),
                  let text = Accessibility.currentText(of: replacement),
                  CorrectionLearner.region(of: watch.inserted, in: CorrectionLearner.normalized(text.value as NSString),
                                           near: expectedLocation) != nil
            else { return stop(watch.lastRegion == nil ? "stopped watching, the field lost the focus" : nil) }
            watch.element = replacement
        }
        guard let text = Accessibility.currentText(of: watch.element) else {
            watch.unreadablePolls += 1
            if watch.unreadablePolls >= 3 { stop("cannot read the text of this field, corrections there are not learned") }
            return
        }
        let value = CorrectionLearner.normalized(text.value as NSString)
        let changed = observe(watch, value: value, near: text.selection?.location ?? expectedLocation)
        if changed { return }
        // The text has stopped changing for a moment: see what became of the dictation.
        guard Date().timeIntervalSince(watch.lastChange) >= CorrectionLearner.settleSeconds else { return }
        analyzeLatest(watch, final: false)
    }

    /// Records what the field holds now and where the dictation is in it. Returns true when the field
    /// changed since the last look. Runs on `Accessibility.queue`.
    @discardableResult
    private func observe(_ watch: Watch, value: NSString, near: Int? = nil) -> Bool {
        watch.longestValue = max(watch.longestValue, value.length)
        guard !value.isEqual(to: watch.lastValue as String) else { return false }
        watch.lastValue = value
        watch.lastChange = Date()
        if let range = CorrectionLearner.region(of: watch.inserted, in: value, near: near ?? watch.lastRegionLocation) {
            watch.lastRegion = value.substring(with: range)
            watch.lastRegionLocation = range.location
        }
        return true
    }

    /// Hands the latest version of the dictation, if it changed since last time, to the main thread.
    private func analyzeLatest(_ watch: Watch, final: Bool) {
        guard let region = watch.lastRegion, region != watch.analyzedRegion else { return }
        watch.analyzedRegion = region
        let original = watch.inserted
        DispatchQueue.main.async { [weak self] in
            self?.apply(original: original, edited: region, watch: watch, final: final)
        }
    }

    /// Main thread: learn new corrections, and withdraw ones that were edited again.
    private func apply(original: String, edited: String, watch: Watch, final: Bool) {
        let corrections = CorrectionAnalyzer.corrections(original: original, edited: edited,
                                                         isRealWord: SpellingOracle.isRealWord)
        if corrections.isEmpty, final, watch.learned.isEmpty, edited != original {
            Log.info("Learning: the dictation was edited, but no word was replaced by a similar spelling (\(watch.appName))")
        }
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

    /// Finds the dictated text in the field, preferring the spot where the cursor was. Spacing may
    /// differ from what was pasted (editors turn spaces into non-breaking ones, or paragraph breaks
    /// into single line breaks), so any run of white space matches any other.
    static func locate(_ inserted: String, in value: NSString, near expected: Int) -> NSRange? {
        let words = normalized(inserted as NSString).components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        guard !words.isEmpty else { return nil }
        let pattern = words.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "\\s+")
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let haystack = normalized(value) as String
        let matches = regex.matches(in: haystack, range: NSRange(location: 0, length: (haystack as NSString).length))
        guard !matches.isEmpty else { return nil }
        // The one closest to where the cursor was.
        return matches.min { abs($0.range.location - expected) < abs($1.range.location - expected) }?.range
    }

    /// Where the dictated text is in the field now, even after edits: its words are aligned with the
    /// field's words (Smith-Waterman on folded words), so a changed word, or edits elsewhere in the
    /// field, still leave it findable. A changed first or last word is included. Nil when most of
    /// the dictation is gone (the message was sent, or rewritten).
    static func region(of inserted: String, in value: NSString, near expected: Int) -> NSRange? {
        let needle = words(in: inserted as NSString)
        var hay = words(in: value)
        guard !needle.isEmpty, !hay.isEmpty else { return nil }
        // In a long document, look around the cursor only.
        if hay.count > 3000 {
            let center = hay.firstIndex { $0.range.location >= expected } ?? hay.count - 1
            let lower = max(0, center - needle.count - 300)
            let upper = min(hay.count, center + needle.count + 300)
            hay = Array(hay[lower..<upper])
        }
        let n = needle.count
        let m = hay.count
        var score = [Int](repeating: 0, count: (n + 1) * (m + 1))
        var best = 0
        var bestCell = (0, 0)
        for i in 1...n {
            for j in 1...m {
                let diagonal = score[(i - 1) * (m + 1) + (j - 1)] + (needle[i - 1].folded == hay[j - 1].folded ? 2 : -1)
                let up = score[(i - 1) * (m + 1) + j] - 1
                let left = score[i * (m + 1) + (j - 1)] - 1
                let value = max(0, diagonal, up, left)
                score[i * (m + 1) + j] = value
                if value > best { best = value; bestCell = (i, j) }
            }
        }
        guard best > 0 else { return nil }
        // Walk back to where the alignment starts.
        var (i, j) = bestCell
        var matched = 0
        let endNeedle = i, endHay = j
        while i > 0, j > 0, score[i * (m + 1) + j] > 0 {
            let here = score[i * (m + 1) + j]
            if here == score[(i - 1) * (m + 1) + (j - 1)] + (needle[i - 1].folded == hay[j - 1].folded ? 2 : -1) {
                if needle[i - 1].folded == hay[j - 1].folded { matched += 1 }
                i -= 1; j -= 1
            } else if here == score[(i - 1) * (m + 1) + j] - 1 {
                i -= 1
            } else {
                j -= 1
            }
        }
        // Most of the dictation must still be there.
        guard matched >= max(1, Int((Double(n) * 0.6).rounded(.up))) else { return nil }
        // Words of the dictation left out at either end were changed: take as many field words with them.
        let first = max(0, j - i)
        let last = min(m - 1, endHay - 1 + (n - endNeedle))
        guard first <= last else { return nil }
        let start = hay[first].range.location
        let end = hay[last].range.location + hay[last].range.length
        return NSRange(location: start, length: end - start)
    }

    private struct Word {
        var range: NSRange
        var folded: String
    }

    private static let wordPattern = try? NSRegularExpression(pattern: "[\\p{L}\\p{N}][\\p{L}\\p{N}'’_@.\\-]*")

    private static func words(in text: NSString) -> [Word] {
        guard let pattern = wordPattern else { return [] }
        return pattern.matches(in: text as String, range: NSRange(location: 0, length: text.length)).map { match in
            let raw = text.substring(with: match.range).trimmingCharacters(in: CharacterSet(charactersIn: ".-'’_"))
            return Word(range: match.range, folded: TextScript.fold(raw))
        }
    }

    /// The same text with the spacing editors substitute turned back into plain spaces and line
    /// breaks. Every replacement keeps the length, so positions stay valid.
    static func normalized(_ text: NSString) -> NSString {
        var result = text as String
        for (from, to) in [("\u{00A0}", " "), ("\u{202F}", " "), ("\u{2007}", " "), ("\r", "\n"), ("\u{2028}", "\n"), ("\u{2029}", "\n")] {
            result = result.replacingOccurrences(of: from, with: to)
        }
        return result as NSString
    }

    /// True when two versions of a field share most of their text (the same field, re-created).
    static func overlaps(_ a: NSString, _ b: NSString) -> Bool {
        guard a.length > 0, b.length > 0 else { return false }
        let shorter = min(a.length, b.length)
        let prefix = a.commonPrefix(with: b as String).count
        return Double(prefix) >= Double(shorter) * 0.5
    }
}
