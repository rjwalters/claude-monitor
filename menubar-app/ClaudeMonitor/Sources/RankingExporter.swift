import Foundation

/// Emits `~/.claude-monitor/ranking.json` — a small, **non-secret**, email-keyed
/// snapshot of per-account utilization / resets / status for external multi-account
/// load balancers (loom, lean-genius). See issue #2.
///
/// Design contract:
/// - **No secrets.** Only derived numbers (utilization, reset timestamps, status)
///   are emitted. OAuth access/refresh tokens and raw API headers are never read
///   into this file. The only join key is `email`.
/// - **Atomic.** The file is written with `Data.write(options: .atomic)` (temp file
///   in the same directory + rename) so consumers never observe a partial/truncated
///   document.
/// - **Best-effort.** A failure to read any single account, or to open the DB, must
///   not crash the app — the exporter logs and returns. Optional data (the `models`
///   / Fable field, backed by the externally-populated `probe_snapshots` table) is
///   simply omitted when unavailable rather than failing the whole export.
///
/// ### Schema v1
/// ```json
/// {
///   "schema": 1,
///   "generated_at": "2026-01-01T00:00:00Z",
///   "accounts": [
///     {
///       "email": "user@example.com",
///       "provider": "anthropic",
///       "plan": "max_20x",
///       "status": "available",
///       "utilization": { "5h": 0.12, "7d": 0.44 },
///       "resets":      { "5h": "2026-01-01T02:00:00Z", "7d": "2026-01-04T00:00:00Z" },
///       "models":      { "fable": { "utilization": 0.30 } },
///       "updated_at":  "2026-01-01T00:00:00Z"
///     }
///   ]
/// }
/// ```
///
/// ### `provider` (added in epic #25 phase 3)
///
/// `provider` is `"anthropic"` or `"openai"` and is **additive within schema 1**:
/// the version number tracks *breaking* changes, and adding an optional key
/// breaks nobody. A consumer that ignores it behaves exactly as before (every
/// account predating multi-provider support reports `"anthropic"`); a consumer
/// that reads it can route work to the right upstream. Unknown future values
/// should be treated as "some other provider", never rejected.
///
/// **A `provider: "openai"` account may legitimately omit `utilization["5h"]`**
/// — the live-verified Codex usage endpoint can report a weekly window and no
/// session window at all. Consumers must treat a missing key as *unknown*, not
/// as 0.0 (which would read as "full session capacity available").
///
/// ### `absent` (added in #135)
///
/// `"absent": true` marks an OpenAI identity this host is *expected* to have
/// but was never provisioned with — a placeholder row created by pasting an
/// identity-only transfer payload (see `OAuthPoller.declareCodexIdentity`).
/// Codex homes are host-local by design (#104), so this is how a fleet-wide
/// consumer can tell "this host is missing one of the three Codex identities"
/// apart from "that identity does not exist anywhere".
///
/// It is **additive within schema 1** on the same reasoning as `provider`:
/// - The key is **omitted entirely** for every normal account, so nothing
///   changes for a consumer that has never heard of it.
/// - An absent account is emitted with `"status": "blocked"` — an existing,
///   already-understood value meaning "do not route work here" — and with no
///   `utilization`/`resets`/`updated_at` keys at all. So a consumer that
///   ignores `absent` still excludes it from its pool exactly as it excludes
///   any other blocked account; it simply cannot say *why*.
/// - A consumer that reads it can distinguish "credential is broken here"
///   (`blocked`, no `absent`) from "never set up here" (`blocked` + `absent`),
///   which is the whole point.
enum RankingExporter {
    static let schemaVersion = 1

    /// Serializes exports so overlapping poll cycles never race on the write.
    private static let queue = DispatchQueue(label: "com.claude-monitor.ranking-exporter")

    static var defaultDBPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude-monitor/usage.db").path
    }

    static var defaultOutputPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude-monitor/ranking.json").path
    }

    /// Trigger a fresh export. Runs off the caller's thread (DB reads + file IO)
    /// on a dedicated serial queue so it never blocks the UI or races with itself.
    static func export() {
        queue.async { exportSync() }
    }

    /// Export and wait for the write to finish. Headless mode uses this so a
    /// --once run can't exit before ranking.json lands on disk.
    static func exportNow() {
        queue.sync { exportSync() }
    }

    /// Export a specific database to a specific path, synchronously. Both paths
    /// are **explicit** — the self-test uses this against a scratch directory
    /// rather than a `HOME` override, which `homeDirectoryForCurrentUser`
    /// ignores on macOS (issue #16).
    static func exportNow(dbPath: String, outputPath: String) {
        queue.sync { exportSync(dbPath: dbPath, outputPath: outputPath) }
    }

    // MARK: - Status mapping

    /// Maps the app's ping signals to the schema's `status` enum. Explicit and
    /// documented per issue #2:
    ///
    /// | Condition                                              | status         |
    /// |--------------------------------------------------------|----------------|
    /// | account has no active OAuth credential (`is_active=0`) | `blocked`      |
    /// | weekly (`7d`) status is `rejected`                     | `exhausted`    |
    /// | session (`5h`) or overall status is `rejected`         | `rate_limited` |
    /// | `allowed` / `allowed_warning` / unknown                | `available`    |
    ///
    /// Weekly-rejected is treated as `exhausted` (the 7d quota is spent and resets
    /// on a multi-day cadence); a session-only rejection is `rate_limited` (the 5h
    /// window is temporarily full and resets soon).
    static func mapStatus(
        overallStatus: String?,
        sessionStatus: String?,
        weeklyStatus: String?,
        credentialActive: Bool
    ) -> String {
        if !credentialActive { return "blocked" }
        if weeklyStatus == "rejected" { return "exhausted" }
        if sessionStatus == "rejected" || overallStatus == "rejected" { return "rate_limited" }
        return "available"
    }

    // MARK: - Export implementation

    private static func exportSync(
        dbPath: String = defaultDBPath,
        outputPath: String = defaultOutputPath
    ) {
        guard FileManager.default.fileExists(atPath: dbPath) else { return }

        do {
            let db = try openDatabase(dbPath, readonly: true)

            var accountObjects: [[String: Any]] = []

            // Only non-secret columns are read. `accounts` carries no tokens.
            // `provider` is selected only when the column exists, so an
            // unmigrated database still exports (every row then resolves to the
            // Anthropic fallback).
            let accountColumns = tableColumns(db, "accounts")
            let hasProvider = accountColumns.contains("provider")
            // `codex_home` is read as a **boolean** and never selected as a
            // value: it names a user, so the path itself must not enter this
            // file or even this process's memory here. Explicit column list,
            // never `SELECT *` — that is what keeps it out (#103).
            let homeRegistered = accountColumns.contains("codex_home")
                ? "(codex_home IS NOT NULL AND TRIM(codex_home) != '')"
                : "0"
            // Both absent-identity inputs degrade the same way every other
            // column here does: a table this database doesn't have reads as
            // "no evidence", which can only ever make a row look *less*
            // absent — never falsely absent.
            let storedTokenCount = storedTokenCountSQL(
                accountRef: "accounts.id",
                credentialsTableExists: !tableColumns(db, "oauth_credentials").isEmpty
            )
            let localReading = tableColumns(db, "usage_history").isEmpty
                ? "1"
                : "EXISTS (SELECT 1 FROM usage_history u WHERE u.account_id = accounts.id)"
            let accountStmt = try db.prepare("""
                SELECT id, email, plan\(hasProvider ? ", provider" : ", NULL"),
                       \(homeRegistered), \(storedTokenCount), \(localReading)
                FROM accounts ORDER BY sort_order ASC, last_updated DESC
            """)

            for row in accountStmt {
                guard let accountId = row[0] as? String else { continue }
                // Acceptance criterion: accounts with a NULL email are excluded
                // (email is the sole join key — a null key is useless to consumers).
                guard let email = row[1] as? String, !email.isEmpty else { continue }
                let plan = row[2] as? String
                let provider = AccountProvider(stored: hasProvider ? row[3] as? String : nil)
                let isAbsent = isAbsentCodexIdentity(
                    provider: provider,
                    hasStoredToken: ((row[5] as? Int64) ?? 0) > 0,
                    hasCodexHome: ((row[4] as? Int64) ?? 0) != 0,
                    hasLocalReading: ((row[6] as? Int64) ?? 0) != 0
                )

                if let obj = buildAccount(db: db, accountId: accountId, email: email,
                                          plan: plan, provider: provider, isAbsent: isAbsent) {
                    accountObjects.append(obj)
                }
            }

            let payload: [String: Any] = [
                "schema": schemaVersion,
                "generated_at": iso8601(Date()),
                "accounts": accountObjects,
            ]

            let data = try JSONSerialization.data(
                withJSONObject: payload,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )

            // Ensure the parent dir exists (it normally does — the DB lives there).
            let dir = (outputPath as NSString).deletingLastPathComponent
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

            // Atomic write: Data.write(.atomic) stages a temp file in the same
            // directory and renames it into place, so readers never see a partial file.
            try data.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
        } catch {
            FileLogger.shared.error("RankingExporter export failed: \(error)", category: "Ranking")
        }
    }

    /// Build one account entry, or `nil` if the account should be skipped.
    private static func buildAccount(
        db: Connection,
        accountId: String,
        email: String,
        plan: String?,
        provider: AccountProvider,
        isAbsent: Bool = false
    ) -> [String: Any]? {
        // `provider` is emitted unconditionally (never omitted) so a consumer
        // can rely on its presence rather than defaulting per-account; rows that
        // predate multi-provider support resolve to "anthropic".
        var obj: [String: Any] = ["email": email, "provider": provider.rawValue]
        if let plan = plan { obj["plan"] = plan }

        // An absent identity (#135) stops here: it has no reading, and any
        // utilization/reset/updated_at figure attached to it would be a
        // fabrication. `blocked` keeps every existing consumer excluding it
        // without understanding `absent`.
        if isAbsent {
            obj["absent"] = true
            obj["status"] = "blocked"
            return obj
        }

        // Latest real (non-synthetic) usage reading for this account.
        var sessionPercent: Double?
        var weeklyPercent: Double?
        var sessionReset: String?
        var weeklyReset: String?
        var rawData: String?
        var updatedAt: String?

        if let usageStmt = try? db.prepare("""
            SELECT timestamp, session_percent, weekly_all_percent, session_reset, weekly_reset, raw_data
            FROM usage_history
            WHERE account_id = ? AND is_synthetic = 0
            ORDER BY timestamp DESC LIMIT 1
        """) {
            for r in usageStmt.bind(accountId) {
                updatedAt = r[0] as? String
                sessionPercent = r[1] as? Double
                weeklyPercent = r[2] as? Double
                sessionReset = r[3] as? String
                weeklyReset = r[4] as? String
                rawData = r[5] as? String
            }
        }

        // Parse the per-poll status blob written by OAuthPoller.writePingToDB().
        let statuses = parseStatuses(rawData)
        let credentialActive = isCredentialActive(db: db, accountId: accountId)

        obj["status"] = mapStatus(
            overallStatus: statuses.overall,
            sessionStatus: statuses.session,
            weeklyStatus: statuses.weekly,
            credentialActive: credentialActive
        )

        // utilization: DB stores 0–100 percentages; schema wants 0.0–1.0 fractions.
        var utilization: [String: Any] = [:]
        if let s = sessionPercent { utilization["5h"] = fraction(s) }
        if let w = weeklyPercent { utilization["7d"] = fraction(w) }
        if !utilization.isEmpty { obj["utilization"] = utilization }

        // resets: pass through the stored ISO 8601 strings, normalizing to UTC.
        var resets: [String: Any] = [:]
        if let s = normalizedISO(sessionReset) { resets["5h"] = s }
        if let w = normalizedISO(weeklyReset) { resets["7d"] = w }
        if !resets.isEmpty { obj["resets"] = resets }

        // models: optional / best-effort. Omitted entirely when unavailable.
        if let models = fableModels(db: db, accountId: accountId) {
            obj["models"] = models
        }

        if let updatedAt = normalizedISO(updatedAt) {
            obj["updated_at"] = updatedAt
        }

        return obj
    }

    // MARK: - Helpers

    /// Whether the account has an active OAuth credential. Reads only the
    /// non-secret `is_active` flag — never a token column. A missing table or
    /// absent row is treated as "active" (we have no signal that it is blocked).
    private static func isCredentialActive(db: Connection, accountId: String) -> Bool {
        guard let stmt = try? db.prepare(
            "SELECT is_active FROM oauth_credentials WHERE account_id = ? ORDER BY updated_at DESC LIMIT 1"
        ) else { return true }
        for r in stmt.bind(accountId) {
            if let active = r[0] as? Int64 { return active != 0 }
        }
        return true
    }

    private struct Statuses { let overall: String?; let session: String?; let weekly: String? }

    /// Parse the status blob stored in `usage_history.raw_data`. Two shapes exist
    /// in the wild and both are tolerated:
    ///   1. The compact form written by this repo's `OAuthPoller.writePingToDB()`:
    ///      `{"ping_status":200,"session_status":"allowed","weekly_status":"allowed","overall_status":"allowed"}`
    ///   2. The full response-header form written by the external poller that
    ///      populates the live DB, keyed by the raw `anthropic-ratelimit-unified-*`
    ///      header names.
    /// Only status *strings* (`allowed` / `allowed_warning` / `rejected`) are read —
    /// never token or identity fields.
    private static func parseStatuses(_ raw: String?) -> Statuses {
        guard let raw = raw,
              let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return Statuses(overall: nil, session: nil, weekly: nil)
        }
        func str(_ keys: String...) -> String? {
            for key in keys {
                if let v = obj[key] as? String, !v.isEmpty { return v }
            }
            return nil
        }
        return Statuses(
            overall: str("overall_status", "anthropic-ratelimit-unified-status"),
            session: str("session_status", "anthropic-ratelimit-unified-5h-status"),
            weekly: str("weekly_status", "anthropic-ratelimit-unified-7d-status")
        )
    }

    /// Best-effort per-model utilization from the externally-populated
    /// `probe_snapshots` table. This repo never creates or writes that table, so
    /// every access is defensive: a missing table, missing row, or unparseable
    /// headers simply yields `nil` and the `models` key is omitted. Returns a dict
    /// shaped like `{ "fable": { "utilization": 0.30 } }` when data is available.
    ///
    /// Semantics: the value is the unified 5h utilization (0.0–1.0) observed in the
    /// response headers of the most recent successful (HTTP 200) Fable-model probe.
    /// Anthropic's unified rate-limit headers are account-scoped rather than truly
    /// per-model, so this is "utilization seen while exercising the Fable model,"
    /// not a separate Fable-only quota. It is an optional/extensible signal per the
    /// schema's `models` note; consumers that don't understand it ignore it.
    private static func fableModels(db: Connection, accountId: String) -> [String: Any]? {
        // `prepare` throws if probe_snapshots doesn't exist — tolerated via try?.
        guard let stmt = try? db.prepare("""
            SELECT headers FROM probe_snapshots
            WHERE account_id = ? AND probe_model LIKE '%fable%' AND http_status = 200
            ORDER BY timestamp DESC LIMIT 1
        """) else { return nil }

        for r in stmt.bind(accountId) {
            guard let headersJSON = r[0] as? String,
                  let data = headersJSON.data(using: .utf8),
                  let headers = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            if let util = parseDoubleValue(headers["anthropic-ratelimit-unified-5h-utilization"]) {
                return ["fable": ["utilization": clampFraction(util)]]
            }
        }
        return nil
    }

    /// Convert a 0–100 percentage to a 0.0–1.0 fraction, rounded to 4 decimals.
    private static func fraction(_ percent: Double) -> Double {
        let f = (percent / 100.0 * 10000).rounded() / 10000
        return clampFraction(f)
    }

    private static func clampFraction(_ v: Double) -> Double {
        min(max(v, 0.0), 1.0)
    }

    /// Accepts a header value that may already be a number or a numeric string.
    private static func parseDoubleValue(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int64 { return Double(i) }
        if let s = value as? String { return Double(s) }
        return nil
    }

    /// Re-serialize a stored timestamp to ISO 8601 UTC (`...Z`). Tolerates the two
    /// formats this codebase writes (with and without fractional seconds). Returns
    /// `nil` for nil/empty/unparseable input so the key can be omitted.
    private static func normalizedISO(_ stored: String?) -> String? {
        UsageRecord.parseISO(stored).map(iso8601)
    }

    /// Canonical ISO 8601 UTC string with no fractional seconds (e.g. `2026-01-01T00:00:00Z`).
    private static func iso8601(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: date)
    }
}
