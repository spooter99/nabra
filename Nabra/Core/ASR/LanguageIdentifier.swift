import Foundation

/// Decides whether a clip is Arabic or English (VoxLingua107 ECAPA via transcribe.cpp, ~15 ms per clip).
/// Not thread-safe.
final class LanguageIdentifier {
    private let model: OpaquePointer
    private let session: OpaquePointer
    /// The model needs at least this much audio.
    static let minimumSamples = SpeechEngine.sampleRate * 6 / 10

    init?(modelPath: String) {
        var loadedModel: OpaquePointer?
        guard transcribe_model_load_file(modelPath, nil, &loadedModel) == TRANSCRIBE_OK, let loadedModel else {
            return nil
        }
        var openedSession: OpaquePointer?
        guard transcribe_langid_session_init(loadedModel, nil, &openedSession) == TRANSCRIBE_OK, let openedSession else {
            transcribe_model_free(loadedModel)
            return nil
        }
        model = loadedModel
        session = openedSession
    }

    deinit {
        transcribe_langid_session_free(session)
        transcribe_model_free(model)
    }

    static var bundledModelPath: String? {
        Bundle.main.path(forResource: "lang-id", ofType: "gguf")
    }

    /// Probability that the clip is English rather than Arabic, or nil when it is too short to tell.
    func englishProbability(_ samples: UnsafeBufferPointer<Float>) -> Float? {
        guard samples.count >= LanguageIdentifier.minimumSamples, let base = samples.baseAddress else { return nil }
        let arabic = strdup("ar")
        let english = strdup("en")
        defer {
            free(arabic)
            free(english)
        }
        var allowed: [UnsafePointer<CChar>?] = [UnsafePointer(arabic), UnsafePointer(english)]
        var params = transcribe_langid_params()
        transcribe_langid_params_init(&params)
        let status: transcribe_status = allowed.withUnsafeMutableBufferPointer { buffer in
            params.allowed = UnsafePointer(buffer.baseAddress)
            params.n_allowed = 2
            return transcribe_langid_run(session, base, Int32(samples.count), &params)
        }
        guard status == TRANSCRIBE_OK else { return nil }
        for index in 0..<2 {
            var candidate = transcribe_langid_candidate()
            transcribe_langid_candidate_init(&candidate)
            guard transcribe_langid_get_candidate(session, Int32(index), &candidate) == TRANSCRIBE_OK,
                  let code = candidate.code
            else { continue }
            if String(cString: code) == "en" { return candidate.p }
        }
        return nil
    }
}
