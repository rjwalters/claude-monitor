import Foundation

/// Ingests Claude Code transcript token counters into `token_sessions` /
/// `token_usage` (#197).
///
/// This is a port of the pre-v2.0 native host's `syncTokenUsage` /
/// `processJsonlFile` (deleted wholesale in `b9db622`), which is why the two
/// tables it writes keep their legacy column shapes byte-for-byte: an existing
/// host still holds ~85k historical rows and those must be preserved, not
/// reshaped. Everything else here is new, because the old importer's
/// assumptions no longer hold at fleet scale:
///
/// * **The tree is nested.** The old importer read one level
///   (`projects/<project>/*.jsonl`). Claude Code now also writes
///   `projects/<project>/<session>/subagents/agent-<hash>.jsonl`, so the walk
///   is recursive.
/// * **`agent-*.jsonl` is *not* excluded.** The old importer skipped it
///   (`claude_monitor_host.cjs:385`); the fleet's work is substantially
///   subagent-driven (894 such files on the host measured for #197), so
///   skipping them drops real spend. Sidechain records count too.
/// * **The scan is incremental.** A full re-read every poll is not viable
///   against a tree with ~10^5 transcripts. A file is opened only when its
///   mtime is newer than the stamp recorded for it.
/// * **`inferred_account_id` stays NULL.** The old "whichever account was
///   polled most recently before the session started" inference is close to
///   uniform noise with ~20 staggered accounts, and transcripts carry no
///   account identity at all. The session→account mapping is tracked
///   separately (rjwalters/loom#8059); this importer records the key that
///   mapping will join on and leaves attribution to a future consumer.
///
/// ## Privacy
///
/// Transcript text is user data and file contents. Nothing here ever reads it
/// into a persisted or logged value: `TranscriptRecord` decodes **only**
/// counters, model name, uuid, timestamp and session id — `message.content`
/// has no representation in the type at all, so there is no path by which a
/// message body could reach the database or `debug.log`. Log lines carry
/// counts; paths are collapsed through `redactPath` because a transcript path
/// names a user and a project.
///
/// ## Isolation
///
/// A plain `enum` namespace of pure static functions over a database path — no
/// shared mutable state, no actor isolation, safe to call from a detached Task
/// (which is exactly how `OAuthPoller` runs it, to keep a multi-second scan off
/// the main actor).
enum TranscriptImporter {

    // MARK: - Configuration

    /// Files opened per run by default. The scan is cheap (a stat per file);
    /// *reading* is not, and a cold host has a five-figure backlog of
    /// transcripts totalling many GB. A per-run budget keeps the first sync
    /// from stalling a poll cycle for minutes, and because candidates are
    /// processed newest-mtime-first the useful (recent) spend lands on the
    /// first run while the backlog drains over subsequent ones. `0` = no cap.
    static let defaultFileBudget = 2000

    /// How much newer than its stamp a file's mtime must be to count as
    /// changed.
    ///
    /// Not zero, because the stamp is an ISO 8601 string with millisecond
    /// precision while a filesystem mtime carries sub-millisecond precision:
    /// serializing truncates, so an exact `>` comparison would re-read every
    /// file on every run and the scan would not be incremental at all. Two
    /// milliseconds covers the round-trip loss with room to spare. The cost is
    /// that a write landing within 2 ms *after* the read would not be noticed
    /// until the file changes again — which cannot happen in practice, since
    /// reading the file takes longer than that.
    private static let mtimeTolerance: TimeInterval = 0.002

    /// Files per write transaction. One transaction for the whole run would
    /// make a large backfill all-or-nothing (and hold a write lock for its
    /// duration); one per file would fsync tens of thousands of times.
    private static let filesPerTransaction = 64

    /// Root of the transcript tree, honoring the same overrides Claude Code
    /// itself uses, plus a test-only override.
    ///
    /// * `LLM_MONITOR_TRANSCRIPT_ROOT` — points the importer at a fixture
    ///   tree (used by `selftest`; also an escape hatch for an operator whose
    ///   transcripts live somewhere unusual).
    /// * `CLAUDE_CONFIG_DIR` — Claude Code's own config-dir override.
    /// * otherwise `~/.claude/projects`.
    static func defaultTranscriptRoot(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let override = AppPaths.environment("TRANSCRIPT_ROOT", in: environment) {
            return override
        }
        if let configDir = environment["CLAUDE_CONFIG_DIR"], !configDir.isEmpty {
            return (configDir as NSString).appendingPathComponent("projects")
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects").path
    }

    static var defaultDBPath: String {
        AppPaths.databasePath
    }

    // MARK: - Results

    /// What one sync run did. Every field is a count — there is deliberately
    /// no sample row, path, or message in here, because this struct is what
    /// gets logged and printed.
    ///
    /// `filesRead` is the incrementality signal: a second run over an
    /// unchanged tree must report `filesScanned > 0, filesRead == 0`.
    struct ImportStats: Sendable, Equatable {
        /// Transcript files found in the tree (stat'd, not opened).
        var filesScanned = 0
        /// Files actually opened and parsed this run.
        var filesRead = 0
        /// Files skipped because their mtime was no newer than their stamp.
        var filesSkipped = 0
        /// Files deferred to a later run by the per-run budget.
        var filesDeferred = 0
        /// Files whose read/parse failed outright (unreadable, vanished).
        var filesFailed = 0
        /// `token_sessions` rows inserted or updated.
        var sessionsWritten = 0
        /// `token_usage` rows actually inserted (the UNIQUE constraint on
        /// `message_uuid` swallows re-imports, so this is *new* rows only).
        var messagesImported = 0
        /// Assistant records carrying `message.usage` that were seen this run,
        /// whether or not they were new.
        var messagesSeen = 0

        /// One-line, identity-free summary for `debug.log` and the CLI.
        var summary: String {
            "scanned \(filesScanned) file(s), read \(filesRead), skipped \(filesSkipped)"
                + (filesDeferred > 0 ? ", deferred \(filesDeferred)" : "")
                + (filesFailed > 0 ? ", failed \(filesFailed)" : "")
                + ", \(sessionsWritten) session(s), \(messagesImported) new message(s) of \(messagesSeen) seen"
        }
    }

    enum ImportError: Error, LocalizedError, CustomStringConvertible {
        case rootMissing(String)
        case database(String)

        var description: String {
            switch self {
            case .rootMissing(let path):
                return "No Claude Code transcript directory at \(path) — nothing to import."
            case .database(let message):
                return "Transcript import failed: \(message)"
            }
        }
        var errorDescription: String? { description }
    }

    // MARK: - Entry point

    /// Scans `root` and imports every transcript record carrying
    /// `message.usage` that this database has not already seen.
    ///
    /// - Parameters:
    ///   - dbPath: database to write. Opened read-write; the schema is applied
    ///     first, so this works against a database the app has never created.
    ///   - root: transcript tree root (defaults to `~/.claude/projects`).
    ///   - fileBudget: maximum files to *open* this run; `0` for no cap.
    @discardableResult
    static func sync(
        dbPath: String = defaultDBPath,
        root: String? = nil,
        fileBudget: Int = defaultFileBudget
    ) throws -> ImportStats {
        let root = root ?? defaultTranscriptRoot()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw ImportError.rootMissing(redactPath(root))
        }

        let db: Connection
        do {
            try ensureParentDirectory(of: dbPath)
            db = try openDatabase(dbPath)
            try UsageStore.applySchema(db)
        } catch {
            throw ImportError.database("\(error)")
        }

        var stats = ImportStats()

        // 1. Walk the tree. Only mtimes are collected here — no file is opened.
        var candidates = scanTranscripts(root: root)
        stats.filesScanned = candidates.count
        guard !candidates.isEmpty else { return stats }

        // 2. Drop the files whose recorded stamp already covers their mtime.
        let stamps = loadStamps(db)
        candidates = candidates.filter { candidate in
            guard let stamp = stamps[candidate.sessionKey] else { return true }
            // A different project directory under the same session key means
            // the stamp describes a *different* file (session ids are UUIDs,
            // so this is vanishingly rare — but "skip" would silently drop a
            // whole transcript, which is not a failure worth risking).
            guard stamp.projectPath == candidate.projectPath else { return true }
            guard let importedAt = stamp.importedAt else { return true }
            return candidate.modified.timeIntervalSince(importedAt) > mtimeTolerance
        }
        stats.filesSkipped = stats.filesScanned - candidates.count

        // 3. Newest first: recent spend is what a calibration series needs, and
        //    a budgeted run should deliver that before draining the backlog.
        candidates.sort { $0.modified > $1.modified }
        if fileBudget > 0 && candidates.count > fileBudget {
            stats.filesDeferred = candidates.count - fileBudget
            candidates = Array(candidates.prefix(fileBudget))
        }

        // 4. Read and write, in bounded transactions.
        var batch: [ParsedFile] = []
        batch.reserveCapacity(filesPerTransaction)
        for candidate in candidates {
            guard let parsed = parse(candidate) else {
                stats.filesFailed += 1
                continue
            }
            stats.filesRead += 1
            stats.messagesSeen += parsed.messages.count
            // A file with no usage-bearing record (a transcript that is all
            // user turns, or an empty file) gets no session row — matching the
            // legacy importer, which required a first-message timestamp.
            guard !parsed.messages.isEmpty else { continue }
            batch.append(parsed)
            if batch.count >= filesPerTransaction {
                try commit(batch, to: db, stats: &stats)
                batch.removeAll(keepingCapacity: true)
            }
        }
        if !batch.isEmpty {
            try commit(batch, to: db, stats: &stats)
        }

        return stats
    }

    // MARK: - Scanning

    /// One transcript file the scan found, with everything the skip decision
    /// needs and nothing read from inside it.
    struct Candidate {
        let url: URL
        /// Primary key for `token_sessions`: the file's basename without
        /// `.jsonl`, exactly as the legacy importer keyed it. For a top-level
        /// transcript that *is* the Claude session id; for a subagent file it
        /// is `agent-<hash>` (whose parent session is recorded separately, see
        /// `parent_session_id`). Keying per file — rather than merging
        /// subagents into their parent row — is what makes `last_import_ts`
        /// a per-file stamp, which is what makes the scan incremental.
        let sessionKey: String
        /// `~/.claude/projects/<project-dir>` with the home directory
        /// collapsed to `~`, matching the legacy column's contents.
        let projectPath: String
        let modified: Date
    }

    /// Every `*.jsonl` under `root`, recursively, with its mtime. Does not open
    /// a single file.
    static func scanTranscripts(root: String) -> [Candidate] {
        let rootURL = URL(fileURLWithPath: root)
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]
        guard let walker = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in true }   // an unreadable subtree skips, never aborts the walk
        ) else { return [] }

        var found: [Candidate] = []
        for case let url as URL in walker {
            guard url.pathExtension == "jsonl" else { continue }
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate else { continue }
            let name = url.deletingPathExtension().lastPathComponent
            guard !name.isEmpty else { continue }
            found.append(Candidate(
                url: url,
                sessionKey: name,
                projectPath: projectPath(of: url, under: rootURL),
                modified: modified
            ))
        }
        return found
    }

    /// The project directory a transcript belongs to — the first path
    /// component below `root`, irrespective of how deeply the file is nested
    /// (`<project>/<session>/subagents/agent-*.jsonl` resolves to
    /// `<project>`). Returned with the home directory collapsed to `~`, which
    /// is the form the legacy column held.
    private static func projectPath(of url: URL, under root: URL) -> String {
        let rootComponents = root.standardizedFileURL.pathComponents
        let fileComponents = url.standardizedFileURL.pathComponents
        guard fileComponents.count > rootComponents.count,
              Array(fileComponents.prefix(rootComponents.count)) == rootComponents else {
            return redactPath(url.deletingLastPathComponent().path)
        }
        let projectDir = fileComponents[rootComponents.count]
        return redactPath(root.appendingPathComponent(projectDir).path)
    }

    // MARK: - Stamps

    private struct Stamp {
        let importedAt: Date?
        let projectPath: String?
    }

    /// `session_id → (last_import_ts, project_path)` for every known session.
    ///
    /// `last_import_ts` is written as the **observed mtime of the file at the
    /// moment it was read**, not the wall clock of the import. Both are ISO
    /// 8601 strings, so a legacy database's wall-clock stamps keep working
    /// (they are always ≥ the mtime they covered, so those files stay
    /// skipped); storing the mtime instead closes the race where a file
    /// appended *during* the read would otherwise be stamped as fully
    /// imported.
    private static func loadStamps(_ db: Connection) -> [String: Stamp] {
        var stamps: [String: Stamp] = [:]
        guard let stmt = try? db.prepare(
            "SELECT session_id, last_import_ts, project_path FROM token_sessions"
        ) else { return stamps }
        for row in stmt {
            guard let key = row[0] as? String else { continue }
            stamps[key] = Stamp(
                importedAt: UsageRecord.parseISO(row[1] as? String),
                projectPath: row[2] as? String
            )
        }
        return stamps
    }

    // MARK: - Parsing

    /// The *only* shape a transcript line is decoded into. There is no field
    /// here for message content — that is the structural guarantee behind
    /// "never log or persist transcript content".
    private struct TranscriptRecord: Decodable {
        let type: String?
        let uuid: String?
        let timestamp: String?
        let sessionId: String?
        let message: Message?

        struct Message: Decodable {
            let model: String?
            let usage: Usage?
        }

        struct Usage: Decodable {
            let inputTokens: Int?
            let outputTokens: Int?
            let cacheCreationInputTokens: Int?
            let cacheReadInputTokens: Int?

            enum CodingKeys: String, CodingKey {
                case inputTokens = "input_tokens"
                case outputTokens = "output_tokens"
                case cacheCreationInputTokens = "cache_creation_input_tokens"
                case cacheReadInputTokens = "cache_read_input_tokens"
            }
        }
    }

    /// One usage-bearing assistant record, reduced to the columns
    /// `token_usage` holds.
    struct MessageRow {
        let uuid: String
        let timestamp: String
        let model: String
        let inputTokens: Int
        let outputTokens: Int
        let cacheCreationTokens: Int
        let cacheReadTokens: Int
    }

    struct ParsedFile {
        let candidate: Candidate
        /// The `sessionId` the records themselves carry, when it differs from
        /// the file's own key — i.e. the parent session of a subagent
        /// transcript. nil for a top-level transcript (where they agree).
        let parentSessionId: String?
        let messages: [MessageRow]
        let firstTimestamp: String
        let lastTimestamp: String
        let totalInput: Int
        let totalOutput: Int
        let totalCacheCreation: Int
        let totalCacheRead: Int
    }

    /// Reads one transcript and reduces it to counters. Returns nil only when
    /// the file could not be read at all; a malformed *line* is skipped
    /// silently (transcripts are appended live, so a half-written last line is
    /// normal, not an error).
    static func parse(_ candidate: Candidate) -> ParsedFile? {
        // `.mappedIfSafe`: transcripts reach tens of MB and this avoids
        // pulling each one fully into the heap.
        guard let data = try? Data(contentsOf: candidate.url, options: .mappedIfSafe) else {
            return nil
        }

        let decoder = JSONDecoder()
        var messages: [MessageRow] = []
        var parentSessionId: String?
        var first: String?
        var last: String?
        var totalInput = 0, totalOutput = 0, totalCacheCreation = 0, totalCacheRead = 0
        var seenUUIDs = Set<String>()

        for line in data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true) {
            guard let record = try? decoder.decode(TranscriptRecord.self, from: Data(line)) else {
                continue
            }
            // Assistant records are the ones that carry billing counters. A
            // record without `usage` (user turn, tool result, summary) is not
            // an error — it simply has nothing to import.
            guard record.type == "assistant", let usage = record.message?.usage,
                  let uuid = record.uuid, !uuid.isEmpty,
                  let timestamp = record.timestamp, !timestamp.isEmpty else { continue }
            // A transcript can legitimately repeat a uuid (a resumed session
            // replays earlier turns); the DB's UNIQUE constraint would ignore
            // the duplicate anyway, but de-duplicating here keeps the session
            // totals from double-counting it.
            guard seenUUIDs.insert(uuid).inserted else { continue }

            if let sessionId = record.sessionId, !sessionId.isEmpty,
               sessionId != candidate.sessionKey {
                parentSessionId = sessionId
            }

            let input = usage.inputTokens ?? 0
            let output = usage.outputTokens ?? 0
            let cacheCreation = usage.cacheCreationInputTokens ?? 0
            let cacheRead = usage.cacheReadInputTokens ?? 0
            totalInput += input
            totalOutput += output
            totalCacheCreation += cacheCreation
            totalCacheRead += cacheRead

            // ISO 8601 with a fixed `Z` offset sorts lexically, which is how
            // the legacy importer tracked first/last too.
            if first == nil || timestamp < first! { first = timestamp }
            if last == nil || timestamp > last! { last = timestamp }

            messages.append(MessageRow(
                uuid: uuid,
                timestamp: timestamp,
                model: record.message?.model ?? "unknown",
                inputTokens: input,
                outputTokens: output,
                cacheCreationTokens: cacheCreation,
                cacheReadTokens: cacheRead
            ))
        }

        guard let firstTimestamp = first, let lastTimestamp = last else {
            // No usage-bearing record: still a successful read (so the caller
            // counts it as read, not failed) with nothing to write.
            return ParsedFile(
                candidate: candidate, parentSessionId: nil, messages: [],
                firstTimestamp: "", lastTimestamp: "",
                totalInput: 0, totalOutput: 0, totalCacheCreation: 0, totalCacheRead: 0
            )
        }

        return ParsedFile(
            candidate: candidate,
            parentSessionId: parentSessionId,
            messages: messages,
            firstTimestamp: firstTimestamp,
            lastTimestamp: lastTimestamp,
            totalInput: totalInput,
            totalOutput: totalOutput,
            totalCacheCreation: totalCacheCreation,
            totalCacheRead: totalCacheRead
        )
    }

    // MARK: - Writing

    /// Writes one batch inside a single transaction, rolling back as a unit on
    /// failure — the shape `UsageStore.mergeAccountRow` established.
    private static func commit(_ batch: [ParsedFile], to db: Connection, stats: inout ImportStats) throws {
        var sessionsWritten = 0
        var messagesImported = 0
        do {
            try db.execute("BEGIN")

            let upsertSession = try db.prepare("""
                INSERT INTO token_sessions (
                    session_id, project_path, first_message_ts, last_message_ts,
                    inferred_account_id, total_input_tokens, total_output_tokens,
                    total_cache_creation_tokens, total_cache_read_tokens, message_count,
                    last_import_ts, parent_session_id
                ) VALUES (?, ?, ?, ?, NULL, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(session_id) DO UPDATE SET
                    project_path = excluded.project_path,
                    first_message_ts = excluded.first_message_ts,
                    last_message_ts = excluded.last_message_ts,
                    total_input_tokens = excluded.total_input_tokens,
                    total_output_tokens = excluded.total_output_tokens,
                    total_cache_creation_tokens = excluded.total_cache_creation_tokens,
                    total_cache_read_tokens = excluded.total_cache_read_tokens,
                    message_count = excluded.message_count,
                    last_import_ts = excluded.last_import_ts,
                    parent_session_id = excluded.parent_session_id
            """)
            // `OR IGNORE` on the `message_uuid` UNIQUE constraint is the
            // idempotency key: re-importing a file that grew by one record
            // inserts exactly that record and silently drops the rest.
            let insertMessage = try db.prepare("""
                INSERT OR IGNORE INTO token_usage (
                    session_id, timestamp, model, input_tokens, output_tokens,
                    cache_creation_tokens, cache_read_tokens, message_uuid
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """)
            let countMessages = try db.prepare(
                "SELECT COUNT(*) FROM token_usage WHERE session_id = ?")

            for file in batch {
                let key = file.candidate.sessionKey
                let before = scalarCount(countMessages, key)

                try runStatement(upsertSession, [
                    key,
                    file.candidate.projectPath,
                    file.firstTimestamp,
                    file.lastTimestamp,
                    file.totalInput,
                    file.totalOutput,
                    file.totalCacheCreation,
                    file.totalCacheRead,
                    file.messages.count,
                    isoString(file.candidate.modified),
                    file.parentSessionId
                ])
                sessionsWritten += 1

                for message in file.messages {
                    try runStatement(insertMessage, [
                        key,
                        message.timestamp,
                        message.model,
                        message.inputTokens,
                        message.outputTokens,
                        message.cacheCreationTokens,
                        message.cacheReadTokens,
                        message.uuid
                    ])
                }
                messagesImported += max(0, scalarCount(countMessages, key) - before)
            }

            try db.execute("COMMIT")
        } catch {
            try? db.execute("ROLLBACK")
            throw ImportError.database("\(error)")
        }
        stats.sessionsWritten += sessionsWritten
        stats.messagesImported += messagesImported
    }

    /// Binds and runs a prepared statement to completion. The wrapper's
    /// `Connection.run` re-prepares every call; batches here reuse one
    /// statement across thousands of rows.
    private static func runStatement(_ statement: Statement, _ bindings: [Any?]) throws {
        try statement.bind(values: bindings).run()
    }

    private static func scalarCount(_ statement: Statement, _ sessionKey: String) -> Int {
        for row in statement.bind(sessionKey) {
            if let count = row[0] as? Int64 { return Int(count) }
        }
        return 0
    }

    // MARK: - Helpers

    private static func ensureParentDirectory(of path: String) throws {
        let dir = (path as NSString).deletingLastPathComponent
        guard !dir.isEmpty, !FileManager.default.fileExists(atPath: dir) else { return }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }

    /// ISO 8601 with fractional seconds — the format `UsageRecord.parseISO`
    /// reads back, and the format the legacy stamps were written in.
    static func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    /// Collapses the user's home directory to `~` — in a bare path *and*
    /// anywhere inside a longer string, because the other caller is an error
    /// message that may quote a path mid-sentence. Every path this file logs
    /// or stores goes through here, for the same reason
    /// `CodexAppServerClient.redactHomePath` exists: a transcript path names a
    /// user, and often a private project.
    static func redactPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard !home.isEmpty, home != "/" else { return path }
        return path.replacingOccurrences(of: home, with: "~")
    }
}
