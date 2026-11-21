import Foundation

/// Breaks a long dictation into paragraphs where the speaker moved on to a new point.
///
/// Dictated text arrives as one block. When it is long, a new paragraph starts at a sentence that
/// opens with the words people use to move on ("Secondly", "And also", "Another thing", "Anyway",
/// "ثانياً", "وكمان" …), once the paragraph so far holds a couple of sentences. A paragraph that grows
/// very long without such words is split where a sentence starts with "So", "But" and the like, and a
/// closing "Thank you." gets a line of its own. Words are never changed, and text that already has
/// line breaks (a list, "new line") is left as it was dictated.
enum Paragraphs {
    /// Shorter dictations stay one paragraph.
    static let minimumLength = 280
    static let minimumSentences = 4
    /// A paragraph is not closed before it has this much in it.
    static let minimumParagraphSentences = 2
    static let minimumParagraphLength = 120
    /// Past this, weaker cues ("So", "But") also start a new paragraph.
    static let longParagraph = 500

    private static let englishMoveOn = "(?i)\\A(?:secondly|thirdly|fourthly|fifthly|finally|lastly|first[ \\t]+of[ \\t]+all|firstly|"
        + "also|and[ \\t]+also|but[ \\t]+also|(?:and[ \\t]+)?another[ \\t]+thing|one[ \\t]+more[ \\t]+thing|the[ \\t]+other[ \\t]+thing|on[ \\t]+another[ \\t]+note|"
        + "on[ \\t]+top[ \\t]+of[ \\t]+that|in[ \\t]+addition|additionally|besides[ \\t]+that|moreover|furthermore|anyway|anyways|"
        + "by[ \\t]+the[ \\t]+way|apart[ \\t]+from[ \\t]+that|other[ \\t]+than[ \\t]+that|aside[ \\t]+from[ \\t]+that|moving[ \\t]+on|"
        + "as[ \\t]+for|regarding|when[ \\t]+it[ \\t]+comes[ \\t]+to|okay[ \\t]+so|ok[ \\t]+so|alright[ \\t]+so|so[ \\t]+anyway|"
        + "last[ \\t]+but[ \\t]+not[ \\t]+least|next)(?![\\p{L}'’])"
    private static let arabicMoveOn = "\\A(?:ثانياً|ثانيا|ثالثاً|ثالثا|رابعاً|رابعا|[أا]ولاً|[أا]ولا|و?[أا]يضاً|و?[أا]يضا|و?كمان|"
        + "بالإضاف[ةه]|بالاضاف[ةه]|و?[أا]خيراً|و?[أا]خيرا|على[ \\t]+فكر[ةه]|عموماً|عموما|المهم|شي[ \\t]+ثاني|شغل[ةه][ \\t]+ثاني[ةه]|"
        + "نقط[ةه][ \\t]+ثاني[ةه]|من[ \\t]+ناحي[ةه][ \\t]+ثاني[ةه]|ومن[ \\t]+ناحي[ةه]|بالنسب[ةه][ \\t]+ل)(?![\\p{L}])"
    private static let englishWeak = "(?i)\\A(?:so|but|basically|now|okay|ok|and[ \\t]+then|in[ \\t]+the[ \\t]+end|overall)(?![\\p{L}'’])"
    private static let arabicWeak = "\\A(?:بس|طيب|يعني|ف?بالتالي|وبعدين)(?![\\p{L}])"
    /// A closing line ("Thank you.", "Thanks a lot, bye.", "شكراً").
    private static let signOff = "(?i)\\A(?:thanks|thank[ \\t]+you|cheers|bye|goodbye|best[ \\t]+regards|kind[ \\t]+regards|regards|"
        + "talk[ \\t]+soon|شكرا|شكراً|يعطيك[ \\t]+العافي[ةه]|مع[ \\t]+السلام[ةه]|سلام)(?![\\p{L}'’])"

    private static let abbreviations: Set<String> = ["mr", "mrs", "ms", "dr", "prof", "st", "vs", "etc", "e.g", "i.e", "no", "inc", "ltd", "jr", "sr"]

    static func format(_ text: String) -> String {
        guard !text.contains("\n"), text.count >= minimumLength else { return text }
        let sentences = split(text)
        guard sentences.count >= minimumSentences else { return text }

        var paragraphs: [[String]] = [[]]
        for (index, sentence) in sentences.enumerated() {
            let current = paragraphs[paragraphs.count - 1]
            let length = current.reduce(0) { $0 + $1.count + 1 }
            let substantial = current.count >= minimumParagraphSentences || length >= minimumParagraphLength
            let nearEnd = index >= sentences.count - 2
            var breakHere = false
            if !current.isEmpty {
                let closing = current.first.map { matches($0, signOff) } ?? false
                if nearEnd, matches(sentence, signOff), !closing, paragraphs.count > 1 || current.count >= 2 {
                    breakHere = true
                } else if substantial, matches(sentence, englishMoveOn) || matches(sentence, arabicMoveOn) {
                    breakHere = true
                } else if length >= longParagraph, matches(sentence, englishWeak) || matches(sentence, arabicWeak) {
                    breakHere = true
                }
            }
            if breakHere {
                paragraphs.append([sentence])
            } else {
                paragraphs[paragraphs.count - 1].append(sentence)
            }
        }
        // A short scrap at the end belongs with what came before, unless it is a closing line.
        if paragraphs.count > 1, let last = paragraphs.last, let first = last.first,
           last.joined(separator: " ").count < 40, !matches(first, signOff) {
            paragraphs.removeLast()
            paragraphs[paragraphs.count - 1] += last
        }
        guard paragraphs.count > 1 else { return text }
        return paragraphs.map { $0.joined(separator: " ") }.joined(separator: "\n\n")
    }

    /// Sentences, each with its closing punctuation.
    static func split(_ text: String) -> [String] {
        var result: [String] = []
        var start = text.startIndex
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            if ".!?؟".contains(character), next == text.endIndex || text[next] == " " {
                var wordStart = index
                while wordStart > start, text[text.index(before: wordStart)].isLetter || text[text.index(before: wordStart)] == "." {
                    wordStart = text.index(before: wordStart)
                }
                let word = text[wordStart..<index].lowercased()
                if character != "." || !abbreviations.contains(word) {
                    let sentence = text[start..<next].trimmingCharacters(in: .whitespaces)
                    if !sentence.isEmpty { result.append(sentence) }
                    start = next
                }
            }
            index = next
        }
        let tail = text[start...].trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { result.append(tail) }
        return result
    }

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        TextPipeline.matches(text, pattern)
    }
}
