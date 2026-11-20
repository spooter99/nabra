import Foundation

/// Where Nabra keeps its files. Everything lives under ~/Library/Application Support/Nabra.
enum AppPaths {
    static let appName = "Nabra"

    static let supportDirectory: URL = {
        // Tests and demos can point the app at a scratch folder instead of the real data.
        if let override = ProcessInfo.processInfo.environment["NABRA_SUPPORT_DIR"], !override.isEmpty {
            return ensure(URL(fileURLWithPath: override, isDirectory: true))
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return ensure(base.appendingPathComponent(appName, isDirectory: true))
    }()

    static var modelsDirectory: URL { ensure(supportDirectory.appendingPathComponent("Models", isDirectory: true)) }
    static var audioDirectory: URL { ensure(supportDirectory.appendingPathComponent("Audio", isDirectory: true)) }
    static var databaseURL: URL { supportDirectory.appendingPathComponent("nabra.sqlite") }
    static var logURL: URL { supportDirectory.appendingPathComponent("nabra.log") }

    @discardableResult
    private static func ensure(_ url: URL) -> URL {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
