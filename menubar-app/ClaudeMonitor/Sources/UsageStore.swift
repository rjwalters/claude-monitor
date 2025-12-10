import Foundation
import SQLite

struct Account: Identifiable {
    let id: String
    let email: String?
    let plan: String?
    let lastUpdated: Date?
    let latestPercent: Double?
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

class UsageStore: ObservableObject {
    @Published var accounts: [Account] = []
    @Published var latestUsage: [String: UsageRecord] = [:]
    @Published var lastRefresh: Date?
    @Published var error: String?

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
            let email = SQLite.Expression<String?>("email")
            let plan = SQLite.Expression<String?>("plan")
            let lastUpdated = SQLite.Expression<String?>("last_updated")

            var loadedAccounts: [Account] = []

            for row in try db.prepare(accountsTable) {
                let accountId = row[id]

                // Get latest percent from usage_history
                let usageTable = Table("usage_history")
                let primaryPercent = SQLite.Expression<Double?>("primary_percent")
                let accountIdCol = SQLite.Expression<String>("account_id")
                let timestamp = SQLite.Expression<String>("timestamp")

                let latestQuery = usageTable
                    .filter(accountIdCol == accountId)
                    .order(timestamp.desc)
                    .limit(1)

                var percent: Double? = nil
                if let usageRow = try db.pluck(latestQuery) {
                    percent = usageRow[primaryPercent]
                }

                let account = Account(
                    id: accountId,
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
            }

        } catch {
            DispatchQueue.main.async {
                self.error = "Database error: \(error.localizedDescription)"
            }
        }
    }

    func loadHistory(for accountId: String, limit: Int = 500) -> [UsageDataPoint] {
        do {
            guard FileManager.default.fileExists(atPath: dbPath) else {
                return []
            }

            let db = try Connection(dbPath, readonly: true)
            let usageTable = Table("usage_history")
            let accountIdCol = SQLite.Expression<String>("account_id")
            let timestamp = SQLite.Expression<String>("timestamp")
            let weeklyAllPercent = SQLite.Expression<Double?>("weekly_all_percent")

            let query = usageTable
                .filter(accountIdCol == accountId)
                .order(timestamp.desc)
                .limit(limit)

            var rawPoints: [(Date, Double)] = []

            for row in try db.prepare(query) {
                if let percent = row[weeklyAllPercent],
                   let date = parseDate(row[timestamp]) {
                    rawPoints.append((date, percent))
                }
            }

            // Reverse to chronological order
            rawPoints.reverse()

            // Calculate deltas (usage consumed = increase in percentage)
            var dataPoints: [UsageDataPoint] = []
            for i in 0..<rawPoints.count {
                let (date, percent) = rawPoints[i]
                var delta: Double = 0
                if i > 0 {
                    let prevPercent = rawPoints[i - 1].1
                    // If percent went up, that's usage. If it went down (reset), ignore
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

    private func parseDate(_ string: String?) -> Date? {
        guard let string = string else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }
}
