import AppKit
import SwiftUI

/// Shared look: rounded cards on the window background.
struct Card<Content: View>: View {
    var padding: CGFloat = 18
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.72))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
            )
    }
}

/// A keyboard key drawn as a key cap.
struct KeyCap: View {
    var symbol: String
    var label: String?
    var size: CGFloat = 54

    var body: some View {
        VStack(spacing: 1) {
            Text(symbol)
                .font(.system(size: size * 0.4, weight: .medium, design: .rounded))
            if let label {
                Text(label)
                    .font(.system(size: size * 0.16, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size * 1.12, height: size)
        .background(
            RoundedRectangle(cornerRadius: size * 0.2, style: .continuous)
                .fill(LinearGradient(colors: [Color(nsColor: .controlBackgroundColor), Color(nsColor: .windowBackgroundColor)],
                                     startPoint: .top, endPoint: .bottom))
                .shadow(color: .black.opacity(0.16), radius: 1.5, y: 1.5)
        )
        .overlay(
            RoundedRectangle(cornerRadius: size * 0.2, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.14), lineWidth: 1)
        )
    }
}

/// Small rounded label.
struct Badge: View {
    var text: String
    var tint: Color = .secondary

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(Capsule().fill(tint.opacity(0.13)))
    }
}

/// Text laid out in its own writing direction: Arabic right-to-left, English left-to-right.
struct DirectionalText: View {
    var text: String
    var font: Font = .body
    var lineLimit: Int?

    var body: some View {
        let rightToLeft = TextScript.isRightToLeft(text)
        Text(text)
            .font(font)
            .lineLimit(lineLimit)
            .lineSpacing(2.5)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .environment(\.layoutDirection, rightToLeft ? .rightToLeft : .leftToRight)
    }
}

/// Icon of the app a dictation went into.
struct AppIcon: View {
    var bundleID: String?
    var size: CGFloat = 16

    var body: some View {
        if let bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: size, height: size)
        } else {
            Image(systemName: "app.dashed")
                .font(.system(size: size * 0.8))
                .foregroundStyle(.tertiary)
                .frame(width: size, height: size)
        }
    }
}

/// The Nabra mark: a notch with sound bars under it.
struct NabraMark: View {
    var size: CGFloat = 64

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.33, green: 0.30, blue: 0.86), Color(red: 0.62, green: 0.33, blue: 0.93)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            VStack(spacing: 0) {
                UnevenRoundedRectangle(bottomLeadingRadius: size * 0.07, bottomTrailingRadius: size * 0.07, style: .continuous)
                    .fill(.black.opacity(0.85))
                    .frame(width: size * 0.42, height: size * 0.13)
                Spacer(minLength: 0)
            }
            HStack(spacing: size * 0.055) {
                ForEach(Array([0.32, 0.62, 1.0, 0.72, 0.42].enumerated()), id: \.offset) { _, height in
                    Capsule()
                        .fill(.white)
                        .frame(width: size * 0.075, height: size * 0.44 * height)
                }
            }
            .offset(y: size * 0.07)
        }
        .frame(width: size, height: size)
    }
}

extension Date {
    /// "Today", "Yesterday", or a full date.
    var dayHeading: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(self) { return "Today" }
        if calendar.isDateInYesterday(self) { return "Yesterday" }
        let formatter = DateFormatter()
        formatter.dateFormat = calendar.isDate(self, equalTo: Date(), toGranularity: .year) ? "EEEE, d MMMM" : "d MMMM yyyy"
        return formatter.string(from: self)
    }

    var clockTime: String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: self)
    }
}

extension TimeInterval {
    /// "8s", "1m 05s".
    var shortDuration: String {
        let seconds = Int(self.rounded())
        if seconds < 60 { return "\(max(1, seconds))s" }
        return String(format: "%dm %02ds", seconds / 60, seconds % 60)
    }
}
