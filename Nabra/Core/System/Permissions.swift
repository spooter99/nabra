import AppKit
import AVFoundation
import Observation

/// Tracks the two permissions Nabra needs: the microphone, and Accessibility (to see the dictation
/// key and to type the result into other apps).
@Observable
final class Permissions {
    private(set) var microphone: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    private(set) var accessibility: Bool = AXIsProcessTrusted()

    @ObservationIgnored private var timer: Timer?
    /// Called on the main thread when Accessibility access changes.
    @ObservationIgnored var onAccessibilityChange: ((Bool) -> Void)?

    var microphoneGranted: Bool { microphone == .authorized }
    var allGranted: Bool { microphoneGranted && accessibility }

    /// Polls once a second. Permission changes have no notification, and the poll is two cheap calls.
    func startMonitoring() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func refresh() {
        let mic = AVCaptureDevice.authorizationStatus(for: .audio)
        if mic != microphone { microphone = mic }
        let trusted = AXIsProcessTrusted()
        if trusted != accessibility {
            accessibility = trusted
            onAccessibilityChange?(trusted)
        }
    }

    func requestMicrophone() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
                DispatchQueue.main.async { self?.refresh() }
            }
        case .authorized:
            refresh()
        default:
            Permissions.openSettings("Privacy_Microphone")
        }
    }

    func requestAccessibility() {
        Accessibility.requestTrust()
        Permissions.openSettings("Privacy_Accessibility")
    }

    static func openSettings(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}
