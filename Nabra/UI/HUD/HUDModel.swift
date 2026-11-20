import AppKit
import Observation

/// What the notch display is showing.
@Observable
final class HUDModel {
    enum Mode: Equatable {
        case hidden
        case listening
        case processing
        case success
        case notice
    }

    var mode: Mode = .hidden
    var isHandsFree = false
    var isPolishing = false
    var noticeText = ""
    var noticeSymbol = "info.circle.fill"
    var noticeIsError = false
    var liveText = ""
    var listeningSince = Date()

    /// Where on the screen the indicator is drawn.
    enum Placement: Equatable {
        /// A small pill floating above the bottom edge.
        case bottom
        /// Growing out of the hardware notch of this size.
        case notch(CGSize)
        /// A pill under the menu bar, for screens without a notch.
        case top(menuBarHeight: CGFloat)
    }

    var placement: Placement = .bottom

    @ObservationIgnored var meter: LevelMeter?
}
