import Foundation

/// Lays out a list that was announced in words as bullet points, one item per line:
/// "Here is the list. I need potatoes, vegetables and a couple of snacks." becomes
///
///     Here is the list. I need:
///     • Potatoes
///     • Vegetables
///     • A couple of snacks
///
/// It takes both an announcement (here is the list, my shopping list is, هاي القائمة …) and, right
/// after it, at least two short items separated by commas or "and". Anything else stays prose.
/// Words are kept, with two exceptions: a lead the items share ("I need … and I need …") is said
/// once, before the list, and joining words that open an item ("also", "and", "و") are dropped.
/// Lists dictated with numbers ("one, … two, …") are left to `SpokenLists`.
enum AnnouncedLists {
    static let bullet = "• "
    /// Items are short: a longer stretch is a sentence, not a list entry.
    static let longestItemWords = 6

    // MARK: - Patterns

    private static let gap = "[ \\t]+"
    private static let listKinds = "(?:(?:shopping|grocery|groceries|to-?do|todo|packing|reading|wish|guest)\(gap))?"
    /// The announcement, ending its sentence or followed by ":" / "," ("Here is the list.", "Here's my list of things to buy:").
    private static let englishCue = "(?i)(?<![\\p{L}'’])(?:here(?:'s|’s|\(gap)is|\(gap)are)|this\(gap)is|that's|that’s|below\(gap)is)"
        + "\(gap)(?:the|a|my|our|your)\(gap)\(listKinds)list(?:\(gap)of\(gap)[^.,:;!?\\n]{1,40}?)?(?=[ \\t]*(?:[.:,;]|\\z))"
    /// The announcement with the items in the same sentence ("My shopping list is potatoes and bread").
    private static let englishInlineCue = "(?i)(?<![\\p{L}'’])(?:the|my|our|your)\(gap)\(listKinds)list\(gap)(?:is|includes|has)(?=\(gap))"
    private static let arabicListWord = "(?:ال)?(?:قائم[ةه]|قايم[ةه]|ليست[ةه]|لست[ةه]|ليست)"
    private static let arabicCue = "(?<![\\p{L}])(?:هاي|هذه|هذي|هاذي|هادي|هيدي|هاد|هذا|هاي\(gap)هي)\(gap)\(arabicListWord)(?=[ \\t]*(?:[.:,،؛]|\\z))"
    private static let arabicInlineCue = "(?<![\\p{L}])\(arabicListWord)\(gap)(?:هي|فيها)(?=\(gap))"

    /// What the items have in common at their start ("I need", "we want to buy", "there are", "بدي").
    private static let englishLead = "(?i)\\A(?:(?:and|so|also|okay|ok|well|now|then)\(gap))*"
        + "(?:(?:i|we|you|they)\(gap)(?:(?:really|just|also|still|only|will|'ll|’ll)\(gap))?"
        + "(?:(?:need|want|have|got)\(gap)to\(gap)(?:get|buy|bring|pick\(gap)up|take|do)|need|want|have|got|bought|"
        + "would\(gap)like|'d\(gap)like|’d\(gap)like|should\(gap)(?:get|buy|bring)|must\(gap)(?:get|buy))"
        + "|there\(gap)(?:is|are)|there's|there’s|it\(gap)is|it's|it’s|they\(gap)are|they're|they’re)\(gap)"
    private static let arabicLead = "\\A(?:(?:و|ف|طيب|يعني)[ \\t]*)?(?:بدي|بدنا|بدك|[أا]ريد|نريد|نحتاج|[أا]حتاج|محتاج|محتاجين|عايز|عاوز|عايزين|"
        + "[أا]بغى|نبغى|لازم\(gap)(?:نجيب|[أا]جيب|نشتري|[أا]شتري)|جيب(?:لي)?)\(gap)"

    /// Words that open an item but are not part of it.
    private static let englishConnector = "(?i)\\A(?:(?:and|also|plus|then|or|oh|as\(gap)well\(gap)as)\(gap))+"
    private static let arabicConnector = "\\A(?:(?:وكمان|كمان|وبعدين|ثم|بالإضاف[ةه]|بالاضاف[ةه])\(gap))+"
    /// An item that starts with someone doing something is a sentence ("I went to the shop").
    private static let startsWithSubject = "(?i)\\A(?:i|we|you|he|she|they|it|[أا]نا|[إا]حنا|نحن|هو|هي|هم)(?![\\p{L}'’])"

    // MARK: - Formatting

    static func format(_ text: String) -> String {
        guard let cue = findCue(in: text) else { return text }

        // What follows the announcement: the rest of its sentence, or the next sentence.
        var cursor = cue.end
        skipSpaces(text, &cursor)
        var separator: Character?
        if cursor < text.endIndex, ".:,;،؛".contains(text[cursor]) {
            separator = text[cursor]
            cursor = text.index(after: cursor)
        }
        let sentences = self.sentences(in: text, from: cursor)
        guard let first = sentences.first else { return text }

        var chunks = items(in: String(text[first]))
        var listEnd = first.upperBound
        // Later sentences that only add items ("Also a couple of snacks.") belong to the list.
        for sentence in sentences.dropFirst() {
            let spoken = String(text[sentence]).trimmingCharacters(in: .whitespaces)
            guard TextPipeline.matches(spoken, englishConnector) || TextPipeline.matches(spoken, arabicConnector) else { break }
            let more = items(in: spoken)
            guard !more.isEmpty, more.allSatisfy(isShort) else { break }
            chunks += more
            listEnd = sentence.upperBound
        }

        // A lead the items share is said once, before the list.
        var lead: String?
        if let found = leadingMatch(of: chunks[0]) {
            lead = found.lead
            chunks[0] = found.rest
            let folded = found.lead.lowercased()
            for index in chunks.indices.dropFirst() {
                if let other = leadingMatch(of: chunks[index]), other.lead.lowercased() == folded {
                    chunks[index] = other.rest
                }
            }
        }
        chunks = chunks.map(cleanItem).filter { !$0.isEmpty }
        guard chunks.count >= 2, chunks.allSatisfy(isShort),
              !chunks.contains(where: { TextPipeline.matches($0, startsWithSubject) })
        else { return text }

        var intro = String(text[..<cue.end]).trimmingCharacters(in: .whitespaces)
        if let lead {
            intro += (separator == "," || separator == "،" ? ", " : ". ") + capitalized(lead)
        }
        intro += ":"
        var result = intro + "\n" + chunks.map { bullet + capitalized($0) }.joined(separator: "\n")
        let rest = text[listEnd...].trimmingCharacters(in: .whitespacesAndNewlines)
        if !rest.isEmpty { result += "\n\n" + rest }
        return result
    }

    // MARK: - Pieces

    private static func findCue(in text: String) -> (start: String.Index, end: String.Index)? {
        var best: Range<String.Index>?
        for pattern in [englishCue, englishInlineCue, arabicCue, arabicInlineCue] {
            guard let regex = TextPipeline.regex(pattern),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(match.range, in: text)
            else { continue }
            if best.map({ range.lowerBound < $0.lowerBound }) ?? true { best = range }
        }
        return best.map { ($0.lowerBound, $0.upperBound) }
    }

    private static func skipSpaces(_ text: String, _ index: inout String.Index) {
        while index < text.endIndex, text[index] == " " || text[index] == "\t" { index = text.index(after: index) }
    }

    /// Sentences from `start` on, each without its closing punctuation. A line break also ends one.
    private static func sentences(in text: String, from start: String.Index) -> [Range<String.Index>] {
        var result: [Range<String.Index>] = []
        var sentenceStart = start
        var index = start
        func close(at end: String.Index) {
            let piece = text[sentenceStart..<end]
            if piece.contains(where: { $0.isLetter || $0.isNumber }) { result.append(sentenceStart..<end) }
        }
        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            let atBoundary = next == text.endIndex || text[next] == " " || text[next].isNewline
            if character.isNewline {
                // A line break the speaker asked for ends the list.
                close(at: index)
                sentenceStart = text.endIndex
                break
            }
            if ".!?؟".contains(character), atBoundary {
                close(at: next)
                sentenceStart = next
            }
            index = next
        }
        if sentenceStart < text.endIndex, index == text.endIndex { close(at: text.endIndex) }
        return result
    }

    /// Splits one sentence into items at commas and at "and" ("و" in Arabic).
    private static func items(in sentence: String) -> [String] {
        let arabic = TextScript.containsArabic(sentence)
        var chunks = sentence.components(separatedBy: CharacterSet(charactersIn: ",،"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let last = chunks.last else { return [] }
        // Arabic "و" is written onto the next word. Only split there in front of a word of three letters
        // or more, so a word that merely begins with و ("وقت") stays whole.
        let andPattern = arabic ? "[ \\t]+و[ \\t]*(?=\\p{L}{3,})" : "(?i)[ \\t]+and[ \\t]+"
        if chunks.count > 1 {
            // "potatoes, vegetables and snacks": only the last piece holds an "and" between items.
            if let regex = TextPipeline.regex(andPattern),
               let match = regex.matches(in: last, range: NSRange(last.startIndex..., in: last)).last,
               let range = Range(match.range, in: last) {
                let before = String(last[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
                let after = String(last[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                if !before.isEmpty, !after.isEmpty {
                    chunks.removeLast()
                    chunks += [before, after]
                }
            }
        } else if let regex = TextPipeline.regex(andPattern) {
            // No commas: "I need potatoes and I need vegetables", "بطاطا وخضار وسناكات".
            var pieces: [String] = []
            var start = last.startIndex
            for match in regex.matches(in: last, range: NSRange(last.startIndex..., in: last)) {
                guard let range = Range(match.range, in: last) else { continue }
                pieces.append(String(last[start..<range.lowerBound]))
                start = range.upperBound
            }
            pieces.append(String(last[start...]))
            let split = pieces.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            // Without commas an attached "و" is only taken as "and" in a run of three or more short items.
            if !arabic || (split.count >= 3 && split.allSatisfy({ $0.split(separator: " ").count <= 3 })) {
                chunks = split
            }
        }
        return chunks
    }

    private static func leadingMatch(of item: String) -> (lead: String, rest: String)? {
        let trimmed = TextPipeline.replace(item, englishConnector, "")
        for pattern in [englishLead, arabicLead] {
            guard let regex = TextPipeline.regex(pattern),
                  let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
                  let range = Range(match.range, in: trimmed)
            else { continue }
            let lead = String(trimmed[..<range.upperBound]).trimmingCharacters(in: .whitespaces)
            let rest = String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            // The joining words in front of the lead ("and I need", "وبدي") are not part of it.
            let bare = TextPipeline.replace(lead, "(?i)\\A(?:(?:and|so|also|okay|ok|well|now|then|طيب|يعني)[ \\t]+|[وف](?=\\p{L}))+", "")
            guard !rest.isEmpty, !bare.isEmpty else { return nil }
            return (bare, rest)
        }
        return nil
    }

    private static func cleanItem(_ item: String) -> String {
        var result = TextPipeline.replace(item, englishConnector, "")
        result = TextPipeline.replace(result, arabicConnector, "")
        return result.trimmingCharacters(in: CharacterSet(charactersIn: " \t.,;:!?،؛؟"))
    }

    private static func isShort(_ item: String) -> Bool {
        let words = item.split(whereSeparator: { $0 == " " || $0 == "\t" }).count
        return words >= 1 && words <= longestItemWords
    }

    private static func capitalized(_ text: String) -> String {
        guard let first = text.first, first.isLowercase, first.isASCII else { return text }
        return first.uppercased() + text.dropFirst()
    }
}
