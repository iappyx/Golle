import Foundation
import SQLite3

struct SQLiteError: Error, CustomStringConvertible {
    let description: String
}

/// A thin wrapper around the system SQLite. Golle works on in-memory databases: a document is read
/// into memory whole (`deserialize`) and written back whole (`serialize`), so there is never a
/// half-written database on disk, and an encrypted document never touches the disk unencrypted.
final class SQLite {
    private var db: OpaquePointer?

    /// An empty in-memory database.
    init() throws {
        guard sqlite3_open_v2(":memory:", &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            throw SQLiteError(description: "Could not create a database in memory.")
        }
        try execute("PRAGMA foreign_keys = ON")
    }

    /// An in-memory database holding a copy of the given database file bytes.
    convenience init(bytes: Data) throws {
        try self.init()
        let size = bytes.count
        guard size > 0, let buffer = sqlite3_malloc64(sqlite3_uint64(size)) else {
            throw SQLiteError(description: "The database file is empty.")
        }
        bytes.copyBytes(to: buffer.assumingMemoryBound(to: UInt8.self), count: size)
        let flags = UInt32(SQLITE_DESERIALIZE_FREEONCLOSE | SQLITE_DESERIALIZE_RESIZEABLE)
        let rc = sqlite3_deserialize(db, "main", buffer.assumingMemoryBound(to: UInt8.self), sqlite3_int64(size), sqlite3_int64(size), flags)
        guard rc == SQLITE_OK else { throw SQLiteError(description: "Not a database file (\(rc)).") }
        // A real database answers this; random bytes fail here rather than later.
        let check = try scalarText("PRAGMA quick_check")
        guard check == "ok" else { throw SQLiteError(description: "The database is damaged: \(check ?? "unknown error").") }
    }

    deinit { sqlite3_close_v2(db) }

    /// The whole database as file bytes.
    func serialize() throws -> Data {
        var size: sqlite3_int64 = 0
        guard let pointer = sqlite3_serialize(db, "main", &size, 0) else {
            throw SQLiteError(description: "Could not write out the database.")
        }
        defer { sqlite3_free(pointer) }
        return Data(bytes: pointer, count: Int(size))
    }

    func execute(_ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &message) != SQLITE_OK {
            let text = message.map { String(cString: $0) } ?? lastError
            sqlite3_free(message)
            throw SQLiteError(description: text)
        }
    }

    func prepare(_ sql: String) throws -> Statement {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw SQLiteError(description: "\(lastError) in: \(sql)")
        }
        return Statement(statement, owner: self)
    }

    func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN")
        do {
            try body()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func scalarText(_ sql: String) throws -> String? {
        let statement = try prepare(sql)
        return try statement.step() ? statement.text(0) : nil
    }

    var lastError: String { db.map { String(cString: sqlite3_errmsg($0)) } ?? "no database" }

    final class Statement {
        private let pointer: OpaquePointer
        private let owner: SQLite
        private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

        fileprivate init(_ pointer: OpaquePointer, owner: SQLite) {
            self.pointer = pointer
            self.owner = owner
        }

        deinit { sqlite3_finalize(pointer) }

        /// Binds values to `?` placeholders in order, runs the statement to completion and resets it.
        func run(_ values: [SQLValue]) throws {
            try bind(values)
            defer { sqlite3_reset(pointer) }
            let rc = sqlite3_step(pointer)
            guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw SQLiteError(description: owner.lastError) }
        }

        func bind(_ values: [SQLValue]) throws {
            sqlite3_reset(pointer)
            sqlite3_clear_bindings(pointer)
            for (offset, value) in values.enumerated() {
                let index = Int32(offset + 1)
                let rc: Int32
                switch value {
                case .null: rc = sqlite3_bind_null(pointer, index)
                case .integer(let i): rc = sqlite3_bind_int64(pointer, index, i)
                case .real(let d): rc = sqlite3_bind_double(pointer, index, d)
                case .text(let s): rc = sqlite3_bind_text(pointer, index, s, -1, Self.transient)
                }
                guard rc == SQLITE_OK else { throw SQLiteError(description: owner.lastError) }
            }
        }

        /// Advances to the next row; false when there are no more.
        func step() throws -> Bool {
            switch sqlite3_step(pointer) {
            case SQLITE_ROW: return true
            case SQLITE_DONE: return false
            default: throw SQLiteError(description: owner.lastError)
            }
        }

        func text(_ column: Int32) -> String? {
            guard let c = sqlite3_column_text(pointer, column) else { return nil }
            return String(cString: c)
        }

        func value(_ column: Int32) -> SQLValue {
            switch sqlite3_column_type(pointer, column) {
            case SQLITE_INTEGER: .integer(sqlite3_column_int64(pointer, column))
            case SQLITE_FLOAT: .real(sqlite3_column_double(pointer, column))
            case SQLITE_TEXT: .text(text(column) ?? "")
            default: .null
            }
        }

        func double(_ column: Int32) -> Double { sqlite3_column_double(pointer, column) }
    }
}

enum SQLValue: Equatable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
}
