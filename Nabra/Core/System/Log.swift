import Foundation
import os

/// Small logger: unified logging plus a rolling plain-text file that is easy to read when something goes wrong.
enum Log {
    private static let logger = Logger(subsystem: "app.nabra.Nabra", category: "app")
    private static let queue = DispatchQueue(label: "app.nabra.log", qos: .utility)
    private static let maxBytes = 1_000_000
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    static func info(_ message: @autoclosure () -> String) {
        let text = message()
        logger.info("\(text, privacy: .public)")
        write("INFO ", text)
    }

    static func error(_ message: @autoclosure () -> String) {
        let text = message()
        logger.error("\(text, privacy: .public)")
        write("ERROR", text)
    }

    /// Waits for every line written so far to reach the file.
    static func flushSynchronously() {
        queue.sync {}
    }

    private static func write(_ level: String, _ text: String) {
        let date = Date()
        queue.async {
            let line = "\(formatter.string(from: date)) \(level) \(text)\n"
            let url = AppPaths.logURL
            guard let data = line.data(using: .utf8) else { return }
            if let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int, size > maxBytes {
                let old = url.deletingPathExtension().appendingPathExtension("old.log")
                try? FileManager.default.removeItem(at: old)
                try? FileManager.default.moveItem(at: url, to: old)
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url, options: .atomic)
            }
        }
    }
}
