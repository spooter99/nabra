import Foundation

/// Headless entry points used for benchmarking and automated checks:
///   Nabra --eval <manifest.jsonl> --model <path> [options]
///   Nabra --transcribe <audio file> --model <path> [options]
enum CommandLineTool {
    static func shouldRun(arguments: [String]) -> Bool {
        arguments.contains("--format")
            || arguments.contains("--eval") || arguments.contains("--transcribe") || arguments.contains("--simulate")
            || arguments.contains("--seed-demo") || arguments.contains("--selftest") || arguments.contains("--polish")
            || arguments.contains("--download-model") || arguments.contains("--render-indicator")
            || arguments.contains("--probe") || arguments.contains("--capture-bench") || arguments.contains("--scribe")
    }

    private struct Arguments {
        private var values: [String: String] = [:]
        private var flags: Set<String> = []

        init(_ raw: [String]) {
            var index = 1
            while index < raw.count {
                let item = raw[index]
                if item.hasPrefix("--") {
                    if index + 1 < raw.count, !raw[index + 1].hasPrefix("--") {
                        values[item] = raw[index + 1]
                        index += 2
                        continue
                    }
                    flags.insert(item)
                }
                index += 1
            }
        }

        func string(_ key: String) -> String? { values[key] }
        func int(_ key: String) -> Int? { values[key].flatMap(Int.init) }
        func has(_ key: String) -> Bool { flags.contains(key) || values[key] != nil }
    }

    static func run(arguments raw: [String]) -> Int32 {
        let arguments = Arguments(raw)
        if let manifest = arguments.string("--eval"), arguments.string("--lang") == nil {
            return evaluatePipeline(manifest: manifest, arguments: arguments)
        }
        if let file = arguments.string("--simulate") {
            return simulate(file: file, arguments: arguments)
        }
        if arguments.has("--seed-demo") { return seedDemo() }
        if arguments.has("--download-model") { return downloadModel(id: arguments.string("--download-model")) }
        if let directory = arguments.string("--render-indicator") {
            return MainActor.assumeIsolated { DocsRenderer.renderIndicator(to: directory) }
        }
        if let text = arguments.string("--format") { return format(text) }
        if let text = arguments.string("--scribe") { return scribe(text, app: arguments.string("--app")) }
        if let report = arguments.string("--capture-bench") {
            return CaptureBench.run(reportPath: report, runs: arguments.int("--runs") ?? 4,
                                    gap: Double(arguments.string("--gap") ?? "5") ?? 5,
                                    paths: (arguments.string("--paths") ?? "direct,engine").split(separator: ",").map(String.init))
        }
        if let text = arguments.string("--polish") { return polish(text, force: arguments.has("--always")) }
        if arguments.has("--selftest") { return SelfTest.run() }
        guard let modelPath = arguments.string("--model") else {
            fputs("missing --model <path>\n", stderr)
            return 2
        }
        let engine: SpeechEngine
        do {
            let started = Date()
            engine = try SpeechEngine(modelPath: modelPath)
            engine.warmUp()
            fputs(String(format: "model ready in %.0f ms\n", Date().timeIntervalSince(started) * 1000), stderr)
        } catch {
            fputs("\(error.localizedDescription)\n", stderr)
            return 1
        }

        var options = SpeechEngine.Options()
        if let language = arguments.string("--lang") { options.language = language }
        if let dump = arguments.string("--attn-dump") { setenv("NABRA_ATTN_DUMP", dump, 1) }
        if arguments.has("--tokens") || arguments.has("--attn-dump") { options.tokenTimes = true }

        if let file = arguments.string("--probe") {
            return probe(file: file, engine: engine, weave: arguments.string("--weave"))
        }
        if let file = arguments.string("--transcribe") {
            return transcribe(file: file, engine: engine, options: options)
        }
        if let manifest = arguments.string("--eval") {
            return evaluate(manifest: manifest, arguments: arguments, engine: engine, options: options)
        }
        return 2
    }

    private static func transcribe(file: String, engine: SpeechEngine, options: SpeechEngine.Options) -> Int32 {
        do {
            let samples = try AudioFileIO.loadSamples(from: URL(fileURLWithPath: file))
            let result = engine.transcribe(samples, options: options)
            print(result.text)
            fputs(String(format: "%.1fs audio, %.0f ms (encode %.0f, decode %.0f), logprob %.2f%@\n",
                         result.audioSeconds, result.totalMs, result.encodeMs, result.decodeMs,
                         result.averageLogProbability, result.truncated ? " TRUNCATED" : ""), stderr)
            if CommandLine.arguments.contains("--tokens") {
                for token in result.tokens {
                    fputs(String(format: "  %6.2fs  %6.2f  %@\n", token.time, token.logProbability,
                                 token.text.replacingOccurrences(of: " ", with: "▁")), stderr)
                }
            }
            return 0
        } catch {
            fputs("\(error.localizedDescription)\n", stderr)
            return 1
        }
    }

    /// Shows what the language decision has to work with for one clip: both decodes with every
    /// piece's time and log-probability, and each transcript scored under the other hint.
    /// `--weave "E:0-4,A:9-13"` also scores a transcript assembled from piece ranges of the two.
    ///   Nabra --probe <audio file> --model <path> [--weave <ranges>]
    private static func probe(file: String, engine: SpeechEngine, weave: String?) -> Int32 {
        guard let samples = try? AudioFileIO.loadSamples(from: URL(fileURLWithPath: file)) else { return 1 }
        let english = engine.transcribe(samples, options: .init(language: "en", tokenTimes: true))
        let arabic = engine.transcribe(samples, options: .init(language: "ar", reuseEncoder: true, tokenTimes: true))
        func show(_ name: String, _ result: SpeechEngine.Result) {
            print(String(format: "%@ avg %.2f end %.2f (%.0f ms): %@", name, result.averageLogProbability,
                         result.endLogProbability, result.totalMs, result.text))
            var line = "   "
            for (index, token) in result.tokens.enumerated() {
                line += String(format: " %d:%@(%.2f@%.2f)", index, token.text.replacingOccurrences(of: " ", with: "▁"),
                               token.logProbability, token.time)
            }
            print(line)
        }
        show("E|en", english)
        show("A|ar", arabic)
        func score(_ name: String, _ ids: [Int32], under language: String) {
            let result = engine.transcribe(samples, options: .init(language: language, reuseEncoder: true, forcedTokens: ids))
            let worst = result.tokens.map(\.logProbability).filter { $0.isFinite }.min() ?? .nan
            print(String(format: "%@ avg %.2f worst %.2f end %.2f (%.0f ms): %@", name, result.averageLogProbability,
                         worst, result.endLogProbability, result.totalMs, result.text))
            var line = "   "
            for token in result.tokens {
                line += String(format: " %@(%.2f)", token.text.replacingOccurrences(of: " ", with: "▁"), token.logProbability)
            }
            print(line)
        }
        score("E|ar", english.tokens.map(\.id), under: "ar")
        score("A|en", arabic.tokens.map(\.id), under: "en")
        if let weave {
            var ids: [Int32] = []
            for part in weave.split(separator: ",") {
                let pieces = part.split(separator: ":")
                guard pieces.count == 2 else { continue }
                let bounds = pieces[1].split(separator: "-").compactMap { Int($0) }
                guard bounds.count == 2 else { continue }
                let source = pieces[0] == "E" ? english.tokens : arabic.tokens
                ids += source[max(0, bounds[0])...min(source.count - 1, bounds[1])].map(\.id)
            }
            score("W|ar", ids, under: "ar")
            score("W|en", ids, under: "en")
        }
        return 0
    }

    private static func evaluate(manifest: String,
                                 arguments: Arguments,
                                 engine: SpeechEngine,
                                 options: SpeechEngine.Options) -> Int32 {
        let manifestURL = URL(fileURLWithPath: manifest)
        let baseURL = arguments.string("--base").map { URL(fileURLWithPath: $0) } ?? manifestURL.deletingLastPathComponent()
        guard let content = try? String(contentsOf: manifestURL, encoding: .utf8) else {
            fputs("cannot read \(manifest)\n", stderr)
            return 1
        }
        let onlyCategory = arguments.string("--category")
        var output = ""
        for line in content.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let item = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = item["id"] as? String,
                  let path = item["path"] as? String
            else { continue }
            let category = item["category"] as? String ?? ""
            if let onlyCategory, onlyCategory != category { continue }
            guard let samples = try? AudioFileIO.loadSamples(from: baseURL.appendingPathComponent(path)) else {
                fputs("skip \(id): unreadable audio\n", stderr)
                continue
            }
            let result = engine.transcribe(samples, options: options)
            let record: [String: Any] = [
                "id": id,
                "category": category,
                "reference": item["reference"] as? String ?? "",
                "hypothesis": result.text,
                "avg_logprob": Double(result.averageLogProbability),
                "truncated": result.truncated,
                "audio_s": result.audioSeconds,
                "total_ms": result.totalMs,
                "encode_ms": result.encodeMs,
                "decode_ms": result.decodeMs,
            ]
            if let json = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]),
               let text = String(data: json, encoding: .utf8) {
                output += text + "\n"
            }
        }
        if let outPath = arguments.string("--out") {
            try? output.write(toFile: outPath, atomically: true, encoding: .utf8)
        } else {
            print(output, terminator: "")
        }
        return 0
    }

    // MARK: - Live simulation

    /// Plays a file into the live pipeline at real-time speed, as if it were being dictated,
    /// then "releases the key" and reports how long the text took to arrive.
    private final class SimulatedSource: SampleSource {
        private let samples: [Float]
        private let started = DispatchTime.now().uptimeNanoseconds
        private let speed: Double

        init(samples: [Float], speed: Double) {
            self.samples = samples
            self.speed = speed
        }

        var sampleCount: Int {
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000
            return min(samples.count, Int(elapsed * speed * Double(SpeechEngine.sampleRate)))
        }

        var isComplete: Bool { sampleCount >= samples.count }

        func copySamples(in range: Range<Int>) -> [Float] {
            let available = sampleCount
            let lower = max(0, min(range.lowerBound, available))
            let upper = max(lower, min(range.upperBound, available))
            return Array(samples[lower..<upper])
        }
    }

    private static func simulate(file: String, arguments: Arguments) -> Int32 {
        guard var samples = try? AudioFileIO.loadSamples(from: URL(fileURLWithPath: file)) else {
            fputs("cannot read \(file)\n", stderr)
            return 1
        }
        // Silence between the last word and releasing the key.
        let pause = Double(arguments.string("--pause") ?? "0.45") ?? 0.45
        samples += [Float](repeating: 0, count: Int(pause * Double(SpeechEngine.sampleRate)))
        let speed = Double(arguments.string("--speed") ?? "1") ?? 1
        let mode = LanguageMode(rawValue: arguments.string("--mode") ?? "auto") ?? .auto

        let service = TranscriptionService()
        var ready = false
        service.prepare(preferredModelID: arguments.string("--model-id") ?? SpeechModel.defaultID) { ready = $0 }
        while !ready { RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01)) }

        let source = SimulatedSource(samples: samples, speed: speed)
        let choice = LanguageChoice(mode: mode, ignoreBackgroundVoices: arguments.has("--mute-background"))
        let live = service.startLive(recorder: source, language: choice)
        if arguments.has("--verbose") {
            live.onPartial = { fputs("  partial: \($0)\n", stderr) }
        }
        while !source.isComplete { RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.005)) }

        var finished: TranscriptionResult?
        live.finish(samples: samples) { finished = $0 }
        while finished == nil { RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.002)) }
        guard let result = finished else { return 1 }
        print(result.text)
        fputs(String(format: "[%@] audio %.1fs, speech %.1fs | text ready %.0f ms after release%@ | compute %.0f ms%@\n",
                     result.language, result.audioSeconds, result.speechSeconds, result.latencyMs,
                     result.wasReadyEarly ? " (already done)" : "", result.computeMs,
                     result.noSpeech ? " | NO SPEECH" : ""), stderr)
        for note in result.languageNotes { fputs("  language: \(note)\n", stderr) }
        return 0
    }

    // MARK: - Demo data

    /// Fills the (scratch) data folder with sample dictations for screenshots. Refuses to touch real data.
    private static func seedDemo() -> Int32 {
        guard ProcessInfo.processInfo.environment["NABRA_SUPPORT_DIR"] != nil else {
            fputs("--seed-demo needs NABRA_SUPPORT_DIR so it cannot write into real history\n", stderr)
            return 2
        }
        // Start from an empty database so nothing from an earlier run lingers.
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: AppPaths.databaseURL.path + suffix)
        }
        guard let database = try? Database(url: AppPaths.databaseURL),
              let history = try? HistoryStore(database: database),
              let dictionary = try? DictionaryStore(database: database)
        else { return 1 }
        let samples: [(String, String, String, Double, Double)] = [
            ("Let's move the launch to Thursday, and ask Rana to send the final numbers before the call.", "Slack", "com.tinyspeck.slackmacgap", 6.4, 0.2),
            ("اليوم عندي meeting مع ال team الساعة ثلاثة، ولازم أبعت ال report قبل ال deadline.", "Notes", "com.apple.Notes", 7.1, 0.9),
            ("طيب خلينا نحكي بكرة الصبح، هسا مشغول شوي ومش قادر أركز.", "Messages", "com.apple.MobileSMS", 4.8, 3.5),
            ("Can you review the pull request when you get a chance? I changed how the cache is invalidated.", "Visual Studio Code", "com.microsoft.VSCode", 5.9, 26),
            ("بدي أطلب منك تراجع ال design قبل ما نبعته للعميل، في كم ملاحظة صغيرة.", "Mail", "com.apple.mail", 6.6, 30),
            ("Remind me to call Darwish about the product video shoot next week.", "Notes", "com.apple.Notes", 4.2, 52),
            ("The quarterly report is ready. I'll share the summary in tomorrow's standup.", "Google Chrome", "com.google.Chrome", 5.0, 75),
        ]
        for (text, app, bundle, seconds, hoursAgo) in samples.reversed() {
            history.add(text: text, rawText: text, language: TranscriptionService.languageLabel(for: text), duration: seconds,
                        appName: app, appBundleID: bundle, audioFile: nil, processingMs: 180, polished: false)
            _ = try? database.execute("UPDATE transcripts SET created_at = ? WHERE id = (SELECT MAX(id) FROM transcripts)",
                                      [.real(Date().addingTimeInterval(-hoursAgo * 3600).timeIntervalSince1970)])
        }
        // A few older days so the chart has something to show.
        for day in 3...12 where day % 3 != 1 {
            let words = 40 + (day * 37) % 160
            let filler = Array(repeating: "word", count: words).joined(separator: " ")
            history.add(text: filler, rawText: filler, language: "en", duration: Double(words) / 2.4, appName: "Notes",
                        appBundleID: "com.apple.Notes", audioFile: nil, processingMs: 200, polished: false)
            _ = try? database.execute("UPDATE transcripts SET created_at = ? WHERE id = (SELECT MAX(id) FROM transcripts)",
                                      [.real(Date().addingTimeInterval(-Double(day) * 86_400).timeIntervalSince1970)])
        }
        for term in ["Darwish", "Qandeel", "Zentro", "Claude Code", "درويش"] { dictionary.addTerm(term) }
        dictionary.addTerm("Nabra", source: .learned)
        dictionary.addReplacement(heard: "cloud code", phrase: "Claude Code")
        dictionary.addReplacement(heard: "Darweesh", phrase: "Darwish", source: .learned)
        print("seeded \(AppPaths.databaseURL.path)")
        return 0
    }

    // MARK: - Evaluation through the full pipeline

    /// Runs every clip in the manifest through the same code path as a real dictation
    /// (voice detection, language choice, chunking). `--mode auto|arabic|english`.
    private static func evaluatePipeline(manifest: String, arguments: Arguments) -> Int32 {
        let manifestURL = URL(fileURLWithPath: manifest)
        let baseURL = arguments.string("--base").map { URL(fileURLWithPath: $0) } ?? manifestURL.deletingLastPathComponent()
        guard let content = try? String(contentsOf: manifestURL, encoding: .utf8) else {
            fputs("cannot read \(manifest)\n", stderr)
            return 1
        }
        let mode = LanguageMode(rawValue: arguments.string("--mode") ?? "auto") ?? .auto
        let modelID = arguments.string("--model-id") ?? SpeechModel.defaultID
        let onlyCategory = arguments.string("--category")
        let service = TranscriptionService()
        var output = ""
        for line in content.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let item = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = item["id"] as? String, let path = item["path"] as? String
            else { continue }
            let category = item["category"] as? String ?? ""
            if let onlyCategory, onlyCategory != category { continue }
            guard let samples = try? AudioFileIO.loadSamples(from: baseURL.appendingPathComponent(path)) else { continue }
            var finished: TranscriptionResult?
            let choice = LanguageChoice(mode: mode, ignoreBackgroundVoices: arguments.has("--mute-background"))
            service.transcribe(samples: samples, language: choice, preferredModelID: modelID,
                               requireSpeech: !arguments.has("--decode-all")) { finished = $0 }
            while finished == nil { RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.002)) }
            guard let result = finished else { continue }
            let record: [String: Any] = [
                "id": id, "category": category, "hypothesis": result.text, "language": result.language,
                "audio_s": result.audioSeconds, "total_ms": result.computeMs, "no_speech": result.noSpeech,
                "notes": result.languageNotes.joined(separator: " | "),
            ]
            if let json = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]),
               let text = String(data: json, encoding: .utf8) {
                output += text + "\n"
            }
        }
        if let outPath = arguments.string("--out") {
            try? output.write(toFile: outPath, atomically: true, encoding: .utf8)
        } else {
            print(output, terminator: "")
        }
        return 0
    }

    // MARK: - Scribe check

    /// Runs one transcript through Scribe exactly as the app would, printing the text as it streams.
    /// Uses the model in Settings, or the file in NABRA_WRITER_MODEL.
    private static func scribe(_ text: String, app: String?) -> Int32 {
        let writer = LlamaServerWriter()
        guard writer.isInstalled else {
            fputs("Scribe is not installed (helper or model missing)\n", stderr)
            return 1
        }
        var request = WritingRequest(transcript: text)
        request.appName = app
        let job = ScribeRouter.job(for: text)
        fputs("job: \(job)\n", stderr)
        let started = Date()
        var firstAt: Date?
        var done = false
        var output: String?
        writer.write(request, job: job, onText: { partial in
            if firstAt == nil { firstAt = Date() }
            _ = partial
        }, completion: { final in
            output = final
            done = true
        })
        while !done { RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01)) }
        if case .compose = job, let written = output { output = ScribeRouter.tidyComposed(written) }
        if job == .polish, let written = output, let problem = ScribeRouter.problem(polished: written, from: text) {
            fputs("check: would keep the words as said, the rewrite \(problem)\n", stderr)
        }
        print(output ?? "(nothing)")
        fputs(String(format: "first text after %.0f ms, done after %.0f ms\n",
                     (firstAt ?? Date()).timeIntervalSince(started) * 1000, Date().timeIntervalSince(started) * 1000), stderr)
        writer.shutdown()
        return output == nil ? 1 : 0
    }

    // MARK: - Text layout check

    /// Runs one transcript through the clean-up that every dictation gets (lists, pauses, commands)
    /// and prints what would be inserted. `\n` in the argument stands for a line break.
    private static func format(_ text: String) -> Int32 {
        var options = TextPipeline.Options()
        options.isRealWord = SpellingOracle.isRealWord
        print(TextPipeline.process(text.replacingOccurrences(of: "\\n", with: "\n"), options: options).text)
        return 0
    }

    // MARK: - Smart clean-up check

    /// Runs the clean-up pass on one line of text and reports what would be inserted.
    private static func polish(_ text: String, force: Bool) -> Int32 {
        let cleanup = SmartCleanup()
        if #available(macOS 26.0, *) { cleanup.rewriter = AppleRewriter() }
        guard cleanup.isAvailable else {
            fputs("the on-device language model is not available\n", stderr)
            return 1
        }
        guard cleanup.shouldPolish(text, mode: force ? .always : .smart) else {
            print("(unchanged, no correction cue) \(text)")
            return 0
        }
        let started = Date()
        var done = false
        cleanup.polish(text, vocabulary: []) { result in
            let ms = Date().timeIntervalSince(started) * 1000
            print(String(format: "[%.0f ms] %@", ms, result ?? "(kept as spoken) \(text)"))
            done = true
        }
        while !done { RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01)) }
        return 0
    }

    // MARK: - Model download

    /// Downloads a speech model with the same code the setup screen uses.
    private static func downloadModel(id: String?) -> Int32 {
        var model = SpeechModel.model(id: id ?? SpeechModel.defaultID)
        // For testing the downloader on a small file: NABRA_TEST_URL and NABRA_TEST_BYTES.
        if let url = ProcessInfo.processInfo.environment["NABRA_TEST_URL"].flatMap(URL.init(string:)),
           let bytes = ProcessInfo.processInfo.environment["NABRA_TEST_BYTES"].flatMap(Int64.init) {
            model = SpeechModel(id: "test", title: "Test", detail: "", fileName: url.lastPathComponent, bytes: bytes, url: url)
        }
        if model.isInstalled {
            print("\(model.fileName) is already installed")
            return 0
        }
        let downloader = ModelDownloader()
        downloader.download(model)
        var lastStep = -1
        while downloader.isDownloading(model) {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.2))
            let step = Int((downloader.progress[model.id] ?? 0) * 10)
            if step != lastStep {
                lastStep = step
                fputs("  \(step * 10)%\n", stderr)
            }
        }
        if let error = downloader.errors[model.id] {
            fputs("download failed: \(error)\n", stderr)
            return 1
        }
        print(model.isInstalled ? "installed \(model.localURL.path)" : "download did not complete")
        return model.isInstalled ? 0 : 1
    }
}
