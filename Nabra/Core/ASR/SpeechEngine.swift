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
        /// Also work out when each piece of text was heard (`Token.time`). Costs a little decode time.
        var tokenTimes = false
        /// Do not transcribe: feed the model these token ids and report how probable it finds them
        /// for this audio. Used to let the model judge a transcript assembled from other decodes.
        var forcedTokens: [Int32] = []
    }

    /// One piece of the decoded text (a word or part of one).
    struct Token {
        /// The model's id for this piece.
        var id: Int32
        /// The text fragment; a leading space marks the start of a word.
        var text: String
        /// Natural log of the model's probability for this piece. NaN when unknown.
        var logProbability: Float
        /// Where in the audio the model was listening when it wrote this piece, in seconds. NaN when unknown.
        var time: Float = .nan
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
        /// The pieces the text was built from, in order.
        var tokens: [Token] = []
        /// Log-probability the model gave to the text ending where it does. NaN when unknown.
        var endLogProbability: Float = .nan
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
        // Silence alone ends before the decoder takes a single step, so feed it a few pieces: that
        // exercises the step graph, including the attention read-out used for word times.
        _ = transcribe(silence, options: Options(language: "en", tokenTimes: true, forcedTokens: [1000, 1001, 1002, 1003]))
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
        if options.tokenTimes {
            TokenTiming.alignmentHeads.withUnsafeBufferPointer {
                transcribe_cohere_set_alignment_heads($0.baseAddress, Int32($0.count / 2))
            }
        }
        if !options.forcedTokens.isEmpty {
            options.forcedTokens.withUnsafeBufferPointer {
                transcribe_cohere_set_forced_tokens($0.baseAddress, Int32($0.count))
            }
        }
        defer {
            transcribe_cohere_set_reuse_encoder(false)
            transcribe_cohere_set_alignment_heads(nil, 0)
            transcribe_cohere_set_forced_tokens(nil, 0)
        }
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
            guard transcribe_get_token(session, index, &token) == TRANSCRIBE_OK, let text = token.text else { continue }
            let known = token.p.isFinite && token.p > 0
            result.tokens.append(Token(id: token.id, text: String(cString: text),
                                       logProbability: known ? log(token.p) : .nan,
                                       time: token.t1_ms > 0 ? Float(token.t0_ms) / 1000 : .nan))
            guard known else { continue }
            logProbabilitySum += log(token.p)
            counted += 1
        }
        result.tokenCount = Int(tokenCount)
        // The stock library reports no per-token probabilities for this model; the local patch does.
        result.averageLogProbability = counted > 0 ? logProbabilitySum / Float(counted)
            : transcribe_cohere_last_avg_logprob()
        result.endLogProbability = transcribe_cohere_last_end_logprob()
        return result
    }

    private static func describe(_ status: transcribe_status) -> String {
        guard let text = transcribe_status_string(Int32(status.rawValue)) else { return "status \(status.rawValue)" }
        return String(cString: text)
    }
}

/// Which parts of the decoder tell where in the audio a token came from.
enum TokenTiming {
    /// (layer, head) pairs of the decoder's cross-attention that move steadily through the audio as
    /// text is written. Found by dumping every head on a set of recordings and keeping the ones
    /// that agree with each other (`eval/tools/alignment_heads.py`); they belong to this model.
    static let alignmentHeads: [Int32] = [6, 3, 3, 0, 1, 6, 4, 1, 5, 6, 6, 7]
}
