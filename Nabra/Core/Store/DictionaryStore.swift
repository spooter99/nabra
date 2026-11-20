import Foundation
import Observation

/// An entry in the personal dictionary.
struct DictionaryEntry: Identifiable, Equatable {
    enum Source: String {
        case manual
        case learned
    }

    var id: Int64
    /// The spelling you want to see.
    var phrase: String
    /// What the recogniser tends to write instead. Nil for plain vocabulary.
    var heard: String?
    var source: Source
    var createdAt: Date
    var useCount: Int

    var isReplacement: Bool { heard != nil }
}

/// Words Nabra should know (names, jargon) and fixes it should apply.
///
/// - Vocabulary entries bias the recogniser toward the right spelling.
/// - Replacement entries rewrite a known mis-hearing to the right text.
@Observable
final class DictionaryStore {
    private(set) var entries: [DictionaryEntry] = []
    @ObservationIgnored private let database: Database

    init(database: Database) throws {
        self.database = database
        try database.execute("""
            CREATE TABLE IF NOT EXISTS dictionary (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                phrase TEXT NOT NULL,
                heard TEXT,
                source TEXT NOT NULL,
                created_at REAL NOT NULL,
                use_count INTEGER NOT NULL DEFAULT 0
            )
            """)
        reload()
    }

    var vocabulary: [DictionaryEntry] { entries.filter { !$0.isReplacement } }
    var replacements: [DictionaryEntry] { entries.filter { $0.isReplacement } }

    /// Every distinct correct spelling, most recently added first.
    var phrases: [String] {
        var seen = Set<String>()
        return entries.compactMap { seen.insert(TextScript.fold($0.phrase)).inserted ? $0.phrase : nil }
    }

    /// Adds a word or name to recognise. Returns the new entry's id, or nil if it already exists.
    @discardableResult
    func addTerm(_ phrase: String, source: DictionaryEntry.Source = .manual) -> Int64? {
        let trimmed = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let folded = TextScript.fold(trimmed)
        if vocabulary.contains(where: { TextScript.fold($0.phrase) == folded }) { return nil }
        return insert(phrase: trimmed, heard: nil, source: source)
    }

    /// Adds a fix: whenever the recogniser writes `heard`, use `phrase`. Returns the new entry's id.
    @discardableResult
    func addReplacement(heard: String, phrase: String, source: DictionaryEntry.Source = .manual) -> Int64? {
        let from = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        let to = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !from.isEmpty, !to.isEmpty, from != to else { return nil }
        let folded = TextScript.fold(from)
        if let existing = replacements.first(where: { TextScript.fold($0.heard ?? "") == folded }) {
            if existing.phrase == to { return nil }
            delete(id: existing.id)
        }
        return insert(phrase: to, heard: from, source: source)
    }

    func delete(id: Int64) {
        _ = try? database.execute("DELETE FROM dictionary WHERE id = ?", [.integer(id)])
        reload()
    }

    func update(id: Int64, phrase: String, heard: String?) {
        let to = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !to.isEmpty else { return }
        let from = heard?.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try? database.execute("UPDATE dictionary SET phrase = ?, heard = ? WHERE id = ?",
                                  [.text(to), (from?.isEmpty == false) ? .text(from!) : .null, .integer(id)])
        reload()
    }

    func recordUse(ids: [Int64]) {
        guard !ids.isEmpty else { return }
        for id in ids {
            _ = try? database.execute("UPDATE dictionary SET use_count = use_count + 1 WHERE id = ?", [.integer(id)])
        }
    }

    private func insert(phrase: String, heard: String?, source: DictionaryEntry.Source) -> Int64? {
        let id = try? database.execute(
            "INSERT INTO dictionary (phrase, heard, source, created_at) VALUES (?, ?, ?, ?)",
            [.text(phrase), heard.map { .text($0) } ?? .null, .text(source.rawValue), .real(Date().timeIntervalSince1970)])
        reload()
        return id
    }

    private func reload() {
        let rows = (try? database.query("SELECT * FROM dictionary ORDER BY created_at DESC, id DESC")) ?? []
        let loaded = rows.map { row in
            DictionaryEntry(id: Int64(row["id"]?.int ?? 0),
                            phrase: row["phrase"]?.string ?? "",
                            heard: row["heard"]?.string,
                            source: DictionaryEntry.Source(rawValue: row["source"]?.string ?? "") ?? .manual,
                            createdAt: Date(timeIntervalSince1970: row["created_at"]?.double ?? 0),
                            useCount: row["use_count"]?.int ?? 0)
        }
        if Thread.isMainThread {
            entries = loaded
        } else {
            DispatchQueue.main.sync { self.entries = loaded }
        }
    }
}
