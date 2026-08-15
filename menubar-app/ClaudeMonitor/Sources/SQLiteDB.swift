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

/// Every rung of the read-only open ladder in `Connection.init` failed. Carries
/// the likely cause and a remedy rather than surfacing a bare
/// `SQLite error 14: unable to open database file`, which tells a user nothing
/// about what to do next (issue #105).
struct SQLiteUnreadableError: Error, LocalizedError, CustomStringConvertible {
    let path: String
    /// The read-only probe failure that triggered the escalation.
    let underlying: SQLiteError

    var description: String {
        "Cannot read the database at \(path) (\(underlying)). "
            + "It is most likely in WAL mode with its -shm shared-index file missing, "
            + "while the database file or its directory is not writable — so SQLite "
            + "cannot recreate the -shm it needs. Make the file and its containing "
            + "directory writable, or copy the database (together with any -wal file "
            + "beside it) into a writable directory and retry there."
    }
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

    /// Opens the database at `path`.
    ///
    /// `readonly` is a **lock-avoidance and safety hint, not a hard guarantee**
    /// that this process will never write the file. Reading a WAL-mode database
    /// requires its `-shm` shared index, and a `SQLITE_OPEN_READONLY` connection
    /// cannot create one — so a perfectly healthy database whose `-shm` is
    /// absent (the app is not running and checkpointed on close, or the file was
    /// copied without its sidecars) fails with `SQLITE_CANTOPEN`. That refusal
    /// lands on the *first statement*, not on the open, so it is detected with a
    /// probe (issue #105).
    ///
    /// The ladder, in order:
    /// 1. `SQLITE_OPEN_READONLY`, then probe with `PRAGMA schema_version`. The
    ///    common case (app running, `-shm` present) stops here — lock-free and
    ///    residue-free.
    /// 2. On `SQLITE_CANTOPEN`, reopen `SQLITE_OPEN_READWRITE` — **without**
    ///    `SQLITE_OPEN_CREATE`, so a typo'd path errors instead of silently
    ///    conjuring an empty database. This creates the `-shm`, recovers any hot
    ///    `-wal`, and reads *current* data.
    /// 3. Only if that fails too (genuinely read-only file/directory/media),
    ///    `file:…?immutable=1` — and only when no non-empty `-wal` sits beside
    ///    the database. `immutable=1` ignores the WAL *silently*, so with WAL
    ///    content present it would return stale rows with no error; for a
    ///    credential-bearing export that is the worst available failure mode.
    ///    A non-empty `-wal` therefore fails loudly instead.
    ///
    /// Nothing on any rung changes `journal_mode` or modifies a row. Rung 2 does
    /// leave a `-shm`/`-wal` pair behind, exactly as the running app does.
    init(_ path: String, readonly: Bool = false) throws {
        guard readonly else {
            try open(path, flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX)
            return
        }

        // Rung 1: plain read-only. An open failure here is a missing file or a
        // permissions problem — report it as before rather than escalating.
        try open(path, flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX)
        guard let probeFailure = Connection.probe(handle) else { return }
        // Any other probe failure (corruption, not-a-database) is left to
        // surface at the caller's own statement, exactly as it did before.
        guard probeFailure.code == SQLITE_CANTOPEN else { return }
        closeHandle()

        // Rung 2: read-write, no CREATE.
        if (try? open(path, flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX)) != nil,
           Connection.probe(handle) == nil {
            return
        }
        closeHandle()

        // Rung 3: immutable, gated on the absence of WAL content.
        if !Connection.hasWALContent(besides: path) {
            let uri = "file:\(Connection.percentEncodedURIPath(path))?immutable=1"
            let immutableFlags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_FULLMUTEX
            if (try? open(uri, flags: immutableFlags)) != nil, Connection.probe(handle) == nil {
                return
            }
            closeHandle()
        }

        throw SQLiteUnreadableError(path: path, underlying: probeFailure)
    }

    deinit {
        sqlite3_close_v2(handle)
    }

    /// `sqlite3_open_v2` with the given flags, leaving `handle` nil on failure.
    private func open(_ filename: String, flags: Int32) throws {
        let rc = sqlite3_open_v2(filename, &handle, flags, nil)
        guard rc == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unable to open database"
            closeHandle()
            throw SQLiteError(code: rc, message: message)
        }
    }

    private func closeHandle() {
        sqlite3_close_v2(handle)
        handle = nil
    }

    /// Runs the cheapest statement that actually touches the database, so a
    /// missing `-shm` surfaces here instead of at the caller's first query.
    /// Returns nil when the connection is usable.
    ///
    /// `PRAGMA schema_version` is the probe because it is measurably sufficient:
    /// it returns `SQLITE_CANTOPEN` in the broken state. `BEGIN; COMMIT;` does
    /// **not** — it returns `SQLITE_OK` and misses the condition entirely.
    private static func probe(_ handle: OpaquePointer?) -> SQLiteError? {
        var errMsg: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, "PRAGMA schema_version;", nil, nil, &errMsg)
        defer { sqlite3_free(errMsg) }
        guard rc != SQLITE_OK else { return nil }
        let message = errMsg.map { String(cString: $0) }
            ?? handle.map { String(cString: sqlite3_errmsg($0)) }
            ?? "unable to open database"
        return SQLiteError(code: rc, message: message)
    }

    /// True when a non-empty `<path>-wal` sits beside the database, i.e. there
    /// is committed content that lives only in the write-ahead log. A missing
    /// `-shm` does **not** imply an empty `-wal`: a crashed writer, or a `cp` of
    /// the database together with its `-wal`, produces exactly that state, and
    /// `immutable=1` would then silently drop every row in the log.
    private static func hasWALContent(besides path: String) -> Bool {
        let walPath = path + "-wal"
        // No -wal beside the database at all: nothing for `immutable=1` to miss.
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: walPath) else {
            return false
        }
        // A -wal that exists but whose size can't be read counts as content:
        // erring toward an actionable error beats erring toward a stale read.
        guard let size = (attributes[.size] as? NSNumber)?.int64Value else { return true }
        return size > 0
    }

    /// Percent-encodes a filesystem path for a SQLite `file:` URI. `?`, `#`, `%`
    /// and spaces are all legal in a macOS path and all significant in a URI.
    private static func percentEncodedURIPath(_ path: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "/-._~")
        return path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path
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
