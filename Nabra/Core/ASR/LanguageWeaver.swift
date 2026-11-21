import Foundation

/// Finds the places where one decode of a recording should borrow words from the other.
///
/// The same audio is decoded twice, once told "English" and once told "Arabic". When someone says
/// an Arabic name inside an English sentence (or an English phrase inside an Arabic one), neither
/// decode is right on its own: one mishears or translates the foreign words, the other mangles
/// everything around them. Each decode knows when every word was heard and how sure the model was,
/// so the unsure words of one can be matched by time to confident words in the other script from
/// the other. This type only proposes such swaps; the caller lets the model score the result
/// before using it.
///
/// Pure logic, no engine: covered by the self-test.
enum LanguageWeaver {
    enum Script: Equatable {
        case arabic, latin, neutral

        var opposite: Script {
            switch self {
            case .arabic: return .latin
            case .latin: return .arabic
            case .neutral: return .neutral
            }
        }
    }

    /// One word of a decode.
    struct Word: Equatable {
        /// Tokens that make up the word, including punctuation that follows it.
        var range: Range<Int>
        /// The same without the trailing punctuation.
        var body: Range<Int>
        var script: Script
        /// When the word was heard, in seconds.
        var start: Float
        var end: Float
        var center: Float
        /// False when the model's own timing for the word was unusable and the time was filled in
        /// from the words around it. That happens where a decode translates instead of transcribing.
        var timed: Bool
        /// Mean log-probability of the word's pieces under the hint it was decoded with.
        var own: Float
        /// The same without the first piece, which mostly reflects what came before the word.
        var ownTail: Float
        /// Lowest log-probability among the pieces.
        var worst: Float
        /// Mean log-probability under the other hint. NaN when that was not measured.
        var cross: Float
        var letters: Int
    }

    /// Words of `other` that should replace words of `base`.
    struct Island: Equatable {
        var base: Range<Int>
        var other: Range<Int>
    }

    struct Proposal: Equatable {
        /// The combined transcript as token ids.
        var tokenIDs: [Int32]
        var islands: [Island]
        /// Short description for the log, e.g. "Darwesh -> درويش".
        var summary: String
    }

    // Thresholds are log-probabilities (0 = certain). They were set on recordings where the right
    // answer is known; the model's own score of the combined text is the real gate.
    /// A word the other decode may lend: its pieces after the first are near certain.
    private static let strongWord: Float = -0.15
    /// A less certain word that may sit between two strong ones ("a", "the").
    private static let usableWord: Float = -0.9
    /// A word that is certain under both hints was really said that way and is never replaced.
    private static let solidWord: Float = -0.30
    /// Words are only replaced where the decode was unsure: on average, or about one piece.
    private static let unsureRun: Float = -0.25
    private static let unsurePiece: Float = -1.0
    private static let requiredImprovement: Float = 0.10
    /// Pieces of one word are at most this far apart in time; a bigger gap means the early ones are misplaced.
    private static let largestGapInsideWord: Float = 0.4
    private static let largestGapBetweenWords: Float = 0.8
    private static let leadTolerance: Float = 0.20
    /// The last piece's time is where the word starts to end; the word itself runs a little longer.
    private static let tailTolerance: Float = 0.6
    private static let minimumSharedTime: Float = 0.4
    private static let restingTime: Float = 0.12
    /// A run of confident words may end on one word this sure.
    private static let trailingWord: Float = -0.5
    private static let debug = ProcessInfo.processInfo.environment["NABRA_DEBUG_WEAVE"] != nil

    // MARK: - Words

    static func script(of text: String) -> Script {
        let counts = TextScript.letterCounts(text)
        if counts.arabic == 0, counts.latin == 0 { return .neutral }
        return counts.arabic >= counts.latin ? .arabic : .latin
    }

    /// The script most of the text's letters are in.
    static func dominantScript(_ tokens: [SpeechEngine.Token]) -> Script {
        script(of: tokens.map(\.text).joined())
    }

    /// Groups tokens into words and places each word in time.
    ///
    /// `cross` holds each token's log-probability under the other hint (same order), or is empty
    /// when that was not measured. `audioSeconds` is the length of the audio that was decoded.
    static func words(_ tokens: [SpeechEngine.Token], cross: [Float] = [], audioSeconds: Float) -> [Word] {
        var groups: [(range: Range<Int>, body: Range<Int>)] = []
        var start = 0
        var bodyEnd = 0
        var open = false
        for (index, token) in tokens.enumerated() {
            if isPunctuationOnly(token.text), open { continue }   // stays with the word before it
            if token.text.hasPrefix(" "), open {
                groups.append((start..<index, start..<bodyEnd))
                open = false
            }
            if !open {
                start = index
                open = true
            }
            bodyEnd = index + 1   // also covers letters after inner punctuation ("Whatsapp" "." "com")
        }
        if open { groups.append((start..<tokens.count, start..<bodyEnd)) }

        var words: [Word] = []
        var plausible: [Bool] = []
        for (position, group) in groups.enumerated() {
            let pieces = Array(tokens[group.body])
            let text = pieces.map(\.text).joined()
            // The opening piece of a decode is a choice among everything that could be said first,
            // so its probability says little about the word: leave it out when there is more to go on.
            let scored = position == 0 && pieces.count > 1 ? Array(pieces.dropFirst()) : pieces
            let known = scored.map(\.logProbability).filter { $0.isFinite }
            let own = known.isEmpty ? Float.nan : known.reduce(0, +) / Float(known.count)
            let tailPieces = scored.dropFirst().map(\.logProbability).filter { $0.isFinite }
            let ownTail = tailPieces.isEmpty ? own : tailPieces.reduce(0, +) / Float(tailPieces.count)
            var crossMean = Float.nan
            if cross.count == tokens.count {
                let values = cross[group.body].filter { $0.isFinite }
                if !values.isEmpty { crossMean = values.reduce(0, +) / Float(values.count) }
            }
            let letters = text.unicodeScalars.reduce(0) { $0 + ($1.properties.isAlphabetic ? 1 : 0) }
            // The very first piece of a decode has no time of its own; it is at the start.
            // Anywhere later, a time at the very start of the audio is where the model's attention
            // rests when it is not following the sound, so it tells nothing.
            var times = pieces.map(\.time).filter { $0.isFinite && (position < 2 || $0 > restingTime) }
            if position == 0, times.isEmpty { times = [0] }
            // The word is where its last pieces were heard: walk back from the final piece while
            // the pieces stay close together. Earlier strays were misplaced by the model. If most
            // of the word strayed, its time cannot be trusted at all.
            var close: [Float] = []
            for time in times.reversed() {
                if let earliest = close.last, time > earliest + 0.001 || earliest - time > largestGapInsideWord { break }
                close.append(time)
            }
            plausible.append(!close.isEmpty && close.count * 2 >= times.count)
            let low = close.last ?? 0
            let high = close.first ?? 0
            words.append(Word(range: group.range, body: group.body, script: script(of: text),
                              start: low, end: high, center: (low + high) / 2, timed: false,
                              own: own, ownTail: ownTail, worst: known.min() ?? .nan, cross: crossMean,
                              letters: letters))
        }
        placeInTime(&words, plausible: plausible, audioSeconds: audioSeconds)
        return words
    }

    /// Keeps the model's timing for the words that advance steadily through the audio and spreads
    /// the others evenly (by length) between those.
    private static func placeInTime(_ words: inout [Word], plausible: [Bool], audioSeconds: Float) {
        guard !words.isEmpty else { return }
        // Longest run of plausible words whose times never go backwards.
        var length = [Int](repeating: 0, count: words.count)
        var previous = [Int](repeating: -1, count: words.count)
        var best = -1
        for index in words.indices where plausible[index] {
            length[index] = 1
            for earlier in 0..<index where plausible[earlier] && words[earlier].center <= words[index].center + 0.001 {
                if length[earlier] + 1 > length[index] {
                    length[index] = length[earlier] + 1
                    previous[index] = earlier
                }
            }
            if best < 0 || length[index] > length[best] { best = index }
        }
        var cursor = best
        while cursor >= 0 {
            words[cursor].timed = true
            cursor = previous[cursor]
        }

        var index = 0
        while index < words.count {
            guard !words[index].timed else { index += 1; continue }
            var end = index
            while end < words.count, !words[end].timed { end += 1 }
            let from = index > 0 ? words[index - 1].end : 0
            let to = max(from, end < words.count ? words[end].start : max(audioSeconds, from))
            let total = Float(words[index..<end].reduce(0) { $0 + max($1.letters, 1) })
            var position = from
            for filled in index..<end {
                let share = (to - from) * Float(max(words[filled].letters, 1)) / total
                words[filled].start = position
                words[filled].end = position + share
                words[filled].center = position + share / 2
                position += share
            }
            index = end
        }
    }

    private static func isPunctuationOnly(_ text: String) -> Bool {
        var sawSomething = false
        for scalar in text.unicodeScalars where scalar != " " {
            sawSomething = true
            if scalar.properties.isAlphabetic || scalar.properties.numericType != nil { return false }
        }
        return sawSomething
    }

    // MARK: - Proposal

    /// Everything found for one pair of decodes.
    struct Candidates {
        var base: [SpeechEngine.Token]
        var other: [SpeechEngine.Token]
        var baseWords: [Word]
        var otherWords: [Word]
        /// Possible swaps, apart from each other and in the order they occur.
        var islands: [Island]
    }

    /// Looks for unsure words in `base` that line up in time with confident words of the other
    /// script in `other`. `baseCross` (log-probability of each base token under the other hint)
    /// may be empty; with it, words that are certain under both hints are never touched.
    static func find(base: [SpeechEngine.Token], baseCross: [Float] = [], other: [SpeechEngine.Token],
                     audioSeconds: Float) -> Candidates? {
        let baseWords = words(base, cross: baseCross, audioSeconds: audioSeconds)
        let otherWords = words(other, audioSeconds: audioSeconds)
        guard !baseWords.isEmpty, !otherWords.isEmpty else { return nil }
        let home = dominantScript(base)
        guard home != .neutral else { return nil }
        let foreign = home.opposite

        var islands: [Island] = []
        var index = 0
        var claimed: Int?   // last word of `other` already used by a run
        while index < otherWords.count {
            guard isStrong(otherWords[index], script: foreign) else { index += 1; continue }
            // A run starts and ends on a confident word; one less certain word in between ("a",
            // "the") does not break it.
            var first = index
            // A one-piece word right before it has only its opening probability to go by, which is
            // low wherever the script changes: take it along if it is not a wild guess.
            if index > 0, otherWords[index - 1].body.count == 1, otherWords[index - 1].script == foreign,
               otherWords[index - 1].own.isFinite, otherWords[index - 1].own > trailingWord,
               claimed.map({ $0 < index - 1 }) ?? true {
                first = index - 1
            }
            var end = index + 1
            while end < otherWords.count {
                if isStrong(otherWords[end], script: foreign) {
                    end += 1
                } else if end + 1 < otherWords.count, isUsable(otherWords[end], script: foreign),
                          isStrong(otherWords[end + 1], script: foreign) {
                    end += 2
                } else {
                    break
                }
            }
            // The last word of a phrase is often said with less emphasis ("... educational system.").
            if end < otherWords.count, otherWords[end].script == foreign, otherWords[end].own.isFinite,
               otherWords[end].own > trailingWord {
                end += 1
            }
            if let island = island(for: first..<end, otherWords: otherWords, otherTokens: other, baseWords: baseWords,
                                   home: home, audioSeconds: audioSeconds) {
                islands.append(island)
            }
            claimed = end - 1
            index = end
        }
        if debug {
            func describe(_ words: [Word], _ tokens: [SpeechEngine.Token]) -> String {
                words.map { word in
                    String(format: "%@[%.2f-%.2f%@ own %.2f tail %.2f cross %.2f]",
                           tokens[word.body].map(\.text).joined().trimmingCharacters(in: .whitespaces), word.start, word.end,
                           word.timed ? "" : "~", word.own, word.ownTail, word.cross)
                }.joined(separator: " ")
            }
            fputs("weave base:  \(describe(baseWords, base))\nweave other: \(describe(otherWords, other))\n", stderr)
            fputs("weave islands: \(islands.map { "base \($0.base) <- other \($0.other)" })\n", stderr)
        }
        guard !islands.isEmpty else { return nil }

        // Keep islands in order and apart.
        islands.sort { $0.base.lowerBound < $1.base.lowerBound }
        var kept: [Island] = []
        for island in islands where kept.last.map({ $0.base.upperBound <= island.base.lowerBound }) ?? true {
            kept.append(island)
        }
        return Candidates(base: base, other: other, baseWords: baseWords, otherWords: otherWords, islands: kept)
    }

    /// The base transcript with the given islands swapped in.
    static func splice(_ candidates: Candidates, islands: [Island]) -> Proposal {
        let base = candidates.base
        let other = candidates.other
        var ids: [Int32] = []
        var parts: [String] = []
        var cursor = 0
        for island in islands.sorted(by: { $0.base.lowerBound < $1.base.lowerBound }) {
            let firstBase = candidates.baseWords[island.base.lowerBound]
            let lastBase = candidates.baseWords[island.base.upperBound - 1]
            ids += base[cursor..<firstBase.range.lowerBound].map(\.id)
            let otherTokens = candidates.otherWords[island.other.lowerBound].range.lowerBound
                ..< candidates.otherWords[island.other.upperBound - 1].body.upperBound
            ids += other[otherTokens].map(\.id)
            // Punctuation that followed the replaced words stays.
            ids += base[lastBase.body.upperBound..<lastBase.range.upperBound].map(\.id)
            cursor = lastBase.range.upperBound
            let from = base[firstBase.range.lowerBound..<lastBase.body.upperBound].map(\.text).joined()
            let to = other[otherTokens].map(\.text).joined()
            parts.append("\(from.trimmingCharacters(in: .whitespaces)) -> \(to.trimmingCharacters(in: .whitespaces))")
        }
        ids += base[cursor...].map(\.id)
        return Proposal(tokenIDs: ids, islands: islands, summary: parts.joined(separator: "; "))
    }

    /// Convenience: all islands found, swapped in at once.
    static func propose(base: [SpeechEngine.Token], baseCross: [Float] = [], other: [SpeechEngine.Token],
                        audioSeconds: Float) -> Proposal? {
        find(base: base, baseCross: baseCross, other: other, audioSeconds: audioSeconds).map {
            splice($0, islands: $0.islands)
        }
    }

    private static func isStrong(_ word: Word, script: Script) -> Bool {
        word.script == script && word.letters >= 2 && word.ownTail.isFinite && word.ownTail > strongWord
            && word.own > usableWord
    }

    private static func isUsable(_ word: Word, script: Script) -> Bool {
        (word.script == script || word.script == .neutral) && word.own.isFinite && word.own > usableWord
    }

    /// A word the model is sure about whichever language it is told: it was really said that way.
    private static func isSolid(_ word: Word) -> Bool {
        guard word.own.isFinite else { return false }
        if word.cross.isFinite { return word.own > solidWord && word.cross > solidWord }
        return word.own > solidWord / 2 && word.worst > unsurePiece / 2
    }

    private static func island(for run: Range<Int>, otherWords: [Word], otherTokens: [SpeechEngine.Token],
                               baseWords: [Word], home: Script, audioSeconds: Float) -> Island? {
        guard let span = heardSpan(of: run, words: otherWords, tokens: otherTokens) else { return nil }
        // The run owns the time up to the next word its own decode really heard, within reason.
        let nextStart = otherWords[run.upperBound...].first(where: \.timed)?.start ?? audioSeconds
        let from = span.start - leadTolerance
        let limit = max(span.end, min(nextStart, span.end + tailTolerance))

        let inside = baseWords.indices.filter { index in
            let word = baseWords[index]
            if word.timed || word.end <= word.start { return word.center >= from && word.center <= limit }
            // A word placed by filling in belongs here when at least half of it falls in the window.
            return min(word.end, limit) - max(word.start, from) >= (word.end - word.start) / 2
        }
        guard var lower = inside.first, var upper = inside.last.map({ $0 + 1 }) else { return nil }
        while lower < upper, isSolid(baseWords[lower]) { lower += 1 }
        while upper > lower, isSolid(baseWords[upper - 1]) { upper -= 1 }
        guard lower < upper else { return nil }
        let replaced = baseWords[lower..<upper]
        // Never drop a word that was certainly said, and do not swap words already in that script.
        guard !replaced.contains(where: isSolid), replaced.contains(where: { $0.script == home }) else { return nil }
        // The words being replaced must account for a good part of the time the new ones were
        // heard in; otherwise the new ones mostly restate words that are staying.
        let frame: Float = 0.08
        let overlap = min(replaced[upper - 1].end, limit) - max(replaced[lower].start, span.start) + frame
        guard overlap >= minimumSharedTime * (span.end - span.start + frame) else { return nil }

        let baseOwn = mean(replaced.map(\.own))
        let baseWorst = replaced.map(\.worst).filter { $0.isFinite }.min() ?? 0
        guard baseOwn < unsureRun || baseWorst < unsurePiece else { return nil }
        guard mean(otherWords[run].map(\.ownTail)) - baseOwn >= requiredImprovement else { return nil }
        return Island(base: lower..<upper, other: run)
    }

    /// When a run of words was heard, from its pieces' own times: the stretch that leads steadily
    /// up to the last piece. Earlier pieces that sit far away were misplaced by the model.
    private static func heardSpan(of run: Range<Int>, words: [Word], tokens: [SpeechEngine.Token]) -> (start: Float, end: Float)? {
        var pieces: [(time: Float, word: Int)] = []
        for index in run {
            for token in tokens[words[index].body] where token.time.isFinite {
                pieces.append((token.time, index))
            }
        }
        guard !pieces.isEmpty else {
            return (words[run.lowerBound].start, words[run.upperBound - 1].end)
        }
        // Longest stretch of pieces whose times never go backwards.
        var length = [Int](repeating: 1, count: pieces.count)
        var previous = [Int](repeating: -1, count: pieces.count)
        var best = 0
        for index in pieces.indices {
            for earlier in 0..<index where pieces[earlier].time <= pieces[index].time + 0.001 {
                if length[earlier] + 1 > length[index] {
                    length[index] = length[earlier] + 1
                    previous[index] = earlier
                }
            }
            if length[index] >= length[best] { best = index }
        }
        var chain: [(time: Float, word: Int)] = []
        var cursor = best
        while cursor >= 0 {
            chain.append(pieces[cursor])
            cursor = previous[cursor]
        }
        // `chain` runs from the last piece backwards: stop at the first jump that is too large.
        var start = chain[0].time
        var word = chain[0].word
        for piece in chain.dropFirst() {
            let allowed = piece.word == word ? largestGapInsideWord : largestGapBetweenWords
            guard start - piece.time <= allowed else { break }
            start = piece.time
            word = piece.word
        }
        return (start, chain[0].time)
    }

    private static func mean(_ values: [Float]) -> Float {
        let known = values.filter { $0.isFinite }
        return known.isEmpty ? 0 : known.reduce(0, +) / Float(known.count)
    }

    // MARK: - Scores

    /// Sum of the known log-probabilities.
    static func total(_ values: [Float]) -> Float {
        values.reduce(0) { $0 + ($1.isFinite ? $1 : 0) }
    }
}
