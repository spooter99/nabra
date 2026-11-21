import AppKit
import SwiftUI

/// Owns the floating panel that hangs under the notch while dictating.
/// The panel never takes focus and ignores the mouse, so it cannot get in the way.
final class HUDController {
    let model = HUDModel()
    /// Where the user wants the indicator. Read each time it is shown.
    var position: () -> IndicatorPosition = { .bottom }
    /// Test switch: keep the model up to date but never put the panel on screen.
    var isSuppressed = false
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?
    private var orderOutWork: DispatchWorkItem?

    static let panelSize = CGSize(width: 620, height: 220)

    /// `live` is false while the microphone is still starting: the indicator then appears dimmed
    /// and still, and comes alive through `setLive` once sound is really arriving.
    func showListening(handsFree: Bool, meter: LevelMeter, live: Bool = true) {
        cancelTimers()
        placeOnActiveScreen()
        model.meter = meter
        model.isHandsFree = handsFree
        model.liveText = ""
        model.listeningSince = Date()
        model.isLive = live
        present(.listening)
    }

    func setLive(_ live: Bool) {
        guard model.isLive != live else { return }
        withAnimation(.easeOut(duration: 0.12)) { model.isLive = live }
    }

    /// Builds the panel and its view ahead of time, so the first dictation after launch does not
    /// spend a tenth of a second creating them before the indicator can appear.
    func prepare() {
        ensurePanel()
        panel?.contentView?.layoutSubtreeIfNeeded()
    }

    func setHandsFree(_ handsFree: Bool) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { model.isHandsFree = handsFree }
    }

    func setLiveText(_ text: String) {
        guard model.mode == .listening else { return }
        withAnimation(.easeOut(duration: 0.18)) { model.liveText = text }
    }

    func showProcessing(polishing: Bool) {
        cancelTimers()
        if panel?.isVisible != true { placeOnActiveScreen() }
        model.isPolishing = polishing
        present(.processing)
    }

    /// Scribe has started writing: open the pill up for the text.
    func showWriting() {
        cancelTimers()
        if panel?.isVisible != true { placeOnActiveScreen() }
        model.writingText = ""
        present(.writing)
    }

    /// The text Scribe has written so far.
    func setWritingText(_ text: String) {
        guard model.mode == .writing else { return }
        withAnimation(.easeOut(duration: 0.12)) { model.writingText = text }
    }

    func showSuccess() {
        cancelTimers()
        guard panel?.isVisible == true else { return }
        present(.success)
        scheduleHide(after: 0.55)
    }

    /// Shows a short message. With an `action` the message carries a button ("Try again") and stays
    /// up longer; only the pill itself then takes clicks, never the empty space around it.
    func showNotice(_ text: String, symbol: String, isError: Bool, action: (title: String, run: () -> Void)? = nil) {
        cancelTimers()
        if panel?.isVisible != true || action != nil { placeOnActiveScreen() }
        model.noticeText = text
        model.noticeSymbol = symbol
        model.noticeIsError = isError
        model.noticeAction = action?.title
        model.onNoticeAction = action.map { action in
            { [weak self] in
                self?.hide()
                action.run()
            }
        }
        present(.notice)
        if action != nil { makeClickable() }
        scheduleHide(after: action != nil ? 6 : (isError ? 2.6 : 1.7))
    }

    /// Shrinks the panel to the pill and lets it take clicks, for a notice with a button.
    private func makeClickable() {
        guard let panel, let screen = HUDController.activeScreen() else { return }
        let estimated = CGFloat(model.noticeText.count) * 7.2 + 60 + CGFloat(model.noticeAction?.count ?? 0) * 7 + 30
        let width = min(HUDController.panelSize.width, max(120, min(480, estimated)) + 40)
        let frame = panel.frame
        var target = NSRect(x: frame.midX - width / 2, y: frame.minY, width: width, height: 60)
        if model.placement != .bottom {
            target.size.height = min(HUDController.panelSize.height, screen.frame.maxY - screen.visibleFrame.maxY + 70)
            target.origin.y = screen.frame.maxY - target.height
        }
        panel.setFrame(target, display: true)
        panel.ignoresMouseEvents = false
    }

    private func makeClickThrough() {
        model.noticeAction = nil
        model.onNoticeAction = nil
        guard let panel, !panel.ignoresMouseEvents else { return }
        panel.ignoresMouseEvents = true
        placeOnActiveScreen()
    }

    func hide() {
        cancelTimers()
        guard panel?.isVisible == true else { return }
        panel?.ignoresMouseEvents = true
        withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) { model.mode = .hidden }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.model.mode == .hidden else { return }
            self.panel?.orderOut(nil)
            self.model.liveText = ""
            self.model.noticeAction = nil
            self.model.onNoticeAction = nil
        }
        orderOutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    // MARK: - Panel

    private func present(_ mode: HUDModel.Mode) {
        ensurePanel()
        if mode != .notice { makeClickThrough() }
        if !isSuppressed { panel?.orderFrontRegardless() }
        withAnimation(.spring(response: 0.34, dampingFraction: 0.78)) { model.mode = mode }
    }

    private func scheduleHide(after delay: TimeInterval) {
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func cancelTimers() {
        hideWork?.cancel()
        hideWork = nil
        orderOutWork?.cancel()
        orderOutWork = nil
    }

    private func ensurePanel() {
        guard panel == nil else { return }
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: HUDController.panelSize),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.isReleasedWhenClosed = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 8)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.animationBehavior = .none
        let host = FirstClickHostingView(rootView: NotchView(model: model))
        host.frame = NSRect(origin: .zero, size: HUDController.panelSize)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        self.panel = panel
    }

    /// Puts the panel on the screen the user is working on: bottom centre, or top centre for the notch style.
    private func placeOnActiveScreen() {
        ensurePanel()
        guard let screen = HUDController.activeScreen() else { return }
        let frame = screen.frame
        let size = HUDController.panelSize
        let origin: CGPoint
        switch position() {
        case .bottom:
            model.placement = .bottom
            // Just above the Dock (or the screen edge when the Dock is hidden).
            origin = CGPoint(x: frame.midX - size.width / 2, y: screen.visibleFrame.minY + 2)
        case .notch:
            if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea, screen.safeAreaInsets.top > 0 {
                model.placement = .notch(CGSize(width: frame.width - left.width - right.width, height: screen.safeAreaInsets.top))
            } else {
                model.placement = .top(menuBarHeight: max(22, frame.maxY - screen.visibleFrame.maxY))
            }
            origin = CGPoint(x: frame.midX - size.width / 2, y: frame.maxY - size.height)
        }
        panel?.setFrame(NSRect(origin: origin, size: size), display: false)
    }

    /// The screen that holds the focused window, falling back to the one under the pointer.
    private static func activeScreen() -> NSScreen? {
        if let main = NSScreen.main { return main }
        let pointer = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.screens.first
    }
}

/// The panel never becomes active, so its button must answer the very first click.
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
