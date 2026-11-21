import AppKit

/// Checks for choosing between the English and the Arabic decode and for weaving words from one
/// into the other. No speech model involved: decodes are written out by hand, and the "model" that
/// scores a candidate sentence is a small table.
extension SelfTest {
    /// Builds decodes out of pieces and scores sentences the way a table says.
    private final class Bench {
        private var ids: [String: Int32] = [:]
        private var texts: [Int32: String] = [:]
        /// Log-probability of a piece under a hint, by exact piece text. Falls back to `fallback`.
        var table: [String: [String: Float]] = ["en": [:], "ar": [:]]
        /// Used for pieces the table does not list: (hint, piece is Arabic script) -> log-probability.
        var fallback: (String, Bool) -> Float = { hint, isArabic in (hint == "ar") == isArabic ? -0.05 : -4.0 }
        var calls = 0
        var abortAll = false

        func id(_ text: String) -> Int32 {
            if let known = ids[text] { return known }
            let new = Int32(ids.count + 1)
            ids[text] = new
            texts[new] = text
            return new
        }

        /// A decode from (piece, log-probability, time) triples. A leading space starts a word; a
        /// negative time means "unknown".
        func decode(_ language: String, _ pieces: [(String, Float, Float)], seconds: Double = 2) -> SpeechEngine.Result {
            var result = SpeechEngine.Result()
            result.language = language
            result.audioSeconds = seconds
            result.tokens = pieces.map {
                SpeechEngine.Token(id: id($0.0), text: $0.0, logProbability: $0.1, time: $0.2 < 0 ? .nan : $0.2)
            }
            result.text = pieces.map(\.0).joined().trimmingCharacters(in: .whitespaces)
            let known = pieces.map(\.1)
            result.averageLogProbability = known.reduce(0, +) / Float(max(known.count, 1))
            result.endLogProbability = -0.01
            return result
        }

        func score(_ tokenIDs: [Int32], _ language: String, _ withTimes: Bool) -> SpeechEngine.Result {
            calls += 1
            var result = SpeechEngine.Result()
            result.language = language
            if abortAll {
                result.aborted = true
                return result
            }
            result.tokens = tokenIDs.map { id in
                let text = texts[id] ?? ""
                let value = table[language]?[text] ?? fallback(language, TextScript.containsArabic(text))
                return SpeechEngine.Token(id: id, text: text, logProbability: value, time: .nan)
            }
            result.text = result.tokens.map(\.text).joined().trimmingCharacters(in: .whitespaces)
            let values = result.tokens.map(\.logProbability)
            result.averageLogProbability = values.reduce(0, +) / Float(max(values.count, 1))
            result.endLogProbability = -0.01
            return result
        }

        func resolve(_ english: SpeechEngine.Result, _ arabic: SpeechEngine.Result, recent: String? = nil) -> LanguageArbiter.Outcome {
            calls = 0
            return LanguageArbiter.resolve(english: english, arabic: arabic, recentLanguage: recent, keyboardIsArabic: false) {
                self.score($0, $1, $2)
            }
        }
    }

    static func language() {
        let bench = Bench()

        // --- An Arabic name said inside an English sentence ("Check the status on درويش") ---
        // The English decode hears the sentence but mangles the name; the Arabic decode invents
        // the sentence but hears the name. Its first piece of the name is misplaced in time.
        let english = bench.decode("en", [
            (" Che", -1.6, -1), ("ck", 0, 0.24), (" the", -0.01, 0.36), (" status", 0, 0.52), (" on", -0.04, 0.92),
            (" Dar", -1.8, 1.12), ("w", -0.3, 1.24), ("e", -0.4, 1.32), ("s", -0.8, 1.36), ("h", -0.04, 1.48), (".", -0.2, 1.6),
        ], seconds: 1.7)
        let arabic = bench.decode("ar", [
            (" ", -1.9, -1), ("إعطينا", -1.0, 0.08), (" ال", -1.5, 0.08), ("رقم", -0.5, 0.08),
            (" د", -2.0, 0.08), ("ر", -0.01, 0.64), ("و", 0, 0.68), ("ي", -0.06, 1.36), ("ش", -0.01, 1.44),
        ], seconds: 1.7)

        let englishWords = LanguageWeaver.words(english.tokens, audioSeconds: 1.7)
        expect(englishWords.count, 5, "weaver: punctuation stays with the word before it")
        expect(englishWords.last.map { english.tokens[$0.body].map(\.text).joined() } ?? "", " Darwesh", "weaver: word body excludes the full stop")
        let name = LanguageWeaver.words(arabic.tokens, audioSeconds: 1.7).last
        expect((name?.start ?? 0) > 1.3, true, "weaver: a word is placed where its last pieces were heard, ignoring early strays")

        let proposal = LanguageWeaver.propose(base: english.tokens, other: arabic.tokens, audioSeconds: 1.7)
        expect(proposal?.summary ?? "none", "Darwesh -> درويش", "weaver: unsure name is matched to the confident Arabic word")
        expect(proposal.map { bench.score($0.tokenIDs, "en", false).text } ?? "", "Check the status on درويش.",
               "weaver: the swap keeps the rest of the sentence and its full stop")

        // The model prefers the woven sentence: it is used.
        bench.table["en"] = [" Dar": -1.8, "w": -0.3, "e": -0.4, "s": -0.8, "h": -0.04, " د": -2.2, " ": -7, "إعطينا": -9, " ال": -3.6, "رقم": -1]
        bench.table["ar"] = [" Che": -4.5, " Dar": -4.5, "w": -0.5, "e": -0.7, "s": -0.7, ".": -3, " د": -0.2]
        bench.fallback = { hint, isArabic in isArabic ? -0.05 : (hint == "en" ? -0.02 : -0.1) }
        var outcome = bench.resolve(english, arabic)
        expect(outcome.result.text, "Check the status on درويش.", "arbiter: weaves the Arabic name into the English sentence")
        expect(outcome.result.language, "en", "arbiter: a woven sentence keeps the language it was built on")
        expect(outcome.note.contains("wove Darwesh -> درويش"), true, "arbiter: the log says what was woven")

        // The model finds the Arabic word unlikely there: the English decode is kept as it was.
        bench.table["en"]?[" د"] = -14
        bench.table["ar"]?[" د"] = -9
        outcome = bench.resolve(english, arabic)
        expect(outcome.result.text, "Check the status on Darwesh.", "arbiter: a swap the model does not prefer is dropped")

        // A name the English decode is sure of is left alone, without spending any scoring.
        let sure = bench.decode("en", [
            (" Tell", -0.5, -1), (" me", -0.02, 0.3), (" what", -0.02, 0.5), (" to", -0.02, 0.7), (" send", -0.03, 0.9),
            (" to", -0.01, 1.2), (" Dar", -0.05, 1.4), ("wish", -0.02, 1.7), (".", -0.1, 1.9),
        ])
        let translated = bench.decode("ar", [
            (" أخبرني", -1.2, -1), (" ماذا", -0.9, 0.3), (" أرسل", -1.1, 0.6), (" ل", -0.7, 1.2), ("درويش", -0.02, 1.5),
        ])
        outcome = bench.resolve(sure, translated)
        expect(outcome.result.text, "Tell me what to send to Darwish.", "arbiter: a clearly better decode wins outright")
        expect(bench.calls, 0, "arbiter: a clear case costs no extra passes")

        // A whole Arabic translation of an English sentence must not replace its one unsure word.
        let weakStart = bench.decode("en", [
            (" For", -1.4, -1), (" some", -0.9, 0.2), (" reason", -0.02, 0.5), (",", -0.1, 0.7), (" I", -0.02, 0.9),
            (" don't", -0.02, 1.1), (" know", -0.01, 1.3), (" why", -0.02, 1.6), (".", -0.05, 1.8),
        ])
        let wholeTranslation = bench.decode("ar", [
            (" ل", -1.5, -1), ("سبب", -0.05, 0.3), (" ما", -0.05, 0.6), (" لا", -0.05, 0.9), (" أعرف", -0.04, 1.2), (" لماذا", -0.03, 1.6),
        ])
        expect(LanguageWeaver.propose(base: weakStart.tokens, baseCross: weakStart.tokens.map { _ in -0.05 },
                                      other: wholeTranslation.tokens, audioSeconds: 2) == nil, true,
               "weaver: a translation of words that are staying is not an island")

        // --- Words the base only translated: their own times are useless, so they are placed between
        // the words around them ("I told him والله ما بعرف and then he left"). ---
        let mixed = bench.decode("en", [
            (" I", -0.6, -1), (" told", -0.02, 0.3), (" him", -0.02, 0.6),
            (" I", -1.4, 0.08), (" swear", -1.6, 2.6), (" I", -0.9, 0.08), (" don't", -1.1, 0.08), (" know", -0.8, 0.08),
            (" and", -0.03, 2.2), (" then", -0.02, 2.5), (" he", -0.02, 2.7), (" left", -0.02, 2.9), (".", -0.1, 3.1),
        ], seconds: 3.3)
        let phrase = bench.decode("ar", [
            (" أي", -2.2, -1), (" تولد", -1.9, 0.08), (" هيم", -2.4, 0.08),
            (" والله", -0.4, 0.85), (" ما", -0.02, 1.3), (" ب", -0.3, 1.6), ("عرف", -0.02, 1.9),
            (" اند", -1.8, 0.08), (" ذين", -2.1, 0.08), (" هي", -1.7, 0.08), (" لفت", -1.5, 0.08),
        ], seconds: 3.3)
        expect(LanguageWeaver.propose(base: mixed.tokens, other: phrase.tokens, audioSeconds: 3.3)?.summary ?? "none",
               "I swear I don't know -> والله ما بعرف", "weaver: a translated stretch is found between the words that were heard")

        // --- Choosing a decode ---
        bench.table = ["en": [:], "ar": [:]]
        bench.fallback = { hint, isArabic in (hint == "ar") == isArabic ? -0.05 : -4.0 }
        let hello = bench.decode("en", [(" Hello", -0.2, -1), (" how", -0.22, 0.4), (" are", -0.2, 0.6), (" you", -0.2, 0.8)])
        let marhaba = bench.decode("ar", [(" مرحبا", -0.2, -1), (" كيف", -0.1, 0.5), (" حالك", -0.05, 0.9)])
        outcome = bench.resolve(hello, marhaba)
        expect(outcome.result.language, "ar", "arbiter: close scores are settled by scoring each text under the other hint")
        expect(bench.calls, 2, "arbiter: the cross-check is two passes")

        let lower = bench.decode("ar", [(" the", -0.02, -1), (" status", -0.02, 0.4), (" on", -0.02, 0.8), (" Darwish", -0.02, 1.2)])
        let proper = bench.decode("en", [(" The", -0.05, -1), (" status", -0.02, 0.4), (" on", -0.02, 0.8), (" Darwish", -0.05, 1.2), (".", -0.1, 1.5)])
        expect(bench.resolve(proper, lower).result.text, "The status on Darwish.", "arbiter: when both wrote English the English hint's version is used")

        let short = bench.decode("en", [(" Thank", -0.05, -1), (" you", -0.02, 0.4)])
        let long = bench.decode("ar", [(" هذه", -0.1, -1), (" مشاعر", -0.1, 0.5), (" جميلة", -0.1, 1.0), (" ورائعة", -0.1, 1.5), (" شكرا", -0.1, 2.0)])
        expect(bench.resolve(short, long).result.language, "ar", "arbiter: a decode that dropped most of the speech loses")

        // A dead heat ("whatsapp.com") goes to the language of what was just dictated.
        bench.fallback = { _, _ in -0.5 }
        let latin = bench.decode("en", [(" Whatsapp", -0.5, -1), (".", -0.5, 0.5), ("com", -0.5, 0.7)])
        let arabicScript = bench.decode("ar", [(" واتساب", -0.5, -1), (".", -0.5, 0.5), ("كوم", -0.5, 0.7)])
        expect(bench.resolve(latin, arabicScript, recent: "ar").result.language, "ar", "arbiter: a dead heat follows recent Arabic")
        expect(bench.resolve(latin, arabicScript, recent: "en").result.language, "en", "arbiter: a dead heat follows recent English")

        bench.abortAll = true
        expect(bench.resolve(latin, arabicScript).aborted, true, "arbiter: an interrupted scoring pass interrupts the decision")

        // --- Putting stretches back together ---
        expect(TranscriptionService.join(["Only this as an open source project on GitHub.", "and yeah make it Apache 2"]),
               "Only this as an open source project on GitHub and yeah make it Apache 2",
               "join: a stretch that continues in lower case takes over the sentence before it")
        expect(TranscriptionService.join(["It did not ring.", "It rang from the browser.", ""]), "It did not ring. It rang from the browser.",
               "join: sentences stay sentences")
        expect(TranscriptionService.join(["Is that right?", "and then what"]), "Is that right? and then what", "join: a question mark is never dropped")
        expect(TextPipeline.stripAnnotations("ولذلك <hesitation> لم <Hesitation> يأتيها"), "ولذلك   لم   يأتيها", "tags in angle brackets are removed")
        expect(TextPipeline.stripAnnotations("use the <div> tag"), "use the <div> tag", "other text in angle brackets is kept")
        expect(TextPipeline.process("@@@ضوضاء", options: TextPipeline.Options()).text, "", "the model's noise marker is not text")

        // --- Lists that were announced rather than numbered ---
        expect(AnnouncedLists.format("And here is the list. I need potatoes and I need vegetables. Also a couple of snacks."),
               "And here is the list. I need:\n• Potatoes\n• Vegetables\n• A couple of snacks", "bullets: parallel clauses share one lead")
        expect(AnnouncedLists.format("Here is the list. I want potatoes, vegetables and a couple of snacks."),
               "Here is the list. I want:\n• Potatoes\n• Vegetables\n• A couple of snacks", "bullets: a comma list after an announcement")
        expect(AnnouncedLists.format("Here's my shopping list: milk, eggs and bread. Thanks."),
               "Here's my shopping list:\n• Milk\n• Eggs\n• Bread\n\nThanks.", "bullets: the sentence after the list stays out of it")
        expect(AnnouncedLists.format("هاي القائمة: بطاطا، خضار وشوية سناكات."), "هاي القائمة:\n• بطاطا\n• خضار\n• شوية سناكات",
               "bullets: Arabic")
        expect(AnnouncedLists.format("هاي القائمة. بدي وقت"), "هاي القائمة. بدي وقت", "bullets: a word starting with و is not split")
        expect(AnnouncedLists.format("I need potatoes, vegetables and a couple of snacks."), "I need potatoes, vegetables and a couple of snacks.",
               "bullets: no announcement, no list")
        expect(AnnouncedLists.format("Here is the list. I checked it and it looks fine."), "Here is the list. I checked it and it looks fine.",
               "bullets: sentences about the list stay prose")
        expect(AnnouncedLists.format("Here is the list. I think we should go over it tomorrow because it is long and boring."),
               "Here is the list. I think we should go over it tomorrow because it is long and boring.", "bullets: long pieces are not items")

        // --- Paragraphs in long dictations ---
        let essay = "There are some things that I want to change. Basically, the startup is slow sometimes. When I press the key it does not "
            + "start immediately. Secondly, when I say an Arabic word in the middle of a sentence, it turns the whole thing into Arabic. "
            + "So I want you to fix that. And also, there are some inconsistencies, but most of them can be solved one by one."
        expect(Paragraphs.format(essay).components(separatedBy: "\n\n").count, 3, "paragraphs: a new point starts a new paragraph")
        expect(Paragraphs.format(essay).components(separatedBy: "\n\n").last?.hasPrefix("And also,") ?? false, true,
               "paragraphs: the break comes before the words that move on")
        expect(Paragraphs.format("Secondly, it works. Also, it is fast. Thanks."), "Secondly, it works. Also, it is fast. Thanks.",
               "paragraphs: short dictations stay one block")
        expect(Paragraphs.format("Line one\n" + essay), "Line one\n" + essay, "paragraphs: text with its own line breaks is left alone")
        let goodbye = essay + " Thank you."
        expect(Paragraphs.format(goodbye).hasSuffix("\n\nThank you."), true, "paragraphs: a closing thank-you gets its own line")
        let noCues = "I went to the office this morning and the meeting started late because the projector did not work. We waited for "
            + "almost twenty minutes before someone fixed it. After that the presentation went well and everyone seemed happy with "
            + "the numbers. I think we can send the proposal tomorrow."
        expect(Paragraphs.format(noCues), noCues, "paragraphs: a story without cues is not chopped up")

        // --- Email and web addresses ---
        let addresses: [(String, String)] = [
            ("Use the work email or the team at zentro.chat, something like that.",
             "Use the work email or the team@zentro.chat, something like that."),
            ("Send it to sara dot darwish at gmail dot com please.", "Send it to sara.darwish@gmail.com please."),
            ("My email is sara underscore k at outlook dot com.", "My email is sara_k@outlook.com."),
            ("Check whatsapp dot com.", "Check whatsapp.com."),
            ("Go to www dot nabra dot app now.", "Go to www.nabra.app now."),
            ("Write to Info @ Example . com today.", "Write to info@example.com today."),
            ("Let's look at google.com tomorrow.", "Let's look at google.com tomorrow."),
            ("The dot com bubble burst.", "The dot com bubble burst."),
            ("I'll meet you at home at five.", "I'll meet you at home at five."),
            ("He works at the team at Apple.", "He works at the team at Apple."),
            ("team at zentro dot chat", "team@zentro.chat"),
        ]
        for (input, expected) in addresses {
            expect(TextPipeline.process(input, options: TextPipeline.Options()).text, expected, "address: \(input)")
        }

        // --- Scribe is off on a new install, so nothing is downloaded for it ---
        let suite = "app.nabra.selftest.\(UUID().uuidString)"
        if let fresh = UserDefaults(suiteName: suite) {
            expect(Settings(defaults: fresh).scribeEnabled, false, "settings: Scribe is off until it is turned on")
            fresh.removePersistentDomain(forName: suite)
        }

        // --- Scribe: what to do with a dictation, and whether to trust what came back ---
        let jobs: [(String, Bool)] = [
            ("write an email to Ahmad telling him the meeting moved to Thursday", true),
            ("reply saying thanks, I'll send it tomorrow morning", true),
            ("make this into a list: milk, eggs and bread", true),
            ("اكتبلي رسالة لريم إنه الطلبية وصلت وبدي أعرف إيمتى", true),
            ("can you write the agenda for tomorrow's meeting and send it", false),
            ("Omar, write the notes from the meeting please", false),
            ("write an email", false),
            ("send the file to Sara before Friday", false),
            ("ممكن تبعتلي التقرير قبل يوم الجمعة", false),
        ]
        for (said, composes) in jobs {
            let job = ScribeRouter.job(for: said)
            expect(job != .polish, composes, "scribe job: \(said)")
        }
        expect(ScribeRouter.job(for: "write an email to Sara saying the build is broken", bundleID: "com.apple.Terminal"), .polish,
               "scribe job: never composes in a terminal")
        expect(ScribeRouter.spokenLanguage("ok so the meeting went well I think. بس لازم نحكي مع العميل بكرا"), "English, then Arabic",
               "scribe language: runs in order")
        expect(ScribeRouter.writeIn("write a message to Reem in Arabic saying hi"), "Arabic", "scribe language: asked for Arabic")
        expect(ScribeRouter.problem(polished: "We solved the problem, it was simple.", from: "احنا حلينا المشكلة كانت بسيطة") != nil, true,
               "scribe check: a translation is rejected")
        expect(ScribeRouter.problem(polished: "Here's the polished text: hello", from: "hello there") != nil, true,
               "scribe check: an answer is rejected")
        expect(ScribeRouter.problem(polished: "لازم نعمل update للتطبيق.", from: "لازم نعمل update لل app") != nil, true,
               "scribe check: a lost English word is rejected")
        expect(ScribeRouter.problem(polished: "مرحبا، شو أخبارك؟", from: "مرحبا شو أخبارك آآ"), nil, "scribe check: a faithful polish passes")
        expect(ScribeRouter.tidyComposed("Subject: Meeting\n\nHi Sara,\n\nIt moved.\n\nBest,\n[Your Name]"), "Hi Sara,\n\nIt moved.\n\nBest,",
               "scribe tidy: no subject line or name placeholder")

        // --- Which dictations go through the slower self-correction rewrite ---
        expect(SmartCleanup.containsCorrectionCue("It shows bullets and stuff, you know what I mean?"), false,
               "cue: 'you know what I mean' is not a correction")
        expect(SmartCleanup.containsCorrectionCue("That's exactly what I meant."), false, "cue: 'what I meant' is not a correction")
        expect(SmartCleanup.containsCorrectionCue("Let's meet at two, I mean three."), true, "cue: 'I mean' after a slip is")
        expect(SmartCleanup.containsCorrectionCue("We need to make that change today."), false, "cue: 'make that change' is not a correction")
        expect(SmartCleanup.containsCorrectionCue("Two coffees, make that three."), true, "cue: 'make that three' is")

        // --- Finding the dictation again in the field, to learn from corrections ---
        let pasted = "Check the status on Darwesh and tell me"
        let webField = "Hi,\u{00A0}Check the status\u{00A0}on Darwesh and tell\u{00A0}me\u{00A0}" as NSString
        expect(CorrectionLearner.locate(pasted, in: webField, near: 4)?.location, 4,
               "learning: found in a web editor that uses non-breaking spaces")
        expect(CorrectionLearner.locate("First line.\n\nSecond line.", in: "First line.\nSecond line." as NSString, near: 0)?.length, 24,
               "learning: found when paragraph breaks became single line breaks")
        expect(CorrectionLearner.locate(pasted, in: "Something else entirely" as NSString, near: 0) == nil, true,
               "learning: not found where it is not")
        expect(CorrectionLearner.normalized(webField).length, webField.length, "learning: normalising keeps positions")

        // --- Did the text land? ---
        let field = AXUIElementCreateApplication(1)
        let other = AXUIElementCreateApplication(2)
        var textArea = FocusSnapshot()
        textArea.element = field
        textArea.role = "AXTextArea"
        textArea.value = "Hello"
        textArea.selection = NSRange(location: 5, length: 0)
        var typed = textArea
        typed.value = "Hello there"
        expect(InsertionCheck.judge(before: textArea, after: typed), .landed, "landing: the field's text changed")
        expect(InsertionCheck.judge(before: textArea, after: textArea), .unchanged, "landing: the field kept its text")
        expect(InsertionCheck.judge(before: textArea, after: FocusSnapshot()), .missed, "landing: nothing has the focus")
        var desktop = FocusSnapshot()
        desktop.element = other
        desktop.role = "AXList"
        expect(InsertionCheck.cannotTakeText(desktop), true, "landing: a list in Finder cannot take text")
        expect(InsertionCheck.cannotTakeText(FocusSnapshot()), false, "landing: an app that reports no focus is not judged early")
        var page = FocusSnapshot()
        page.element = other
        page.role = "AXWebArea"
        expect(InsertionCheck.cannotTakeText(page), true, "landing: a web page with no text box selected cannot take text")
        var editor = FocusSnapshot()
        editor.element = other
        editor.role = "AXGroup"
        expect(InsertionCheck.judge(before: editor, after: editor), .unknown, "landing: an editor that hides its text is trusted")

        // --- Listening on after the key comes up (levels: 20 ms slices, 0 silent … 1 loud) ---
        let speech = [Float](repeating: 0.7, count: 100)
        let room = [Float](repeating: 0.03, count: 20)
        expect(DictationController.endsQuietly(room + speech + [Float](repeating: 0.03, count: 10), recent: 10), true,
               "tail: a fifth of a second of quiet means the speaker has finished")
        expect(DictationController.endsQuietly(room + speech, recent: 10), false, "tail: still speaking at release keeps listening")
        expect(DictationController.endsQuietly(room + speech + [Float](repeating: 0.03, count: 5) + [0.3, 0.3, 0.3, 0.3, 0.03], recent: 10), false,
               "tail: a soft trailing sound keeps listening")
        let noisy = [Float](repeating: 0.45, count: 60)
        expect(DictationController.endsQuietly(noisy + speech + [Float](repeating: 0.45, count: 10), recent: 10), false,
               "tail: in a room too loud to tell, it listens for the whole half second")
        expect(DictationController.endsQuietly(room + speech + [0.03, 0.03, 0.03, 0.03, 0.6, 0.6, 0.03, 0.03, 0.03, 0.03], recent: 10), true,
               "tail: a key click is not speech")
        expect(DictationController.endsQuietly(room + speech + [0.03, 0.03, 0.03, 0.6, 0.6, 0.6, 0.03, 0.03, 0.03, 0.03], recent: 10), false,
               "tail: a sound that lasts is")
        let fan = [Float](repeating: 0.2, count: 60)
        expect(DictationController.endsQuietly(fan + speech + [Float](repeating: 0.2, count: 10), recent: 10), true,
               "tail: steady background noise is recognised as quiet")
    }
}
