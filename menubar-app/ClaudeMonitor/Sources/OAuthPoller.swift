import Foundation
import Security
import SQLite
import os

private let logger = Logger(subsystem: "com.claude-monitor.app", category: "OAuthPoller")
private let flog = FileLogger.shared
private let fcat = "OAuth"

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
            flog.info("No Claude Code keychain entry found", category: fcat)
            return .failure(.noKeychainEntry)
        }

        if status == errSecAuthFailed || status == errSecInteractionNotAllowed {
            logger.error("Keychain access denied: \(status)")
            flog.error("Keychain access denied (OSStatus \(status))", category: fcat)
            return .failure(.accessDenied)
        }

        guard status == errSecSuccess,
              let item = result as? [String: Any],
              let data = item[kSecValueData as String] as? Data else {
            logger.error("Keychain read failed: \(status)")
            flog.error("Keychain read failed (OSStatus \(status))", category: fcat)
            return .failure(.otherError(status))
        }

        return parseKeychainItem(item: item, data: data)
    }

    /// Read ALL Claude Code OAuth credentials from the macOS Keychain (M2.1)
    func importAllFromKeychain() -> [Swift.Result<OAuthCredential, KeychainError>] {
        // Step 1: Get all account names via attributes-only query
        let attrQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]

        var attrResult: CFTypeRef?
        let attrStatus = SecItemCopyMatching(attrQuery as CFDictionary, &attrResult)

        if attrStatus == errSecItemNotFound {
            logger.info("No Claude Code keychain entries found")
            flog.info("No Claude Code keychain entries found", category: fcat)
            return [.failure(.noKeychainEntry)]
        }

        if attrStatus == errSecAuthFailed || attrStatus == errSecInteractionNotAllowed {
            logger.error("Keychain access denied: \(attrStatus)")
            flog.error("Keychain access denied (OSStatus \(attrStatus))", category: fcat)
            return [.failure(.accessDenied)]
        }

        guard attrStatus == errSecSuccess else {
            logger.error("Keychain attribute query failed: \(attrStatus)")
            flog.error("Keychain attribute query failed (OSStatus \(attrStatus))", category: fcat)
            // Fall back to single-item import
            flog.info("Falling back to single-item keychain import", category: fcat)
            return [importFromKeychain()]
        }

        // Collect account names from the attributes result
        var accountNames: [String] = []
        if let items = attrResult as? [[String: Any]] {
            for item in items {
                if let acct = item[kSecAttrAccount as String] as? String {
                    accountNames.append(acct)
                }
            }
        } else if let item = attrResult as? [String: Any],
                  let acct = item[kSecAttrAccount as String] as? String {
            accountNames.append(acct)
        }

        flog.info("Found \(accountNames.count) keychain account(s): \(accountNames.joined(separator: ", "))", category: fcat)

        if accountNames.isEmpty {
            return [.failure(.noKeychainEntry)]
        }

        // Step 2: Fetch each credential individually (avoids kSecMatchLimitAll + kSecReturnData issues)
        var results: [Swift.Result<OAuthCredential, KeychainError>] = []
        for accountName in accountNames {
            flog.info("Fetching keychain data for account: \(accountName)", category: fcat)
            let dataQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "Claude Code-credentials",
                kSecAttrAccount as String: accountName,
                kSecReturnData as String: true,
                kSecReturnAttributes as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne
            ]

            var dataResult: CFTypeRef?
            let dataStatus = SecItemCopyMatching(dataQuery as CFDictionary, &dataResult)
            flog.info("Keychain data query result for \(accountName): OSStatus \(dataStatus)", category: fcat)

            guard dataStatus == errSecSuccess,
                  let item = dataResult as? [String: Any],
                  let data = item[kSecValueData as String] as? Data else {
                flog.warning("Failed to read keychain data for \(accountName) (OSStatus \(dataStatus))", category: fcat)
                results.append(.failure(.otherError(dataStatus)))
                continue
            }

            results.append(parseKeychainItem(item: item, data: data))
        }

        return results
    }

    private func parseKeychainItem(item: [String: Any], data: Data) -> Swift.Result<OAuthCredential, KeychainError> {
        let keychainAccount = item[kSecAttrAccount as String] as? String ?? "unknown"

        guard let topJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            logger.error("Failed to parse keychain JSON for account \(keychainAccount)")
            flog.error("Failed to parse keychain JSON for \(keychainAccount)", category: fcat)
            return .failure(.malformedJSON)
        }

        // Claude Code wraps credentials under "claudeAiOauth"; fall back to top-level keys
        let json = (topJson["claudeAiOauth"] as? [String: Any]) ?? topJson
        flog.info("Keychain JSON keys for \(keychainAccount): \(Array(topJson.keys).joined(separator: ", "))", category: fcat)

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
        flog.info("Imported keychain credential for \(keychainAccount)", category: fcat)
        return .success(credential)
    }

    // MARK: - Wizard: profile-aware keychain scan

    /// Import the current keychain token, identify the account via profile API,
    /// and save as a per-account credential (doesn't clobber other accounts).
    /// Returns the account email on success.
    func scanKeychainWithProfile() async -> String? {
        let importResult = importFromKeychain()
        guard case .success(let rawCred) = importResult,
              let token = rawCred.accessToken else {
            flog.warning("scanKeychainWithProfile: no token from keychain", category: fcat)
            return nil
        }

        // Identify the account
        guard let profile = try? await apiClient.fetchProfile(accessToken: token) else {
            flog.warning("scanKeychainWithProfile: profile fetch failed", category: fcat)
            return nil
        }

        let orgId = profile.organization.uuid
        let email = profile.account.email
        let orgName = profile.organization.name
        let plan = profile.organization.organizationType ?? "Pro"

        flog.info("scanKeychainWithProfile: token belongs to \(email) (\(orgId))", category: fcat)

        // Save credential keyed by account_id (not keychain entry)
        saveCredentialForAccount(
            accountId: orgId,
            email: email,
            orgName: orgName,
            plan: plan,
            accessToken: token,
            refreshToken: rawCred.refreshToken,
            expiresAt: rawCred.expiresAt,
            keychainService: rawCred.keychainService,
            keychainAccount: rawCred.keychainAccount
        )

        // Also poll usage immediately for this account
        if let usage = try? await apiClient.fetchUsage(accessToken: token) {
            // Write usage to DB
            let creds = loadActiveCredentials().filter { $0.accountId == orgId }
            if let cred = creds.first {
                writeUsageToDB(credential: cred, usage: usage)
            }
        }

        return email
    }

    /// Save a credential keyed by account_id (not keychain entry).
    /// Creates a new credential row per account so multiple accounts each keep their token.
    private func saveCredentialForAccount(
        accountId: String, email: String?, orgName: String?, plan: String,
        accessToken: String, refreshToken: String?, expiresAt: Int64?,
        keychainService: String?, keychainAccount: String?
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
                // Update existing credential for this account
                try db.run("""
                    UPDATE oauth_credentials SET
                        access_token = ?, refresh_token = COALESCE(?, refresh_token),
                        expires_at = COALESCE(?, expires_at),
                        keychain_service = ?, keychain_account = ?,
                        is_active = 1, updated_at = ?
                    WHERE id = ?
                """, accessToken, refreshToken,
                   expiresAt.map { Int64($0) },
                   keychainService ?? "", keychainAccount ?? "",
                   now, credId)
                flog.info("Updated credential for account \(accountId)", category: fcat)
            } else {
                // Create new credential for this account
                try db.run("""
                    INSERT INTO oauth_credentials (
                        account_id, label, source, keychain_service, keychain_account,
                        access_token, refresh_token, expires_at,
                        is_active, created_at, updated_at
                    ) VALUES (?, ?, 'keychain', ?, ?, ?, ?, ?, 1, ?, ?)
                """, accountId, label,
                   keychainService ?? "", keychainAccount ?? "",
                   accessToken, refreshToken,
                   expiresAt.map { Int64($0) },
                   now, now)
                flog.info("Created new credential for account \(accountId)", category: fcat)
            }
        } catch {
            flog.error("Failed to save credential for account: \(error.localizedDescription)", category: fcat)
        }
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
                // Update existing credential — always refresh stored tokens
                try db.run("""
                    UPDATE oauth_credentials SET
                        account_id = ?, label = ?,
                        access_token = COALESCE(?, access_token),
                        refresh_token = COALESCE(?, refresh_token),
                        expires_at = COALESCE(?, expires_at),
                        subscription_type = ?,
                        rate_limit_tier = ?, is_active = 1, updated_at = ?
                    WHERE id = ?
                """, accountId, credential.label,
                   credential.accessToken, credential.refreshToken,
                   credential.expiresAt.map { Int64($0) },
                   credential.subscriptionType ?? "",
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
                   credential.accessToken,
                   credential.refreshToken,
                   credential.expiresAt.map { Int64($0) },
                   credential.subscriptionType ?? "",
                   credential.rateLimitTier ?? "", now, now)
            }

            logger.info("Saved credential for \(credential.label)")
            flog.info("Saved credential for \(credential.label)", category: fcat)
        } catch {
            logger.error("Failed to save credential: \(error.localizedDescription)")
            flog.error("Failed to save credential: \(error.localizedDescription)", category: fcat)
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
            flog.error("Failed to load credentials: \(error.localizedDescription)", category: fcat)
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
            flog.info("Deactivated credential \(credential.label)", category: fcat)
        } catch {
            logger.error("Failed to deactivate credential: \(error.localizedDescription)")
            flog.error("Failed to deactivate credential: \(error.localizedDescription)", category: fcat)
        }
    }

    // MARK: - Keychain Sync (runs once per poll cycle)

    /// Read the keychain once, identify the account, and update the matching credential.
    /// Claude Code stores one token at a time in a single keychain entry (`rwalters`).
    /// When the user does `/login` for a different account, this picks it up.
    private func syncKeychainTokens() async {
        // Read token from the single shared keychain entry
        guard let freshToken = readTokenFromKeychain(service: "Claude Code-credentials", account: nil) else {
            return
        }
        let freshExpiry = readExpiresAtFromKeychain(service: "Claude Code-credentials", account: nil)
        let freshRefreshToken = readRefreshTokenFromKeychain(service: "Claude Code-credentials", account: nil)
        let now = Int64(Date().timeIntervalSince1970 * 1000)

        // If token is expired, attempt refresh using stored refresh token
        if let exp = freshExpiry, exp <= now {
            flog.info("syncKeychainTokens: keychain token is expired, attempting refresh", category: fcat)
            let credentials = loadActiveCredentials()
            for cred in credentials where cred.source == "keychain" {
                // Use fresh refresh token from keychain, fall back to stored one
                let rt = freshRefreshToken ?? cred.refreshToken
                guard let refreshToken = rt else { continue }
                do {
                    let refreshResponse = try await apiClient.refreshToken(refreshToken: refreshToken)
                    flog.info("syncKeychainTokens: refreshed expired token for \(cred.label)", category: fcat)
                    updateCredentialTokens(cred, response: refreshResponse)
                    updateCredentialStatus(cred, status: .valid, error: nil)
                } catch {
                    flog.warning("syncKeychainTokens: refresh failed for \(cred.label): \(error.localizedDescription)", category: fcat)
                }
            }
            return
        }

        // Identify which account this token belongs to
        guard let profile = try? await apiClient.fetchProfile(accessToken: freshToken) else {
            flog.warning("syncKeychainTokens: profile fetch failed", category: fcat)
            return
        }

        let tokenAccountId = profile.organization.uuid
        let credentials = loadActiveCredentials()

        // Find the credential(s) matching this account and update if their token is stale
        for cred in credentials where cred.source == "keychain" && cred.accountId == tokenAccountId {
            let health = checkTokenHealth(cred)
            if health == .missing || health == .expired || cred.accessToken != freshToken {
                flog.info("syncKeychainTokens: updating token for \(cred.label) (\(tokenAccountId))", category: fcat)
                updateStoredToken(cred, accessToken: freshToken, expiresAt: freshExpiry, refreshToken: freshRefreshToken)
            }
        }
    }

    // MARK: - Polling (round-robin, one account per tick)

    /// Index of the next credential to poll (round-robin)
    private var nextPollIndex = 0

    /// Poll the next credential in round-robin order.
    /// Called once per timer tick (60s) so API calls are spaced out.
    func pollNext() async {
        await syncKeychainTokens()

        let credentials = loadActiveCredentials()
        guard !credentials.isEmpty else {
            flog.info("pollNext: no active credentials", category: fcat)
            return
        }

        // Wrap index if credentials changed
        if nextPollIndex >= credentials.count {
            nextPollIndex = 0
        }

        let credential = credentials[nextPollIndex]
        flog.info("pollNext: \(credential.label) (\(nextPollIndex + 1)/\(credentials.count))", category: fcat)
        nextPollIndex = (nextPollIndex + 1) % credentials.count

        await pollWithRetry(credential)
    }

    /// Poll all credentials at once (used for initial load and manual refresh).
    func pollAll() async {
        await syncKeychainTokens()

        let credentials = loadActiveCredentials()
        guard !credentials.isEmpty else {
            flog.info("pollAll: no active credentials", category: fcat)
            return
        }
        flog.info("pollAll: polling \(credentials.count) credential(s)", category: fcat)

        for credential in credentials {
            await pollWithRetry(credential)
        }
    }

    /// Poll with exponential backoff (M1.1)
    private func pollWithRetry(_ credential: OAuthCredential, maxRetries: Int = 3) async {
        var retryDelay: UInt64 = 2_000_000_000  // 2 seconds

        for attempt in 0...maxRetries {
            do {
                try await pollSingle(credential)
                flog.info("Poll success for \(credential.label)", category: fcat)
                return  // Success
            } catch let error as AnthropicAPIError where error.isTransient && attempt < maxRetries {
                logger.warning("Transient error polling \(credential.label) (attempt \(attempt + 1)/\(maxRetries + 1)): \(error.localizedDescription)")
                flog.warning("Transient error polling \(credential.label) (attempt \(attempt + 1)/\(maxRetries + 1)): \(error.localizedDescription)", category: fcat)
                updateCredentialStatus(credential, status: .refreshing, error: "Retrying... (\(error.localizedDescription))")
                try? await Task.sleep(nanoseconds: retryDelay)
                retryDelay *= 2  // Exponential backoff: 2s, 4s, 8s
            } catch {
                // Non-transient error or max retries exceeded
                let isUnauthorized: Bool
                if case AnthropicAPIError.unauthorized = error { isUnauthorized = true } else { isUnauthorized = false }
                let status: TokenStatus = isUnauthorized ? .revoked : .error
                flog.error("Poll failed for \(credential.label): \(error.localizedDescription)", category: fcat)
                updateCredentialStatus(credential, status: status, error: error.localizedDescription)
                updateCredentialError(credential, error: error.localizedDescription)
                return
            }
        }
    }

    private func pollSingle(_ credential: OAuthCredential) async throws {
        // Check token health first (M4.1)
        let tokenHealth = checkTokenHealth(credential)
        flog.info("Token health for \(credential.label): \(tokenHealth.rawValue)", category: fcat)
        if tokenHealth == .expired || tokenHealth == .missing {
            updateCredentialStatus(credential, status: tokenHealth, error: "Token \(tokenHealth.rawValue)")
            if tokenHealth == .expired, let refreshToken = credential.refreshToken {
                // Try automatic refresh for expired tokens
                logger.info("Auto-refreshing expired token for \(credential.label)")
                flog.info("Auto-refreshing expired token for \(credential.label)", category: fcat)
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

        // Proactive refresh: refresh tokens nearing expiry (within 5 minutes)
        if tokenHealth == .valid, let expiresAt = credential.expiresAt, let refreshToken = credential.refreshToken {
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            let fiveMinutes: Int64 = 5 * 60 * 1000
            if expiresAt - now < fiveMinutes {
                logger.info("Proactively refreshing nearly-expired token for \(credential.label)")
                flog.info("Proactively refreshing nearly-expired token for \(credential.label) (expires in \((expiresAt - now) / 1000)s)", category: fcat)
                updateCredentialStatus(credential, status: .refreshing, error: nil)
                do {
                    let refreshResponse = try await apiClient.refreshToken(refreshToken: refreshToken)
                    updateCredentialTokens(credential, response: refreshResponse)
                    let usage = try await apiClient.fetchUsage(accessToken: refreshResponse.accessToken)
                    writeUsageToDB(credential: credential, usage: usage)
                    updateCredentialLastPoll(credential, error: nil)
                    updateCredentialStatus(credential, status: .valid, error: nil)
                    return
                } catch {
                    flog.warning("Proactive refresh failed for \(credential.label): \(error.localizedDescription) — continuing with current token", category: fcat)
                    // Fall through to use the still-valid (but soon-to-expire) token
                }
            }
        }

        guard let token = resolveAccessToken(credential) else {
            updateCredentialStatus(credential, status: .missing, error: "Could not resolve access token")
            updateCredentialError(credential, error: "Could not resolve access token")
            throw AnthropicAPIError.unauthorized
        }

        do {
            let usage = try await apiClient.fetchUsage(accessToken: token)

            // Fetch profile to associate credential with correct account (by org UUID)
            if let profile = try? await apiClient.fetchProfile(accessToken: token) {
                updateAccountFromProfile(credential: credential, profile: profile)
            }

            writeUsageToDB(credential: credential, usage: usage)
            updateCredentialLastPoll(credential, error: nil)
            updateCredentialStatus(credential, status: .valid, error: nil)
            await MainActor.run {
                self.lastError = nil
            }
        } catch AnthropicAPIError.unauthorized {
            // Try refresh if we have a refresh token (manual source)
            if let refreshToken = credential.refreshToken {
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
                    flog.error("Token refresh failed for \(credential.label): \(error.localizedDescription)", category: fcat)
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
        // Use DB-stored token/expiry to avoid blocking keychain queries
        if credential.accessToken == nil {
            return .missing
        }

        if let expiresAt = credential.expiresAt {
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            if now >= expiresAt {
                return .expired
            }
        }

        return .valid
    }

    // MARK: - Token Resolution

    private func resolveAccessToken(_ credential: OAuthCredential) -> String? {
        // Prefer DB-stored token (avoids blocking keychain queries on unsigned binaries)
        if let storedToken = credential.accessToken {
            // Check expiry
            if let expiresAt = credential.expiresAt {
                let now = Int64(Date().timeIntervalSince1970 * 1000)
                if now >= expiresAt {
                    flog.info("Stored token expired for \(credential.label)", category: fcat)
                    return nil
                }
            }
            return storedToken
        }

        // Fall back to keychain if no stored token
        if credential.source == "keychain" {
            if let keychainToken = readTokenFromKeychain(service: credential.keychainService, account: credential.keychainAccount) {
                return keychainToken
            }
            flog.info("No stored or keychain token for \(credential.label)", category: fcat)
        }

        return nil
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
              let topJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let json = (topJson["claudeAiOauth"] as? [String: Any]) ?? topJson
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
              let topJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let json = (topJson["claudeAiOauth"] as? [String: Any]) ?? topJson
        return json["expiresAt"] as? Int64 ?? json["expires_at"] as? Int64
    }

    private func readRefreshTokenFromKeychain(service: String?, account: String?) -> String? {
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
              let topJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let json = (topJson["claudeAiOauth"] as? [String: Any]) ?? topJson
        return json["refreshToken"] as? String ?? json["refresh_token"] as? String
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

    // MARK: - Profile-based Account Association

    private func updateAccountFromProfile(credential: OAuthCredential, profile: ProfileResponse) {
        guard let credId = credential.id,
              FileManager.default.fileExists(atPath: dbPath) else { return }

        let orgId = profile.organization.uuid
        let email = profile.account.email
        let orgName = profile.organization.name
        let plan = profile.organization.organizationType ?? "Pro"

        do {
            let db = try Connection(dbPath)
            let now = ISO8601DateFormatter().string(from: Date())

            // Upsert account using org UUID — never overwrite account_name (user may have renamed)
            try db.run("""
                INSERT INTO accounts (id, account_name, email, plan, last_updated, sort_order)
                VALUES (?, ?, ?, ?, ?, COALESCE((SELECT MAX(sort_order) + 1 FROM accounts), 0))
                ON CONFLICT(id) DO UPDATE SET
                    email = COALESCE(excluded.email, accounts.email),
                    plan = COALESCE(excluded.plan, accounts.plan),
                    last_updated = excluded.last_updated
            """, orgId, orgName, email, plan, now)

            // Update credential to point to correct account
            let currentAccountId = credential.accountId
            if currentAccountId != orgId {
                // Only re-link if the current account_id is auto-generated (oauth_N) or nil.
                // Once a credential is linked to a real org UUID, don't override it — the
                // token may belong to a different account (shared keychain entry).
                if let oldId = currentAccountId, !oldId.hasPrefix("oauth_") {
                    flog.warning("Profile says \(orgId) but credential already linked to \(oldId) — not re-linking", category: fcat)
                } else {
                    try db.run(
                        "UPDATE oauth_credentials SET account_id = ?, updated_at = ? WHERE id = ?",
                        orgId, now, credId
                    )
                    flog.info("Linked credential \(credential.label) to account \(email) (\(orgId))", category: fcat)

                    // Clean up orphaned account if it was auto-generated (oauth_N)
                    if let oldId = currentAccountId, oldId.hasPrefix("oauth_") {
                        let refCount = try db.scalar(
                            "SELECT COUNT(*) FROM oauth_credentials WHERE account_id = ?", oldId
                        ) as? Int64 ?? 0
                        if refCount == 0 {
                            try db.run("DELETE FROM accounts WHERE id = ?", oldId)
                            flog.info("Cleaned up orphaned account \(oldId)", category: fcat)
                        }
                    }
                }
            }
        } catch {
            flog.error("Failed to update account from profile: \(error.localizedDescription)", category: fcat)
        }
    }

    // MARK: - DB Writes

    private func writeUsageToDB(credential: OAuthCredential, usage: UsageResponse) {
        guard let accountId = credential.accountId,
              FileManager.default.fileExists(atPath: dbPath) else { return }

        do {
            let db = try Connection(dbPath)
            let now = ISO8601DateFormatter().string(from: Date())

            let sessionPercent = usage.fiveHour?.utilization ?? 0
            let weeklyAllPercent = usage.sevenDay?.utilization ?? 0
            let weeklySonnetPercent = usage.sevenDaySonnet?.utilization ?? 0
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
            flog.error("Failed to write usage to DB: \(error.localizedDescription)", category: fcat)
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
        flog.warning("OAuth poll error for \(credential.label): \(error)", category: fcat)
        Task { @MainActor in
            self.lastError = error
        }
        updateCredentialLastPoll(credential, error: error)
    }

    /// Update stored access_token, expires_at, and optionally refresh_token from raw values (used for keychain re-reads)
    private func updateStoredToken(_ credential: OAuthCredential, accessToken: String, expiresAt: Int64?, refreshToken: String? = nil) {
        guard let credId = credential.id,
              FileManager.default.fileExists(atPath: dbPath) else { return }
        do {
            let db = try Connection(dbPath)
            let now = ISO8601DateFormatter().string(from: Date())
            try db.run(
                "UPDATE oauth_credentials SET access_token = ?, expires_at = ?, refresh_token = COALESCE(?, refresh_token), updated_at = ? WHERE id = ?",
                accessToken, expiresAt, refreshToken, now, credId
            )
            flog.info("Updated stored token for credential \(credId) from keychain", category: fcat)
        } catch {
            flog.error("Failed to update stored token: \(error.localizedDescription)", category: fcat)
        }
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
