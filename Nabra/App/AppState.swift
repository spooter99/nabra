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
    @ObservationIgnored private var hotkeysPaused = false

    @ObservationIgnored let recorder = AudioRecorder()
    @ObservationIgnored let hud = HUDController()
    @ObservationIgnored let cleanup = SmartCleanup()
    /// Scribe's writing model (a helper process, started only when needed).
    @ObservationIgnored let writer = LlamaServerWriter()
    @ObservationIgnored private let hotkeys: HotkeyMonitor
    /// Watches the Scribe key, when Scribe is on and its key differs from the dictation key.
    @ObservationIgnored private let scribeHotkeys: HotkeyMonitor
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
        scribeHotkeys = HotkeyMonitor(hotkey: settings.scribeHotkey, config: settings.gestureConfig)
    }

    /// The app is usable once both permissions are granted and a speech model is installed.
    /// Demo mode (NABRA_DEMO=1, used with NABRA_SUPPORT_DIR for screenshots): sample data, no setup
    /// screen, and no listening for the dictation key, so it can run next to a real installation.
    static let isDemo = ProcessInfo.processInfo.environment["NABRA_DEMO"] == "1"

    /// Unattended end-to-end checks (see `Robot`): no window, no key monitoring, nothing inserted.
    static let isRobot = Robot.isEnabled

    var needsSetup: Bool {
        if AppState.isDemo || AppState.isRobot { return false }
        return !settings.onboardingCompleted || !permissions.allGranted || transcription.state == .missingModel
    }

    func start() {
        if #available(macOS 26.0, *) { cleanup.rewriter = AppleRewriter() }
        dictation.writer = writer
        hud.position = { [weak self] in self?.settings.indicatorPosition ?? .bottom }
        hotkeys.onAction = { [weak self] action, keyDownAt in self?.dictation.handle(action, keyDownAt: keyDownAt) }
        scribeHotkeys.onAction = { [weak self] action, keyDownAt in
            self?.dictation.handle(action, keyDownAt: keyDownAt, mode: .scribe)
        }
        dictation.onEndedExternally = { [weak self] mode in
            (mode == .scribe ? self?.scribeHotkeys : self?.hotkeys)?.dictationEndedExternally()
        }
        dictation.onInserted = { [weak self] text, context, transcriptID in
            self?.learner.watch(inserted: text, context: context, transcriptID: transcriptID)
        }

        permissions.onAccessibilityChange = { [weak self] _ in self?.updateHotkeyMonitor() }
        permissions.startMonitoring()
        updateHotkeyMonitor()

        // Set the microphone up ahead of time, and again whenever the choice or the permission changes,
        // so that pressing the key only has to switch it on.
        prepareMicrophone()
        observeChanges(of: { [weak self] in self?.settings.inputDeviceUID }) { [weak self] _ in self?.prepareMicrophone() }
        observeChanges(of: { [weak self] in self?.settings.microphoneReadiness }) { [weak self] _ in self?.prepareMicrophone() }
        observeChanges(of: { [weak self] in self?.permissions.microphone }) { [weak self] _ in self?.prepareMicrophone() }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.recorder.refreshAfterWake()
        }

        NotificationCenter.default.addObserver(forName: .nabraHotkeySettingsChanged, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.hotkeys.update(hotkey: self.settings.hotkey, config: self.settings.gestureConfig)
            self.scribeHotkeys.update(hotkey: self.settings.scribeHotkey, config: self.settings.gestureConfig)
            self.updateHotkeyMonitor()
            // Switched off, Scribe lets go of its model at once rather than after the idle wait.
            if !self.settings.scribeEnabled { self.writer.stopNow() }
        }

        downloads.onInstalled = { [weak self] model in
            guard let self else { return }
            // Scribe's files are not speech models: there is nothing to reload for them.
            guard !model.id.hasPrefix("writer-") else { return }
            self.transcription.refreshInstalledState()
            self.warmUp()
        }

        // Everything the first press would otherwise have to create on the spot.
        hud.prepare()
        _ = KeyboardLayout.currentInputIsArabic

        // Load once at launch so the first dictation is instant, then release when idle.
        warmUp()
        if let days = settings.audioRetention.days, days > 0 {
            history.pruneAudio(olderThanDays: days)
        }
    }

    private func prepareMicrophone() {
        // A demo or test instance runs next to the real app and must not hold the microphone open on its own.
        var standby = AudioRecorder.Standby.never
        if !AppState.isDemo, !AppState.isRobot {
            switch settings.microphoneReadiness {
            case .onDemand: standby = .never
            case .lingering: standby = .after(60)
            case .always: standby = .always
            }
        }
        if let forced = AppState.forcedStandby { standby = forced }
        recorder.setStandby(standby)
        recorder.prepare(deviceUID: settings.inputDeviceUID)
    }

    /// For the end-to-end tests: NABRA_STANDBY=always or a number of seconds.
    private static let forcedStandby: AudioRecorder.Standby? = {
        guard let value = ProcessInfo.processInfo.environment["NABRA_STANDBY"] else { return nil }
        if value == "always" { return .always }
        return Double(value).map { .after($0) }
    }()

    /// The key monitors, for the built-in end-to-end tests.
    var hotkeyMonitor: HotkeyMonitor { hotkeys }
    var scribeHotkeyMonitor: HotkeyMonitor { scribeHotkeys }

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
        if AppState.isDemo || AppState.isRobot {
            hotkeyActive = true
            return
        }
        if hotkeysPaused { return }
        if permissions.accessibility {
            hotkeyActive = hotkeys.start()
            if scribeKeyUsable {
                scribeHotkeys.start()
            } else {
                scribeHotkeys.stop()
            }
            if !hotkeyActive {
                // Access was only just granted; the system can take a moment to honour it.
                retryTimer?.invalidate()
                retryTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
                    self?.updateHotkeyMonitor()
                }
            }
        } else {
            hotkeys.stop()
            scribeHotkeys.stop()
            hotkeyActive = false
        }
    }

    /// Switches Nabra's own keys off while a new shortcut is being recorded, and back on afterwards.
    func pauseHotkeys(_ paused: Bool) {
        guard !AppState.isDemo, !AppState.isRobot else { return }
        hotkeysPaused = paused
        if paused {
            hotkeys.stop()
            scribeHotkeys.stop()
        } else {
            updateHotkeyMonitor()
        }
    }

    /// Scribe is on and its key is not also the dictation key.
    var scribeKeyUsable: Bool {
        settings.scribeEnabled && !settings.scribeHotkey.overlaps(settings.hotkey)
    }
}
