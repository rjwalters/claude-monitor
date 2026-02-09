import Foundation
import SQLite
import AppKit

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

    /// Called when accounts change (e.g., reordering) so the menubar can update
    var onAccountsChanged: (() -> Void)?

    private let dbPath: String

    init() {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        dbPath = homeDir.appendingPathComponent(".claude-monitor/usage.db").path
    }

    // MARK: - Primary Account (M3.3)

    /// The account ID shown in the menubar badge
    var primaryAccountId: String? {
        get { getSetting("primary_account_id") }
        set { setSetting("primary_account_id", value: newValue) }
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
            let db = try Connection(dbPath)
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
                CREATE INDEX IF NOT EXISTS idx_usage_account ON usage_history(account_id);
                CREATE INDEX IF NOT EXISTS idx_usage_timestamp ON usage_history(timestamp DESC);
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
            print("Failed to create database: \(error)")
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

            let db = try Connection(dbPath, readonly: true)

            // Load accounts
            let accountsTable = Table("accounts")
            let id = SQLite.Expression<String>("id")
            let accountName = SQLite.Expression<String?>("account_name")
            let email = SQLite.Expression<String?>("email")
            let plan = SQLite.Expression<String?>("plan")
            let lastUpdated = SQLite.Expression<String?>("last_updated")
            let sortOrder = SQLite.Expression<Int?>("sort_order")

            var loadedAccounts: [Account] = []

            // Prepare timestamp filter to exclude future timestamps (safety check)
            let isoFormatter = ISO8601DateFormatter()
            isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let nowString = isoFormatter.string(from: Date())

            // Order by sort_order ascending, then last_updated descending
            let query = accountsTable.order(sortOrder.asc, lastUpdated.desc)
            for row in try db.prepare(query) {
                let accountId = row[id]

                // Get latest percent from usage_history
                let usageTable = Table("usage_history")
                let primaryPercent = SQLite.Expression<Double?>("primary_percent")
                let accountIdCol = SQLite.Expression<String>("account_id")
                let timestamp = SQLite.Expression<String>("timestamp")

                let latestQuery = usageTable
                    .filter(accountIdCol == accountId && timestamp <= nowString)
                    .order(timestamp.desc)
                    .limit(1)

                var percent: Double? = nil
                if let usageRow = try db.pluck(latestQuery) {
                    percent = usageRow[primaryPercent]
                }

                let account = Account(
                    id: accountId,
                    accountName: row[accountName],
                    email: row[email],
                    plan: row[plan],
                    lastUpdated: parseDate(row[lastUpdated]),
                    latestPercent: percent
                )
                loadedAccounts.append(account)

                // Load latest usage for this account
                if let usageRow = try db.pluck(latestQuery) {
                    let sessionPercent = SQLite.Expression<Double?>("session_percent")
                    let weeklyAllPercent = SQLite.Expression<Double?>("weekly_all_percent")
                    let weeklySONnetPercent = SQLite.Expression<Double?>("weekly_sonnet_percent")
                    let sessionReset = SQLite.Expression<String?>("session_reset")
                    let weeklyReset = SQLite.Expression<String?>("weekly_reset")
                    let rowId = SQLite.Expression<Int64>("id")

                    let record = UsageRecord(
                        id: usageRow[rowId],
                        accountId: accountId,
                        timestamp: parseDate(usageRow[timestamp]) ?? Date(),
                        primaryPercent: usageRow[primaryPercent],
                        sessionPercent: usageRow[sessionPercent],
                        weeklyAllPercent: usageRow[weeklyAllPercent],
                        weeklySONnetPercent: usageRow[weeklySONnetPercent],
                        sessionReset: usageRow[sessionReset],
                        weeklyReset: usageRow[weeklyReset]
                    )
                    latestUsage[accountId] = record
                }
            }

            DispatchQueue.main.async {
                self.accounts = loadedAccounts
                self.lastRefresh = Date()
                self.error = nil
                self.onAccountsChanged?()
            }

        } catch {
            DispatchQueue.main.async {
                self.error = "Database error: \(error.localizedDescription)"
            }
        }
    }

    func loadHistory(for accountId: String, daysBack: Int = 7, minChangePercent: Double = 1.0) -> [UsageDataPoint] {
        do {
            guard FileManager.default.fileExists(atPath: dbPath) else {
                return []
            }

            let db = try Connection(dbPath, readonly: true)
            let usageTable = Table("usage_history")
            let accountIdCol = SQLite.Expression<String>("account_id")
            let timestamp = SQLite.Expression<String>("timestamp")
            let weeklyAllPercent = SQLite.Expression<Double?>("weekly_all_percent")

            // Calculate the cutoff date for time-based filtering
            let cutoffDate = Date().addingTimeInterval(-Double(daysBack) * 24 * 60 * 60)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let cutoffString = formatter.string(from: cutoffDate)

            let query = usageTable
                .filter(accountIdCol == accountId && timestamp >= cutoffString)
                .order(timestamp.asc)

            var rawPoints: [(Date, Double)] = []

            for row in try db.prepare(query) {
                if let percent = row[weeklyAllPercent],
                   let date = parseDate(row[timestamp]) {
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

            let db = try Connection(dbPath, readonly: true)
            let usageTable = Table("usage_history")
            let accountIdCol = SQLite.Expression<String>("account_id")
            let timestamp = SQLite.Expression<String>("timestamp")
            let sessionPercent = SQLite.Expression<Double?>("session_percent")
            let weeklyAllPercent = SQLite.Expression<Double?>("weekly_all_percent")

            let cutoffDate = Date().addingTimeInterval(-Double(daysBack) * 24 * 60 * 60)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let cutoffString = formatter.string(from: cutoffDate)

            let query = usageTable
                .filter(accountIdCol == accountId && timestamp >= cutoffString)
                .order(timestamp.asc)

            var rawPoints: [FullUsageDataPoint] = []

            for row in try db.prepare(query) {
                if let date = parseDate(row[timestamp]) {
                    rawPoints.append(FullUsageDataPoint(
                        timestamp: date,
                        sessionPercent: row[sessionPercent],
                        weeklyAllPercent: row[weeklyAllPercent]
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

            let db = try Connection(dbPath, readonly: true)

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

            let db = try Connection(dbPath, readonly: true)

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

            let db = try Connection(dbPath, readonly: true)

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

    func updateAccountName(accountId: String, newName: String) {
        do {
            guard FileManager.default.fileExists(atPath: dbPath) else {
                return
            }

            let db = try Connection(dbPath)
            let accountsTable = Table("accounts")
            let id = SQLite.Expression<String>("id")
            let accountName = SQLite.Expression<String?>("account_name")

            let account = accountsTable.filter(id == accountId)
            try db.run(account.update(accountName <- newName))

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

    func moveAccountToTop(accountId: String) {
        do {
            guard FileManager.default.fileExists(atPath: dbPath) else {
                return
            }

            let db = try Connection(dbPath)
            let accountsTable = Table("accounts")
            let id = SQLite.Expression<String>("id")
            let sortOrder = SQLite.Expression<Int?>("sort_order")

            // Get current accounts in order
            let query = accountsTable.order(sortOrder.asc)
            var accountIds: [String] = []
            for row in try db.prepare(query) {
                accountIds.append(row[id])
            }

            // Find and move target to front
            guard let targetIndex = accountIds.firstIndex(of: accountId) else {
                return
            }

            // Already at top, no need to reorder
            if targetIndex == 0 {
                return
            }

            // Reorder: move target to front
            let targetId = accountIds.remove(at: targetIndex)
            accountIds.insert(targetId, at: 0)

            // Update all sort orders
            for (index, accId) in accountIds.enumerated() {
                let account = accountsTable.filter(id == accId)
                try db.run(account.update(sortOrder <- index))
            }

            // Also set as primary account (M3.5)
            primaryAccountId = accountId

            // Immediately update local state for instant UI feedback
            if let localIndex = accounts.firstIndex(where: { $0.id == accountId }) {
                let movedAccount = accounts.remove(at: localIndex)
                accounts.insert(movedAccount, at: 0)
                onAccountsChanged?()
            }

            // Reload to get any other database changes
            loadFromDatabase()

        } catch {
            DispatchQueue.main.async {
                self.error = "Failed to reorder account: \(error.localizedDescription)"
            }
        }
    }

    func clearAccountData(accountId: String) {
        do {
            guard FileManager.default.fileExists(atPath: dbPath) else {
                return
            }

            let db = try Connection(dbPath)

            // Delete usage history for this account
            let usageTable = Table("usage_history")
            let accountIdCol = SQLite.Expression<String>("account_id")
            try db.run(usageTable.filter(accountIdCol == accountId).delete())

            // Delete the account
            let accountsTable = Table("accounts")
            let id = SQLite.Expression<String>("id")
            try db.run(accountsTable.filter(id == accountId).delete())

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

            let db = try Connection(dbPath, readonly: true)
            let settingsTable = Table("settings")
            let keyCol = SQLite.Expression<String>("key")
            let valueCol = SQLite.Expression<String?>("value")

            let query = settingsTable.filter(keyCol == key)
            if let row = try db.pluck(query) {
                return row[valueCol]
            }
            return nil
        } catch {
            print("Error reading setting: \(error)")
            return nil
        }
    }

    /// Set a setting value in the database (M3.3)
    func setSetting(_ key: String, value: String?) {
        do {
            guard FileManager.default.fileExists(atPath: dbPath) else { return }
            let db = try Connection(dbPath)
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

    /// Check if native host manifests exist (for migration notice M5.3)
    var hasNativeHostManifests: Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let firefoxPath = home
            .appendingPathComponent("Library/Application Support/Mozilla/NativeMessagingHosts/claude_monitor.json")
        let chromePath = home
            .appendingPathComponent("Library/Application Support/Google/Chrome/NativeMessagingHosts/claude_monitor.json")
        return FileManager.default.fileExists(atPath: firefoxPath.path)
            || FileManager.default.fileExists(atPath: chromePath.path)
    }
}

// MARK: - Update Checker

struct AppVersion {
    static let current = "2.0.0"
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
