import AppKit
import Observation

extension Notification.Name {
    static let nabraHotkeySettingsChanged = Notification.Name("app.nabra.hotkeySettingsChanged")
}

/// Runs `onChange` on the main queue every time an observed value changes.
func observeChanges<T>(of value: @escaping () -> T, onChange: @escaping (T) -> Void) {
    withObservationTracking {
        _ = value()
    } onChange: {
        DispatchQueue.main.async {
            onChange(value())
            observeChanges(of: value, onChange: onChange)
        }
    }
}

/// Everything the app is made of, wired together once at launch.
@Observable
final class AppState {
    let settings = Settings.shared
    let history: HistoryStore
    let dictionary: DictionaryStore
    let transcription = TranscriptionService()
    let permissions = Permissions()
    let downloads = ModelDownloader()
    let dictation: DictationController
    let learner: CorrectionLearner

    /// True while the global dictation key is being watched.
    private(set) var hotkeyActive = false

    @ObservationIgnored let recorder = AudioRecorder()
    @ObservationIgnored let hud = HUDController()
    @ObservationIgnored let cleanup = SmartCleanup()
    @ObservationIgnored private let hotkeys: HotkeyMonitor
    @ObservationIgnored private var retryTimer: Timer?

    init() {
        let database: Database
        do {
            database = try Database(url: AppPaths.databaseURL)
        } catch {
            Log.error("Database unavailable, using a temporary one: \(error.localizedDescription)")
            let fallback = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("nabra-\(UUID().uuidString).sqlite")
            database = try! Database(url: fallback)
        }
        history = try! HistoryStore(database: database)
        dictionary = try! DictionaryStore(database: database)
        dictation = DictationController(settings: settings, recorder: recorder, transcription: transcription,
                                        history: history, dictionary: dictionary, cleanup: cleanup, hud: hud)
        learner = CorrectionLearner(dictionary: dictionary, history: history, settings: settings, hud: hud)
        hotkeys = HotkeyMonitor(hotkey: settings.hotkey, config: settings.gestureConfig)
    }

    /// The app is usable once both permissions are granted and a speech model is installed.
    /// Demo mode (NABRA_DEMO=1, used with NABRA_SUPPORT_DIR for screenshots): sample data, no setup
    /// screen, and no listening for the dictation key, so it can run next to a real installation.
    static let isDemo = ProcessInfo.processInfo.environment["NABRA_DEMO"] == "1"

    var needsSetup: Bool {
        if AppState.isDemo { return false }
        return !settings.onboardingCompleted || !permissions.allGranted || transcription.state == .missingModel
    }

    func start() {
        if #available(macOS 26.0, *) { cleanup.rewriter = AppleRewriter() }
        hud.position = { [weak self] in self?.settings.indicatorPosition ?? .bottom }
        hotkeys.onAction = { [weak self] action in self?.dictation.handle(action) }
        dictation.onEndedExternally = { [weak self] in self?.hotkeys.dictationEndedExternally() }
        dictation.onInserted = { [weak self] text, context, transcriptID in
            self?.learner.watch(inserted: text, context: context, transcriptID: transcriptID)
        }

        permissions.onAccessibilityChange = { [weak self] _ in self?.updateHotkeyMonitor() }
        permissions.startMonitoring()
        updateHotkeyMonitor()

        NotificationCenter.default.addObserver(forName: .nabraHotkeySettingsChanged, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.hotkeys.update(hotkey: self.settings.hotkey, config: self.settings.gestureConfig)
        }

        downloads.onInstalled = { [weak self] _ in
            guard let self else { return }
            self.transcription.refreshInstalledState()
            self.warmUp()
        }

        // Load once at launch so the first dictation is instant, then release when idle.
        warmUp()
        if let days = settings.audioRetention.days, days > 0 {
            history.pruneAudio(olderThanDays: days)
        }
    }

    func warmUp() {
        guard SpeechModel.bestInstalled(preferred: settings.modelID) != nil else { return }
        transcription.prepare(preferredModelID: settings.modelID) { [weak self] _ in
            guard let self else { return }
            self.transcription.scheduleUnload(afterMinutes: self.settings.modelIdleMinutes)
        }
    }

    /// Starts watching the dictation key as soon as Accessibility access allows it.
    private func updateHotkeyMonitor() {
        // A demo instance must not listen for the dictation key alongside the real app.
        if AppState.isDemo {
            hotkeyActive = true
            return
        }
        if permissions.accessibility {
            hotkeyActive = hotkeys.start()
            if !hotkeyActive {
                // Access was only just granted; the system can take a moment to honour it.
                retryTimer?.invalidate()
                retryTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
                    self?.updateHotkeyMonitor()
                }
            }
        } else {
            hotkeys.stop()
            hotkeyActive = false
        }
    }
}
