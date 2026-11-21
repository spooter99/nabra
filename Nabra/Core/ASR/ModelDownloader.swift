import Foundation
import Observation

/// Downloads speech models with progress, resuming where possible.
@Observable
final class ModelDownloader: NSObject, URLSessionDownloadDelegate {
    /// Model id → fraction complete (0...1) for downloads in flight.
    private(set) var progress: [String: Double] = [:]
    /// Model id → last error message.
    private(set) var errors: [String: String] = [:]
    /// Increments whenever a download finishes, so views re-check what is installed.
    private(set) var completedCount = 0

    @ObservationIgnored private var tasks: [String: URLSessionDownloadTask] = [:]
    @ObservationIgnored private var models: [Int: SpeechModel] = [:]
    @ObservationIgnored var onInstalled: ((SpeechModel) -> Void)?
    @ObservationIgnored private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        configuration.waitsForConnectivity = true
        return URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
    }()

    func isDownloading(_ model: SpeechModel) -> Bool { progress[model.id] != nil }

    func download(_ model: SpeechModel) {
        guard tasks[model.id] == nil, !model.isInstalled else { return }
        errors[model.id] = nil
        progress[model.id] = 0
        let task = session.downloadTask(with: model.url)
        models[task.taskIdentifier] = model
        tasks[model.id] = task
        task.resume()
    }

    func cancel(_ model: SpeechModel) {
        tasks[model.id]?.cancel()
        tasks[model.id] = nil
        progress[model.id] = nil
    }

    func delete(_ model: SpeechModel) {
        try? FileManager.default.removeItem(at: model.localURL)
        completedCount += 1
    }

    // MARK: - URLSessionDownloadDelegate (main queue)

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let model = models[downloadTask.taskIdentifier] else { return }
        let expected = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : model.bytes
        progress[model.id] = min(1, Double(totalBytesWritten) / Double(max(1, expected)))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let model = models[downloadTask.taskIdentifier] else { return }
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        let size = (try? FileManager.default.attributesOfItem(atPath: location.path)[.size]) as? Int64 ?? 0
        guard (200..<300).contains(status), size == model.bytes else {
            errors[model.id] = "Download was incomplete. Try again."
            return
        }
        do {
            try? FileManager.default.removeItem(at: model.localURL)
            try FileManager.default.moveItem(at: location, to: model.localURL)
            Log.info("Installed model \(model.id)")
        } catch {
            errors[model.id] = error.localizedDescription
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let model = models.removeValue(forKey: task.taskIdentifier) else { return }
        tasks[model.id] = nil
        progress[model.id] = nil
        if let error = error as NSError?, error.code != NSURLErrorCancelled {
            errors[model.id] = error.localizedDescription
        }
        completedCount += 1
        if model.isInstalled { onInstalled?(model) }
    }
}
