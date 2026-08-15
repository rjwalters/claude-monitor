import Foundation

/// Headless-safe account export/import for multi-host sync (issue #16). Reads
/// and writes `~/.claude-monitor/usage.db` directly through `SQLiteDB.swift` —
/// no AppKit/SwiftUI/Combine — so it works identically on macOS and Linux.
///
/// Export serializes account identity records plus their OAuth credentials
/// (excluding host-local operational state: keychain refs, last_poll_at,
/// last_error). Import upserts by email (falling back to id when email is
/// absent), and never regresses a local record whose `last_updated` is newer
/// than the imported one.
///
/// The exported bundle contains plaintext OAuth tokens — callers (see
/// `AccountSyncCLI`) must treat it as a secret.
enum AccountSync {
    static let formatVersion = 1

    /// New optional fields (`provider`, `tokenExpiresAt`) decode as nil from a
    /// pre-multi-provider bundle and resolve to Anthropic on import, so
    /// `formatVersion` stays at 1 — old and new hosts still interoperate.
    struct ExportedCredential: Codable {
        var label: String
        var source: String
        var provider: String?
        var accessToken: String?
        var refreshToken: String?
        var expiresAt: Int64?
        var tokenExpiresAt: String?
        var scopes: String?
        var subscriptionType: String?
        var rateLimitTier: String?
        var isActive: Bool
        var createdAt: String?
        var updatedAt: String?
        var tokenRolledAt: String?
    }

    struct ExportedAccount: Codable {
        var id: String
        var provider: String?
        var accountName: String?
        var email: String?
        var plan: String?
        var lastUpdated: String?
        var sortOrder: Int
        var credentials: [ExportedCredential]
    }

    struct ExportBundle: Codable {
        var formatVersion: Int
        var exportedAt: String
        var sourceHost: String
        var accounts: [ExportedAccount]
    }

    enum SyncError: Error, LocalizedError {
        /// Carries the path that was actually looked at — with `--db <path>` the
        /// default location is not the one that mattered (issue #105).
        case databaseMissing(String)
        case sqlite(Error)

        var errorDescription: String? {
            switch self {
            case .databaseMissing(let path):
                return "No database found at \(path)"
            case .sqlite(let error):
                return "Database error: \(error.localizedDescription)"
            }
        }
    }

    /// `~/.claude-monitor/usage.db`, resolved the same way as
    /// `UsageStore`/`OAuthPoller`. Every entry point below takes an explicit
    /// `dbPath` (defaulting to this) so callers — including tests — can point
    /// at an isolated database instead.
    static var defaultDBPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude-monitor/usage.db").path
    }

    // MARK: - Export

    static func exportBundle(dbPath: String = defaultDBPath) throws -> ExportBundle {
        guard FileManager.default.fileExists(atPath: dbPath) else { throw SyncError.databaseMissing(dbPath) }
        do {
            let db = try openDatabase(dbPath, readonly: true)
            var accounts: [ExportedAccount] = []

            // Provider columns are selected only when present, so exporting
            // from a database that predates the migration still works.
            let hasAcctProvider = tableColumns(db, "accounts").contains("provider")
            let credColumns = tableColumns(db, "oauth_credentials")
            let hasCredProvider = credColumns.contains("provider")
            let hasTokenExpiry = credColumns.contains("token_expires_at")

            let acctStmt = try db.prepare("""
                SELECT id, account_name, email, plan, last_updated, sort_order,
                       \(hasAcctProvider ? "provider" : "NULL")
                FROM accounts ORDER BY sort_order, id
            """)
            for row in acctStmt {
                guard let id = row[0] as? String else { continue }
                let provider = AccountProvider(stored: row[6] as? String)

                // Codex/OpenAI accounts are host-local (#104): `codex_home`
                // names a local `~/.codex` directory that means nothing on
                // another machine, and any bearer this app still held would
                // be a copy of a secret OpenAI rotates on every use — a copy
                // this export is guaranteed to invalidate the moment it's
                // imported and refreshed elsewhere. Register a Codex account
                // per host instead (`claude-monitor codex add --home`).
                guard provider != .openai else { continue }

                let credStmt = try db.prepare("""
                    SELECT label, source, access_token, refresh_token, expires_at,
                           scopes, subscription_type, rate_limit_tier, is_active,
                           created_at, updated_at, token_rolled_at,
                           \(hasCredProvider ? "provider" : "NULL"),
                           \(hasTokenExpiry ? "token_expires_at" : "NULL")
                    FROM oauth_credentials WHERE account_id = ?
                """)
                var credentials: [ExportedCredential] = []
                for c in credStmt.bind(id) {
                    credentials.append(ExportedCredential(
                        label: (c[0] as? String) ?? id,
                        source: (c[1] as? String) ?? "token",
                        provider: AccountProvider(stored: c[12] as? String).rawValue,
                        accessToken: c[2] as? String,
                        refreshToken: c[3] as? String,
                        expiresAt: c[4] as? Int64,
                        tokenExpiresAt: c[13] as? String,
                        scopes: c[5] as? String,
                        subscriptionType: c[6] as? String,
                        rateLimitTier: c[7] as? String,
                        isActive: ((c[8] as? Int64) ?? 1) == 1,
                        createdAt: c[9] as? String,
                        updatedAt: c[10] as? String,
                        tokenRolledAt: c[11] as? String
                    ))
                }

                accounts.append(ExportedAccount(
                    id: id,
                    provider: provider.rawValue,
                    accountName: row[1] as? String,
                    email: row[2] as? String,
                    plan: row[3] as? String,
                    lastUpdated: row[4] as? String,
                    sortOrder: Int((row[5] as? Int64) ?? 0),
                    credentials: credentials
                ))
            }

            let now = ISO8601DateFormatter().string(from: Date())
            return ExportBundle(
                formatVersion: formatVersion,
                exportedAt: now,
                sourceHost: ProcessInfo.processInfo.hostName,
                accounts: accounts
            )
        } catch let error as SyncError {
            throw error
        } catch {
            throw SyncError.sqlite(error)
        }
    }

    static func exportJSON(pretty: Bool = true, dbPath: String = defaultDBPath) throws -> Data {
        let bundle = try exportBundle(dbPath: dbPath)
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        return try encoder.encode(bundle)
    }

    // MARK: - Import

    struct ImportOutcome {
        let email: String?
        let id: String
        let action: Action

        enum Action: String {
            case created
            case updated
            case skippedNewer  // local record's last_updated is >= the imported one
            case excludedProvider  // provider (e.g. openai/Codex) is host-local; never imported (#104)
        }
    }

    struct ImportSummary {
        var outcomes: [ImportOutcome] = []
        var created: Int { outcomes.filter { $0.action == .created }.count }
        var updated: Int { outcomes.filter { $0.action == .updated }.count }
        var skipped: Int { outcomes.filter { $0.action == .skippedNewer }.count }
        var excluded: Int { outcomes.filter { $0.action == .excludedProvider }.count }
    }

    /// Upserts accounts by email (falling back to id when email is absent on
    /// either side), skipping any account whose local `last_updated` is newer
    /// than or equal to the imported record. Existing local ids are preserved
    /// on match so `usage_history` / `probe_snapshots` rows stay attached.
    @discardableResult
    static func importBundle(_ bundle: ExportBundle, dbPath: String = defaultDBPath) throws -> ImportSummary {
        guard FileManager.default.fileExists(atPath: dbPath) else { throw SyncError.databaseMissing(dbPath) }
        do {
            let db = try openDatabase(dbPath)
            // Bring the target database up to the current schema first — a host
            // that has never launched the app still has a pre-migration
            // database, and the upserts below write the provider columns.
            try? UsageStore.applySchema(db)
            var summary = ImportSummary()
            for account in bundle.accounts {
                summary.outcomes.append(try importAccount(account, db: db))
            }
            return summary
        } catch let error as SyncError {
            throw error
        } catch {
            throw SyncError.sqlite(error)
        }
    }

    private static func importAccount(_ account: ExportedAccount, db: Connection) throws -> ImportOutcome {
        // A bundle exported before multi-provider support carries no provider;
        // it resolves to Anthropic, which is what those hosts were polling.
        let resolvedProvider = AccountProvider(stored: account.provider)

        // Codex/OpenAI accounts are host-local (#104) and current exports never
        // emit one, but an *older* bundle produced before this change may still
        // carry one. Skip it rather than failing the whole import — importing
        // it would be pointless (`codex_home` is never exported, so there is
        // nothing on this host for the account to read) and any bearer it
        // carries is a copy of a secret this host must not hold.
        guard resolvedProvider != .openai else {
            return ImportOutcome(email: account.email, id: account.id, action: .excludedProvider)
        }
        let provider = resolvedProvider.rawValue

        var existingId: String?
        var existingLastUpdated: String?

        // The email match MUST be scoped to the incoming account's provider: a
        // Claude and a ChatGPT account legitimately share one address, and an
        // unscoped match lands the OpenAI import on the Anthropic row —
        // flipping its provider and overwriting its credential in place, which
        // destroys the Claude token.
        if let email = account.email, !email.isEmpty {
            let stmt = try db.prepare("""
                SELECT id, last_updated FROM accounts
                WHERE email = ? AND COALESCE(provider, 'anthropic') = ? LIMIT 1
            """)
            for r in stmt.bind(email, provider) {
                existingId = r[0] as? String
                existingLastUpdated = r[1] as? String
            }
        }
        if existingId == nil {
            let stmt = try db.prepare("SELECT id, last_updated FROM accounts WHERE id = ? LIMIT 1")
            for r in stmt.bind(account.id) {
                existingId = r[0] as? String
                existingLastUpdated = r[1] as? String
            }
        }

        let isNewAccount = existingId == nil
        let targetId = existingId ?? account.id

        if !isNewAccount, isLocalAuthoritative(existingLastUpdated, incoming: account.lastUpdated) {
            return ImportOutcome(email: account.email, id: targetId, action: .skippedNewer)
        }

        let now = ISO8601DateFormatter().string(from: Date())
        let lastUpdated = account.lastUpdated ?? now

        try db.run("""
            INSERT INTO accounts (id, account_name, email, plan, last_updated, sort_order, provider)
            VALUES (?, ?, ?, ?, ?, COALESCE((SELECT MAX(sort_order) + 1 FROM accounts), 0), ?)
            ON CONFLICT(id) DO UPDATE SET
                account_name = COALESCE(excluded.account_name, accounts.account_name),
                email = COALESCE(excluded.email, accounts.email),
                plan = COALESCE(excluded.plan, accounts.plan),
                last_updated = excluded.last_updated,
                provider = excluded.provider
        """, targetId, account.accountName, account.email, account.plan, lastUpdated, provider)

        for credential in account.credentials {
            try importCredential(credential, accountId: targetId, db: db)
        }

        return ImportOutcome(email: account.email, id: targetId, action: isNewAccount ? .created : .updated)
    }

    private static func importCredential(_ credential: ExportedCredential, accountId: String, db: Connection) throws {
        let now = ISO8601DateFormatter().string(from: Date())
        let existingId = try db.scalar(
            "SELECT id FROM oauth_credentials WHERE account_id = ? LIMIT 1", accountId
        ) as? Int64
        let existingToken = try db.scalar(
            "SELECT access_token FROM oauth_credentials WHERE account_id = ? LIMIT 1", accountId
        ) as? String

        let provider = AccountProvider(stored: credential.provider).rawValue

        if let credId = existingId {
            // Only bump token_rolled_at when the token value actually changes,
            // mirroring saveCredentialForAccount's roll-clock semantics.
            let tokenChanged = existingToken != credential.accessToken
            try db.run("""
                UPDATE oauth_credentials SET
                    label = ?, source = ?, provider = ?, access_token = ?, refresh_token = ?,
                    expires_at = ?, token_expires_at = ?,
                    scopes = ?, subscription_type = ?, rate_limit_tier = ?,
                    is_active = ?, updated_at = ?,
                    token_rolled_at = CASE WHEN ? THEN ? ELSE token_rolled_at END
                WHERE id = ?
            """, credential.label, credential.source, provider, credential.accessToken, credential.refreshToken,
                 credential.expiresAt, credential.tokenExpiresAt,
                 credential.scopes, credential.subscriptionType, credential.rateLimitTier,
                 credential.isActive, now, tokenChanged, credential.tokenRolledAt ?? now, credId)
        } else {
            try db.run("""
                INSERT INTO oauth_credentials (
                    account_id, label, source, provider, access_token, refresh_token,
                    expires_at, token_expires_at, scopes, subscription_type, rate_limit_tier,
                    is_active, created_at, updated_at, token_rolled_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, accountId, credential.label, credential.source, provider,
                 credential.accessToken, credential.refreshToken,
                 credential.expiresAt, credential.tokenExpiresAt,
                 credential.scopes, credential.subscriptionType, credential.rateLimitTier,
                 credential.isActive, credential.createdAt ?? now, now, credential.tokenRolledAt)
        }
    }

    /// True if the local record should win: it has a timestamp at least as
    /// recent as the incoming one, or the incoming record carries no
    /// timestamp to compare against. False (incoming wins) when the local
    /// record has no timestamp but the incoming one does.
    private static func isLocalAuthoritative(_ existing: String?, incoming: String?) -> Bool {
        guard let incoming = incoming, let incomingDate = UsageRecord.parseISO(incoming) else { return true }
        guard let existing = existing, let existingDate = UsageRecord.parseISO(existing) else { return false }
        return existingDate >= incomingDate
    }
}
