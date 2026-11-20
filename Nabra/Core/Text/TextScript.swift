import Foundation

/// Script detection and normalisation helpers shared by search, layout and learning.
enum TextScript {
    static func isArabic(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0600...0x06FF, 0x0750...0x077F, 0x08A0...0x08FF, 0xFB50...0xFDFF, 0xFE70...0xFEFF: return true
        default: return false
        }
    }

    static func isLatin(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x41...0x5A, 0x61...0x7A, 0xC0...0x24F: return true
        default: return false
        }
    }

    /// Counts of Arabic and Latin letters in `text`.
    static func letterCounts(_ text: String) -> (arabic: Int, latin: Int) {
        var arabic = 0
        var latin = 0
        for scalar in text.unicodeScalars {
            if isArabic(scalar), scalar.properties.isAlphabetic { arabic += 1 } else if isLatin(scalar) { latin += 1 }
        }
        return (arabic, latin)
    }

    /// True when the text should be laid out right-to-left (its first strong letters are Arabic).
    static func isRightToLeft(_ text: String) -> Bool {
        var arabic = 0
        var latin = 0
        for scalar in text.unicodeScalars.prefix(160) {
            if isArabic(scalar), scalar.properties.isAlphabetic { arabic += 1 } else if isLatin(scalar) { latin += 1 }
            if arabic + latin >= 24 { break }
        }
        return arabic > latin
    }

    static func containsArabic(_ text: String) -> Bool {
        text.unicodeScalars.contains { isArabic($0) && $0.properties.isAlphabetic }
    }

    /// Folds text for matching: lower-cases, strips Latin accents and Arabic diacritics/tatweel,
    /// and unifies Arabic letter variants (أ إ آ → ا, ى → ي, ة → ه, ؤ → و, ئ → ي).
    static func fold(_ text: String) -> String {
        var result = String.UnicodeScalarView()
        let lowered = text.lowercased().decomposedStringWithCanonicalMapping
        for scalar in lowered.unicodeScalars {
            switch scalar.value {
            case 0x0300...0x036F: continue                        // combining Latin accents
            case 0x064B...0x065F, 0x0670, 0x06D6...0x06ED: continue // Arabic diacritics
            case 0x0640: continue                                 // tatweel
            case 0x0622, 0x0623, 0x0625, 0x0671: result.append(Unicode.Scalar(0x0627)!)
            case 0x0649: result.append(Unicode.Scalar(0x064A)!)
            case 0x0629: result.append(Unicode.Scalar(0x0647)!)
            case 0x0624: result.append(Unicode.Scalar(0x0648)!)
            case 0x0626: result.append(Unicode.Scalar(0x064A)!)
            default: result.append(scalar)
            }
        }
        return String(result)
    }

    /// Folded text with everything except letters and digits removed.
    static func lettersOnly(_ text: String) -> String {
        String(String.UnicodeScalarView(fold(text).unicodeScalars.filter {
            $0.properties.isAlphabetic || $0.properties.numericType != nil
        }))
    }

    static func wordCount(_ text: String) -> Int {
        var count = 0
        text.enumerateSubstrings(in: text.startIndex..., options: [.byWords, .substringNotRequired]) { _, _, _, _ in
            count += 1
        }
        return count
    }

    /// Levenshtein distance between two strings (by Unicode scalar).
    static func editDistance(_ lhs: String, _ rhs: String) -> Int {
        let a = Array(lhs.unicodeScalars)
        let b = Array(rhs.unicodeScalars)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }

    /// 1 for identical strings, 0 for nothing in common.
    static func similarity(_ lhs: String, _ rhs: String) -> Double {
        let longest = max(lhs.unicodeScalars.count, rhs.unicodeScalars.count)
        guard longest > 0 else { return 1 }
        return 1 - Double(editDistance(lhs, rhs)) / Double(longest)
    }
}
