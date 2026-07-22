import Foundation
import AppKit

/// Opens a SQLite connection with a busy timeout so concurrent access from
/// other processes waits briefly for locks instead of failing immediately.
func openDatabase(_ path: String, readonly: Bool = false) throws -> Connection {
    let db = try Connection(path, readonly: readonly)
    db.busyTimeout = 5
    return db
}

struct Account: Identifiable {
    let id: String
    let accountName: String?
    let email: String?
    let plan: String?
    let lastUpdated: Date?
    let latestPercent: Double?

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

    /// Remaining Fable allocation 0–100, or nil if unknown.
    var fableRemaining: Double? {
        fablePercent.map { max(0, 100 - $0) }
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

class UsageStore: ObservableObject {
    @Published var accounts: [Account] = []
    @Published var latestUsage: [String: UsageRecord] = [:]
    @Published var lastRefresh: Date?
    @Published var error: String?
    /// Account chosen by the user to drive the menubar icon. `nil` = auto (most-available).
    @Published var primaryAccountId: String?

    /// Called when accounts change (e.g., reordering, primary selection) so the menubar can update
    var onAccountsChanged: (() -> Void)?

    private static let primaryAccountSettingKey = "primary_account_id"

    private let dbPath: String

    init() {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        dbPath = homeDir.appendingPathComponent(".claude-monitor/usage.db").path
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
            try db.execute("""
                CREATE TABLE IF NOT EXISTS accounts (
                    id TEXT PRIMARY KEY,
                    account_name TEXT,
                    email TEXT,
                    plan TEXT,
                    last_updated TEXT,
                    sort_order INTEGER DEFAULT 0
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
                CREATE INDEX IF NOT EXISTS idx_usage_account ON usage_history(account_id);
                CREATE INDEX IF NOT EXISTS idx_usage_timestamp ON usage_history(timestamp DESC);
                CREATE INDEX IF NOT EXISTS idx_probe_account_time ON probe_snapshots(account_id, timestamp DESC);
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
                    FOREIGN KEY (account_id) REFERENCES accounts(id)
                );
            """)
        } catch {
            FileLogger.shared.error("Failed to create database: \(error)", category: "DB")
        }
    }

    /// Seconds until reset (session first, then weekly). Returns large value if unknown.
    static func resetSeconds(_ usage: UsageRecord?) -> TimeInterval {
        guard let usage = usage else { return .greatestFiniteMagnitude }
        for str in [usage.sessionReset, usage.weeklyReset].compactMap({ $0 }) {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = iso.date(from: str) ?? ISO8601DateFormatter().date(from: str) {
                return date.timeIntervalSinceNow
            }
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
    var sortedAccountsForPopover: [Account] {
        let pairs = accounts.map { account in
            (account: account, usage: latestUsage[account.id])
        }
        let sorted = pairs.sorted { a, b in
            let aEffective = max(a.usage?.sessionPercent ?? 0, a.usage?.weeklyAllPercent ?? 0)
            let bEffective = max(b.usage?.sessionPercent ?? 0, b.usage?.weeklyAllPercent ?? 0)
            if aEffective != bEffective { return aEffective < bEffective }
            return UsageStore.resetSeconds(a.usage) < UsageStore.resetSeconds(b.usage)
        }
        return sorted.map { $0.account }
    }

    /// Decode a `probe_snapshots.headers` JSON blob into a [String:String] map.
    static func parseHeaders(_ json: String) -> [String: String]? {
        guard let data = json.data(using: .utf8) else { return nil }
        return (try? JSONDecoder().decode([String: String].self, from: data))
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

            // Load accounts using raw SQL
            let accountStmt = try db.prepare(
                "SELECT id, account_name, email, plan, last_updated FROM accounts ORDER BY last_updated DESC"
            )

            for row in accountStmt {
                guard let accountId = row[0] as? String else { continue }
                let acctName = row[1] as? String
                let acctEmail = row[2] as? String
                let acctPlan = row[3] as? String
                let acctLastUpdated = row[4] as? String

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

            // Immediately update local state for instant UI feedback
            if let index = accounts.firstIndex(where: { $0.id == accountId }) {
                let oldAccount = accounts[index]
                let updatedAccount = Account(
                    id: oldAccount.id,
                    accountName: newName,
                    email: oldAccount.email,
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

    private func parseDate(_ string: String?) -> Date? {
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
    static let current = "1.15.0"
    static let repoOwner = "rjwalters"
    static let repoName = "claude-monitor"
}

struct UpdateInfo {
    let version: String
    let releaseURL: String
}

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
