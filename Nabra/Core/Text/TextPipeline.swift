import Foundation
import NaturalLanguage

/// Deterministic clean-up applied to every transcript. Fast (about a millisecond) and predictable.
struct TextPipeline {
    struct Options {
        var removeFillers = true
        var voiceCommands = true
        /// Lay out dictated enumerations ("one, … two, …", "first, … second, …") as numbered lists.
        var formatLists = true
        /// Undo full stops the recogniser wrote where the speaker only paused ("I need. Potatoes").
        var repairPauses = true
        /// Break long dictations into paragraphs where the speaker moves on to a new point.
        var paragraphs = true
        /// (what the recogniser writes, what it should be), longest first.
        var replacements: [(heard: String, phrase: String)] = []
        /// Correct spellings to snap near-misses onto.
        var vocabulary: [String] = []
        /// Returns true when `word` is an ordinary dictionary word. Used to avoid "fixing" real words.
        var isRealWord: (String) -> Bool = { _ in false }
        /// Returns true when `word`, as it stands in `sentence`, is a name. A name keeps its capital
        /// when the full stop in front of it is removed.
        var isName: (_ word: String, _ sentence: String) -> Bool = TextPipeline.looksLikeName
    }

    struct Output: Equatable {
        var text: String
        /// Dictionary phrases that were applied.
        var appliedPhrases: [String] = []
    }

    /// Loads what the rarer steps need (the list patterns, the name tagger) on a background thread the
    /// first time anything is processed, so the first list after launch is as quick as every later one.
    private static let warmUp: Void = {
        DispatchQueue.global(qos: .utility).async {
            _ = SpokenLists.format("One, a. Two, b.")
            _ = looksLikeName("Potatoes", in: "We need Potatoes today")
        }
    }()

    static func process(_ raw: String, options: Options) -> Output {
        _ = warmUp
        var text = raw.replacingOccurrences(of: "\r", with: " ")
        text = stripAnnotations(text)
        text = collapseWhitespace(text)
        if Hallucinations.isHallucination(text) { return Output(text: "") }

        if options.voiceCommands { text = applyVoiceCommands(text) }
        text = Addresses.format(text)
        if options.removeFillers { text = removeFillers(text) }
        // Whether a word that is capitalised only because a full stop stood before it may lose the capital.
        let spoken = text
        let lowercase: (String, String) -> Bool = { word, sentence in
            // Written with a capital in the middle of another sentence too: that is how the word is spelled.
            let elsewhere = "(?<=[\\p{Ll},،;] )" + NSRegularExpression.escapedPattern(for: word) + "(?![\\p{L}\\p{N}'’])"
            if spoken.range(of: elsewhere, options: .regularExpression) != nil { return false }
            return mayLowercase(word, in: sentence, isRealWord: options.isRealWord, isName: options.isName)
        }
        if options.repairPauses { text = repairPauseStops(text, lowercase: lowercase) }
        // After the pauses are mended, so that "and. And then" does not leave "and and" behind.
        if options.removeFillers { text = collapseStutter(text) }
        var applied: [String] = []
        text = applyReplacements(text, options.replacements, applied: &applied)
        text = snapVocabulary(text, options.vocabulary, isRealWord: options.isRealWord, applied: &applied)
        if options.formatLists {
            // Numbered when the items were numbered aloud, bullets when the list was only announced.
            let numbered = SpokenLists.format(text, lowercase: lowercase)
            text = numbered != text ? numbered : AnnouncedLists.format(text)
        }
        if options.paragraphs { text = Paragraphs.format(text) }
        text = tidyPunctuation(text)
        text = capitalizeStarts(text)
        return Output(text: text, appliedPhrases: applied)
    }

    // MARK: - Steps

    private static let annotationWords = [
        "blank_audio", "blank audio", "music", "applause", "laughter", "laughs", "laughing", "silence",
        "inaudible", "noise", "background noise", "sigh", "sighs", "coughs", "cough", "no audio", "no speech",
        "موسيقى", "تصفيق", "ضحك", "صمت", "موسيقي", "ضوضاء",
    ]

    /// Tags the recogniser writes in angle brackets where the speaker hesitated or made a noise.
    private static let annotationTags = "hesitation|unk|unknown|noise|laugh|laughs|laughter|music|silence|inaudible|"
        + "unintelligible|cough|breath|sigh|overlap|applause|foreign|no[ _]speech|blank[ _]audio"

    /// Removes non-speech markers such as "[BLANK_AUDIO]", "(music)", "*laughs*", "<hesitation>" and musical notes.
    static func stripAnnotations(_ text: String) -> String {
        var result = text
        let alternatives = annotationWords.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
        result = replace(result, "(?i)[\\[\\(\\*]\\s*(?:\(alternatives))\\s*[\\]\\)\\*]", " ")
        result = replace(result, "(?i)<\\s*(?:\(annotationTags))\\s*>", " ")
        // The model marks non-speech it heard with "@@@" and a word ("@@@ضوضاء", noise).
        result = replace(result, "@@@[\\p{L}_]*", " ")
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

    // MARK: - Pauses written as full stops

    /// Words a sentence cannot end on. A full stop right after one of them is a pause, not an ending.
    private static let neverFinalWords: Set<String> = [
        "a", "an", "the", "and", "or", "but", "because", "my", "your", "our", "their",
        "i'm", "you're", "we're", "they're", "he's", "she's", "it's", "that's", "there's", "here's",
        "i'll", "you'll", "we'll", "they'll", "he'll", "she'll", "it'll",
        "i've", "you've", "we've", "they've", "i'd", "you'd", "we'd", "they'd",
    ]
    /// "Plan A." and "option a." do end a sentence.
    private static let letterLabels: Set<String> = [
        "plan", "option", "part", "type", "grade", "class", "vitamin", "point", "section", "group", "exhibit", "appendix",
        "version", "phase", "step", "level", "team", "side", "column", "row", "item", "choice", "answer", "letter",
    ]
    private static let joiningWords: Set<String> = ["and", "but", "so", "or", "because", "plus", "yet"]
    private static let asideWords: Set<String> = ["basically", "actually", "like", "well", "also", "okay", "ok", "now"]
    /// A clause that is only a subject and "need"/"want" has not said what yet.
    private static let unfinishedClause = "^(?:(?:and|but|so|then|because|well|okay|ok|also|now)\\s+)*"
        + "(?:(?:i|we|you|they|he|she|it)\\s+(?:(?:really|just|only|also|still)\\s+)?(?:need|needs|want|wants|would\\s+like)"
        + "|(?:i|we|you|they|he|she)'d\\s+like)$"

    /// Removes full stops the recogniser wrote where the speaker merely paused. Deliberately narrow,
    /// because almost any word can end a sentence. It acts only when the words before the stop
    /// cannot be a finished clause:
    /// - the stop follows a word no sentence ends on ("the.", "it's.", "and."),
    /// - the clause is just a subject and "need"/"want" ("I need. Potatoes"),
    /// - the clause is only joining words ("but basically. It doesn't" becomes "but basically, it doesn't").
    static func repairPauseStops(_ text: String, lowercase: (String, String) -> Bool) -> String {
        guard text.contains(". ") else { return text }
        guard let regex = regex("(?<![\\p{L}\\p{N}'’.])([\\p{L}'’]+)\\.[ \\t]+(?=([\\p{L}'’]+))") else { return text }
        var edits: [(range: Range<String.Index>, replacement: String)] = []
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let before = Range(match.range(at: 1), in: text), let after = Range(match.range(at: 2), in: text) else { continue }
            let stop = before.upperBound..<text.index(after: before.upperBound)
            let word = text[before].lowercased().replacingOccurrences(of: "’", with: "'")

            // The clause the stop closes: everything since the last punctuation mark.
            var clauseStart = before.lowerBound
            while clauseStart > text.startIndex {
                let previous = text[text.index(before: clauseStart)]
                if previous.isNewline || ".!?,;:،؛؟…".contains(previous) { break }
                clauseStart = text.index(before: clauseStart)
            }
            let spokenClause = text[clauseStart..<before.upperBound].trimmingCharacters(in: .whitespaces)
            let clause = spokenClause.lowercased().replacingOccurrences(of: "’", with: "'")
            let clauseWords = clause.split(separator: " ").map(String.init)

            var replacement: String?
            if neverFinalWords.contains(word) {
                // A capital "A." is a label, and so is a lower-case one after "plan" or "option".
                let isLabel = word == "a" && (text[before] == "A" || clauseWords.count < 2
                    || letterLabels.contains(clauseWords[clauseWords.count - 2]))
                if !isLabel { replacement = "" }
            } else if matches(clause, unfinishedClause) {
                replacement = ""
            } else if !clauseWords.isEmpty, clauseWords.contains(where: joiningWords.contains),
                      clauseWords.allSatisfy({ joiningWords.contains($0) || asideWords.contains($0) || $0 == "then" }) {
                replacement = asideWords.contains(word) ? "," : ""
            }
            guard let replacement else { continue }
            edits.append((stop, replacement))

            // The next word was capitalised because of the stop.
            let next = String(text[after])
            var sentenceEnd = after.upperBound
            while sentenceEnd < text.endIndex, !text[sentenceEnd].isNewline, !".!?؟".contains(text[sentenceEnd]) {
                sentenceEnd = text.index(after: sentenceEnd)
            }
            let sentence = spokenClause + " " + String(text[after.lowerBound..<sentenceEnd])
            if let first = next.first, first.isUppercase, lowercase(next, sentence) {
                edits.append((after.lowerBound..<text.index(after: after.lowerBound), first.lowercased()))
            }
        }
        guard !edits.isEmpty else { return text }
        var result = text
        for edit in edits.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            result.replaceSubrange(edit.range, with: edit.replacement)
        }
        return result
    }

    /// Words that start sentences all the time and are never names.
    private static let ordinaryStarters: Set<String> = [
        "the", "a", "an", "this", "that", "these", "those", "my", "your", "his", "her", "its", "our", "their", "some", "any",
        "no", "every", "each", "all", "both", "it", "he", "she", "we", "you", "they", "there", "here", "what", "which", "who",
        "whose", "when", "where", "why", "how", "and", "but", "or", "so", "because", "if", "then", "than", "as", "while",
        "although", "though", "unless", "until", "since", "to", "of", "in", "on", "at", "for", "with", "from", "by", "about",
        "into", "over", "under", "after", "before", "between", "through", "during", "without", "within", "is", "are", "was",
        "were", "be", "been", "being", "am", "do", "does", "did", "have", "has", "had", "will", "would", "can", "could",
        "should", "might", "must", "shall", "not", "just", "also", "only", "even", "still", "very", "really", "too", "maybe",
        "please", "like", "basically", "actually", "immediately", "now", "yes", "yeah", "okay", "ok", "well", "let's",
        "it's", "that's", "there's", "here's", "what's", "don't", "doesn't", "didn't", "can't", "won't", "isn't", "aren't",
        "wasn't", "weren't", "you're", "we're", "they're", "he's", "she's", "you'll", "we'll", "they'll", "you've", "we've",
        "they've",
    ]

    /// Whether `word`, capitalised only because a full stop stood before it, should be written in
    /// lower case now that the stop is gone. Names, "I" and anything unfamiliar keep their capital.
    static func mayLowercase(_ word: String, in sentence: String, isRealWord: (String) -> Bool,
                             isName: (String, String) -> Bool) -> Bool {
        let plain = word.replacingOccurrences(of: "’", with: "'")
        guard let first = plain.first, first.isUppercase, first.isASCII else { return false }
        if plain == "I" || plain.hasPrefix("I'") { return false }
        // "GitHub", "USA": capitals inside the word are part of how it is written.
        if plain.dropFirst().contains(where: \.isUppercase) { return false }
        if ordinaryStarters.contains(plain.lowercased()) { return true }
        return isRealWord(plain) && !isName(word, sentence)
    }

    /// Asks the on-device language tagger whether `word`, as it stands in `sentence`, is a name.
    static func looksLikeName(_ word: String, in sentence: String) -> Bool {
        guard let range = sentence.range(of: word) else { return false }
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = sentence
        let (tag, _) = tagger.tag(at: range.lowerBound, unit: .word, scheme: .nameType)
        return tag == .personalName || tag == .placeName || tag == .organizationName
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

    private static func startsAddress(_ text: String, at offset: Int) -> Bool {
        let rest = text.dropFirst(offset).prefix(80)
        guard let end = rest.firstIndex(where: { $0 == " " || $0 == "\n" }) ?? Optional(rest.endIndex) else { return false }
        return rest[..<end].contains("@")
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

    /// Capitalises the first Latin letter of the text and of every new line, but never the start of
    /// an email address.
    static func capitalizeStarts(_ text: String) -> String {
        var result = ""
        var atStart = true
        for (offset, character) in text.enumerated() {
            if atStart, character.isLetter, startsAddress(text, at: offset) {
                atStart = false
                result.append(character)
                continue
            }
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
