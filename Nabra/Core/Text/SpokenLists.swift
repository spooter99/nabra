import Foundation

/// Lays out enumerations that were dictated as such ("one, … two, …") as numbered lists.
///
/// The rule: a list opens at a "one" marker (first, one, number one, 1, أولاً, أول شي, واحد …) that is
/// set off by punctuation and stands at the start of a clause or right after words announcing a
/// list, and it goes on only with the next number in order, at the start of a clause or after
/// "and"; two items make a list. Anything else ("first of all" on its own, "one apple and two
/// oranges") stays prose.
///
/// Words are never changed: markers become numbers, and punctuation, capitals and line breaks are adjusted.
enum SpokenLists {
    // MARK: - Markers

    private enum Kind {
        case ordinal, ordinalNoun, cardinal, cardinalExplicit, digit
        case arabicAdverb, arabicNoun, arabicNounDefinite, arabicCardinal, arabicCardinalExplicit
        case continuer, closer

        var isNumeric: Bool { self != .continuer && self != .closer }

        /// The first two items of a list must use markers of one group ("first… second…", not "first… two…").
        var group: Int {
            switch self {
            case .ordinal, .ordinalNoun: return 0
            case .cardinal, .cardinalExplicit, .digit: return 1
            case .arabicAdverb, .arabicNoun, .arabicNounDefinite: return 2
            case .arabicCardinal, .arabicCardinalExplicit: return 3
            case .continuer, .closer: return 4
            }
        }

        /// "First… then… finally…" is a sequence; "one… two… then…" is a list followed by a sentence.
        var allowsContinuers: Bool { group == 0 || group == 2 }
    }

    /// One way of saying list positions, as a regular expression per position.
    private struct Family {
        var kind: Kind
        var arabic = false
        /// Whether the marker only counts when punctuation follows it. English markers are ordinary
        /// words too ("first point", "one apple"); the Arabic adverb forms are not.
        var needsPunctuation = true
        var members: [(position: Int, pattern: String)]
    }

    private static let englishOrdinals = ["first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth", "tenth"]
    private static let englishCardinals = ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten"]
    private static let listNouns = "point|thing|step|item|question|option|reason|issue|part|task|idea|note|problem|change|request"
    private static let numberNouns = "number|point|step|item|option|part|task|question|reason|note"
    private static let gap = "[ \\t]+"

    private static let arabicThings = "شي|شيء|اشي|إشي|شغل[ةه]|حاج[ةه]|نقط[ةه]|[أا]مر|خطو[ةه]"
    private static let arabicOrdinalStems = ["[أا]ول", "[ثت]اني", "[ثت]ال[ثت]", "رابع", "خامس", "سادس", "سابع", "[ثت]امن", "تاسع", "عاشر"]
    private static let arabicCardinals = [
        "واحد|وحد[ةه]", "[اإ]ثنين|[اإ]تنين|ثنين|تنين|[اإ]ثنان", "ثلاث[ةه]?|تلات[ةه]?", "[أا]ربع[ةه]?", "خمس[ةه]?",
        "ست[ةه]?", "سبع[ةه]?", "ثماني[ةه]?|تماني[ةه]?", "تسع[ةه]?", "عشر[ةه]?",
    ]
    private static let arabicFeminineOrdinals = ["ال[أا]ولى", "ال[ثت]اني[ةه]", "ال[ثت]ال[ثت][ةه]", "الرابع[ةه]", "الخامس[ةه]"]
    private static let arabicMasculineOrdinals = ["ال[أا]ول", "ال[ثت]اني", "ال[ثت]ال[ثت]", "الرابع", "الخامس"]

    private static let families: [Family] = {
        var all: [Family] = []
        all.append(Family(kind: .ordinal, members: englishOrdinals.enumerated().map { index, word in
            switch index {
            case 0: return (1, "first(?:ly)?(?:\(gap)of\(gap)all|\(gap)off)?")
            case 1: return (2, "second(?:ly)?(?:\(gap)of\(gap)all)?")
            default: return (index + 1, "\(word)(?:ly)?")
            }
        }))
        all.append(Family(kind: .ordinalNoun, members: englishOrdinals.enumerated().map { index, word in
            (index + 1, "(?:the\(gap))?\(word)\(gap)(?:\(listNouns))")
        }))
        all.append(Family(kind: .cardinal, members: englishCardinals.enumerated().map { ($0.offset + 1, $0.element) }))
        all.append(Family(kind: .cardinalExplicit, members: englishCardinals.enumerated().map { index, word in
            (index + 1, "(?:(?:\(numberNouns))\(gap)(?:\(word)|\(index + 1))|#[ \\t]?\(index + 1))")
        }))
        all.append(Family(kind: .arabicAdverb, arabic: true, needsPunctuation: false,
                          members: arabicOrdinalStems.enumerated().map { ($0.offset + 1, "\($0.element)[اً]{1,2}") }))
        all.append(Family(kind: .arabicNoun, arabic: true, needsPunctuation: false,
                          members: arabicOrdinalStems.prefix(7).enumerated().map { ($0.offset + 1, "\($0.element)\(gap)(?:\(arabicThings))") }))
        all.append(Family(kind: .arabicNounDefinite, arabic: true, members: (0..<5).map { index in
            (index + 1, "(?:(?:ال)?(?:نقط[ةه]|شغل[ةه]|حاج[ةه]|خطو[ةه])\(gap)\(arabicFeminineOrdinals[index])"
                + "|(?:ال)?(?:شي|شيء|[أا]مر|سبب|بند)\(gap)\(arabicMasculineOrdinals[index]))")
        }))
        all.append(Family(kind: .arabicCardinal, arabic: true,
                          members: arabicCardinals.enumerated().map { ($0.offset + 1, "(?:\($0.element))") }))
        all.append(Family(kind: .arabicCardinalExplicit, arabic: true, needsPunctuation: false,
                          members: arabicCardinals.enumerated().map { ($0.offset + 1, "(?:رقم|نمر[ةه]|بند)\(gap)(?:\($0.element))") }))
        all.append(Family(kind: .continuer, members: [(0, "next|then|after\(gap)that")]))
        all.append(Family(kind: .closer, members: [(0, "finally|lastly|last\(gap)but\(gap)not\(gap)least|last(?:\(gap)one)?")]))
        all.append(Family(kind: .continuer, arabic: true, members: [(0, "بعدين|بعد\(gap)هيك|بعد\(gap)كد[اه]|بعد\(gap)ذلك|ثم")]))
        all.append(Family(kind: .closer, arabic: true, needsPunctuation: false, members: [
            (0, "[أا]خير[اً]{1,2}|[آا]خر\(gap)(?:\(arabicThings))|في\(gap)النهاي[ةه]|بالنهاي[ةه]|بال[آا]خر"),
        ]))
        return all
    }()

    private static let notInsideWord = "(?<![\\p{L}\\p{N}'’_])"
    private static let wordEnds = "(?![\\p{L}\\p{N}'’_])"
    /// Joining words in front of a marker: "and two", "okay so first", "and then number three", "وثانياً".
    private static let englishLead = "((?:(?:and|then|plus|also|so|okay|ok|well|now|but|alright)\(gap)){1,3})?"
    private static let arabicLead = "((?:(?:وبعدين|بعدين|ثم|يعني|طيب|و)[ \\t]*){1,3})?"
    /// What sets a marker off from its item: punctuation, or (for markers that allow it) just a space.
    private static let separator = "([ \\t]*[,،:][ \\t]*|[ \\t]*[-–—]\(gap)|[ \\t]*\\.(?:\(gap)|$)|\(gap))"
    /// A written number as a marker: "1." "2)" "3," but not "3.5", "10:30" or "1,000".
    private static let digitPattern = "(?<![\\p{L}\\p{N}'’_.,:/#-])\(englishLead)(\\d{1,2})(?![\\p{L}\\p{N}])"
        + "([ \\t]*[.)](?:\(gap)|$)|[ \\t]*[,:]\(gap)|\(gap)[-–—]\(gap))"

    /// One search per family: joining words, any of the family's markers, then what sets it off.
    private static let scanners: [(family: Family, regex: NSRegularExpression)] = families.compactMap { family in
        let alternatives = family.members.map { "(?:\($0.pattern))" }.joined(separator: "|")
        let pattern = "(?i)\(notInsideWord)\(family.arabic ? arabicLead : englishLead)(\(alternatives))\(wordEnds)\(separator)"
        return TextPipeline.regex(pattern).map { (family, $0) }
    }

    /// Words that announce a list ("here's the list", "a few things", "the steps are").
    private static let englishCueWords = "lists?|following|follows|things|points|steps|items|tasks|options|questions|reasons|"
        + "issues|changes|ideas|notes|requests|problems"
    /// The Arabic ones: "القائمة", "ثلاث نقاط", "شغلتين", "كم شغلة", "التالي".
    private static let arabicCueWords = "(?:ال)?(?:قائم[ةه]|لست[ةه]|ليست|[أا]شياء|شغلات|نقاط|[أا]مور|حاجات|خطوات|[أا]سباب|ملاحظات|طلبات)"
        + "|التالي[ةه]?|كالتالي|ال[آا]تي|يلي|شغلتين|نقطتين|[أا]مرين|شيئين|حاجتين|ملاحظتين|سببين"
        + "|(?:كم|كذا)\(gap)(?:شغل[ةه]|شي|شيء|حاج[ةه]|نقط[ةه]|[أا]مر|ملاحظ[ةه]|طلب|سبب|خطو[ةه])"
    /// Such words ending the text right before the first marker ("here's the list one, …").
    private static let englishCueEnd = "(?<![\\p{L}])(?:\(englishCueWords))"
        + "(?:\(gap)(?:is|are|was|were|which\(gap)(?:is|are)|like|such\(gap)as|namely|here|below|so|now))?[ \\t]*\\z"
    /// A verb that leaves the sentence open for what follows ("the plan is first, …").
    private static let openVerbEnd = "(?i)(?<![\\p{L}'’])(?:is|are|was|were|includes?|including)[ \\t]*\\z"
    private static let arabicCueEnd = "(?<![\\p{L}])(?:\(arabicCueWords))(?:\(gap)(?:هي|هم|هما|هو|هدول|هذول|هاي))?[ \\t]*\\z"
    /// Such words anywhere in the sentence that leads into a list: its full stop becomes a colon.
    private static let cueAnywhere = "(?i)(?<![\\p{L}])(?:\(englishCueWords)|here(?:'s|’s|\(gap)is|\(gap)are))(?![\\p{L}])"
        + "|(?<![\\p{L}])(?:\(arabicCueWords))(?![\\p{L}])"

    // MARK: - Finding markers

    private enum Boundary {
        /// Start of the text, of a line, or after . ! ? : ;
        case sentenceStart
        case afterComma
        /// Right after words that announce a list ("here's the list one, …").
        case afterCue
        /// Right after "is" / "are" ("the plan is first, …").
        case afterVerb
        case middle
    }

    private enum Separator {
        case space, comma, dash, period, bracket
    }

    private struct Hit {
        /// Where the text before this marker ends (the joining word, if any, belongs to the marker).
        var start: String.Index
        /// Where this item's own text begins.
        var end: String.Index
        var position: Int
        var kind: Kind
        var boundary: Boundary
        var hasLead: Bool
        var separator: Separator
        var needsPunctuation: Bool

        private var isSetOff: Bool { separator != .space || !needsPunctuation }

        /// Strong enough to open a list.
        var canStart: Bool {
            guard kind.isNumeric, isSetOff else { return false }
            switch boundary {
            case .sentenceStart, .afterComma, .afterCue: return true
            // "The plan is first, …" opens a list; "the answer is 1." and "he is first." do not.
            case .afterVerb: return separator == .comma && kind != .digit
            case .middle: return false
            }
        }

        /// Good enough to be the next item of a list that is already open: at the start of a clause
        /// or joined on with "and". ("He is first, she is second" has neither.)
        var canContinue: Bool {
            kind.isNumeric && isSetOff && (boundary == .sentenceStart || boundary == .afterComma || hasLead)
        }

        /// "1. I need potatoes 2. I need vegetables": a written number with its own full stop goes on a
        /// list that was opened by one, wherever it stands.
        var continuesWrittenNumbers: Bool {
            kind == .digit && (separator == .period || separator == .bracket)
        }

        /// "Then, …" / "Finally, …" as a further item: at the start of a sentence, or joined on with "and".
        var canExtend: Bool {
            guard !kind.isNumeric, isSetOff else { return false }
            return boundary == .sentenceStart || hasLead
        }
    }

    private static func boundary(before index: String.Index, in text: String) -> Boundary {
        var cursor = index
        while cursor > text.startIndex {
            let previous = text[text.index(before: cursor)]
            guard previous == " " || previous == "\t" || "\"'”’)»".contains(previous) else { break }
            cursor = text.index(before: cursor)
        }
        guard cursor > text.startIndex else { return .sentenceStart }
        let previous = text[text.index(before: cursor)]
        if previous.isNewline || ".!?؟:;؛".contains(previous) { return .sentenceStart }
        if ",،-–—".contains(previous) { return .afterComma }
        let tail = String(text[..<cursor].suffix(60))
        if TextPipeline.matches(tail, "(?i)" + englishCueEnd) || TextPipeline.matches(tail, arabicCueEnd) { return .afterCue }
        return TextPipeline.matches(tail, openVerbEnd) ? .afterVerb : .middle
    }

    private static func separatorKind(_ text: Substring) -> Separator {
        if text.contains(where: { ",،:".contains($0) }) { return .comma }
        if text.contains(".") { return .period }
        if text.contains(")") { return .bracket }
        if text.contains(where: { "-–—".contains($0) }) { return .dash }
        return .space
    }

    /// Every place in `text` that reads like a list marker, in order, without overlaps.
    private static func hits(in text: String) -> [Hit] {
        var found: [Hit] = []
        let whole = NSRange(text.startIndex..., in: text)

        for (family, regex) in scanners {
            for match in regex.matches(in: text, range: whole) {
                guard let range = Range(match.range, in: text), let marker = Range(match.range(at: 2), in: text),
                      let separatorRange = Range(match.range(at: 3), in: text)
                else { continue }
                let spoken = String(text[marker])
                guard let member = family.members.first(where: { TextPipeline.matches(spoken, "(?i)^(?:\($0.pattern))$") }) else { continue }
                found.append(Hit(start: range.lowerBound, end: range.upperBound, position: member.position, kind: family.kind,
                                 boundary: boundary(before: range.lowerBound, in: text),
                                 hasLead: match.range(at: 1).location != NSNotFound,
                                 separator: separatorKind(text[separatorRange]), needsPunctuation: family.needsPunctuation))
            }
        }
        if let regex = TextPipeline.regex("(?i)" + digitPattern) {
            for match in regex.matches(in: text, range: whole) {
                // wholeNumberValue also reads Arabic-Indic digits (١ ٢ ٣).
                guard let range = Range(match.range, in: text), let marker = Range(match.range(at: 2), in: text),
                      let separatorRange = Range(match.range(at: 3), in: text)
                else { continue }
                let position = text[marker].reduce(0) { $0 * 10 + ($1.wholeNumberValue ?? 0) }
                guard position >= 1 else { continue }
                found.append(Hit(start: range.lowerBound, end: range.upperBound, position: position, kind: .digit,
                                 boundary: boundary(before: range.lowerBound, in: text),
                                 hasLead: match.range(at: 1).location != NSNotFound,
                                 separator: separatorKind(text[separatorRange]), needsPunctuation: true))
            }
        }

        // Longer matches win where two overlap ("number one" over "one", "أول شي" over "أول").
        found.sort {
            $0.start != $1.start ? $0.start < $1.start
                : text.distance(from: $0.start, to: $0.end) > text.distance(from: $1.start, to: $1.end)
        }
        var distinct: [Hit] = []
        for hit in found {
            if let last = distinct.last, hit.start < last.end {
                if text.distance(from: hit.start, to: hit.end) > text.distance(from: last.start, to: last.end), hit.start == last.start {
                    distinct[distinct.count - 1] = hit
                }
            } else {
                distinct.append(hit)
            }
        }
        return distinct
    }

    // MARK: - Sentences

    private static let abbreviations: Set<String> = [
        "mr", "mrs", "ms", "dr", "prof", "sr", "jr", "st", "vs", "etc", "e.g", "i.e", "eg", "ie", "approx", "inc", "ltd",
        "co", "corp", "dept", "fig", "gen", "gov", "mt", "no",
    ]

    /// True when the character at `index` ends a sentence (a full stop that is not part of a number,
    /// an abbreviation, a web address or an ellipsis; or ! ? ؟).
    private static func endsSentence(at index: String.Index, in text: String) -> Bool {
        let character = text[index]
        if "!?؟".contains(character) { return true }
        guard character == "." else { return false }
        let next = text.index(after: index)
        let following: Character? = next < text.endIndex ? text[next] : nil
        let previous: Character? = index > text.startIndex ? text[text.index(before: index)] : nil
        if following == "." || previous == "." { return false }
        if let following, !following.isWhitespace, !"\"'”’)»".contains(following) { return false }
        var wordStart = index
        while wordStart > text.startIndex {
            let before = text[text.index(before: wordStart)]
            guard before.isLetter || before == "." else { break }
            wordStart = text.index(before: wordStart)
        }
        return !abbreviations.contains(text[wordStart..<index].lowercased())
    }

    /// The index just past the first `sentences` sentences that start at `from`. A line break also ends it.
    private static func end(ofSentences sentences: Int, from: String.Index, in text: String) -> String.Index {
        var remaining = max(1, sentences)
        var index = from
        while index < text.endIndex {
            if text[index].isNewline { return index }
            if endsSentence(at: index, in: text) {
                var after = text.index(after: index)
                while after < text.endIndex, "!?؟\"'”’)»".contains(text[after]) { after = text.index(after: after) }
                remaining -= 1
                if remaining == 0 { return after }
                index = after
                continue
            }
            index = text.index(after: index)
        }
        return text.endIndex
    }

    /// How many sentences `text` holds (at least one).
    private static func sentenceCount(_ text: String) -> Int {
        var count = 1
        var index = text.startIndex
        while index < text.endIndex {
            if endsSentence(at: index, in: text) {
                var after = text.index(after: index)
                while after < text.endIndex, !text[after].isLetter, !text[after].isNumber { after = text.index(after: after) }
                if after < text.endIndex { count += 1 }
                index = after
                continue
            }
            index = text.index(after: index)
        }
        return count
    }

    // MARK: - Building the list

    /// An item that opens with a short aside and then a verb with no subject of its own ("I think, is enough").
    private static let numberIsSubject = "(?i)\\A[ \\t]*[^,.;:!?\\n]{0,40},[ \\t]*(?:is|are|was|were|would|will|can|could|should|has|"
        + "have|had|does|did|might|must)\(gap)(?!(?:you|we|i|they|he|she|it|there|this|that)(?![\\p{L}]))"

    private static func hasWord(_ text: Substring) -> Bool {
        text.contains { $0.isLetter || $0.isNumber }
    }

    /// The first run of markers that makes a list: "one" then "two" and so on, each good enough for its place.
    private static func firstRun(in hits: [Hit], text: String) -> [Hit]? {
        for (index, opener) in hits.enumerated() where opener.position == 1 && opener.canStart {
            var run = [opener]
            var expected = 2
            var lastTaken = index
            var stop = hits.count
            for next in (index + 1)..<hits.count {
                let hit = hits[next]
                guard hit.kind.isNumeric else { continue }
                let continues = hit.canContinue || (opener.kind == .digit && hit.continuesWrittenNumbers)
                if hit.position == expected, continues, expected > 2 || hit.kind.group == opener.kind.group {
                    run.append(hit)
                    expected += 1
                    lastTaken = next
                } else if hit.canStart, hit.position == 1 || hit.position > expected {
                    // Another list opens here, or the numbering jumps: this run ends before it.
                    stop = next
                    break
                }
            }
            let numbered = run.count
            // "Then, …" and "Finally, …" after the numbered items carry the sequence on. After a lone
            // "first" they must open their own sentence: "first… and then… and finally…" is a story.
            if lastTaken + 1 < stop {
                for hit in hits[(lastTaken + 1)..<stop] where !hit.kind.isNumeric && hit.canExtend {
                    guard numbered >= 2 || hit.boundary == .sentenceStart else { continue }
                    if hit.kind == .closer {
                        run.append(hit)
                        break
                    }
                    if opener.kind.allowsContinuers { run.append(hit) }
                }
            }
            // Two numbered items make a list; "first" needs two more steps to be one ("first… then… finally…").
            guard numbered >= 2 || run.count >= 3 else { continue }
            // "One, two, three, go": markers with nothing between them are counting, not a list.
            var usable = run.count
            for position in 0..<(run.count - 1) where !hasWord(text[run[position].end..<run[position + 1].start]) {
                usable = position
                break
            }
            if usable < run.count { run = Array(run[..<usable]) }
            guard run.count >= 2, min(numbered, run.count) >= 2 || run.count >= 3 else { continue }
            // "One, I think, is enough. Two, in my view, would be too many": there the number is the
            // subject of its sentence, not a label in front of it.
            let subjects = (0..<(run.count - 1)).prefix(2).contains { position in
                TextPipeline.matches(String(text[run[position].end..<run[position + 1].start]), numberIsSubject)
            }
            if subjects { continue }
            return run
        }
        return nil
    }

    /// Rewrites every dictated enumeration in `text` as a numbered list. `lowercase` decides whether a
    /// word that only has a capital because a pause was written as a full stop may lose it.
    static func format(_ text: String, lowercase: (String, String) -> Bool = { _, _ in false }) -> String {
        guard mayHoldList(text) else { return text }
        let found = hits(in: text)
        guard let run = firstRun(in: found, text: text) else { return text }

        // Items: each runs to the next marker. The last one has no marker after it, so it is given as
        // many sentences as the shortest of the others: the sentence that follows the list stays out.
        let lastStart = run[run.count - 1].end
        let earlier = (0..<(run.count - 1)).map { trimmedItem(String(text[run[$0].end..<run[$0 + 1].start])) }
        var listEnd = end(ofSentences: 1, from: lastStart, in: text)
        var items = rejoinPausedItems(earlier + [trimmedItem(String(text[lastStart..<listEnd]))], lowercase: lowercase)
        let sentences = items.dropLast().map(sentenceCount).min() ?? 1
        if sentences > 1 {
            listEnd = end(ofSentences: sentences, from: lastStart, in: text)
            items = rejoinPausedItems(earlier + [trimmedItem(String(text[lastStart..<listEnd]))], lowercase: lowercase)
        }
        guard items.allSatisfy({ hasWord($0[...]) }) else { return text }
        // Short items read best without full stops; keep them only when an item has several sentences.
        if items.allSatisfy({ sentenceCount($0) == 1 }) {
            items = items.map { $0.hasSuffix(".") && !$0.hasSuffix("..") ? String($0.dropLast()) : $0 }
        }
        items = items.map { item in
            guard let first = item.first, first.isLowercase, first.isASCII else { return item }
            return first.uppercased() + item.dropFirst()
        }

        var result = introduction(String(text[..<run[0].start]))
        if !result.isEmpty { result += "\n" }
        result += items.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        let rest = text[listEnd...].trimmingCharacters(in: .whitespacesAndNewlines)
        if !rest.isEmpty {
            // A blank line, so that what follows is not read as part of the last item.
            result += "\n\n" + format(rest, lowercase: lowercase)
        }
        return result
    }

    /// True when `text` opens with a list this formatter produced (no introduction in front of it).
    static func startsWithList(_ text: String) -> Bool {
        text.hasPrefix("1. ") && text.contains("\n2. ")
    }

    /// Cheap test that lets ordinary dictation skip all of the above.
    private static func mayHoldList(_ text: String) -> Bool {
        TextPipeline.matches(text, "(?i)first|one|(?<![\\p{N}.,:/-])[1١](?!\\p{N})|[أا]ول|واحد|وحد[ةه]")
    }

    private static func trimmedItem(_ text: String) -> String {
        let edges = CharacterSet(charactersIn: " \t\n,،;؛:-–—")
        var item = text.trimmingCharacters(in: edges)
        // A joining word left dangling before the next marker ("…potatoes, and, second").
        item = TextPipeline.replace(item, "(?i)(?:[,،;؛][ \\t]*|[ \\t]+)(?:and|و)\\z", "")
        return item.trimmingCharacters(in: edges)
    }

    /// "I need. Potatoes" next to "I need vegetables": the full stop is a pause, not the end of the item.
    private static func rejoinPausedItems(_ items: [String], lowercase: (String, String) -> Bool) -> [String] {
        items.enumerated().map { index, item in
            guard let stop = item.range(of: ". ") else { return item }
            let head = String(item[..<stop.lowerBound])
            let words = head.split(separator: " ")
            guard (1...3).contains(words.count), !head.contains(where: { ",;:!?".contains($0) }) else { return item }
            let opening = head.lowercased() + " "
            let parallel = items.enumerated().contains { other, candidate in
                other != index && candidate.lowercased().hasPrefix(opening)
            }
            guard parallel else { return item }
            let tail = item[stop.upperBound...].trimmingCharacters(in: .whitespaces)
            guard let word = tail.split(whereSeparator: { !($0.isLetter || $0 == "'" || $0 == "’") }).first.map(String.init) else { return item }
            let joined = lowercase(word, head + " " + tail) ? word.prefix(1).lowercased() + tail.dropFirst() : tail
            return head + " " + joined
        }
    }

    /// The text that leads into a list ends in a colon when it announces the list or is cut off mid-sentence.
    private static func introduction(_ raw: String) -> String {
        var intro = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = intro.last else { return "" }
        if ",،;؛-–—".contains(last) {
            intro = String(intro.dropLast()).trimmingCharacters(in: .whitespaces)
            return intro.isEmpty ? "" : intro + ":"
        }
        if last == "." {
            guard !intro.hasSuffix("..") else { return intro }
            // Only the sentence that leads into the list matters.
            let body = String(intro.dropLast())
            var sentenceStart = body.startIndex
            var index = body.startIndex
            while index < body.endIndex {
                if body[index].isNewline || endsSentence(at: index, in: body) { sentenceStart = body.index(after: index) }
                index = body.index(after: index)
            }
            return TextPipeline.matches(String(body[sentenceStart...]), cueAnywhere) ? body + ":" : intro
        }
        if ":!?؟…".contains(last) { return intro }
        return intro + ":"
    }
}
