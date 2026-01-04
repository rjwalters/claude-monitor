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

    func loadFromDatabase() {
        do {
            guard FileManager.default.fileExists(atPath: dbPath) else {
                error = "Database not found. Install the Firefox extension first."
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
            // Keep a point if EITHER:
            // - Change from last kept point is >= threshold, OR
            // - Change to next point is >= threshold (preserves reset points)
            var filteredPoints: [(Date, Double)] = []
            var lastKeptPercent: Double?

            for i in 0..<rawPoints.count {
                let (date, percent) = rawPoints[i]
                let isFirst = i == 0
                let isLast = i == rawPoints.count - 1

                if isFirst || isLast {
                    // Always keep first and last points
                    filteredPoints.append((date, percent))
                    lastKeptPercent = percent
                } else if let lastPercent = lastKeptPercent {
                    let changeFromPrev = abs(percent - lastPercent)
                    let nextPercent = rawPoints[i + 1].1
                    let changeToNext = abs(nextPercent - percent)

                    // Keep if either transition is significant
                    if changeFromPrev >= minChangePercent || changeToNext >= minChangePercent {
                        filteredPoints.append((date, percent))
                        lastKeptPercent = percent
                    }
                }
            }

            // Calculate deltas (usage consumed = increase in percentage)
            // Synthetic reset points are now stored in the database, so they'll be
            // loaded naturally and create vertical lines on the chart
            var dataPoints: [UsageDataPoint] = []
            for i in 0..<filteredPoints.count {
                let (date, percent) = filteredPoints[i]
                var delta: Double = 0
                if i > 0 {
                    let prevPercent = filteredPoints[i - 1].1
                    let diff = percent - prevPercent
                    // Only count increases as usage (resets show as drops, synthetic points handle visualization)
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

            // Calculate the cutoff date for time-based filtering
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

            // Apply change filter based on weeklyAllPercent to reduce data points
            // Keep a point if EITHER:
            // - Change from last kept point is >= threshold, OR
            // - Change to next point is >= threshold (preserves reset points)
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

                    // Keep if either transition is significant
                    if changeFromPrev >= minChangePercent || changeToNext >= minChangePercent {
                        filteredPoints.append(point)
                        lastKeptPercent = currentPercent
                    }
                } else {
                    // Keep points with nil percent values to avoid losing data
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

            // Calculate the cutoff date
            let cutoffDate = Date().addingTimeInterval(-Double(daysBack) * 24 * 60 * 60)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let cutoffString = formatter.string(from: cutoffDate)

            // Query hourly aggregated token usage for this account
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

            // Reload to reflect the change
            loadFromDatabase()

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

            // Reload to reflect the change
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

    /// Get the last browser that sent data (firefox or chrome)
    var lastBrowser: String {
        getSetting("last_browser") ?? "firefox"
    }

    /// Open all accounts - first account in default browser, others in private windows
    func openAllAccounts() {
        guard !accounts.isEmpty else { return }
        guard accounts.count > 1 else {
            // Only one account, just open usage page
            if let url = URL(string: "https://claude.ai/settings/usage") {
                NSWorkspace.shared.open(url)
            }
            return
        }

        let browser = lastBrowser

        // Show setup hint for first few uses
        let hintKey = "openAllAccountsHintCount"
        let hintCount = UserDefaults.standard.integer(forKey: hintKey)
        if hintCount < 3 {
            UserDefaults.standard.set(hintCount + 1, forKey: hintKey)
            showPrivateWindowHint(browser: browser)
        }

        // Open first account's usage page in default browser
        if let url = URL(string: "https://claude.ai/settings/usage") {
            NSWorkspace.shared.open(url)
        }

        // Open private windows for remaining accounts (to login page)
        for (index, account) in accounts.enumerated() {
            guard index > 0 else { continue }

            openPrivateWindow(browser: browser, accountName: account.displayName)
        }
    }

    /// Show a hint about enabling extension in private windows
    private func showPrivateWindowHint(browser: String) {
        let alert = NSAlert()
        alert.messageText = "Enable Extension in Private Windows"
        alert.informativeText = """
            To see which account to log into, enable the extension in private/incognito windows:

            \(browser == "chrome" ? "Chrome" : "Firefox"): Extensions → Claude Usage Monitor → \(browser == "chrome" ? "Allow in Incognito" : "Run in Private Windows")

            This message will show \(3 - UserDefaults.standard.integer(forKey: "openAllAccountsHintCount")) more time(s).
            """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// Open a private browser window to Claude login page
    private func openPrivateWindow(browser: String, accountName: String) {
        // Pass account name via URL fragment so the extension can show a toast
        let encodedName = accountName.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? accountName
        let url = "https://claude.ai/login#cm_account=\(encodedName)"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")

        switch browser {
        case "chrome":
            process.arguments = ["-na", "Google Chrome", "--args", "--incognito", url]
        case "firefox":
            fallthrough
        default:
            process.arguments = ["-na", "Firefox", "--args", "-private-window", url]
        }

        do {
            try process.run()
        } catch {
            print("Failed to open private window: \(error)")
        }
    }
}

// MARK: - Update Checker

struct AppVersion {
    static let current = "1.7.0"
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
