import Foundation

/// A downloadable speech model (Cohere Transcribe Arabic, GGUF for transcribe.cpp).
///
/// All variants are the same model at different compression levels. Measured accuracy is within
/// noise of each other, so the smallest is the default.
struct SpeechModel: Identifiable, Equatable {
    var id: String
    var title: String
    var detail: String
    var fileName: String
    var bytes: Int64
    var url: URL

    var localURL: URL { AppPaths.modelsDirectory.appendingPathComponent(fileName) }

    var isInstalled: Bool {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: localURL.path)[.size]) as? Int64 else {
            return false
        }
        return size == bytes
    }

    var sizeDescription: String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private static let base = "https://huggingface.co/handy-computer/cohere-transcribe-arabic-07-2026-gguf/resolve/main/"

    private static func make(_ id: String, _ title: String, _ detail: String, _ quant: String, _ bytes: Int64) -> SpeechModel {
        let file = "cohere-transcribe-arabic-07-2026-\(quant).gguf"
        return SpeechModel(id: id, title: title, detail: detail, fileName: file, bytes: bytes,
                           url: URL(string: base + file)!)
    }

    static let compact = make("cohere-arabic-q4", "Compact",
                              "Smallest on disk. Same accuracy in testing.", "Q4_K_M", 1_558_162_848)
    static let balanced = make("cohere-arabic-q5", "Balanced",
                               "A little larger, a little closer to the original weights.", "Q5_K_M", 1_770_270_112)
    static let high = make("cohere-arabic-q6", "High",
                           "Near-lossless compression.", "Q6_K", 1_972_524_448)

    static let all: [SpeechModel] = [.compact, .balanced, .high]
    static let defaultID = SpeechModel.compact.id

    static func model(id: String) -> SpeechModel {
        all.first { $0.id == id } ?? .compact
    }

    /// The chosen model if installed, otherwise any installed one.
    static func bestInstalled(preferred id: String) -> SpeechModel? {
        let preferred = model(id: id)
        if preferred.isInstalled { return preferred }
        return all.first { $0.isInstalled }
    }
}
