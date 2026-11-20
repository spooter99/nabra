import Foundation
import Observation

/// One saved dictation.
struct Transcript: Identifiable, Equatable {
    var id: Int64
    var createdAt: Date
    /// Text that was inserted (after cleanup, and after any later edit in the app).
    var text: String
    /// What the recogniser produced before cleanup.
    var rawText: String
    var language: String
    var duration: TimeInterval
    var wordCount: Int
    var appName: String?
    var appBundleID: String?
    var audioFile: String?
    var processingMs: Double
    var polished: Bool
    var edited: Bool

    var audioURL: URL? {
        guard let audioFile else { return nil }
        let url = AppPaths.audioDirectory.appendingPathComponent(audioFile)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

struct UsageStats: Equatable {
    var totalCount = 0
    var totalWords = 0
    var totalSeconds: Double = 0
    var todayWords = 0
    var todayCount = 0
    var weekWords = 0
    var streakDays = 0
    /// Words per day for the last 14 days, oldest first.
    var dailyWords: [(day: Date, words: Int)] = []

    static func == (lhs: UsageStats, rhs: UsageStats) -> Bool {
        lhs.totalCount == rhs.totalCount && lhs.totalWords == rhs.totalWords && lhs.todayWords == rhs.todayWords
            && lhs.streakDays == rhs.streakDays && lhs.totalSeconds == rhs.totalSeconds
    }

    /// Average speaking speed in words per minute.
    var wordsPerMinute: Int {
        totalSeconds > 5 ? Int((Double(totalWords) / totalSeconds * 60).rounded()) : 0
    }

    /// Minutes saved compared with typing at 45 words per minute.
    var minutesSaved: Int {
        let typing = Double(totalWords) / 45
        return max(0, Int((typing - totalSeconds / 60).rounded()))
    }
}

/// Persists dictations in SQLite. `revision` changes whenever the data does, so views can refresh.
@Observable
final class HistoryStore {
    private(set) var revision = 0
    @ObservationIgnored private let database: Database

    init(database: Database) throws {
        self.database = database
        try database.execute("""
            CREATE TABLE IF NOT EXISTS transcripts (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                created_at REAL NOT NULL,
                text TEXT NOT NULL,
                raw_text TEXT NOT NULL,
                search_text TEXT NOT NULL,
                language TEXT NOT NULL,
                duration REAL NOT NULL,
                word_count INTEGER NOT NULL,
                app_name TEXT,
                app_bundle_id TEXT,
                audio_file TEXT,
                processing_ms REAL NOT NULL DEFAULT 0,
                polished INTEGER NOT NULL DEFAULT 0,
                edited INTEGER NOT NULL DEFAULT 0
            )
            """)
        try database.execute("CREATE INDEX IF NOT EXISTS transcripts_created ON transcripts(created_at DESC)")
    }

    @discardableResult
    func add(text: String, rawText: String, language: String, duration: TimeInterval, appName: String?,
             appBundleID: String?, audioFile: String?, processingMs: Double, polished: Bool) -> Transcript? {
        let now = Date()
        let words = TextScript.wordCount(text)
        do {
            let id = try database.execute("""
                INSERT INTO transcripts (created_at, text, raw_text, search_text, language, duration, word_count,
                                         app_name, app_bundle_id, audio_file, processing_ms, polished)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, [
                    .real(now.timeIntervalSince1970), .text(text), .text(rawText), .text(TextScript.fold(text)),
                    .text(language), .real(duration), .integer(Int64(words)),
                    appName.map { .text($0) } ?? .null, appBundleID.map { .text($0) } ?? .null,
                    audioFile.map { .text($0) } ?? .null, .real(processingMs), .integer(polished ? 1 : 0),
                ])
            bump()
            return Transcript(id: id, createdAt: now, text: text, rawText: rawText, language: language,
                              duration: duration, wordCount: words, appName: appName, appBundleID: appBundleID,
                              audioFile: audioFile, processingMs: processingMs, polished: polished, edited: false)
        } catch {
            Log.error("Could not save transcript: \(error.localizedDescription)")
            return nil
        }
    }

    func transcripts(matching search: String = "", limit: Int = 200, offset: Int = 0) -> [Transcript] {
        let folded = TextScript.fold(search.trimmingCharacters(in: .whitespacesAndNewlines))
        do {
            let rows: [Database.Row]
            if folded.isEmpty {
                rows = try database.query(
                    "SELECT * FROM transcripts ORDER BY created_at DESC LIMIT ? OFFSET ?",
                    [.integer(Int64(limit)), .integer(Int64(offset))])
            } else {
                let escaped = folded.replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
                rows = try database.query("""
                    SELECT * FROM transcripts
                    WHERE search_text LIKE ? ESCAPE '\\' OR app_name LIKE ? ESCAPE '\\'
                    ORDER BY created_at DESC LIMIT ? OFFSET ?
                    """, [.text("%\(escaped)%"), .text("%\(escaped)%"), .integer(Int64(limit)), .integer(Int64(offset))])
            }
            return rows.map(Self.transcript)
        } catch {
            Log.error("History query failed: \(error.localizedDescription)")
            return []
        }
    }

    func latest() -> Transcript? { transcripts(limit: 1).first }

    func transcript(id: Int64) -> Transcript? {
        (try? database.query("SELECT * FROM transcripts WHERE id = ?", [.integer(id)]))?.first.map(Self.transcript)
    }

    func updateText(id: Int64, text: String) {
        _ = try? database.execute(
            "UPDATE transcripts SET text = ?, search_text = ?, word_count = ?, edited = 1 WHERE id = ?",
            [.text(text), .text(TextScript.fold(text)), .integer(Int64(TextScript.wordCount(text))), .integer(id)])
        bump()
    }

    func delete(id: Int64) {
        if let item = transcript(id: id), let url = item.audioURL { try? FileManager.default.removeItem(at: url) }
        _ = try? database.execute("DELETE FROM transcripts WHERE id = ?", [.integer(id)])
        bump()
    }

    func deleteAll() {
        _ = try? database.execute("DELETE FROM transcripts")
        if let files = try? FileManager.default.contentsOfDirectory(at: AppPaths.audioDirectory, includingPropertiesForKeys: nil) {
            files.forEach { try? FileManager.default.removeItem(at: $0) }
        }
        bump()
    }

    /// Deletes audio files older than the retention period. The text stays.
    func pruneAudio(olderThanDays days: Int) {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400).timeIntervalSince1970
        guard let rows = try? database.query(
            "SELECT id, audio_file FROM transcripts WHERE audio_file IS NOT NULL AND created_at < ?", [.real(cutoff)])
        else { return }
        for row in rows {
            if let name = row["audio_file"]?.string {
                try? FileManager.default.removeItem(at: AppPaths.audioDirectory.appendingPathComponent(name))
            }
        }
        _ = try? database.execute("UPDATE transcripts SET audio_file = NULL WHERE audio_file IS NOT NULL AND created_at < ?",
                                  [.real(cutoff)])
    }

    func stats() -> UsageStats {
        var stats = UsageStats()
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: Date())
        guard let totals = try? database.query(
            "SELECT COUNT(*) AS n, COALESCE(SUM(word_count), 0) AS w, COALESCE(SUM(duration), 0) AS d FROM transcripts").first
        else { return stats }
        stats.totalCount = totals["n"]?.int ?? 0
        stats.totalWords = totals["w"]?.int ?? 0
        stats.totalSeconds = totals["d"]?.double ?? 0

        let windowStart = calendar.date(byAdding: .day, value: -60, to: startOfToday) ?? startOfToday
        let rows = (try? database.query("SELECT created_at, word_count FROM transcripts WHERE created_at >= ?",
                                        [.real(windowStart.timeIntervalSince1970)])) ?? []
        var wordsByDay: [Date: Int] = [:]
        for row in rows {
            let day = calendar.startOfDay(for: Date(timeIntervalSince1970: row["created_at"]?.double ?? 0))
            wordsByDay[day, default: 0] += row["word_count"]?.int ?? 0
        }
        stats.todayWords = wordsByDay[startOfToday] ?? 0
        stats.todayCount = rows.filter { ($0["created_at"]?.double ?? 0) >= startOfToday.timeIntervalSince1970 }.count
        for offset in (0..<14).reversed() {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: startOfToday) else { continue }
            stats.dailyWords.append((day, wordsByDay[day] ?? 0))
        }
        stats.weekWords = stats.dailyWords.suffix(7).reduce(0) { $0 + $1.words }

        // Consecutive days with at least one dictation, ending today (or yesterday if nothing yet today).
        var streak = 0
        var cursor = startOfToday
        if wordsByDay[cursor] == nil, let yesterday = calendar.date(byAdding: .day, value: -1, to: cursor) {
            cursor = yesterday
        }
        while wordsByDay[cursor] != nil {
            streak += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        stats.streakDays = streak
        return stats
    }

    private func bump() {
        if Thread.isMainThread {
            revision += 1
        } else {
            DispatchQueue.main.async { self.revision += 1 }
        }
    }

    private static func transcript(_ row: Database.Row) -> Transcript {
        Transcript(id: Int64(row["id"]?.int ?? 0),
                   createdAt: Date(timeIntervalSince1970: row["created_at"]?.double ?? 0),
                   text: row["text"]?.string ?? "",
                   rawText: row["raw_text"]?.string ?? "",
                   language: row["language"]?.string ?? "",
                   duration: row["duration"]?.double ?? 0,
                   wordCount: row["word_count"]?.int ?? 0,
                   appName: row["app_name"]?.string,
                   appBundleID: row["app_bundle_id"]?.string,
                   audioFile: row["audio_file"]?.string,
                   processingMs: row["processing_ms"]?.double ?? 0,
                   polished: (row["polished"]?.int ?? 0) != 0,
                   edited: (row["edited"]?.int ?? 0) != 0)
    }
}
