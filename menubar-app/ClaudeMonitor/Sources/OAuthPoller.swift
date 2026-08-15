import Foundation

private let flog = FileLogger.shared
private let fcat = "OAuth"

/// A conservative "well-formed enough" email check — not full RFC 5322
/// validation, just enough to distinguish a real address (e.g. one a user
/// typed as an account label/alias) from an opaque account ID (a UUID/org ID,
/// which never contains '@'). Used to backfill the `accounts.email` column —
/// the join key `loom-daemon tokens import-from-monitor` uses to find
/// accounts (#15) — whenever a profile-fetch-derived email is unavailable but
/// the label plainly carries the address.
func looksLikeEmailAddress(_ s: String) -> Bool {
    guard !s.isEmpty, !s.contains(where: { $0.isWhitespace }) else { return false }
    let parts = s.split(separator: "@", omittingEmptySubsequences: false)
    guard parts.count == 2 else { return false }  // exactly one '@'
    let local = parts[0]
    let domain = parts[1]
    guard !local.isEmpty, domain.contains("."), !domain.hasPrefix("."), !domain.hasSuffix(".") else {
        return false
    }
    return true
}

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
    /// Which upstream this credential authenticates against. Pre-migration rows
    /// resolve to `.anthropic`.
    let provider: AccountProvider
    let label: String
    let source: String  // "token" or "env"
    let accessToken: String?
    let refreshToken: String?
    let expiresAt: Int64?  // epoch ms — vestigial keychain-era column
    /// When `accessToken` expires, parsed from `oauth_credentials.token_expires_at`.
    /// nil for Anthropic (long-lived tokens); OpenAI access tokens live ~10 days
    /// and must be refreshed before this instant (spike #26).
    let tokenExpiresAt: Date?
    let subscriptionType: String?
    let rateLimitTier: String?
    let isActive: Bool

    init(
        id: Int64?,
        accountId: String?,
        provider: AccountProvider = .anthropic,
        label: String,
        source: String,
        accessToken: String?,
        refreshToken: String?,
        expiresAt: Int64?,
        tokenExpiresAt: Date? = nil,
        subscriptionType: String?,
        rateLimitTier: String?,
        isActive: Bool
    ) {
        self.id = id
        self.accountId = accountId
        self.provider = provider
        self.label = label
        self.source = source
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.tokenExpiresAt = tokenExpiresAt
        self.subscriptionType = subscriptionType
        self.rateLimitTier = rateLimitTier
        self.isActive = isActive
    }

    /// This credential in the provider-agnostic shape a `UsageProviderClient`
    /// consumes. nil when there is no access token to present.
    var providerCredentials: ProviderCredentials? {
        guard let accessToken = accessToken else { return nil }
        return ProviderCredentials(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: tokenExpiresAt
        )
    }
}

/// Raised when a credential's access token is past expiry and could not be
/// renewed. Distinct from `ProviderAPIError.unauthorized` so the retry loop can
/// preserve the `.expired` token-health state (and its actionable message)
/// instead of flattening it to the generic "revoked".
struct CredentialExpiredError: Error, LocalizedError {
    let reason: String
    var errorDescription: String? { reason }
}

struct EnvImportResult {
    let email: String
    let success: Bool
    let error: String?
    /// Which upstream this entry authenticated against. Defaults to
    /// `.anthropic` so existing call sites that predate multi-provider
    /// clipboard transfer (#67) — the file-read-error path in
    /// `importFromEnvFile`, `syncFromAccountFiles`, which stays Anthropic-only
    /// — don't need updating. `pasteAccounts()` (UsagePopoverView.swift) reads
    /// this to scope its replace-semantics deletion to only the providers a
    /// paste actually described.
    var provider: AccountProvider = .anthropic
}

// `@Published`-driven state is only ever read/written from the main thread
// today (SwiftUI views on macOS; a single Task-driven headless loop that
// pumps via `dispatchMain()` on Linux) — @MainActor isolation matches actual
// usage and lets Swift 6 verify it, rather than sprinkling per-call
// `Task { @MainActor in ... }` hops that only *assert* the same invariant.
@MainActor
class OAuthPoller: ObservableObject {
    private let apiClient = AnthropicAPIClient()
    private let openAIClient = OpenAIAPIClient()
    /// Tier 1 of the OpenAI read ladder (see `pollOpenAI`): asks the locally
    /// installed Codex CLI, so no OpenAI credential is read, stored, or
    /// refreshed by this app. `codexHome: nil` means "whatever this process
    /// inherited" — resolving a different home per account is issue #103.
    private let codexAppServerClient = CodexAppServerClient()
    @Published var lastError: String?
    @Published var credentialStatuses: [CredentialStatus] = []

    private let dbPath: String

    /// `dbPath` defaults to `~/.claude-monitor/usage.db`. An explicit path lets
    /// the CLI (and tests) exercise the real add/poll paths against a throwaway
    /// database — the same escape hatch `UsageStore(dbPath:)` provides, and the
    /// only safe one: `homeDirectoryForCurrentUser` ignores a `HOME` override on
    /// macOS, so redirecting via the environment silently hits the live store
    /// (issue #16).
    init(dbPath: String? = nil) {
        self.dbPath = dbPath ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude-monitor/usage.db").path
    }

    /// The client that speaks a given provider's protocol.
    ///
    /// `.openai` resolves to the HTTP client, not `codexAppServerClient`: this
    /// is the *credential-shaped* surface (`refreshCredentials` in particular),
    /// and the app-server transport deliberately has no credential to refresh.
    /// Transport selection for reads happens in `pollOpenAI`'s tier ladder.
    private func client(for provider: AccountProvider) -> UsageProviderClient {
        switch provider {
        case .anthropic: return apiClient
        case .openai: return openAIClient
        }
    }

    // MARK: - Add Account with Token

    /// Validate a token via a ping, identify org via headers, create/update the account.
    /// Returns the account org ID on success. If email is provided (e.g. from .env), it's stored.
    func addAccountWithToken(_ token: String, email: String? = nil) async -> (orgId: String?, error: String?) {
        // Strip ALL whitespace, not just the ends: pasting a token copied from a
        // terminal often carries embedded newlines/spaces from line-wrapping.
        // OAuth tokens never legitimately contain whitespace, so this is safe.
        let token = token.filter { !$0.isWhitespace }
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

    // MARK: - Add OpenAI / Codex Account

    /// Validate an OpenAI credential against `GET /backend-api/wham/usage`,
    /// then create/update the account from the identity that same response
    /// carries (`account_id`, `email`, `plan_type` — no separate profile call).
    ///
    /// Returns the OpenAI account id on success.
    func addOpenAIAccount(
        accessToken: String,
        refreshToken: String? = nil,
        expiresAt: Date? = nil
    ) async -> (accountId: String?, error: String?) {
        let accessToken = accessToken.filter { !$0.isWhitespace }
        guard !accessToken.isEmpty else { return (nil, "Token is empty") }

        var credentials = ProviderCredentials(
            accessToken: accessToken,
            refreshToken: refreshToken,
            // Fall back to the token's own `exp` claim when the caller has no
            // stated expiry — an OpenAI access token lives ~10 days and the
            // poller must know when to renew it.
            expiresAt: expiresAt ?? OpenAIAPIClient.accessTokenExpiry(accessToken)
        )

        // Renew up front if the imported credential is already stale, so an
        // account added from an old auth.json works immediately.
        if credentials.isExpiring(within: refreshLeadTime), credentials.isRefreshable {
            if let refreshed = try? await openAIClient.refresh(credentials) {
                credentials = refreshed
            }
        }

        let snapshot: ProviderUsageSnapshot
        do {
            snapshot = try await openAIClient.fetchUsage(credentials)
        } catch {
            flog.error("addOpenAIAccount: usage fetch failed: \(error.localizedDescription)", category: fcat)
            return (nil, "Invalid OpenAI credential: \(error.localizedDescription)")
        }

        var accountId = snapshot.accountKey
        if FileManager.default.fileExists(atPath: dbPath),
           let db = try? openDatabase(dbPath, readonly: true) {
            accountId = Self.resolveOpenAIAccountId(
                email: snapshot.email, nativeId: snapshot.accountKey, db: db
            )
        }

        saveCredentialForAccount(
            accountId: accountId,
            email: snapshot.email,
            orgName: nil,
            plan: snapshot.plan ?? "ChatGPT",
            accessToken: credentials.accessToken,
            source: "codex",
            provider: .openai,
            refreshToken: credentials.refreshToken,
            tokenExpiresAt: credentials.expiresAt
        )

        writeSnapshotToDB(accountId: accountId, snapshot: snapshot)

        flog.info("addOpenAIAccount: account \(accountId.prefix(8))... plan \(snapshot.plan ?? "?")", category: fcat)
        return (accountId, nil)
    }

    /// The account row a fresh OpenAI import must land on. Rows created before
    /// the native-id era are keyed by a locally generated UUID rather than
    /// OpenAI's `user-…` account id, so upserting on the native id alone would
    /// create a duplicate sibling for the same account. Match by email within
    /// the provider first — the same guard `AccountSync.importAccount` applies
    /// on multi-host import.
    // Pure function of its arguments (plus the module-level `flog`) — touches
    // no instance/class main-actor state.
    nonisolated static func resolveOpenAIAccountId(email: String?, nativeId: String, db: Connection) -> String {
        guard let email, !email.isEmpty else { return nativeId }
        do {
            let stmt = try db.prepare("""
                SELECT id FROM accounts
                WHERE email = ? AND COALESCE(provider, 'anthropic') = 'openai'
                ORDER BY last_updated DESC
                LIMIT 1
            """)
            for row in stmt.bind(email) {
                if let id = row[0] as? String, !id.isEmpty { return id }
            }
        } catch {
            flog.error("resolveOpenAIAccountId: \(error.localizedDescription)", category: fcat)
        }
        return nativeId
    }

    /// Import the credential Codex CLI stores at `~/.codex/auth.json` (or
    /// `$CODEX_HOME/auth.json`). `path` overrides the location — the self-test
    /// and CLI pass an explicit scratch path rather than relying on a `HOME`
    /// override, which `FileManager.homeDirectoryForCurrentUser` ignores on
    /// macOS (issue #16).
    func importCodexCredential(path: String? = nil) async -> (accountId: String?, error: String?) {
        let credential: CodexAuth.Credential
        do {
            credential = try CodexAuth.load(path: path)
        } catch {
            flog.error("importCodexCredential: \(error.localizedDescription)", category: fcat)
            return (nil, error.localizedDescription)
        }
        return await addOpenAIAccount(
            accessToken: credential.accessToken,
            refreshToken: credential.refreshToken,
            expiresAt: credential.expiresAt
        )
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

    /// Parse an env string for ACCOUNT_EMAIL_N / ACCOUNT_KEY_N pairs (plus the
    /// additive `ACCOUNT_PROVIDER_N` / `ACCOUNT_REFRESH_N` / `ACCOUNT_EXPIRES_N`
    /// keys #67 adds) and import each, dispatching to the provider-appropriate
    /// add-account path.
    func importFromEnvString(_ content: String) async -> [EnvImportResult] {
        let accounts = parseAccountPairs(content)

        if accounts.isEmpty {
            flog.warning("importFromEnvFile: no ACCOUNT_EMAIL_N/ACCOUNT_KEY_N pairs found", category: fcat)
            return [EnvImportResult(email: "—", success: false, error: "No ACCOUNT_EMAIL_N / ACCOUNT_KEY_N pairs found in file")]
        }

        flog.info("importFromEnvFile: found \(accounts.count) account(s)", category: fcat)

        var results: [EnvImportResult] = []
        for account in accounts {
            let error: String?
            switch account.provider {
            case .anthropic:
                (_, error) = await addAccountWithToken(account.token, email: account.email)
            case .openai:
                (_, error) = await addOpenAIAccount(
                    accessToken: account.token,
                    refreshToken: account.refreshToken,
                    expiresAt: account.tokenExpiresAt
                )
            }
            results.append(EnvImportResult(
                email: account.email,
                success: error == nil,
                error: error,
                provider: account.provider
            ))
        }

        return results
    }

    /// Serialize active accounts into ACCOUNT_EMAIL_N / ACCOUNT_KEY_N env
    /// format, the same base format the Bulk Import field and the account
    /// list files accept. Returns nil if there are no exportable accounts (so
    /// the caller can disable the Copy button). Order follows sort_order.
    ///
    /// **Every active provider round-trips (#67).** An Anthropic entry is
    /// just `ACCOUNT_EMAIL_N` / `ACCOUNT_KEY_N`, exactly as before this
    /// format was extended. A non-Anthropic (OpenAI/Codex) entry additionally
    /// carries:
    ///   - `ACCOUNT_PROVIDER_N` — the provider tag (e.g. `openai`)
    ///   - `ACCOUNT_REFRESH_N` — its refresh token, the credential the import
    ///     path actually needs long-term, since the access token in
    ///     `ACCOUNT_KEY_N` expires in ~10 days
    ///   - `ACCOUNT_EXPIRES_N` — the access token's own expiry (ISO 8601), so
    ///     an importing host knows to renew proactively rather than waiting
    ///     for a 401
    ///
    /// All three are additive keys: an old build's `parseAccountPairs()`
    /// doesn't recognize them and ignores them, so a new-format paste into an
    /// old build still imports the Anthropic entries unchanged and only fails
    /// — harmlessly, no account is created — on the OpenAI ones, whose access
    /// token doesn't authenticate against the Anthropic API an old build
    /// assumes.
    ///
    /// Returns the serialized env text alongside the number of accounts it
    /// actually contains, so callers can report an accurate count rather than
    /// re-deriving it from `store.accounts.count`.
    func exportAccountsEnv() -> (env: String, count: Int)? {
        guard FileManager.default.fileExists(atPath: dbPath) else { return nil }
        do {
            let db = try openDatabase(dbPath, readonly: true)
            // `provider` (accounts) and `token_expires_at` (oauth_credentials)
            // are migrated columns (#28) — select them only when present so a
            // database opened before that migration ran still exports its
            // (necessarily all-Anthropic) accounts instead of failing the
            // query outright.
            let hasAcctProvider = tableColumns(db, "accounts").contains("provider")
            let hasTokenExpiry = tableColumns(db, "oauth_credentials").contains("token_expires_at")
            let stmt = try db.prepare("""
                SELECT COALESCE(a.email, a.account_name, c.label) AS email, c.access_token,
                       \(hasAcctProvider ? "a.provider" : "NULL") AS provider,
                       c.refresh_token,
                       \(hasTokenExpiry ? "c.token_expires_at" : "NULL") AS token_expires_at
                FROM oauth_credentials c
                JOIN accounts a ON a.id = c.account_id
                WHERE c.is_active = 1 AND c.access_token IS NOT NULL
                ORDER BY a.sort_order, a.id
            """)

            var lines: [String] = []
            var n = 0
            for row in stmt {
                guard let token = row[1] as? String, !token.isEmpty else { continue }
                n += 1
                let email = (row[0] as? String) ?? "account-\(n)"
                let provider = AccountProvider(stored: row[2] as? String)
                lines.append("ACCOUNT_EMAIL_\(n)=\(email)")
                lines.append("ACCOUNT_KEY_\(n)=\(token)")
                if provider != .anthropic {
                    lines.append("ACCOUNT_PROVIDER_\(n)=\(provider.rawValue)")
                    if let refresh = row[3] as? String, !refresh.isEmpty {
                        lines.append("ACCOUNT_REFRESH_\(n)=\(refresh)")
                    }
                    if let expiresISO = row[4] as? String, !expiresISO.isEmpty {
                        lines.append("ACCOUNT_EXPIRES_\(n)=\(expiresISO)")
                    }
                }
            }

            guard n > 0 else { return nil }

            let header = """
                # Claude Monitor accounts — \(n) account(s)
                # Paste into the app (Add Account → Bulk Import) or save as ~/.claude-monitor/accounts.env

                """
            return (header + lines.joined(separator: "\n") + "\n", n)
        } catch {
            flog.error("exportAccountsEnv failed: \(error.localizedDescription)", category: fcat)
            return nil
        }
    }

    /// One parsed clipboard/env entry. `provider`/`refreshToken`/
    /// `tokenExpiresAt` are additive (#67): an old-format entry (no
    /// `ACCOUNT_PROVIDER_N` key) parses as `.anthropic` with no refresh
    /// token, exactly as every entry parsed before this format was extended.
    // Not private: exercised directly by SelfTest (no network access needed
    // to verify parsing), same pattern as `resolveOpenAIAccountId` below.
    struct ParsedAccountEntry {
        let email: String
        let token: String
        let provider: AccountProvider
        let refreshToken: String?
        let tokenExpiresAt: Date?
    }

    /// Parse env content into ordered entries from ACCOUNT_EMAIL_N /
    /// ACCOUNT_KEY_N (plus the additive per-index provider/refresh/expiry
    /// keys). Gaps in numbering are skipped; order follows the index N.
    func parseAccountPairs(_ content: String) -> [ParsedAccountEntry] {
        var env: [String: String] = [:]
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            guard let eqIndex = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[trimmed.startIndex..<eqIndex]).trimmingCharacters(in: .whitespaces)
            let value = String(trimmed[trimmed.index(after: eqIndex)...]).trimmingCharacters(in: .whitespaces)
            env[key] = value
        }

        var pairs: [ParsedAccountEntry] = []
        for i in 1...99 {
            guard let email = env["ACCOUNT_EMAIL_\(i)"],
                  let token = env["ACCOUNT_KEY_\(i)"] else {
                continue  // Skip gaps — files may have non-consecutive numbering
            }
            let provider = AccountProvider(stored: env["ACCOUNT_PROVIDER_\(i)"])
            let refreshToken = env["ACCOUNT_REFRESH_\(i)"]
            let tokenExpiresAt = env["ACCOUNT_EXPIRES_\(i)"].flatMap { UsageRecord.parseISO($0) }
            pairs.append(ParsedAccountEntry(
                email: email, token: token, provider: provider,
                refreshToken: refreshToken, tokenExpiresAt: tokenExpiresAt
            ))
        }
        return pairs
    }

    // MARK: - Account List Files (master + local override)

    /// Master account list — the shared source of truth.
    private var masterAccountsPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude-monitor/accounts.env").path
    }

    /// Local override/additions — never shared; wins over master by email.
    private var localAccountsPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude-monitor/accounts.local.env").path
    }

    /// Load the master account list plus the local override/additions file, merge
    /// them (local overrides master for a matching email and appends new emails),
    /// and additively import each. Accounts already in the DB but absent from the
    /// merged list are left untouched — this never removes accounts.
    ///
    /// Anthropic-only, unlike `importFromEnvString`: these are periodic
    /// background files, not a one-shot clipboard/file paste, and the
    /// `ACCOUNT_PROVIDER_N` key #67 adds is not expected to appear here. A
    /// non-Anthropic entry (if one ever did appear) is imported via
    /// `addAccountWithToken` same as before — it fails harmlessly (invalid
    /// token against the Anthropic API), matching the pre-#67 behavior for
    /// any account this format couldn't express.
    @discardableResult
    func syncFromAccountFiles() async -> [EnvImportResult] {
        let fm = FileManager.default
        var merged: [ParsedAccountEntry] = []
        var indexByEmail: [String: Int] = [:]

        func apply(_ path: String, label: String) {
            guard fm.fileExists(atPath: path),
                  let content = try? String(contentsOfFile: path, encoding: .utf8) else { return }
            let pairs = parseAccountPairs(content)
            flog.info("syncFromAccountFiles: \(label) lists \(pairs.count) account(s)", category: fcat)
            for pair in pairs {
                if let existing = indexByEmail[pair.email] {
                    merged[existing] = pair            // local overrides master token
                } else {
                    indexByEmail[pair.email] = merged.count
                    merged.append(pair)                // addition, order preserved
                }
            }
        }

        apply(masterAccountsPath, label: "master")
        apply(localAccountsPath, label: "local")

        guard !merged.isEmpty else {
            flog.info("syncFromAccountFiles: no account list files found", category: fcat)
            return []
        }

        flog.info("syncFromAccountFiles: importing \(merged.count) merged account(s)", category: fcat)
        var results: [EnvImportResult] = []
        for pair in merged {
            let (_, error) = await addAccountWithToken(pair.token, email: pair.email)
            results.append(EnvImportResult(email: pair.email, success: error == nil, error: error))
        }
        return results
    }

    // MARK: - Save Credential for Account

    private func saveCredentialForAccount(
        accountId: String, email: String?, orgName: String?, plan: String,
        accessToken: String, source: String = "token",
        provider: AccountProvider = .anthropic,
        refreshToken: String? = nil, tokenExpiresAt: Date? = nil
    ) {
        guard FileManager.default.fileExists(atPath: dbPath) else { return }
        do {
            let db = try openDatabase(dbPath)
            let now = ISO8601DateFormatter().string(from: Date())
            let label = orgName ?? email ?? accountId
            let providerValue = provider.rawValue
            let expiryISO = tokenExpiresAt.map { ISO8601DateFormatter().string(from: $0) }

            // When the profile/caller-supplied email is unavailable, fall back to
            // the label itself if it's a well-formed address — an account must
            // never persist indefinitely with email = NULL just because its
            // profile fetch failed (or was never attempted) while the label
            // plainly carries the address (#15).
            let resolvedEmail = email ?? (looksLikeEmailAddress(label) ? label : nil)

            // Upsert account — never overwrite account_name (user may have renamed)
            try db.run("""
                INSERT INTO accounts (id, account_name, email, plan, last_updated, sort_order, provider)
                VALUES (?, ?, ?, ?, ?, COALESCE((SELECT MAX(sort_order) + 1 FROM accounts), 0), ?)
                ON CONFLICT(id) DO UPDATE SET
                    email = COALESCE(excluded.email, accounts.email),
                    plan = COALESCE(excluded.plan, accounts.plan),
                    last_updated = excluded.last_updated,
                    provider = excluded.provider
            """, accountId, label, resolvedEmail, plan, now, providerValue)

            // Look for existing credential for THIS account
            let existingCred = try db.scalar(
                "SELECT id FROM oauth_credentials WHERE account_id = ? LIMIT 1",
                accountId
            ) as? Int64
            let existingToken = try db.scalar(
                "SELECT access_token FROM oauth_credentials WHERE account_id = ? LIMIT 1",
                accountId
            ) as? String

            if let credId = existingCred {
                // Only stamp token_rolled_at when the token value actually changes,
                // so the periodic .env re-sync (same token) doesn't reset the clock.
                let tokenChanged = existingToken != accessToken
                if tokenChanged {
                    try db.run("""
                        UPDATE oauth_credentials SET
                            access_token = ?, source = ?, provider = ?,
                            refresh_token = COALESCE(?, refresh_token),
                            token_expires_at = ?,
                            is_active = 1, updated_at = ?, token_rolled_at = ?
                        WHERE id = ?
                    """, accessToken, source, providerValue, refreshToken, expiryISO, now, now, credId)
                    flog.info("Rolled credential for account \(accountId)", category: fcat)
                } else {
                    try db.run("""
                        UPDATE oauth_credentials SET
                            source = ?, provider = ?, is_active = 1, updated_at = ?
                        WHERE id = ?
                    """, source, providerValue, now, credId)
                    flog.info("Updated credential for account \(accountId)", category: fcat)
                }
            } else {
                try db.run("""
                    INSERT INTO oauth_credentials (
                        account_id, label, source, provider,
                        access_token, refresh_token, token_expires_at,
                        is_active, created_at, updated_at, token_rolled_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, 1, ?, ?, ?)
                """, accountId, label, source, providerValue,
                     accessToken, refreshToken, expiryISO, now, now, now)
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
            let db = try openDatabase(dbPath, readonly: true)
            var credentials: [OAuthCredential] = []

            // The provider columns are selected only when present, so a
            // database opened before the migration ran still loads (every row
            // then resolves to the Anthropic fallback).
            let columns = tableColumns(db, "oauth_credentials")
            let hasProvider = columns.contains("provider")
            let hasTokenExpiry = columns.contains("token_expires_at")
            let stmt = try db.prepare("""
                SELECT id, account_id, label, source,
                       access_token, refresh_token, expires_at,
                       subscription_type, rate_limit_tier, is_active,
                       \(hasProvider ? "provider" : "NULL"),
                       \(hasTokenExpiry ? "token_expires_at" : "NULL")
                FROM oauth_credentials
                WHERE is_active = 1 AND access_token IS NOT NULL
            """)

            for row in stmt {
                credentials.append(OAuthCredential(
                    id: row[0] as? Int64,
                    accountId: row[1] as? String,
                    provider: AccountProvider(stored: row[10] as? String),
                    label: (row[2] as? String) ?? "Unknown",
                    source: (row[3] as? String) ?? "token",
                    accessToken: row[4] as? String,
                    refreshToken: row[5] as? String,
                    expiresAt: row[6] as? Int64,
                    tokenExpiresAt: UsageRecord.parseISO(row[11] as? String),
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

    // MARK: - Token Rolling Support

    /// The active access token currently stored for an account, if any.
    func currentToken(for accountId: String) -> String? {
        loadActiveCredentials().first { $0.accountId == accountId }?.accessToken
    }

    /// When this account's token was last set/rolled (token value last changed),
    /// or nil if unknown (older credential written before we tracked this).
    func tokenRolledAt(for accountId: String) -> Date? {
        guard FileManager.default.fileExists(atPath: dbPath) else { return nil }
        do {
            let db = try openDatabase(dbPath, readonly: true)
            guard let iso = try db.scalar(
                "SELECT token_rolled_at FROM oauth_credentials WHERE account_id = ? AND token_rolled_at IS NOT NULL LIMIT 1",
                accountId
            ) as? String else { return nil }
            return ISO8601DateFormatter().date(from: iso)
        } catch {
            flog.error("tokenRolledAt failed: \(error.localizedDescription)", category: fcat)
            return nil
        }
    }

    /// Ping a token to see whether it has been revoked. Returns `true` if the API
    /// rejects it with 401 (dead), `false` if it still authenticates (200/429),
    /// and `nil` if the check itself failed (network/other) so the caller can say
    /// "couldn't verify" rather than claim success. A depleted-but-valid account
    /// answers 429, which correctly reads as "still alive."
    func verifyTokenRevoked(_ token: String) async -> Bool? {
        do {
            _ = try await apiClient.pingToken(accessToken: token)
            return false  // 200/429 → still valid
        } catch AnthropicAPIError.unauthorized {
            return true   // 401 → revoked
        } catch let error as AnthropicAPIError where error.isTransient {
            return nil    // network/5xx → indeterminate
        } catch {
            return nil
        }
    }

    // MARK: - Deactivate Credential

    func deactivateCredential(_ credential: OAuthCredential) {
        guard let credId = credential.id,
              FileManager.default.fileExists(atPath: dbPath) else { return }
        do {
            let db = try openDatabase(dbPath)
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

    /// How often each account should be polled (seconds). Headless mode may
    /// override this via --interval; the app keeps the default.
    var pollInterval: TimeInterval = 600  // 10 minutes

    /// Last poll time per credential ID
    private var lastPollTimes: [Int64: Date] = [:]

    /// How often to probe the Fable tier per account (seconds). Independent of the
    /// Haiku poll — a few times an hour is enough to track Fable availability/usage
    /// without spending meaningful Fable quota.
    private let fableProbeInterval: TimeInterval = 1200  // 20 minutes → ~3×/hour
    private let fableProbeModel = "claude-fable-5"
    private var lastFableProbeTimes: [String: Date] = [:]

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

    /// Probe the Fable tier for any account whose Fable-probe interval has elapsed,
    /// archiving whatever the API returns (a headerless 429 today; real Fable
    /// rate-limit data once extra-usage credits are enabled). Returns count probed.
    func probeFableDue() async -> Int {
        let credentials = loadActiveCredentials()
        guard !credentials.isEmpty else { return 0 }

        let now = Date()
        var probed = 0

        for credential in credentials {
            // Fable is an Anthropic premium tier; other providers expose their
            // per-model sub-limits in the usage response itself.
            guard credential.provider == .anthropic else { continue }
            guard let accountId = credential.accountId,
                  let token = credential.accessToken else { continue }
            let last = lastFableProbeTimes[accountId]
            guard last == nil || now.timeIntervalSince(last!) >= fableProbeInterval else { continue }

            let (status, headers) = await apiClient.rawProbe(accessToken: token, model: fableProbeModel)
            if status > 0 {
                archiveSnapshot(accountId: accountId, probeModel: "fable", httpStatus: status, headers: headers)
                flog.info("Fable probe \(status) — org: \(accountId.prefix(8))... (\(headers.count) header(s))", category: fcat)
            }
            lastFableProbeTimes[accountId] = Date()
            probed += 1
        }

        return probed
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
            } catch is CredentialExpiredError {
                // The refresh path already recorded `.expired` plus an
                // actionable message; retrying or downgrading it to the generic
                // "revoked" would bury the reason. Stop here.
                return
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
        switch credential.provider {
        case .anthropic:
            try await pollAnthropic(credential)
        case .openai:
            try await pollOpenAI(credential)
        }
    }

    private func pollAnthropic(_ credential: OAuthCredential) async throws {
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

    /// Read one OpenAI/Codex account, preferring the transport that touches the
    /// fewest credentials.
    ///
    /// OpenAI rotates the refresh token on every use and supports exactly one
    /// `auth.json` per machine, so *any* copy this app keeps is a copy that will
    /// eventually invalidate Codex CLI's — and vice versa. The ladder is ordered
    /// by how little credential handling each rung needs:
    ///
    /// 1. **`codex app-server`** — the Codex CLI owns the credential entirely;
    ///    we read nothing. Preferred whenever the binary resolves and the RPC
    ///    answers.
    /// 2. **`auth.json` at request time** — read the current bearer, use it once,
    ///    never write it back and never refresh it. Removes the rotation race
    ///    even without the RPC.
    /// 3. **Stored credential** — today's exact behaviour, proactive refresh
    ///    included. Last resort; issue #104 deletes it.
    ///
    /// A tier that is merely *unavailable* (no codex binary, codex too old, no
    /// `auth.json`) never marks the account unhealthy — it falls through
    /// silently. Only the last tier's own failure sets a status.
    private func pollOpenAI(_ credential: OAuthCredential) async throws {
        // The account id is not on the app-server wire at all, so the stored one
        // is what the higher tiers write against.
        let storedAccountId = credential.accountId.flatMap { $0.isEmpty ? nil : $0 }

        // MARK: Tier 1 — codex app-server (no credential touched)
        if let storedAccountId = storedAccountId {
            do {
                let snapshot = try await codexAppServerClient.fetchUsage()
                // The reading is only this account's if the local Codex login is
                // this account. Verified after the fact rather than before it
                // because `account/read` is the only place that identity exists.
                if codexHomeConflicts(with: credential, reportedEmail: snapshot.email) {
                    noteCodexIdentityConflict(credential)
                } else {
                    writeSnapshotToDB(accountId: storedAccountId, snapshot: snapshot)
                    updateCredentialLastPoll(credential, error: nil)
                    updateCredentialStatus(credential, status: .valid, error: nil)
                    await MainActor.run { self.lastError = nil }
                    return
                }
            } catch let error as CodexAppServerError {
                noteCodexFallback(credential, error)
            } catch {
                flog.warning("codex app-server read failed for \(credential.label): \(error.localizedDescription) — falling back", category: fcat)
            }
        }

        // MARK: Tier 2 — bearer read from auth.json at request time
        //
        // Read, used once, and dropped: never persisted, never refreshed. That
        // alone removes the rotation race, so it is worth trying before the
        // stored copy even when the RPC is unavailable.
        if let live = try? CodexAuth.load(), let storedAccountId = storedAccountId,
           !codexHomeConflicts(with: credential, reportedAccountId: live.accountId) {
            do {
                let snapshot = try await openAIClient.fetchUsage(accessToken: live.accessToken)
                writeSnapshotToDB(accountId: storedAccountId, snapshot: snapshot)
                updateCredentialLastPoll(credential, error: nil)
                updateCredentialStatus(credential, status: .valid, error: nil)
                await MainActor.run { self.lastError = nil }
                return
            } catch {
                flog.warning("auth.json bearer read failed for \(credential.label): \(error.localizedDescription) — falling back to the stored credential", category: fcat)
            }
        }

        // MARK: Tier 3 — stored credential (unchanged; removed by #104)
        guard let stored = credential.providerCredentials else {
            let reason = pendingCodexFailure(credential)?.localizedDescription ?? "No access token"
            let status = pendingCodexFailure(credential)?.tokenStatus ?? .missing
            updateCredentialStatus(credential, status: status, error: reason)
            throw AnthropicAPIError.unauthorized
        }

        // Proactive, not reactive: renew ahead of expiry rather than waiting
        // for a 401. Throws (loudly, with a visible token-health state) when the
        // token is already dead and cannot be renewed.
        let renewal = try await refreshIfNeeded(credential, stored)

        let snapshot = try await openAIClient.fetchUsage(renewal.credentials)

        // Prefer the stored account_id; fall back to the one the response
        // carries so a credential imported before identification still lands.
        let accountId = storedAccountId ?? snapshot.accountKey
        guard !accountId.isEmpty else {
            flog.warning("Credential \(credential.label) has no account_id", category: fcat)
            return
        }

        writeSnapshotToDB(accountId: accountId, snapshot: snapshot)

        // A successful read does NOT clear a refresh warning: the usage figures
        // are current, but the credential is still on a path to expiry that we
        // could not renew. Surfacing that now (yellow dot + reason) is the whole
        // point of refreshing proactively.
        if let warning = renewal.warning {
            updateCredentialLastPoll(credential, error: warning)
            updateCredentialStatus(credential, status: .refreshing, error: warning)
        } else {
            updateCredentialLastPoll(credential, error: nil)
            updateCredentialStatus(credential, status: .valid, error: nil)
        }

        await MainActor.run {
            self.lastError = nil
        }
    }

    // MARK: - Codex app-server fallback bookkeeping

    /// The last tier-1 failure per credential, kept only so a *total* failure
    /// (every tier down) can report the most actionable reason — "Codex home not
    /// logged in" beats "No access token". Cleared implicitly: a later success
    /// never reads it.
    private var lastCodexFailure: [Int64: CodexAppServerError] = [:]
    /// Capability gaps are logged once per credential, not once per poll: a host
    /// without `codex` installed would otherwise write the same line every
    /// interval, forever.
    private var loggedCodexCapabilityGap: Set<Int64> = []

    private func noteCodexFallback(_ credential: OAuthCredential, _ error: CodexAppServerError) {
        guard let id = credential.id else { return }
        lastCodexFailure[id] = error

        if error.isCapabilityGap {
            // Not an account failure — verified: codex 0.46.0 answers -32600
            // identically for an unsupported method and a bogus one, so this
            // signal can only ever mean "this transport is unavailable here".
            if loggedCodexCapabilityGap.insert(id).inserted {
                flog.info("codex app-server unavailable for \(credential.label): \(error.localizedDescription) — using the fallback path", category: fcat)
            }
        } else {
            flog.warning("codex app-server: \(error.localizedDescription) — falling back for \(credential.label)", category: fcat)
        }
    }

    private func pendingCodexFailure(_ credential: OAuthCredential) -> CodexAppServerError? {
        credential.id.flatMap { lastCodexFailure[$0] }
    }

    // MARK: - Codex home identity guard

    /// Credentials whose Codex home demonstrably belongs to someone else, logged
    /// once rather than every poll.
    private var loggedCodexIdentityConflict: Set<Int64> = []

    /// True when the local Codex login demonstrably belongs to a **different**
    /// account than this credential.
    ///
    /// Tiers 1 and 2 both read whichever `CODEX_HOME` this process inherited,
    /// and that single home speaks for exactly one account. On a host with two
    /// OpenAI accounts, attributing its reading to both would overwrite one
    /// account's usage with a stranger's — a silent data corruption, since the
    /// numbers look perfectly plausible. Resolving a *different* home per
    /// account is issue #103; until it lands, a demonstrated conflict is enough
    /// to leave this account on its own stored credential.
    ///
    /// Deliberately asymmetric: only a **contradiction** disqualifies a tier.
    /// Absent identity on either side proves nothing, so the ordinary
    /// single-account host — where neither the row nor the wire need carry an
    /// email — keeps using the preferred transport.
    private func codexHomeConflicts(with credential: OAuthCredential, reportedEmail: String?) -> Bool {
        guard let accountId = credential.accountId, !accountId.isEmpty else { return false }
        return Self.identitiesConflict(reportedEmail, storedEmail(for: accountId))
    }

    /// Same guard for tier 2, where `auth.json` carries an account id rather
    /// than an email. Both sides are the ChatGPT `account_id`, so a mismatch is
    /// as conclusive as the email one.
    private func codexHomeConflicts(with credential: OAuthCredential, reportedAccountId: String?) -> Bool {
        Self.identitiesConflict(reportedAccountId, credential.accountId)
    }

    /// Two identity strings that are both known and disagree. Pure function of
    /// its arguments so the self-test can pin the asymmetry directly.
    nonisolated static func identitiesConflict(_ lhs: String?, _ rhs: String?) -> Bool {
        func normalized(_ value: String?) -> String? {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return (trimmed?.isEmpty == false) ? trimmed : nil
        }
        guard let lhs = normalized(lhs), let rhs = normalized(rhs) else { return false }
        return lhs != rhs
    }

    /// The email recorded on an account row, used only to tell two OpenAI
    /// accounts apart. Never logged.
    private func storedEmail(for accountId: String) -> String? {
        guard FileManager.default.fileExists(atPath: dbPath) else { return nil }
        do {
            let db = try openDatabase(dbPath, readonly: true)
            return try db.scalar("SELECT email FROM accounts WHERE id = ?", accountId) as? String
        } catch {
            flog.error("storedEmail failed: \(error.localizedDescription)", category: fcat)
            return nil
        }
    }

    private func noteCodexIdentityConflict(_ credential: OAuthCredential) {
        guard let id = credential.id else { return }
        if loggedCodexIdentityConflict.insert(id).inserted {
            flog.info(
                "codex app-server reports a different account than \(credential.label) — this host's CODEX_HOME belongs to another login, using the stored credential instead (per-account CODEX_HOME is issue #103)",
                category: fcat
            )
        }
    }

    // MARK: - Proactive Token Refresh

    /// How far ahead of expiry a credential is renewed. Comfortably longer than
    /// the poll interval, so a token never expires between two poll cycles.
    let refreshLeadTime: TimeInterval = 6 * 3600

    /// What `refreshIfNeeded` decided: the credential to poll with, plus a
    /// non-nil `warning` when renewal was needed but didn't happen and the
    /// current token is nonetheless still inside its validity window.
    struct RenewalOutcome {
        let credentials: ProviderCredentials
        let warning: String?
    }

    /// Renew `credentials` when they are at or near expiry, persisting the
    /// result. Anthropic credentials state no expiry and short-circuit here.
    ///
    /// Failure is **never silent**:
    /// - token already past expiry and unrenewable → `.expired` (red dot) with
    ///   an actionable message, and the caller throws rather than issuing a
    ///   request with a token we already know is dead;
    /// - renewal failed but the token is still valid → a `warning` the caller
    ///   surfaces as `.refreshing` (yellow dot), and polling continues on the
    ///   current token.
    private func refreshIfNeeded(
        _ credential: OAuthCredential,
        _ credentials: ProviderCredentials
    ) async throws -> RenewalOutcome {
        guard credentials.isExpiring(within: refreshLeadTime) else {
            return RenewalOutcome(credentials: credentials, warning: nil)
        }

        var reason: String
        if !credentials.isRefreshable {
            reason = "Access token expires soon and no refresh token is stored — re-import with `claude-monitor codex import`"
        } else {
            do {
                if let refreshed = try await client(for: credential.provider)
                    .refreshCredentials(credentials) {
                    persistRefreshedCredential(credential, refreshed)
                    return RenewalOutcome(credentials: refreshed, warning: nil)
                }
                // Provider has nothing to refresh (Anthropic's default).
                return RenewalOutcome(credentials: credentials, warning: nil)
            } catch {
                reason = "Token refresh failed: \(error.localizedDescription)"
            }
        }

        let alreadyExpired = credentials.expiresAt.map { $0 <= Date() } ?? false
        if alreadyExpired {
            updateCredentialLastPoll(credential, error: reason)
            updateCredentialStatus(credential, status: .expired, error: reason)
            flog.error("\(credential.label): \(reason) — token already expired, skipping poll", category: fcat)
            throw CredentialExpiredError(reason: reason)
        }

        flog.warning("\(credential.label): \(reason) — token still valid, polling with it", category: fcat)
        return RenewalOutcome(credentials: credentials, warning: reason)
    }

    /// Write a renewed access/refresh token pair back to `oauth_credentials`.
    /// OpenAI rotates refresh tokens, so both halves are replaced together.
    private func persistRefreshedCredential(_ credential: OAuthCredential, _ refreshed: ProviderCredentials) {
        guard let credId = credential.id,
              FileManager.default.fileExists(atPath: dbPath) else { return }
        do {
            let db = try openDatabase(dbPath)
            let now = ISO8601DateFormatter().string(from: Date())
            let expiryISO = refreshed.expiresAt.map { ISO8601DateFormatter().string(from: $0) }
            try db.run("""
                UPDATE oauth_credentials SET
                    access_token = ?,
                    refresh_token = COALESCE(?, refresh_token),
                    token_expires_at = ?,
                    is_active = 1, last_error = NULL,
                    updated_at = ?, token_rolled_at = ?
                WHERE id = ?
            """, refreshed.accessToken, refreshed.refreshToken, expiryISO, now, now, credId)
            flog.info("Persisted refreshed credential for \(credential.label)", category: fcat)
        } catch {
            flog.error("Failed to persist refreshed credential: \(error.localizedDescription)", category: fcat)
        }
    }

    // MARK: - Write Usage Data to DB

    private func writePingToDB(accountId: String, ping: PingResponse) {
        // `?? 0` preserves the long-standing Anthropic behavior of storing 0 for
        // an absent header. Anthropic always reports both windows in practice,
        // and existing history rows are all 0-filled, so keeping the coercion
        // here avoids introducing NULLs into a series that has never had them.
        let windows = ping.rateLimit
        writeUsageToDB(
            accountId: accountId,
            sessionPercent: windows.session?.usedPercent ?? 0,
            weeklyPercent: windows.weekly?.usedPercent ?? 0,
            sessionReset: windows.session?.resetAtISO,
            weeklyReset: windows.weekly?.resetAtISO,
            rawFields: ping.rawHeaders,
            probeModel: "haiku",
            httpStatus: ping.httpStatus,
            namedLimits: windows.named
        )
    }

    /// Persist a provider-agnostic usage reading.
    ///
    /// Unlike the Anthropic path, an absent window is written as **NULL**, not
    /// 0 — an OpenAI account may legitimately report no session window, and
    /// storing 0 there would read downstream as "no session capacity used",
    /// inflating the account's apparent headroom.
    private func writeSnapshotToDB(accountId: String, snapshot: ProviderUsageSnapshot) {
        let windows = snapshot.rateLimit
        writeUsageToDB(
            accountId: accountId,
            sessionPercent: windows.session?.usedPercent,
            weeklyPercent: windows.weekly?.usedPercent,
            sessionReset: windows.session?.resetAtISO,
            weeklyReset: windows.weekly?.resetAtISO,
            rawFields: snapshot.rawFields,
            probeModel: "\(snapshot.provider.rawValue)-usage",
            httpStatus: snapshot.httpStatus,
            namedLimits: windows.named
        )
    }

    /// The single write path for both providers: one `usage_history` row plus a
    /// verbatim `probe_snapshots` archive entry.
    ///
    /// `namedLimits` additionally writes one `named_limits` row per entry
    /// (OpenAI's `additional_rate_limits[]`), stamped with the same timestamp
    /// as the `usage_history` row. Empty for Anthropic pings today, so those
    /// accounts continue to produce zero `named_limits` rows.
    private func writeUsageToDB(
        accountId: String,
        sessionPercent: Double?,
        weeklyPercent: Double?,
        sessionReset: String?,
        weeklyReset: String?,
        rawFields: [String: String],
        probeModel: String,
        httpStatus: Int,
        namedLimits: [String: RateLimitWindow] = [:]
    ) {
        guard FileManager.default.fileExists(atPath: dbPath) else { return }

        do {
            let db = try openDatabase(dbPath)
            let now = ISO8601DateFormatter().string(from: Date())

            let primaryPercent = [sessionPercent, weeklyPercent].compactMap { $0 }.max()

            // Reset detection: a large drop in the weekly figure means the
            // window rolled over. Only meaningful when this provider actually
            // reports a weekly window.
            if let weeklyPercent = weeklyPercent {
                let prevStmt = try db.prepare(
                    "SELECT primary_percent, session_percent, weekly_all_percent, weekly_sonnet_percent, timestamp FROM usage_history WHERE account_id = ? ORDER BY timestamp DESC LIMIT 1"
                )
                for prev in prevStmt.bind(accountId) {
                    let prevWeekly = (prev[2] as? Double) ?? 0
                    if prevWeekly - weeklyPercent > 5 {
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
            }

            // Store the full captured field set (not a hand-picked subset) so
            // the archive keeps up with new fields the provider adds.
            let rawData = headersJSON(rawFields)

            try db.run("""
                INSERT INTO usage_history (
                    account_id, timestamp, primary_percent, session_percent,
                    weekly_all_percent, weekly_sonnet_percent, session_reset, weekly_reset, raw_data, is_synthetic
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 0)
            """, accountId, now, primaryPercent, sessionPercent,
               weeklyPercent, 0.0, sessionReset, weeklyReset, rawData)

            UsageStore.insertNamedLimits(db, accountId: accountId, timestamp: now, named: namedLimits)

            try db.run("UPDATE accounts SET last_updated = ? WHERE id = ?", now, accountId)

        } catch {
            flog.error("Failed to write usage to DB: \(error.localizedDescription)", category: fcat)
        }

        // Archive the raw capture regardless of the curated write above.
        archiveSnapshot(accountId: accountId, probeModel: probeModel,
                        httpStatus: httpStatus, headers: rawFields)
    }

    // MARK: - Raw Snapshot Archive

    /// Serialize a header dictionary to a stable (sorted-key) JSON string.
    private func headersJSON(_ headers: [String: String]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(headers),
              let str = String(data: data, encoding: .utf8) else { return "{}" }
        return str
    }

    /// Append one raw probe result to `probe_snapshots`. This is the "store
    /// everything" archive — every field, understood or not, per poll per model.
    func archiveSnapshot(accountId: String, probeModel: String, httpStatus: Int, headers: [String: String]) {
        guard FileManager.default.fileExists(atPath: dbPath) else { return }
        do {
            let db = try openDatabase(dbPath)
            let now = ISO8601DateFormatter().string(from: Date())
            try db.run("""
                INSERT INTO probe_snapshots (account_id, timestamp, probe_model, http_status, headers)
                VALUES (?, ?, ?, ?, ?)
            """, accountId, now, probeModel, httpStatus, headersJSON(headers))
        } catch {
            flog.error("Failed to archive \(probeModel) snapshot: \(error.localizedDescription)", category: fcat)
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
            let db = try openDatabase(dbPath)
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
