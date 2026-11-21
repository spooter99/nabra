import Foundation

/// Which of the two keys started a dictation.
enum DictationMode: Equatable {
    /// Your words, as you said them (tidied, never rewritten).
    case dictate
    /// Your words written up by a small local language model, or the text you asked it to write.
    case scribe
}

/// What Scribe is asked to write.
struct WritingRequest {
    /// What was said, after the usual clean-up.
    var transcript: String
    /// The app the text goes into, when known.
    var appName: String?
    var bundleID: String?
    /// The end of the text before the cursor, so names and tone can follow it. Empty when not shared.
    var textBefore: String = ""
}

/// A local language model that turns a transcript into finished text, streaming as it writes.
protocol TextWriter: AnyObject {
    /// The model is downloaded and the runtime is present.
    var isInstalled: Bool { get }
    /// Loads the model ahead of time. Safe to call often.
    func prepare()
    /// Writes. `onText` receives the whole text so far (main queue) while it is being generated;
    /// `completion` the final text, or nil when writing failed (main queue).
    func write(_ request: WritingRequest, job: ScribeRouter.Job, onText: @escaping (String) -> Void,
               completion: @escaping (String?) -> Void)
    /// Stops a write in progress; its completion receives nil.
    func cancel()
}
