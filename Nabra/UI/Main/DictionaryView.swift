import SwiftUI

struct DictionaryView: View {
    @Environment(AppState.self) private var state
    @State private var newTerm = ""
    @State private var newHeard = ""
    @State private var newFix = ""
    @FocusState private var termFocused: Bool

    var body: some View {
        let vocabulary = state.dictionary.vocabulary
        let replacements = state.dictionary.replacements

        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Dictionary")
                        .font(.system(size: 28, weight: .bold))
                    Text("Names and terms Nabra should get right. It also learns on its own: fix a word right after dictating, or edit a dictation in History, and the spelling is added here.")
                        .font(.system(size: 13.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // Vocabulary
                VStack(alignment: .leading, spacing: 10) {
                    sectionTitle("Words and names", count: vocabulary.count)
                    Card(padding: 12) {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 8) {
                                TextField("Add a name or term, e.g. Darwish", text: $newTerm)
                                    .textFieldStyle(.plain)
                                    .font(.system(size: 13.5))
                                    .focused($termFocused)
                                    .onSubmit(addTerm)
                                Button("Add", action: addTerm)
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.small)
                                    .disabled(newTerm.trimmingCharacters(in: .whitespaces).isEmpty)
                            }
                            .padding(.horizontal, 6)
                            if !vocabulary.isEmpty {
                                Divider()
                                FlowLayout(spacing: 7) {
                                    ForEach(vocabulary) { entry in
                                        TermChip(entry: entry) { state.dictionary.delete(id: entry.id) }
                                    }
                                }
                                .padding(.horizontal, 4)
                                .padding(.bottom, 2)
                            }
                        }
                    }
                    if vocabulary.isEmpty {
                        hint("Add how you want a name spelled. When Nabra hears something close to it, it uses your spelling.")
                    }
                }

                // Replacements
                VStack(alignment: .leading, spacing: 10) {
                    sectionTitle("Fixes", count: replacements.count)
                    Card(padding: 12) {
                        VStack(alignment: .leading, spacing: 0) {
                            HStack(spacing: 8) {
                                TextField("When Nabra writes…", text: $newHeard)
                                    .textFieldStyle(.plain)
                                Image(systemName: "arrow.right")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.tertiary)
                                TextField("Use this instead", text: $newFix)
                                    .textFieldStyle(.plain)
                                    .onSubmit(addFix)
                                Button("Add", action: addFix)
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.small)
                                    .disabled(newHeard.trimmingCharacters(in: .whitespaces).isEmpty
                                        || newFix.trimmingCharacters(in: .whitespaces).isEmpty)
                            }
                            .font(.system(size: 13.5))
                            .padding(.horizontal, 6)
                            .padding(.bottom, replacements.isEmpty ? 0 : 10)
                            ForEach(replacements) { entry in
                                Divider()
                                FixRow(entry: entry) { state.dictionary.delete(id: entry.id) }
                            }
                        }
                    }
                    if replacements.isEmpty {
                        hint("For anything that keeps coming out wrong, e.g. “cloud code” → “Claude Code”.")
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

    private func sectionTitle(_ title: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.system(size: 15, weight: .semibold))
            if count > 0 {
                Text("\(count)").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .padding(.leading, 4)
    }

    private func addTerm() {
        guard state.dictionary.addTerm(newTerm) != nil || !newTerm.isEmpty else { return }
        newTerm = ""
        termFocused = true
    }

    private func addFix() {
        guard !newHeard.trimmingCharacters(in: .whitespaces).isEmpty,
              !newFix.trimmingCharacters(in: .whitespaces).isEmpty
        else { return }
        state.dictionary.addReplacement(heard: newHeard, phrase: newFix)
        newHeard = ""
        newFix = ""
    }
}

private struct TermChip: View {
    var entry: DictionaryEntry
    var onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 5) {
            if entry.source == .learned {
                Image(systemName: "sparkle")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.accentColor)
                    .help("Learned from a correction you made")
            }
            Text(entry.phrase)
                .font(.system(size: 12.5, weight: .medium))
            Button(action: onDelete) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .opacity(hovering ? 1 : 0.35)
            .help("Remove")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
        .onHover { hovering = $0 }
    }
}

private struct FixRow: View {
    var entry: DictionaryEntry
    var onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Text(entry.heard ?? "")
                .foregroundStyle(.secondary)
                .strikethrough(color: .secondary.opacity(0.5))
            Image(systemName: "arrow.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
            Text(entry.phrase)
                .fontWeight(.medium)
            if entry.source == .learned { Badge(text: "Learned", tint: .accentColor) }
            Spacer()
            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .opacity(hovering ? 1 : 0)
            .help("Remove")
        }
        .font(.system(size: 13))
        .padding(.horizontal, 6)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

/// Lays children out in rows, wrapping when a row is full.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(subviews, width: proposal.width ?? .infinity).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(subviews, width: bounds.width)
        for (index, origin) in result.origins.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> (size: CGSize, origins: [CGPoint]) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return (CGSize(width: widest, height: y + rowHeight), origins)
    }
}
