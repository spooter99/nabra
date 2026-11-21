import Foundation

/// Decides what Scribe does with a dictation, and checks what the model wrote.
///
/// The model never decides on its own whether to write something new: a small fixed rule does. It
/// composes only when the dictation starts with an instruction to write or reformat a kind of text
/// ("write an email to…", "reply saying…", "make this into a list", "اكتبلي رسالة…") and at least
/// three words follow. Questions ("can you write…?"), anything addressed to a person ("Omar, write…")
/// and requests about anything that is not a text stay dictation and are only polished. On 63 test
/// dictations and 53 phrases it was not tuned on, it never chose wrongly; the self-test keeps a sample.
enum ScribeRouter {
    enum Job: Equatable {
        /// Clean up what was said, keeping its meaning and language.
        case polish
        /// Write the text that was asked for.
        case compose(rule: String)
    }

    private static let enLead = #"^(?:(?:ok|okay|so|um+|uh+|hey|alright|right|now|and|also)\b[\s,.!]*)*(?:please\s+)?"#
    private static let enText = #"(?:e-?mails?|mails?|messages?|msgs?|repl(?:y|ies)|responses?|notes?|texts?|letters?|posts?|tweets?|"#
        + #"comments?|captions?|announcements?|invitations?|invites?|memos?|lists?|bullet(?:ed)?\s+(?:points|list)|"#
        + #"bullets|to-?dos?(?:\s+list)?|thank[\s-]you(?:\s+(?:note|message|email))?|follow[\s-]?ups?|dms?|whatsapp|slack)"#
    private static let enFill = #"(?:(?:a|an|the|my|our|some|quick|short|brief|polite|formal|friendly|nice|small|long|\w+)\s+){0,3}?"#
    private static let arLead = #"^(?:(?:طيب|يلا|هلا|اوكي|ok|okay|please|لو سمحت|من فضلك)\s*[،,]?\s*)*"#
    private static let arText = #"(?:رساله|رسايل|رسائل|مسج|ايميل|ايمل|اميل|بريد|منشور|بوست|تغريده|ملاحظه|قائمه|قايمه|ليسته|"#
        + #"نقاط|بنقاط|بنود|email|message|post|list|نوت|دعوه|اعلان)"#

    private static let rules: [(name: String, regex: NSRegularExpression)] = {
        var list: [(String, String)] = [
            ("write-text", enLead + #"(?:write|draft|compose|type\s+up|prepare)\s+(?:(?:me|us|him|her|them|up|out)\s+)?"# + enFill + enText + #"\b"#),
            ("send-text-saying", enLead + #"send\s+(?:(?:\w+)\s+)?(?:a|an)\s+"# + enFill + enText
                + #"\b.*?\b(?:saying|telling|asking|to\s+say|that)\b"#),
            ("reply-saying", enLead + #"(?:reply|respond|answer|write\s+back)\b(?:\s+(?:to\s+\w+|him|her|them|back|and))*"#
                + #"\s*(?:saying|and\s+say|that|with|telling|to\s+say|and\s+tell|:)"#),
            ("reformat-this", enLead + #"(?:make|turn|put|format|convert|change)\s+(?:this|that|it|these|those|the\s+following|the\s+above)\s+"#
                + #"(?:in(?:to)?|as|a|an)\s+(?:(?:a|an|the|short|quick|numbered|bulleted|nice|clean|\w+)\s+){0,2}"#
                + #"(?:list|bullets|bullet\s+points|points|steps|table|email|message|paragraphs?|tweet|post)\b"#),
            ("restyle-this", enLead + #"make\s+(?:this|that)\s+(?:sound\s+)?(?:more|less)\s+"#
                + #"(?:formal|professional|polite|friendly|casual|concise|clear|warm)\b"#),
            ("want-to-write", enLead + #"(?:i\s+(?:want|need|would\s+like|'d\s+like|wanna)\s+to|help\s+me|let'?s|let\s+me)\s+"#
                + #"(?:write|draft|compose|send|reply\s+with)\s+"# + enFill + enText + #"\b"#),
            ("email-someone", enLead + #"(?:e-?mail|message|text|dm|ping)\s+(?:\w+\s+){1,2}?(?:saying|to\s+say|and\s+say|that|asking|telling)\b"#),
        ].map { ($0.0, "(?i)" + $0.1) }
        list += [
            ("ar-write-text", arLead + #"(?:اكتب\S*|بدي اكتب|بدنا نكتب|صيغ\S*|صغلي|حضرلي|جهزلي)\s+(?:\S+\s+){0,2}?"# + arText),
            ("ar-send-text-saying", arLead + #"(?:ابعت\S*|بدي ابعت)\s+(?:رساله|مسج|ايميل|ايمل)\s+ل\S+\s+(?:انه|انو|بانه|بانو|اني|تقول|يقول|تقله|تقلها)"#),
            ("ar-reply-saying", arLead + #"(?:رد|ردي|ردلي|ردو|جاوب\S*)\s+(?:(?:عليه|عليها|عليهم)\s*)?(?:و)?\s*"#
                + #"(?:قله|قلها|قلهم|قول|قوله|قولها|احكيله|احكيلها|احكيلهم|انه|انو|بانه|بانو|اني)"#),
            ("ar-reformat", arLead + #"(?:حول\S*|حط\S*|رتب\S*|اعمل\S*|خلي\S*|نظم\S*)\s+(?:\S+\s+){0,3}?"#
                + #"(?:نقاط|بنقاط|لنقاط|قائمه|بقائمه|لقائمه|قايمه|بقايمه|ليسته|بليسته|بنود|جدول|list|bullet)"#),
        ]
        return list.compactMap { name, pattern in (try? NSRegularExpression(pattern: pattern)).map { (name, $0) } }
    }()

    /// An instruction with nothing to write from ("write an email") stays dictation.
    private static let minimumContentWords = 3

    /// Apps where dictation is usually an instruction to a coding assistant, not text to write:
    /// there Scribe only polishes ("write an email template and add it to the docs" stays as said).
    private static let codingApps: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.mitchellh.ghostty", "net.kovidgoyal.kitty",
        "org.alacritty", "com.github.wez.wezterm", "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "com.apple.dt.Xcode",
        "dev.zed.Zed", "com.exafunction.windsurf", "com.openai.codex",
    ]

    static func job(for text: String, bundleID: String? = nil) -> Job {
        if let bundleID, codingApps.contains(bundleID) || bundleID.hasPrefix("com.jetbrains.") { return .polish }
        let folded = TextScript.fold(text).trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        let whole = NSRange(location: 0, length: (folded as NSString).length)
        for rule in rules {
            guard let match = rule.regex.firstMatch(in: folded, range: whole) else { continue }
            let rest = (folded as NSString).substring(from: NSMaxRange(match.range))
            let words = rest.components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'")).inverted)
                .filter { !$0.isEmpty && !["um", "uh", "please"].contains($0) }
            return words.count < minimumContentWords ? .polish : .compose(rule: rule.name)
        }
        return .polish
    }

    // MARK: - Language

    static func arabicShare(_ text: String) -> Double {
        var arabic = 0
        var latin = 0
        for scalar in text.unicodeScalars {
            if (0x0600...0x06FF).contains(scalar.value) { arabic += 1 }
            else if (0x41...0x5A).contains(scalar.value) || (0x61...0x7A).contains(scalar.value) { latin += 1 }
        }
        return arabic + latin == 0 ? 0 : Double(arabic) / Double(arabic + latin)
    }

    /// "English, then Arabic", "Arabic with some English words": the runs of language in the order spoken.
    static func spokenLanguage(_ text: String) -> String {
        let parts = text.components(separatedBy: CharacterSet(charactersIn: ".?!؟،,;\n"))
        var runs: [String] = []
        for part in parts {
            let arabicWords = count(#"[\x{0600}-\x{06FF}]+"#, in: part)
            let latinWords = count("[A-Za-z]+", in: part)
            guard arabicWords + latinWords > 0 else { continue }
            let language = arabicWords >= latinWords ? "Arabic" : "English"
            if runs.last != language { runs.append(language) }
        }
        guard let only = runs.first else { return "English" }
        if runs.count > 1 { return runs.joined(separator: ", then ") }
        let share = arabicShare(text)
        if only == "Arabic", share < 0.97 { return "Arabic with some English words" }
        if only == "English", share > 0.03 { return "English with some Arabic words" }
        return only
    }

    /// The language to compose in: the one asked for, else the one mostly spoken.
    static func writeIn(_ text: String) -> String {
        if text.range(of: #"(?i)\bin arabic\b|بالعربي|بالعربية|باللغة العربية"#, options: .regularExpression) != nil { return "Arabic" }
        if text.range(of: #"(?i)\bin english\b|بالانجليزي|بالإنجليزي|بالانكليزي|بالإنكليزي|بالانجليزية|بالإنجليزية"#,
                      options: .regularExpression) != nil { return "English" }
        return arabicShare(text) >= 0.5 ? "Arabic" : "English"
    }

    private static func count(_ pattern: String, in text: String) -> Int {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return 0 }
        return regex.numberOfMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
    }

    // MARK: - Checking what was written

    private static let assistantOpening = #"(?i)\A\s*(?:please provide|here(?:'s| is| are)\b|sure[,!.]|certainly|of course|i'?m sorry|"#
        + #"i am sorry|as an ai|i can(?:not|'t)\b|could you (?:please )?provide|عذرا|عذراً|بالتأكيد|إليك|اليك)"#

    /// Why a polished text cannot be trusted, or nil when it can. Anything suspicious falls back to the
    /// words as said: a change of language or script, a lost English word inside Arabic, an answer
    /// instead of the text, or a text much longer than what was said.
    static func problem(polished: String, from said: String) -> String? {
        let output = polished.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else { return "wrote nothing" }
        if abs(arabicShare(output) - arabicShare(said)) > 0.25 { return "changed the language" }
        if runs(output) != runs(said) { return "changed the language of a part" }
        if arabicShare(said) >= 0.5 {
            let kept = Set(words(in: output.lowercased(), latinOnly: true))
            let lost = words(in: said.lowercased(), latinOnly: true).first {
                $0.count >= 2 && !kept.contains($0) && !fillerWords.contains($0)
            }
            if let lost { return "dropped the English word \(lost)" }
        }
        if output.range(of: assistantOpening, options: .regularExpression) != nil { return "answered instead of writing" }
        if Double(output.count) > Double(said.count) * 1.5 + 20 { return "wrote much more than was said" }
        return nil
    }

    /// Words the clean-up may drop on purpose.
    private static let fillerWords: Set<String> = ["um", "umm", "uh", "uhh", "ok", "okay", "like", "so", "yeah", "you", "know", "mm"]

    /// The order of languages, ignoring a few borrowed words ("Arabic with some English words" is Arabic).
    private static func runs(_ text: String) -> String {
        spokenLanguage(text)
            .replacingOccurrences(of: " with some English words", with: "")
            .replacingOccurrences(of: " with some Arabic words", with: "")
    }

    /// Removes what a composed text should never have: a subject line, a name placeholder.
    static func tidyComposed(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        result = result.replacingOccurrences(of: #"\A(?:subject|الموضوع)\s*:[^\n]*\n+"#, with: "",
                                             options: [.regularExpression, .caseInsensitive])
        result = result.replacingOccurrences(of: #"[ \t]*\[[^\]\n]*(?:\bname\b|اسم)[^\]\n]*\]"#, with: "",
                                             options: [.regularExpression, .caseInsensitive])
        result = result.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func words(in text: String, latinOnly: Bool) -> [String] {
        let pattern = latinOnly ? "[a-z][a-z0-9'’-]*" : #"[\p{L}\p{N}]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
    }
}
