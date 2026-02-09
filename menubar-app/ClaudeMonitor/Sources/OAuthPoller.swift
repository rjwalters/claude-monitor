import Foundation
import Security
import SQLite
import os

private let logger = Logger(subsystem: "com.claude-monitor.app", category: "OAuthPoller")

// MARK: - Token Status (M1.2)

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

// MARK: - Keychain Errors (M1.4)

enum KeychainError: Error, LocalizedError {
    case noKeychainEntry
    case accessDenied
    case malformedJSON
    case missingAccessToken
    case otherError(OSStatus)

    var errorDescription: String? {
        switch self {
        case .noKeychainEntry:
            return "No Claude Code credentials found in Keychain"
        case .accessDenied:
            return "Access denied reading Keychain — check app permissions"
        case .malformedJSON:
            return "Keychain entry contains invalid JSON"
        case .missingAccessToken:
            return "No access token found in Keychain data"
        case .otherError(let status):
            return "Keychain error: \(status)"
        }
    }
}

struct OAuthCredential {
    let id: Int64?
    let accountId: String?
    let label: String
    let source: String  // "keychain" or "manual"
    let keychainService: String?
    let keychainAccount: String?
    let accessToken: String?
    let refreshToken: String?
    let expiresAt: Int64?  // epoch ms
    let subscriptionType: String?
    let rateLimitTier: String?
    let isActive: Bool
}

class OAuthPoller: ObservableObject {
    private let apiClient = AnthropicAPIClient()
    @Published var lastError: String?
    @Published var credentialStatuses: [CredentialStatus] = []

    /// Interval for checking keychain for new credentials (M2.4)
    private var lastKeychainCheck: Date?
    private let keychainCheckInterval: TimeInterval = 300  // 5 minutes

    private var dbPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude-monitor/usage.db").path
    }

    // MARK: - Keychain Import (M1.4 typed errors, M2.1 multi-account)

    /// Read a single Claude Code OAuth credential from the macOS Keychain
    func importFromKeychain() -> Swift.Result<OAuthCredential, KeychainError> {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            logger.info("No Claude Code keychain entry found")
            return .failure(.noKeychainEntry)
        }

        if status == errSecAuthFailed || status == errSecInteractionNotAllowed {
            logger.error("Keychain access denied: \(status)")
            return .failure(.accessDenied)
        }

        guard status == errSecSuccess,
              let item = result as? [String: Any],
              let data = item[kSecValueData as String] as? Data else {
            logger.error("Keychain read failed: \(status)")
            return .failure(.otherError(status))
        }

        return parseKeychainItem(item: item, data: data)
    }

    /// Read ALL Claude Code OAuth credentials from the macOS Keychain (M2.1)
    func importAllFromKeychain() -> [Swift.Result<OAuthCredential, KeychainError>] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            logger.info("No Claude Code keychain entries found")
            return [.failure(.noKeychainEntry)]
        }

        if status == errSecAuthFailed || status == errSecInteractionNotAllowed {
            logger.error("Keychain access denied: \(status)")
            return [.failure(.accessDenied)]
        }

        guard status == errSecSuccess else {
            logger.error("Keychain read failed: \(status)")
            return [.failure(.otherError(status))]
        }

        // kSecMatchLimitAll returns an array; kSecMatchLimitOne returns a single dict
        if let items = result as? [[String: Any]] {
            return items.compactMap { item -> Swift.Result<OAuthCredential, KeychainError>? in
                guard let data = item[kSecValueData as String] as? Data else {
                    return .failure(.malformedJSON)
                }
                return parseKeychainItem(item: item, data: data)
            }
        } else if let item = result as? [String: Any],
                  let data = item[kSecValueData as String] as? Data {
            return [parseKeychainItem(item: item, data: data)]
        }

        return [.failure(.noKeychainEntry)]
    }

    private func parseKeychainItem(item: [String: Any], data: Data) -> Swift.Result<OAuthCredential, KeychainError> {
        let keychainAccount = item[kSecAttrAccount as String] as? String ?? "unknown"

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            logger.error("Failed to parse keychain JSON for account \(keychainAccount)")
            return .failure(.malformedJSON)
        }

        let accessToken = json["accessToken"] as? String ?? json["access_token"] as? String
        let refreshToken = json["refreshToken"] as? String ?? json["refresh_token"] as? String
        let expiresAt = json["expiresAt"] as? Int64 ?? json["expires_at"] as? Int64
        let subscriptionType = json["subscriptionType"] as? String ?? json["subscription_type"] as? String
        let rateLimitTier = json["rateLimitTier"] as? String ?? json["rate_limit_tier"] as? String

        guard accessToken != nil else {
            logger.error("No access token in keychain data for account \(keychainAccount)")
            return .failure(.missingAccessToken)
        }

        let credential = OAuthCredential(
            id: nil,
            accountId: nil,
            label: "Claude Code (\(keychainAccount))",
            source: "keychain",
            keychainService: "Claude Code-credentials",
            keychainAccount: keychainAccount,
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: expiresAt,
            subscriptionType: subscriptionType,
            rateLimitTier: rateLimitTier,
            isActive: true
        )

        logger.info("Imported keychain credential for \(keychainAccount)")
        return .success(credential)
    }

    // MARK: - Database Operations

    func saveCredential(_ credential: OAuthCredential) {
        guard FileManager.default.fileExists(atPath: dbPath) else { return }
        do {
            let db = try Connection(dbPath)
            let now = ISO8601DateFormatter().string(from: Date())

            // Generate account ID
            let accountId: String
            if let existing = credential.accountId {
                accountId = existing
            } else {
                // Find existing oauth credential for same keychain entry
                let existingId = try db.scalar(
                    "SELECT account_id FROM oauth_credentials WHERE keychain_service = ? AND keychain_account = ? AND account_id IS NOT NULL LIMIT 1",
                    credential.keychainService ?? "", credential.keychainAccount ?? ""
                ) as? String

                if let existingId = existingId {
                    accountId = existingId
                } else {
                    // Check how many oauth accounts exist to create unique ID
                    let count = try db.scalar("SELECT COUNT(*) FROM oauth_credentials") as? Int64 ?? 0
                    accountId = "oauth_\(count + 1)"
                }
            }

            // Upsert account
            let plan = credential.subscriptionType ?? "Pro"
            try db.run("""
                INSERT INTO accounts (id, account_name, plan, last_updated, sort_order)
                VALUES (?, ?, ?, ?, COALESCE((SELECT MAX(sort_order) + 1 FROM accounts), 0))
                ON CONFLICT(id) DO UPDATE SET
                    plan = COALESCE(excluded.plan, accounts.plan),
                    last_updated = excluded.last_updated
            """, accountId, credential.label, plan, now)

            // Check if credential already exists for this keychain entry
            let existingCred = try db.scalar(
                "SELECT id FROM oauth_credentials WHERE keychain_service = ? AND keychain_account = ?",
                credential.keychainService ?? "", credential.keychainAccount ?? ""
            ) as? Int64

            if let credId = existingCred {
                // Update existing credential
                try db.run("""
                    UPDATE oauth_credentials SET
                        account_id = ?, label = ?, subscription_type = ?,
                        rate_limit_tier = ?, is_active = 1, updated_at = ?
                    WHERE id = ?
                """, accountId, credential.label, credential.subscriptionType ?? "",
                   credential.rateLimitTier ?? "", now, credId)
            } else {
                // Insert new credential
                try db.run("""
                    INSERT INTO oauth_credentials (
                        account_id, label, source, keychain_service, keychain_account,
                        access_token, refresh_token, expires_at, subscription_type,
                        rate_limit_tier, is_active, created_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?)
                """, accountId, credential.label, credential.source,
                   credential.keychainService ?? "", credential.keychainAccount ?? "",
                   credential.source == "manual" ? (credential.accessToken ?? "") : nil,
                   credential.source == "manual" ? (credential.refreshToken ?? "") : nil,
                   credential.expiresAt.map { Int64($0) },
                   credential.subscriptionType ?? "",
                   credential.rateLimitTier ?? "", now, now)
            }

            logger.info("Saved credential for \(credential.label)")
        } catch {
            logger.error("Failed to save credential: \(error.localizedDescription)")
        }
    }

    func loadActiveCredentials() -> [OAuthCredential] {
        guard FileManager.default.fileExists(atPath: dbPath) else { return [] }
        do {
            let db = try Connection(dbPath, readonly: true)
            var credentials: [OAuthCredential] = []

            let stmt = try db.prepare("""
                SELECT id, account_id, label, source, keychain_service, keychain_account,
                       access_token, refresh_token, expires_at, subscription_type,
                       rate_limit_tier, is_active
                FROM oauth_credentials WHERE is_active = 1
            """)

            for row in stmt {
                credentials.append(OAuthCredential(
                    id: row[0] as? Int64,
                    accountId: row[1] as? String,
                    label: (row[2] as? String) ?? "Unknown",
                    source: (row[3] as? String) ?? "keychain",
                    keychainService: row[4] as? String,
                    keychainAccount: row[5] as? String,
                    accessToken: row[6] as? String,
                    refreshToken: row[7] as? String,
                    expiresAt: row[8] as? Int64,
                    subscriptionType: row[9] as? String,
                    rateLimitTier: row[10] as? String,
                    isActive: (row[11] as? Int64 ?? 1) == 1
                ))
            }

            return credentials
        } catch {
            logger.error("Failed to load credentials: \(error.localizedDescription)")
            return []
        }
    }

    /// Check if any active OAuth credentials exist
    var hasCredentials: Bool {
        !loadActiveCredentials().isEmpty
    }

    // MARK: - Deactivate Credential (M4.3)

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
            logger.info("Deactivated credential \(credential.label)")
        } catch {
            logger.error("Failed to deactivate credential: \(error.localizedDescription)")
        }
    }

    // MARK: - Polling (M1.1 retry, M2.3 concurrent)

    func pollAll() async {
        let credentials = loadActiveCredentials()
        guard !credentials.isEmpty else { return }

        // Check for new keychain credentials periodically (M2.4)
        if lastKeychainCheck == nil || Date().timeIntervalSince(lastKeychainCheck!) > keychainCheckInterval {
            checkForNewKeychainCredentials()
            lastKeychainCheck = Date()
        }

        // Concurrent polling with stagger (M2.3)
        await withTaskGroup(of: Void.self) { group in
            for (index, credential) in credentials.enumerated() {
                group.addTask {
                    // Stagger by 5 seconds per credential to avoid rate limits
                    if index > 0 {
                        try? await Task.sleep(nanoseconds: UInt64(index) * 5_000_000_000)
                    }
                    await self.pollWithRetry(credential)
                }
            }
        }
    }

    /// Poll with exponential backoff (M1.1)
    private func pollWithRetry(_ credential: OAuthCredential, maxRetries: Int = 3) async {
        var retryDelay: UInt64 = 2_000_000_000  // 2 seconds

        for attempt in 0...maxRetries {
            do {
                try await pollSingle(credential)
                return  // Success
            } catch let error as AnthropicAPIError where error.isTransient && attempt < maxRetries {
                logger.warning("Transient error polling \(credential.label) (attempt \(attempt + 1)/\(maxRetries + 1)): \(error.localizedDescription)")
                updateCredentialStatus(credential, status: .refreshing, error: "Retrying... (\(error.localizedDescription))")
                try? await Task.sleep(nanoseconds: retryDelay)
                retryDelay *= 2  // Exponential backoff: 2s, 4s, 8s
            } catch {
                // Non-transient error or max retries exceeded
                let isUnauthorized: Bool
                if case AnthropicAPIError.unauthorized = error { isUnauthorized = true } else { isUnauthorized = false }
                let status: TokenStatus = isUnauthorized ? .revoked : .error
                updateCredentialStatus(credential, status: status, error: error.localizedDescription)
                updateCredentialError(credential, error: error.localizedDescription)
                return
            }
        }
    }

    private func pollSingle(_ credential: OAuthCredential) async throws {
        // Check token health first (M4.1)
        let tokenHealth = checkTokenHealth(credential)
        if tokenHealth == .expired || tokenHealth == .missing {
            updateCredentialStatus(credential, status: tokenHealth, error: "Token \(tokenHealth.rawValue)")
            if tokenHealth == .expired && credential.source == "manual", let refreshToken = credential.refreshToken {
                // Try automatic refresh for manual credentials
                logger.info("Attempting automatic token refresh for \(credential.label)")
                updateCredentialStatus(credential, status: .refreshing, error: nil)
                let refreshResponse = try await apiClient.refreshToken(refreshToken: refreshToken)
                updateCredentialTokens(credential, response: refreshResponse)
                // Retry with new token
                let usage = try await apiClient.fetchUsage(accessToken: refreshResponse.accessToken)
                writeUsageToDB(credential: credential, usage: usage)
                updateCredentialLastPoll(credential, error: nil)
                updateCredentialStatus(credential, status: .valid, error: nil)
                return
            }
            throw AnthropicAPIError.unauthorized
        }

        guard let token = resolveAccessToken(credential) else {
            updateCredentialStatus(credential, status: .missing, error: "Could not resolve access token")
            updateCredentialError(credential, error: "Could not resolve access token")
            throw AnthropicAPIError.unauthorized
        }

        do {
            let usage = try await apiClient.fetchUsage(accessToken: token)
            writeUsageToDB(credential: credential, usage: usage)
            updateCredentialLastPoll(credential, error: nil)
            updateCredentialStatus(credential, status: .valid, error: nil)
            await MainActor.run {
                self.lastError = nil
            }
        } catch AnthropicAPIError.unauthorized {
            // Try refresh if we have a refresh token (manual source)
            if credential.source == "manual", let refreshToken = credential.refreshToken {
                do {
                    updateCredentialStatus(credential, status: .refreshing, error: nil)
                    let refreshResponse = try await apiClient.refreshToken(refreshToken: refreshToken)
                    updateCredentialTokens(credential, response: refreshResponse)
                    // Retry with new token
                    let usage = try await apiClient.fetchUsage(accessToken: refreshResponse.accessToken)
                    writeUsageToDB(credential: credential, usage: usage)
                    updateCredentialLastPoll(credential, error: nil)
                    updateCredentialStatus(credential, status: .valid, error: nil)
                } catch {
                    logger.error("Token refresh failed for \(credential.label): \(error.localizedDescription)")
                    updateCredentialStatus(credential, status: .revoked, error: "Token refresh failed")
                    throw error
                }
            } else {
                updateCredentialStatus(credential, status: .revoked, error: "Unauthorized — Claude Code may need to re-authenticate")
                throw AnthropicAPIError.unauthorized
            }
        }
    }

    // MARK: - Token Health (M4.1)

    func checkTokenHealth(_ credential: OAuthCredential) -> TokenStatus {
        if credential.source == "keychain" {
            // For keychain credentials, check if the keychain entry exists and has a token
            let token = readTokenFromKeychain(service: credential.keychainService, account: credential.keychainAccount)
            if token == nil {
                return .missing
            }
            // Check expiresAt from keychain JSON
            if let expiresAt = readExpiresAtFromKeychain(service: credential.keychainService, account: credential.keychainAccount) {
                let now = Int64(Date().timeIntervalSince1970 * 1000)
                if now >= expiresAt {
                    return .expired
                }
            }
            return .valid
        }

        // Manual source: check expiry
        if let expiresAt = credential.expiresAt {
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            if now >= expiresAt {
                return .expired
            }
        }

        if credential.accessToken == nil {
            return .missing
        }

        return .valid
    }

    // MARK: - Token Resolution

    private func resolveAccessToken(_ credential: OAuthCredential) -> String? {
        if credential.source == "keychain" {
            return readTokenFromKeychain(service: credential.keychainService, account: credential.keychainAccount)
        }

        // Manual source: check expiry
        if let expiresAt = credential.expiresAt {
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            if now >= expiresAt {
                return nil  // Expired, needs refresh
            }
        }
        return credential.accessToken
    }

    private func readTokenFromKeychain(service: String?, account: String?) -> String? {
        guard let service = service else { return nil }

        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        if let account = account {
            query[kSecAttrAccount as String] = account
        }

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        return json["accessToken"] as? String ?? json["access_token"] as? String
    }

    private func readExpiresAtFromKeychain(service: String?, account: String?) -> Int64? {
        guard let service = service else { return nil }

        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        if let account = account {
            query[kSecAttrAccount as String] = account
        }

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        return json["expiresAt"] as? Int64 ?? json["expires_at"] as? Int64
    }

    // MARK: - Keychain Change Detection (M2.4)

    func checkForNewKeychainCredentials() {
        let results = importAllFromKeychain()
        let existingCredentials = loadActiveCredentials()
        let existingAccounts = Set(existingCredentials.compactMap { $0.keychainAccount })

        for result in results {
            if case .success(let credential) = result {
                if !existingAccounts.contains(credential.keychainAccount ?? "") {
                    logger.info("Auto-importing new keychain credential: \(credential.label)")
                    saveCredential(credential)
                }
            }
        }
    }

    // MARK: - Credential Status Tracking (M1.2)

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

    // MARK: - DB Writes

    private func writeUsageToDB(credential: OAuthCredential, usage: UsageResponse) {
        guard let accountId = credential.accountId,
              FileManager.default.fileExists(atPath: dbPath) else { return }

        do {
            let db = try Connection(dbPath)
            let now = ISO8601DateFormatter().string(from: Date())

            let sessionPercent = (usage.fiveHour?.utilization ?? 0) * 100
            let weeklyAllPercent = (usage.sevenDay?.utilization ?? 0) * 100
            let weeklySonnetPercent = (usage.sevenDaySonnet?.utilization ?? 0) * 100
            let primaryPercent = max(sessionPercent, weeklyAllPercent)

            let sessionReset = usage.fiveHour?.resetsAt
            let weeklyReset = usage.sevenDay?.resetsAt

            // Encode full response as raw_data
            let rawData: String?
            if let jsonData = try? JSONEncoder().encode(usage) {
                rawData = String(data: jsonData, encoding: .utf8)
            } else {
                rawData = nil
            }

            // Reset detection: check previous reading
            let prevStmt = try db.prepare(
                "SELECT primary_percent, session_percent, weekly_all_percent, weekly_sonnet_percent, timestamp FROM usage_history WHERE account_id = ? ORDER BY timestamp DESC LIMIT 1"
            )
            for prev in prevStmt.bind(accountId) {
                let prevWeekly = (prev[2] as? Double) ?? 0
                // Reset detected if usage dropped by more than 5%
                if prevWeekly - weeklyAllPercent > 5 {
                    // Insert synthetic reset points
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
                break  // Only need the first row
            }

            // Insert current usage record
            try db.run("""
                INSERT INTO usage_history (
                    account_id, timestamp, primary_percent, session_percent,
                    weekly_all_percent, weekly_sonnet_percent, session_reset, weekly_reset, raw_data, is_synthetic
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 0)
            """, accountId, now, primaryPercent, sessionPercent,
               weeklyAllPercent, weeklySonnetPercent, sessionReset, weeklyReset, rawData)

            // Update account last_updated
            try db.run("UPDATE accounts SET last_updated = ? WHERE id = ?", now, accountId)

        } catch {
            logger.error("Failed to write usage to DB: \(error.localizedDescription)")
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
            logger.error("Failed to update credential poll time: \(error.localizedDescription)")
        }
    }

    private func updateCredentialError(_ credential: OAuthCredential, error: String) {
        logger.warning("OAuth poll error for \(credential.label): \(error)")
        Task { @MainActor in
            self.lastError = error
        }
        updateCredentialLastPoll(credential, error: error)
    }

    private func updateCredentialTokens(_ credential: OAuthCredential, response: TokenRefreshResponse) {
        guard let credId = credential.id,
              FileManager.default.fileExists(atPath: dbPath) else { return }
        do {
            let db = try Connection(dbPath)
            let now = ISO8601DateFormatter().string(from: Date())
            let expiresAt: Int64? = response.expiresIn.map { Int64(Date().timeIntervalSince1970 * 1000) + Int64($0) * 1000 }
            try db.run(
                "UPDATE oauth_credentials SET access_token = ?, refresh_token = COALESCE(?, refresh_token), expires_at = ?, updated_at = ? WHERE id = ?",
                response.accessToken, response.refreshToken, expiresAt, now, credId
            )
            logger.info("Updated tokens for credential \(credId)")
        } catch {
            logger.error("Failed to update credential tokens: \(error.localizedDescription)")
        }
    }
}
