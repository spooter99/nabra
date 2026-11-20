import AVFoundation
import SwiftUI

struct HistoryView: View {
    @Environment(AppState.self) private var state
    @State private var search = ""
    @State private var confirmingClear = false

    var body: some View {
        let _ = state.history.revision
        let transcripts = state.history.transcripts(matching: search, limit: 400)
        let groups = Dictionary(grouping: transcripts) { Calendar.current.startOfDay(for: $0.createdAt) }
        let days = groups.keys.sorted(by: >)

        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8, pinnedViews: []) {
                if transcripts.isEmpty {
                    emptyState
                } else {
                    ForEach(days, id: \.self) { day in
                        Text(day.dayHeading)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.top, day == days.first ? 0 : 12)
                            .padding(.leading, 4)
                        ForEach(groups[day] ?? []) { transcript in
                            TranscriptRow(transcript: transcript, compact: false)
                        }
                    }
                }
            }
            .padding(.horizontal, 30)
            .padding(.vertical, 22)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollContentBackground(.hidden)
        .searchable(text: $search, placement: .toolbar, prompt: "Search dictations")
        .navigationTitle("History")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Export as Text…", action: export)
                    Divider()
                    Button("Delete All History…", role: .destructive) { confirmingClear = true }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .disabled(transcripts.isEmpty && search.isEmpty)
            }
        }
        .confirmationDialog("Delete every saved dictation?", isPresented: $confirmingClear) {
            Button("Delete All", role: .destructive) { state.history.deleteAll() }
        } message: {
            Text("This removes all text and audio saved by Nabra. Your dictionary is kept.")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: search.isEmpty ? "clock.arrow.circlepath" : "magnifyingglass")
                .font(.system(size: 30))
                .foregroundStyle(.tertiary)
            Text(search.isEmpty ? "Nothing here yet" : "No dictations match “\(search)”")
                .font(.system(size: 14, weight: .semibold))
            if search.isEmpty {
                Text("Everything you dictate is saved here, on this Mac.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 110)
    }

    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Nabra dictations.txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        let text = state.history.transcripts(matching: search, limit: 100_000).reversed().map { item in
            "[\(formatter.string(from: item.createdAt))\(item.appName.map { " · \($0)" } ?? "")]\n\(item.text)\n"
        }.joined(separator: "\n")
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
}

/// One saved dictation, with copy, edit, play and delete.
struct TranscriptRow: View {
    @Environment(AppState.self) private var state
    var transcript: Transcript
    var compact: Bool

    @State private var hovering = false
    @State private var editing = false
    @State private var draft = ""
    @State private var copied = false
    @State private var learned: [String] = []
    @State private var player = ClipPlayer()

    var body: some View {
        Card(padding: 14) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    AppIcon(bundleID: transcript.appBundleID, size: 15)
                    Text(metaLine)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if transcript.polished { Badge(text: "Polished", tint: .purple) }
                    if transcript.edited { Badge(text: "Edited") }
                    Spacer(minLength: 8)
                    actions
                        .opacity(hovering || editing || copied || player.isPlaying ? 1 : 0)
                }
                if editing {
                    editor
                } else {
                    DirectionalText(text: transcript.text, font: .system(size: 13.5), lineLimit: compact ? 3 : nil)
                        .textSelection(.enabled)
                }
                if !learned.isEmpty {
                    Label("Added to your dictionary: \(learned.joined(separator: ", "))", systemImage: "character.book.closed.fill")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Copy") { copy() }
            Button("Edit…") { beginEditing() }
            if transcript.rawText != transcript.text {
                Button("Copy Original Wording") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(transcript.rawText, forType: .string)
                }
            }
            Divider()
            Button("Delete", role: .destructive) { state.history.delete(id: transcript.id) }
        }
    }

    private var metaLine: String {
        var parts = [compact ? relativeTime : transcript.createdAt.clockTime]
        if let app = transcript.appName { parts.append(app) }
        parts.append(transcript.duration.shortDuration)
        parts.append("\(transcript.wordCount) words")
        return parts.joined(separator: "  ·  ")
    }

    private var relativeTime: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: transcript.createdAt, relativeTo: Date())
    }

    private var actions: some View {
        HStack(spacing: 2) {
            if let url = transcript.audioURL {
                rowButton(player.isPlaying ? "stop.fill" : "play.fill", help: player.isPlaying ? "Stop" : "Play recording") {
                    player.toggle(url)
                }
            }
            rowButton(copied ? "checkmark" : "doc.on.doc", help: "Copy") { copy() }
            rowButton("pencil", help: "Edit. Fixes you make teach Nabra the spelling") { beginEditing() }
            rowButton("trash", help: "Delete") { state.history.delete(id: transcript.id) }
        }
    }

    private func rowButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11.5, weight: .medium))
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
    }

    private var editor: some View {
        VStack(alignment: .trailing, spacing: 8) {
            TextEditor(text: $draft)
                .font(.system(size: 13.5))
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(minHeight: 70, maxHeight: 180)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(0.05)))
                .environment(\.layoutDirection, TextScript.isRightToLeft(draft) ? .rightToLeft : .leftToRight)
            HStack(spacing: 8) {
                Text("Fix a name or word and Nabra will remember the spelling.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { editing = false }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.small)
        }
    }

    private func beginEditing() {
        draft = transcript.text
        learned = []
        editing = true
    }

    private func save() {
        let edited = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        editing = false
        guard !edited.isEmpty, edited != transcript.text else { return }
        learned = state.learner.learn(original: transcript.text, edited: edited)
        state.history.updateText(id: transcript.id, text: edited)
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(transcript.text, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
    }
}

/// Plays a saved recording.
@Observable
final class ClipPlayer: NSObject, AVAudioPlayerDelegate {
    private(set) var isPlaying = false
    @ObservationIgnored private var player: AVAudioPlayer?

    func toggle(_ url: URL) {
        if isPlaying {
            player?.stop()
            isPlaying = false
            return
        }
        guard let player = try? AVAudioPlayer(contentsOf: url) else { return }
        player.delegate = self
        self.player = player
        isPlaying = player.play()
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        isPlaying = false
    }
}
