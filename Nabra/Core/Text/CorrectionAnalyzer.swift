import Foundation

/// Something learned from comparing dictated text with the user's corrected version.
struct LearnedCorrection: Equatable {
    /// What the recogniser wrote.
    var heard: String
    /// What the user changed it to.
    var corrected: String
    /// Whether "heard" should always be rewritten to "corrected" from now on.
    /// False when "heard" is an ordinary word that must keep working normally.
    var createReplacement: Bool
}

/// Works out which edits are spelling corrections (worth learning) and which are rewrites (not).
enum CorrectionAnalyzer {
    static func corrections(original: String, edited: String, isRealWord: (String) -> Bool) -> [LearnedCorrection] {
        let oldWords = words(original)
        let newWords = words(edited)
        guard !oldWords.isEmpty, !newWords.isEmpty, oldWords != newWords else { return [] }
        // Keep the comparison bounded for very long texts.
        guard oldWords.count <= 600, newWords.count <= 900 else { return [] }

        let spans = changedSpans(oldWords.map(comparable), newWords.map(comparable))
        // Only substitutions count. Text added or removed around the dictation is not a correction.
        let substitutions = spans.filter { !$0.old.isEmpty && !$0.new.isEmpty }
        guard !substitutions.isEmpty else { return [] }
        let changedWords = substitutions.reduce(0) { $0 + $1.old.count }
        if substitutions.count > 4 || Double(changedWords) > max(3, Double(oldWords.count) * 0.4) { return [] }

        var learned: [LearnedCorrection] = []
        for span in substitutions {
            guard span.old.count <= 3, span.new.count <= 3 else { continue }
            let heard = oldWords[span.old].map(strip).joined(separator: " ")
            let corrected = newWords[span.new].map(strip).joined(separator: " ")
            guard !heard.isEmpty, !corrected.isEmpty, heard != corrected else { continue }
            guard heard.contains(where: \.isLetter), corrected.contains(where: \.isLetter) else { continue }
            guard looksLikeCorrection(heard: heard, corrected: corrected) else { continue }

            let heardIsOrdinary = span.old.count == 1 && isRealWord(heard)
            let correctedIsOrdinary = span.new.count == 1 && isRealWord(corrected)
                && corrected == corrected.lowercased() && !TextScript.containsArabic(corrected)
            // Swapping one ordinary word for another ("there" → "their") teaches nothing reusable.
            if heardIsOrdinary && correctedIsOrdinary { continue }
            // Case-only fixes of ordinary words at sentence starts are not vocabulary.
            if TextScript.fold(heard) == TextScript.fold(corrected), correctedIsOrdinary { continue }

            learned.append(LearnedCorrection(heard: heard, corrected: corrected, createReplacement: !heardIsOrdinary))
        }
        return learned
    }

    /// A correction keeps most of the sound of the word; a rewrite does not.
    static func looksLikeCorrection(heard: String, corrected: String) -> Bool {
        let a = TextScript.lettersOnly(heard)
        let b = TextScript.lettersOnly(corrected)
        guard !a.isEmpty, !b.isEmpty else { return false }
        if a == b { return true }                               // casing, spacing or diacritics only
        let aArabic = TextScript.containsArabic(a)
        let bArabic = TextScript.containsArabic(b)
        if aArabic != bArabic {                                  // same word written in the other script
            return heard.split(separator: " ").count <= 2 && corrected.split(separator: " ").count <= 2
        }
        let similarity = TextScript.similarity(a, b)
        if similarity >= 0.55 { return true }
        return similarity >= 0.4 && consonantSkeleton(a) == consonantSkeleton(b)
    }

    /// Crude phonetic key: drops vowels and repeated letters.
    static func consonantSkeleton(_ text: String) -> String {
        let vowels = Set("aeiouyاويى")
        var result = ""
        for character in text where !vowels.contains(character) {
            if result.last != character { result.append(character) }
        }
        return result
    }

    // MARK: - Diff

    struct Span: Equatable {
        var old: Range<Int>
        var new: Range<Int>
    }

    /// Maximal runs where the two word lists differ, found with a longest-common-subsequence alignment.
    static func changedSpans(_ a: [String], _ b: [String]) -> [Span] {
        let n = a.count
        let m = b.count
        var table = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        if n > 0, m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    table[i][j] = a[i] == b[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
                }
            }
        }
        var spans: [Span] = []
        var i = 0
        var j = 0
        var startI = 0
        var startJ = 0
        var inSpan = false
        func close(_ endI: Int, _ endJ: Int) {
            if inSpan { spans.append(Span(old: startI..<endI, new: startJ..<endJ)) }
        }
        while i < n || j < m {
            if i < n, j < m, a[i] == b[j] {
                close(i, j)
                inSpan = false
                i += 1
                j += 1
            } else {
                if !inSpan {
                    inSpan = true
                    startI = i
                    startJ = j
                }
                if j < m, i == n || table[i][j + 1] >= table[i + 1][j] {
                    j += 1
                } else {
                    i += 1
                }
            }
        }
        close(n, m)
        return spans
    }

    private static func words(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    /// Form used for alignment: punctuation at the edges does not matter, case does.
    private static func comparable(_ word: String) -> String {
        strip(word)
    }

    private static let edgePunctuation = CharacterSet(charactersIn: ".,!?;:،؛؟…\"'“”‘’()[]{}«»")

    private static func strip(_ word: String) -> String {
        word.trimmingCharacters(in: edgePunctuation)
    }
}
