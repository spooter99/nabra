import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private(set) var state: AppState!
    private var statusItem: StatusItemController!
    private var mainWindow: NSWindow?
    private let navigation = Navigation()
    private var robot: Robot?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.info("Nabra \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "") launched")
        NSApp.mainMenu = MainMenu.build(target: self)

        state = AppState()
        if AppState.isRobot {
            // Unattended end-to-end checks: no menu bar item, no window, nothing inserted, and it quits by itself.
            Robot.configure(state)
            state.start()
            robot = Robot(state: state)
            robot?.run()
            return
        }
        statusItem = StatusItemController(state: state, delegate: self)
        state.dictation.onNeedsSetup = { [weak self] in self?.showMainWindow() }
        state.start()
        RemoteControl.install(state: state, delegate: self)

        // Opened by hand, or still needs setting up: show the window. Launched at login: stay in the menu bar.
        let quietLaunch = AppDelegate.launchedAsLoginItem || CommandLine.arguments.contains("--background")
        if state.needsSetup || !quietLaunch {
            showMainWindow()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        state?.recorder.shutdown()
        state?.writer.shutdown()
        state?.transcription.shutdown()
        UserDefaults.standard.synchronize()
        // The speech engine's GPU backend tears itself down in C++ static destructors when the process
        // exits, and aborts there if Metal is still finishing work. Everything that matters is saved
        // by now (the database commits as it goes), so leave without running them.
        Log.flushSynchronously()
        _exit(0)
    }

    // MARK: - Windows

    @objc func showMainWindow() {
        if mainWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 660),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.title = "Nabra"
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.toolbarStyle = .unified
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 820, height: 560)
            window.delegate = self
            if !AppState.isDemo { window.setFrameAutosaveName("NabraMainWindow2") }
            let root = RootView()
                .environment(state)
                .environment(navigation)
            let host = NSHostingController(rootView: root)
            // The window decides its size; SwiftUI only supplies the minimum.
            host.sizingOptions = [.minSize]
            window.contentViewController = host
            if AppState.isDemo || !window.setFrameUsingName("NabraMainWindow2") {
                window.setContentSize(NSSize(width: 1000, height: 700))
                window.center()
            }
            mainWindow = window
        }
        NSApp.setActivationPolicy(.regular)
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func showSettings() {
        navigation.section = .settings
        showMainWindow()
    }

    func show(_ section: Navigation.Section) {
        navigation.section = section
        showMainWindow()
    }

    func windowWillClose(_ notification: Notification) {
        // Back to a menu-bar-only app once the window is gone.
        DispatchQueue.main.async {
            if NSApp.windows.allSatisfy({ !$0.isVisible || $0 is NSPanel || $0.className.contains("StatusBar") }) {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }

    private static var launchedAsLoginItem: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventID == kAEOpenApplication
        else { return false }
        return event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }
}

/// Which page of the main window is showing.
@Observable
final class Navigation {
    enum Section: String, CaseIterable, Identifiable {
        case home
        case history
        case dictionary
        case settings

        var id: String { rawValue }

        var title: String {
            switch self {
            case .home: return "Home"
            case .history: return "History"
            case .dictionary: return "Dictionary"
            case .settings: return "Settings"
            }
        }

        var symbol: String {
            switch self {
            case .home: return "waveform"
            case .history: return "clock.arrow.circlepath"
            case .dictionary: return "character.book.closed"
            case .settings: return "gearshape"
            }
        }
    }

    var section: Section = .home
}

/// The standard menus. Without an Edit menu, copy and paste do not work in the app's own text fields.
enum MainMenu {
    static func build(target: AppDelegate) -> NSMenu {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Nabra", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let settings = appMenu.addItem(withTitle: "Settings…", action: #selector(AppDelegate.showSettings), keyEquivalent: ",")
        settings.target = target
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Nabra", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Nabra", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.windowsMenu = windowMenu
        return main
    }
}
