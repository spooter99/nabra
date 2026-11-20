import Foundation

/// Synchronous wrapper around one transcribe.cpp model + session (ggml on Metal).
///
/// The model file is memory-mapped, so its weights live in reclaimable file-backed pages
/// rather than in the app's own memory. Not thread-safe: every call except `requestAbort()`
/// must come from the same serial queue.
final class SpeechEngine {
    struct Options {
        /// Language hint: "ar" or "en". For Arabic speech with English mixed in, use "ar".
        var language: String = "ar"
        /// Decode the same audio as the previous call again (under another language hint),
        /// skipping the encoder. Only valid immediately after a decode of identical audio.
        var reuseEncoder = false
    }

    struct Result {
        var text: String = ""
        /// The language hint this text was decoded under.
        var language: String = ""
        /// Mean log-probability of the decoded tokens (closer to 0 is more confident).
        var averageLogProbability: Float = 0
        var tokenCount: Int = 0
        var encodeMs: Double = 0
        var decodeMs: Double = 0
        var totalMs: Double = 0
        var audioSeconds: Double = 0
        var aborted: Bool = false
        var failed: Bool = false
        /// The decoder stopped early (output budget or repetition guard): the text is incomplete.
        var truncated: Bool = false
    }

    enum EngineError: LocalizedError {
        case loadFailed(String)
        var errorDescription: String? {
            switch self {
            case .loadFailed(let reason): return "Could not load the speech model (\(reason))."
            }
        }
    }

    static let sampleRate = 16_000
    /// Clips shorter than this are padded with silence; very short inputs decode unreliably.
    private static let minimumSamples = sampleRate / 2

    let modelPath: String
    private let model: OpaquePointer
    private let session: OpaquePointer
    private let abortFlag: OpaquePointer

    private static let quietLogs: Void = {
        transcribe_log_set({ level, message, _ in
            guard level == TRANSCRIBE_LOG_LEVEL_ERROR, let message else { return }
            fputs(message, stderr)
        }, nil)
    }()

    /// Routes the inference library's logging away from stderr (errors only).
    static func silenceLibraryLogs() {
        _ = quietLogs
    }

    init(modelPath: String) throws {
        _ = SpeechEngine.quietLogs
        var loadedModel: OpaquePointer?
        let loadStatus = transcribe_model_load_file(modelPath, nil, &loadedModel)
        guard loadStatus == TRANSCRIBE_OK, let loadedModel else {
            throw EngineError.loadFailed(SpeechEngine.describe(loadStatus))
        }
        var sessionParams = transcribe_session_params()
        transcribe_session_params_init(&sessionParams)
        sessionParams.n_threads = 4
        var openedSession: OpaquePointer?
        let sessionStatus = transcribe_session_init(loadedModel, &sessionParams, &openedSession)
        guard sessionStatus == TRANSCRIBE_OK, let openedSession else {
            transcribe_model_free(loadedModel)
            throw EngineError.loadFailed(SpeechEngine.describe(sessionStatus))
        }
        model = loadedModel
        session = openedSession
        self.modelPath = modelPath
        abortFlag = NabraFlagCreate()
        transcribe_set_abort_callback(openedSession, NabraAbortCallback, UnsafeMutableRawPointer(abortFlag))
    }

    deinit {
        transcribe_session_free(session)
        transcribe_model_free(model)
        NabraFlagDestroy(abortFlag)
    }

    /// Safe to call from any thread: makes a running `transcribe` return early.
    func requestAbort() {
        NabraFlagSet(abortFlag, true)
    }

    /// Runs one short decode so the Metal pipelines are compiled before the first real request.
    func warmUp() {
        let silence = [Float](repeating: 0, count: SpeechEngine.sampleRate)
        _ = transcribe(silence, options: Options(language: "en"))
    }

    func transcribe(_ samples: [Float], options: Options) -> Result {
        samples.withUnsafeBufferPointer { transcribe($0, options: options) }
    }

    func transcribe(_ input: UnsafeBufferPointer<Float>, options: Options) -> Result {
        var result = Result()
        result.language = options.language
        result.audioSeconds = Double(input.count) / Double(SpeechEngine.sampleRate)
        guard input.count > 0, let inputBase = input.baseAddress else { return result }

        NabraFlagSet(abortFlag, false)
        let started = DispatchTime.now().uptimeNanoseconds

        var params = transcribe_run_params()
        transcribe_run_params_init(&params)
        params.task = TRANSCRIBE_TASK_TRANSCRIBE
        params.timestamps = TRANSCRIBE_TIMESTAMPS_NONE

        transcribe_cohere_set_reuse_encoder(options.reuseEncoder)
        defer { transcribe_cohere_set_reuse_encoder(false) }
        let status: transcribe_status = options.language.withCString { language in
            params.language = language
            if input.count >= SpeechEngine.minimumSamples {
                return transcribe_run(session, inputBase, Int32(input.count), &params)
            }
            var padded = [Float](repeating: 0, count: SpeechEngine.minimumSamples)
            padded.withUnsafeMutableBufferPointer { $0.baseAddress!.update(from: inputBase, count: input.count) }
            return padded.withUnsafeBufferPointer { transcribe_run(session, $0.baseAddress, Int32($0.count), &params) }
        }

        result.totalMs = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        result.aborted = transcribe_was_aborted(session) || status == TRANSCRIBE_ERR_ABORTED
        result.truncated = status == TRANSCRIBE_ERR_OUTPUT_TRUNCATED || status == TRANSCRIBE_ERR_OUTPUT_REPETITION

        var timings = transcribe_timings()
        transcribe_timings_init(&timings)
        if transcribe_get_timings(session, &timings) == TRANSCRIBE_OK {
            result.encodeMs = Double(timings.mel_ms + timings.encode_ms)
            result.decodeMs = Double(timings.decode_ms)
        }
        if result.aborted { return result }
        // A truncated decode still carries usable partial text.
        guard status == TRANSCRIBE_OK || result.truncated else {
            result.failed = true
            Log.error("Speech engine error: \(SpeechEngine.describe(status))")
            return result
        }

        if let text = transcribe_full_text(session) {
            result.text = String(cString: text).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var logProbabilitySum: Float = 0
        var counted = 0
        let tokenCount = transcribe_n_tokens(session)
        for index in 0..<tokenCount {
            var token = transcribe_token()
            transcribe_token_init(&token)
            guard transcribe_get_token(session, index, &token) == TRANSCRIBE_OK, token.text != nil else { continue }
            guard token.p.isFinite, token.p > 0 else { continue }
            logProbabilitySum += log(token.p)
            counted += 1
        }
        result.tokenCount = Int(tokenCount)
        // The stock library reports no per-token probabilities for this model; the local patch does.
        result.averageLogProbability = counted > 0 ? logProbabilitySum / Float(counted)
            : transcribe_cohere_last_avg_logprob()
        return result
    }

    private static func describe(_ status: transcribe_status) -> String {
        guard let text = transcribe_status_string(Int32(status.rawValue)) else { return "status \(status.rawValue)" }
        return String(cString: text)
    }
}
