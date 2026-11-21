import Darwin
import Foundation

/// Runs Scribe's language model in a helper process (llama.cpp's server, bundled as `nabra-writer`)
/// and streams what it writes.
///
/// A separate process keeps the model's memory out of the app: it is started when the Scribe key is
/// pressed (so it loads while you talk), and stopped after a while without use, which gives all of
/// that memory back. It listens only on the loopback interface, behind a random key.
final class LlamaServerWriter: TextWriter {
    private let queue = DispatchQueue(label: "app.nabra.writer", qos: .userInitiated)
    private var process: Process?
    private var port: Int = 0
    private var apiKey = ""
    private var ready = false
    private var idleWork: DispatchWorkItem?
    private var current: Task<Void, Never>?

    /// The helper itself frees the model after a minute without use (it stays loaded on disk, mapped,
    /// and comes back in well under a second). After this long it is stopped altogether.
    var idleSeconds: TimeInterval = 600

    private static let helperName = "nabra-writer"
    private static var pidFile: URL { AppPaths.supportDirectory.appendingPathComponent("writer.pid") }

    init() {
        LlamaServerWriter.stopLeftoverHelper()
    }

    var helperURL: URL? { Bundle.main.url(forAuxiliaryExecutable: LlamaServerWriter.helperName) }

    var isInstalled: Bool {
        helperURL != nil && WriterModel.current.isInstalled
    }

    /// Called when the Scribe key goes down: the model loads, and its instructions are computed,
    /// while you are still talking.
    func prepare() {
        queue.async { [self] in
            guard startIfNeeded(waitUntilReady: true) else { return }
            scheduleIdleStop()
            warmUp()
        }
    }

    /// A one-token request with the usual instructions, so the server has them ready.
    private func warmUp() {
        var body = ScribePrompt.requestBody(for: WritingRequest(transcript: "ok"), job: .polish, model: WriterModel.current)
        body["stream"] = false
        body["max_tokens"] = 1
        guard let url = URL(string: "http://127.0.0.1:\(port)/v1/chat/completions"),
              let data = try? JSONSerialization.data(withJSONObject: body)
        else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = data
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { _, _, _ in done.signal() }.resume()
        _ = done.wait(timeout: .now() + 10)
    }

    func write(_ request: WritingRequest, job: ScribeRouter.Job, onText: @escaping (String) -> Void,
               completion: @escaping (String?) -> Void) {
        queue.async { [self] in
            guard startIfNeeded(waitUntilReady: true) else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            scheduleIdleStop()
            let body = ScribePrompt.requestBody(for: request, job: job, model: WriterModel.current)
            guard let url = URL(string: "http://127.0.0.1:\(port)/v1/chat/completions"),
                  let data = try? JSONSerialization.data(withJSONObject: body)
            else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            var urlRequest = URLRequest(url: url)
            urlRequest.httpMethod = "POST"
            urlRequest.httpBody = data
            urlRequest.timeoutInterval = 60
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            current = Task.detached(priority: .userInitiated) {
                var text = ""
                var lastShown = Date.distantPast
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: urlRequest)
                    guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let json = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
                              let choice = (json["choices"] as? [[String: Any]])?.first,
                              let delta = choice["delta"] as? [String: Any],
                              let piece = delta["content"] as? String
                        else { continue }
                        text += piece
                        // About thirty updates a second is smooth enough and keeps the indicator cheap.
                        if Date().timeIntervalSince(lastShown) > 0.033 {
                            lastShown = Date()
                            let shown = ScribePrompt.clean(text)
                            DispatchQueue.main.async { onText(shown) }
                        }
                    }
                } catch {
                    if !Task.isCancelled { Log.error("Scribe: the writing model failed: \(error.localizedDescription)") }
                    DispatchQueue.main.async { completion(nil) }
                    return
                }
                let final = Task.isCancelled ? nil : ScribePrompt.clean(text)
                DispatchQueue.main.async {
                    if let final { onText(final) }
                    completion(final)
                }
            }
        }
    }

    func cancel() {
        queue.async { [self] in
            current?.cancel()
            current = nil
        }
    }

    /// Stops the helper now and frees its memory (Scribe was switched off). It starts again on next use.
    func stopNow() {
        queue.async { [self] in
            idleWork?.cancel()
            if process != nil { Log.info("Scribe: writing model stopped (Scribe was switched off)") }
            stop()
        }
    }

    /// Stops the helper (the app is quitting).
    func shutdown() {
        queue.sync { stop() }
    }

    // MARK: - The helper process (on `queue`)

    private func startIfNeeded(waitUntilReady: Bool) -> Bool {
        if let process, process.isRunning {
            return ready || !waitUntilReady || waitForReady()
        }
        guard let helper = helperURL, WriterModel.current.isInstalled else { return false }
        let model = WriterModel.current
        guard let free = LlamaServerWriter.freePort() else {
            Log.error("Scribe: no free local port for the writing model")
            return false
        }
        port = free
        apiKey = UUID().uuidString
        ready = false
        let process = Process()
        process.executableURL = helper
        var arguments = [
            "--model", model.localURL.path,
            "--host", "127.0.0.1", "--port", String(port), "--api-key", apiKey,
            "--ctx-size", "4096", "--n-gpu-layers", "99", "--parallel", "1", "--flash-attn", "on",
            "--no-webui", "--log-disable",
            // Small models that can "think" first would spend the whole budget doing it: Scribe needs the text at once.
            "--reasoning", "off",
            // Read the large per-layer embedding table from disk as needed instead of holding it in
            // memory (about 1.1 GB less), and skip fitting checks that only cost time at load.
            "--lazy-mode", "on", "--fit", "off",
            // Keep the instructions computed between requests, and let go of the model after a minute idle.
            "--cache-ram", "128", "--sleep-idle-seconds", "60",
        ]
        if let drafter = model.drafter, drafter.isInstalled {
            // Draft a few tokens ahead and check them in one step: identical text, about twice as fast.
            arguments += ["--model-draft", drafter.localURL.path, "--spec-type", "draft-mtp,ngram-simple",
                          "--spec-draft-n-max", "4", "--spec-ngram-simple-size-n", "4", "--spec-ngram-simple-size-m", "24"]
        }
        process.arguments = arguments + model.extraArguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            Log.error("Scribe: could not start the writing model: \(error.localizedDescription)")
            return false
        }
        self.process = process
        try? String(process.processIdentifier).write(to: LlamaServerWriter.pidFile, atomically: true, encoding: .utf8)
        Log.info("Scribe: writing model starting (\(model.title))")
        return !waitUntilReady || waitForReady()
    }

    private func waitForReady() -> Bool {
        let started = Date()
        guard let url = URL(string: "http://127.0.0.1:\(port)/health") else { return false }
        while Date().timeIntervalSince(started) < 30 {
            guard let process, process.isRunning else { return false }
            var request = URLRequest(url: url)
            request.timeoutInterval = 1
            let semaphore = DispatchSemaphore(value: 0)
            var ok = false
            URLSession.shared.dataTask(with: request) { _, response, _ in
                ok = (response as? HTTPURLResponse)?.statusCode == 200
                semaphore.signal()
            }.resume()
            _ = semaphore.wait(timeout: .now() + 1.5)
            if ok {
                ready = true
                Log.info(String(format: "Scribe: writing model ready in %.0f ms", Date().timeIntervalSince(started) * 1000))
                return true
            }
            usleep(50_000)
        }
        Log.error("Scribe: the writing model did not become ready")
        return false
    }

    private func scheduleIdleStop() {
        idleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.current == nil || self.current?.isCancelled == true else { return }
            Log.info("Scribe: writing model stopped after a quiet spell")
            self.stop()
        }
        idleWork = work
        queue.asyncAfter(deadline: .now() + idleSeconds, execute: work)
    }

    private func stop() {
        current?.cancel()
        current = nil
        if let process, process.isRunning { process.terminate() }
        process = nil
        ready = false
        try? FileManager.default.removeItem(at: LlamaServerWriter.pidFile)
    }

    /// A helper left running by an earlier session that ended abruptly is stopped.
    private static func stopLeftoverHelper() {
        guard let text = try? String(contentsOf: pidFile, encoding: .utf8), let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 0
        else { return }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        if proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0, String(cString: buffer).hasSuffix("/\(helperName)") {
            kill(pid, SIGTERM)
        }
        try? FileManager.default.removeItem(at: pidFile)
    }

    /// A port on the loopback interface that nothing is using right now.
    private static func freePort() -> Int? {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else { return nil }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        guard named == 0 else { return nil }
        return Int(UInt16(bigEndian: address.sin_port))
    }
}
