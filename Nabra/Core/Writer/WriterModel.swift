import Foundation

/// The language model Scribe writes with: one small instruct model in GGUF form, downloaded on demand.
struct WriterModel: Equatable {
    var id: String
    var title: String
    var detail: String
    var fileName: String
    var bytes: Int64
    var url: URL
    /// Extra arguments for the helper (llama.cpp's server) that this model needs.
    var extraArguments: [String] = []
    /// Settings sent with every request (for example to switch a model's thinking mode off).
    var templateOptions: [String: Any] = [:]
    /// A small companion model that lets the server write several tokens per step (same output, faster).
    var drafter: WriterModel.File?

    struct File: Equatable {
        var fileName: String
        var bytes: Int64
        var url: URL
        var localURL: URL { AppPaths.modelsDirectory.appendingPathComponent(fileName) }
        var isInstalled: Bool {
            (try? FileManager.default.attributesOfItem(atPath: localURL.path)[.size]) as? Int64 == bytes
        }
        func download(id: String, title: String) -> SpeechModel {
            SpeechModel(id: id, title: title, detail: "", fileName: fileName, bytes: bytes, url: url)
        }
    }

    static func == (lhs: WriterModel, rhs: WriterModel) -> Bool { lhs.id == rhs.id }

    /// Set only for a model file somewhere else (testing with `NABRA_WRITER_MODEL`).
    var path: URL?

    var localURL: URL { path ?? AppPaths.modelsDirectory.appendingPathComponent(fileName) }

    var isInstalled: Bool {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: localURL.path)[.size]) as? Int64 else { return false }
        return size == bytes
    }

    var sizeDescription: String { ByteCountFormatter.string(fromByteCount: bytes + (drafter?.bytes ?? 0), countStyle: .file) }

    /// The same file described for the shared downloader.
    var download: SpeechModel {
        SpeechModel(id: id, title: title, detail: detail, fileName: fileName, bytes: bytes, url: url)
    }

    /// Chosen by measuring candidates on real dictations for faithfulness (above all in Arabic),
    /// speed and memory.
    static var current: WriterModel {
        if let override = ProcessInfo.processInfo.environment["NABRA_WRITER_MODEL"], !override.isEmpty {
            let url = URL(fileURLWithPath: override)
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int64 ?? 0
            return WriterModel(id: "writer-test", title: url.lastPathComponent, detail: "", fileName: url.lastPathComponent,
                               bytes: size, url: url, path: url)
        }
        return .gemma4E2B
    }

    /// Gemma 4 E2B (Google, Apache-2.0) in the 4-bit build made from Google's quantisation-aware
    /// checkpoint, with its drafter. Chosen over Qwen 3.5 (0.8B to 4B), Gemma 4 E4B and Gemma 3 4B:
    /// the only small model that kept Levantine Arabic Levantine on every test, never translated a
    /// mixed sentence, and still wrote good emails; about 0.15 s for a short dictation on an M5.
    /// The revision is pinned because the files are regenerated upstream.
    static let gemma4E2B = WriterModel(
        id: "writer-gemma4-e2b", title: "Gemma 4 E2B",
        detail: "Google's small open model, run on this Mac. Downloaded once.",
        fileName: "gemma-4-E2B-it-Q4_0.gguf", bytes: 2_841_481_184,
        url: URL(string: "https://huggingface.co/ggml-org/gemma-4-E2B-it-GGUF/resolve/2a8538c2e2d4687953a86c422c7c623cfd022880/gemma-4-E2B-it-Q4_0.gguf")!,
        drafter: File(fileName: "mtp-gemma-4-E2B-it-Q4_0.gguf", bytes: 59_235_872,
                      url: URL(string: "https://huggingface.co/ggml-org/gemma-4-E2B-it-GGUF/resolve/2a8538c2e2d4687953a86c422c7c623cfd022880/mtp-gemma-4-E2B-it-Q4_0.gguf")!))
}
