import Foundation

/// Writes spoken email and web addresses the way they are typed:
/// "team at zentro dot chat" becomes "team@zentro.chat", "sara dot k at gmail dot com" becomes
/// "sara.k@gmail.com", "whatsapp dot com" becomes "whatsapp.com".
///
/// An address must end in a known domain ending (.com, .chat, .app …), so ordinary uses of "at" and
/// "dot" stay as they are ("look at the dot", "the dot com bubble", "meet at google.com" when it is
/// about a place). The word before "at" must look like the start of an address, not like prose.
enum Addresses {
    private static let endings = "com|net|org|io|ai|co|app|dev|me|chat|info|biz|edu|gov|uk|us|ca|de|fr|es|it|nl|se|ch|au|in|"
        + "sa|ae|jo|eg|ps|lb|qa|kw|om|bh|tr|tech|xyz|so|sh|gg|tv|site|online|store|cloud|design|studio|page|link|live|email|"
        + "ly|to|fm|ie|be|cz|pl|pt|br|mx|jp|kr|cn|hk|sg|my|id|nz|za|ng|ke|ma|tn|dz|iq|sy|ye|ly|sd"
    /// Words that end prose before "at", never an address ("look at", "I'm at", "the team at").
    private static let notAnAddress: Set<String> = [
        "look", "looking", "looked", "arrive", "arrived", "arriving", "meet", "meeting", "met", "stay", "staying", "stayed",
        "work", "working", "worked", "works", "live", "living", "lives", "be", "been", "is", "are", "was", "were", "am", "i'm",
        "it's", "he's", "she's", "we're", "they're", "you're", "me", "you", "him", "her", "us", "them", "it", "this", "that",
        "these", "those", "here", "there", "home", "school", "office", "good", "great", "bad", "best", "better", "worse",
        "aimed", "aim", "point", "pointing", "pointed", "stare", "staring", "laugh", "laughing", "smile", "smiling", "yell",
        "shoot", "glance", "hint", "available", "located", "based", "start", "starting", "starts", "started", "end", "ends",
        "open", "opens", "close", "closes", "the", "a", "an", "and", "or", "but", "so", "then", "also", "just", "only", "all",
        "not", "even", "right", "left", "back", "out", "up", "down", "over", "off", "sit", "sitting", "stand", "standing",
        "wait", "waiting", "call", "calling", "called", "him", "anyone", "someone", "everyone", "people", "guys", "we", "they",
        "i", "he", "she", "what", "where", "when", "who", "how", "why", "read", "check", "checked", "see", "saw", "go", "went",
    ]
    /// Words around that say an email address is being given.
    private static let emailContext = "(?i)(?<![\\p{L}])(?:e-?mails?|mail|address|contact|reach|write\\s+to|send\\s+(?:it|this|that)?\\s*to)(?![\\p{L}])"

    static func format(_ text: String) -> String {
        guard text.range(of: "(?i)(?<![\\p{L}])(?:dot|at)(?![\\p{L}])|@|\\.", options: .regularExpression) != nil else { return text }
        var result = text

        // 1. Domains said with "dot": "zentro dot chat", "www dot google dot co dot uk".
        result = replaceAll(in: result, "(?i)(?<![\\p{L}\\p{N}@.-])([a-z0-9][a-z0-9-]*)((?:\\s+dot\\s+[a-z0-9-]+)*)\\s+dot\\s+(\(endings))(?![\\p{L}\\p{N}])") { match, text in
            let first = text[match.range(at: 1)].lowercased()
            guard !notAnAddress.contains(first) else { return nil }
            let middle = text[match.range(at: 2)].replacingOccurrences(of: "(?i)\\s+dot\\s+", with: ".", options: .regularExpression)
            return text[match.range(at: 1)] + middle + "." + text[match.range(at: 3)].lowercased()
        }

        // 2. Spacing the recogniser put inside written addresses: "name @ gmail . com", "gmail. com".
        result = replaceAll(in: result, "(?i)([a-z0-9._-]+)\\s*@\\s*([a-z0-9-]+(?:\\s*\\.\\s*[a-z0-9-]+)*)") { match, text in
            text[match.range(at: 1)] + "@" + text[match.range(at: 2)].replacingOccurrences(of: "\\s*\\.\\s*", with: ".", options: .regularExpression)
        }

        // 3. "at" between a name and a domain: "team at zentro.chat" is an email address.
        result = replaceAll(in: result, "(?i)(?<![\\p{L}\\p{N}._@-])([a-z0-9][a-z0-9._-]*)\\s+at\\s+([a-z0-9][a-z0-9-]*(?:\\.[a-z0-9-]+)*\\.(?:\(endings)))(?![\\p{L}\\p{N}@-])") { match, text in
            let local = text[match.range(at: 1)]
            guard !notAnAddress.contains(local.lowercased()) else { return nil }
            // After "the" or "a" it may be a team at a company; take it as an address only when the
            // sentence is about email.
            let before = text.substring(to: match.range.location)
            let words = before.split(whereSeparator: { $0 == " " || $0 == "\n" })
            if let previous = words.last?.lowercased(), ["the", "a", "an", "our", "my", "your"].contains(previous) {
                let after = text.substring(from: NSMaxRange(match.range))
                let sentence = String(before.suffix(120)) + " " + String(after.prefix(40))
                guard sentence.range(of: emailContext, options: .regularExpression) != nil else { return nil }
            }
            return (local + "@" + text[match.range(at: 2)]).lowercased()
        }

        // 4. Dots, underscores and dashes said inside the name part: "sara dot k@gmail.com".
        var previous = ""
        while previous != result {
            previous = result
            result = replaceAll(in: result, "(?i)(?<![\\p{L}\\p{N}._-])([a-z0-9]+)\\s+(dot|underscore|dash|hyphen)\\s+([a-z0-9._-]*[a-z0-9]@)") { match, text in
                let separator: String
                switch text[match.range(at: 2)].lowercased() {
                case "dot": separator = "."
                case "underscore": separator = "_"
                default: separator = "-"
                }
                return (text[match.range(at: 1)] + separator + text[match.range(at: 3)]).lowercased()
            }
        }
        // Addresses are written in lower case, whatever the recogniser capitalised.
        result = replaceAll(in: result, "[A-Za-z0-9._-]+@[A-Za-z0-9-]+(?:\\.[A-Za-z0-9-]+)+") { match, text in
            text[match.range].lowercased()
        }
        return result
    }

    /// Replaces every match from the end backwards; `make` returns nil to leave a match alone.
    private static func replaceAll(in text: String, _ pattern: String, _ make: (NSTextCheckingResult, NSString) -> String?) -> String {
        guard let regex = TextPipeline.regex(pattern) else { return text }
        let ns = text as NSString
        var result = text as NSString
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            guard let replacement = make(match, ns) else { continue }
            result = result.replacingCharacters(in: match.range, with: replacement) as NSString
        }
        return result as String
    }
}

private extension NSString {
    subscript(_ range: NSRange) -> String {
        range.location == NSNotFound ? "" : substring(with: range)
    }
}
