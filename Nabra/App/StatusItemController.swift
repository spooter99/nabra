import AppKit

/// The menu bar item: shows whether Nabra is listening and gives quick access to recent dictations.
final class StatusItemController: NSObject, NSMenuDelegate {
    private let item: NSStatusItem
    private let state: AppState
    private weak var delegate: AppDelegate?

    init(state: AppState, delegate: AppDelegate) {
        self.state = state
        self.delegate = delegate
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        updateIcon()
        observeChanges(of: { [weak state] in state?.dictation.phase }) { [weak self] _ in self?.updateIcon() }
        observeChanges(of: { [weak state] in state?.needsSetup }) { [weak self] _ in self?.updateIcon() }
    }

    private func updateIcon() {
        guard let button = item.button else { return }
        let listening = state.dictation.phase == .listening
        let symbol: String
        if state.needsSetup {
            symbol = "waveform.badge.exclamationmark"
        } else if listening {
            symbol = "waveform.circle.fill"
        } else {
            symbol = "waveform"
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Nabra")
        image?.isTemplate = !listening
        button.image = image
        button.contentTintColor = listening ? .systemRed : nil
        button.toolTip = listening ? "Nabra is listening" : "Nabra: hold \(state.settings.hotkey.displayName) to dictate"
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let headline: String
        if !state.permissions.allGranted {
            headline = "Finish setup to start dictating"
        } else if state.transcription.state == .missingModel {
            headline = "Speech model not installed"
        } else {
            headline = "Hold \(state.settings.hotkey.displayName) and speak"
        }
        let header = NSMenuItem(title: headline, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        let toggleTitle = state.dictation.phase == .listening ? "Finish Dictation" : "Start Dictation"
        let toggle = menu.addItem(withTitle: toggleTitle, action: #selector(toggleDictation), keyEquivalent: "")
        toggle.target = self
        toggle.isEnabled = !state.needsSetup
        menu.addItem(.separator())

        let recent = state.history.transcripts(limit: 6)
        if recent.isEmpty {
            let empty = NSMenuItem(title: "No dictations yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            let label = NSMenuItem(title: "Recent (click to copy)", action: nil, keyEquivalent: "")
            label.isEnabled = false
            menu.addItem(label)
            for transcript in recent {
                let single = transcript.text.replacingOccurrences(of: "\n", with: " ")
                let title = single.count > 58 ? String(single.prefix(56)) + "…" : single
                let entry = menu.addItem(withTitle: title, action: #selector(copyTranscript(_:)), keyEquivalent: "")
                entry.target = self
                entry.representedObject = transcript.text
                entry.toolTip = transcript.text
            }
        }
        menu.addItem(.separator())

        let pasteLast = menu.addItem(withTitle: "Paste Last Dictation", action: #selector(pasteLast), keyEquivalent: "")
        pasteLast.target = self
        pasteLast.isEnabled = state.dictation.lastText != nil
        menu.addItem(.separator())

        let open = menu.addItem(withTitle: "Open Nabra", action: #selector(openApp), keyEquivalent: "")
        open.target = self
        let settings = menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Nabra", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    @objc private func toggleDictation() { state.dictation.toggle() }
    @objc private func pasteLast() {
        // Let the menu close and the previous app regain focus first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.state.dictation.pasteLast() }
    }
    @objc private func openApp() { delegate?.showMainWindow() }
    @objc private func openSettings() { delegate?.showSettings() }

    @objc private func copyTranscript(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
