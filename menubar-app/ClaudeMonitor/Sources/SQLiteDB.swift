import Foundation
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif

/// Minimal wrapper over the system SQLite C API (libsqlite3 ships with macOS),
/// mirroring the subset of the SQLite.swift API this app uses: raw SQL with `?`
/// placeholders, rows as index-subscriptable `[Any?]` arrays, and a busy
/// timeout for concurrent access. Replaces the SQLite.swift package dependency.
///
/// Column values decode as: INTEGER → Int64, REAL → Double, TEXT → String,
/// BLOB → Data, NULL → nil — so call sites read `row[0] as? String` etc.

struct SQLiteError: Error, LocalizedError, CustomStringConvertible {
    let code: Int32
    let message: String

    var description: String { "SQLite error \(code): \(message)" }
    var errorDescription: String? { description }
}

// Tells sqlite3_bind_text/blob to copy the buffer before returning.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class Connection {
    fileprivate var handle: OpaquePointer?

    /// Busy timeout in seconds. Concurrent access waits this long for locks
    /// instead of failing immediately with SQLITE_BUSY.
    var busyTimeout: Double = 0 {
        didSet { sqlite3_busy_timeout(handle, Int32(busyTimeout * 1000)) }
    }

    init(_ path: String, readonly: Bool = false) throws {
        let flags = readonly
            ? SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
            : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(path, &handle, flags, nil)
        guard rc == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unable to open database"
            sqlite3_close_v2(handle)
            handle = nil
            throw SQLiteError(code: rc, message: message)
        }
    }

    deinit {
        sqlite3_close_v2(handle)
    }

    fileprivate func lastError(_ code: Int32) -> SQLiteError {
        SQLiteError(code: code, message: String(cString: sqlite3_errmsg(handle)))
    }

    /// Execute one or more SQL statements with no bindings (DDL, PRAGMA).
    func execute(_ sql: String) throws {
        var errMsg: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &errMsg)
        if rc != SQLITE_OK {
            let message = errMsg.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(errMsg)
            throw SQLiteError(code: rc, message: message)
        }
    }

    /// Prepare a single statement; bind values with `.bind(...)` and iterate rows.
    func prepare(_ sql: String) throws -> Statement {
        try Statement(self, sql)
    }

    /// Run a single DML statement to completion with the given bindings.
    func run(_ sql: String, _ bindings: Any?...) throws {
        let stmt = try Statement(self, sql)
        stmt.bindValues(bindings)
        try stmt.runToCompletion()
    }

    /// First column of the first result row, or nil if there are no rows.
    func scalar(_ sql: String, _ bindings: Any?...) throws -> Any? {
        let stmt = try Statement(self, sql)
        stmt.bindValues(bindings)
        guard let row = try stmt.stepRow(), !row.isEmpty else { return nil }
        return row[0]
    }
}

final class Statement: Sequence, IteratorProtocol {
    private let connection: Connection
    private var handle: OpaquePointer?

    fileprivate init(_ connection: Connection, _ sql: String) throws {
        self.connection = connection
        let rc = sqlite3_prepare_v2(connection.handle, sql, -1, &handle, nil)
        guard rc == SQLITE_OK else { throw connection.lastError(rc) }
    }

    deinit {
        sqlite3_finalize(handle)
    }

    /// Bind values to `?` placeholders, resetting the statement first so it
    /// can be re-bound and re-iterated. Returns self for `for row in stmt.bind(...)`.
    @discardableResult
    func bind(_ values: Any?...) -> Statement {
        bindValues(values)
        return self
    }

    fileprivate func bindValues(_ values: [Any?]) {
        sqlite3_reset(handle)
        sqlite3_clear_bindings(handle)
        for (i, value) in values.enumerated() {
            let idx = Int32(i + 1)
            let rc: Int32
            switch value {
            case nil:
                rc = sqlite3_bind_null(handle, idx)
            case let v as String:
                rc = sqlite3_bind_text(handle, idx, v, -1, SQLITE_TRANSIENT)
            case let v as Double:
                rc = sqlite3_bind_double(handle, idx, v)
            case let v as Int64:
                rc = sqlite3_bind_int64(handle, idx, v)
            case let v as Int:
                rc = sqlite3_bind_int64(handle, idx, Int64(v))
            case let v as Bool:
                rc = sqlite3_bind_int64(handle, idx, v ? 1 : 0)
            case let v as Data:
                rc = v.withUnsafeBytes {
                    sqlite3_bind_blob(handle, idx, $0.baseAddress, Int32(v.count), SQLITE_TRANSIENT)
                }
            default:
                // Wrong type/arity is a programming error, not a runtime condition.
                preconditionFailure("SQLiteDB: unsupported binding type \(type(of: value!)) at index \(idx)")
            }
            precondition(rc == SQLITE_OK, "SQLiteDB: bind failed at index \(idx) (code \(rc))")
        }
    }

    func makeIterator() -> Statement { self }

    /// Steps the statement. A step error mid-iteration ends the sequence and
    /// logs, since `for row in stmt` can't throw.
    func next() -> [Any?]? {
        let rc = sqlite3_step(handle)
        switch rc {
        case SQLITE_ROW:
            return currentRow()
        case SQLITE_DONE:
            return nil
        default:
            FileLogger.shared.error("SQLiteDB: step failed: \(connection.lastError(rc))", category: "DB")
            return nil
        }
    }

    fileprivate func runToCompletion() throws {
        while true {
            switch sqlite3_step(handle) {
            case SQLITE_DONE: return
            case SQLITE_ROW: continue
            case let rc: throw connection.lastError(rc)
            }
        }
    }

    fileprivate func stepRow() throws -> [Any?]? {
        switch sqlite3_step(handle) {
        case SQLITE_ROW: return currentRow()
        case SQLITE_DONE: return nil
        case let rc: throw connection.lastError(rc)
        }
    }

    private func currentRow() -> [Any?] {
        let count = sqlite3_column_count(handle)
        var row: [Any?] = []
        row.reserveCapacity(Int(count))
        for i in 0..<count {
            switch sqlite3_column_type(handle, i) {
            case SQLITE_INTEGER:
                row.append(sqlite3_column_int64(handle, i))
            case SQLITE_FLOAT:
                row.append(sqlite3_column_double(handle, i))
            case SQLITE_TEXT:
                if let text = sqlite3_column_text(handle, i) {
                    row.append(String(cString: text))
                } else {
                    row.append(nil)
                }
            case SQLITE_BLOB:
                if let bytes = sqlite3_column_blob(handle, i) {
                    row.append(Data(bytes: bytes, count: Int(sqlite3_column_bytes(handle, i))))
                } else {
                    row.append(Data())
                }
            default:
                row.append(nil)
            }
        }
        return row
    }
}
