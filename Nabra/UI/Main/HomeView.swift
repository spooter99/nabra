import Charts
import SwiftUI

struct HomeView: View {
    @Environment(AppState.self) private var state
    @Environment(Navigation.self) private var navigation

    var body: some View {
        // Reading `revision` makes the page refresh whenever a dictation is saved.
        let _ = state.history.revision
        let stats = state.history.stats()
        let recent = state.history.transcripts(limit: 4)

        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(greeting)
                        .font(.system(size: 28, weight: .bold))
                    Text("Speak anywhere on your Mac. Nabra types it for you, in Arabic, English, or both at once.")
                        .font(.system(size: 13.5))
                        .foregroundStyle(.secondary)
                }

                HowToCard()

                HStack(spacing: 12) {
                    StatTile(value: stats.todayWords.formatted(), label: "Words today", symbol: "sun.max.fill", tint: .orange)
                    StatTile(value: stats.totalWords.formatted(), label: "Words dictated", symbol: "text.word.spacing", tint: .accentColor)
                    StatTile(value: savedText(stats.minutesSaved), label: "Time saved", symbol: "bolt.fill", tint: .green)
                    StatTile(value: stats.streakDays == 1 ? "1 day" : "\(stats.streakDays) days", label: "Streak", symbol: "flame.fill", tint: .pink)
                }

                if stats.totalCount > 0 {
                    Card {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("Last 14 days")
                                    .font(.system(size: 13, weight: .semibold))
                                Spacer()
                                if stats.wordsPerMinute > 0 {
                                    Text("\(stats.wordsPerMinute) words per minute on average")
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Chart(stats.dailyWords, id: \.day) { entry in
                                BarMark(x: .value("Day", entry.day, unit: .day), y: .value("Words", entry.words), width: .ratio(0.62))
                                    .foregroundStyle(Color.accentColor.gradient)
                                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                            }
                            .chartXAxis {
                                AxisMarks(values: .stride(by: .day, count: 2)) { _ in
                                    AxisValueLabel(format: .dateTime.day().month(.abbreviated), centered: true)
                                        .font(.system(size: 9.5))
                                }
                            }
                            .chartYAxis {
                                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
                                    AxisGridLine().foregroundStyle(Color.primary.opacity(0.06))
                                    AxisValueLabel().font(.system(size: 9.5))
                                }
                            }
                            .frame(height: 120)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Recent")
                            .font(.system(size: 15, weight: .semibold))
                        Spacer()
                        if !recent.isEmpty {
                            Button("See all") { navigation.section = .history }
                                .buttonStyle(.link)
                                .font(.system(size: 12))
                        }
                    }
                    if recent.isEmpty {
                        Card {
                            HStack(spacing: 12) {
                                Image(systemName: "text.bubble")
                                    .font(.system(size: 22))
                                    .foregroundStyle(.tertiary)
                                Text("Your dictations will appear here. Click into any text field, hold \(state.settings.hotkey.displayName), and say something.")
                                    .font(.system(size: 12.5))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        VStack(spacing: 8) {
                            ForEach(recent) { transcript in
                                TranscriptRow(transcript: transcript, compact: true)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 30)
            .padding(.vertical, 26)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollContentBackground(.hidden)
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<12: return "Good morning"
        case 12..<18: return "Good afternoon"
        default: return "Good evening"
        }
    }

    private func savedText(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes) min" }
        return String(format: "%.1f hr", Double(minutes) / 60)
    }
}

/// Explains the two gestures, drawn with key caps.
private struct HowToCard: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let hotkey = state.settings.hotkey
        Card(padding: 20) {
            HStack(spacing: 22) {
                KeyCap(symbol: hotkey.keyCapSymbol, label: hotkey.kind == .key ? nil : "hold", size: 60)
                VStack(alignment: .leading, spacing: 9) {
                    gesture("Hold \(hotkey.displayName) and speak", "Release to insert the text where your cursor is.", "hand.tap.fill")
                    if state.settings.handsFreeEnabled {
                        gesture("Double-tap for hands-free", "Keeps listening without holding. Tap once more to finish.", "lock.fill")
                    }
                    gesture("Esc cancels", "Nothing is inserted.", "escape")
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 6) {
                    Badge(text: state.settings.languageMode.title, tint: .accentColor)
                    Badge(text: "On this Mac only", tint: .green)
                }
            }
        }
    }

    private func gesture(_ title: String, _ detail: String, _ symbol: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
        }
    }
}

private struct StatTile: View {
    var value: String
    var label: String
    var symbol: String
    var tint: Color

    var body: some View {
        Card(padding: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(tint.opacity(0.14)))
                Text(value)
                    .font(.system(size: 21, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(label)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
        }
    }
}
