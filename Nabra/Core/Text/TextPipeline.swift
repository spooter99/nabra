import Foundation

/// Deterministic clean-up applied to every transcript. Fast (well under a millisecond) and predictable.
struct TextPipeline {
    struct Options {
        var removeFillers = true
        var voiceCommands = true
        /// Turn "first… second… third…" into a numbered list.
        var formatLists = true
        /// (what the recogniser writes, what it should be), longest first.
        var replacements: [(heard: String, phrase: String)] = []
        /// Correct spellings to snap near-misses onto.
        var vocabulary: [String] = []
        /// Returns true when `word` is an ordinary dictionary word. Used to avoid "fixing" real words.
        var isRealWord: (String) -> Bool = { _ in false }
    }

    struct Output: Equatable {
        var text: String
        /// Dictionary phrases that were applied.
        var appliedPhrases: [String] = []
    }

    static func process(_ raw: String, options: Options) -> Output {
        var text = raw.replacingOccurrences(of: "\r", with: " ")
        text = stripAnnotations(text)
        text = collapseWhitespace(text)
        if Hallucinations.isHallucination(text) { return Output(text: "") }

        if options.voiceCommands { text = applyVoiceCommands(text) }
        if options.removeFillers {
            text = removeFillers(text)
            text = collapseStutter(text)
        }
        var applied: [String] = []
        text = applyReplacements(text, options.replacements, applied: &applied)
        text = snapVocabulary(text, options.vocabulary, isRealWord: options.isRealWord, applied: &applied)
        if options.formatLists { text = formatSpokenLists(text) }
        text = tidyPunctuation(text)
        text = capitalizeStarts(text)
        return Output(text: text, appliedPhrases: applied)
    }

    // MARK: - Steps

    private static let annotationWords = [
        "blank_audio", "blank audio", "music", "applause", "laughter", "laughs", "laughing", "silence",
        "inaudible", "noise", "background noise", "sigh", "sighs", "coughs", "cough", "no audio", "no speech",
        "موسيقى", "تصفيق", "ضحك", "صمت", "موسيقي",
    ]

    /// Removes non-speech markers such as "[BLANK_AUDIO]", "(music)", "*laughs*" and musical notes.
    static func stripAnnotations(_ text: String) -> String {
        var result = text
        let alternatives = annotationWords.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
        result = replace(result, "(?i)[\\[\\(\\*]\\s*(?:\(alternatives))\\s*[\\]\\)\\*]", " ")
        result = replace(result, "[♪♫♬♩]+", " ")
        return result
    }

    static func collapseWhitespace(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n").map { line in
            replace(line, "[ \\t\\u00A0]+", " ").trimmingCharacters(in: .whitespaces)
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// "new line" / "new paragraph" (and "سطر جديد" / "فقرة جديدة") when spoken as their own phrase.
    static func applyVoiceCommands(_ text: String) -> String {
        var result = text
        let boundaryBefore = "(?:^|(?<=[.,!?;:،؛؟…]))"
        let boundaryAfter = "(?:[.,!?;:،؛؟…]+|$)"
        let commands: [(String, String)] = [
            ("new\\s+paragraph", "\n\n"), ("next\\s+paragraph", "\n\n"), ("new\\s+line", "\n"), ("next\\s+line", "\n"),
            ("فقر[ةه]\\s+جديد[ةه]", "\n\n"), ("سطر\\s+جديد", "\n"),
        ]
        for (pattern, replacement) in commands {
            result = replace(result, "(?i)\(boundaryBefore)\\s*\(pattern)\\s*\(boundaryAfter)[ \\t]*", replacement)
        }
        // A command at the very start or end leaves stray breaks behind.
        result = replace(result, "[ \\t]+\\n", "\n")
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Drops hesitation sounds: um, uh, uhm, erm and Arabic "اممم".
    static func removeFillers(_ text: String) -> String {
        var result = text
        let english = "(?:u+m+|u+h+|u+h+m+|e+r+m+|h+m+m+m+)"
        result = replace(result, "(?i)(?<![\\p{L}\\p{N}'’-])\(english)(?![\\p{L}\\p{N}'’-])[,.…]*\\s*", "")
        let arabic = "(?:[اأإآ]?م{2,}|[اآ]{3,}|[إاأ]م+م)"
        result = replace(result, "(?<![\\p{L}\\p{N}])\(arabic)(?![\\p{L}\\p{N}])[،,.…]*\\s*", "")
        return result
    }

    /// Collapses stuttered function words ("I I think", "the the").
    static func collapseStutter(_ text: String) -> String {
        let words = "i|the|a|an|to|and|of|in|we|so|but|it's|i'm"
        return replace(text, "(?i)(?<![\\p{L}\\p{N}'’])(\(words))(?:[,]?\\s+\\1)+(?![\\p{L}\\p{N}'’])", "$1")
    }

    static func applyReplacements(_ text: String,
                                  _ replacements: [(heard: String, phrase: String)],
                                  applied: inout [String]) -> String {
        var result = text
        for item in replacements.sorted(by: { $0.heard.count > $1.heard.count }) {
            let heard = item.heard.trimmingCharacters(in: .whitespaces)
            guard !heard.isEmpty else { continue }
            // Allow any run of whitespace where the heard phrase has a space.
            let core = heard.split(separator: " ").map { NSRegularExpression.escapedPattern(for: String($0)) }
                .joined(separator: "\\s+")
            let pattern = "(?i)(?<![\\p{L}\\p{N}])\(core)(?![\\p{L}\\p{N}])"
            let replaced = replace(result, pattern, NSRegularExpression.escapedTemplate(for: item.phrase))
            if replaced != result {
                applied.append(item.phrase)
                result = replaced
            }
        }
        return result
    }

    /// Snaps words that are almost a dictionary phrase onto its exact spelling
    /// ("Darwesh" or "Dar Wish" → "Darwish"), without touching ordinary words.
    static func snapVocabulary(_ text: String,
                               _ vocabulary: [String],
                               isRealWord: (String) -> Bool,
                               applied: inout [String]) -> String {
        guard !vocabulary.isEmpty, !text.isEmpty else { return text }
        var tokens = tokenize(text)
        let wordIndices = tokens.indices.filter { tokens[$0].isWord }
        guard !wordIndices.isEmpty else { return text }

        for phrase in vocabulary.sorted(by: { $0.count > $1.count }) {
            let target = TextScript.lettersOnly(phrase)
            guard target.unicodeScalars.count >= 4 else { continue }
            let phraseWordCount = max(1, phrase.split(separator: " ").count)
            // Compare against windows of the same size, one smaller and one larger (splits and merges).
            for size in Set([phraseWordCount, phraseWordCount + 1, max(1, phraseWordCount - 1)]).sorted(by: >) {
                var position = 0
                let live = tokens.indices.filter { tokens[$0].isWord && !tokens[$0].consumed }
                while position + size <= live.count {
                    let window = Array(live[position..<(position + size)])
                    // Words must be adjacent (only whitespace between them).
                    let contiguous = zip(window, window.dropFirst()).allSatisfy { first, second in
                        tokens[(first + 1)..<second].allSatisfy { $0.text.allSatisfy(\.isWhitespace) }
                    }
                    guard contiguous else { position += 1; continue }
                    let original = window.map { tokens[$0].text }.joined(separator: " ")
                    let candidate = TextScript.lettersOnly(original)
                    var matches = false
                    var replacement = phrase
                    if candidate == target {
                        matches = original != phrase
                    } else if size == 1, let prefix = attachedArabicPrefix(original, target: target) {
                        // "بمرعى" with "مرعي" in the dictionary: fix the name, keep the attached particle.
                        replacement = prefix + phrase
                        matches = original != replacement
                    } else if candidate.unicodeScalars.count >= 4 {
                        // A near miss ("Darwesh" for "Darwish"). Only when nothing in what was written is an
                        // ordinary word, so real vocabulary is never overwritten.
                        let similarity = TextScript.similarity(candidate, target)
                        let sameStart = candidate.unicodeScalars.first == target.unicodeScalars.first
                        let closeEnough = similarity >= 0.85 || (sameStart && similarity >= 0.72)
                        if closeEnough {
                            matches = window.allSatisfy { !isRealWord(tokens[$0].text) }
                        }
                    }
                    if matches {
                        tokens[window[0]].text = replacement
                        tokens[window[0]].consumed = true
                        if let last = window.last, last > window[0] {
                            for index in (window[0] + 1)...last { tokens[index].text = ""; tokens[index].consumed = true }
                        }
                        if !applied.contains(phrase) { applied.append(phrase) }
                        position += size
                    } else {
                        position += 1
                    }
                }
            }
        }
        return tokens.map(\.text).joined()
    }

    // MARK: - Spoken lists

    /// Words that announce a list item, with the position they stand for. 0 means "the last one".
    private static let listMarkers: [(pattern: String, position: Int)] = [
        ("first(?:ly)?(?:\\s+of\\s+all)?", 1), ("second(?:ly)?", 2), ("third(?:ly)?", 3), ("fourth(?:ly)?", 4),
        ("fifth(?:ly)?", 5), ("sixth(?:ly)?", 6), ("seventh(?:ly)?", 7), ("eighth(?:ly)?", 8), ("ninth(?:ly)?", 9),
        ("tenth(?:ly)?", 10),
        ("number\\s+one", 1), ("number\\s+two", 2), ("number\\s+three", 3), ("number\\s+four", 4),
        ("number\\s+five", 5), ("number\\s+six", 6), ("number\\s+seven", 7), ("number\\s+eight", 8),
        ("finally", 0), ("lastly", 0), ("last(?:\\s+one)?", 0),
        ("[أا]ول[اً]{1,2}", 1), ("ثاني[اً]{1,2}", 2), ("ثالث[اً]{1,2}", 3), ("رابع[اً]{1,2}", 4), ("خامس[اً]{1,2}", 5),
        ("سادس[اً]{1,2}", 6), ("سابع[اً]{1,2}", 7),
        ("[أا]ول\\s+(?:شي|شيء|اشي|إشي)", 1), ("[ثت]اني\\s+(?:شي|شيء|اشي|إشي)", 2), ("[ثت]الت?ث?\\s+(?:شي|شيء|اشي|إشي)", 3),
        ("رابع\\s+(?:شي|شيء|اشي|إشي)", 4), ("خامس\\s+(?:شي|شيء|اشي|إشي)", 5),
        ("رقم\\s+واحد", 1), ("رقم\\s+(?:اثنين|ثنين|اتنين)", 2), ("رقم\\s+(?:ثلاث[ةه]|تلات[ةه])", 3), ("رقم\\s+[أا]ربع[ةه]", 4),
        ("[أا]خير[اً]{1,2}", 0), ("[آا]خر\\s+(?:شي|شيء|اشي|إشي)", 0),
    ]

    /// Rewrites an explicit spoken enumeration as a numbered list:
    /// "Three things. First, milk. Second, eggs. Third, bread." becomes
    /// "Three things.\n1. Milk\n2. Eggs\n3. Bread".
    /// Only fires when the markers come in order starting from "first", so ordinary prose is untouched.
    static func formatSpokenLists(_ text: String) -> String {
        struct Hit {
            var range: Range<String.Index>
            var position: Int
        }
        // A marker counts only at the start of a clause, optionally after "and" / "و".
        let boundary = "(?:^|(?<=[.!?:;،؛؟\\n])|(?<=,))"
        var hits: [Hit] = []
        for marker in listMarkers {
            // English ordinals double as ordinary adjectives ("first point"), so they only count when
            // followed by a comma or colon. The Arabic adverb forms are unambiguous.
            let isArabic = TextScript.containsArabic(marker.pattern)
            let separator = isArabic ? "[ \\t]*[,:.،-]?[ \\t]+" : "[ \\t]*[,:][ \\t]*"
            let pattern = "(?i)\(boundary)[ \\t]*(?:and[ \\t]+|و[ \\t]*)?(?:\(marker.pattern))(?![\\p{L}\\p{N}])\(separator)"
            guard let regex = regex(pattern) else { continue }
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let range = Range(match.range, in: text) else { continue }
                hits.append(Hit(range: range, position: marker.position))
            }
        }
        guard hits.count >= 2 else { return text }
        hits.sort { $0.range.lowerBound < $1.range.lowerBound }
        // Drop overlapping matches ("أول" inside "أول شي"): keep the longer one.
        var distinct: [Hit] = []
        for hit in hits {
            if let last = distinct.last, hit.range.lowerBound < last.range.upperBound {
                if text.distance(from: hit.range.lowerBound, to: hit.range.upperBound)
                    > text.distance(from: last.range.lowerBound, to: last.range.upperBound) {
                    distinct[distinct.count - 1] = hit
                }
            } else {
                distinct.append(hit)
            }
        }
        // The run must start at 1 and count upward; a "finally" may close it.
        guard let start = distinct.firstIndex(where: { $0.position == 1 }) else { return text }
        var run: [Hit] = [distinct[start]]
        var expected = 2
        for hit in distinct[(start + 1)...] {
            if hit.position == expected {
                run.append(hit)
                expected += 1
            } else if hit.position == 0, run.count >= 2 {
                run.append(hit)
                break
            } else {
                break
            }
        }
        guard run.count >= 2 else { return text }

        let intro = text[..<run[0].range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        var lines: [String] = []
        for (index, hit) in run.enumerated() {
            let end = index + 1 < run.count ? run[index + 1].range.lowerBound : text.endIndex
            var item = String(text[hit.range.upperBound..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            // Drop the joining "and" / comma that led into the next marker.
            item = replace(item, "(?i)[,،;؛]?\\s*(?:and|و)?\\s*$", "")
            item = item.trimmingCharacters(in: CharacterSet(charactersIn: " ,،;؛"))
            guard !item.isEmpty else { continue }
            if TextScript.wordCount(item) <= 6, item.hasSuffix(".") { item.removeLast() }
            if let first = item.first, first.isLowercase, first.isASCII { item = first.uppercased() + item.dropFirst() }
            lines.append("\(lines.count + 1). \(item)")
        }
        guard lines.count >= 2 else { return text }
        return (intro.isEmpty ? "" : intro + "\n") + lines.joined(separator: "\n")
    }

    private static let arabicPrefixes = ["وال", "بال", "فال", "كال", "لل", "ال", "و", "ف", "ب", "ل", "ك"]

    /// If `word` is an Arabic particle glued onto `target` (and/with/to/the...), returns that particle.
    private static func attachedArabicPrefix(_ word: String, target: String) -> String? {
        guard TextScript.containsArabic(word) else { return nil }
        for prefix in arabicPrefixes where word.hasPrefix(prefix) {
            let rest = String(word.dropFirst(prefix.count))
            if TextScript.lettersOnly(rest) == target { return prefix }
        }
        return nil
    }

    static func tidyPunctuation(_ text: String) -> String {
        var result = text
        result = replace(result, "[ \\t]+([,.!?;:،؛؟])", "$1")          // no space before punctuation
        result = replace(result, "([,،])(?:\\s*[,،])+", "$1")           // ", ," → ","
        result = replace(result, "\\A[\\s,،;؛:]+", "")                  // leading leftovers
        result = replace(result, "(?m)^[ \\t]*[,،;؛][ \\t]*", "")       // after a line break too
        result = replace(result, "[ \\t]{2,}", " ")
        result = replace(result, "[ \\t]+\\n", "\n")
        result = replace(result, "\\n{3,}", "\n\n")
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Capitalises the first Latin letter of the text and of every new line.
    static func capitalizeStarts(_ text: String) -> String {
        var result = ""
        var atStart = true
        for character in text {
            if atStart, character.isLetter {
                result += character.isLowercase && character.isASCII ? character.uppercased() : String(character)
                atStart = false
            } else {
                result.append(character)
                if character == "\n" { atStart = true } else if !character.isWhitespace, !"\"'“‘([".contains(character) {
                    atStart = false
                }
            }
        }
        return result
    }

    // MARK: - Helpers

    struct Token {
        var text: String
        var isWord: Bool
        var consumed = false
    }

    /// Splits text into alternating word and separator tokens, preserving everything.
    static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        var current = ""
        var currentIsWord = false
        for character in text {
            let isWord = character.isLetter || character.isNumber || character == "'" || character == "’"
            if current.isEmpty {
                current = String(character)
                currentIsWord = isWord
            } else if isWord == currentIsWord {
                current.append(character)
            } else {
                tokens.append(Token(text: current, isWord: currentIsWord))
                current = String(character)
                currentIsWord = isWord
            }
        }
        if !current.isEmpty { tokens.append(Token(text: current, isWord: currentIsWord)) }
        return tokens
    }

    private static var regexCache: [String: NSRegularExpression] = [:]
    private static let regexLock = NSLock()

    static func regex(_ pattern: String) -> NSRegularExpression? {
        regexLock.lock(); defer { regexLock.unlock() }
        if let cached = regexCache[pattern] { return cached }
        guard let compiled = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return nil }
        regexCache[pattern] = compiled
        return compiled
    }

    static func replace(_ text: String, _ pattern: String, _ template: String) -> String {
        guard let regex = regex(pattern) else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    static func matches(_ text: String, _ pattern: String) -> Bool {
        guard let regex = regex(pattern) else { return false }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}

/// Phrases Whisper invents when it hears silence or noise (they come from subtitle credits in its training data).
enum Hallucinations {
    private static let phrases: Set<String> = Set([
        "thanks for watching", "thank you for watching", "thanks for watching!", "thank you for watching!",
        "please subscribe", "subscribe to my channel", "like and subscribe", "see you next time",
        "subtitles by the amara.org community", "subtitles by the amara org community",
        "transcribed by eso, translated by —", "you", "bye", "bye.", "bye bye", ".", "...",
        "ترجمة نانسي قنقر", "ترجمه نانسي قنقر", "اشتركوا في القناة", "اشترك في القناة", "اشتركوا بالقناة",
        "لا تنسوا الاشتراك في القناة", "شكرا للمشاهدة", "شكرا على المشاهدة", "شكرا لكم على المشاهدة",
        "شكرا لمتابعتكم", "ترجمة", "المترجم", "تابعونا", "نانسي قنقر",
    ].map { key($0) })

    private static func key(_ text: String) -> String {
        TextScript.fold(text).trimmingCharacters(in: CharacterSet(charactersIn: " .!?،؛؟…\"'"))
    }

    /// True when the whole transcript is a known invented phrase.
    static func isHallucination(_ text: String) -> Bool {
        let normalized = key(text)
        if normalized.isEmpty { return true }
        return phrases.contains(normalized)
    }

    /// Short polite phrases that are also the most common inventions on silence. These are real things
    /// people say, so they are only rejected when there is other evidence the clip had no speech.
    static func isSuspiciousOnSilence(_ text: String) -> Bool {
        let normalized = key(text)
        return ["thank you", "thanks", "شكرا", "شكرا لكم", "okay", "ok", "yeah", "so"].contains(normalized)
    }
}
