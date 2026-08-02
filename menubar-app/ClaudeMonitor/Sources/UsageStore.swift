import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Opens a SQLite connection with a busy timeout so concurrent access from
/// other processes waits briefly for locks instead of failing immediately.
func openDatabase(_ path: String, readonly: Bool = false) throws -> Connection {
    let db = try Connection(path, readonly: readonly)
    db.busyTimeout = 5
    return db
}

/// Column names present on `table`, or an empty set when the table doesn't
/// exist. Lets read paths tolerate a database that hasn't been migrated yet
/// (e.g. `accounts export` run before the app has launched once).
func tableColumns(_ db: Connection, _ table: String) -> Set<String> {
    guard let stmt = try? db.prepare("PRAGMA table_info(\(table))") else { return [] }
    var names: Set<String> = []
    for row in stmt {
        if let name = row[1] as? String { names.insert(name) }
    }
    return names
}

struct Account: Identifiable {
    let id: String
    /// Which upstream this account belongs to. Rows written before
    /// multi-provider support resolve to `.anthropic` via the schema migration.
    let provider: AccountProvider
    let accountName: String?
    let email: String?
    let plan: String?
    let lastUpdated: Date?
    let latestPercent: Double?

    init(
        id: String,
        provider: AccountProvider = .anthropic,
        accountName: String?,
        email: String?,
        plan: String?,
        lastUpdated: Date?,
        latestPercent: Double?
    ) {
        self.id = id
        self.provider = provider
        self.accountName = accountName
        self.email = email
        self.plan = plan
        self.lastUpdated = lastUpdated
        self.latestPercent = latestPercent
    }

    /// Returns the best display name for the account
    var displayName: String {
        accountName ?? email ?? id
    }
}

struct UsageRecord: Identifiable {
    let id: Int64
    let accountId: String
    let timestamp: Date
    let primaryPercent: Double?
    let sessionPercent: Double?
    let weeklyAllPercent: Double?
    let weeklySONnetPercent: Double?
    let sessionReset: String?
    let weeklyReset: String?

    /// Premium/Fable weekly usage 0–100 (from the `7d_oi` bucket on the Fable
    /// probe). nil if we don't have a recent premium-model probe.
    var fablePercent: Double? = nil
    /// Extra-usage (overage) consumed 0–100, as a fraction of the account's
    /// configured budget. Stays 0 for unlimited/unmetered balances even while
    /// active, so it's only meaningful when > 0.
    var overagePercent: Double? = nil
    /// Overage availability: "allowed", "rejected", etc.
    var overageStatus: String? = nil
    /// Why overage is unavailable (e.g. "org_level_disabled", "out_of_credits").
    var overageDisabledReason: String? = nil
    /// Whether the account is currently drawing on extra usage.
    var overageInUse: Bool? = nil

    /// This stored reading expressed in the shared, provider-agnostic window
    /// model. The `usage_history` columns are already kind-keyed (a session
    /// column and a weekly column), so each window's kind is explicit and its
    /// duration is the bucket's nominal length.
    ///
    /// A NULL column stays nil here — it is **not** coerced to 0%. That is what
    /// makes "this provider reported no session window" survive the round trip
    /// through the database (an OpenAI account may legitimately have none), and
    /// what keeps `headroomScore` from reporting full capacity for an account
    /// we know nothing about.
    var rateLimit: RateLimitSnapshot {
        var named: [String: RateLimitWindow] = [:]
        if let fable = fablePercent {
            named["fable"] = RateLimitWindow(kind: .weekly, usedPercent: fable)
        }
        return RateLimitSnapshot(
            session: sessionPercent.map {
                RateLimitWindow(kind: .session, usedPercent: $0, resetAt: UsageRecord.parseISO(sessionReset))
            },
            weekly: weeklyAllPercent.map {
                RateLimitWindow(kind: .weekly, usedPercent: $0, resetAt: UsageRecord.parseISO(weeklyReset))
            },
            named: named
        )
    }

    /// Parses the two ISO 8601 shapes this codebase writes (with and without
    /// fractional seconds).
    static func parseISO(_ string: String?) -> Date? {
        guard let string = string, !string.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }

    /// Compact state of the extra-usage balance for display. `.percent` carries
    /// a remaining figure only when the balance is actually metered (>0 used).
    enum ExtraUsageState {
        case unknown          // no premium probe yet
        case off              // org-level disabled — extra usage not a thing here
        case empty            // out of credits — needs a recharge
        case active           // allowed and currently drawing
        case ready            // allowed, available, not yet drawing
        case percent(Double)  // allowed with a real remaining % (metered budget)
    }

    var extraUsageState: ExtraUsageState {
        switch overageStatus {
        case "allowed":
            if let used = overagePercent, used > 0 { return .percent(max(0, 100 - used)) }
            return (overageInUse == true) ? .active : .ready
        case "rejected":
            return overageDisabledReason == "out_of_credits" ? .empty : .off
        default:
            return .unknown
        }
    }
}

/// "Which account should I use" score 0–100.
/// 100 = no usage / max headroom; 0 = capped on any known window.
///
/// Returns nil when there is no usage data at all — either no reading yet, or a
/// reading whose provider reported neither a session nor a weekly window. The
/// popover renders nil as "—" so an account we know nothing about never
/// masquerades as fully available.
///
/// Lives in the portable core (not the macOS-only popover) because the headless
/// Linux daemon and `ranking.json` reason about the same score.
func headroomScore(_ usage: UsageRecord?) -> Double? {
    usage?.rateLimit.headroomScore
}

struct UsageDataPoint: Identifiable {
    let id = UUID()
    let timestamp: Date
    let weeklyPercent: Double
    let usageDelta: Double  // How much was used since last reading (negative of the drop)
}

struct FullUsageDataPoint: Identifiable {
    let id = UUID()
    let timestamp: Date
    let sessionPercent: Double?
    let weeklyAllPercent: Double?
}

/// One reading of a single named sub-limit (`named_limits` table) — one series
/// per provider-chosen `limit_name`, e.g. OpenAI's `additional_rate_limits[]`
/// entries. Anthropic accounts never populate this today.
struct NamedLimitDataPoint: Identifiable {
    let id = UUID()
    let timestamp: Date
    let usedPercent: Double
}

struct TokenDataPoint: Identifiable {
    let id = UUID()
    let timestamp: Date
    let inputTokens: Int64
    let outputTokens: Int64
    let cacheCreationTokens: Int64
    let cacheReadTokens: Int64

    var totalTokens: Int64 {
        inputTokens + outputTokens + cacheCreationTokens + cacheReadTokens
    }

    var billableTokens: Int64 {
        // Cache reads don't count toward quota
        inputTokens + outputTokens + cacheCreationTokens
    }
}

struct DailyTokenSummary: Identifiable {
    let id = UUID()
    let day: Date
    let accountId: String?
    let inputTokens: Int64
    let outputTokens: Int64
    let cacheCreationTokens: Int64
    let cacheReadTokens: Int64
    let messageCount: Int64

    var totalTokens: Int64 {
        inputTokens + outputTokens + cacheCreationTokens + cacheReadTokens
    }

    var billableTokens: Int64 {
        inputTokens + outputTokens + cacheCreationTokens
    }
}

// `@Published`-driven state is only ever read/written from the main thread
// today (SwiftUI views on macOS; a single Task-driven headless loop that
// pumps via `dispatchMain()` on Linux) — @MainActor isolation matches actual
// usage and lets Swift 6 verify it, rather than sprinkling per-call
// `DispatchQueue.main.async` hops that only *assert* the same invariant.
@MainActor
class UsageStore: ObservableObject {
    @Published var accounts: [Account] = []
    @Published var latestUsage: [String: UsageRecord] = [:]
    @Published var lastRefresh: Date?
    @Published var error: String?
    /// Account chosen by the user to drive the menubar icon. `nil` = auto (most-available).
    @Published var primaryAccountId: String?

    /// Called when accounts change (e.g., reordering, primary selection) so the menubar can update
    var onAccountsChanged: (() -> Void)?

    // Immutable String constant — safe to read from the nonisolated merge
    // helpers above as well as main-actor instance methods.
    private nonisolated static let primaryAccountSettingKey = "primary_account_id"

    private let dbPath: String

    /// `dbPath` defaults to `~/.claude-monitor/usage.db`. An explicit path is
    /// used by the self-test to exercise schema migration against a throwaway
    /// database without touching the real one.
    init(dbPath: String? = nil) {
        self.dbPath = dbPath ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude-monitor/usage.db").path
    }

    /// Creates the database and schema if they don't exist.
    /// Called on launch so the app works standalone without the native host.
    func ensureDatabase() {
        let fm = FileManager.default
        let dir = (dbPath as NSString).deletingLastPathComponent
        if !fm.fileExists(atPath: dir) {
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        do {
            let db = try openDatabase(dbPath)
            try db.execute("PRAGMA journal_mode=WAL")
            try UsageStore.applySchema(db)
        } catch {
            FileLogger.shared.error("Failed to create database: \(error)", category: "DB")
        }
    }

    /// Idempotent schema creation plus healing migrations, against any
    /// read-write connection. Safe to run on every launch — that is the
    /// established pattern here (#15, #23): heal in place rather than make the
    /// user re-add accounts.
    // Pure function of its `db` argument — touches no instance/class
    // main-actor state, so it stays callable from non-UI contexts (CLI
    // import/export, headless startup) without forcing them onto MainActor.
    nonisolated static func applySchema(_ db: Connection) throws {
        try db.execute("""
            CREATE TABLE IF NOT EXISTS accounts (
                id TEXT PRIMARY KEY,
                account_name TEXT,
                email TEXT,
                plan TEXT,
                last_updated TEXT,
                sort_order INTEGER DEFAULT 0,
                provider TEXT NOT NULL DEFAULT 'anthropic'
            );
            CREATE TABLE IF NOT EXISTS usage_history (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                account_id TEXT NOT NULL,
                timestamp TEXT NOT NULL,
                primary_percent REAL,
                session_percent REAL,
                weekly_all_percent REAL,
                weekly_sonnet_percent REAL,
                session_reset TEXT,
                weekly_reset TEXT,
                raw_data TEXT,
                is_synthetic INTEGER DEFAULT 0,
                FOREIGN KEY (account_id) REFERENCES accounts(id)
            );
            CREATE TABLE IF NOT EXISTS settings (
                key TEXT PRIMARY KEY,
                value TEXT
            );
            CREATE TABLE IF NOT EXISTS probe_snapshots (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                account_id TEXT NOT NULL,
                timestamp TEXT NOT NULL,
                probe_model TEXT NOT NULL,
                http_status INTEGER,
                headers TEXT NOT NULL,
                FOREIGN KEY (account_id) REFERENCES accounts(id)
            );
            CREATE TABLE IF NOT EXISTS named_limits (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                account_id TEXT NOT NULL,
                timestamp TEXT NOT NULL,
                limit_name TEXT NOT NULL,
                used_percent REAL,
                window_seconds REAL,
                reset_at TEXT,
                FOREIGN KEY (account_id) REFERENCES accounts(id)
            );
            CREATE INDEX IF NOT EXISTS idx_usage_account ON usage_history(account_id);
            CREATE INDEX IF NOT EXISTS idx_usage_timestamp ON usage_history(timestamp DESC);
            CREATE INDEX IF NOT EXISTS idx_probe_account_time ON probe_snapshots(account_id, timestamp DESC);
            CREATE INDEX IF NOT EXISTS idx_named_limits_account_time
                ON named_limits(account_id, limit_name, timestamp DESC);
            CREATE TABLE IF NOT EXISTS oauth_credentials (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                account_id TEXT,
                label TEXT NOT NULL,
                source TEXT DEFAULT 'keychain',
                keychain_service TEXT,
                keychain_account TEXT,
                access_token TEXT,
                refresh_token TEXT,
                expires_at INTEGER,
                scopes TEXT,
                subscription_type TEXT,
                rate_limit_tier TEXT,
                last_poll_at TEXT,
                last_error TEXT,
                is_active INTEGER DEFAULT 1,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                token_rolled_at TEXT,
                provider TEXT NOT NULL DEFAULT 'anthropic',
                token_expires_at TEXT,
                FOREIGN KEY (account_id) REFERENCES accounts(id)
            );
        """)

        // Migration: add token_rolled_at to older DBs. `updated_at` can't serve
        // this — it's bumped on every poll — so we track token changes separately.
        // ADD COLUMN throws if it already exists; that's the expected no-op path.
        try? db.execute("ALTER TABLE oauth_credentials ADD COLUMN token_rolled_at TEXT")

        // Migration (multi-provider, #28): provider identity + refresh-capable
        // credentials. SQLite's ADD COLUMN with a constant DEFAULT backfills
        // every existing row in place, so accounts written before this build
        // become `provider = 'anthropic'` with no user action.
        //
        // The credential columns live on `oauth_credentials` rather than
        // `accounts` because that is already the table that holds token
        // material; `accounts` stays free of secrets (RankingExporter reads
        // it directly and must never see one).
        addColumnIfMissing(db, table: "accounts",
                           column: "provider", definition: "TEXT NOT NULL DEFAULT 'anthropic'")
        addColumnIfMissing(db, table: "oauth_credentials",
                           column: "provider", definition: "TEXT NOT NULL DEFAULT 'anthropic'")
        // `refresh_token` has been in the CREATE TABLE since the beginning,
        // so this is a no-op on every database we have seen — kept so the
        // migration is self-describing and heals a truncated schema.
        addColumnIfMissing(db, table: "oauth_credentials",
                           column: "refresh_token", definition: "TEXT")
        // ISO 8601 expiry of the access token. Distinct from the vestigial
        // epoch-ms `expires_at` column (a keychain-import-era field this app
        // has never written), and consistent with `token_rolled_at`'s format.
        // Stays NULL for Anthropic; OpenAI access tokens live ~10 days and
        // must be refreshed before this instant (spike #26).
        addColumnIfMissing(db, table: "oauth_credentials",
                           column: "token_expires_at", definition: "TEXT")

        // Heal rows whose provider is absent/blank — a database edited by an
        // external tool, or one where an earlier ADD COLUMN raced.
        try? db.run("UPDATE accounts SET provider = ? WHERE provider IS NULL OR TRIM(provider) = ''",
                    AccountProvider.fallback.rawValue)
        try? db.run("UPDATE oauth_credentials SET provider = ? WHERE provider IS NULL OR TRIM(provider) = ''",
                    AccountProvider.fallback.rawValue)

        // Migration: heal accounts left with email = NULL by earlier app
        // versions — e.g. added via plain token paste (no email known) and
        // later renamed to the real address, which only touched
        // account_name. `email` is the join key downstream consumers (like
        // loom-daemon's `tokens import-from-monitor`) key accounts on, so an
        // account must never persist indefinitely without one (#15).
        backfillMissingEmailsFromAccountName(db)

        // Migration: merge account rows left duplicated by pre-1.18.1
        // databases. `10660f3` stops a fresh `codex import` from creating a
        // second row for an OpenAI account whose original row predated the
        // native-id era (keyed by a locally generated UUID rather than
        // OpenAI's `user-…` id) — that fix is prevention only, so any
        // database where the duplicate already exists still has two active
        // rows polling the same account independently (#45). Must run after
        // the email backfill above so a row healed there is eligible too.
        mergeDuplicateAccountsSharingEmail(db)
    }

    /// Adds a column only when it isn't already there. `ALTER TABLE ... ADD
    /// COLUMN` throws on a duplicate; checking first keeps the (expected)
    /// already-migrated path free of spurious errors and lets us log the one
    /// launch where a real migration happens.
    // Pure function of its arguments (plus the free `tableColumns` helper and
    // `FileLogger.shared`) — touches no instance/class main-actor state.
    private nonisolated static func addColumnIfMissing(
        _ db: Connection, table: String, column: String, definition: String
    ) {
        let existing = tableColumns(db, table)
        guard !existing.isEmpty, !existing.contains(column) else { return }
        do {
            try db.execute("ALTER TABLE \(table) ADD COLUMN \(column) \(definition)")
            FileLogger.shared.info("Migrated \(table): added \(column)", category: "DB")
        } catch {
            FileLogger.shared.error("Migration failed adding \(table).\(column): \(error)", category: "DB")
        }
    }

    /// One-time-per-launch healing pass: any account with `email IS NULL`
    /// whose `account_name` is itself a well-formed address gets that address
    /// copied into `email`. Idempotent and side-effect-free once every row is
    /// backfilled — cheap enough to run unconditionally on every launch rather
    /// than tracking a schema version for it.
    // Pure function of its argument — touches no instance/class main-actor
    // state.
    private nonisolated static func backfillMissingEmailsFromAccountName(_ db: Connection) {
        do {
            let stmt = try db.prepare("SELECT id, account_name FROM accounts WHERE email IS NULL AND account_name IS NOT NULL")
            var candidates: [(id: String, name: String)] = []
            for row in stmt {
                if let id = row[0] as? String, let name = row[1] as? String {
                    candidates.append((id: id, name: name))
                }
            }
            for candidate in candidates where looksLikeEmailAddress(candidate.name) {
                try db.run("UPDATE accounts SET email = ? WHERE id = ? AND email IS NULL", candidate.name, candidate.id)
                FileLogger.shared.info(
                    "backfillMissingEmailsFromAccountName: healed email for account \(candidate.id) from account_name",
                    category: "DB"
                )
            }
        } catch {
            FileLogger.shared.error("backfillMissingEmailsFromAccountName failed: \(error)", category: "DB")
        }
    }

    /// One-time-per-launch healing pass (#45): merges account rows that
    /// share the same `(email, provider)` pair. Matching is provider-scoped
    /// so a Claude and a ChatGPT account under one address never merge —
    /// same guard `resolveOpenAIAccountId` and `AccountSync.importAccount`
    /// already apply. Idempotent: once only one row remains per (email,
    /// provider), the grouping query below finds nothing to merge.
    // Pure function of its argument — touches no instance/class main-actor
    // state.
    private nonisolated static func mergeDuplicateAccountsSharingEmail(_ db: Connection) {
        struct Candidate {
            let id: String
            let provider: String
            let email: String
            let lastUpdated: String?
        }
        do {
            let stmt = try db.prepare("""
                SELECT id, COALESCE(provider, 'anthropic'), email, last_updated
                FROM accounts
                WHERE email IS NOT NULL AND TRIM(email) != ''
            """)
            var candidates: [Candidate] = []
            for row in stmt {
                guard let id = row[0] as? String,
                      let provider = row[1] as? String,
                      let email = row[2] as? String else { continue }
                candidates.append(Candidate(id: id, provider: provider, email: email, lastUpdated: row[3] as? String))
            }

            // Group key uses a separator that cannot appear in either field
            // (both come from the accounts table, never user-typed free
            // text) so an email/provider pair can't collide with another.
            let groups = Dictionary(grouping: candidates) { "\($0.email)\u{0}\($0.provider)" }
            for (_, group) in groups where group.count > 1 {
                let survivorId = pickMergeSurvivor(group.map { (id: $0.id, lastUpdated: $0.lastUpdated) })
                for candidate in group where candidate.id != survivorId {
                    mergeAccountRow(db, from: candidate.id, into: survivorId)
                }
            }
        } catch {
            FileLogger.shared.error("mergeDuplicateAccountsSharingEmail failed: \(error)", category: "DB")
        }
    }

    /// Picks which of a set of duplicate `(email, provider)` rows survives a
    /// merge. Prefers a provider-native id (one that doesn't parse as a
    /// canonical UUID — the shape Swift's `UUID()` produces for a locally
    /// generated id, and the shape the pre-native-id-era duplicate is keyed
    /// by) over a generated one; ties — including when every candidate looks
    /// native, or none does — break on the most-recently-updated row.
    // Pure function of its argument — touches no instance/class main-actor
    // state.
    private nonisolated static func pickMergeSurvivor(_ candidates: [(id: String, lastUpdated: String?)]) -> String {
        let native = candidates.filter { UUID(uuidString: $0.id) == nil }
        let pool = native.isEmpty ? candidates : native
        return pool.max { ($0.lastUpdated ?? "") < ($1.lastUpdated ?? "") }?.id ?? candidates[0].id
    }

    /// Merges `loserId`'s history, credential, and settings pin onto
    /// `survivorId`, then removes the now-empty `loserId` row. Runs inside a
    /// transaction so a mid-merge failure never leaves history split across
    /// two rows with neither id complete.
    // Pure function of its arguments — touches no instance/class main-actor
    // state.
    private nonisolated static func mergeAccountRow(_ db: Connection, from loserId: String, into survivorId: String) {
        do {
            try db.execute("BEGIN")
            try db.run("UPDATE usage_history SET account_id = ? WHERE account_id = ?", survivorId, loserId)
            try db.run("UPDATE probe_snapshots SET account_id = ? WHERE account_id = ?", survivorId, loserId)
            try db.run("UPDATE named_limits SET account_id = ? WHERE account_id = ?", survivorId, loserId)

            // Exactly one credential survives: the most recently renewed
            // between the two rows (falling back to updated_at for a
            // credential that has never been rolled). Any other credential
            // row for either id is discarded rather than merged — a stale
            // token for an account that already has a fresher one is not
            // useful to keep around.
            var winnerCredentialId: Int64?
            let credStmt = try db.prepare("""
                SELECT id FROM oauth_credentials
                WHERE account_id IN (?, ?)
                ORDER BY COALESCE(token_rolled_at, updated_at) DESC
                LIMIT 1
            """)
            for row in credStmt.bind(survivorId, loserId) {
                winnerCredentialId = row[0] as? Int64
            }
            if let winnerCredentialId {
                try db.run("UPDATE oauth_credentials SET account_id = ? WHERE id = ?",
                           survivorId, winnerCredentialId)
                try db.run("DELETE FROM oauth_credentials WHERE account_id IN (?, ?) AND id != ?",
                           survivorId, loserId, winnerCredentialId)
            } else {
                try db.run("DELETE FROM oauth_credentials WHERE account_id = ?", loserId)
            }

            // The user's pinned "primary" account (if it was the row being
            // removed) must keep pointing at a live account after the merge.
            try db.run("UPDATE settings SET value = ? WHERE key = ? AND value = ?",
                       survivorId, primaryAccountSettingKey, loserId)

            try db.run("DELETE FROM accounts WHERE id = ?", loserId)
            try db.execute("COMMIT")
            FileLogger.shared.info(
                "mergeDuplicateAccountsSharingEmail: merged \(loserId) into \(survivorId)",
                category: "DB"
            )
        } catch {
            try? db.execute("ROLLBACK")
            FileLogger.shared.error(
                "mergeDuplicateAccountsSharingEmail: merge of \(loserId) into \(survivorId) failed: \(error)",
                category: "DB"
            )
        }
    }

    /// Seconds until reset (session first, then weekly). Returns large value if
    /// unknown — including when the provider reports no window at all.
    // Pure function of its argument — touches no instance/class main-actor
    // state.
    nonisolated static func resetSeconds(_ usage: UsageRecord?) -> TimeInterval {
        guard let usage = usage else { return .greatestFiniteMagnitude }
        let snapshot = usage.rateLimit
        for date in [snapshot.session?.resetAt, snapshot.weekly?.resetAt].compactMap({ $0 }) {
            return date.timeIntervalSinceNow
        }
        return .greatestFiniteMagnitude
    }

    /// Account ID currently driving the menubar icon. Falls back to the
    /// most-available account when the user hasn't pinned one (or pinned a
    /// removed account).
    var effectivePrimaryAccountId: String? {
        if let pinned = primaryAccountId, accounts.contains(where: { $0.id == pinned }) {
            return pinned
        }
        return sortedAccountsForPopover.first?.id
    }

    /// User picked a row as the menubar source (or `nil` to revert to auto).
    func setPrimaryAccount(_ id: String?) {
        primaryAccountId = id
        setSetting(Self.primaryAccountSettingKey, value: id)
        onAccountsChanged?()
    }

    /// Accounts sorted for popover display: most available (lowest usage) first.
    /// Reads through the shared window model, so an account whose provider
    /// reports only a weekly window is ranked on that window alone rather than
    /// being credited with a fictitious 0% session.
    var sortedAccountsForPopover: [Account] {
        let pairs = accounts.map { account in
            (account: account, usage: latestUsage[account.id])
        }
        let sorted = pairs.sorted { a, b in
            // An absent window contributes nothing (rather than a fabricated
            // 0%), so an OpenAI account reporting only a weekly figure ranks on
            // that figure. Unchanged for Anthropic rows, which always carry both.
            let aWindows = a.usage?.rateLimit
            let bWindows = b.usage?.rateLimit
            let aEffective = max(aWindows?.session?.usedPercent ?? 0, aWindows?.weekly?.usedPercent ?? 0)
            let bEffective = max(bWindows?.session?.usedPercent ?? 0, bWindows?.weekly?.usedPercent ?? 0)
            if aEffective != bEffective { return aEffective < bEffective }
            let aReset = UsageStore.resetSeconds(a.usage)
            let bReset = UsageStore.resetSeconds(b.usage)
            if aReset != bReset { return aReset < bReset }
            // Usage and reset both tie (common for freshly-added or idle
            // accounts that all read 0%): order by natural display name
            // instead of falling through to arbitrary insertion/UUID order.
            let cmp = NaturalSort.compare(a.account.displayName, b.account.displayName)
            if cmp != .orderedSame { return cmp == .orderedAscending }
            return a.account.id < b.account.id
        }
        return sorted.map { $0.account }
    }

    /// Decode a `probe_snapshots.headers` JSON blob into a [String:String] map.
    static func parseHeaders(_ json: String) -> [String: String]? {
        guard let data = json.data(using: .utf8) else { return nil }
        return (try? JSONDecoder().decode([String: String].self, from: data))
    }

    /// Write one `named_limits` row per entry in `named`, all stamped with the
    /// same `timestamp` as the sibling `usage_history` row so the two can be
    /// joined on `(account_id, timestamp)` if ever needed.
    ///
    /// `named` is empty for every Anthropic reading today (the ping response
    /// never populates `RateLimitSnapshot.named`), so this is a silent no-op
    /// for those accounts — exactly the "zero named_limits rows" behavior the
    /// chart overlay depends on to stay hidden.
    // Pure function of its arguments — touches no instance/class main-actor
    // state.
    nonisolated static func insertNamedLimits(
        _ db: Connection,
        accountId: String,
        timestamp: String,
        named: [String: RateLimitWindow]
    ) {
        for (limitName, window) in named {
            do {
                try db.run("""
                    INSERT INTO named_limits (account_id, timestamp, limit_name, used_percent, window_seconds, reset_at)
                    VALUES (?, ?, ?, ?, ?, ?)
                """, accountId, timestamp, limitName, window.usedPercent,
                   window.durationSeconds, window.resetAtISO)
            } catch {
                FileLogger.shared.error(
                    "Failed to write named_limits row for \(limitName): \(error.localizedDescription)",
                    category: "DB"
                )
            }
        }
    }

    func loadFromDatabase() {
        do {
            if !FileManager.default.fileExists(atPath: dbPath) {
                ensureDatabase()
            }
            guard FileManager.default.fileExists(atPath: dbPath) else {
                error = "Could not create database."
                accounts = []
                return
            }

            let db = try openDatabase(dbPath)

            var loadedAccounts: [Account] = []

            let isoFormatter = ISO8601DateFormatter()
            isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let nowString = isoFormatter.string(from: Date())

            // Load accounts using raw SQL. `provider` is selected only when the
            // column exists, so a database that hasn't been migrated yet (an
            // external tool opened it first) still loads — every row then
            // resolves to the .anthropic fallback.
            let hasProvider = tableColumns(db, "accounts").contains("provider")
            let accountStmt = try db.prepare("""
                SELECT id, account_name, email, plan, last_updated\(hasProvider ? ", provider" : "")
                FROM accounts ORDER BY last_updated DESC
            """)

            for row in accountStmt {
                guard let accountId = row[0] as? String else { continue }
                let acctName = row[1] as? String
                let acctEmail = row[2] as? String
                let acctPlan = row[3] as? String
                let acctLastUpdated = row[4] as? String
                let acctProvider = AccountProvider(stored: hasProvider ? row[5] as? String : nil)

                // Get latest percent from usage_history
                var percent: Double? = nil
                let usageStmt = try db.prepare(
                    "SELECT primary_percent FROM usage_history WHERE account_id = ? AND timestamp <= ? ORDER BY timestamp DESC LIMIT 1"
                )
                for usageRow in usageStmt.bind(accountId, nowString) {
                    percent = usageRow[0] as? Double
                }

                let account = Account(
                    id: accountId,
                    provider: acctProvider,
                    accountName: acctName,
                    email: acctEmail,
                    plan: acctPlan,
                    lastUpdated: parseDate(acctLastUpdated),
                    latestPercent: percent
                )
                loadedAccounts.append(account)

                // Load latest usage for this account
                let latestStmt = try db.prepare(
                    "SELECT id, timestamp, primary_percent, session_percent, weekly_all_percent, weekly_sonnet_percent, session_reset, weekly_reset FROM usage_history WHERE account_id = ? AND timestamp <= ? ORDER BY timestamp DESC LIMIT 1"
                )
                for usageRow in latestStmt.bind(accountId, nowString) {
                    var record = UsageRecord(
                        id: (usageRow[0] as? Int64) ?? 0,
                        accountId: accountId,
                        timestamp: parseDate(usageRow[1] as? String) ?? Date(),
                        primaryPercent: usageRow[2] as? Double,
                        sessionPercent: usageRow[3] as? Double,
                        weeklyAllPercent: usageRow[4] as? Double,
                        weeklySONnetPercent: usageRow[5] as? Double,
                        sessionReset: usageRow[6] as? String,
                        weeklyReset: usageRow[7] as? String
                    )

                    // Premium/Fable allocation + overage come from the latest
                    // Fable probe snapshot's raw headers.
                    let fableStmt = try db.prepare(
                        "SELECT headers FROM probe_snapshots WHERE account_id = ? AND probe_model = 'fable' ORDER BY timestamp DESC LIMIT 1"
                    )
                    for probeRow in fableStmt.bind(accountId) {
                        guard let headersJSON = probeRow[0] as? String,
                              let headers = Self.parseHeaders(headersJSON) else { continue }
                        if let oi = Double(headers["anthropic-ratelimit-unified-7d_oi-utilization"] ?? "") {
                            record.fablePercent = oi * 100
                        }
                        if let ov = Double(headers["anthropic-ratelimit-unified-overage-utilization"] ?? "") {
                            record.overagePercent = ov * 100
                        }
                        record.overageStatus = headers["anthropic-ratelimit-unified-overage-status"]
                        record.overageDisabledReason = headers["anthropic-ratelimit-unified-overage-disabled-reason"]
                        record.overageInUse = headers["anthropic-ratelimit-unified-overage-in-use"] == "true"
                    }

                    latestUsage[accountId] = record
                }
            }

            self.accounts = loadedAccounts
            self.lastRefresh = Date()
            self.error = nil

            // Refresh primary account selection from settings (handles external DB edits)
            let savedPrimary = getSetting(Self.primaryAccountSettingKey)
            if self.primaryAccountId != savedPrimary {
                self.primaryAccountId = savedPrimary
            }

            self.onAccountsChanged?()

        } catch {
            FileLogger.shared.error("loadFromDatabase: \(error)", category: "DB")
            self.error = "Database error: \(error.localizedDescription)"
        }
    }

    func loadHistory(for accountId: String, daysBack: Int = 7, minChangePercent: Double = 1.0) -> [UsageDataPoint] {
        do {
            guard FileManager.default.fileExists(atPath: dbPath) else {
                return []
            }

            let db = try openDatabase(dbPath, readonly: true)

            // Calculate the cutoff date for time-based filtering
            let cutoffDate = Date().addingTimeInterval(-Double(daysBack) * 24 * 60 * 60)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let cutoffString = formatter.string(from: cutoffDate)

            let stmt = try db.prepare(
                "SELECT timestamp, weekly_all_percent FROM usage_history WHERE account_id = ? AND timestamp >= ? ORDER BY timestamp ASC"
            )

            var rawPoints: [(Date, Double)] = []

            for row in stmt.bind(accountId, cutoffString) {
                if let percent = row[1] as? Double,
                   let date = parseDate(row[0] as? String) {
                    rawPoints.append((date, percent))
                }
            }

            // Apply change filter to reduce data points while preserving chart shape
            var filteredPoints: [(Date, Double)] = []
            var lastKeptPercent: Double?

            for i in 0..<rawPoints.count {
                let (date, percent) = rawPoints[i]
                let isFirst = i == 0
                let isLast = i == rawPoints.count - 1

                if isFirst || isLast {
                    filteredPoints.append((date, percent))
                    lastKeptPercent = percent
                } else if let lastPercent = lastKeptPercent {
                    let changeFromPrev = abs(percent - lastPercent)
                    let nextPercent = rawPoints[i + 1].1
                    let changeToNext = abs(nextPercent - percent)

                    if changeFromPrev >= minChangePercent || changeToNext >= minChangePercent {
                        filteredPoints.append((date, percent))
                        lastKeptPercent = percent
                    }
                }
            }

            var dataPoints: [UsageDataPoint] = []
            for i in 0..<filteredPoints.count {
                let (date, percent) = filteredPoints[i]
                var delta: Double = 0
                if i > 0 {
                    let prevPercent = filteredPoints[i - 1].1
                    let diff = percent - prevPercent
                    delta = diff > 0 ? diff : 0
                }
                dataPoints.append(UsageDataPoint(
                    timestamp: date,
                    weeklyPercent: percent,
                    usageDelta: delta
                ))
            }

            return dataPoints

        } catch {
            print("Error loading history: \(error)")
            return []
        }
    }

    func loadFullHistory(for accountId: String, daysBack: Int = 7, minChangePercent: Double = 1.0) -> [FullUsageDataPoint] {
        do {
            guard FileManager.default.fileExists(atPath: dbPath) else {
                return []
            }

            let db = try openDatabase(dbPath, readonly: true)

            let cutoffDate = Date().addingTimeInterval(-Double(daysBack) * 24 * 60 * 60)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let cutoffString = formatter.string(from: cutoffDate)

            let stmt = try db.prepare(
                "SELECT timestamp, session_percent, weekly_all_percent FROM usage_history WHERE account_id = ? AND timestamp >= ? ORDER BY timestamp ASC"
            )

            var rawPoints: [FullUsageDataPoint] = []

            for row in stmt.bind(accountId, cutoffString) {
                if let date = parseDate(row[0] as? String) {
                    rawPoints.append(FullUsageDataPoint(
                        timestamp: date,
                        sessionPercent: row[1] as? Double,
                        weeklyAllPercent: row[2] as? Double
                    ))
                }
            }

            var filteredPoints: [FullUsageDataPoint] = []
            var lastKeptPercent: Double?

            for i in 0..<rawPoints.count {
                let point = rawPoints[i]
                let isFirst = i == 0
                let isLast = i == rawPoints.count - 1

                if isFirst || isLast {
                    filteredPoints.append(point)
                    lastKeptPercent = point.weeklyAllPercent
                } else if let currentPercent = point.weeklyAllPercent, let lastPercent = lastKeptPercent {
                    let changeFromPrev = abs(currentPercent - lastPercent)
                    let nextPercent = rawPoints[i + 1].weeklyAllPercent ?? currentPercent
                    let changeToNext = abs(nextPercent - currentPercent)

                    if changeFromPrev >= minChangePercent || changeToNext >= minChangePercent {
                        filteredPoints.append(point)
                        lastKeptPercent = currentPercent
                    }
                } else {
                    filteredPoints.append(point)
                }
            }

            return filteredPoints

        } catch {
            print("Error loading full history: \(error)")
            return []
        }
    }

    /// Named per-model / per-feature sub-limit history (`named_limits`),
    /// grouped by the provider-chosen `limit_name` — one time series per key,
    /// ascending by timestamp. Returns an empty dictionary for every account
    /// with no named limits (every Anthropic account today), which is what
    /// lets `UsageChartView` hide the overlay entirely rather than rendering
    /// an empty series.
    // Reads only the immutable `dbPath` and calls `parseDate` (also
    // `nonisolated`) — touches no @Published main-actor state, so it stays
    // callable from the (synchronous, non-UI) selftest suite.
    nonisolated func loadNamedLimitHistory(for accountId: String, daysBack: Int = 7) -> [String: [NamedLimitDataPoint]] {
        do {
            guard FileManager.default.fileExists(atPath: dbPath) else {
                return [:]
            }

            let db = try openDatabase(dbPath, readonly: true)
            guard tableColumns(db, "named_limits").contains("limit_name") else { return [:] }

            let cutoffDate = Date().addingTimeInterval(-Double(daysBack) * 24 * 60 * 60)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let cutoffString = formatter.string(from: cutoffDate)

            let stmt = try db.prepare("""
                SELECT limit_name, timestamp, used_percent FROM named_limits
                WHERE account_id = ? AND timestamp >= ?
                ORDER BY limit_name, timestamp ASC
            """)

            var result: [String: [NamedLimitDataPoint]] = [:]
            for row in stmt.bind(accountId, cutoffString) {
                guard let limitName = row[0] as? String,
                      let date = parseDate(row[1] as? String),
                      let percent = row[2] as? Double else { continue }
                result[limitName, default: []].append(NamedLimitDataPoint(timestamp: date, usedPercent: percent))
            }
            return result

        } catch {
            print("Error loading named limit history: \(error)")
            return [:]
        }
    }

    /// Load hourly token usage for an account from Claude Code data
    func loadTokenHistory(for accountId: String, daysBack: Int = 7) -> [TokenDataPoint] {
        do {
            guard FileManager.default.fileExists(atPath: dbPath) else {
                return []
            }

            let db = try openDatabase(dbPath, readonly: true)

            let cutoffDate = Date().addingTimeInterval(-Double(daysBack) * 24 * 60 * 60)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let cutoffString = formatter.string(from: cutoffDate)

            let sql = """
                SELECT
                    strftime('%Y-%m-%dT%H:00:00Z', tu.timestamp) as hour,
                    SUM(tu.input_tokens) as input_tokens,
                    SUM(tu.output_tokens) as output_tokens,
                    SUM(tu.cache_creation_tokens) as cache_creation_tokens,
                    SUM(tu.cache_read_tokens) as cache_read_tokens
                FROM token_usage tu
                JOIN token_sessions ts ON tu.session_id = ts.session_id
                WHERE COALESCE(ts.override_account_id, ts.inferred_account_id) = ?
                  AND tu.timestamp >= ?
                GROUP BY hour
                ORDER BY hour ASC
            """

            var dataPoints: [TokenDataPoint] = []
            let statement = try db.prepare(sql)

            for row in statement.bind(accountId, cutoffString) {
                if let hourStr = row[0] as? String,
                   let date = parseDate(hourStr) {
                    let inputTokens = (row[1] as? Int64) ?? 0
                    let outputTokens = (row[2] as? Int64) ?? 0
                    let cacheCreationTokens = (row[3] as? Int64) ?? 0
                    let cacheReadTokens = (row[4] as? Int64) ?? 0

                    dataPoints.append(TokenDataPoint(
                        timestamp: date,
                        inputTokens: inputTokens,
                        outputTokens: outputTokens,
                        cacheCreationTokens: cacheCreationTokens,
                        cacheReadTokens: cacheReadTokens
                    ))
                }
            }

            return dataPoints

        } catch {
            print("Error loading token history: \(error)")
            return []
        }
    }

    /// Load daily token summaries for an account
    func loadDailyTokenSummary(for accountId: String, daysBack: Int = 7) -> [DailyTokenSummary] {
        do {
            guard FileManager.default.fileExists(atPath: dbPath) else {
                return []
            }

            let db = try openDatabase(dbPath, readonly: true)

            let cutoffDate = Date().addingTimeInterval(-Double(daysBack) * 24 * 60 * 60)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let cutoffString = formatter.string(from: cutoffDate)

            let sql = """
                SELECT
                    date(tu.timestamp) as day,
                    SUM(tu.input_tokens) as input_tokens,
                    SUM(tu.output_tokens) as output_tokens,
                    SUM(tu.cache_creation_tokens) as cache_creation_tokens,
                    SUM(tu.cache_read_tokens) as cache_read_tokens,
                    COUNT(*) as message_count
                FROM token_usage tu
                JOIN token_sessions ts ON tu.session_id = ts.session_id
                WHERE COALESCE(ts.override_account_id, ts.inferred_account_id) = ?
                  AND tu.timestamp >= ?
                GROUP BY day
                ORDER BY day DESC
            """

            var summaries: [DailyTokenSummary] = []
            let statement = try db.prepare(sql)

            let dayFormatter = DateFormatter()
            dayFormatter.dateFormat = "yyyy-MM-dd"
            dayFormatter.timeZone = TimeZone(identifier: "UTC")

            for row in statement.bind(accountId, cutoffString) {
                if let dayStr = row[0] as? String,
                   let date = dayFormatter.date(from: dayStr) {
                    summaries.append(DailyTokenSummary(
                        day: date,
                        accountId: accountId,
                        inputTokens: (row[1] as? Int64) ?? 0,
                        outputTokens: (row[2] as? Int64) ?? 0,
                        cacheCreationTokens: (row[3] as? Int64) ?? 0,
                        cacheReadTokens: (row[4] as? Int64) ?? 0,
                        messageCount: (row[5] as? Int64) ?? 0
                    ))
                }
            }

            return summaries

        } catch {
            print("Error loading daily token summary: \(error)")
            return []
        }
    }

    /// Check if token data exists for an account
    func hasTokenData(for accountId: String) -> Bool {
        do {
            guard FileManager.default.fileExists(atPath: dbPath) else {
                return false
            }

            let db = try openDatabase(dbPath, readonly: true)

            let sql = """
                SELECT COUNT(*) FROM token_sessions
                WHERE COALESCE(override_account_id, inferred_account_id) = ?
            """

            let statement = try db.prepare(sql)
            for row in statement.bind(accountId) {
                if let count = row[0] as? Int64 {
                    return count > 0
                }
            }
            return false

        } catch {
            print("Error checking token data: \(error)")
            return false
        }
    }

    /// Set a custom alias for an account. Pass `nil` to clear the alias and
    /// fall back to the email/id default.
    func updateAccountName(accountId: String, newName: String?) {
        do {
            guard FileManager.default.fileExists(atPath: dbPath) else {
                return
            }

            let db = try openDatabase(dbPath)
            try db.run("UPDATE accounts SET account_name = ? WHERE id = ?", newName, accountId)

            // Backfill email from a well-formed label — an account renamed to
            // its real address must not keep email = NULL indefinitely just
            // because a profile fetch never populated it (#15). Never
            // overwrites an existing email.
            var backfilledEmail: String?
            if let newName, looksLikeEmailAddress(newName) {
                try db.run("UPDATE accounts SET email = COALESCE(email, ?) WHERE id = ?", newName, accountId)
                backfilledEmail = try db.scalar("SELECT email FROM accounts WHERE id = ?", accountId) as? String
            }

            // Immediately update local state for instant UI feedback
            if let index = accounts.firstIndex(where: { $0.id == accountId }) {
                let oldAccount = accounts[index]
                let updatedAccount = Account(
                    id: oldAccount.id,
                    provider: oldAccount.provider,
                    accountName: newName,
                    email: backfilledEmail ?? oldAccount.email,
                    plan: oldAccount.plan,
                    lastUpdated: oldAccount.lastUpdated,
                    latestPercent: oldAccount.latestPercent
                )
                accounts[index] = updatedAccount
                onAccountsChanged?()
            }

        } catch {
            DispatchQueue.main.async {
                self.error = "Failed to update account name: \(error.localizedDescription)"
            }
        }
    }

    func clearAccountData(accountId: String) {
        do {
            guard FileManager.default.fileExists(atPath: dbPath) else {
                return
            }

            let db = try openDatabase(dbPath)

            // Delete usage history for this account, then the account itself
            try db.run("DELETE FROM usage_history WHERE account_id = ?", accountId)
            try db.run("DELETE FROM accounts WHERE id = ?", accountId)

            // Reload to reflect the change
            loadFromDatabase()

        } catch {
            DispatchQueue.main.async {
                self.error = "Failed to clear account data: \(error.localizedDescription)"
            }
        }
    }

    func clearDatabase() {
        do {
            if FileManager.default.fileExists(atPath: dbPath) {
                try FileManager.default.removeItem(atPath: dbPath)
            }
            DispatchQueue.main.async {
                self.accounts = []
                self.latestUsage = [:]
                self.lastRefresh = nil
                self.error = nil
            }
        } catch {
            DispatchQueue.main.async {
                self.error = "Failed to clear database: \(error.localizedDescription)"
            }
        }
    }

    // Pure function of its argument — touches no @Published main-actor state.
    private nonisolated func parseDate(_ string: String?) -> Date? {
        guard let string = string else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }

    /// Get a setting value from the database
    func getSetting(_ key: String) -> String? {
        do {
            guard FileManager.default.fileExists(atPath: dbPath) else {
                return nil
            }

            let db = try openDatabase(dbPath, readonly: true)
            return try db.scalar("SELECT value FROM settings WHERE key = ?", key) as? String
        } catch {
            print("Error reading setting: \(error)")
            return nil
        }
    }

    /// Set a setting value in the database (M3.3)
    func setSetting(_ key: String, value: String?) {
        do {
            guard FileManager.default.fileExists(atPath: dbPath) else { return }
            let db = try openDatabase(dbPath)
            if let value = value {
                try db.run("""
                    INSERT INTO settings (key, value) VALUES (?, ?)
                    ON CONFLICT(key) DO UPDATE SET value = excluded.value
                """, key, value)
            } else {
                try db.run("DELETE FROM settings WHERE key = ?", key)
            }
        } catch {
            print("Error writing setting: \(error)")
        }
    }

}

// MARK: - Update Checker

struct AppVersion {
    static let current = "1.18.3"
    static let repoOwner = "rjwalters"
    static let repoName = "claude-monitor"
}

struct UpdateInfo {
    let version: String
    let releaseURL: String
}

// Only ever instantiated from a SwiftUI `@StateObject` in the macOS-only
// chart window (UsageChartView.swift), so @MainActor isolation matches the
// only actual caller rather than papering over the diagnostic.
@MainActor
class UpdateChecker: ObservableObject {
    @Published var updateAvailable: UpdateInfo?
    @Published var isChecking = false

    static let shared = UpdateChecker()

    func checkForUpdates() {
        guard !isChecking else { return }
        isChecking = true

        let urlString = "https://api.github.com/repos/\(AppVersion.repoOwner)/\(AppVersion.repoName)/releases/latest"
        guard let url = URL(string: urlString) else {
            isChecking = false
            return
        }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                self?.isChecking = false

                guard let data = data, error == nil else { return }

                do {
                    if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let tagName = json["tag_name"] as? String,
                       let htmlURL = json["html_url"] as? String {
                        let latestVersion = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName

                        if self?.isNewerVersion(latestVersion, than: AppVersion.current) == true {
                            self?.updateAvailable = UpdateInfo(version: latestVersion, releaseURL: htmlURL)
                        }
                    }
                } catch {
                    print("Failed to parse release info: \(error)")
                }
            }
        }.resume()
    }

    private func isNewerVersion(_ new: String, than current: String) -> Bool {
        let newParts = new.split(separator: ".").compactMap { Int($0) }
        let currentParts = current.split(separator: ".").compactMap { Int($0) }

        for i in 0..<max(newParts.count, currentParts.count) {
            let newPart = i < newParts.count ? newParts[i] : 0
            let currentPart = i < currentParts.count ? currentParts[i] : 0

            if newPart > currentPart { return true }
            if newPart < currentPart { return false }
        }
        return false
    }
}
