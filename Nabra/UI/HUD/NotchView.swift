import SwiftUI

/// The dictation indicator.
///
/// By default a small pill near the bottom of the screen: just a waveform while you speak.
/// Optionally a black shape that grows out of the notch (or sits under the menu bar on screens without one).
struct NotchView: View {
    let model: HUDModel

    var body: some View {
        ZStack(alignment: isBottom ? .bottom : .top) {
            switch model.placement {
            case .bottom: pill(anchor: .bottom, inset: 12)
            case .notch(let notch): attached(to: notch)
            case .top(let menuBarHeight): pill(anchor: .top, inset: menuBarHeight + 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: isBottom ? .bottom : .top)
        .environment(\.colorScheme, .dark)
        .environment(\.layoutDirection, .leftToRight)
    }

    // MARK: - Layout

    private var isBottom: Bool { model.placement == .bottom }
    /// The bottom pill is deliberately tiny; the notch style has room for a timer.
    private var compact: Bool { isBottom }
    private var rowHeight: CGFloat { compact ? 28 : 36 }
    private var isVisible: Bool { model.mode != .hidden }
    private var showsLiveText: Bool { model.mode == .listening && !model.liveText.isEmpty }
    private var showsHint: Bool { model.mode == .listening && model.isHandsFree && !showsLiveText && !compact }
    private var showsWritingText: Bool { model.mode == .writing && !model.writingText.isEmpty }
    private static let writingWidth: CGFloat = 440

    /// Room for the text Scribe has written so far: up to seven lines, growing as it streams in.
    private var writingTextHeight: CGFloat {
        guard showsWritingText else { return 0 }
        let perLine = max(1, Int((NotchView.writingWidth - 32) / 6.6))
        let lines = model.writingText.components(separatedBy: "\n").reduce(0) { $0 + max(1, ($1.count + perLine - 1) / perLine) }
        return CGFloat(min(7, lines)) * 17 + 14
    }

    private func bodyWidth(minimum: CGFloat) -> CGFloat {
        if showsLiveText { return max(minimum, 380) }
        if model.mode == .writing { return max(minimum, showsWritingText ? NotchView.writingWidth : 96) }
        if model.mode == .notice {
            var estimated = CGFloat(model.noticeText.count) * 7.2 + 60
            if let action = model.noticeAction { estimated += CGFloat(action.count) * 7 + 30 }
            return max(minimum, min(480, estimated))
        }
        if compact, model.mode == .listening, model.isHandsFree { return minimum + 18 }
        return minimum
    }

    private var contentHeight: CGFloat {
        guard isVisible else { return 0 }
        var height = rowHeight
        if showsLiveText { height += 44 }
        height += writingTextHeight
        if showsHint { height += 16 }
        return height
    }

    private func attached(to notch: CGSize) -> some View {
        // Two points wider than the hardware notch so no hairline shows at its edges.
        let top = notch.width + 2
        let width = bodyWidth(minimum: top)
        return ZStack(alignment: .top) {
            NotchShape(topWidth: top, notchHeight: notch.height, bodyWidth: width, height: notch.height + contentHeight)
                .fill(.black)
            content
                .frame(width: width, height: max(contentHeight, 1), alignment: .top)
                .padding(.top, notch.height)
                .opacity(isVisible ? 1 : 0)
        }
    }

    private func pill(anchor: UnitPoint, inset: CGFloat) -> some View {
        let width = bodyWidth(minimum: compact ? 78 : 196)
        let radius = min(rowHeight / 2, 19)
        return content
            .frame(width: width, height: max(contentHeight, rowHeight), alignment: .top)
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(.black.opacity(0.9))
                    .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(.white.opacity(0.16), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
            )
            .padding(anchor == .bottom ? .bottom : .top, inset)
            .opacity(isVisible ? 1 : 0)
            .scaleEffect(isVisible ? 1 : 0.7, anchor: anchor)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        VStack(spacing: 0) {
            // In the bottom pill the live text sits above the waveform, so the pill grows upward.
            if showsLiveText, compact { liveText }
            if showsWritingText { writingText }
            Group {
                switch model.mode {
                case .listening: listeningRow
                case .processing: processingRow
                case .success: successRow
                case .notice: noticeRow
                case .writing: writingRow
                case .hidden: Color.clear
                }
            }
            .frame(height: rowHeight)
            .padding(.horizontal, compact ? 12 : 15)

            if showsLiveText, !compact { liveText }
            if showsHint {
                Text("Tap key to finish · esc cancels")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(height: 16, alignment: .top)
                    .transition(.opacity)
            }
        }
    }

    private var liveText: some View {
        let rightToLeft = TextScript.isRightToLeft(model.liveText)
        return Text(model.liveText)
            .font(.system(size: 12.5))
            .foregroundStyle(.white.opacity(0.86))
            .lineLimit(2)
            .truncationMode(.head)
            .multilineTextAlignment(rightToLeft ? .trailing : .leading)
            .frame(maxWidth: .infinity, maxHeight: 44, alignment: rightToLeft ? .trailing : .leading)
            .padding(.horizontal, 16)
            .transition(.opacity)
    }

    private var writingText: some View {
        let rightToLeft = TextScript.isRightToLeft(model.writingText)
        return Text(model.writingText)
            .font(.system(size: 12.5))
            .foregroundStyle(.white.opacity(0.9))
            .lineLimit(7)
            .truncationMode(.head)
            .multilineTextAlignment(rightToLeft ? .trailing : .leading)
            .frame(maxWidth: .infinity, maxHeight: writingTextHeight, alignment: rightToLeft ? .bottomTrailing : .bottomLeading)
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .transition(.opacity)
    }

    private var writingRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles")
                .font(.system(size: compact ? 9.5 : 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
            ThinkingDots(size: compact ? 4 : 5)
        }
        .transition(.opacity)
    }

    private var listeningRow: some View {
        HStack(spacing: compact ? 6 : 9) {
            if compact {
                if model.isHandsFree {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white.opacity(0.75))
                }
                WaveformView(meter: model.meter, compact: true, live: model.isLive)
                    .frame(maxWidth: .infinity)
            } else {
                RecordingDot(isLocked: model.isHandsFree)
                WaveformView(meter: model.meter, compact: false, live: model.isLive)
                    .frame(maxWidth: .infinity)
                ElapsedTime(since: model.listeningSince)
            }
        }
        // Dimmed and still until the microphone is really being heard.
        .opacity(model.isLive ? 1 : 0.4)
        .transition(.opacity)
    }

    private var processingRow: some View {
        HStack(spacing: 6) {
            if model.isPolishing {
                Image(systemName: "sparkles")
                    .font(.system(size: compact ? 9.5 : 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
            }
            ThinkingDots(size: compact ? 4 : 5)
        }
        .transition(.opacity)
    }

    private var successRow: some View {
        Image(systemName: "checkmark")
            .font(.system(size: compact ? 11.5 : 14, weight: .bold))
            .foregroundStyle(Color(red: 0.36, green: 0.9, blue: 0.56))
            .transition(.scale(scale: 0.5).combined(with: .opacity))
    }

    private var noticeRow: some View {
        HStack(spacing: 7) {
            Image(systemName: model.noticeSymbol)
                .font(.system(size: compact ? 11 : 12, weight: .semibold))
                .foregroundStyle(model.noticeIsError ? Color(red: 1, green: 0.42, blue: 0.4) : .white.opacity(0.85))
            Text(model.noticeText)
                .font(.system(size: compact ? 12 : 12.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.95))
                .lineLimit(1)
            if let action = model.noticeAction {
                Text(action)
                    .font(.system(size: compact ? 11 : 11.5, weight: .semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2.5)
                    .background(Capsule().fill(.white.opacity(0.92)))
                    .contentShape(Capsule())
                    .onTapGesture { model.onNoticeAction?() }
                    .help(action)
            }
        }
        .fixedSize()
        .transition(.opacity)
    }
}

// MARK: - Shape

/// A rectangle hanging from the top edge whose lower part may be wider than its neck.
/// The neck matches the hardware notch; the widened body joins it with small inward curves.
struct NotchShape: Shape {
    var topWidth: CGFloat
    var notchHeight: CGFloat
    var bodyWidth: CGFloat
    var height: CGFloat
    var cornerRadius: CGFloat = 15

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(bodyWidth, height) }
        set {
            bodyWidth = newValue.first
            height = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let centre = rect.midX
        let total = max(height, notchHeight)
        let width = max(bodyWidth, topWidth)
        let overhang = (width - topWidth) / 2
        let below = total - notchHeight
        let bottom = min(cornerRadius, width / 2, max(0, below))
        let join = min(9, overhang, max(0, below / 2))
        let shoulder = min(9, max(0, overhang - join), max(0, below - bottom))

        let neckLeft = centre - topWidth / 2
        let neckRight = centre + topWidth / 2
        let bodyLeft = centre - width / 2
        let bodyRight = centre + width / 2

        var path = Path()
        path.move(to: CGPoint(x: neckLeft, y: 0))
        path.addLine(to: CGPoint(x: neckRight, y: 0))
        if overhang > 0.5, below > 0.5 {
            path.addLine(to: CGPoint(x: neckRight, y: notchHeight - join))
            path.addArc(tangent1End: CGPoint(x: neckRight, y: notchHeight),
                        tangent2End: CGPoint(x: neckRight + join, y: notchHeight), radius: join)
            path.addLine(to: CGPoint(x: bodyRight - shoulder, y: notchHeight))
            path.addArc(tangent1End: CGPoint(x: bodyRight, y: notchHeight),
                        tangent2End: CGPoint(x: bodyRight, y: notchHeight + shoulder), radius: shoulder)
        }
        path.addLine(to: CGPoint(x: bodyRight, y: total - bottom))
        path.addArc(tangent1End: CGPoint(x: bodyRight, y: total), tangent2End: CGPoint(x: bodyRight - bottom, y: total), radius: bottom)
        path.addLine(to: CGPoint(x: bodyLeft + bottom, y: total))
        path.addArc(tangent1End: CGPoint(x: bodyLeft, y: total), tangent2End: CGPoint(x: bodyLeft, y: total - bottom), radius: bottom)
        if overhang > 0.5, below > 0.5 {
            path.addLine(to: CGPoint(x: bodyLeft, y: notchHeight + shoulder))
            path.addArc(tangent1End: CGPoint(x: bodyLeft, y: notchHeight),
                        tangent2End: CGPoint(x: bodyLeft + shoulder, y: notchHeight), radius: shoulder)
            path.addLine(to: CGPoint(x: neckLeft - join, y: notchHeight))
            path.addArc(tangent1End: CGPoint(x: neckLeft, y: notchHeight),
                        tangent2End: CGPoint(x: neckLeft, y: notchHeight - join), radius: join)
        }
        path.closeSubpath()
        return path
    }
}

// MARK: - Pieces

private struct RecordingDot: View {
    var isLocked: Bool
    @State private var pulsing = false

    var body: some View {
        ZStack {
            if isLocked {
                Image(systemName: "lock.fill")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(Color(red: 1, green: 0.35, blue: 0.33))
            } else {
                Circle()
                    .fill(Color(red: 1, green: 0.27, blue: 0.25))
                    .frame(width: 7, height: 7)
                    .opacity(pulsing ? 0.45 : 1)
            }
        }
        .frame(width: 10, height: 10)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true)) { pulsing = true }
        }
    }
}

private struct ElapsedTime: View {
    var since: Date

    var body: some View {
        TimelineView(.periodic(from: since, by: 0.5)) { context in
            let seconds = max(0, Int(context.date.timeIntervalSince(since)))
            Text(String(format: "%d:%02d", seconds / 60, seconds % 60))
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.72))
        }
        .frame(width: 30, alignment: .trailing)
    }
}

private struct ThinkingDots: View {
    var size: CGFloat = 5

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: size) {
                ForEach(0..<3, id: \.self) { index in
                    let phase = sin(time * 6.5 - Double(index) * 0.9)
                    Circle()
                        .fill(.white)
                        .frame(width: size, height: size)
                        .opacity(0.35 + 0.6 * max(0, phase))
                        .offset(y: -2.2 * max(0, phase))
                }
            }
        }
    }
}

/// Scrolling loudness bars driven by the microphone level history.
private struct WaveformView: View {
    var meter: LevelMeter?
    var compact = false
    /// False while the microphone is starting: the bars rest instead of moving.
    var live = true
    @State private var clock = WaveformClock()

    private var barWidth: CGFloat { compact ? 2.5 : 3 }
    private var barSpacing: CGFloat { compact ? 2 : 2.5 }
    private let slicesPerBar = 2.0

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { context in
            Canvas { graphics, size in
                let count = max(5, Int((size.width + barSpacing) / (barWidth + barSpacing)))
                let used = CGFloat(count) * barWidth + CGFloat(count - 1) * barSpacing
                let originX = (size.width - used) / 2
                let cursor = clock.advance(to: context.date, available: meter?.sliceCount ?? 0)
                let needed = Int(Double(count) * slicesPerBar) + 4
                let end = Int(cursor.rounded(.down))
                let levels = meter?.levels(endingAt: end, count: needed) ?? []
                let fraction = cursor - Double(end)
                let time = context.date.timeIntervalSinceReferenceDate

                for bar in 0..<count {
                    // Newest audio is on the right; older audio scrolls left.
                    let age = Double(count - 1 - bar) * slicesPerBar - fraction
                    let position = Double(levels.count) - 1 - age
                    var level = WaveformView.sample(levels, at: position)
                    // A faint ripple keeps the display alive in silence.
                    level = live ? max(level, 0.05 + 0.03 * Float(sin(time * 3.2 + Double(bar) * 0.7))) : 0.05
                    let tallest = size.height * (compact ? 0.86 : 0.62)
                    let height = barWidth + (tallest - barWidth) * CGFloat(pow(Double(min(1, level)), 0.85))
                    let rect = CGRect(x: originX + CGFloat(bar) * (barWidth + barSpacing),
                                      y: (size.height - height) / 2, width: barWidth, height: height)
                    let fade = 0.45 + 0.55 * Double(bar + 1) / Double(count)
                    graphics.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2), with: .color(.white.opacity(fade)))
                }
            }
        }
        .frame(height: compact ? 18 : 30)
    }

    private static func sample(_ levels: [Float], at position: Double) -> Float {
        guard !levels.isEmpty, position >= 0 else { return 0 }
        let lower = Int(position.rounded(.down))
        guard lower < levels.count else { return levels[levels.count - 1] }
        let upper = min(levels.count - 1, lower + 1)
        let mix = Float(position - Double(lower))
        return levels[lower] * (1 - mix) + levels[upper] * mix
    }
}

/// Plays the level history back at real-time speed so bars move smoothly even though
/// audio arrives from the microphone in bursts.
private final class WaveformClock {
    private var cursor = 0.0
    private var lastDate: Date?

    func advance(to date: Date, available: Int) -> Double {
        let target = Double(available)
        if let lastDate {
            cursor += date.timeIntervalSince(lastDate) * LevelMeter.slicesPerSecond
        } else {
            cursor = target
        }
        lastDate = date
        // Stay within a short distance of the newest audio; never run ahead of it.
        cursor = min(target, max(cursor, target - 9))
        return cursor
    }
}
