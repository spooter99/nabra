import Foundation
import SQLite3

/// Minimal SQLite wrapper. All access is serialised on one queue.
final class Database {
    enum Value: Equatable {
        case null
        case integer(Int64)
        case real(Double)
        case text(String)

        var int: Int { if case .integer(let value) = self { return Int(value) }; if case .real(let value) = self { return Int(value) }; return 0 }
        var double: Double { if case .real(let value) = self { return value }; if case .integer(let value) = self { return Double(value) }; return 0 }
        var string: String? { if case .text(let value) = self { return value }; return nil }
    }

    typealias Row = [String: Value]

    struct DatabaseError: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    private var handle: OpaquePointer?
    private let queue = DispatchQueue(label: "app.nabra.database")
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL) throws {
        var connection: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &connection, flags, nil) == SQLITE_OK, let connection else {
            let message = connection.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(connection)
            throw DatabaseError(message: "Could not open database: \(message)")
        }
        handle = connection
        sqlite3_busy_timeout(connection, 2000)
        try execute("PRAGMA journal_mode = WAL")
        try execute("PRAGMA synchronous = NORMAL")
    }

    deinit {
        sqlite3_close(handle)
    }

    @discardableResult
    func execute(_ sql: String, _ parameters: [Value] = []) throws -> Int64 {
        try queue.sync {
            let statement = try prepare(sql, parameters)
            defer { sqlite3_finalize(statement) }
            var status = sqlite3_step(statement)
            while status == SQLITE_ROW { status = sqlite3_step(statement) }
            guard status == SQLITE_DONE else { throw lastError() }
            return sqlite3_last_insert_rowid(handle)
        }
    }

    func query(_ sql: String, _ parameters: [Value] = []) throws -> [Row] {
        try queue.sync {
            let statement = try prepare(sql, parameters)
            defer { sqlite3_finalize(statement) }
            var rows: [Row] = []
            let columnCount = sqlite3_column_count(statement)
            while true {
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE { break }
                guard status == SQLITE_ROW else { throw lastError() }
                var row = Row()
                for column in 0..<columnCount {
                    let name = String(cString: sqlite3_column_name(statement, column))
                    switch sqlite3_column_type(statement, column) {
                    case SQLITE_INTEGER: row[name] = .integer(sqlite3_column_int64(statement, column))
                    case SQLITE_FLOAT: row[name] = .real(sqlite3_column_double(statement, column))
                    case SQLITE_TEXT: row[name] = .text(String(cString: sqlite3_column_text(statement, column)))
                    default: row[name] = .null
                    }
                }
                rows.append(row)
            }
            return rows
        }
    }

    var userVersion: Int {
        get { (try? query("PRAGMA user_version").first?["user_version"]?.int) ?? 0 }
        set { _ = try? execute("PRAGMA user_version = \(newValue)") }
    }

    private func prepare(_ sql: String, _ parameters: [Value]) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw lastError()
        }
        for (index, parameter) in parameters.enumerated() {
            let position = Int32(index + 1)
            switch parameter {
            case .null: sqlite3_bind_null(statement, position)
            case .integer(let value): sqlite3_bind_int64(statement, position, value)
            case .real(let value): sqlite3_bind_double(statement, position, value)
            case .text(let value): sqlite3_bind_text(statement, position, value, -1, Database.transient)
            }
        }
        return statement
    }

    private func lastError() -> DatabaseError {
        DatabaseError(message: handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown database error")
    }
}
