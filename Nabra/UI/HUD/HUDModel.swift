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
        /// Scribe is writing: the pill opens up and shows the text as it is generated.
        case writing
    }

    var mode: Mode = .hidden
    var isHandsFree = false
    var isPolishing = false
    var noticeText = ""
    var noticeSymbol = "info.circle.fill"
    var noticeIsError = false
    /// A button on the notice ("Try again"), or nil.
    var noticeAction: String?
    @ObservationIgnored var onNoticeAction: (() -> Void)?
    var liveText = ""
    /// What Scribe has written so far.
    var writingText = ""
    var listeningSince = Date()
    /// False while the microphone has been asked to start but is not being heard yet.
    var isLive = true

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
