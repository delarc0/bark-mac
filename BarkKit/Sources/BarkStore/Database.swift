import Foundation
import SQLite3

public struct StoreError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// A value bound to a statement parameter.
protocol SQLBindable {}
extension Int: SQLBindable {}
extension Int64: SQLBindable {}
extension Double: SQLBindable {}
extension String: SQLBindable {}
extension Bool: SQLBindable {}

/// One row while a query steps over it.
struct SQLRow {
    let statement: OpaquePointer

    func int(_ column: Int32) -> Int64 { sqlite3_column_int64(statement, column) }
    func double(_ column: Int32) -> Double { sqlite3_column_double(statement, column) }
    func optionalDouble(_ column: Int32) -> Double? {
        sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : double(column)
    }
    func optionalInt(_ column: Int32) -> Int64? {
        sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : int(column)
    }
    func text(_ column: Int32) -> String { optionalText(column) ?? "" }
    func optionalText(_ column: Int32) -> String? {
        sqlite3_column_text(statement, column).map { String(cString: $0) }
    }
}

/// One SQLite connection in WAL mode, used under a lock, with the schema migrated by
/// `PRAGMA user_version`: migration i (0-based) takes the file from version i to i + 1.
final class Database: @unchecked Sendable {
    private let db: OpaquePointer
    private let lock = NSRecursiveLock()
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(path: String, migrations: [String]) throws {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
              let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "out of memory"
            sqlite3_close(handle)
            throw StoreError("cannot open \(path): \(message)")
        }
        db = handle
        sqlite3_busy_timeout(db, 5_000)
        // FULL: a committed segment survives power loss, not only a crash. Commits are seconds apart.
        try execute("PRAGMA journal_mode = WAL; PRAGMA synchronous = FULL; PRAGMA foreign_keys = ON;")
        try migrate(migrations)
    }

    deinit { sqlite3_close_v2(db) }

    var userVersion: Int {
        (try? query("PRAGMA user_version") { Int($0.int(0)) }.first) ?? 0
    }

    private func migrate(_ migrations: [String]) throws {
        let version = userVersion
        guard version <= migrations.count else {
            throw StoreError("the meeting store is schema v\(version), newer than this Bark (v\(migrations.count))")
        }
        for (index, sql) in migrations.enumerated().dropFirst(version) {
            try transaction {
                try execute(sql)
                try execute("PRAGMA user_version = \(index + 1)")
            }
        }
    }

    func execute(_ sql: String) throws {
        try locked {
            var error: UnsafeMutablePointer<CChar>?
            guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
                let message = error.map { String(cString: $0) } ?? "unknown error"
                sqlite3_free(error)
                throw StoreError(message)
            }
        }
    }

    /// Runs a write; returns the number of rows it changed.
    @discardableResult
    func run(_ sql: String, _ arguments: [SQLBindable?] = []) throws -> Int {
        try locked {
            _ = try step(sql, arguments) { _ in }
            return Int(sqlite3_changes(db))
        }
    }

    func query<T>(_ sql: String, _ arguments: [SQLBindable?] = [], _ map: (SQLRow) throws -> T) throws -> [T] {
        try locked { try step(sql, arguments, map) }
    }

    /// Runs an INSERT; returns the new row's id.
    func insert(_ sql: String, _ arguments: [SQLBindable?] = []) throws -> Int64 {
        try locked {
            _ = try step(sql, arguments) { _ in }
            return sqlite3_last_insert_rowid(db)
        }
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try locked {
            try execute("BEGIN IMMEDIATE")
            do {
                let result = try body()
                try execute("COMMIT")
                return result
            } catch {
                try? execute("ROLLBACK")
                throw error
            }
        }
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private func step<T>(_ sql: String, _ arguments: [SQLBindable?], _ map: (SQLRow) throws -> T) throws -> [T] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw StoreError("\(String(cString: sqlite3_errmsg(db))) in \(sql)")
        }
        defer { sqlite3_finalize(statement) }
        for (index, argument) in arguments.enumerated() {
            let position = Int32(index + 1)
            switch argument {
            case nil: sqlite3_bind_null(statement, position)
            case let value as Int: sqlite3_bind_int64(statement, position, Int64(value))
            case let value as Int64: sqlite3_bind_int64(statement, position, value)
            case let value as Double: sqlite3_bind_double(statement, position, value)
            case let value as Bool: sqlite3_bind_int64(statement, position, value ? 1 : 0)
            case let value as String: sqlite3_bind_text(statement, position, value, -1, Self.transient)
            default: throw StoreError("cannot bind \(String(describing: argument))")
            }
        }
        var rows: [T] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: rows.append(try map(SQLRow(statement: statement)))
            case SQLITE_DONE: return rows
            default: throw StoreError("\(String(cString: sqlite3_errmsg(db))) in \(sql)")
            }
        }
    }
}
