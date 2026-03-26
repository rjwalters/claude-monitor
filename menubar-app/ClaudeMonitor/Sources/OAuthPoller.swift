import Foundation
import SQLite
import os

private let logger = Logger(subsystem: "com.claude-monitor.app", category: "OAuthPoller")
private let flog = FileLogger.shared
private let fcat = "OAuth"

// MARK: - Token Status

enum TokenStatus: String {
    case valid
    case expired
    case refreshing
    case missing
    case revoked
    case error
}

struct CredentialStatus: Identifiable {
    let id: Int64
    let label: String
    let accountId: String?
    var status: TokenStatus
    var lastPoll: Date?
    var lastError: String?
}

struct OAuthCredential {
    let id: Int64?
    let accountId: String?
    let label: String
    let source: String  // "token" or "env"
    let accessToken: String?
    let refreshToken: String?
    let expiresAt: Int64?  // epoch ms
    let subscriptionType: String?
    let rateLimitTier: String?
    let isActive: Bool
}

struct EnvImportResult {
    let email: String
    let success: Bool
    let error: String?
}

class OAuthPoller: ObservableObject {
    private let apiClient = AnthropicAPIClient()
    @Published var lastError: String?
    @Published var credentialStatuses: [CredentialStatus] = []

    private var dbPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude-monitor/usage.db").path
    }

    // MARK: - Add Account with Token

    /// Validate a token via a ping, identify org via headers, create/update the account.
    /// Returns the account org ID on success. If email is provided (e.g. from .env), it's stored.
    func addAccountWithToken(_ token: String, email: String? = nil) async -> (orgId: String?, error: String?) {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            return (nil, "Token is empty")
        }

        // Ping to get org ID and current usage
        let ping: PingResponse
        do {
            ping = try await apiClient.pingToken(accessToken: token)
        } catch {
            // Fall back to count_tokens for identification (no quota cost)
            do {
                let orgId = try await apiClient.identifyToken(accessToken: token)
                saveCredentialForAccount(
                    accountId: orgId, email: email, orgName: nil, plan: "Max",
                    accessToken: token, source: "token"
                )
                flog.info("addAccountWithToken: identified via count_tokens — org \(orgId)", category: fcat)
                return (orgId, nil)
            } catch {
                flog.error("addAccountWithToken: both ping and identify failed: \(error.localizedDescription)", category: fcat)
                return (nil, "Invalid token: \(error.localizedDescription)")
            }
        }

        let orgId = ping.organizationId
        guard !orgId.isEmpty else {
            return (nil, "Could not identify account from token")
        }

        flog.info("addAccountWithToken: org \(orgId), session: \(Int(ping.sessionPercent))%, weekly: \(Int(ping.weeklyPercent))%", category: fcat)

        // Save credential and account
        saveCredentialForAccount(
            accountId: orgId, email: email, orgName: nil, plan: "Max",
            accessToken: token, source: "token"
        )

        // Write the usage data we got from the ping
        writePingToDB(accountId: orgId, ping: ping)

        return (orgId, nil)
    }

    // MARK: - Import from .env File

    /// Parse a .env file for ACCOUNT_EMAIL_N / ACCOUNT_KEY_N pairs and import each.
    func importFromEnvFile(url: URL) async -> [EnvImportResult] {
        let content: String
        do {
            content = try String(contentsOf: url, encoding: .utf8)
        } catch {
            flog.error("importFromEnvFile: could not read file: \(error.localizedDescription)", category: fcat)
            return [EnvImportResult(email: url.lastPathComponent, success: false, error: "Could not read file")]
        }

        return await importFromEnvString(content)
    }

    /// Parse an env string for ACCOUNT_EMAIL_N / ACCOUNT_KEY_N pairs and import each.
    func importFromEnvString(_ content: String) async -> [EnvImportResult] {
        // Parse all KEY=VALUE pairs
        var env: [String: String] = [:]
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            guard let eqIndex = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[trimmed.startIndex..<eqIndex]).trimmingCharacters(in: .whitespaces)
            let value = String(trimmed[trimmed.index(after: eqIndex)...]).trimmingCharacters(in: .whitespaces)
            env[key] = value
        }

        // Find numbered account pairs: ACCOUNT_EMAIL_N + ACCOUNT_KEY_N
        var accounts: [(index: Int, email: String, token: String)] = []
        for i in 1...99 {
            guard let email = env["ACCOUNT_EMAIL_\(i)"],
                  let token = env["ACCOUNT_KEY_\(i)"] else {
                continue  // Skip gaps — files may have non-consecutive numbering
            }
            accounts.append((index: i, email: email, token: token))
        }

        if accounts.isEmpty {
            flog.warning("importFromEnvFile: no ACCOUNT_EMAIL_N/ACCOUNT_KEY_N pairs found", category: fcat)
            return [EnvImportResult(email: "—", success: false, error: "No ACCOUNT_EMAIL_N / ACCOUNT_KEY_N pairs found in file")]
        }

        flog.info("importFromEnvFile: found \(accounts.count) account(s)", category: fcat)

        var results: [EnvImportResult] = []
        for account in accounts {
            let (orgId, error) = await addAccountWithToken(account.token, email: account.email)
            results.append(EnvImportResult(
                email: account.email,
                success: error == nil,
                error: error
            ))
        }

        return results
    }

    // MARK: - Save Credential for Account

    private func saveCredentialForAccount(
        accountId: String, email: String?, orgName: String?, plan: String,
        accessToken: String, source: String = "token"
    ) {
        guard FileManager.default.fileExists(atPath: dbPath) else { return }
        do {
            let db = try Connection(dbPath)
            let now = ISO8601DateFormatter().string(from: Date())
            let label = orgName ?? email ?? accountId

            // Upsert account — never overwrite account_name (user may have renamed)
            try db.run("""
                INSERT INTO accounts (id, account_name, email, plan, last_updated, sort_order)
                VALUES (?, ?, ?, ?, ?, COALESCE((SELECT MAX(sort_order) + 1 FROM accounts), 0))
                ON CONFLICT(id) DO UPDATE SET
                    email = COALESCE(excluded.email, accounts.email),
                    plan = COALESCE(excluded.plan, accounts.plan),
                    last_updated = excluded.last_updated
            """, accountId, label, email, plan, now)

            // Look for existing credential for THIS account
            let existingCred = try db.scalar(
                "SELECT id FROM oauth_credentials WHERE account_id = ? LIMIT 1",
                accountId
            ) as? Int64

            if let credId = existingCred {
                try db.run("""
                    UPDATE oauth_credentials SET
                        access_token = ?, source = ?,
                        is_active = 1, updated_at = ?
                    WHERE id = ?
                """, accessToken, source, now, credId)
                flog.info("Updated credential for account \(accountId)", category: fcat)
            } else {
                try db.run("""
                    INSERT INTO oauth_credentials (
                        account_id, label, source,
                        access_token, is_active, created_at, updated_at
                    ) VALUES (?, ?, ?, ?, 1, ?, ?)
                """, accountId, label, source, accessToken, now, now)
                flog.info("Created new credential for account \(accountId)", category: fcat)
            }
        } catch {
            flog.error("Failed to save credential for account: \(error.localizedDescription)", category: fcat)
        }
    }

    // MARK: - Database Operations

    func loadActiveCredentials() -> [OAuthCredential] {
        guard FileManager.default.fileExists(atPath: dbPath) else { return [] }
        do {
            let db = try Connection(dbPath, readonly: true)
            var credentials: [OAuthCredential] = []

            let stmt = try db.prepare("""
                SELECT id, account_id, label, source,
                       access_token, refresh_token, expires_at,
                       subscription_type, rate_limit_tier, is_active
                FROM oauth_credentials
                WHERE is_active = 1 AND access_token IS NOT NULL
            """)

            for row in stmt {
                credentials.append(OAuthCredential(
                    id: row[0] as? Int64,
                    accountId: row[1] as? String,
                    label: (row[2] as? String) ?? "Unknown",
                    source: (row[3] as? String) ?? "token",
                    accessToken: row[4] as? String,
                    refreshToken: row[5] as? String,
                    expiresAt: row[6] as? Int64,
                    subscriptionType: row[7] as? String,
                    rateLimitTier: row[8] as? String,
                    isActive: (row[9] as? Int64 ?? 1) == 1
                ))
            }

            return credentials
        } catch {
            flog.error("Failed to load credentials: \(error.localizedDescription)", category: fcat)
            return []
        }
    }

    var hasCredentials: Bool {
        !loadActiveCredentials().isEmpty
    }

    // MARK: - Deactivate Credential

    func deactivateCredential(_ credential: OAuthCredential) {
        guard let credId = credential.id,
              FileManager.default.fileExists(atPath: dbPath) else { return }
        do {
            let db = try Connection(dbPath)
            let now = ISO8601DateFormatter().string(from: Date())
            try db.run(
                "UPDATE oauth_credentials SET is_active = 0, updated_at = ? WHERE id = ?",
                now, credId
            )
            flog.info("Deactivated credential \(credential.label)", category: fcat)
        } catch {
            flog.error("Failed to deactivate credential: \(error.localizedDescription)", category: fcat)
        }
    }

    // MARK: - Polling (each account once per interval, staggered)

    /// How often each account should be polled (seconds)
    private let pollInterval: TimeInterval = 600  // 10 minutes

    /// Last poll time per credential ID
    private var lastPollTimes: [Int64: Date] = [:]

    /// Poll all accounts (startup and manual refresh). Staggers next-poll times
    /// by spacing sequential calls so they naturally spread out.
    func pollAll() async {
        let credentials = loadActiveCredentials()
        guard !credentials.isEmpty else {
            flog.info("pollAll: no active credentials", category: fcat)
            return
        }
        flog.info("pollAll: polling \(credentials.count) credential(s)", category: fcat)

        for credential in credentials {
            await pollWithRetry(credential)
            if let credId = credential.id {
                lastPollTimes[credId] = Date()
            }
        }
    }

    /// Poll any accounts whose poll interval has elapsed. Returns count of accounts polled.
    func pollDue() async -> Int {
        let credentials = loadActiveCredentials()
        guard !credentials.isEmpty else { return 0 }

        let now = Date()
        var polled = 0

        for credential in credentials {
            guard let credId = credential.id else { continue }
            let lastPoll = lastPollTimes[credId]
            if lastPoll == nil || now.timeIntervalSince(lastPoll!) >= pollInterval {
                await pollWithRetry(credential)
                lastPollTimes[credId] = Date()
                polled += 1
            }
        }

        return polled
    }

    private func pollWithRetry(_ credential: OAuthCredential, maxRetries: Int = 2) async {
        var retryDelay: UInt64 = 2_000_000_000

        for attempt in 0...maxRetries {
            do {
                try await pollSingle(credential)
                return
            } catch let error as AnthropicAPIError where error.isTransient && attempt < maxRetries {
                flog.warning("Transient error polling \(credential.label) (attempt \(attempt + 1)): \(error.localizedDescription)", category: fcat)
                updateCredentialStatus(credential, status: .refreshing, error: "Retrying...")
                try? await Task.sleep(nanoseconds: retryDelay)
                retryDelay *= 2
            } catch {
                let isUnauthorized: Bool
                if case AnthropicAPIError.unauthorized = error { isUnauthorized = true } else { isUnauthorized = false }
                let status: TokenStatus = isUnauthorized ? .revoked : .error
                flog.error("Poll failed for \(credential.label): \(error.localizedDescription)", category: fcat)
                updateCredentialStatus(credential, status: status, error: error.localizedDescription)
                return
            }
        }
    }

    private func pollSingle(_ credential: OAuthCredential) async throws {
        guard let token = credential.accessToken else {
            updateCredentialStatus(credential, status: .missing, error: "No access token")
            throw AnthropicAPIError.unauthorized
        }

        let ping = try await apiClient.pingToken(accessToken: token)

        guard let accountId = credential.accountId, !accountId.isEmpty else {
            flog.warning("Credential \(credential.label) has no account_id", category: fcat)
            return
        }

        writePingToDB(accountId: accountId, ping: ping)
        updateCredentialLastPoll(credential, error: nil)
        updateCredentialStatus(credential, status: .valid, error: nil)

        await MainActor.run {
            self.lastError = nil
        }
    }

    // MARK: - Write Ping Data to DB

    private func writePingToDB(accountId: String, ping: PingResponse) {
        guard FileManager.default.fileExists(atPath: dbPath) else { return }

        do {
            let db = try Connection(dbPath)
            let now = ISO8601DateFormatter().string(from: Date())

            let sessionPercent = ping.sessionPercent
            let weeklyAllPercent = ping.weeklyPercent
            let primaryPercent = max(sessionPercent, weeklyAllPercent)

            let sessionReset = ping.sessionResetISO
            let weeklyReset = ping.weeklyResetISO

            // Reset detection: check previous reading
            let prevStmt = try db.prepare(
                "SELECT primary_percent, session_percent, weekly_all_percent, weekly_sonnet_percent, timestamp FROM usage_history WHERE account_id = ? ORDER BY timestamp DESC LIMIT 1"
            )
            for prev in prevStmt.bind(accountId) {
                let prevWeekly = (prev[2] as? Double) ?? 0
                if prevWeekly - weeklyAllPercent > 5 {
                    let midpointDate = Date()
                    let midpointISO = ISO8601DateFormatter().string(from: midpointDate.addingTimeInterval(-1))

                    try db.run(
                        "INSERT INTO usage_history (account_id, timestamp, primary_percent, session_percent, weekly_all_percent, weekly_sonnet_percent, session_reset, weekly_reset, raw_data, is_synthetic) VALUES (?, ?, ?, ?, ?, ?, NULL, NULL, NULL, 1)",
                        accountId, midpointISO,
                        (prev[0] as? Double) ?? 0, (prev[1] as? Double) ?? 0,
                        prevWeekly, (prev[3] as? Double) ?? 0
                    )

                    let zeroISO = ISO8601DateFormatter().string(from: midpointDate)
                    try db.run(
                        "INSERT INTO usage_history (account_id, timestamp, primary_percent, session_percent, weekly_all_percent, weekly_sonnet_percent, session_reset, weekly_reset, raw_data, is_synthetic) VALUES (?, ?, 0, 0, 0, 0, NULL, NULL, NULL, 1)",
                        accountId, zeroISO
                    )
                }
                break
            }

            // Build raw_data JSON from ping headers
            let rawData = """
            {"ping_status":\(ping.httpStatus),"session_status":"\(ping.sessionStatus ?? "")","weekly_status":"\(ping.weeklyStatus ?? "")","overall_status":"\(ping.overallStatus ?? "")"}
            """

            try db.run("""
                INSERT INTO usage_history (
                    account_id, timestamp, primary_percent, session_percent,
                    weekly_all_percent, weekly_sonnet_percent, session_reset, weekly_reset, raw_data, is_synthetic
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 0)
            """, accountId, now, primaryPercent, sessionPercent,
               weeklyAllPercent, 0.0, sessionReset, weeklyReset, rawData)

            try db.run("UPDATE accounts SET last_updated = ? WHERE id = ?", now, accountId)

        } catch {
            flog.error("Failed to write ping to DB: \(error.localizedDescription)", category: fcat)
        }
    }

    // MARK: - Credential Status Tracking

    private func updateCredentialStatus(_ credential: OAuthCredential, status: TokenStatus, error: String?) {
        Task { @MainActor in
            if let credId = credential.id {
                if let index = self.credentialStatuses.firstIndex(where: { $0.id == credId }) {
                    self.credentialStatuses[index].status = status
                    self.credentialStatuses[index].lastPoll = Date()
                    self.credentialStatuses[index].lastError = error
                } else {
                    self.credentialStatuses.append(CredentialStatus(
                        id: credId,
                        label: credential.label,
                        accountId: credential.accountId,
                        status: status,
                        lastPoll: Date(),
                        lastError: error
                    ))
                }
            }
        }
    }

    private func updateCredentialLastPoll(_ credential: OAuthCredential, error: String?) {
        guard let credId = credential.id,
              FileManager.default.fileExists(atPath: dbPath) else { return }
        do {
            let db = try Connection(dbPath)
            let now = ISO8601DateFormatter().string(from: Date())
            try db.run(
                "UPDATE oauth_credentials SET last_poll_at = ?, last_error = ?, updated_at = ? WHERE id = ?",
                now, error, now, credId
            )
        } catch {
            flog.error("Failed to update credential poll time: \(error.localizedDescription)", category: fcat)
        }
    }
}
