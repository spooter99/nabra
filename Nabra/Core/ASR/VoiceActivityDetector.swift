import Foundation

/// Voice-activity detection (Silero VAD on the CPU via transcribe.cpp).
/// One speech probability per 512-sample (32 ms) frame. Not thread-safe.
final class VoiceActivityDetector {
    static let frameSamples = 512
    static let frameSeconds = Double(frameSamples) / Double(SpeechEngine.sampleRate)

    private let model: OpaquePointer
    private let session: OpaquePointer

    init?(modelPath: String) {
        var loadedModel: OpaquePointer?
        guard transcribe_model_load_file(modelPath, nil, &loadedModel) == TRANSCRIBE_OK, let loadedModel else {
            return nil
        }
        var params = transcribe_vad_session_params()
        transcribe_vad_session_params_init(&params)
        params.n_threads = 1
        var openedSession: OpaquePointer?
        guard transcribe_vad_session_init(loadedModel, &params, &openedSession) == TRANSCRIBE_OK, let openedSession else {
            transcribe_model_free(loadedModel)
            return nil
        }
        model = loadedModel
        session = openedSession
    }

    deinit {
        transcribe_vad_session_free(session)
        transcribe_model_free(model)
    }

    /// Bundled model location.
    static var bundledModelPath: String? {
        Bundle.main.path(forResource: "silero-vad", ofType: "gguf")
    }

    /// Starts a new stream. Call between utterances.
    func reset() {
        transcribe_vad_stream_reset(session)
    }

    /// Feeds audio of any length; returns the probabilities of the frames this call completed.
    func feed(_ samples: UnsafeBufferPointer<Float>) -> [Float] {
        guard samples.count > 0, let base = samples.baseAddress else { return [] }
        guard transcribe_vad_stream_feed(session, base, Int32(samples.count)) == TRANSCRIBE_OK else { return [] }
        return lastProbabilities()
    }

    /// Per-frame probabilities for a whole clip (resets the stream first).
    func probabilities(for samples: [Float]) -> [Float] {
        reset()
        var all = samples.withUnsafeBufferPointer { feed($0) }
        if transcribe_vad_stream_flush(session) == TRANSCRIBE_OK { all += lastProbabilities() }
        return all
    }

    private func lastProbabilities() -> [Float] {
        var result = transcribe_vad_result()
        transcribe_vad_result_init(&result)
        guard transcribe_vad_get_result(session, &result) == TRANSCRIBE_OK, result.n_probs > 0,
              let probabilities = transcribe_vad_probs(session)
        else { return [] }
        return Array(UnsafeBufferPointer(start: probabilities, count: Int(result.n_probs)))
    }
}
