import Foundation

/// Optional second pass that applies spoken self-corrections ("at two, no, three" → "at three").
///
/// It only runs when a dictation actually contains a correction cue (or when the user asks for every
/// dictation to be polished), so ordinary dictation stays instant.
final class SmartCleanup {
    /// The component that rewrites text. Nil when no language model is installed.
    var rewriter: TextRewriter?

    var isAvailable: Bool { rewriter?.isReady ?? false }

    func shouldPolish(_ text: String, mode: CleanupMode) -> Bool {
        guard let rewriter, rewriter.canRewrite(text) else { return false }
        switch mode {
        case .off: return false
        case .always: return TextScript.wordCount(text) >= 3
        case .smart: return SmartCleanup.containsCorrectionCue(text)
        }
    }

    /// Returns the polished text, or nil when polishing failed or looked unsafe (the caller keeps the original).
    func polish(_ text: String, vocabulary: [String], completion: @escaping (String?) -> Void) {
        guard let rewriter else {
            completion(nil)
            return
        }
        rewriter.rewrite(text, vocabulary: vocabulary) { candidate in
            guard let candidate, SmartCleanup.isFaithful(original: text, rewritten: candidate) else {
                if let candidate { Log.info("Rewrite rejected as unfaithful: \(candidate.prefix(120))") }
                completion(nil)
                return
            }
            completion(candidate == text ? nil : candidate)
        }
    }

    // MARK: - Cue detection

    /// Phrases people use to take back what they just said. Deliberately specific: bare "actually"
    /// or "sorry" are everyday words and would send ordinary sentences through the slow path.
    private static let englishCues = [
        "no actually", "actually no", "no wait", "wait no", "oh wait", "no sorry", "sorry i meant", "sorry i mean",
        "i mean", "i meant", "scratch that", "strike that", "delete that", "or rather", "let me rephrase",
        "correction", "never mind", "make that", "no no",
    ]
    private static let arabicCues = [
        "لا لا", "قصدي", "أقصد", "اقصد", "بقصد", "بالأحرى", "بالاحرى", "استنى", "استني", "لحظة",
        "عفوا", "مش هيك", "لا مش", "يعني لا", "امسح", "احذف", "شيل هاد",
    ]
    private static let cues: [[String]] = (englishCues + arabicCues).map { words(TextScript.fold($0)) }

    /// Positions (as word index ranges) of every correction phrase in `text`.
    private static func cueRanges(in tokens: [String]) -> [Range<Int>] {
        var found: [Range<Int>] = []
        for cue in cues where !cue.isEmpty && tokens.count >= cue.count {
            for start in 0...(tokens.count - cue.count) where Array(tokens[start..<(start + cue.count)]) == cue {
                found.append(start..<(start + cue.count))
            }
        }
        return found.sorted { $0.lowerBound < $1.lowerBound }
    }

    /// True when the text contains a phrase people use while correcting themselves.
    static func containsCorrectionCue(_ text: String) -> Bool {
        !cueRanges(in: words(TextScript.fold(text))).isEmpty
    }

    // MARK: - Safety

    /// Accepts a rewrite only if it is what a self-correction looks like and nothing more:
    /// - it invents no words and keeps the original order,
    /// - the correcting phrase itself is gone,
    /// - everything said after that phrase (the corrected version) is still there,
    /// - and the only words removed sit right around the correcting phrase.
    /// Anything else (an answer, a translation, a summary, dropped content) is rejected and the
    /// dictation is used exactly as spoken.
    static func isFaithful(original: String, rewritten: String) -> Bool {
        let before = words(TextScript.fold(original))
        let after = words(TextScript.fold(rewritten))
        guard !before.isEmpty, !after.isEmpty else { return false }
        if after.count > before.count + 2 { return false }
        if Double(after.count) < Double(before.count) * 0.3 { return false }

        // No new words (digits are allowed: "three" may become "3").
        let available = Set(before)
        let spoken = after.filter { !$0.allSatisfy(\.isNumber) }
        if spoken.contains(where: { !available.contains($0) }) { return false }

        // Same order.
        let kept = alignment(original: before, rewritten: spoken)
        if Double(kept.count) < Double(spoken.count) * 0.8 { return false }

        // Same balance of Arabic and Latin letters (catches translation).
        if abs(share(TextScript.letterCounts(original)) - share(TextScript.letterCounts(rewritten))) > 0.25 { return false }

        let cueSpots = cueRanges(in: before)
        guard !cueSpots.isEmpty else {
            // "Always polish" on a sentence without a correction: only light touch-ups are acceptable.
            return before.count - kept.count <= max(2, before.count / 6)
        }
        // The correcting phrase must be gone.
        if !cueRanges(in: after).isEmpty { return false }

        // What was said after the last correcting phrase must survive (a couple of lead-in words
        // such as "make it" may go).
        let tail = Array(before[cueSpots[cueSpots.count - 1].upperBound...])
        if tail.count > 3 {
            let mustKeep = tail.dropFirst(3).filter { !$0.allSatisfy(\.isNumber) }
            let keptWords = Set(kept.map { before[$0] })
            let missing = mustKeep.filter { !keptWords.contains($0) }
            if Double(missing.count) > Double(mustKeep.count) * 0.1 { return false }
        }

        // Every removed word must be close to a correcting phrase: up to ten words before it
        // (the part being taken back), the phrase itself, or three words after it.
        let keptSet = Set(kept)
        for index in before.indices where !keptSet.contains(index) {
            let near = cueSpots.contains { index >= $0.lowerBound - 10 && index < $0.upperBound + 3 }
            if !near { return false }
        }
        return true
    }

    /// Indices of `original` matched, in order, by the words of `rewritten` (longest common subsequence).
    private static func alignment(original: [String], rewritten: [String]) -> [Int] {
        let n = original.count
        let m = rewritten.count
        guard n > 0, m > 0 else { return [] }
        var table = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                table[i][j] = original[i] == rewritten[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var matched: [Int] = []
        var i = 0
        var j = 0
        while i < n, j < m {
            if original[i] == rewritten[j] {
                matched.append(i)
                i += 1
                j += 1
            } else if table[i + 1][j] > table[i][j + 1] {
                i += 1
            } else {
                // On ties prefer skipping a rewritten word, so matches land as late in the original as
                // possible: repeated words then align with the corrected (later) occurrence.
                j += 1
            }
        }
        return matched
    }

    private static func words(_ text: String) -> [String] {
        text.split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "'") }).map(String.init)
    }

    private static func share(_ counts: (arabic: Int, latin: Int)) -> Double {
        let total = counts.arabic + counts.latin
        return total == 0 ? 0 : Double(counts.arabic) / Double(total)
    }
}

/// Something that can rewrite a transcript (a local language model).
protocol TextRewriter: AnyObject {
    var isReady: Bool { get }
    /// Whether this rewriter can handle `text` (for example, its language).
    func canRewrite(_ text: String) -> Bool
    /// Warm up so the next rewrite starts quickly.
    func prepare()
    /// Calls `completion` on the main queue with the rewritten text, or nil on failure.
    func rewrite(_ text: String, vocabulary: [String], completion: @escaping (String?) -> Void)
}
