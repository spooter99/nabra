import Foundation
import Observation

enum LanguageMode: String, CaseIterable, Identifiable, Codable {
    case auto
    case arabic
    case english

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return "Arabic + English"
        case .arabic: return "Arabic"
        case .english: return "English"
        }
    }

    var detail: String {
        switch self {
        case .auto: return "Speak either language, or mix them in one sentence."
        case .arabic: return "Arabic, with English words kept as you say them."
        case .english: return "English only."
        }
    }

    /// Language hint given to the speech model. Arabic speech with English mixed in uses "ar".
    var engineLanguage: String {
        switch self {
        case .auto, .arabic: return "ar"
        case .english: return "en"
        }
    }
}

enum CleanupMode: String, CaseIterable, Identifiable, Codable {
    case off
    case smart
    case always

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: return "Exactly as spoken"
        case .smart: return "Smart"
        case .always: return "Always polish"
        }
    }

    var detail: String {
        switch self {
        case .off: return "Fastest. Your words, with punctuation."
        case .smart: return "Instant normally. When you correct yourself (“at two, no actually three”), only what you meant is kept. English for now; adds about half a second on those sentences."
        case .always: return "Every English dictation is tidied up. Adds about half a second each time."
        }
    }
}

enum InsertionMethod: String, CaseIterable, Identifiable, Codable {
    case paste
    case type

    var id: String { rawValue }

    var title: String {
        switch self {
        case .paste: return "Paste"
        case .type: return "Type"
        }
    }

    var detail: String {
        switch self {
        case .paste: return "Fast and works almost everywhere. Your clipboard is restored afterwards."
        case .type: return "Simulates typing. Slower, for apps that block pasting."
        }
    }
}

enum IndicatorPosition: String, CaseIterable, Identifiable, Codable {
    case bottom
    case notch

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bottom: return "Bottom of screen"
        case .notch: return "Under the notch"
        }
    }
}

/// When the microphone is switched on.
enum MicrophoneReadiness: String, CaseIterable, Identifiable, Codable {
    case onDemand
    case lingering
    case always

    var id: String { rawValue }

    var title: String {
        switch self {
        case .onDemand: return "When I press the key"
        case .lingering: return "Stays on for a minute after dictating"
        case .always: return "Always on"
        }
    }

    var detail: String {
        switch self {
        case .onDemand:
            return "A built-in microphone needs about a fifth of a second after the key goes down before it hears anything. Speak when the indicator comes alive, or pick another option to never lose the first word."
        case .lingering:
            return "While you are dictating one thing after another, nothing is missed, not even the first syllable. The microphone stays on for a minute after each dictation, and macOS shows its orange dot for that time. Nothing is recorded or kept unless you hold the key."
        case .always:
            return "Not even the first syllable is ever missed. The microphone is on whenever Nabra runs, so macOS shows its orange dot all the time. Nothing is recorded or kept unless you hold the key."
        }
    }
}

enum AudioRetention: String, CaseIterable, Identifiable, Codable {
    case never
    case week
    case month
    case forever

    var id: String { rawValue }

    var title: String {
        switch self {
        case .never: return "Don't keep"
        case .week: return "7 days"
        case .month: return "30 days"
        case .forever: return "Forever"
        }
    }

    var days: Int? {
        switch self {
        case .never: return 0
        case .week: return 7
        case .month: return 30
        case .forever: return nil
        }
    }
}

/// User preferences, stored in UserDefaults.
@Observable
final class Settings {
    static let shared = Settings()

    @ObservationIgnored private let defaults: UserDefaults

    var hotkey: Hotkey {
        didSet {
            saveCodable(hotkey, "hotkey")
            NotificationCenter.default.post(name: .nabraHotkeySettingsChanged, object: nil)
        }
    }
    var handsFreeEnabled: Bool {
        didSet {
            defaults.set(handsFreeEnabled, forKey: "handsFreeEnabled")
            NotificationCenter.default.post(name: .nabraHotkeySettingsChanged, object: nil)
        }
    }
    /// Scribe: hold this key instead, and what you say comes back written up (or written for you).
    var scribeEnabled: Bool {
        didSet {
            defaults.set(scribeEnabled, forKey: "scribeEnabled")
            NotificationCenter.default.post(name: .nabraHotkeySettingsChanged, object: nil)
        }
    }
    var scribeHotkey: Hotkey {
        didSet {
            saveCodable(scribeHotkey, "scribeHotkey")
            NotificationCenter.default.post(name: .nabraHotkeySettingsChanged, object: nil)
        }
    }
    /// Let Scribe see which app you are in and the text around the cursor, to match names and tone.
    var scribeUsesContext: Bool { didSet { defaults.set(scribeUsesContext, forKey: "scribeUsesContext") } }

    var languageMode: LanguageMode { didSet { defaults.set(languageMode.rawValue, forKey: "languageMode") } }
    var modelID: String { didSet { defaults.set(modelID, forKey: "modelID") } }
    /// Minutes the speech model stays in memory after the last dictation. 0 keeps it loaded.
    var modelIdleMinutes: Int { didSet { defaults.set(modelIdleMinutes, forKey: "modelIdleMinutes") } }

    var cleanupMode: CleanupMode { didSet { defaults.set(cleanupMode.rawValue, forKey: "cleanupMode") } }
    var removeFillers: Bool { didSet { defaults.set(removeFillers, forKey: "removeFillers") } }
    var voiceCommands: Bool { didSet { defaults.set(voiceCommands, forKey: "voiceCommands") } }
    var learnFromCorrections: Bool { didSet { defaults.set(learnFromCorrections, forKey: "learnFromCorrections") } }
    /// Mute sustained speech much quieter than your own voice (people talking across the room).
    var ignoreBackgroundVoices: Bool { didSet { defaults.set(ignoreBackgroundVoices, forKey: "ignoreBackgroundVoices") } }
    /// Turn spoken lists ("one, … two, …", "first, … second, …") into numbered lists.
    var formatLists: Bool { didSet { defaults.set(formatLists, forKey: "formatLists") } }
    /// Break long dictations into paragraphs.
    var formatParagraphs: Bool { didSet { defaults.set(formatParagraphs, forKey: "formatParagraphs") } }

    var insertionMethod: InsertionMethod { didSet { defaults.set(insertionMethod.rawValue, forKey: "insertionMethod") } }
    var restoreClipboard: Bool { didSet { defaults.set(restoreClipboard, forKey: "restoreClipboard") } }
    var smartSpacing: Bool { didSet { defaults.set(smartSpacing, forKey: "smartSpacing") } }

    var playSounds: Bool { didSet { defaults.set(playSounds, forKey: "playSounds") } }
    /// Loudness of the start/stop cues, 0...1. Kept low by default: they should be barely there.
    var soundVolume: Double { didSet { defaults.set(soundVolume, forKey: "soundVolume") } }
    var showLiveText: Bool { didSet { defaults.set(showLiveText, forKey: "showLiveText") } }
    /// Where the small recording indicator appears.
    var indicatorPosition: IndicatorPosition {
        didSet { defaults.set(indicatorPosition.rawValue, forKey: "indicatorPosition") }
    }

    /// Core Audio UID of the chosen microphone, or nil for the system default.
    var inputDeviceUID: String? { didSet { defaults.set(inputDeviceUID, forKey: "inputDeviceUID") } }
    /// Whether the microphone stays on between dictations, so not even the first syllable is lost.
    /// It opens on demand by default: macOS shows its microphone indicator for as long as it is on.
    var microphoneReadiness: MicrophoneReadiness {
        didSet { defaults.set(microphoneReadiness.rawValue, forKey: "microphoneReadiness") }
    }
    var audioRetention: AudioRetention { didSet { defaults.set(audioRetention.rawValue, forKey: "audioRetention") } }
    var saveHistory: Bool { didSet { defaults.set(saveHistory, forKey: "saveHistory") } }

    var onboardingCompleted: Bool { didSet { defaults.set(onboardingCompleted, forKey: "onboardingCompleted") } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hotkey = Settings.loadCodable(Hotkey.self, "hotkey", defaults) ?? .default
        scribeEnabled = defaults.object(forKey: "scribeEnabled") as? Bool ?? true
        scribeHotkey = Settings.loadCodable(Hotkey.self, "scribeHotkey", defaults) ?? .rightCommand
        scribeUsesContext = defaults.object(forKey: "scribeUsesContext") as? Bool ?? true
        handsFreeEnabled = defaults.object(forKey: "handsFreeEnabled") as? Bool ?? true
        languageMode = LanguageMode(rawValue: defaults.string(forKey: "languageMode") ?? "") ?? .auto
        modelID = defaults.string(forKey: "modelID") ?? SpeechModel.defaultID
        modelIdleMinutes = defaults.object(forKey: "modelIdleMinutes") as? Int ?? 30
        cleanupMode = CleanupMode(rawValue: defaults.string(forKey: "cleanupMode") ?? "") ?? .smart
        removeFillers = defaults.object(forKey: "removeFillers") as? Bool ?? true
        voiceCommands = defaults.object(forKey: "voiceCommands") as? Bool ?? true
        learnFromCorrections = defaults.object(forKey: "learnFromCorrections") as? Bool ?? true
        ignoreBackgroundVoices = defaults.object(forKey: "ignoreBackgroundVoices") as? Bool ?? false
        formatLists = defaults.object(forKey: "formatLists") as? Bool ?? true
        formatParagraphs = defaults.object(forKey: "formatParagraphs") as? Bool ?? true
        insertionMethod = InsertionMethod(rawValue: defaults.string(forKey: "insertionMethod") ?? "") ?? .paste
        restoreClipboard = defaults.object(forKey: "restoreClipboard") as? Bool ?? true
        smartSpacing = defaults.object(forKey: "smartSpacing") as? Bool ?? true
        playSounds = defaults.object(forKey: "playSounds") as? Bool ?? true
        soundVolume = defaults.object(forKey: "soundVolume") as? Double ?? 0.3
        showLiveText = defaults.object(forKey: "showLiveText") as? Bool ?? false
        indicatorPosition = IndicatorPosition(rawValue: defaults.string(forKey: "indicatorPosition") ?? "") ?? .bottom
        inputDeviceUID = defaults.string(forKey: "inputDeviceUID")
        microphoneReadiness = MicrophoneReadiness(rawValue: defaults.string(forKey: "microphoneReadiness") ?? "") ?? .onDemand
        audioRetention = AudioRetention(rawValue: defaults.string(forKey: "audioRetention") ?? "") ?? .week
        saveHistory = defaults.object(forKey: "saveHistory") as? Bool ?? true
        onboardingCompleted = defaults.bool(forKey: "onboardingCompleted")
    }

    var gestureConfig: HotkeyGesture.Config {
        var config = HotkeyGesture.Config()
        config.handsFreeEnabled = handsFreeEnabled
        return config
    }

    private func saveCodable<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }

    private static func loadCodable<T: Decodable>(_ type: T.Type, _ key: String, _ defaults: UserDefaults) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
