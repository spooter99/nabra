import Foundation

/// What Scribe asks the writing model. The instructions and examples were tuned on real dictations
/// (Levantine Arabic, English and mixed) and are bundled as ScribePrompts.json: one set for polishing
/// what was said, one for composing a text that was asked for.
enum ScribePrompt {
    private struct Set: Decodable {
        struct Example: Decodable {
            var user: String
            var assistant: String
        }
        var system: String
        var examples: [Example]
    }

    private struct Bundled: Decodable {
        var polish: Set
        var compose: Set
    }

    private static let bundled: Bundled? = {
        guard let url = Bundle.main.url(forResource: "ScribePrompts", withExtension: "json"),
              let data = try? Data(contentsOf: url)
        else { return nil }
        return try? JSONDecoder().decode(Bundled.self, from: data)
    }()

    static var isAvailable: Bool { bundled != nil }

    /// The conversation sent for one request.
    static func messages(for request: WritingRequest, job: ScribeRouter.Job) -> [[String: String]] {
        guard let bundled else { return [] }
        let set: Set
        let languageLine: String
        switch job {
        case .polish:
            set = bundled.polish
            languageLine = "Spoken language: \(ScribeRouter.spokenLanguage(request.transcript))"
        case .compose:
            set = bundled.compose
            languageLine = "Write in: \(ScribeRouter.writeIn(request.transcript))"
        }
        var messages: [[String: String]] = [["role": "system", "content": set.system]]
        for example in set.examples {
            messages.append(["role": "user", "content": example.user])
            messages.append(["role": "assistant", "content": example.assistant])
        }
        var context: [String] = []
        if let app = request.appName, !app.isEmpty { context.append("App: \(app)") }
        let field = request.textBefore.trimmingCharacters(in: .whitespacesAndNewlines)
        if !field.isEmpty { context.append("Text already in the field: \(field.suffix(800))") }
        context.append(languageLine)
        let user = "<context>\n" + context.joined(separator: "\n") + "\n</context>\n<dictation>\(request.transcript)</dictation>"
        messages.append(["role": "user", "content": user])
        return messages
    }

    static func requestBody(for request: WritingRequest, job: ScribeRouter.Job, model: WriterModel) -> [String: Any] {
        let words = request.transcript.split(whereSeparator: { $0 == " " || $0 == "\n" }).count
        var body: [String: Any] = [
            "messages": messages(for: request, job: job),
            "stream": true,
            "temperature": 0,
            // The instructions and examples are the same every time: the server keeps them computed.
            "cache_prompt": true,
            "max_tokens": job == .polish ? 3 * words + 80 : 500,
        ]
        if !model.templateOptions.isEmpty { body["chat_template_kwargs"] = model.templateOptions }
        return body
    }

    /// Removes what small models sometimes wrap around the text: a thinking block, a code fence, a
    /// preface, surrounding quotation marks or the prompt's own tags.
    static func clean(_ raw: String) -> String {
        var text = raw
        if let end = text.range(of: "</think>") { text = String(text[end.upperBound...]) }
        if text.hasPrefix("<think>") { return "" }
        text = text.replacingOccurrences(of: "</?dictation>", with: "", options: .regularExpression)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        text = text.replacingOccurrences(of: "\\A```[a-z]*\\n?", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\n?```\\z", with: "", options: .regularExpression)
        if text.count > 1, let first = text.first, let last = text.last,
           (first == "\"" && last == "\"") || (first == "“" && last == "”") {
            text = String(text.dropFirst().dropLast())
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
