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
    /// The Codex home this account is registered against is currently logged
    /// in as a *different* identity (#146). Distinct from every other case:
    /// not a transient poll failure (`.error`/`.revoked`), not `.missing` (a
    /// credential exists — it just cannot be attributed), and never `.valid`,
    /// because the numbers on this row stopped advancing the moment the home
    /// drifted. Re-derived fresh on every poll rather than latched, so a
    /// later poll that finds the identity restored — home re-registered, or
    /// the original login restored — reports `.valid` again with no restart.
    ///
    /// Raw value is deliberately `"drift"`, matching `CodexCLI.driftLabel` —
    /// `SelfTest` pins the two literals equal so the popover and
    /// `codex list` can never name this condition two different ways.
    case drifted = "drift"
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
    /// The `accounts.codex_home` of the account this credential belongs to,
    /// carried along so the poll loop can build this account's own
    /// `CodexAppServerClient` without a second query. nil = no registered home
    /// (the ambient `$CODEX_HOME`, else `~/.codex`).
    let codexHome: String?

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
        isActive: Bool,
        codexHome: String? = nil
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
        self.codexHome = codexHome
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
    /// This entry carried no credential — it declared an identity this host is
    /// expected to have (#135) rather than importing an account. Kept distinct
    /// from a merely failed import so `pasteAccounts()` can exclude it from
    /// replace semantics: a declaration says "this identity exists", never
    /// "every other identity of this provider should be deleted".
    var identityOnly: Bool = false
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

    /// Which existing `provider = 'openai'` account row (if any) an identity
    /// belongs to — the read half of re-attribution (#147). Same precedence
    /// `resolveOpenAIAccountId` already uses for a fresh import (native id,
    /// the stable key `codex add --home` registers by, then email), so an
    /// automatic re-attribution and a manual `codex add --home` can never
    /// disagree about which row an identity belongs to. Unlike
    /// `resolveOpenAIAccountId`, this returns `nil` — not a guessed id —
    /// when nothing matches, so the caller can tell "reuse this row" apart
    /// from "nothing exists yet, mint one."
    // Pure function of its arguments (plus the module-level `flog`) — touches
    // no instance/class main-actor state.
    nonisolated static func lookupOpenAIAccountId(nativeId: String?, email: String?, db: Connection) -> String? {
        do {
            if let nativeId, !nativeId.isEmpty {
                if let id = try db.scalar(
                    "SELECT id FROM accounts WHERE id = ? AND COALESCE(provider, 'anthropic') = 'openai'",
                    nativeId
                ) as? String, !id.isEmpty {
                    return id
                }
            }
            if let email, !email.isEmpty {
                if let id = try db.scalar("""
                    SELECT id FROM accounts
                    WHERE email = ? AND COALESCE(provider, 'anthropic') = 'openai'
                    ORDER BY last_updated DESC
                    LIMIT 1
                """, email) as? String, !id.isEmpty {
                    return id
                }
            }
        } catch {
            flog.error("lookupOpenAIAccountId: \(error.localizedDescription)", category: fcat)
        }
        return nil
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

    // MARK: - Register a Codex home (per-account CODEX_HOME, #103)

    /// One registered Codex account, for `claude-monitor codex list`.
    ///
    /// The CLI identifies accounts by the truncated-id convention the rest of
    /// this surface uses — `email` below is carried for internal comparison
    /// only and is never printed.
    struct CodexAccountRegistration {
        let accountId: String
        /// nil = no registered home (the ambient `$CODEX_HOME`, else `~/.codex`).
        let codexHome: String?
        let plan: String?
        /// Whether a token is still stored for this account (tier 3). A
        /// home-registered account has none, which is the point.
        let hasStoredToken: Bool
        /// The email on the account row, carried **only** so a drift check can
        /// compare it with what the home reports. `codex list` never prints
        /// it — see the file comment on `CodexCLI`.
        let email: String?
        /// The display label on the account row (`accounts.account_name`).
        /// For a declared-but-absent identity this is the `<label>` half of
        /// `~/.codex-<label>` carried across by the transfer payload, which is
        /// exactly the argument `codex provision <label>` wants. Never a path.
        let accountName: String?
        /// Whether this host has ever recorded a usage reading for this
        /// account — the conservative guard in `isAbsentCodexIdentity`.
        var hasLocalReading: Bool = false

        /// This host is expected to have this identity but was never
        /// provisioned with it (#135) — no stored token, no registered home,
        /// and no reading ever taken here. Same rule the popover and
        /// `ranking.json` apply (`isAbsentCodexIdentity`).
        var isAbsent: Bool {
            isAbsentCodexIdentity(
                provider: .openai,
                hasStoredToken: hasStoredToken,
                hasCodexHome: codexHome != nil,
                hasLocalReading: hasLocalReading
            )
        }

        /// The `codex provision <label>` argument that would fill this gap, or
        /// nil when the payload carried no label. Only ever a bare label — a
        /// value containing a path separator is rejected rather than echoed,
        /// since `provision` would reject it too.
        var provisionLabel: String? {
            OAuthPoller.codexHomeLabel(codexHome) ?? OAuthPoller.provisionLabelCandidate(accountName)
        }
    }

    /// Register an account by its `CODEX_HOME`, storing **no token**.
    ///
    /// The identity comes from two places, in order:
    ///
    /// 1. `<home>/auth.json`'s `tokens.account_id` — read via
    ///    `CodexAuth.accountId(inHome:)`, which touches that one opaque field
    ///    and never a token. `account/read` carries no account id on any
    ///    verified `app-server` version, so this is the only source of a stable
    ///    `user-…` key.
    /// 2. The email `account/read` reports, matched against an existing
    ///    `provider = 'openai'` row by `resolveOpenAIAccountId` — so a home
    ///    registered for an account that already exists updates that row rather
    ///    than minting a duplicate sibling (the #45 failure mode).
    ///
    /// Returns the account id it landed on, plus a non-fatal warning when the
    /// home registered but its usage could not be read yet.
    func registerCodexHome(_ rawHome: String) async -> (accountId: String?, error: String?) {
        let home = Self.normalizeCodexHome(rawHome)
        guard FileManager.default.fileExists(atPath: home) else {
            return (nil, CodexAppServerError.homeMissing(home).localizedDescription)
        }

        // Read before the probe: an account id from auth.json lets registration
        // still succeed on a codex too old to answer `account/read`.
        let nativeId = CodexAuth.accountId(inHome: home)

        let client = CodexAppServerClient(codexHome: home)
        var identity: CodexAccountIdentity?
        var snapshot: ProviderUsageSnapshot?
        var warning: String?

        do {
            let usage = try await client.fetchUsage()
            snapshot = usage
            identity = CodexAccountIdentity(email: usage.email, planType: usage.plan)
        } catch let error as CodexAppServerError {
            switch error {
            case .notLoggedIn, .homeMissing:
                // The actionable states: there is nothing to register yet.
                return (nil, error.localizedDescription)
            case .methodUnsupported:
                // A codex too old for `account/rateLimits/read` may still answer
                // `account/read`; and even if it doesn't, auth.json's account id
                // is enough to register a home the fallback tiers can use.
                identity = try? await client.fetchAccountIdentity()
                warning = error.localizedDescription
            case .binaryNotFound, .launchFailed:
                guard nativeId != nil else { return (nil, error.localizedDescription) }
                warning = error.localizedDescription
            case .timedOut, .protocolFailure:
                return (nil, error.localizedDescription)
            }
        } catch {
            return (nil, error.localizedDescription)
        }

        let email = identity?.email
        var accountId = nativeId ?? ""
        if FileManager.default.fileExists(atPath: dbPath),
           let db = try? openDatabase(dbPath, readonly: true) {
            accountId = Self.resolveOpenAIAccountId(email: email, nativeId: accountId, db: db)
        }
        if accountId.isEmpty {
            // No `account_id` in auth.json and no existing row to match. Mint a
            // local id, which is safe precisely because the email lookup above
            // already ruled out a duplicate.
            guard email?.isEmpty == false else {
                return (nil, "Could not identify the account at \(home) — its auth.json carries no account_id and `account/read` reported no email. Run `CODEX_HOME=\(home) codex login --device-auth` and try again.")
            }
            accountId = "openai-\(UUID().uuidString.lowercased())"
        }

        // Deliberately optional: on a degraded registration (no codex binary,
        // a codex too old) we learned no plan, and a placeholder would
        // *overwrite* the real one an earlier read had already stored.
        saveCodexHomeAccount(
            accountId: accountId,
            email: email,
            plan: identity?.planType ?? snapshot?.plan,
            codexHome: home
        )

        if let snapshot = snapshot {
            writeSnapshotToDB(accountId: accountId, snapshot: snapshot)
        }

        // Never the home path: this line goes to debug.log.
        flog.info("codex add: registered OpenAI account \(accountId.prefix(8))… against its own CODEX_HOME", category: fcat)
        return (accountId, warning)
    }

    /// `~`-expansion plus trimming, so `codex list` echoes back a stable path
    /// and two spellings of the same home don't register twice.
    nonisolated static func normalizeCodexHome(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        return (trimmed as NSString).expandingTildeInPath
    }

    /// Upsert the account row **and** make sure the poll loop can see it.
    ///
    /// The credential row is the load-bearing half: `loadActiveCredentials` is
    /// the only enumeration the poll loop uses, so an account with no row there
    /// registers, lists, and then never updates. It is created token-free
    /// (`access_token = NULL`, `source = 'codex-home'`) and an **existing** row's
    /// token is never touched — re-registering a home on an account that still
    /// has a stored credential must not destroy it (that removal is #104's).
    // Not private: exercised directly by SelfTest, which drives the whole DB
    // half of registration synchronously and offline (the subprocess half is
    // covered by the stub-binary spawn test). Same pattern as
    // `resolveOpenAIAccountId` and `parseAccountPairs`.
    ///
    /// `email` and `plan` are optional and merged with `COALESCE`: a
    /// registration that could not learn them (an old or absent `codex`) must
    /// never blank out values an earlier read already stored.
    func saveCodexHomeAccount(
        accountId: String, email: String?, plan: String?, codexHome: String
    ) {
        guard FileManager.default.fileExists(atPath: dbPath) else { return }
        do {
            let db = try openDatabase(dbPath)
            let now = ISO8601DateFormatter().string(from: Date())
            let label = email ?? accountId

            try db.run("""
                INSERT INTO accounts (id, account_name, email, plan, last_updated, sort_order, provider, codex_home)
                VALUES (?, ?, ?, ?, ?, COALESCE((SELECT MAX(sort_order) + 1 FROM accounts), 0), 'openai', ?)
                ON CONFLICT(id) DO UPDATE SET
                    email = COALESCE(excluded.email, accounts.email),
                    plan = COALESCE(excluded.plan, accounts.plan),
                    last_updated = excluded.last_updated,
                    provider = 'openai',
                    codex_home = excluded.codex_home
            """, accountId, label, email, plan, now, codexHome)

            let existing = try db.scalar(
                "SELECT id FROM oauth_credentials WHERE account_id = ? LIMIT 1", accountId
            ) as? Int64

            if let credId = existing {
                try db.run("""
                    UPDATE oauth_credentials SET provider = 'openai', is_active = 1, updated_at = ?
                    WHERE id = ?
                """, now, credId)
            } else {
                try db.run("""
                    INSERT INTO oauth_credentials (
                        account_id, label, source, provider,
                        access_token, refresh_token, token_expires_at,
                        is_active, created_at, updated_at
                    ) VALUES (?, ?, 'codex-home', 'openai', NULL, NULL, NULL, 1, ?, ?)
                """, accountId, label, now, now)
            }
        } catch {
            flog.error("Failed to register codex home: \(error.localizedDescription)", category: fcat)
        }
    }

    /// Every OpenAI account row, for `claude-monitor codex list`.
    func codexAccounts() -> [CodexAccountRegistration] {
        guard FileManager.default.fileExists(atPath: dbPath) else { return [] }
        do {
            let db = try openDatabase(dbPath, readonly: true)
            let accountColumns = tableColumns(db, "accounts")
            guard accountColumns.contains("provider") else { return [] }
            let hasCodexHome = accountColumns.contains("codex_home")
            let stmt = try db.prepare("""
                SELECT a.id, \(hasCodexHome ? "a.codex_home" : "NULL"), a.plan,
                       (SELECT COUNT(*) FROM oauth_credentials c
                         WHERE c.account_id = a.id AND c.access_token IS NOT NULL),
                       a.email, a.account_name,
                       EXISTS (SELECT 1 FROM usage_history u WHERE u.account_id = a.id)
                FROM accounts a
                WHERE COALESCE(a.provider, 'anthropic') = 'openai'
                ORDER BY a.sort_order, a.id
            """)
            var rows: [CodexAccountRegistration] = []
            for row in stmt {
                guard let id = row[0] as? String else { continue }
                rows.append(CodexAccountRegistration(
                    accountId: id,
                    codexHome: (row[1] as? String).flatMap {
                        $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0
                    },
                    plan: row[2] as? String,
                    hasStoredToken: ((row[3] as? Int64) ?? 0) > 0,
                    email: (row[4] as? String).flatMap { $0.isEmpty ? nil : $0 },
                    accountName: (row[5] as? String).flatMap { $0.isEmpty ? nil : $0 },
                    hasLocalReading: ((row[6] as? Int64) ?? 0) != 0
                ))
            }
            return rows
        } catch {
            flog.error("codexAccounts failed: \(error.localizedDescription)", category: fcat)
            return []
        }
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
            var identityOnly = false
            switch (account.provider, account.token) {
            case (.anthropic, let token?):
                (_, error) = await addAccountWithToken(token, email: account.email)
            case (.openai, let token?):
                (_, error) = await addOpenAIAccount(
                    accessToken: token,
                    refreshToken: account.refreshToken,
                    expiresAt: account.tokenExpiresAt
                )
            case (_, nil):
                // A declared identity: no credential to validate, so nothing
                // is fetched or authenticated — a placeholder row is created
                // and `codex provision` fills it in later (#135).
                identityOnly = true
                (_, error) = declareCodexIdentity(email: account.email, homeLabel: account.homeLabel)
            }
            results.append(EnvImportResult(
                email: account.email,
                success: error == nil,
                error: error,
                provider: account.provider,
                identityOnly: identityOnly
            ))
        }

        return results
    }

    // MARK: - Declared (absent) Codex identities (#135)

    /// Record that this host is *expected* to have an OpenAI/Codex identity it
    /// has not been provisioned with, as a placeholder `accounts` row:
    /// `provider = 'openai'`, `codex_home = NULL`, and **no credential row at
    /// all**. `isAbsentCodexIdentity` reads exactly that shape, so the row
    /// surfaces as **absent** in `codex list`, the popover, and `ranking.json`
    /// without any of them needing a new table or config file to consult.
    ///
    /// **Nothing here reads, stores, transfers, or logs a credential.** The
    /// only inputs are an email address and an optional bare label; the row it
    /// writes is pure bookkeeping over data the app already had.
    ///
    /// Idempotent and non-destructive in both directions:
    /// - An existing `provider = 'openai'` row for this email is **left
    ///   exactly as it is** — declaring an identity a host already has (the
    ///   normal case when the same payload is pasted twice, or pasted on the
    ///   host it was copied from) must never downgrade a working, polling
    ///   account to a placeholder.
    /// - The placeholder it does create is keyed by a locally minted
    ///   `openai-<uuid>` id and carries the declared email, so a later
    ///   `codex provision`/`codex add --home` for that identity resolves onto
    ///   this same row via `resolveOpenAIAccountId`'s email match and
    ///   *converts* it rather than creating a duplicate sibling.
    ///
    /// Returns the account id the declaration landed on (existing or new).
    @discardableResult
    func declareCodexIdentity(email: String, homeLabel: String?) -> (accountId: String?, error: String?) {
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty else { return (nil, "Declared identity has no email") }
        guard FileManager.default.fileExists(atPath: dbPath) else {
            return (nil, "No database at the configured path")
        }
        do {
            let db = try openDatabase(dbPath)
            if let existing = Self.lookupOpenAIAccountId(nativeId: nil, email: email, db: db) {
                // Already present — real or placeholder, either way untouched.
                return (existing, nil)
            }

            let accountId = "openai-\(UUID().uuidString.lowercased())"
            // `last_updated` stays NULL: this identity has never been read on
            // this host, and a fabricated timestamp would read as a successful
            // poll to every freshness/staleness surface.
            try db.run("""
                INSERT INTO accounts (id, account_name, email, plan, last_updated, sort_order, provider, codex_home)
                VALUES (?, ?, ?, NULL, NULL,
                        COALESCE((SELECT MAX(sort_order) + 1 FROM accounts), 0), 'openai', NULL)
            """, accountId, homeLabel ?? email, email)

            // Deliberately no oauth_credentials row: its absence *is* the
            // absent state, and it is what keeps `loadActiveCredentials` from
            // ever handing this row to the poll loop.
            flog.info(
                "declared an unprovisioned Codex identity \(accountId.prefix(8))… — run `claude-monitor codex provision <label>` on this host to fill it in",
                category: fcat
            )
            return (accountId, nil)
        } catch {
            flog.error("declareCodexIdentity failed: \(error.localizedDescription)", category: fcat)
            return (nil, "Could not record the declared identity: \(error.localizedDescription)")
        }
    }

    /// Serialize active accounts into ACCOUNT_EMAIL_N / ACCOUNT_KEY_N env
    /// format, the same base format the Bulk Import field and the account
    /// list files accept. Returns nil if there is nothing to report at all
    /// (no exportable accounts and no excluded ones — so the caller can
    /// disable the Copy button). Order follows sort_order.
    ///
    /// **Every active, tokened provider round-trips (#67).** An Anthropic
    /// entry is just `ACCOUNT_EMAIL_N` / `ACCOUNT_KEY_N`, exactly as before
    /// this format was extended. A non-Anthropic (OpenAI/Codex) entry
    /// additionally carries:
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
    /// **A non-Anthropic account with no stored token travels as an
    /// *identity only* (#135).** #123 nulls `access_token`/`refresh_token` for
    /// every `provider = 'openai'` row at migration — the app holds no OpenAI
    /// credential — so a Codex account has no credential to carry, and #129
    /// therefore left it out of the payload entirely. That made an identity
    /// that was never provisioned on a host indistinguishable from one that
    /// does not exist. Such a row is now emitted as:
    ///   - `ACCOUNT_EMAIL_N` — the identity's address, the join key
    ///   - `ACCOUNT_PROVIDER_N=openai`
    ///   - `ACCOUNT_HOME_LABEL_N` — the `<label>` half of `~/.codex-<label>`,
    ///     when the home follows that convention, so the receiving host can
    ///     print the exact `codex provision <label>` that fills the gap
    ///   - **no `ACCOUNT_KEY_N`** — there is no credential and never will be
    ///
    /// **#104's guarantee is untouched: labels cross machines, credentials
    /// never do.** The home *path* is never emitted (it names a user); only
    /// the label the operator chose is, and only when it can be derived from
    /// the `~/.codex-<label>` convention. The receiving host creates a
    /// placeholder account row (`OAuthPoller.declareCodexIdentity`) that
    /// `codex list`, the popover, and `ranking.json` all report as **absent**.
    ///
    /// A keyless entry is additive in the same sense the #67 keys are: an
    /// older build's `parseAccountPairs()` requires `ACCOUNT_KEY_N` and simply
    /// skips the entry, creating nothing.
    ///
    /// Returns the serialized env text, the number of *credentialed* accounts
    /// it contains, and the number of identity-only (tokenless, non-Anthropic)
    /// entries alongside them, so callers can report an accurate count and
    /// name the difference rather than re-deriving either from
    /// `store.accounts.count`.
    func exportAccountsEnv() -> (env: String, count: Int, identityOnly: Int)? {
        guard FileManager.default.fileExists(atPath: dbPath) else { return nil }
        do {
            let db = try openDatabase(dbPath, readonly: true)
            // `provider`/`codex_home` (accounts) and `token_expires_at`
            // (oauth_credentials) are migrated columns (#28, #103) — select
            // them only when present so a database opened before those
            // migrations ran still exports its (necessarily all-Anthropic)
            // accounts instead of failing the query outright.
            let accountColumns = tableColumns(db, "accounts")
            let hasAcctProvider = accountColumns.contains("provider")
            let hasCodexHome = accountColumns.contains("codex_home")
            let hasTokenExpiry = tableColumns(db, "oauth_credentials").contains("token_expires_at")
            // No `access_token IS NOT NULL` filter here (unlike before #123):
            // a tokenless row still needs to be seen so a tokenless
            // non-Anthropic one can be emitted identity-only below, rather
            // than disappearing from both the export and the count.
            //
            // Driven from `accounts` with a LEFT JOIN rather than from
            // `oauth_credentials` inward (#135): a *declared* identity has no
            // credential row at all, so an inner join would drop it and a
            // declaration could never be propagated on to a third host. For
            // Anthropic this changes nothing — a row with no active credential
            // has no token, and a tokenless Anthropic entry is skipped below
            // exactly as it always was.
            let stmt = try db.prepare("""
                SELECT COALESCE(a.email, a.account_name, c.label) AS email, c.access_token,
                       \(hasAcctProvider ? "a.provider" : "NULL") AS provider,
                       c.refresh_token,
                       \(hasTokenExpiry ? "c.token_expires_at" : "NULL") AS token_expires_at,
                       \(hasCodexHome ? "a.codex_home" : "NULL") AS codex_home,
                       a.account_name
                FROM accounts a
                LEFT JOIN oauth_credentials c ON c.account_id = a.id AND c.is_active = 1
                ORDER BY a.sort_order, a.id
            """)

            var lines: [String] = []
            var n = 0
            var credentialed = 0
            var identityOnly = 0
            for row in stmt {
                let provider = AccountProvider(stored: row[2] as? String)
                let token = (row[1] as? String).flatMap { $0.isEmpty ? nil : $0 }
                if token == nil && provider == .anthropic {
                    // A tokenless Anthropic row is some other, unrelated
                    // inactive state — silently skipped, exactly as before.
                    continue
                }
                // An identity entry is nothing *but* a name, so a row with no
                // usable one is not worth emitting: `account-N` would be a
                // fabricated join key, and the receiving host would create a
                // placeholder nobody can match to a real account.
                let resolvedEmail = (row[0] as? String).flatMap {
                    $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0
                }
                if token == nil && resolvedEmail == nil { continue }
                n += 1
                let email = resolvedEmail ?? "account-\(n)"
                lines.append("ACCOUNT_EMAIL_\(n)=\(email)")
                if let token = token {
                    credentialed += 1
                    lines.append("ACCOUNT_KEY_\(n)=\(token)")
                } else {
                    identityOnly += 1
                }
                if provider != .anthropic {
                    lines.append("ACCOUNT_PROVIDER_\(n)=\(provider.rawValue)")
                    if let refresh = row[3] as? String, !refresh.isEmpty {
                        lines.append("ACCOUNT_REFRESH_\(n)=\(refresh)")
                    }
                    if let expiresISO = row[4] as? String, !expiresISO.isEmpty {
                        lines.append("ACCOUNT_EXPIRES_\(n)=\(expiresISO)")
                    }
                    // Label only, never the path this was derived from.
                    if let label = Self.codexHomeLabel(row[5] as? String)
                        ?? Self.provisionLabelCandidate(row[6] as? String) {
                        lines.append("ACCOUNT_HOME_LABEL_\(n)=\(label)")
                    }
                }
            }

            guard n > 0 else { return nil }

            let header = """
                # Claude Monitor accounts — \(credentialed) account(s)\
                \(identityOnly > 0 ? " + \(identityOnly) Codex identity/identities (no credential)" : "")
                # Paste into the app (Add Account → Bulk Import) or save as ~/.claude-monitor/accounts.env

                """
            return (header + lines.joined(separator: "\n") + "\n", credentialed, identityOnly)
        } catch {
            flog.error("exportAccountsEnv failed: \(error.localizedDescription)", category: fcat)
            return nil
        }
    }

    /// The `<label>` half of a `~/.codex-<label>` home directory — the exact
    /// argument `codex provision <label>` takes — or nil for any home that
    /// doesn't follow that convention (the ambient `~/.codex`, or a custom
    /// `--home` path somewhere else entirely).
    ///
    /// **Only the label ever leaves this function.** A home path contains a
    /// username; the label is a name the operator chose, so it is the one part
    /// of a home that is safe to put on a clipboard bound for another machine.
    /// A label that would not survive `parseProvisionArgs` (empty, or
    /// containing a path separator) is rejected rather than emitted.
    nonisolated static func codexHomeLabel(_ home: String?) -> String? {
        guard let home = home?.trimmingCharacters(in: .whitespacesAndNewlines), !home.isEmpty else {
            return nil
        }
        let base = (home as NSString).lastPathComponent
        guard base.hasPrefix(".codex-") else { return nil }
        return provisionLabelCandidate(String(base.dropFirst(".codex-".count)))
    }

    /// A stored display name that is usable as a `codex provision <label>`
    /// argument: non-empty, no path separator, and not an email address (a
    /// row whose `account_name` is just its email carries no label at all).
    nonisolated static func provisionLabelCandidate(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty, !value.contains("/"), !looksLikeEmailAddress(value) else { return nil }
        return value
    }

    /// One parsed clipboard/env entry. `provider`/`refreshToken`/
    /// `tokenExpiresAt` are additive (#67): an old-format entry (no
    /// `ACCOUNT_PROVIDER_N` key) parses as `.anthropic` with no refresh
    /// token, exactly as every entry parsed before this format was extended.
    ///
    /// `token` is **optional** as of #135: a Codex identity travels with no
    /// credential at all (`ACCOUNT_EMAIL_N` + `ACCOUNT_PROVIDER_N=openai`,
    /// optionally `ACCOUNT_HOME_LABEL_N`, and no `ACCOUNT_KEY_N`). A keyless
    /// *Anthropic* entry is still meaningless and is dropped at parse time, so
    /// nil here always means "a declared identity", never "a token went
    /// missing".
    // Not private: exercised directly by SelfTest (no network access needed
    // to verify parsing), same pattern as `resolveOpenAIAccountId` below.
    struct ParsedAccountEntry {
        let email: String
        let token: String?
        let provider: AccountProvider
        let refreshToken: String?
        let tokenExpiresAt: Date?
        /// The `codex provision <label>` argument for a declared identity, when
        /// the sending host could derive one. Never a path (#135).
        let homeLabel: String?
    }

    /// Parse env content into ordered entries from ACCOUNT_EMAIL_N (plus
    /// ACCOUNT_KEY_N and the additive per-index provider/refresh/expiry/
    /// home-label keys). Gaps in numbering are skipped; order follows the
    /// index N.
    ///
    /// An entry with no `ACCOUNT_KEY_N` is kept **only** for a non-Anthropic
    /// provider — that is a declared Codex identity (#135). Everything else
    /// still requires the email/key pair it always did.
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
            guard let email = env["ACCOUNT_EMAIL_\(i)"], !email.isEmpty else {
                continue  // Skip gaps — files may have non-consecutive numbering
            }
            let provider = AccountProvider(stored: env["ACCOUNT_PROVIDER_\(i)"])
            let token = env["ACCOUNT_KEY_\(i)"].flatMap { $0.isEmpty ? nil : $0 }
            // Keyless is a declared identity, which only exists for a
            // non-Anthropic provider. A keyless Anthropic entry is malformed
            // input and is dropped exactly as it was before #135.
            if token == nil && provider == .anthropic { continue }
            let refreshToken = env["ACCOUNT_REFRESH_\(i)"]
            let tokenExpiresAt = env["ACCOUNT_EXPIRES_\(i)"].flatMap { UsageRecord.parseISO($0) }
            pairs.append(ParsedAccountEntry(
                email: email, token: token, provider: provider,
                refreshToken: refreshToken, tokenExpiresAt: tokenExpiresAt,
                homeLabel: Self.provisionLabelCandidate(env["ACCOUNT_HOME_LABEL_\(i)"])
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
    /// **Tokened** entries here are Anthropic-only, unlike
    /// `importFromEnvString`: these are periodic background files, not a
    /// one-shot clipboard/file paste, and the `ACCOUNT_PROVIDER_N` key #67
    /// adds is not expected to appear here. A tokened non-Anthropic entry (if
    /// one ever did appear) is imported via `addAccountWithToken` same as
    /// before — it fails harmlessly (invalid token against the Anthropic API),
    /// matching the pre-#67 behavior for any account this format couldn't
    /// express.
    ///
    /// **Keyless entries are declared Codex identities (#135)** and *are*
    /// honored, because a headless Linux host has no popover to paste into —
    /// these files are its only env-transfer surface, so excluding them would
    /// make the intended set a macOS-only feature. That is safe on an
    /// every-launch cadence for the same reason the rest of this function is:
    /// `declareCodexIdentity` only ever *adds* a placeholder for an identity
    /// that isn't there, and is a no-op once one exists — including after the
    /// identity has been provisioned for real.
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
            // A keyless entry is a declared Codex identity (#135). Honoring it
            // here is what makes the intended set expressible on a **headless
            // Linux host**, which has no popover to paste into — these two
            // files are its only env-transfer surface. Safe on the every-launch
            // cadence precisely because `declareCodexIdentity` is idempotent
            // and non-destructive: it creates a placeholder the first time and
            // is a no-op forever after, including once the identity has been
            // provisioned for real.
            guard let token = pair.token else {
                let (_, error) = declareCodexIdentity(email: pair.email, homeLabel: pair.homeLabel)
                results.append(EnvImportResult(
                    email: pair.email, success: error == nil, error: error,
                    provider: pair.provider, identityOnly: true
                ))
                continue
            }
            let (_, error) = await addAccountWithToken(token, email: pair.email)
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

    /// Every credential the poll loop should visit this cycle.
    ///
    /// **This is the only enumeration `pollAll` / `pollDue` / `probeFableDue`
    /// use**, so anything absent here silently never updates. Two shapes
    /// qualify:
    ///
    /// 1. A row with a stored `access_token` — every account before #103.
    /// 2. A **token-free** row whose account has a registered `codex_home`
    ///    (`claude-monitor codex add --home`). Registering an account by its
    ///    home deliberately never reads or stores a token, so its credential row
    ///    carries `access_token = NULL` and `source = 'codex-home'`; without
    ///    this clause it would register fine, list fine, and never poll.
    ///
    /// Clause 2 is written as narrowly as it can be — `provider = 'openai'` and
    /// a non-NULL `codex_home` — rather than relaxing the token predicate for
    /// all OpenAI rows, so a token-less row from any *other* source (e.g. an
    /// `accounts import` bundle exported from a host that had a home) is not
    /// resurrected into the poll set on a host where it has no home to read.
    func loadActiveCredentials() -> [OAuthCredential] {
        guard FileManager.default.fileExists(atPath: dbPath) else { return [] }
        do {
            let db = try openDatabase(dbPath, readonly: true)
            var credentials: [OAuthCredential] = []

            // The migrated columns are selected only when present, so a
            // database opened before the migration ran still loads (every row
            // then resolves to the Anthropic fallback with no registered home).
            let columns = tableColumns(db, "oauth_credentials")
            let hasProvider = columns.contains("provider")
            let hasTokenExpiry = columns.contains("token_expires_at")
            let accountColumns = tableColumns(db, "accounts")
            let hasCodexHome = accountColumns.contains("codex_home")
            let accountProvider = accountColumns.contains("provider")
                ? "COALESCE(a.provider, 'anthropic')" : "'anthropic'"
            let homeRegistered = hasCodexHome
                ? "(a.codex_home IS NOT NULL AND TRIM(a.codex_home) != '' AND \(accountProvider) = 'openai')"
                : "0"
            let stmt = try db.prepare("""
                SELECT c.id, c.account_id, c.label, c.source,
                       c.access_token, c.refresh_token, c.expires_at,
                       c.subscription_type, c.rate_limit_tier, c.is_active,
                       \(hasProvider ? "c.provider" : "NULL"),
                       \(hasTokenExpiry ? "c.token_expires_at" : "NULL"),
                       \(hasCodexHome ? "a.codex_home" : "NULL")
                FROM oauth_credentials c
                LEFT JOIN accounts a ON a.id = c.account_id
                WHERE c.is_active = 1
                  AND (c.access_token IS NOT NULL OR \(homeRegistered))
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
                    isActive: (row[9] as? Int64 ?? 1) == 1,
                    codexHome: (row[12] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ))
            }

            return credentials
        } catch {
            flog.error("Failed to load credentials: \(error.localizedDescription)", category: fcat)
            return []
        }
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
    /// eventually invalidate Codex CLI's — and vice versa. This app stores no
    /// OpenAI credential of its own (#104): the ladder is ordered by how little
    /// credential handling each rung needs, and there is no stored-credential
    /// fallback below it.
    ///
    /// 1. **`codex app-server`** — the Codex CLI owns the credential entirely;
    ///    we read nothing. Preferred whenever the binary resolves and the RPC
    ///    answers.
    /// 2. **`auth.json` at request time** — read the current bearer, use it once,
    ///    never write it back and never refresh it. Removes the rotation race
    ///    even without the RPC.
    ///
    /// A tier that is merely *unavailable* (no codex binary, codex too old, no
    /// `auth.json`) never marks the account unhealthy — it falls through
    /// silently. Only the last tier's own failure sets a status.
    private func pollOpenAI(_ credential: OAuthCredential) async throws {
        // The account id is not on the app-server wire at all, so the stored one
        // is what the higher tiers write against.
        let storedAccountId = credential.accountId.flatMap { $0.isEmpty ? nil : $0 }

        // Which Codex home — if any — is allowed to speak for this account.
        // Resolved once, up front, and shared by both home-reading tiers.
        let home = resolveCodexHome(for: credential)
        if case .ambiguous = home { noteAmbiguousCodexHome(credential) }

        // MARK: Tier 1 — codex app-server (no credential touched)
        if let storedAccountId = storedAccountId, home.allowsHomeRead {
            let client = CodexAppServerClient(codexHome: home.readableHome)
            do {
                // A nil `codexHome` is the `.ambient` case — the client then
                // falls back to `$CODEX_HOME`, else `~/.codex`, as before.
                let snapshot = try await client.fetchUsage()
                // Belt and braces on top of the per-account home: a registered
                // home that has since been re-logged-in as somebody else, or an
                // ambient home that never belonged to this account, still gets
                // caught here rather than overwriting the row.
                if codexHomeConflicts(with: credential, reportedEmail: snapshot.email) {
                    // Definitive for this poll cycle: the home answered, and it
                    // answered as somebody else. Report the drift and stop —
                    // falling through to tier 2/3 would either re-derive the
                    // same conflict or, worse, let the "every tier exhausted"
                    // path below bury it behind an unrelated "No access
                    // token"/"revoked" state (#146).
                    let homeAccountId = CodexAuth.accountId(inHome: home.readableHome)
                    noteCodexIdentityConflict(credential, homeAccountId: homeAccountId, homeEmail: snapshot.email)
                    // #147: the operator's `codex login` already expressed the
                    // intent — follow it. The snapshot this tier already
                    // fetched is the new identity's own reading, so it is
                    // written immediately rather than waiting a cycle.
                    adoptDriftedIdentity(
                        homeAccountId: homeAccountId, homeEmail: snapshot.email,
                        home: client.effectiveCodexHome, snapshot: snapshot
                    )
                    return
                }
                writeSnapshotToDB(accountId: storedAccountId, snapshot: snapshot)
                updateCredentialLastPoll(credential, error: nil)
                updateCredentialStatus(credential, status: .valid, error: nil)
                await MainActor.run { self.lastError = nil }
                return
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
        // stored copy even when the RPC is unavailable. The file read is scoped
        // to *this account's* home, not `CodexAuth.defaultAuthPath`.
        if home.allowsHomeRead,
           let live = try? CodexAuth.load(path: CodexAuth.authPath(inHome: home.readableHome)),
           let storedAccountId = storedAccountId {
            if codexHomeConflicts(with: credential, reportedAccountId: live.accountId) {
                // Same belt-and-braces guard as tier 1, reached whenever tier 1
                // itself didn't run (capability gap, no RPC) but the local
                // `auth.json` still contradicts the registration. Reported here
                // rather than left to fall through, for the same reason as
                // tier 1's own conflict branch.
                noteCodexIdentityConflict(credential, homeAccountId: live.accountId, homeEmail: nil)
                // #147: same re-attribution as tier 1. No snapshot is in hand
                // here (only the auth.json bearer was read, not used yet), so
                // the adopted row picks up fresh numbers on its own next poll
                // rather than triggering a second network round-trip inline.
                adoptDriftedIdentity(
                    homeAccountId: live.accountId, homeEmail: nil,
                    home: (CodexAuth.authPath(inHome: home.readableHome) as NSString).deletingLastPathComponent,
                    snapshot: nil
                )
                return
            }
            do {
                let snapshot = try await openAIClient.fetchUsage(accessToken: live.accessToken)
                writeSnapshotToDB(accountId: storedAccountId, snapshot: snapshot)
                updateCredentialLastPoll(credential, error: nil)
                updateCredentialStatus(credential, status: .valid, error: nil)
                await MainActor.run { self.lastError = nil }
                return
            } catch {
                flog.warning("auth.json bearer read failed for \(credential.label): \(error.localizedDescription) — every tier is now exhausted; no stored-credential fallback (#104)", category: fcat)
            }
        }

        // Every tier is now exhausted for this poll cycle — there is no
        // stored-credential fallback (#104). An account registered by home
        // alone has no further fallback, so tier 1's failure *is* this
        // account's health state. Reported and returned rather than
        // rethrown: `pollWithRetry` would flatten an `unauthorized` throw to
        // `.revoked`, burying "needs login" behind a state that suggests the
        // wrong fix.
        if let codexFailure = pendingCodexFailure(credential) {
            let reason = codexFailure.localizedDescription
            updateCredentialLastPoll(credential, error: reason)
            updateCredentialStatus(credential, status: codexFailure.tokenStatus, error: reason)
            return
        }
        updateCredentialStatus(credential, status: .missing, error: "No access token")
        throw AnthropicAPIError.unauthorized
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

    /// One log line per (credential, kind-of-failure), so a *persistent* state
    /// is reported once rather than every poll. Keyed by kind rather than by
    /// credential alone so a state change (needs login → logged in again → home
    /// deleted) is still visible.
    ///
    /// This matters more with per-account homes than it did before: a
    /// registered-but-unauthenticated home is now a legitimate, indefinite
    /// steady state, not a transient. Deduping only capability gaps would write
    /// the same `[WARN]` line every interval, forever.
    private var loggedCodexFailureKind: Set<String> = []

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
        } else if loggedCodexFailureKind.insert("\(id):\(Self.failureKind(error))").inserted {
            flog.warning("codex app-server: \(error.localizedDescription) — falling back for \(credential.label)", category: fcat)
        }
    }

    /// A stable discriminator for the *kind* of failure, ignoring its payload
    /// (which is a home path, and must not be part of a log-dedupe key any more
    /// than it may be part of a log line).
    nonisolated static func failureKind(_ error: CodexAppServerError) -> String {
        switch error {
        case .binaryNotFound: return "binaryNotFound"
        case .launchFailed: return "launchFailed"
        case .notLoggedIn: return "notLoggedIn"
        case .homeMissing: return "homeMissing"
        case .methodUnsupported: return "methodUnsupported"
        case .timedOut: return "timedOut"
        case .protocolFailure: return "protocolFailure"
        }
    }

    private func pendingCodexFailure(_ credential: OAuthCredential) -> CodexAppServerError? {
        credential.id.flatMap { lastCodexFailure[$0] }
    }

    // MARK: - Per-account Codex home resolution

    /// Which `CODEX_HOME` — if any — may speak for one account.
    ///
    /// A single Codex home holds exactly one login, so attributing a home's
    /// reading to the wrong account overwrites that account's usage with a
    /// stranger's: plausible-looking numbers, silently wrong, and invisible to
    /// tests and review. This type makes the three cases explicit rather than
    /// leaving "which home?" implicit in the ambient environment.
    enum CodexHomeResolution: Equatable {
        /// The account's own registered `codex_home` (`codex add --home`).
        /// Correct attribution is a property of the *construction* here: the
        /// child is spawned against this account's home and can only ever
        /// report this account.
        case explicit(String)
        /// No registered home, and no sibling the ambient home could belong to
        /// instead — i.e. this is the only OpenAI account on the host. Exactly
        /// today's single-account behaviour, preserved so an existing
        /// installation needs no user action.
        case ambient
        /// No registered home, but there **are** other OpenAI accounts. The
        /// ambient home belongs to at most one of them and nothing available
        /// says which, so no home may speak for this account at all.
        ///
        /// This is what closes the hole the #111 Judge recorded: the old guard
        /// compared emails, so a row with `email IS NULL` could still be handed
        /// the ambient home's numbers. Ambiguity is now resolved by *counting
        /// candidates*, which needs no identity on either side and therefore has
        /// no NULL-email gap. The account falls through to its stored credential.
        case ambiguous

        /// The home the read tiers should be constructed with, or nil to mean
        /// "the client's own ambient default".
        var readableHome: String? {
            switch self {
            case .explicit(let home): return home
            case .ambient, .ambiguous: return nil
            }
        }

        /// Whether a home-reading tier may run at all. Distinguishes `.ambient`
        /// (run, with the inherited home) from `.ambiguous` (do not run).
        var allowsHomeRead: Bool {
            if case .ambiguous = self { return false }
            return true
        }
    }

    /// The pure decision, split out so the self-test can pin every shape —
    /// including the NULL-email one — with no database and no subprocess.
    ///
    /// `openAIAccountCount` is the number of `provider = 'openai'` account rows
    /// on this host. One means the ambient home can only be this account's; more
    /// than one means it cannot be attributed without proof.
    nonisolated static func resolveCodexHome(
        registered: String?, openAIAccountCount: Int
    ) -> CodexHomeResolution {
        if let registered = registered?.trimmingCharacters(in: .whitespacesAndNewlines),
           !registered.isEmpty {
            return .explicit(registered)
        }
        return openAIAccountCount > 1 ? .ambiguous : .ambient
    }

    private func resolveCodexHome(for credential: OAuthCredential) -> CodexHomeResolution {
        Self.resolveCodexHome(
            registered: credential.codexHome,
            openAIAccountCount: openAIAccountCount()
        )
    }

    /// How many OpenAI accounts this host could plausibly be reading the
    /// ambient home for. Counted per poll (one scalar against a database this
    /// cycle opens anyway) rather than cached, so adding an account takes
    /// effect on the next cycle without a restart.
    ///
    /// **Absent identities (#135) are excluded.** A placeholder row — declared
    /// by a paste, never provisioned here, no stored token and no registered
    /// home — has no login on this host at all, so the ambient home cannot be
    /// its and it is not a candidate owner. Counting it would be worse than
    /// useless: declaring the identities a host is *supposed* to have would
    /// push its one genuinely-ambient account into `.ambiguous` and stop it
    /// polling, i.e. the bookkeeping layer would break the thing it is
    /// bookkeeping. The belt-and-braces identity guard
    /// (`identitiesConflict`/`codexHomeDrift`) still catches an ambient home
    /// that turns out to hold someone else's login, which is the case this
    /// count was never able to decide on its own anyway.
    // Not private: exercised directly by SelfTest, which pins that declaring
    // an intended set never pushes a working single-account host into
    // `.ambiguous`. Same pattern as `saveCodexHomeAccount`/`codexAccounts`.
    func openAIAccountCount() -> Int {
        guard FileManager.default.fileExists(atPath: dbPath) else { return 0 }
        do {
            let db = try openDatabase(dbPath, readonly: true)
            let accountColumns = tableColumns(db, "accounts")
            guard accountColumns.contains("provider") else { return 0 }
            let homeRegistered = accountColumns.contains("codex_home")
                ? "(a.codex_home IS NOT NULL AND TRIM(a.codex_home) != '')"
                : "0"
            // Third term mirrors `isAbsentCodexIdentity`'s `hasLocalReading` guard
            // (UsageStore.swift's account-loading query uses the identical
            // EXISTS-against-usage_history shape) so this count is exactly the
            // negation of "absent": a legacy row with no token and no registered
            // home, but with usage_history from before #123 nulled every OpenAI
            // access_token, must still count as a candidate owner of the ambient
            // home — only a genuine placeholder (no reading by construction) may
            // be excluded. A missing usage_history table reads as "no evidence",
            // which can only make a row look less pollable, never falsely excluded.
            let hasLocalReading = tableColumns(db, "usage_history").isEmpty
                ? "1"
                : "EXISTS (SELECT 1 FROM usage_history u WHERE u.account_id = a.id)"
            let count = try db.scalar("""
                SELECT COUNT(*) FROM accounts a
                WHERE COALESCE(a.provider, 'anthropic') = 'openai'
                  AND (\(homeRegistered)
                       OR EXISTS (SELECT 1 FROM oauth_credentials c
                                   WHERE c.account_id = a.id
                                     AND c.access_token IS NOT NULL
                                     AND TRIM(c.access_token) != '')
                       OR \(hasLocalReading))
            """) as? Int64
            return Int(count ?? 0)
        } catch {
            flog.error("openAIAccountCount failed: \(error.localizedDescription)", category: fcat)
            // Fail closed: an unknown count must not license the ambient home.
            return 2
        }
    }

    /// Accounts already told once that they need their own home registered.
    private var loggedAmbiguousCodexHome: Set<Int64> = []

    private func noteAmbiguousCodexHome(_ credential: OAuthCredential) {
        guard let id = credential.id else { return }
        if loggedAmbiguousCodexHome.insert(id).inserted {
            flog.info(
                "\(credential.label) has no registered CODEX_HOME and this host has more than one OpenAI account — the ambient home can speak for only one of them, so it is not used here. Register this account's own home with `claude-monitor codex add --home <path>`.",
                category: fcat
            )
        }
    }

    // MARK: - Codex home identity guard (belt and braces)

    /// Credentials whose Codex home demonstrably belongs to someone else, logged
    /// once rather than every poll.
    private var loggedCodexIdentityConflict: Set<Int64> = []

    /// True when the Codex login just read demonstrably belongs to a
    /// **different** account than this credential.
    ///
    /// Per-account homes make correct attribution structural, so this is no
    /// longer the primary defence — it is **kept deliberately** as a second line
    /// for the two cases resolution alone cannot see:
    ///
    /// - a `codex_home IS NULL` row reading the ambient home on a
    ///   single-account host, where that ambient home may belong to a ChatGPT
    ///   login this app has never registered;
    /// - a **registered** home that has since been re-logged-in as a different
    ///   account, which no amount of construction-time care can predict.
    ///
    /// Deliberately asymmetric: only a **contradiction** disqualifies a tier.
    /// Absent identity on either side proves nothing — which is precisely why it
    /// could never close the NULL-email hole on its own, and why
    /// `resolveCodexHome` (which needs no identity at all) does that instead.
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
    ///
    /// Now a thin reading of `compareIdentities` — **exactly** the same answer
    /// for every input, which the self-test pins case by case. The attribution
    /// gate this feeds is deliberately untouched: widening the comparison's
    /// result was about letting `codex list` *name* a conflict, never about
    /// moving the line at which the poller refuses to attribute a reading.
    nonisolated static func identitiesConflict(_ lhs: String?, _ rhs: String?) -> Bool {
        if case .conflict = compareIdentities(reported: lhs, stored: rhs) { return true }
        return false
    }

    /// What comparing a *reported* identity with a *stored* one actually
    /// established — the same three-way answer `identitiesConflict` used to
    /// collapse into a `Bool`.
    ///
    /// The distinction that matters is between `.match` and `.indeterminate`:
    /// both mean "do not decline attribution", but only `.match` means the two
    /// sides agree. Collapsing them is what made drift invisible.
    enum CodexIdentityComparison: Equatable, Sendable {
        /// At least one side carries no identity. Proves nothing in either
        /// direction — the asymmetry the tiers rely on.
        case indeterminate
        /// Both sides known and equal.
        case match
        /// Both sides known and different. `reported` is the identity the home
        /// currently holds, carried verbatim (trimmed, original case) so a
        /// caller can display it.
        case conflict(reported: String)
    }

    /// Compare an identity a Codex home currently reports with the one an
    /// account carries. Pure function of its arguments — no IO, no database,
    /// so the self-test drives it directly.
    nonisolated static func compareIdentities(reported: String?, stored: String?) -> CodexIdentityComparison {
        func normalized(_ value: String?) -> String? {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return (trimmed?.isEmpty == false) ? trimmed : nil
        }
        guard let lhs = normalized(reported), let rhs = normalized(stored) else { return .indeterminate }
        guard lhs != rhs else { return .match }
        let verbatim = reported?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let verbatim = verbatim, !verbatim.isEmpty { return .conflict(reported: verbatim) }
        return .conflict(reported: lhs)
    }

    /// Whether a *registered* Codex home still belongs to the account it was
    /// registered against — the operator-visible reading of the same guard.
    enum CodexHomeDrift: Equatable, Sendable {
        /// Nothing contradicts the registration. Absent identity lands here
        /// too: a home logged out after registration is "needs login", not
        /// drift.
        case stable
        /// The home now holds a different identity than the account row.
        /// `reportedAccountId` is the account id `auth.json` currently carries,
        /// when it carries one — `nil` when the drift was proven by email
        /// alone, because no caller of this may print an email.
        case drifted(reportedAccountId: String?)
    }

    /// Has a registered home been re-logged-in as somebody else?
    ///
    /// Pure: the caller does the IO (reads `auth.json`'s `tokens.account_id`
    /// and/or `account/read`'s email) and hands both observations in. Two
    /// signals, in precedence order:
    ///
    /// 1. **Account id** — the stable key `codex add` registered the home by,
    ///    and the only one that can be *named* in output. A locally minted id
    ///    (`openai-<uuid>`, minted when `auth.json` carried no `account_id`)
    ///    lives in a different namespace, so it is never compared — an
    ///    unrelated string is not evidence of drift.
    /// 2. **Email** — only consulted when the ids leave the question open. If
    ///    the ids *agree*, a disagreeing email is a stale account row, not a
    ///    different login, and reporting drift there would cry wolf.
    ///
    /// Same asymmetry as `identitiesConflict`: only a contradiction counts.
    nonisolated static func codexHomeDrift(
        registeredAccountId: String,
        registeredEmail: String?,
        homeAccountId: String?,
        homeEmail: String?
    ) -> CodexHomeDrift {
        let comparableStoredId = isLocallyMintedAccountId(registeredAccountId) ? nil : registeredAccountId
        switch compareIdentities(reported: homeAccountId, stored: comparableStoredId) {
        case .conflict(let reported):
            return .drifted(reportedAccountId: reported)
        case .match:
            return .stable
        case .indeterminate:
            if case .conflict = compareIdentities(reported: homeEmail, stored: registeredEmail) {
                return .drifted(reportedAccountId: nil)
            }
            return .stable
        }
    }

    /// An id this app minted for itself because the home's `auth.json` named
    /// none (see `registerCodexHome`). It is not an OpenAI account id and must
    /// never be compared with one.
    nonisolated static func isLocallyMintedAccountId(_ accountId: String) -> Bool {
        accountId.hasPrefix("openai-")
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

    /// Record that this credential's Codex home is currently logged in as a
    /// **different** identity than the one it is registered against — the
    /// user-visible drift state #146 introduced, replacing a signal that used
    /// to be nothing but this log line.
    ///
    /// The log line itself stays deduped once per credential lifetime (a
    /// steady drifted state would otherwise write the same `[INFO]` forever),
    /// but the *status* below is set on every call — i.e. every poll that
    /// finds the conflict still standing — so a later poll that finds it
    /// resolved (home re-registered, or the original login restored) simply
    /// never calls this again and the row reports `.valid` on its own, no
    /// restart required.
    ///
    /// `homeAccountId`/`homeEmail` are whichever identity the calling tier
    /// actually read; passed through `OAuthPoller.codexHomeDrift` — the same
    /// comparison `CodexCLI`'s `driftStatus(for:reportedEmail:)` uses for
    /// `codex list` — so the popover and the CLI describe one conflict with
    /// one vocabulary, never two.
    ///
    /// Not private: exercised directly by SelfTest, which drives the full
    /// conflict → `.drifted` → resolved → `.valid` sequence through this
    /// method rather than spawning a real `codex` subprocess (#146).
    func noteCodexIdentityConflict(
        _ credential: OAuthCredential, homeAccountId: String?, homeEmail: String?
    ) {
        guard let id = credential.id else { return }
        if loggedCodexIdentityConflict.insert(id).inserted {
            flog.info(
                "codex app-server reports a different account than \(credential.label) — the Codex home it reads belongs to another login. Register this account's own home with `claude-monitor codex add --home <path>`, or run `claude-monitor codex provision <label>`.",
                category: fcat
            )
        }

        let registeredAccountId = credential.accountId ?? ""
        let drift = Self.codexHomeDrift(
            registeredAccountId: registeredAccountId,
            registeredEmail: storedEmail(for: registeredAccountId),
            homeAccountId: homeAccountId,
            homeEmail: homeEmail
        )
        updateCredentialStatus(credential, status: .drifted, error: Self.driftDetailMessage(for: credential, drift: drift))
    }

    // MARK: - Re-attribution: follow a codex login switch (#147)

    /// Account ids already reported as adopted, logged once rather than
    /// every poll that still finds the same drift standing.
    private var loggedCodexAdoption: Set<String> = []

    /// Re-attribute a drifted Codex home to the identity actually logged in
    /// there, instead of leaving it frozen (#147): the operator's `codex
    /// login` already expressed the intent, so the app follows it rather
    /// than waiting for a second manual `codex add --home`.
    ///
    /// - An existing `provider = 'openai'` row for `homeAccountId`/
    ///   `homeEmail` is repointed — `codex_home` becomes `home` and its
    ///   credential is reactivated — so it is picked up by
    ///   `loadActiveCredentials` and resumes polling on the very next cycle.
    ///   This is "point that row at this home," never a copy: the row's
    ///   history, id, and every other column are untouched.
    /// - No existing row means one is registered here, in the exact shape
    ///   `codex add --home`/`registerCodexHome` produces — the same
    ///   `saveCodexHomeAccount` write path — so a manual and an automatic
    ///   registration can never disagree about the row's shape. Converting a
    ///   placeholder row (#135: `provider = openai`, `codex_home IS NULL`, no
    ///   credential) is exactly the "existing row" branch above, since the
    ///   email lookup does not require a credential to already exist — so
    ///   logging into a placeholder's identity lands on that one row, not a
    ///   second one.
    ///
    /// Deliberately keyed **only** by the identity the home itself just
    /// reported (`homeAccountId`/`homeEmail`) — never by `credential`, the
    /// *previous* tenant of this home. Every caller only reaches this
    /// function after `codexHomeConflicts` has already established that the
    /// reported identity disagrees with `credential`'s own, so the row this
    /// resolves to can never be `credential`'s row — the #103 safety
    /// property (never write one identity's usage onto another identity's
    /// row) holds structurally, under any polling order, because this
    /// function never has `credential`'s own account id in hand to write to.
    ///
    /// A cheap read-only check runs first so the overwhelmingly common case —
    /// a *steady* drifted state, unchanged since the last poll that already
    /// adopted it — costs one `SELECT`, not a repeated write or log line,
    /// once the matched row already agrees with `home`.
    ///
    /// Not private: exercised directly by SelfTest, which drives the two
    /// branches (adopt into an existing row / register a new one) and the
    /// #103 non-overwrite property through this exact method rather than
    /// spawning a real `codex` subprocess — same pattern as
    /// `noteCodexIdentityConflict`.
    func adoptDriftedIdentity(
        homeAccountId: String?, homeEmail: String?, home: String, snapshot: ProviderUsageSnapshot?
    ) {
        let normalizedHome = Self.normalizeCodexHome(home)
        let trimmedNativeId = homeAccountId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let nativeId = (trimmedNativeId?.isEmpty == false) ? trimmedNativeId : nil
        let trimmedEmail = homeEmail?.trimmingCharacters(in: .whitespacesAndNewlines)
        let email = (trimmedEmail?.isEmpty == false) ? trimmedEmail : nil
        // Nothing to key a row on — extremely unlikely (a conflict was only
        // just raised from one of these two), but fail closed rather than
        // mint an unattributable row.
        guard nativeId != nil || email != nil else { return }
        guard FileManager.default.fileExists(atPath: dbPath),
              let db = try? openDatabase(dbPath, readonly: true) else { return }

        let existingId = Self.lookupOpenAIAccountId(nativeId: nativeId, email: email, db: db)
        if let existingId {
            let currentHome = (try? db.scalar(
                "SELECT codex_home FROM accounts WHERE id = ?", existingId
            )) as? String
            if currentHome.map(Self.normalizeCodexHome) == normalizedHome {
                return  // already adopted — nothing has changed since the last poll
            }
        }

        let accountId = existingId ?? nativeId ?? "openai-\(UUID().uuidString.lowercased())"
        let isNewRow = existingId == nil

        saveCodexHomeAccount(accountId: accountId, email: email, plan: snapshot?.plan, codexHome: normalizedHome)
        if let snapshot {
            writeSnapshotToDB(accountId: accountId, snapshot: snapshot)
        }

        if loggedCodexAdoption.insert(accountId).inserted {
            let action = isNewRow ? "registered a new account for it" : "repointed the existing account"
            flog.info(
                "codex home re-attribution: \(redactHomePath(normalizedHome)) is now logged in as a different identity — \(action) (\(accountId.prefix(8))…). Its previous account keeps its history and no longer reads as current.",
                category: fcat
            )
        }
    }

    /// The hover/detail text for a drifted row: names the identity the home
    /// now holds (an account id, truncated like every other identifier this
    /// app prints — never an email, see `CodexCLI`'s own rule) and the exact
    /// remediation command. Pure formatting so `SelfTest` can pin it without
    /// a poll.
    nonisolated static func driftDetailMessage(for credential: OAuthCredential, drift: CodexHomeDrift) -> String {
        let home = credential.codexHome.map { " (\(redactHomePath($0)))" } ?? ""
        let identity: String
        switch drift {
        case .drifted(let reportedAccountId):
            identity = reportedAccountId.map { "\($0.prefix(8))…" } ?? "a different account"
        case .stable:
            // Reached only when the id-based comparison disagrees with the
            // email-based gate that triggered this call in the first place
            // (a stale `accounts.email`, not a different login) — a real but
            // rare edge case. Naming no specific identity here is honest:
            // `codexHomeDrift` itself found nothing conclusive.
            identity = "a different account"
        }
        return "\(credential.label)'s Codex home\(home) is now logged in as \(identity), not the account this row is registered against. Register this account's own home with `claude-monitor codex add --home <path>`, or run `claude-monitor codex provision <label>`."
    }

    // MARK: - Import-Time Token Renewal

    /// How far ahead of expiry a credential is renewed. Used only by
    /// `addOpenAIAccount`'s upfront renewal of a just-imported credential
    /// (#104 removed the proactive per-poll renewal loop this constant used
    /// to also drive, since polling no longer holds a stored OpenAI token to
    /// renew).
    let refreshLeadTime: TimeInterval = 6 * 3600

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

    // Not private: exercised directly by SelfTest, which drives the drifted ⇄
    // valid transition (#146) through this exact method rather than
    // reimplementing it. Previously wrapped its body in `Task { @MainActor in
    // ... }`, which was a redundant hop — `OAuthPoller` is already
    // `@MainActor`, so every caller (including this one) is already isolated
    // — and, worse, made the mutation's completion untestable from
    // synchronous code with no run loop to pump. Mutating `credentialStatuses`
    // directly is both simpler and immediately observable.
    func updateCredentialStatus(_ credential: OAuthCredential, status: TokenStatus, error: String?) {
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
