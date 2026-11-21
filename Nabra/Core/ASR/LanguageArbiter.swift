import Foundation

/// Decides what was said from two decodes of the same audio: one told "English", one told "Arabic".
///
/// 1. Pick the decode to build on. When both wrote the same script that is easy. When one wrote
///    English and the other Arabic, one of them is translating: the model is far surer of a
///    transcript than of a translation. When its two scores are close, each text is also scored
///    under the other hint, which separates the cases much better.
/// 2. Weave. Where the chosen decode is unsure of a word and the other decode heard a confident
///    word of the other script at that moment (an Arabic name in an English sentence), swap it in,
///    then let the model score the combined sentence under both hints. The swap is kept only when
///    the model itself finds the combined sentence more likely.
/// 3. If step 1 stays open even after cross-scoring, both versions are built and the one the model
///    finds more likely overall wins.
///
/// The engine is reached only through `Scorer`, so the rules can be tested without a model.
enum LanguageArbiter {
    /// Feeds the model a transcript (token ids) under a language hint and returns how probable it
    /// finds each piece. `withTimes` also asks for when each piece was heard.
    typealias Scorer = (_ tokenIDs: [Int32], _ language: String, _ withTimes: Bool) -> SpeechEngine.Result

    struct Outcome {
        var result: SpeechEngine.Result
        /// How the decision was reached, for the log.
        var note: String
        /// The decision was interrupted; `result` is not usable.
        var aborted = false
    }

    /// A decode whose average confidence is this much better than the other's is taken without further checks.
    static let clearMargin: Float = 0.30
    /// After cross-scoring, a combined margin this large settles which decode to build on.
    static let decisiveMargin: Float = 0.50
    /// A cross-scored margin smaller than this is a dead heat.
    static let tieMargin: Float = 0.05
    /// Between two decodes in the same script, the one whose hint matches the script wins unless it is this much worse.
    static let sameScriptMargin: Float = 0.15
    /// How far recent context tips an otherwise even decision: on the averaged margin, and in nats on whole sentences.
    static let contextBias: Float = 0.10
    static let contextBiasTotal: Float = 1.5
    /// The model must find a woven sentence this much more likely (in nats, both hints together) to keep it.
    static let weaveGain: Float = 0.5
    /// A swap that makes the sentence this much less likely under its own hint is dropped at once.
    static let screeningFloor: Float = -6.0
    /// Swaps considered per stretch of speech; each costs decoder passes.
    static let maximumIslands = 3

    static func resolve(english: SpeechEngine.Result, arabic: SpeechEngine.Result, recentLanguage: String?,
                        keyboardIsArabic: Bool, score: Scorer) -> Outcome {
        if english.text.isEmpty != arabic.text.isEmpty {
            let chosen = english.text.isEmpty ? arabic : english
            return Outcome(result: chosen, note: "only \(chosen.language) heard speech")
        }
        if english.text.isEmpty { return Outcome(result: english, note: "") }
        guard !english.tokens.isEmpty, !arabic.tokens.isEmpty else {
            // No per-piece detail to work with: fall back to each decode's own confidence.
            let chosen = english.averageLogProbability >= arabic.averageLogProbability ? english : arabic
            return Outcome(result: chosen, note: "no detail: \(chosen.language)")
        }

        var note = String(format: "en %.2f vs ar %.2f", english.averageLogProbability, arabic.averageLogProbability)
        var interrupted: SpeechEngine.Result?
        var crossScores: [String: SpeechEngine.Result] = [:]

        /// `decode`'s own text scored under the other hint. Nil when interrupted.
        func cross(_ decode: SpeechEngine.Result) -> SpeechEngine.Result? {
            if let known = crossScores[decode.language] { return known }
            let scored = score(decode.tokens.map(\.id), decode.language == "en" ? "ar" : "en", false)
            if scored.aborted {
                interrupted = scored
                return nil
            }
            crossScores[decode.language] = scored
            return scored
        }

        /// The best transcript built on `base`: itself, or with words woven in from `other`.
        /// `total` is its likelihood under both hints together, when that was worked out.
        func build(on base: SpeechEngine.Result, from other: SpeechEngine.Result,
                   needTotal: Bool) -> (result: SpeechEngine.Result, total: Float?, woven: Bool, note: String)? {
            let otherLanguage = base.language == "en" ? "ar" : "en"
            let seconds = Float(base.audioSeconds)
            // Only Arabic words are woven into English text. The other way round is left to the
            // Arabic hint, which already writes English words in Latin when it hears them; in
            // testing the model never preferred a swap there, so trying only cost time.
            let weaves = LanguageWeaver.dominantScript(base.tokens) == .latin
            guard weaves, LanguageWeaver.find(base: base.tokens, other: other.tokens, audioSeconds: seconds) != nil else {
                guard needTotal else { return (base, nil, false, "") }
                guard let baseCross = cross(base) else { return nil }
                return (base, likelihood(base) + likelihood(baseCross), false, "")
            }
            guard let baseCross = cross(base) else { return nil }
            let baseOwn = likelihood(base)
            let baseTotal = baseOwn + likelihood(baseCross)
            guard baseCross.tokens.count == base.tokens.count,
                  let found = LanguageWeaver.find(base: base.tokens, baseCross: baseCross.tokens.map(\.logProbability),
                                                  other: other.tokens, audioSeconds: seconds)
            else { return (base, baseTotal, false, "") }

            /// Scores a transcript under the base's own hint. Nil when interrupted or unusable.
            func scoreOwn(_ proposal: LanguageWeaver.Proposal) -> SpeechEngine.Result?? {
                let scored = score(proposal.tokenIDs, base.language, true)
                if scored.aborted {
                    interrupted = scored
                    return nil
                }
                return .some(!scored.failed && scored.tokens.count == proposal.tokenIDs.count ? scored : nil)
            }

            // With several candidate swaps, try each on its own first: one bad swap must not sink
            // the good ones, and a clearly bad one is dropped after a single pass.
            var islands = Array(found.islands.prefix(maximumIslands))
            var dropped: [String] = []
            var woven: SpeechEngine.Result?
            if islands.count > 1 {
                var kept: [LanguageWeaver.Island] = []
                for island in islands {
                    let single = LanguageWeaver.splice(found, islands: [island])
                    guard let scored = scoreOwn(single) else { return nil }
                    if let scored, likelihood(scored) - baseOwn >= screeningFloor {
                        kept.append(island)
                        woven = scored
                    } else {
                        dropped.append(single.summary)
                    }
                }
                islands = kept
                if islands.count != 1 { woven = nil }
            }
            let droppedNote = dropped.isEmpty ? "" : " (not \(dropped.joined(separator: "; ")))"
            guard !islands.isEmpty else { return (base, baseTotal, false, droppedNote) }

            let proposal = LanguageWeaver.splice(found, islands: islands)
            if woven == nil {
                guard let scored = scoreOwn(proposal) else { return nil }
                woven = scored
            }
            guard var woven, likelihood(woven) - baseOwn >= screeningFloor else {
                return (base, baseTotal, false, droppedNote + " (not \(proposal.summary))")
            }
            let wovenCross = score(proposal.tokenIDs, otherLanguage, false)
            if wovenCross.aborted { interrupted = wovenCross; return nil }
            guard !wovenCross.failed, wovenCross.tokens.count == proposal.tokenIDs.count else {
                return (base, baseTotal, false, droppedNote)
            }

            let wovenTotal = likelihood(woven) + likelihood(wovenCross)
            let gain = wovenTotal - baseTotal
            guard gain >= weaveGain else {
                return (base, baseTotal, false, droppedNote + String(format: " (not %@, %+.1f)", proposal.summary, gain))
            }
            woven.language = base.language
            woven.truncated = base.truncated
            return (woven, wovenTotal, true, String(format: ", wove %@ (%+.1f)", proposal.summary, gain) + droppedNote)
        }

        // --- Which decode to build on ----------------------------------------------------------------
        let scoreEnglish = english.averageLogProbability - (english.truncated ? 0.5 : 0)
        let scoreArabic = arabic.averageLogProbability - (arabic.truncated ? 0.5 : 0)
        let englishIsArabicScript = arabicShare(english.text) >= 0.5
        let arabicIsArabicScript = arabicShare(arabic.text) >= 0.5
        var baseIsEnglish: Bool?
        var crossMargin: Float = 0
        if let fuller = fullerDecode(english, arabic) {
            // One version says much more and is itself confident: the other one dropped speech.
            baseIsEnglish = fuller.language == "en"
            note += ", \(fuller.language) covers more"
        } else if !englishIsArabicScript, !arabicIsArabicScript {
            // Both wrote English. The English hint punctuates and capitalises better.
            baseIsEnglish = scoreArabic - scoreEnglish <= sameScriptMargin
            note += ", both English"
        } else if englishIsArabicScript, arabicIsArabicScript {
            // Both wrote Arabic. The Arabic hint spells better.
            baseIsEnglish = scoreEnglish - scoreArabic > sameScriptMargin
            note += ", both Arabic"
        } else if abs(scoreEnglish - scoreArabic) >= clearMargin {
            baseIsEnglish = scoreEnglish > scoreArabic
        } else {
            // Too close to call from each decode's own confidence: ask each hint about the other text.
            guard let underArabic = cross(english), let underEnglish = cross(arabic) else {
                return Outcome(result: interrupted ?? english, note: note, aborted: true)
            }
            var margin = (scoreEnglish + underArabic.averageLogProbability) - (scoreArabic + underEnglish.averageLogProbability)
            if recentLanguage == "en" { margin += contextBias }
            if recentLanguage == "ar" { margin -= contextBias }
            if recentLanguage == nil, keyboardIsArabic { margin -= contextBias / 3 }
            note += String(format: ", cross-checked %+.2f", margin)
            crossMargin = margin
            if abs(margin) >= decisiveMargin { baseIsEnglish = margin > 0 }
        }

        if let baseIsEnglish {
            let base = baseIsEnglish ? english : arabic
            guard let built = build(on: base, from: baseIsEnglish ? arabic : english, needTotal: false) else {
                return Outcome(result: interrupted ?? base, note: note, aborted: true)
            }
            return Outcome(result: built.result, note: note + ": \(base.language)" + built.note)
        }

        // --- Still open: build both and let the model choose ---------------------------------------
        guard let onEnglish = build(on: english, from: arabic, needTotal: true),
              let onArabic = build(on: arabic, from: english, needTotal: true),
              let totalEnglish = onEnglish.total, let totalArabic = onArabic.total
        else { return Outcome(result: interrupted ?? english, note: note, aborted: true) }
        var difference = totalEnglish - totalArabic
        if recentLanguage == "en" { difference += contextBiasTotal }
        if recentLanguage == "ar" { difference -= contextBiasTotal }
        if recentLanguage == nil, keyboardIsArabic { difference -= contextBiasTotal / 3 }
        // Whole-sentence likelihood favours whichever text is shorter, so it only decides when the
        // two languages really are mixed (something was woven) or the cross-check is a dead heat.
        let englishWins: Bool
        if onEnglish.woven || onArabic.woven || abs(crossMargin) < tieMargin {
            englishWins = difference >= 0
            note += String(format: ", whole sentence %+.1f", difference)
        } else {
            englishWins = crossMargin > 0
        }
        let chosen = englishWins ? onEnglish : onArabic
        return Outcome(result: chosen.result, note: note + ": \(englishWins ? "en" : "ar")" + chosen.note)
    }

    /// Total log-probability of a transcript, including that it ends where it does.
    static func likelihood(_ result: SpeechEngine.Result) -> Float {
        LanguageWeaver.total(result.tokens.map(\.logProbability))
            + (result.endLogProbability.isFinite ? result.endLogProbability : 0)
    }

    /// When one decode holds clearly more text and is confident about it, returns that one.
    ///
    /// Under the English hint the model can skip an Arabic sentence entirely and be very sure about
    /// the little English it did write.
    static func fullerDecode(_ a: SpeechEngine.Result, _ b: SpeechEngine.Result) -> SpeechEngine.Result? {
        let lengthA = letters(a.text)
        let lengthB = letters(b.text)
        let longer = lengthA >= lengthB ? a : b
        guard Double(min(lengthA, lengthB)) < Double(max(lengthA, lengthB)) * 0.7,
              longer.averageLogProbability > -0.35, !longer.truncated
        else { return nil }
        return longer
    }

    private static func letters(_ text: String) -> Int {
        text.unicodeScalars.reduce(0) { $0 + ($1.properties.isAlphabetic ? 1 : 0) }
    }

    /// Share of the text's letters that are Arabic (0 when it has none).
    static func arabicShare(_ text: String) -> Double {
        let counts = TextScript.letterCounts(text)
        let total = counts.arabic + counts.latin
        return total > 0 ? Double(counts.arabic) / Double(total) : 0
    }
}
