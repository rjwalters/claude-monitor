import Foundation

/// `ClaudeMonitor selftest` — assertions over the portable core, runnable on
/// macOS and Linux with no network, no credentials, and no package
/// dependencies (this project deliberately has none, so there is no XCTest
/// target to hang tests off).
///
/// Everything here operates on throwaway databases under a temporary
/// directory; the real `~/.claude-monitor/usage.db` is never opened.
/// Exits 0 when every check passes, 1 otherwise, so CI can gate on it.
enum SelfTest {
    private static var failures: [String] = []
    private static var checks = 0

    static func main(_ arguments: [String] = []) -> Never {
        failures = []
        checks = 0

        if arguments.contains("--help") || arguments.contains("-h") {
            print("""
                Usage: ClaudeMonitor selftest [--db <path>]

                Runs assertions over the portable core (rate-limit window model,
                schema migration). No network access and no credentials needed.

                  --db <path>   Additionally migrate an existing database *copy*
                                and verify its accounts still load. Point this at
                                a COPY of ~/.claude-monitor/usage.db — it writes.

                Exits 0 when every check passes, 1 otherwise.
                """)
            exit(0)
        }

        testWindowKindDerivation()
        testSnapshotFromPositionalWindows()
        testMissingSessionWindow()
        testProviderParsing()
        testSchemaMigrationFromPreMigrationDatabase()

        if let idx = arguments.firstIndex(of: "--db"), idx + 1 < arguments.count {
            testMigrationOfExistingDatabase(at: arguments[idx + 1])
        }

        if failures.isEmpty {
            print("selftest: \(checks) check(s) passed")
            exit(0)
        }
        for failure in failures {
            FileHandle.standardError.write(Data("selftest FAILED: \(failure)\n".utf8))
        }
        FileHandle.standardError.write(Data("selftest: \(failures.count)/\(checks) check(s) failed\n".utf8))
        exit(1)
    }

    // MARK: - Assertions

    private static func expect(_ condition: Bool, _ message: @autoclosure () -> String) {
        checks += 1
        if !condition { failures.append(message()) }
    }

    private static func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
        checks += 1
        if actual != expected {
            failures.append("\(label): expected \(expected), got \(actual)")
        }
    }

    // MARK: - Window model

    /// Window kind must come from the window's *duration*, never its position
    /// in the provider response (spike #26: a weekly `primary_window` with a
    /// null `secondary_window` is a real, observed reply).
    private static func testWindowKindDerivation() {
        expectEqual(RateLimitWindow.kind(forDuration: 18000), .session, "5h → session")
        expectEqual(RateLimitWindow.kind(forDuration: 300), .session, "300s → session")
        expectEqual(RateLimitWindow.kind(forDuration: 604800), .weekly, "604800s (7d) → weekly")
        expectEqual(RateLimitWindow.kind(forDuration: nil), .unknown, "no duration → unknown")
        expectEqual(RateLimitWindow.kind(forDuration: 0), .unknown, "zero duration → unknown")
        expectEqual(RateLimitWindow.kind(forDuration: 30 * 86400), .other(30 * 86400), "30d → other")

        // Kind-labelled sources get the bucket's nominal duration for free.
        let labelled = RateLimitWindow(kind: .weekly, usedPercent: 44)
        expectEqual(labelled.durationSeconds, 7 * 86400, "weekly nominal duration")
        expectEqual(labelled.remainingPercent, 56, "remainingPercent")
        expect(!labelled.isExhausted, "44% weekly is not exhausted")
        expect(RateLimitWindow(kind: .weekly, usedPercent: 12, status: "rejected").isExhausted,
               "a rejected window is exhausted regardless of percent")
    }

    /// The exact shape the live-verified Codex probe returned: a *weekly*
    /// `primary_window` and a null `secondary_window`. Filing by duration must
    /// land it in `weekly`, leaving `session` nil.
    private static func testSnapshotFromPositionalWindows() {
        let primary = RateLimitWindow(
            usedPercent: 14,
            durationSeconds: 604800,
            resetAt: Date(timeIntervalSince1970: 1785967226)
        )
        let snapshot = RateLimitSnapshot(windows: [primary])

        expect(snapshot.session == nil, "primary weekly window must not be filed as session")
        expectEqual(snapshot.weekly?.usedPercent, 14, "weekly usedPercent")
        expectEqual(snapshot.weekly?.kind, .weekly, "weekly kind")
        expectEqual(snapshot.headroomScore, 86, "headroom from a weekly-only snapshot")

        // Order must not matter: a session window arriving in the *secondary*
        // slot still files as session.
        let reordered = RateLimitSnapshot(windows: [
            RateLimitWindow(usedPercent: 90, durationSeconds: 604800),
            RateLimitWindow(usedPercent: 10, durationSeconds: 18000),
        ])
        expectEqual(reordered.session?.usedPercent, 10, "session filed from second slot")
        expectEqual(reordered.weekly?.usedPercent, 90, "weekly filed from first slot")
        expectEqual(reordered.headroomScore, 10, "headroom uses the most-consumed window")
    }

    /// A nil session window must be a supported state end-to-end: no crash, and
    /// no misleading 0%-used / 100-headroom reading.
    private static func testMissingSessionWindow() {
        let weeklyOnly = UsageRecord(
            id: 1, accountId: "acct", timestamp: Date(),
            primaryPercent: 14, sessionPercent: nil, weeklyAllPercent: 14,
            weeklySONnetPercent: nil, sessionReset: nil, weeklyReset: nil
        )
        expect(weeklyOnly.rateLimit.session == nil, "NULL session_percent must stay nil, not become 0%")
        expectEqual(headroomScore(weeklyOnly), 86, "weekly-only account scores off the weekly window")

        // Nothing known at all: score is nil so the UI shows "—" rather than a
        // confident 100 ("plenty of capacity") or 0 ("exhausted").
        let empty = UsageRecord(
            id: 2, accountId: "acct", timestamp: Date(),
            primaryPercent: nil, sessionPercent: nil, weeklyAllPercent: nil,
            weeklySONnetPercent: nil, sessionReset: nil, weeklyReset: nil
        )
        expect(empty.rateLimit.isEmpty, "a record with no windows is empty")
        expect(headroomScore(empty) == nil, "no windows → nil headroom, never a number")
        expect(headroomScore(nil) == nil, "no record → nil headroom")
        expectEqual(UsageStore.resetSeconds(empty), .greatestFiniteMagnitude, "no window → unknown reset")

        // Anthropic's usual both-windows reading is unaffected.
        let both = UsageRecord(
            id: 3, accountId: "acct", timestamp: Date(),
            primaryPercent: 70, sessionPercent: 70, weeklyAllPercent: 30,
            weeklySONnetPercent: nil, sessionReset: nil, weeklyReset: nil
        )
        expectEqual(headroomScore(both), 30, "both windows → scored on the worse one")
    }

    private static func testProviderParsing() {
        expectEqual(AccountProvider(stored: nil), .anthropic, "missing provider → anthropic")
        expectEqual(AccountProvider(stored: ""), .anthropic, "blank provider → anthropic")
        expectEqual(AccountProvider(stored: "  OpenAI "), .openai, "provider parse is trimmed + case-insensitive")
        expectEqual(AccountProvider(stored: "martian"), .anthropic, "unknown provider → anthropic fallback")
        expectEqual(AccountProvider(stored: "openai").rawValue, "openai", "round-trips through rawValue")
    }

    // MARK: - Schema migration

    /// Builds a database with the *pre-#28* schema, populates it the way a real
    /// installation would, then runs the current migration over it and checks
    /// that (a) the new columns exist, (b) existing rows were backfilled to
    /// `anthropic`, and (c) the account still loads and reads normally.
    private static func testSchemaMigrationFromPreMigrationDatabase() {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("claude-monitor-selftest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let dbPath = dir.appendingPathComponent("usage.db").path

            // --- The v1.17.0 schema, verbatim minus the new columns. ---
            let legacy = try openDatabase(dbPath)
            try legacy.execute("""
                CREATE TABLE accounts (
                    id TEXT PRIMARY KEY,
                    account_name TEXT,
                    email TEXT,
                    plan TEXT,
                    last_updated TEXT,
                    sort_order INTEGER DEFAULT 0
                );
                CREATE TABLE usage_history (
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
                    is_synthetic INTEGER DEFAULT 0
                );
                CREATE TABLE oauth_credentials (
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
                    updated_at TEXT NOT NULL
                );
            """)
            let now = ISO8601DateFormatter().string(from: Date())
            // Backdate the reading: `loadFromDatabase` filters on
            // `timestamp <= <now, with fractional seconds>`, and a row stamped
            // in the same second sorts *after* that bound as a string.
            let earlier = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-60))
            try legacy.run("""
                INSERT INTO accounts (id, account_name, email, plan, last_updated, sort_order)
                VALUES ('org-legacy', 'legacy@example.com', 'legacy@example.com', 'Max', ?, 0)
            """, now)
            try legacy.run("""
                INSERT INTO usage_history
                    (account_id, timestamp, primary_percent, session_percent,
                     weekly_all_percent, weekly_sonnet_percent, is_synthetic)
                VALUES ('org-legacy', ?, 40, 40, 12, 0, 0)
            """, earlier)
            try legacy.run("""
                INSERT INTO oauth_credentials (account_id, label, source, access_token, is_active, created_at, updated_at)
                VALUES ('org-legacy', 'legacy@example.com', 'token', 'sk-ant-oat01-selftest', 1, ?, ?)
            """, now, now)

            expect(!tableColumns(legacy, "accounts").contains("provider"),
                   "fixture must start without the provider column")

            // --- What launching the current build does. ---
            let store = UsageStore(dbPath: dbPath)
            store.ensureDatabase()

            let db = try openDatabase(dbPath, readonly: true)
            expect(tableColumns(db, "accounts").contains("provider"),
                   "migration adds accounts.provider")
            let credColumns = tableColumns(db, "oauth_credentials")
            expect(credColumns.contains("provider"), "migration adds oauth_credentials.provider")
            expect(credColumns.contains("refresh_token"), "migration ensures oauth_credentials.refresh_token")
            expect(credColumns.contains("token_expires_at"), "migration adds oauth_credentials.token_expires_at")
            expect(credColumns.contains("token_rolled_at"), "pre-existing token_rolled_at migration still runs")

            expectEqual(try db.scalar("SELECT provider FROM accounts WHERE id = 'org-legacy'") as? String,
                        "anthropic", "existing account backfilled to anthropic")
            expectEqual(try db.scalar("SELECT provider FROM oauth_credentials WHERE account_id = 'org-legacy'") as? String,
                        "anthropic", "existing credential backfilled to anthropic")
            expect((try db.scalar("SELECT token_expires_at FROM oauth_credentials WHERE account_id = 'org-legacy'")) == nil,
                   "Anthropic credentials leave token_expires_at null")

            // The pre-migration account keeps working with no user action.
            store.loadFromDatabase()
            expectEqual(store.accounts.count, 1, "migrated account still loads")
            expectEqual(store.accounts.first?.provider, .anthropic, "loaded account resolves to anthropic")
            expectEqual(headroomScore(store.latestUsage["org-legacy"]), 60, "usage still reads through the window model")

            // Migration is idempotent — a second launch is a no-op, not an error.
            UsageStore(dbPath: dbPath).ensureDatabase()
            expectEqual(try db.scalar("SELECT COUNT(*) FROM accounts") as? Int64, 1,
                        "re-running the migration doesn't duplicate rows")

            // Export/import round-trips the new columns.
            let bundle = try AccountSync.exportBundle(dbPath: dbPath)
            expectEqual(bundle.accounts.first?.provider, "anthropic", "export carries provider")
            let reimportPath = dir.appendingPathComponent("usage-copy.db").path
            try FileManager.default.copyItem(atPath: dbPath, toPath: reimportPath)
            _ = try AccountSync.importBundle(bundle, dbPath: reimportPath)
            let copy = try openDatabase(reimportPath, readonly: true)
            expectEqual(try copy.scalar("SELECT provider FROM accounts WHERE id = 'org-legacy'") as? String,
                        "anthropic", "import preserves provider")
        } catch {
            checks += 1
            failures.append("schema migration test threw: \(error)")
        }
    }

    /// Migrate a real (copied) database and confirm its accounts still load —
    /// the "launch against a pre-migration `usage.db`" check, run on demand
    /// against a copy of a real installation's database rather than a fixture.
    private static func testMigrationOfExistingDatabase(at path: String) {
        do {
            guard FileManager.default.fileExists(atPath: path) else {
                checks += 1
                failures.append("--db: no database at \(path)")
                return
            }

            let before = UsageStore(dbPath: path)
            before.loadFromDatabase()
            let accountsBefore = before.accounts.count
            let scoresBefore = before.accounts.reduce(into: [String: Double?]()) {
                $0[$1.id] = headroomScore(before.latestUsage[$1.id])
            }

            let store = UsageStore(dbPath: path)
            store.ensureDatabase()
            store.loadFromDatabase()

            let db = try openDatabase(path, readonly: true)
            expect(tableColumns(db, "accounts").contains("provider"),
                   "--db: migration added accounts.provider")
            let credColumns = tableColumns(db, "oauth_credentials")
            expect(credColumns.contains("provider"), "--db: migration added oauth_credentials.provider")
            expect(credColumns.contains("token_expires_at"), "--db: migration added oauth_credentials.token_expires_at")

            expectEqual(store.accounts.count, accountsBefore, "--db: account count unchanged by migration")
            expect(store.accounts.allSatisfy { $0.provider == .anthropic },
                   "--db: every pre-existing account backfilled to anthropic")
            for account in store.accounts {
                expectEqual(headroomScore(store.latestUsage[account.id]),
                            scoresBefore[account.id] ?? nil,
                            "--db: headroom for \(account.id) unchanged by migration")
            }
            let stray = try db.scalar(
                "SELECT COUNT(*) FROM accounts WHERE provider IS NULL OR TRIM(provider) = ''"
            ) as? Int64
            expectEqual(stray, 0, "--db: no account left without a provider")
            print("selftest --db: migrated \(store.accounts.count) account(s) at \(path)")
        } catch {
            checks += 1
            failures.append("--db migration check threw: \(error)")
        }
    }
}
