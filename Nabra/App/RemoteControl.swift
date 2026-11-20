import AppKit

/// Lets scripts and tests drive a running Nabra:
///   defaults write app.nabra.Nabra remoteControlEnabled -bool YES
///   Nabra --remote start | stop | toggle | show | hud-demo
/// Off unless that preference is set, because it lets any local process start the microphone.
enum RemoteControl {
    /// A demo instance listens on its own channel so commands never reach the real app.
    private static let notification = Notification.Name(
        "app.nabra.remote" + (ProcessInfo.processInfo.environment["NABRA_REMOTE_CHANNEL"] ?? ""))

    static func install(state: AppState, delegate: AppDelegate) {
        guard UserDefaults.standard.bool(forKey: "remoteControlEnabled")
            || ProcessInfo.processInfo.environment["NABRA_REMOTE_CHANNEL"] != nil
        else { return }
        DistributedNotificationCenter.default().addObserver(forName: notification, object: nil, queue: .main) { [weak delegate] note in
            guard let command = note.object as? String else { return }
            Log.info("Remote command: \(command)")
            switch command {
            case "start": state.dictation.handle(.start(handsFree: true))
            case "stop": state.dictation.handle(.stop)
            case "cancel": state.dictation.handle(.cancel(.escape))
            case "toggle": state.dictation.toggle()
            case "show": delegate?.showMainWindow()
            case "home": delegate?.show(.home)
            case "history": delegate?.show(.history)
            case "dictionary": delegate?.show(.dictionary)
            case "settings": delegate?.show(.settings)
            case "hud-listening": state.hud.showListening(handsFree: false, meter: state.recorder.meter)
            case "hud-handsfree": state.hud.showListening(handsFree: true, meter: state.recorder.meter)
            case "hud-processing": state.hud.showProcessing(polishing: false)
            case "hud-polishing": state.hud.showProcessing(polishing: true)
            case "hud-success": state.hud.showSuccess()
            case "hud-notice": state.hud.showNotice("Learned “Darwish”", symbol: "character.book.closed.fill", isError: false)
            case "hud-error": state.hud.showNotice("Microphone access is off", symbol: "exclamationmark.triangle.fill", isError: true)
            case "hud-hide": state.hud.hide()
            default: break
            }
        }
    }

    /// Sends a command to the running app. Returns the process exit code.
    static func send(_ command: String) -> Int32 {
        DistributedNotificationCenter.default().postNotificationName(notification, object: command, userInfo: nil,
                                                                     deliverImmediately: true)
        // Give the notification a moment to leave this process.
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
        return 0
    }
}
