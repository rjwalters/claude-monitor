import Foundation

/// `ClaudeMonitor selftest` — assertions over the portable core, runnable on
/// macOS and Linux with no network, no credentials, and no package
/// dependencies (this project deliberately has none, so there is no XCTest
/// target to hang tests off).
///
/// Everything here operates on throwaway databases under a temporary
/// directory; the real `~/.claude-monitor/usage.db` is never opened.
/// Exits 0 when every check passes, 1 otherwise, so CI can gate on it.
///
/// @MainActor: several checks exercise `UsageStore` (a main-actor-isolated
/// class — see its definition) directly against throwaway databases; `main()`
/// runs synchronously to completion on the process's initial thread before
/// calling `exit()`, so this matches the real caller rather than forcing a
/// `Task` hop purely to satisfy the type-checker.
@MainActor
enum SelfTest {
    // `main()` runs every test function sequentially on a single thread to
    // completion before exiting the process — there is no concurrent access,
    // so a global accumulator is genuinely safe here (narrower than adding an
    // actor or threading state through every one of the ~40 call sites below).
    private nonisolated(unsafe) static var failures: [String] = []
    private nonisolated(unsafe) static var checks = 0

    static func main(_ arguments: [String] = []) -> Never {
        failures = []
        checks = 0

        if arguments.contains("--help") || arguments.contains("-h") {
            print("""
                Usage: ClaudeMonitor selftest [--db <path>] [--wire <path>]

                Runs assertions over the portable core (rate-limit window model,
                schema migration). No network access and no credentials needed.

                  --db <path>   Additionally migrate an existing database *copy*
                                and verify its accounts still load. Point this at
                                a COPY of ~/.claude-monitor/usage.db — it writes.

                  --wire <path> Additionally decode a captured OpenAI
                                `GET /backend-api/wham/usage` body and report the
                                windows it maps to — the offline way to re-check
                                the wire contract after OpenAI changes it. Only
                                derived numbers are printed; identity fields are
                                never echoed.

                  --codex       Additionally run the real `codex app-server`
                                handshake once against the installed Codex CLI
                                and report the windows it maps to. OPT-IN: every
                                other check is offline, so CI never needs codex
                                installed. Only derived numbers are printed;
                                identity fields are never echoed.

                Exits 0 when every check passes, 1 otherwise.
                """)
            exit(0)
        }

        testNaturalSort()
        testSortedAccountsForPopoverTieBreak()
        testGatingResetOrdering()
        testWindowKindDerivation()
        testSnapshotFromPositionalWindows()
        testMissingSessionWindow()
        testProviderParsing()
        testOpenAIUsageResponseMapping()
        testOpenAIRawFieldRedaction()
        testOpenAITokenExpiryParsing()
        testCodexAuthParsing()
        testCodexAppServerFraming()
        testCodexAppServerEnvelopeDecoding()
        testCodexVersionDiagnosticLogging()
        testCodexAppServerMapping()
        testCodexAppServerRedaction()
        testCodexSnapshotOfflinePathWritesNoLog()
        testCodexBinaryResolution()
        testCodexHomeIdentityGuard()
        testCodexHomeResolution()
        testCodexHomeRegistrationEnumeration()
        testCodexAppServerSpawnAgainstStub()
        testCodexPerAccountHomeReachesChild()
        testSchemaMigrationFromPreMigrationDatabase()
        testRankingExportCarriesProvider()
        testNamedLimitsRoundTrip()
        testOpenAIImportResolvesExistingAccountByEmail()
        testExportAccountsEnvIncludesAllProviders()
        testExportAccountsEnvExcludesTokenlessCodexAccount()
        testExportAccountsEnvCodexOnlyHostIsNotGenuinelyEmpty()
        testExportAccountsEnvGenuinelyEmptyStoreReturnsNil()
        testParseAccountPairsBackwardCompatibleWithOldFormat()
        testParseAccountPairsRoundTripsOpenAIFields()
        testAccountSyncExcludesOpenAIAccounts()
        testMergeDuplicateAccountsSharingEmail()
        testAccountDeletionRemovesCredentials()
        testPurgeOrphanedCredentialsMigration()
        testNullOutOpenAITokensMigration()
        testPurgeOrphanedProbeAndNamedLimitsMigration()
        testReadOnlyOpenOfWALDatabaseWithoutSHM()

        if let idx = arguments.firstIndex(of: "--db"), idx + 1 < arguments.count {
            testMigrationOfExistingDatabase(at: arguments[idx + 1])
        }

        if let idx = arguments.firstIndex(of: "--wire"), idx + 1 < arguments.count {
            testCapturedOpenAIWireBody(at: arguments[idx + 1])
        }

        if arguments.contains("--codex") {
            testLiveCodexAppServer()
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

    // MARK: - Account name ordering

    /// Natural (hybrid lexical/numeric) ordering of account names. The rules
    /// live beside the implementation in `NaturalSort.selfCheck()`, which
    /// reports its own count and failures rather than depending on this file's
    /// private helpers.
    private static func testNaturalSort() {
        let result = NaturalSort.selfCheck()
        checks += result.checks
        failures.append(contentsOf: result.failures.map { "naturalSort: \($0)" })
    }

    /// Two accounts with identical usage and reset must not fall through to
    /// arbitrary insertion/UUID order (#40): the account id here is chosen to
    /// *disagree* with natural name order, so a fix that still tiebreaks on
    /// id would sort these the wrong way.
    private static func testSortedAccountsForPopoverTieBreak() {
        let store = UsageStore(dbPath: ":memory:selftest-tiebreak")

        let agentNine = Account(
            id: "zzz-later-id", accountName: "agent-9", email: nil, plan: "Max",
            lastUpdated: nil, latestPercent: nil
        )
        let agentTen = Account(
            id: "aaa-earlier-id", accountName: "agent-10", email: nil, plan: "Max",
            lastUpdated: nil, latestPercent: nil
        )
        store.accounts = [agentTen, agentNine]

        func identicalUsage(_ accountId: String, _ recordId: Int64) -> UsageRecord {
            UsageRecord(
                id: recordId, accountId: accountId, timestamp: Date(),
                primaryPercent: 50, sessionPercent: 50, weeklyAllPercent: 20,
                weeklySONnetPercent: nil, sessionReset: nil, weeklyReset: nil
            )
        }
        store.latestUsage = [
            agentNine.id: identicalUsage(agentNine.id, 1),
            agentTen.id: identicalUsage(agentTen.id, 2),
        ]

        let ordered = store.sortedAccountsForPopover.map { $0.displayName }
        expectEqual(ordered, ["agent-9", "agent-10"],
                    "equal usage/reset falls back to natural name order, not account id")
    }

    /// Accounts that are all capped (0 headroom) still have a meaningful order:
    /// whichever comes back first. The gating reset is the weekly one once the
    /// week is spent, so an account with a session reset minutes away but no
    /// weekly capacity must rank *behind* one whose session reset is hours out.
    private static func testGatingResetOrdering() {
        func iso(_ seconds: TimeInterval) -> String {
            ISO8601DateFormatter().string(from: Date().addingTimeInterval(seconds))
        }
        func capped(_ accountId: String, weekly: Double, session: TimeInterval, weeklyReset: TimeInterval)
            -> UsageRecord {
            UsageRecord(
                id: 1, accountId: accountId, timestamp: Date(),
                primaryPercent: 100, sessionPercent: 100, weeklyAllPercent: weekly,
                weeklySONnetPercent: nil,
                sessionReset: iso(session), weeklyReset: iso(weeklyReset)
            )
        }

        // Session-capped with weekly capacity left → the session reset gates.
        let sessionGated = capped("a", weekly: 40, session: 7200, weeklyReset: 3 * 86400)
        expect((sessionGated.rateLimit.secondsUntilRecovery ?? 0) > 7000,
               "session-capped account recovers at its session reset")
        expect((sessionGated.rateLimit.secondsUntilRecovery ?? .infinity) < 7300,
               "session-gated recovery must not read the weekly reset")

        // Weekly spent → the session reset is irrelevant; the week gates.
        let weeklyGated = capped("b", weekly: 100, session: 600, weeklyReset: 3 * 86400)
        expect((weeklyGated.rateLimit.secondsUntilRecovery ?? 0) > 2 * 86400,
               "an exhausted weekly window gates recovery, not the session reset")

        // Nothing known → unknown, never "available now".
        let empty = UsageRecord(
            id: 2, accountId: "c", timestamp: Date(),
            primaryPercent: nil, sessionPercent: nil, weeklyAllPercent: nil,
            weeklySONnetPercent: nil, sessionReset: nil, weeklyReset: nil
        )
        expect(empty.rateLimit.secondsUntilRecovery == nil, "no windows → unknown recovery")

        let store = UsageStore(dbPath: ":memory:selftest-gating")
        func account(_ name: String) -> Account {
            Account(id: name, accountName: name, email: nil, plan: "Max",
                    lastUpdated: nil, latestPercent: nil)
        }
        store.accounts = ["agent-1", "agent-2", "agent-3"].map(account)
        store.latestUsage = [
            "agent-1": capped("agent-1", weekly: 40, session: 7200, weeklyReset: 3 * 86400),
            "agent-2": capped("agent-2", weekly: 100, session: 600, weeklyReset: 3 * 86400),
            "agent-3": capped("agent-3", weekly: 10, session: 1800, weeklyReset: 3 * 86400),
        ]
        expectEqual(store.sortedAccountsForPopover.map { $0.displayName },
                    ["agent-3", "agent-1", "agent-2"],
                    "capped accounts order by time until they are usable again")
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

    // MARK: - OpenAI / Codex

    /// A recorded `GET /backend-api/wham/usage` body in the exact shape the
    /// live probe returned (spike #26 § "Live verification"), with every
    /// identity value replaced by a fixture string. Deliberately includes the
    /// two findings that broke the static-analysis hypothesis: a **weekly**
    /// `primary_window` and a **null** `secondary_window`.
    private static let openAIUsageFixture = """
    {
      "user_id": "user-fixture",
      "account_id": "acct-fixture",
      "email": "fixture@example.com",
      "plan_type": "pro",
      "rate_limit": {
        "allowed": true,
        "limit_reached": false,
        "primary_window": {
          "used_percent": 14,
          "limit_window_seconds": 604800,
          "reset_after_seconds": 524971,
          "reset_at": 1785967226
        },
        "secondary_window": null
      },
      "code_review_rate_limit": null,
      "additional_rate_limits": [
        {
          "limit_name": "GPT-5.3-Codex-Spark",
          "metered_feature": "codex_bengalfox",
          "rate_limit": {
            "allowed": true,
            "limit_reached": false,
            "primary_window": {
              "used_percent": 62,
              "limit_window_seconds": 604800,
              "reset_after_seconds": 100,
              "reset_at": 1785967226
            },
            "secondary_window": null
          }
        }
      ]
    }
    """

    /// The wire contract, mapped onto the shared model: windows filed by
    /// duration, a null secondary window left nil, identity picked up from the
    /// same response, and per-model sub-limits landing in `named`.
    private static func testOpenAIUsageResponseMapping() {
        do {
            let snapshot = try OpenAIAPIClient.snapshot(
                from: Data(openAIUsageFixture.utf8), httpStatus: 200
            )

            expectEqual(snapshot.provider, .openai, "snapshot provider")
            expectEqual(snapshot.accountKey, "acct-fixture", "account key from account_id")
            expectEqual(snapshot.email, "fixture@example.com", "identity arrives with usage")
            expectEqual(snapshot.plan, "pro", "plan_type arrives with usage")

            let windows = snapshot.rateLimit
            expect(windows.session == nil,
                   "a null secondary_window must leave session nil, never a fabricated 0%")
            expectEqual(windows.weekly?.usedPercent, 14, "weekly used_percent")
            expectEqual(windows.weekly?.kind, .weekly,
                        "a weekly primary_window is filed by duration, not by slot")
            expectEqual(windows.weekly?.durationSeconds, 604800, "limit_window_seconds is seconds")
            expectEqual(windows.weekly?.resetAt, Date(timeIntervalSince1970: 1785967226),
                        "reset_at is unix epoch seconds")
            expectEqual(windows.headroomScore, 86, "headroom from a weekly-only OpenAI snapshot")
            expectEqual(windows.overallStatus, "allowed", "allowed:true maps to the shared 'allowed'")
            expectEqual(windows.named["GPT-5.3-Codex-Spark"]?.usedPercent, 62,
                        "additional_rate_limits land in the named sub-limit map")

            // `limit_reached` is the direct "you are cut off" signal.
            let capped = openAIUsageFixture
                .replacingOccurrences(of: "\"limit_reached\": false", with: "\"limit_reached\": true")
                .replacingOccurrences(of: "\"allowed\": true", with: "\"allowed\": false")
            let cappedSnapshot = try OpenAIAPIClient.snapshot(from: Data(capped.utf8), httpStatus: 200)
            expectEqual(cappedSnapshot.rateLimit.overallStatus, "rejected",
                        "limit_reached maps to the shared 'rejected' status")
            expect(cappedSnapshot.rateLimit.weekly?.isExhausted == true,
                   "a rejected window reads as exhausted regardless of percent")

            // A response with no account_id is unusable — fail rather than
            // inventing a key that would collide across accounts.
            let anonymous = openAIUsageFixture
                .replacingOccurrences(of: "\"account_id\": \"acct-fixture\"", with: "\"account_id\": null")
            var threw = false
            do {
                _ = try OpenAIAPIClient.snapshot(from: Data(anonymous.utf8), httpStatus: 200)
            } catch {
                threw = true
            }
            expect(threw, "a response without account_id must throw, not fabricate a key")

            // A session window arriving in either slot still files as session.
            let withSession = openAIUsageFixture.replacingOccurrences(
                of: "\"secondary_window\": null",
                with: """
                "secondary_window": {"used_percent": 30, "limit_window_seconds": 18000, "reset_at": 1785900000}
                """
            )
            let paired = try OpenAIAPIClient.snapshot(from: Data(withSession.utf8), httpStatus: 200)
            expectEqual(paired.rateLimit.session?.usedPercent, 30, "session filed from the secondary slot")
            expectEqual(paired.rateLimit.weekly?.usedPercent, 14, "weekly stays in weekly")
            expectEqual(paired.rateLimit.headroomScore, 70, "headroom uses the most-consumed window")
        } catch {
            checks += 1
            failures.append("OpenAI usage mapping threw: \(error)")
        }
    }

    /// The archive must capture the response's *shape* without its secrets. The
    /// #26 near-miss was a **nested** identity claim surviving a top-level-only
    /// redaction pass, so this asserts on nesting explicitly.
    private static func testOpenAIRawFieldRedaction() {
        do {
            let snapshot = try OpenAIAPIClient.snapshot(
                from: Data(openAIUsageFixture.utf8), httpStatus: 200
            )
            let archived = snapshot.rawFields
            let serialized = archived.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")

            expect(!serialized.contains("fixture@example.com"), "email must never reach the archive")
            expect(!serialized.contains("acct-fixture"), "account_id must never reach the archive")
            expect(!serialized.contains("user-fixture"), "user_id must never reach the archive")
            expectEqual(archived["email"], "[redacted]", "redacted keys are recorded as present")

            // Nested PII: a profile object buried two levels down must be
            // redacted just like a top-level key.
            let nested = """
            {"account_id":"acct-fixture","rate_limit":{"allowed":true,"primary_window":
             {"used_percent":1,"limit_window_seconds":604800}},
             "profile":{"organization":{"email":"nested@example.com","name":"Nested Person"}}}
            """
            let nestedSnapshot = try OpenAIAPIClient.snapshot(from: Data(nested.utf8), httpStatus: 200)
            let nestedSerialized = nestedSnapshot.rawFields
                .map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
            expect(!nestedSerialized.contains("nested@example.com"),
                   "a nested email claim must be redacted (the #26 near-miss)")
            expect(!nestedSerialized.contains("Nested Person"),
                   "a nested name claim must be redacted")
            expectEqual(nestedSnapshot.rawFields["profile.organization.email"], "[redacted]",
                        "nested redaction records the path")

            // Non-PII fields are still archived verbatim, so a field OpenAI adds
            // later is captured before we interpret it.
            expectEqual(archived["rate_limit.primary_window.limit_window_seconds"], "604800",
                        "verbatim wire fields are archived")
            expectEqual(archived["overall_status"], "allowed",
                        "normalized status keys are archived for RankingExporter")
        } catch {
            checks += 1
            failures.append("OpenAI redaction test threw: \(error)")
        }
    }

    /// Base64url-encodes a JSON fixture for building a synthetic JWT (no
    /// padding, `+`/`/` swapped for `-`/`_` per RFC 7515 §2). Shared by the
    /// OpenAI-token and Codex-auth fixture tests below.
    private static func b64url(_ json: String) -> String {
        Data(json.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// OpenAI access tokens expire (~10 days) and `auth.json` states no expiry,
    /// so the token's own `exp` claim is the only source. Only `exp` is read.
    private static func testOpenAITokenExpiryParsing() {
        // A structurally-valid but entirely synthetic JWT — no real credential.
        let token = "\(b64url("{\"alg\":\"RS256\"}")).\(b64url("{\"exp\":1785967226,\"sub\":\"fixture\"}")).sig"
        expectEqual(OpenAIAPIClient.accessTokenExpiry(token),
                    Date(timeIntervalSince1970: 1785967226), "exp claim decodes to a Date")
        expect(OpenAIAPIClient.accessTokenExpiry("not-a-jwt") == nil, "a non-JWT yields nil, not a crash")
        expect(OpenAIAPIClient.accessTokenExpiry("") == nil, "an empty token yields nil")
        expect(OpenAIAPIClient.accessTokenExpiry("\(b64url("{}")).\(b64url("{\"sub\":\"x\"}")).sig") == nil,
               "a JWT without exp yields nil")

        // Expiry drives proactive renewal, and an Anthropic credential (no
        // stated expiry) must never report as expiring.
        let expiring = ProviderCredentials(accessToken: "x", refreshToken: "rt",
                                           expiresAt: Date().addingTimeInterval(600))
        expect(expiring.isExpiring(within: 3600), "a token expiring in 10 min is expiring")
        expect(expiring.isRefreshable, "a stored refresh token makes it refreshable")
        let anthropic = ProviderCredentials(accessToken: "sk-ant-oat01-x")
        expect(!anthropic.isExpiring(within: 3600), "no stated expiry never reports as expiring")
        expect(!anthropic.isRefreshable, "no refresh token means not refreshable")

        // OAuth error bodies surface only their machine-readable code. Both the
        // flat RFC 6749 form and the nested form `auth.openai.com` actually
        // returns (verified live with a deliberately-invalid refresh token)
        // are handled.
        expectEqual(OpenAIAPIClient.oauthErrorCode(Data("{\"error\":\"invalid_grant\"}".utf8)),
                    "invalid_grant", "flat OAuth error code is extracted")
        expectEqual(
            OpenAIAPIClient.oauthErrorCode(Data("""
            {"error":{"message":"Invalid refresh token.","type":"invalid_request_error",
                      "param":null,"code":"invalid_refresh_token"}}
            """.utf8)),
            "invalid_refresh_token",
            "the nested error shape auth.openai.com returns is extracted"
        )
        expect(OpenAIAPIClient.oauthErrorCode(Data("not json".utf8)) == nil,
               "a non-JSON error body yields nil")
    }

    /// Codex CLI's `auth.json`, parsed from an explicit scratch path — never a
    /// `$HOME`-relative default, which `homeDirectoryForCurrentUser` would
    /// resolve to the real credential store regardless of a `HOME` override
    /// (issue #16).
    private static func testCodexAuthParsing() {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("claude-monitor-selftest-codex-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let authPath = dir.appendingPathComponent("auth.json").path

            let fakeAccess = "\(b64url("{\"alg\":\"none\"}")).\(b64url("{\"exp\":1785967226}")).sig"
            let fixture = """
            {"OPENAI_API_KEY": null,
             "tokens": {"id_token": "fixture-id", "access_token": "\(fakeAccess)",
                        "refresh_token": "rt.fixture", "account_id": "acct-fixture"},
             "last_refresh": "2026-07-30T00:00:00Z"}
            """
            try Data(fixture.utf8).write(to: URL(fileURLWithPath: authPath))

            let credential = try CodexAuth.load(path: authPath)
            expectEqual(credential.accessToken, fakeAccess, "access_token read from tokens{}")
            expectEqual(credential.refreshToken, "rt.fixture", "refresh_token read from tokens{}")
            expectEqual(credential.accountId, "acct-fixture", "account_id read from tokens{}")
            expectEqual(credential.expiresAt, Date(timeIntervalSince1970: 1785967226),
                        "expiry derived from the access token's exp claim")

            // A file that isn't a Codex credential fails cleanly.
            let bogusPath = dir.appendingPathComponent("bogus.json").path
            try Data("{\"hello\":\"world\"}".utf8).write(to: URL(fileURLWithPath: bogusPath))
            var threw = false
            do { _ = try CodexAuth.load(path: bogusPath) } catch { threw = true }
            expect(threw, "a file with no tokens{} object is rejected")

            // A missing file reports the path rather than crashing.
            threw = false
            do {
                _ = try CodexAuth.load(path: dir.appendingPathComponent("absent.json").path)
            } catch { threw = true }
            expect(threw, "a missing auth.json is an error, not a crash")

            // $CODEX_HOME resolution is pure string work — assert the shape
            // without mutating this process's environment.
            expect(CodexAuth.defaultAuthPath.hasSuffix("auth.json"),
                   "default Codex credential path ends in auth.json")
        } catch {
            checks += 1
            failures.append("Codex auth parsing test threw: \(error)")
        }
    }

    // MARK: - Codex app-server (JSON-RPC over stdio)

    /// `account/rateLimits/read`'s `result` payload, captured from
    /// `codex-cli 0.147.0` on 2026-08-15 with every usage figure and reset
    /// instant replaced by fixture values. Shape is verbatim, including the
    /// keys this client does not read (`individualLimit`,
    /// `rateLimitReachedType`) so a decoder that got stricter would fail here.
    private static let codexRateLimitsFixture = """
    {"rateLimits":{"limitId":"codex","limitName":null,
       "primary":{"usedPercent":37,"windowDurationMins":10080,"resetsAt":1785967226},
       "secondary":null,
       "credits":{"hasCredits":false,"unlimited":false,"balance":"0"},
       "individualLimit":null,"spendControlReached":false,"planType":"pro",
       "rateLimitReachedType":null},
     "rateLimitsByLimitId":{
       "codex":{"limitId":"codex","limitName":null,
         "primary":{"usedPercent":37,"windowDurationMins":10080,"resetsAt":1785967226},
         "secondary":null,
         "credits":{"hasCredits":false,"unlimited":false,"balance":"0"},
         "individualLimit":null,"spendControlReached":false,"planType":"pro",
         "rateLimitReachedType":null},
       "codex_bengalfox":{"limitId":"codex_bengalfox","limitName":"GPT-5.3-Codex-Spark",
         "primary":{"usedPercent":62,"windowDurationMins":10080,"resetsAt":1785967226},
         "secondary":null,"credits":null,"individualLimit":null,
         "spendControlReached":null,"planType":"pro","rateLimitReachedType":null}},
     "rateLimitResetCredits":{"availableCount":0,"credits":[]}}
    """

    /// `account/read`'s `result` payload, same capture. The email is a fixture
    /// value and must never reach the archive — that assertion is the point of
    /// `testCodexAppServerRedaction`.
    private static let codexAccountFixture = """
    {"account":{"type":"chatgpt","email":"fixture@example.com","planType":"pro"},
     "requiresOpenaiAuth":true}
    """

    /// The transport is newline-delimited JSON, not `Content-Length`-framed, and
    /// a pipe read boundary lands wherever the kernel puts it. Drive the framer
    /// with the awkward chunkings explicitly.
    private static func testCodexAppServerFraming() {
        var framer = CodexLineFramer()

        // A single object split mid-line across two reads.
        expectEqual(framer.append(Data("{\"id\":1,\"resu".utf8)).count, 0,
                    "a partial line yields nothing until its newline arrives")
        let completed = framer.append(Data("lt\":{}}\n".utf8))
        expectEqual(completed.count, 1, "the line completes on the chunk carrying its newline")
        expectEqual(String(data: completed.first ?? Data(), encoding: .utf8),
                    "{\"id\":1,\"result\":{}}", "the reassembled line is byte-exact")

        // Two whole objects plus a partial third, all in one read.
        let batch = framer.append(Data("{\"id\":2}\n{\"id\":3}\n{\"id\":4".utf8))
        expectEqual(batch.count, 2, "one chunk can complete several lines")
        expectEqual(String(data: batch.last ?? Data(), encoding: .utf8), "{\"id\":3}",
                    "lines come back in arrival order")
        expectEqual(framer.append(Data("}\n".utf8)).count, 1, "the held-back partial completes later")

        // Blank lines are noise, not empty replies.
        expectEqual(framer.append(Data("\n\n".utf8)).count, 0, "blank lines are dropped")

        // A child that never emits a newline must not grow the buffer forever.
        var overflowing = CodexLineFramer()
        let megabyte = Data(repeating: 0x41, count: 1024 * 1024)
        for _ in 0..<5 { _ = overflowing.append(megabyte) }
        expect(overflowing.overflowed, "an unterminated line past the cap trips the overflow guard")
        expectEqual(overflowing.append(Data("{\"id\":9}\n".utf8)).count, 0,
                    "an overflowed framer stops accumulating rather than lying")
    }

    /// Two verified wire quirks a textbook JSON-RPC decoder gets wrong: replies
    /// carry **no `jsonrpc` member**, and server notifications carry **no `id`**.
    /// Plus the error classification, where `-32600` is deliberately *not* an
    /// account failure.
    private static func testCodexAppServerEnvelopeDecoding() {
        func envelope(_ json: String) -> CodexRPCEnvelope? {
            try? JSONDecoder().decode(CodexRPCEnvelope.self, from: Data(json.utf8))
        }

        // Verbatim initialize reply shape (0.147.0) — note the absent `jsonrpc`.
        let reply = envelope("""
        {"id":1,"result":{"userAgent":"codex_cli_rs/0.147.0","codexHome":"/x",
         "platformFamily":"unix","platformOs":"macos"}}
        """)
        expectEqual(reply?.id, 1, "a reply with no jsonrpc member still decodes")
        expect(reply?.error == nil, "a successful reply carries no error")

        // Verbatim notification shape — no id, so it is not anybody's reply.
        let notification = envelope("""
        {"method":"remoteControl/status/changed","params":{"status":"disabled"},"emittedAtMs":1}
        """)
        expect(notification != nil, "an id-less notification decodes rather than failing the poll")
        expect(notification?.id == nil, "a notification has no id and must never match a request")

        let rpcError = envelope("{\"error\":{\"code\":-32600,\"message\":\"Invalid request\"},\"id\":3}")
        expectEqual(rpcError?.id, 3, "an error reply is matched by id like any other")
        expectEqual(rpcError?.error?.code, -32600, "the error code decodes")

        // -32600 is what codex 0.46.0 returns for an unsupported method *and*
        // for a bogus one — a capability gap, never an unhealthy account.
        for code in [-32600, -32601] {
            let classified = CodexAppServerClient.classify(
                CodexRPCEnvelope.RPCError(code: code, message: "Invalid request"),
                method: "account/rateLimits/read"
            )
            guard case .methodUnsupported = classified else {
                checks += 1
                failures.append("code \(code) must classify as methodUnsupported, got \(classified)")
                continue
            }
            expect(classified.isCapabilityGap,
                   "\(code) is a capability gap — fall back, do not mark the account unhealthy")
        }

        let unexpected = CodexAppServerClient.classify(
            CodexRPCEnvelope.RPCError(code: -32000, message: "boom"), method: "account/read"
        )
        expect(!unexpected.isCapabilityGap, "an unrecognized RPC error is a real failure, not a gap")

        // Status mapping for the degradations the poller has to distinguish.
        expectEqual(CodexAppServerError.notLoggedIn("/x").tokenStatus, .missing,
                    "a home with no login is 'missing', not 'error'")
        expect(!CodexAppServerError.notLoggedIn("/x").isCapabilityGap,
               "not-logged-in is actionable, so it survives to the status line")
        expectEqual(CodexAppServerError.timedOut("account/read").tokenStatus, .error,
                    "an RPC timeout is an error state")
        expect(CodexAppServerError.binaryNotFound.isCapabilityGap,
               "a missing codex binary is a capability gap")
        expect(CodexAppServerError.binaryNotFound.errorDescription?
                .contains("CLAUDE_MONITOR_CODEX_BIN") == true,
               "the not-found message names the override that fixes it")
    }

    /// The resolved-binary version diagnostic (issue #115): the `initialize`
    /// reply's `result.userAgent` is read back — no separate `codex --version`
    /// subprocess — and the dedup cache logs a given (path, version) pair only
    /// once, not on every poll.
    private static func testCodexVersionDiagnosticLogging() {
        // Verbatim initialize result payloads (verified 0.46.0 and 0.147.0 —
        // see docs/spikes/2026-07-30-codex-usage-probe.md).
        expectEqual(
            codexVersionFromInitializeResult(Data("""
            {"userAgent":"codex_cli_rs/0.46.0"}
            """.utf8)),
            "codex_cli_rs/0.46.0",
            "the stale-formula version decodes from a minimal 0.46.0-shaped reply"
        )
        expectEqual(
            codexVersionFromInitializeResult(Data("""
            {"userAgent":"codex_cli_rs/0.147.0","codexHome":"/x",
             "platformFamily":"unix","platformOs":"macos"}
            """.utf8)),
            "codex_cli_rs/0.147.0",
            "the current version decodes from the fuller 0.147.0-shaped reply, ignoring extra fields"
        )
        expect(
            codexVersionFromInitializeResult(Data("{}".utf8)) == nil,
            "a reply with no userAgent yields nil rather than a fabricated version"
        )
        expect(
            codexVersionFromInitializeResult(Data("not json".utf8)) == nil,
            "an undecodable payload yields nil rather than crashing the handshake"
        )

        // Dedup: log once per distinct (path, version) key, not every poll —
        // a scratch instance, not `.shared`, so this doesn't interact with any
        // other test or a real poll cycle.
        let log = CodexBinaryVersionLog()
        expect(log.shouldLog("~/.local/bin/codex|codex_cli_rs/0.147.0"),
               "the first sighting of a path+version pair logs")
        expect(!log.shouldLog("~/.local/bin/codex|codex_cli_rs/0.147.0"),
               "an unchanged path+version pair does not log again — this is what keeps it to once per poll cycle, not once per line")
        expect(log.shouldLog("~/.local/bin/codex|codex_cli_rs/0.46.0"),
               "a version change at the same path logs again — e.g. a Homebrew formula→cask swap")
        expect(log.shouldLog("~/.npm-global/bin/codex|codex_cli_rs/0.147.0"),
               "a path change logs again even with the same version")
    }

    /// Fixture → `RateLimitSnapshot`. The load-bearing assertion is the unit
    /// conversion: `windowDurationMins` is **minutes** while the shared model
    /// takes **seconds**, and getting it wrong reclassifies a weekly window as
    /// `.other(10080)` while every other check still passes.
    private static func testCodexAppServerMapping() {
        do {
            let snapshot = try CodexAppServerClient.snapshot(
                accountResult: Data(codexAccountFixture.utf8),
                rateLimitsResult: Data(codexRateLimitsFixture.utf8)
            )

            expectEqual(snapshot.provider, .openai, "app-server readings are still the openai provider")
            expectEqual(snapshot.accountKey, "",
                        "account/read carries no account id — the caller keeps the stored one")
            expectEqual(snapshot.email, "fixture@example.com", "identity comes from account/read")
            expectEqual(snapshot.plan, "pro", "planType comes from account/read")

            let windows = snapshot.rateLimit
            expectEqual(windows.weekly?.usedPercent, 37, "primary usedPercent")
            expectEqual(windows.weekly?.durationSeconds, 604800,
                        "windowDurationMins is MINUTES — 10080 min must become 604800 s")
            expectEqual(windows.weekly?.kind, .weekly,
                        "10080 minutes files as weekly, not .other(10080)")
            expectEqual(windows.weekly?.resetAt, Date(timeIntervalSince1970: 1785967226),
                        "resetsAt is unix epoch seconds")
            expect(windows.session == nil,
                   "a null secondary leaves session nil (stored NULL), never a fabricated 0%")
            expectEqual(windows.overallStatus, "allowed", "an unspent account is 'allowed'")
            expectEqual(windows.headroomScore, 63, "headroom from a weekly-only reading")

            // Per-model sub-limits, keyed by limitName; the entry duplicating
            // the top-level limitId is skipped rather than double-counted.
            expectEqual(windows.named["GPT-5.3-Codex-Spark"]?.usedPercent, 62,
                        "rateLimitsByLimitId lands in the named sub-limit map")
            expect(windows.named["codex"] == nil,
                   "the entry duplicating the top-level limitId is not repeated as a sub-limit")

            // A session-length secondary window classifies by its duration.
            let withSession = codexRateLimitsFixture.replacingOccurrences(
                of: "\"secondary\":null",
                with: "\"secondary\":{\"usedPercent\":80,\"windowDurationMins\":300,\"resetsAt\":1785900000}"
            )
            let paired = try CodexAppServerClient.snapshot(
                accountResult: nil, rateLimitsResult: Data(withSession.utf8)
            )
            expectEqual(paired.rateLimit.session?.durationSeconds, 18000,
                        "a 300-minute window is 18000 s")
            expectEqual(paired.rateLimit.session?.kind, .session,
                        "18000 s is under sessionUpperBound, so it files as session")
            expectEqual(paired.rateLimit.weekly?.usedPercent, 37, "the weekly window stays weekly")
            expectEqual(paired.rateLimit.headroomScore, 20, "headroom uses the most-consumed window")
            expect(paired.email == nil, "a skipped account/read simply yields no identity")

            // Spend control is a hard stop even while the windows look healthy.
            let capped = codexRateLimitsFixture.replacingOccurrences(
                of: "\"spendControlReached\":false", with: "\"spendControlReached\":true"
            )
            let cappedSnapshot = try CodexAppServerClient.snapshot(
                accountResult: nil, rateLimitsResult: Data(capped.utf8)
            )
            expectEqual(cappedSnapshot.rateLimit.overallStatus, "rejected",
                        "spendControlReached maps to the shared 'rejected' status")
            expect(cappedSnapshot.rateLimit.weekly?.isExhausted == true,
                   "a rejected window reads as exhausted regardless of percent")

            // A window at the cap is also 'rejected'.
            let spent = codexRateLimitsFixture.replacingOccurrences(
                of: "\"usedPercent\":37", with: "\"usedPercent\":100"
            )
            expectEqual(
                try CodexAppServerClient.snapshot(
                    accountResult: nil, rateLimitsResult: Data(spent.utf8)
                ).rateLimit.overallStatus,
                "rejected", "a window at 100% is 'rejected'"
            )

            // Defensive: a provider that switched to milliseconds must not yield
            // a year-56000 date.
            let millis = codexRateLimitsFixture.replacingOccurrences(
                of: "\"resetsAt\":1785967226", with: "\"resetsAt\":1785967226000"
            )
            expectEqual(
                try CodexAppServerClient.snapshot(
                    accountResult: nil, rateLimitsResult: Data(millis.utf8)
                ).rateLimit.weekly?.resetAt,
                Date(timeIntervalSince1970: 1785967226),
                "a millisecond resetsAt is detected rather than producing a far-future date"
            )

            // A reply with no windows at all is a failure, not a 0% reading.
            var threw = false
            do {
                _ = try CodexAppServerClient.snapshot(
                    accountResult: nil,
                    rateLimitsResult: Data("{\"rateLimits\":{\"limitId\":\"codex\"}}".utf8)
                )
            } catch { threw = true }
            expect(threw, "a reply with no windows must throw, never write a fabricated 0%")

            threw = false
            do {
                _ = try CodexAppServerClient.snapshot(
                    accountResult: nil, rateLimitsResult: Data("not json".utf8)
                )
            } catch { threw = true }
            expect(threw, "an undecodable payload throws rather than crashing the poll")
        } catch {
            checks += 1
            failures.append("codex app-server mapping threw: \(error)")
        }
    }

    /// `account/read` volunteers an email. It must reach `accounts.email` (the
    /// documented join key) and **never** the verbatim `usage_history.raw_data`
    /// archive, which is dumped into logs far more freely — the same discipline
    /// `testOpenAIRawFieldRedaction` enforces for the `wham` path, via the same
    /// redactor rather than a second shallower one.
    private static func testCodexAppServerRedaction() {
        do {
            let snapshot = try CodexAppServerClient.snapshot(
                accountResult: Data(codexAccountFixture.utf8),
                rateLimitsResult: Data(codexRateLimitsFixture.utf8)
            )
            let serialized = snapshot.rawFields.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")

            expect(!serialized.contains("fixture@example.com"),
                   "the email account/read returns must never reach the archive")
            expectEqual(snapshot.rawFields["account.account.email"], "[redacted]",
                        "the redactor records the email's path as present but elided")
            expectEqual(snapshot.email, "fixture@example.com",
                        "the email still reaches accounts.email, the documented join key")

            // Non-PII wire fields are archived verbatim, so a field Codex adds
            // later is captured before this app interprets it.
            expectEqual(snapshot.rawFields["rate_limits.rateLimits.primary.windowDurationMins"],
                        "10080", "the raw wire unit is archived unconverted")
            expectEqual(snapshot.rawFields["rate_limits.rateLimits.limitId"], "codex",
                        "limitId is not PII and is archived")
            expectEqual(snapshot.rawFields["rate_limits.rateLimitsByLimitId.codex_bengalfox.limitName"],
                        "GPT-5.3-Codex-Spark", "sub-limit names survive redaction")
            expectEqual(snapshot.rawFields["transport"], "codex-app-server",
                        "the archive records which transport produced the row")
            expectEqual(snapshot.rawFields["overall_status"], "allowed",
                        "normalized status keys are archived for RankingExporter")
        } catch {
            checks += 1
            failures.append("codex app-server redaction test threw: \(error)")
        }
    }

    /// Regression for #116: `flog.info` used to live inside `snapshot()`
    /// itself, which runs during **offline** fixture decoding (this very
    /// selftest) as much as during a live poll — so a plain `ClaudeMonitor
    /// selftest` run wrote ~14 lines into the user's real `debug.log`. The fix
    /// moved the log call into `fetchUsage()` (the caller that actually
    /// performed a live poll), leaving `snapshot()` free of I/O.
    ///
    /// `FileLogger` writes on its own serial background queue, so a plain
    /// before/after size check right after calling `snapshot()` would race
    /// the write. `FileLogger.sync()` flushes that queue deterministically —
    /// since it is FIFO, waiting on it proves anything `snapshot()` might
    /// have enqueued has already landed (or, per this fix, was never
    /// enqueued) — without padding the user's real `debug.log` with a marker
    /// line just to observe it.
    private static func testCodexSnapshotOfflinePathWritesNoLog() {
        let logPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude-monitor/debug.log").path
        FileLogger.shared.sync()
        let before = FileManager.default.contents(atPath: logPath)?.count ?? 0

        // Exercise the offline mapper exactly the way `testCodexAppServerMapping`
        // / `testCodexAppServerRedaction` do — this is the path selftest drives,
        // with no network, no credentials, and (per this fix) no live poll.
        _ = try? CodexAppServerClient.snapshot(
            accountResult: Data(codexAccountFixture.utf8),
            rateLimitsResult: Data(codexRateLimitsFixture.utf8)
        )

        FileLogger.shared.sync()
        let after = FileManager.default.contents(atPath: logPath)?.count ?? 0

        expectEqual(after, before,
                    "snapshot() must stay free of I/O — the offline selftest path must never write to debug.log")
    }

    /// A Finder-launched `.app` inherits launchd's minimal `PATH`, so
    /// `/usr/bin/env codex` resolves during development and fails in the bundle.
    /// Resolution therefore walks an explicit candidate list and returns an
    /// absolute path — asserted here against a scratch directory rather than
    /// whatever happens to be installed on the build host.
    private static func testCodexBinaryResolution() {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("claude-monitor-selftest-bin-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let stub = dir.appendingPathComponent("codex").path
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: URL(fileURLWithPath: stub))
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub)

            expectEqual(CodexBinary.resolve(environment: ["PATH": dir.path]), stub,
                        "a PATH entry resolves to an absolute codex path")

            let nonExecutable = dir.appendingPathComponent("nested").path
            try FileManager.default.createDirectory(atPath: nonExecutable, withIntermediateDirectories: true)
            let plain = (nonExecutable as NSString).appendingPathComponent("codex")
            try Data("not executable".utf8).write(to: URL(fileURLWithPath: plain))
            // Not `== nil`: the absolute fallback list is also probed, and this
            // build host may genuinely have codex installed. The assertion that
            // matters is that the non-executable file is never chosen.
            expect(CodexBinary.resolve(environment: ["PATH": nonExecutable]) != plain,
                   "a present-but-not-executable codex is not a usable candidate")

            expectEqual(
                CodexBinary.resolve(environment: [CodexBinary.overrideEnvKey: stub, "PATH": "/nowhere"]),
                stub, "CLAUDE_MONITOR_CODEX_BIN wins over PATH"
            )
            expect(
                CodexBinary.resolve(environment: [
                    CodexBinary.overrideEnvKey: dir.appendingPathComponent("absent").path,
                    "PATH": dir.path,
                ]) == nil,
                "an override that does not resolve fails loudly rather than silently using PATH"
            )
        } catch {
            checks += 1
            failures.append("codex binary resolution test threw: \(error)")
        }
    }

    /// Both new tiers read whichever `CODEX_HOME` this process inherited, and
    /// that one home speaks for exactly one account. On a two-OpenAI-account
    /// host, attributing its reading to both would overwrite one account's usage
    /// with a stranger's — plausible-looking numbers, silently wrong. The guard
    /// is deliberately asymmetric: only a *contradiction* disqualifies a tier,
    /// so the ordinary single-account host (where identity may be absent on
    /// either side) keeps using the preferred transport.
    private static func testCodexHomeIdentityGuard() {
        expect(OAuthPoller.identitiesConflict("a@example.com", "b@example.com"),
               "two known, different identities conflict — do not attribute the reading")
        expect(!OAuthPoller.identitiesConflict("a@example.com", "A@Example.com "),
               "identity comparison is case- and whitespace-insensitive")
        expect(!OAuthPoller.identitiesConflict(nil, "a@example.com"),
               "an unknown reported identity proves nothing and must not block the tier")
        expect(!OAuthPoller.identitiesConflict("a@example.com", nil),
               "an account row with no email proves nothing either")
        expect(!OAuthPoller.identitiesConflict("", "a@example.com"),
               "an empty string is absent identity, not a conflicting one")
        expect(!OAuthPoller.identitiesConflict(nil, nil),
               "the single-account case, where neither side carries identity, still uses tier 1")
        expect(OAuthPoller.identitiesConflict("user-aaa", "user-bbb"),
               "the same rule guards tier 2, where auth.json carries an account id")
    }

    /// Which `CODEX_HOME` may speak for one account — the decision that makes
    /// correct attribution structural instead of something detected afterwards.
    ///
    /// **This is where the NULL-email hole the #111 Judge recorded is closed.**
    /// The old guard compared emails, so an OpenAI row with `email IS NULL`
    /// could still be handed the ambient home's numbers on a two-account host.
    /// Resolution needs no identity on either side: it counts candidate
    /// accounts, so the NULL-email row is exactly as protected as any other.
    private static func testCodexHomeResolution() {
        typealias Resolution = OAuthPoller.CodexHomeResolution

        // A registered home is always its own account's, however many siblings
        // exist — that is the whole point of registering it.
        expectEqual(OAuthPoller.resolveCodexHome(registered: "/tmp/codex-a", openAIAccountCount: 1),
                    Resolution.explicit("/tmp/codex-a"),
                    "a registered home is used verbatim")
        expectEqual(OAuthPoller.resolveCodexHome(registered: "/tmp/codex-a", openAIAccountCount: 4),
                    Resolution.explicit("/tmp/codex-a"),
                    "siblings do not make a registered home ambiguous")
        expectEqual(OAuthPoller.resolveCodexHome(registered: "  /tmp/codex-b  ", openAIAccountCount: 2),
                    Resolution.explicit("/tmp/codex-b"),
                    "a registered home is trimmed before use")

        // No registered home: safe only while nothing else could own the
        // ambient one. This preserves today's single-account behaviour exactly.
        expectEqual(OAuthPoller.resolveCodexHome(registered: nil, openAIAccountCount: 1),
                    Resolution.ambient,
                    "the only OpenAI account on the host may read the ambient home")
        expectEqual(OAuthPoller.resolveCodexHome(registered: nil, openAIAccountCount: 0),
                    Resolution.ambient,
                    "a freshly imported account with no siblings still reads the ambient home")
        expectEqual(OAuthPoller.resolveCodexHome(registered: "", openAIAccountCount: 1),
                    Resolution.ambient,
                    "an empty codex_home is absent, not a path")

        // THE NULL-EMAIL CASE (#111 Judge). Nothing in this call carries an
        // email, and the result is still "no home may speak for this account".
        expectEqual(OAuthPoller.resolveCodexHome(registered: nil, openAIAccountCount: 2),
                    Resolution.ambiguous,
                    "a second OpenAI account makes the ambient home unattributable — with or without an email")
        expect(!Resolution.ambiguous.allowsHomeRead,
               "an ambiguous home disqualifies BOTH home-reading tiers, not just tier 1")
        expect(Resolution.ambient.allowsHomeRead && Resolution.ambient.readableHome == nil,
               "the ambient case reads with no explicit home — the client's own default")
        expectEqual(Resolution.explicit("/tmp/codex-a").readableHome, "/tmp/codex-a",
                    "an explicit home is what the client is constructed with")

        // A home path names a user, so it must never reach a log line or a
        // persisted error string verbatim.
        expectEqual(redactHomePath(NSHomeDirectory() + "/.codex-work"), "~/.codex-work",
                    "this user's home directory collapses to ~")
        expectEqual(redactHomePath(NSHomeDirectory()), "~", "the bare home directory collapses to ~")
        expectEqual(redactHomePath("/Users/someoneelse/.codex"), "~/.codex",
                    "another macOS user's name is redacted too")
        expectEqual(redactHomePath("/home/someoneelse/.codex-b"), "~/.codex-b",
                    "another Linux user's name is redacted too")
        expectEqual(redactHomePath("/opt/shared/codex"), "/opt/shared/codex",
                    "a path outside any home directory is left legible")
        let notLoggedIn = CodexAppServerError.notLoggedIn(NSHomeDirectory() + "/.codex-work")
        expect(!(notLoggedIn.localizedDescription).contains(NSHomeDirectory()),
               "the needs-login message — which is logged AND stored as last_error — carries no raw home path")

        // A persistent "needs login" must log once, not once per poll, so the
        // dedupe key discriminates the *kind* and never the payload path.
        expectEqual(OAuthPoller.failureKind(.notLoggedIn("/tmp/a")),
                    OAuthPoller.failureKind(.notLoggedIn("/tmp/b")),
                    "the log-dedupe key is the failure kind, never the home path")
        expect(OAuthPoller.failureKind(.notLoggedIn("/tmp/a")) != OAuthPoller.failureKind(.homeMissing("/tmp/a")),
               "a change of state still logs — needs-login and home-missing are different kinds")
        expect(!CodexAppServerError.homeMissing("/tmp/a").isCapabilityGap,
               "a vanished home is this account's problem, not an absent transport — it must not fall through silently")
        expectEqual(CodexAppServerError.notLoggedIn("/tmp/a").tokenStatus, TokenStatus.missing,
                    "needs login surfaces as .missing, distinct from a request failure")
        expectEqual(CodexAppServerError.homeMissing("/tmp/a").tokenStatus, TokenStatus.error,
                    "a vanished home surfaces as .error, distinct from needs login")
    }

    /// **The load-bearing enumeration check.** `loadActiveCredentials` is the
    /// only enumeration `pollAll` / `pollDue` use, and it filtered
    /// `access_token IS NOT NULL`. An account registered by home alone — which
    /// "registering never stores a token" requires — would otherwise register
    /// fine, list fine, and then never poll.
    ///
    /// Also pins the non-leak invariants for the new column against the two
    /// files this issue deliberately does not edit: an `accounts export` bundle
    /// must not carry the home, and `ranking.json` must not publish it.
    private static func testCodexHomeRegistrationEnumeration() {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("claude-monitor-selftest-codexhome-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let dbPath = dir.appendingPathComponent("usage.db").path
            UsageStore(dbPath: dbPath).ensureDatabase()

            let homeA = "/tmp/selftest-codex-home-a"
            let homeB = "/tmp/selftest-codex-home-b"
            let poller = OAuthPoller(dbPath: dbPath)

            poller.saveCodexHomeAccount(
                accountId: "user-aaa", email: "a@example.com", plan: "pro", codexHome: homeA
            )

            var credentials = poller.loadActiveCredentials()
            expectEqual(credentials.count, 1,
                        "a token-free, home-registered account IS enumerated by the poll loop")
            expectEqual(credentials.first?.accessToken, nil,
                        "registration stored no access token")
            expectEqual(credentials.first?.refreshToken, nil,
                        "registration stored no refresh token either")
            expectEqual(credentials.first?.codexHome, homeA,
                        "the account's own home rides along with the credential")
            expectEqual(credentials.first?.provider, AccountProvider.openai,
                        "the registered account is an OpenAI account")
            expectEqual(credentials.first?.source, "codex-home",
                        "the row is tagged as home-registered rather than token-imported")

            // Re-registering must update the row, never mint a sibling (#45).
            poller.saveCodexHomeAccount(
                accountId: "user-aaa", email: "a@example.com", plan: "pro", codexHome: homeB
            )
            let db = try openDatabase(dbPath, readonly: true)
            expectEqual(try db.scalar("SELECT COUNT(*) FROM accounts") as? Int64, 1,
                        "re-registering a home does not create a duplicate account row")
            expectEqual(try db.scalar("SELECT COUNT(*) FROM oauth_credentials") as? Int64, 1,
                        "re-registering a home does not create a duplicate credential row")
            expectEqual(try db.scalar("SELECT codex_home FROM accounts WHERE id = 'user-aaa'") as? String,
                        homeB, "re-registering updates the stored home")

            // A token-free OpenAI row with NO home is not resurrected into the
            // poll set — there is nothing on this host for it to read.
            let now = ISO8601DateFormatter().string(from: Date())
            try openDatabase(dbPath).run("""
                INSERT INTO accounts (id, account_name, email, plan, last_updated, sort_order, provider)
                VALUES ('user-homeless', 'h@example.com', 'h@example.com', 'pro', ?, 9, 'openai')
            """, now)
            try openDatabase(dbPath).run("""
                INSERT INTO oauth_credentials (account_id, label, source, provider, access_token, is_active, created_at, updated_at)
                VALUES ('user-homeless', 'h@example.com', 'codex', 'openai', NULL, 1, ?, ?)
            """, now, now)
            // …while an ordinary stored-token account still enumerates exactly as before.
            try openDatabase(dbPath).run("""
                INSERT INTO accounts (id, account_name, email, plan, last_updated, sort_order, provider)
                VALUES ('org-anthropic', 'x@example.com', 'x@example.com', 'Max', ?, 10, 'anthropic')
            """, now)
            try openDatabase(dbPath).run("""
                INSERT INTO oauth_credentials (account_id, label, source, provider, access_token, is_active, created_at, updated_at)
                VALUES ('org-anthropic', 'x@example.com', 'token', 'anthropic', 'sk-ant-oat01-selftest', 1, ?, ?)
            """, now, now)

            credentials = poller.loadActiveCredentials()
            expectEqual(credentials.count, 2,
                        "a token-free row with no registered home stays out of the poll set")
            expect(credentials.contains { $0.accountId == "org-anthropic" && $0.accessToken != nil },
                   "a stored-token account is enumerated exactly as before")
            expect(credentials.contains { $0.accountId == "user-aaa" },
                   "the home-registered account is still enumerated alongside it")
            expect(credentials.allSatisfy { $0.provider == .anthropic || $0.codexHome != nil || $0.accessToken != nil },
                   "nothing token-free and homeless slipped in")

            // `codex list` sees the registration, token-free and all.
            let listed = poller.codexAccounts()
            expectEqual(listed.count, 2, "codex list shows every OpenAI account, registered or not")
            let registered = listed.first { $0.accountId == "user-aaa" }
            expectEqual(registered?.codexHome, homeB, "codex list reports the registered home")
            expectEqual(registered?.hasStoredToken, false, "codex list reports that no token is stored")
            expectEqual(listed.first { $0.accountId == "user-homeless" }?.codexHome, nil,
                        "an account with no registered home lists as using the ambient default")

            // A home path contains a username: it must stay host-local. Both
            // files below are VERIFY-ONLY in this issue — they already use
            // explicit column lists, and this is what pins that.
            let bundle = try AccountSync.exportBundle(dbPath: dbPath)
            let encoded = String(data: try JSONEncoder().encode(bundle), encoding: .utf8) ?? ""
            expect(!encoded.contains(homeB) && !encoded.contains("codex_home"),
                   "an accounts export bundle carries no codex_home — a home path is meaningless on another host")

            let rankingPath = dir.appendingPathComponent("ranking.json").path
            RankingExporter.exportNow(dbPath: dbPath, outputPath: rankingPath)
            let ranking = String(data: FileManager.default.contents(atPath: rankingPath) ?? Data(),
                                 encoding: .utf8) ?? ""
            expect(!ranking.isEmpty, "ranking.json was written")
            expect(!ranking.contains(homeB) && !ranking.contains("codex_home"),
                   "ranking.json never publishes a home path")
        } catch {
            checks += 1
            failures.append("codex home registration test threw: \(error)")
        }
    }

    /// Spawn / handshake / reap against a **stub** binary, so CI exercises the
    /// subprocess path on macOS and Linux without the real Codex CLI installed.
    ///
    /// The stub ends in `cat > /dev/null`, so it stays alive until this client
    /// closes its stdin — reproducing the verified real behaviour (stdin close
    /// makes `app-server` exit 0 on its own) and letting an `EXIT` trap prove
    /// the child was actually reaped, not orphaned.
    private static func testCodexAppServerSpawnAgainstStub() {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("claude-monitor-selftest-appserver-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

            func writeStub(_ name: String, _ body: String) throws -> String {
                let path = dir.appendingPathComponent(name).path
                try Data(body.utf8).write(to: URL(fileURLWithPath: path))
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
                return path
            }

            let reapedMarker = dir.appendingPathComponent("reaped").path
            let oneLine: (String) -> String = { $0.replacingOccurrences(of: "\n", with: "") }

            // Replies are emitted up front, out of the order they are requested,
            // to prove matching is by `id` and that an early arrival is stashed
            // rather than dropped.
            let goodStub = try writeStub("codex", """
            #!/bin/sh
            trap 'echo reaped > "$MARKER"' EXIT
            echo '{"id":1,"result":{"userAgent":"stub"}}'
            echo '{"method":"remoteControl/status/changed","params":{},"emittedAtMs":1}'
            echo '{"id":3,"result":\(oneLine(codexRateLimitsFixture))}'
            echo '{"id":2,"result":\(oneLine(codexAccountFixture))}'
            cat > /dev/null
            """)

            var timeouts = CodexAppServerClient.Timeouts()
            timeouts.initialize = 10
            timeouts.method = 10
            timeouts.overall = 20

            let client = CodexAppServerClient(
                codexHome: dir.path,
                timeouts: timeouts,
                environment: [
                    CodexBinary.overrideEnvKey: goodStub,
                    "PATH": "/usr/bin:/bin",
                    "MARKER": reapedMarker,
                ]
            )

            switch runBlocking({ try await client.fetchUsage() }) {
            case .success(let snapshot):
                expectEqual(snapshot.rateLimit.weekly?.usedPercent, 37,
                            "a spawned handshake produces the same mapping as the offline fixture")
                expectEqual(snapshot.email, "fixture@example.com",
                            "an out-of-order account/read reply is matched by id, not arrival order")
            case .failure(let error):
                checks += 1
                failures.append("stub app-server handshake failed: \(error)")
            }

            expect(FileManager.default.fileExists(atPath: reapedMarker),
                   "the child exits after its stdin is closed — no orphaned process survives the call")

            // A stub that never replies must time out and still be reaped.
            let silentMarker = dir.appendingPathComponent("silent-reaped").path
            let silentStub = try writeStub("codex-silent", """
            #!/bin/sh
            trap 'echo reaped > "$MARKER"' EXIT
            cat > /dev/null
            """)

            var shortTimeouts = CodexAppServerClient.Timeouts()
            shortTimeouts.initialize = 1
            shortTimeouts.method = 1
            shortTimeouts.overall = 3

            let silentClient = CodexAppServerClient(
                codexHome: dir.path,
                timeouts: shortTimeouts,
                environment: [
                    CodexBinary.overrideEnvKey: silentStub,
                    "PATH": "/usr/bin:/bin",
                    "MARKER": silentMarker,
                ]
            )

            let started = Date()
            switch runBlocking({ try await silentClient.fetchUsage() }) {
            case .success:
                checks += 1
                failures.append("a silent app-server must time out, not appear to succeed")
            case .failure(let error):
                guard let codexError = error as? CodexAppServerError,
                      case .timedOut = codexError else {
                    checks += 1
                    failures.append("a silent app-server must fail with .timedOut, got \(error)")
                    break
                }
                expect(Date().timeIntervalSince(started) < 10,
                       "the timeout is enforced rather than waiting on the child indefinitely")
            }
            expect(FileManager.default.fileExists(atPath: silentMarker),
                   "a timed-out child is still reaped (stdin close → SIGTERM → SIGKILL)")

            // #118 item 2: a reply that doesn't decode as `CodexWire.AccountRead`
            // at all (here, a bare JSON string instead of an object) must be
            // distinguishable from a reply that decodes fine with an explicit
            // `account: null`. Collapsing both into `.notLoggedIn` would misreport
            // a wire/protocol regression as "needs login".
            let malformedStub = try writeStub("codex-malformed-account", """
            #!/bin/sh
            trap 'echo reaped > "$MARKER"' EXIT
            echo '{"id":1,"result":{"userAgent":"stub"}}'
            echo '{"id":2,"result":"not-an-object"}'
            cat > /dev/null
            """)
            let malformedClient = CodexAppServerClient(
                codexHome: dir.path,
                timeouts: timeouts,
                environment: [
                    CodexBinary.overrideEnvKey: malformedStub,
                    "PATH": "/usr/bin:/bin",
                    "MARKER": dir.appendingPathComponent("malformed-reaped").path,
                ]
            )
            switch runBlocking({ try await malformedClient.fetchUsage() }) {
            case .success:
                checks += 1
                failures.append("an undecodable account/read reply must not appear to succeed")
            case .failure(let error):
                guard let codexError = error as? CodexAppServerError, case .protocolFailure = codexError else {
                    checks += 1
                    failures.append("an undecodable account/read reply must fail with .protocolFailure, got \(error)")
                    break
                }
            }

            let nullAccountStub = try writeStub("codex-null-account", """
            #!/bin/sh
            trap 'echo reaped > "$MARKER"' EXIT
            echo '{"id":1,"result":{"userAgent":"stub"}}'
            echo '{"id":2,"result":{"account":null,"requiresOpenaiAuth":true}}'
            cat > /dev/null
            """)
            let nullAccountClient = CodexAppServerClient(
                codexHome: dir.path,
                timeouts: timeouts,
                environment: [
                    CodexBinary.overrideEnvKey: nullAccountStub,
                    "PATH": "/usr/bin:/bin",
                    "MARKER": dir.appendingPathComponent("null-account-reaped").path,
                ]
            )
            switch runBlocking({ try await nullAccountClient.fetchUsage() }) {
            case .success:
                checks += 1
                failures.append("a decoded-but-null account must not appear to succeed")
            case .failure(let error):
                guard let codexError = error as? CodexAppServerError, case .notLoggedIn = codexError else {
                    checks += 1
                    failures.append("a decoded-but-null account must fail with .notLoggedIn, got \(error)")
                    break
                }
            }

            // #118 item 3: a child that ignores SIGTERM must still be walked
            // through the full stdin-close → SIGTERM → SIGKILL ladder rather than
            // hanging — this is what originally caught the `waitUntilExit()`
            // off-main-thread regression, and must keep passing after `reap`
            // switched from a busy `usleep` poll to a suspending `Task.sleep` one.
            let wedgedMarker = dir.appendingPathComponent("wedged-reaped").path
            let wedgedStub = try writeStub("codex-wedged", """
            #!/bin/sh
            trap '' TERM
            trap 'echo reaped > "$MARKER"' EXIT
            while true; do sleep 0.05; done
            """)

            var wedgedTimeouts = CodexAppServerClient.Timeouts()
            wedgedTimeouts.initialize = 1
            wedgedTimeouts.method = 1
            wedgedTimeouts.overall = 1
            wedgedTimeouts.gracefulExit = 0.3
            wedgedTimeouts.terminateGrace = 0.3

            let wedgedClient = CodexAppServerClient(
                codexHome: dir.path,
                timeouts: wedgedTimeouts,
                environment: [
                    CodexBinary.overrideEnvKey: wedgedStub,
                    "PATH": "/usr/bin:/bin",
                    "MARKER": wedgedMarker,
                ]
            )

            let wedgedStarted = Date()
            switch runBlocking({ try await wedgedClient.fetchUsage() }) {
            case .success:
                checks += 1
                failures.append("a wedged app-server must fail, not appear to succeed")
            case .failure(let error):
                guard let codexError = error as? CodexAppServerError, case .timedOut = codexError else {
                    checks += 1
                    failures.append("a wedged app-server must fail with .timedOut, got \(error)")
                    break
                }
            }
            // Bound: overall timeout (1s) plus the escalation ladder
            // (gracefulExit 0.3 + terminateGrace 0.3 + up to 2s final wait) —
            // generously capped well short of a real hang.
            expect(Date().timeIntervalSince(wedgedStarted) < 8,
                   "a SIGTERM-ignoring child is still force-killed and reaped, not hung on indefinitely")

            // `trap ... EXIT` never fires on SIGKILL (it cannot be caught), so
            // the marker file isn't a valid signal here — confirm no process
            // survives via `pgrep` on the stub's own (unique, per-run) path
            // instead. `waitUntilExit()` is safe on this call: `selftest` runs
            // this whole suite synchronously on the main thread, never inside a
            // Swift concurrency pool task — see the note on
            // `CodexAppServerClient.waitForExit` for why that distinction matters.
            let pgrepCheck = Process()
            pgrepCheck.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
            pgrepCheck.arguments = ["-f", wedgedStub]
            let pgrepOutput = Pipe()
            pgrepCheck.standardOutput = pgrepOutput
            pgrepCheck.standardError = FileHandle.nullDevice
            do {
                try pgrepCheck.run()
                pgrepCheck.waitUntilExit()
                let leaked = pgrepOutput.fileHandleForReading.readDataToEndOfFile()
                expect(leaked.isEmpty, "no orphaned wedged child survives the SIGKILL escalation")
            } catch {
                // `pgrep` itself is missing on this host (rare) — not this
                // test's concern; the timeout/elapsed-time assertions above
                // already cover the escalation ladder's correctness.
            }
        } catch {
            checks += 1
            failures.append("codex app-server stub test threw: \(error)")
        }
    }

    /// **The strongest available offline proof of the core behaviour**: a stub
    /// `codex` that echoes its own `$CODEX_HOME` back into a marker file, so
    /// two clients built from two different accounts' homes are shown to reach
    /// the child's environment as two different values — on macOS *and* Linux
    /// CI, with no real Codex CLI installed.
    ///
    /// A resolver unit test alone would not do: the whole failure mode this
    /// issue exists to prevent is one account's home silently reaching the
    /// other account's read.
    private static func testCodexPerAccountHomeReachesChild() {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("claude-monitor-selftest-perhome-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

            func writeStub(_ name: String, _ body: String) throws -> String {
                let path = dir.appendingPathComponent(name).path
                try Data(body.utf8).write(to: URL(fileURLWithPath: path))
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
                return path
            }

            // Two homes that actually exist, as `codex login` would leave them.
            let homeA = dir.appendingPathComponent("codex-home-a").path
            let homeB = dir.appendingPathComponent("codex-home-b").path
            for home in [homeA, homeB] {
                try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
            }

            let oneLine: (String) -> String = { $0.replacingOccurrences(of: "\n", with: "") }
            let echoStub = try writeStub("codex-echo-home", """
            #!/bin/sh
            printf '%s' "$CODEX_HOME" > "$HOME_MARKER"
            echo '{"id":1,"result":{"userAgent":"stub"}}'
            echo '{"id":2,"result":\(oneLine(codexAccountFixture))}'
            echo '{"id":3,"result":\(oneLine(codexRateLimitsFixture))}'
            cat > /dev/null
            """)

            var timeouts = CodexAppServerClient.Timeouts()
            timeouts.initialize = 10
            timeouts.method = 10
            timeouts.overall = 20

            func readBack(home: String, marker: String) -> String? {
                let client = CodexAppServerClient(
                    codexHome: home,
                    timeouts: timeouts,
                    environment: [
                        CodexBinary.overrideEnvKey: echoStub,
                        "PATH": "/usr/bin:/bin",
                        "HOME_MARKER": marker,
                    ]
                )
                switch runBlocking({ try await client.fetchUsage() }) {
                case .success:
                    return (try? String(contentsOfFile: marker, encoding: .utf8))?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                case .failure(let error):
                    checks += 1
                    failures.append("per-account home handshake failed: \(error)")
                    return nil
                }
            }

            let markerA = dir.appendingPathComponent("seen-a").path
            let markerB = dir.appendingPathComponent("seen-b").path
            let seenA = readBack(home: homeA, marker: markerA)
            let seenB = readBack(home: homeB, marker: markerB)

            expectEqual(seenA, homeA,
                        "account A's registered CODEX_HOME is what its child process actually sees")
            expectEqual(seenB, homeB,
                        "account B's registered CODEX_HOME is what its child process actually sees")
            expect(seenA != seenB,
                   "two accounts polled from two homes never share one home — the corruption this issue prevents")

            // A registered home that no longer exists gets its own state, and
            // is decided before anything is spawned.
            let vanished = dir.appendingPathComponent("codex-home-gone").path
            let goneClient = CodexAppServerClient(
                codexHome: vanished,
                timeouts: timeouts,
                environment: [CodexBinary.overrideEnvKey: echoStub, "PATH": "/usr/bin:/bin",
                              "HOME_MARKER": dir.appendingPathComponent("seen-gone").path]
            )
            switch runBlocking({ try await goneClient.fetchUsage() }) {
            case .success:
                checks += 1
                failures.append("a registered home that does not exist must not appear to succeed")
            case .failure(let error):
                guard let codexError = error as? CodexAppServerError, case .homeMissing = codexError else {
                    checks += 1
                    failures.append("a vanished home must fail with .homeMissing, got \(error)")
                    break
                }
                expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("seen-gone").path),
                       "a vanished home is caught before a child is spawned at all")
            }

            // A home that exists but was never logged into: `account: null` is
            // the real signal — `requiresOpenaiAuth` is true even when logged in.
            let loggedOutStub = try writeStub("codex-logged-out", """
            #!/bin/sh
            echo '{"id":1,"result":{"userAgent":"stub"}}'
            echo '{"id":2,"result":{"account":null,"requiresOpenaiAuth":true}}'
            echo '{"id":3,"error":{"code":-32600,"message":"Invalid request"}}'
            cat > /dev/null
            """)
            let loggedOutClient = CodexAppServerClient(
                codexHome: homeA,
                timeouts: timeouts,
                environment: [CodexBinary.overrideEnvKey: loggedOutStub, "PATH": "/usr/bin:/bin"]
            )
            switch runBlocking({ try await loggedOutClient.fetchUsage() }) {
            case .success:
                checks += 1
                failures.append("an unauthenticated home must not appear to succeed")
            case .failure(let error):
                guard let codexError = error as? CodexAppServerError, case .notLoggedIn = codexError else {
                    checks += 1
                    failures.append("an unauthenticated home must surface as .notLoggedIn, got \(error)")
                    break
                }
                expectEqual(codexError.tokenStatus, TokenStatus.missing,
                            "needs login is its own health state, not a request failure")
                expect(!codexError.isCapabilityGap,
                       "needs login is an account state — it must not fall through silently as a capability gap")
            }
        } catch {
            checks += 1
            failures.append("per-account codex home test threw: \(error)")
        }
    }

    /// Carries the result of an `async` call back to this synchronous,
    /// single-threaded test runner.
    ///
    /// `@unchecked Sendable` with a named invariant: the box is written exactly
    /// once by the detached task **before** `signal()` and read exactly once
    /// after `wait()` returns, so the semaphore is the happens-before edge and
    /// no two threads ever touch it concurrently.
    private final class AsyncOutcomeBox: @unchecked Sendable {
        var snapshot: ProviderUsageSnapshot?
        var error: Error?
    }

    private struct SelfTestTimeout: Error, LocalizedError {
        var errorDescription: String? { "the async operation did not finish inside the self-test budget" }
    }

    /// Run an async operation to completion from `main()`'s synchronous thread.
    /// Safe because nothing in the operation needs the main actor; the bounded
    /// wait means a hung subprocess fails the self-test instead of hanging CI.
    private static func runBlocking(
        _ operation: @escaping @Sendable () async throws -> ProviderUsageSnapshot
    ) -> Result<ProviderUsageSnapshot, Error> {
        let box = AsyncOutcomeBox()
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            do { box.snapshot = try await operation() } catch { box.error = error }
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + 60) == .success else {
            return .failure(SelfTestTimeout())
        }
        if let snapshot = box.snapshot { return .success(snapshot) }
        return .failure(box.error ?? SelfTestTimeout())
    }

    // MARK: - Named limits (per-model sub-limits, #32)

    /// Decodes a fixture carrying `additional_rate_limits[]`, writes the
    /// resulting `named` map into a throwaway database via
    /// `UsageStore.insertNamedLimits` (the same helper `OAuthPoller` calls on
    /// every poll), then reads it back via `loadNamedLimitHistory` and
    /// confirms `limit_name` / `used_percent` survive the round trip.
    private static func testNamedLimitsRoundTrip() {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("claude-monitor-selftest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let dbPath = dir.appendingPathComponent("usage.db").path

            let store = UsageStore(dbPath: dbPath)
            store.ensureDatabase()

            let snapshot = try OpenAIAPIClient.snapshot(
                from: Data(openAIUsageFixture.utf8), httpStatus: 200
            )
            let named = snapshot.rateLimit.named
            expect(!named.isEmpty, "fixture must decode at least one named sub-limit")

            let db = try openDatabase(dbPath)
            let now = ISO8601DateFormatter().string(from: Date())
            UsageStore.insertNamedLimits(db, accountId: "acct-fixture", timestamp: now, named: named)

            let history = store.loadNamedLimitHistory(for: "acct-fixture")
            expectEqual(history.count, 1, "one series per distinct limit_name")
            let series = history["GPT-5.3-Codex-Spark"]
            expect(series != nil, "the fixture's limit_name is preserved verbatim as the series key")
            expectEqual(series?.first?.usedPercent, 62,
                        "used_percent round-trips through named_limits")

            // An account with no named limits at all must read back empty —
            // this is what lets the chart overlay stay hidden for every
            // Anthropic account.
            let emptyHistory = store.loadNamedLimitHistory(for: "acct-with-no-named-limits")
            expect(emptyHistory.isEmpty, "an account with zero named_limits rows reads back an empty dictionary")

            // Anthropic's ping response never populates `named` — confirm the
            // write path is a true no-op for it, not merely untested.
            UsageStore.insertNamedLimits(db, accountId: "acct-anthropic", timestamp: now, named: [:])
            let anthropicCount = try db.scalar(
                "SELECT COUNT(*) FROM named_limits WHERE account_id = 'acct-anthropic'"
            ) as? Int64
            expectEqual(anthropicCount, 0, "an empty named map writes zero named_limits rows")
        } catch {
            checks += 1
            failures.append("named limits round-trip test threw: \(error)")
        }
    }

    // MARK: - OpenAI import account resolution

    /// A fresh `codex import` must land on the account row that already tracks
    /// the same email, not create a sibling keyed by OpenAI's native id —
    /// rows created before the native-id era carry a locally generated UUID.
    private static func testOpenAIImportResolvesExistingAccountByEmail() {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("claude-monitor-selftest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let dbPath = dir.appendingPathComponent("usage.db").path

            let store = UsageStore(dbPath: dbPath)
            store.ensureDatabase()
            let db = try openDatabase(dbPath)

            try db.run("""
                INSERT INTO accounts (id, account_name, email, plan, last_updated, provider)
                VALUES ('legacy-uuid-row', 'me@example.com', 'me@example.com', 'pro',
                        '2026-01-01T00:00:00Z', 'openai')
            """)
            try db.run("""
                INSERT INTO accounts (id, account_name, email, plan, last_updated, provider)
                VALUES ('anthropic-row', 'me@example.com', 'me@example.com', 'Max',
                        '2026-01-01T00:00:00Z', 'anthropic')
            """)

            expectEqual(
                OAuthPoller.resolveOpenAIAccountId(
                    email: "me@example.com", nativeId: "user-native", db: db),
                "legacy-uuid-row",
                "an existing openai row with the same email wins over the native id")
            expectEqual(
                OAuthPoller.resolveOpenAIAccountId(
                    email: "someone-else@example.com", nativeId: "user-native", db: db),
                "user-native",
                "an unknown email falls through to the native id")
            expectEqual(
                OAuthPoller.resolveOpenAIAccountId(
                    email: nil, nativeId: "user-native", db: db),
                "user-native",
                "a missing email falls through to the native id")

            // The anthropic row shares the email; matching is provider-scoped
            // so a Claude and a ChatGPT account under one address never merge.
            expect(
                OAuthPoller.resolveOpenAIAccountId(
                    email: "me@example.com", nativeId: "user-native", db: db) != "anthropic-row",
                "resolution never lands on an anthropic row")
        } catch {
            checks += 1
            failures.append("openai import account resolution test threw: \(error)")
        }
    }

    // MARK: - Copy/Paste accounts export/import round trip (#67)

    /// `exportAccountsEnv()` reports its own count so `copyAccounts()` can
    /// build an accurate "Copied N accounts" message instead of over-reporting
    /// with `store.accounts.count` (issue #63). As of #67 the env format
    /// round-trips every provider — a mixed-provider store's reported count
    /// covers *all* active, tokened rows, the Codex/OpenAI email appears in
    /// the serialized text, and the OpenAI entry carries the additive
    /// `ACCOUNT_PROVIDER_N` / `ACCOUNT_REFRESH_N` / `ACCOUNT_EXPIRES_N` keys
    /// while the Anthropic entries carry none of them (so an old-format,
    /// Anthropic-only export is byte-for-byte what it was before #67).
    private static func testExportAccountsEnvIncludesAllProviders() {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("claude-monitor-selftest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let dbPath = dir.appendingPathComponent("usage.db").path

            let store = UsageStore(dbPath: dbPath)
            store.ensureDatabase()
            let db = try openDatabase(dbPath)

            try db.run("""
                INSERT INTO accounts (id, account_name, email, plan, last_updated, sort_order, provider)
                VALUES ('anthropic-1', 'Claude One', 'one@example.com', 'Max', '2026-01-01T00:00:00Z', 0, 'anthropic')
            """)
            try db.run("""
                INSERT INTO accounts (id, account_name, email, plan, last_updated, sort_order, provider)
                VALUES ('anthropic-2', 'Claude Two', 'two@example.com', 'Pro', '2026-01-01T00:00:00Z', 1, 'anthropic')
            """)
            try db.run("""
                INSERT INTO accounts (id, account_name, email, plan, last_updated, sort_order, provider)
                VALUES ('codex-1', 'Codex One', 'codex@example.com', 'Plus', '2026-01-01T00:00:00Z', 2, 'openai')
            """)
            for (accountId, token) in [
                ("anthropic-1", "token-one"),
                ("anthropic-2", "token-two"),
            ] {
                try db.run("""
                    INSERT INTO oauth_credentials
                        (account_id, label, access_token, is_active, created_at, updated_at, provider)
                    VALUES (?, ?, ?, 1, '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z',
                            (SELECT provider FROM accounts WHERE id = ?))
                """, accountId, accountId, token, accountId)
            }
            try db.run("""
                INSERT INTO oauth_credentials
                    (account_id, label, access_token, refresh_token, token_expires_at,
                     is_active, created_at, updated_at, provider)
                VALUES ('codex-1', 'codex-1', 'token-codex', 'refresh-codex',
                        '2026-08-15T00:00:00Z', 1, '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z', 'openai')
            """)

            let poller = OAuthPoller(dbPath: dbPath)
            guard let (env, count, excludedHostLocal) = poller.exportAccountsEnv() else {
                checks += 1
                failures.append("exportAccountsEnv returned nil for a store with exportable accounts")
                return
            }

            expectEqual(count, 3, "exported count covers every active, tokened row regardless of provider")
            expectEqual(excludedHostLocal, 0, "a tokened Codex row (e.g. imported via clipboard) is not host-local-excluded")
            expect(env.contains("one@example.com"), "export includes the first Anthropic account")
            expect(env.contains("two@example.com"), "export includes the second Anthropic account")
            expect(env.contains("codex@example.com"), "export now includes the Codex/OpenAI account (#67)")
            expect(env.contains("ACCOUNT_PROVIDER_3=openai"), "the OpenAI entry is tagged with its provider")
            expect(env.contains("ACCOUNT_REFRESH_3=refresh-codex"), "the OpenAI entry carries its refresh token")
            expect(env.contains("ACCOUNT_EXPIRES_3=2026-08-15T00:00:00Z"), "the OpenAI entry carries its access-token expiry")
            expect(!env.contains("ACCOUNT_PROVIDER_1"), "an Anthropic entry emits no provider marker")
            expect(!env.contains("ACCOUNT_PROVIDER_2"), "an Anthropic entry emits no provider marker")
            expect(!env.contains("ACCOUNT_REFRESH_1") && !env.contains("ACCOUNT_REFRESH_2"),
                   "an Anthropic entry emits no refresh-token key")
        } catch {
            checks += 1
            failures.append("exportAccountsEnv provider test threw: \(error)")
        }
    }

    /// Mixed host, post-#123: a normally-polled Codex account has NO stored
    /// token (`nullOutOpenAITokens` nulls it at migration), unlike the
    /// clipboard-imported one above. `exportAccountsEnv` must still count the
    /// Anthropic accounts normally *and* report the Codex account as
    /// host-local-excluded rather than silently dropping it from both the
    /// count and any explanation (issue #129).
    private static func testExportAccountsEnvExcludesTokenlessCodexAccount() {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("claude-monitor-selftest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let dbPath = dir.appendingPathComponent("usage.db").path

            let store = UsageStore(dbPath: dbPath)
            store.ensureDatabase()
            let db = try openDatabase(dbPath)

            try db.run("""
                INSERT INTO accounts (id, account_name, email, plan, last_updated, sort_order, provider)
                VALUES ('anthropic-1', 'Claude One', 'one@example.com', 'Max', '2026-01-01T00:00:00Z', 0, 'anthropic')
            """)
            try db.run("""
                INSERT INTO accounts (id, account_name, email, plan, last_updated, sort_order, codex_home, provider)
                VALUES ('codex-1', 'Codex One', 'codex@example.com', 'Plus', '2026-01-01T00:00:00Z', 1, '/home/codex', 'openai')
            """)
            try db.run("""
                INSERT INTO oauth_credentials
                    (account_id, label, access_token, is_active, created_at, updated_at, provider)
                VALUES ('anthropic-1', 'anthropic-1', 'token-one', 1,
                        '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z', 'anthropic')
            """)
            // Mirrors what `nullOutOpenAITokens` (#123) leaves behind: an
            // active, tokenless credential row for a registered Codex home.
            try db.run("""
                INSERT INTO oauth_credentials
                    (account_id, label, access_token, refresh_token, is_active, created_at, updated_at, provider)
                VALUES ('codex-1', 'codex-1', NULL, NULL, 1, '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z', 'openai')
            """)

            let poller = OAuthPoller(dbPath: dbPath)
            guard let (env, count, excludedHostLocal) = poller.exportAccountsEnv() else {
                checks += 1
                failures.append("exportAccountsEnv returned nil for a mixed host with a tokenless Codex account")
                return
            }

            expectEqual(count, 1, "only the tokened Anthropic account is exported")
            expectEqual(excludedHostLocal, 1, "the tokenless Codex account is counted as host-local-excluded")
            expect(env.contains("one@example.com"), "export still includes the Anthropic account")
            expect(!env.contains("codex@example.com"), "the tokenless Codex account is not serialized (there is no token to export)")
        } catch {
            checks += 1
            failures.append("exportAccountsEnv tokenless-Codex test threw: \(error)")
        }
    }

    /// Codex-only host, post-#123: every active credential is a tokenless
    /// Codex row. `exportAccountsEnv` must NOT return nil here — a nil result
    /// is indistinguishable from a genuinely empty store, and `copyAccounts()`
    /// would report the bare, misleading "Nothing to copy" that #67 already
    /// fixed once (issue #129 is that regression coming back through #123).
    private static func testExportAccountsEnvCodexOnlyHostIsNotGenuinelyEmpty() {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("claude-monitor-selftest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let dbPath = dir.appendingPathComponent("usage.db").path

            let store = UsageStore(dbPath: dbPath)
            store.ensureDatabase()
            let db = try openDatabase(dbPath)

            try db.run("""
                INSERT INTO accounts (id, account_name, email, plan, last_updated, sort_order, codex_home, provider)
                VALUES ('codex-1', 'Codex One', 'codex@example.com', 'Plus', '2026-01-01T00:00:00Z', 0, '/home/codex', 'openai')
            """)
            try db.run("""
                INSERT INTO oauth_credentials
                    (account_id, label, access_token, refresh_token, is_active, created_at, updated_at, provider)
                VALUES ('codex-1', 'codex-1', NULL, NULL, 1, '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z', 'openai')
            """)

            let poller = OAuthPoller(dbPath: dbPath)
            guard let (_, count, excludedHostLocal) = poller.exportAccountsEnv() else {
                checks += 1
                failures.append("exportAccountsEnv returned nil for a Codex-only host — it must report the exclusion instead")
                return
            }

            expectEqual(count, 0, "a Codex-only host has nothing tokened to export")
            expectEqual(excludedHostLocal, 1, "the sole Codex account is reported as host-local-excluded, not silently dropped")
        } catch {
            checks += 1
            failures.append("exportAccountsEnv Codex-only-host test threw: \(error)")
        }
    }

    /// A genuinely empty store (no accounts at all) must still return nil —
    /// the excluded-count reporting above must not turn every empty store
    /// into a false "N accounts are host-local" claim.
    private static func testExportAccountsEnvGenuinelyEmptyStoreReturnsNil() {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("claude-monitor-selftest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let dbPath = dir.appendingPathComponent("usage.db").path

            let store = UsageStore(dbPath: dbPath)
            store.ensureDatabase()

            let poller = OAuthPoller(dbPath: dbPath)
            expect(poller.exportAccountsEnv() == nil, "a genuinely empty store still reports nil, not a false exclusion")
        } catch {
            checks += 1
            failures.append("exportAccountsEnv empty-store test threw: \(error)")
        }
    }

    /// `parseAccountPairs` must keep parsing an old-format, Anthropic-only
    /// paste (no `ACCOUNT_PROVIDER_N` key at all) exactly as it did before
    /// #67: every entry resolves to `.anthropic` with no refresh token or
    /// expiry — the backward-compatibility constraint the issue calls out.
    private static func testParseAccountPairsBackwardCompatibleWithOldFormat() {
        let poller = OAuthPoller(dbPath: "/nonexistent/does-not-matter-for-parsing.db")
        let legacy = """
            # Claude Monitor accounts — 2 account(s)
            ACCOUNT_EMAIL_1=one@example.com
            ACCOUNT_KEY_1=token-one
            ACCOUNT_EMAIL_2=two@example.com
            ACCOUNT_KEY_2=token-two
            """
        let parsed = poller.parseAccountPairs(legacy)
        expectEqual(parsed.count, 2, "both legacy entries parse")
        for entry in parsed {
            expectEqual(entry.provider, .anthropic, "a legacy entry with no provider marker resolves to Anthropic")
            expect(entry.refreshToken == nil, "a legacy entry carries no refresh token")
            expect(entry.tokenExpiresAt == nil, "a legacy entry carries no token expiry")
        }
        expectEqual(parsed[0].email, "one@example.com", "order follows the ACCOUNT_EMAIL_N index")
        expectEqual(parsed[1].email, "two@example.com", "order follows the ACCOUNT_EMAIL_N index")
    }

    /// A new-format, mixed-provider paste round-trips through
    /// `exportAccountsEnv` → `parseAccountPairs`: the Anthropic entries parse
    /// exactly as before, and the OpenAI entry recovers its provider tag,
    /// refresh token, and expiry — the credential material
    /// `addOpenAIAccount` needs to re-authenticate on the destination host.
    /// Also asserts an unrecognized future key (`ACCOUNT_FOOBAR_1`) doesn't
    /// perturb parsing of the known ones — the graceful-degradation property
    /// an older build's parser relies on when it meets a still-newer format.
    private static func testParseAccountPairsRoundTripsOpenAIFields() {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("claude-monitor-selftest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let dbPath = dir.appendingPathComponent("usage.db").path
            let store = UsageStore(dbPath: dbPath)
            store.ensureDatabase()
            let db = try openDatabase(dbPath)

            try db.run("""
                INSERT INTO accounts (id, account_name, email, plan, last_updated, sort_order, provider)
                VALUES ('anthropic-1', 'Claude One', 'one@example.com', 'Max', '2026-01-01T00:00:00Z', 0, 'anthropic')
            """)
            try db.run("""
                INSERT INTO accounts (id, account_name, email, plan, last_updated, sort_order, provider)
                VALUES ('codex-1', 'Codex One', 'codex@example.com', 'Plus', '2026-01-01T00:00:00Z', 1, 'openai')
            """)
            try db.run("""
                INSERT INTO oauth_credentials
                    (account_id, label, access_token, is_active, created_at, updated_at, provider)
                VALUES ('anthropic-1', 'anthropic-1', 'token-one', 1,
                        '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z', 'anthropic')
            """)
            try db.run("""
                INSERT INTO oauth_credentials
                    (account_id, label, access_token, refresh_token, token_expires_at,
                     is_active, created_at, updated_at, provider)
                VALUES ('codex-1', 'codex-1', 'token-codex', 'refresh-codex',
                        '2026-08-15T00:00:00Z', 1, '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z', 'openai')
            """)

            let poller = OAuthPoller(dbPath: dbPath)
            guard let (env, _, _) = poller.exportAccountsEnv() else {
                checks += 1
                failures.append("exportAccountsEnv returned nil for a store with exportable accounts")
                return
            }

            // A future key an older/newer build might add — must not disturb
            // parsing of the keys this build understands.
            let withUnknownKey = env + "\nACCOUNT_FOOBAR_1=surprise\n"
            let parsed = poller.parseAccountPairs(withUnknownKey)
            expectEqual(parsed.count, 2, "both entries parse despite the unrecognized key")

            guard let anthropicEntry = parsed.first(where: { $0.email == "one@example.com" }),
                  let openaiEntry = parsed.first(where: { $0.email == "codex@example.com" }) else {
                checks += 1
                failures.append("round-trip parse is missing an expected entry")
                return
            }

            expectEqual(anthropicEntry.provider, .anthropic, "the Anthropic entry round-trips as Anthropic")
            expect(anthropicEntry.refreshToken == nil, "the Anthropic entry carries no refresh token")

            expectEqual(openaiEntry.provider, .openai, "the OpenAI entry round-trips as OpenAI")
            expectEqual(openaiEntry.token, "token-codex", "the OpenAI entry round-trips its access token")
            expectEqual(openaiEntry.refreshToken, "refresh-codex", "the OpenAI entry round-trips its refresh token")
            expectEqual(openaiEntry.tokenExpiresAt, UsageRecord.parseISO("2026-08-15T00:00:00Z"),
                        "the OpenAI entry round-trips its access-token expiry")
        } catch {
            checks += 1
            failures.append("parseAccountPairs OpenAI round-trip test threw: \(error)")
        }
    }

    // MARK: - AccountSync host-local provider exclusion (#104)

    /// Codex/OpenAI accounts are host-local (#104): `exportBundle` must never
    /// emit one, and `importBundle` must skip (not fail on) one carried by a
    /// bundle from an older version. This also covers the hazard that
    /// motivated the original provider-scoped email match: an OpenAI entry
    /// sharing an Anthropic account's email must never land on — or
    /// overwrite the credential of — that Anthropic row. Exclusion is a
    /// stronger guarantee than scoping (the entry is never touched at all),
    /// so this single test now covers both.
    private static func testAccountSyncExcludesOpenAIAccounts() {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("claude-monitor-selftest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let dbPath = dir.appendingPathComponent("usage.db").path

            let store = UsageStore(dbPath: dbPath)
            store.ensureDatabase()
            let db = try openDatabase(dbPath)
            try db.run("""
                INSERT INTO accounts (id, account_name, email, plan, last_updated, provider)
                VALUES ('claude-org-uuid', 'me@example.com', 'me@example.com', 'Max',
                        '2026-01-01T00:00:00Z', 'anthropic')
            """)
            try db.run("""
                INSERT INTO oauth_credentials
                    (account_id, label, source, provider, access_token, is_active,
                     created_at, updated_at)
                VALUES ('claude-org-uuid', 'me@example.com', 'token', 'anthropic',
                        'sk-ant-claude-token', 1, '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z')
            """)
            // A live OpenAI account, present in the local database.
            try db.run("""
                INSERT INTO accounts (id, account_name, email, plan, last_updated, provider)
                VALUES ('user-native-openai', 'me2@example.com', 'me2@example.com', 'pro',
                        '2026-01-01T00:00:00Z', 'openai')
            """)
            try db.run("""
                INSERT INTO oauth_credentials
                    (account_id, label, source, provider, access_token, refresh_token, is_active,
                     created_at, updated_at)
                VALUES ('user-native-openai', 'me2@example.com', 'codex', 'openai',
                        'openai-access-token', 'openai-refresh-token', 1,
                        '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z')
            """)

            // --- Export excludes the OpenAI account entirely. ---
            let exported = try AccountSync.exportBundle(dbPath: dbPath)
            expectEqual(exported.accounts.count, 1, "export carries only the Anthropic account")
            expectEqual(exported.accounts.first?.provider, "anthropic",
                        "the one exported account is the Anthropic one")
            expect(!exported.accounts.contains { $0.provider == "openai" },
                   "no openai account appears in the export bundle")

            // --- Import skips an OpenAI entry from an older bundle, without error. ---
            let bundle = AccountSync.ExportBundle(
                formatVersion: AccountSync.formatVersion,
                exportedAt: "2026-07-01T00:00:00Z",
                sourceHost: "selftest",
                accounts: [
                    AccountSync.ExportedAccount(
                        id: "user-native-openai-imported",
                        provider: "openai",
                        accountName: "me@example.com",
                        email: "me@example.com",
                        plan: "pro",
                        lastUpdated: "2026-07-01T00:00:00Z",
                        sortOrder: 0,
                        credentials: [AccountSync.ExportedCredential(
                            label: "me@example.com", source: "codex", provider: "openai",
                            accessToken: "openai-access-token", refreshToken: "openai-refresh",
                            expiresAt: nil, tokenExpiresAt: "2026-08-01T00:00:00Z",
                            scopes: nil, subscriptionType: nil, rateLimitTier: nil,
                            isActive: true, createdAt: nil, updatedAt: nil, tokenRolledAt: nil
                        )]
                    ),
                    AccountSync.ExportedAccount(
                        id: "claude-org-uuid-2",
                        provider: "anthropic",
                        accountName: "second@example.com",
                        email: "second@example.com",
                        plan: "Max",
                        lastUpdated: "2026-07-01T00:00:00Z",
                        sortOrder: 1,
                        credentials: []
                    ),
                ]
            )
            let summary = try AccountSync.importBundle(bundle, dbPath: dbPath)
            expectEqual(summary.excluded, 1, "the OpenAI entry is reported as excluded, not created/updated")
            expectEqual(summary.created, 1, "the Anthropic entry in the same bundle still imports normally")

            expectEqual(
                try db.scalar("SELECT COUNT(*) FROM accounts WHERE provider = 'openai'") as? Int64,
                1, "importing a bundle with an OpenAI entry does not create a new OpenAI row")
            expectEqual(
                try db.scalar("SELECT id FROM accounts WHERE provider = 'openai'") as? String,
                "user-native-openai", "the pre-existing OpenAI account is untouched by the import")

            let claudeProvider = try db.scalar(
                "SELECT provider FROM accounts WHERE id = 'claude-org-uuid'") as? String
            expectEqual(claudeProvider, "anthropic",
                        "the Anthropic row sharing the email keeps its provider")
            let claudeToken = try db.scalar(
                "SELECT access_token FROM oauth_credentials WHERE account_id = 'claude-org-uuid'") as? String
            expectEqual(claudeToken, "sk-ant-claude-token",
                        "the Claude credential is not overwritten by the excluded OpenAI import")
        } catch {
            checks += 1
            failures.append("account sync host-local exclusion test threw: \(error)")
        }
    }

    // MARK: - Duplicate account merge (#45)

    /// A database created before `10660f3` (v1.18.0) can carry two active
    /// rows for the same account — one keyed by a locally generated UUID
    /// from the pre-native-id era, one by the provider's native id — each
    /// polled independently. The healing migration must merge them: history
    /// moves onto the surviving (native-id) row, exactly one credential
    /// survives (the more recently renewed of the two), the settings pin
    /// follows if it pointed at the row being removed, an Anthropic row
    /// sharing the same email is left untouched (provider-scoped), and a
    /// second run over the healed database is a no-op.
    private static func testMergeDuplicateAccountsSharingEmail() {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("claude-monitor-selftest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let dbPath = dir.appendingPathComponent("usage.db").path

            let store = UsageStore(dbPath: dbPath)
            store.ensureDatabase()
            let db = try openDatabase(dbPath)

            let legacyId = "BFA6C1F0-8C2A-4CB0-9A5E-000000000001" // canonical UUID shape
            let nativeId = "user-native-oai"

            try db.run("""
                INSERT INTO accounts (id, account_name, email, plan, last_updated, provider)
                VALUES (?, 'me@example.com', 'me@example.com', 'pro', '2026-01-01T00:00:00Z', 'openai')
            """, legacyId)
            try db.run("""
                INSERT INTO accounts (id, account_name, email, plan, last_updated, provider)
                VALUES (?, 'me@example.com', 'me@example.com', 'pro', '2026-06-01T00:00:00Z', 'openai')
            """, nativeId)
            // Shares the email but a different provider — must survive untouched.
            try db.run("""
                INSERT INTO accounts (id, account_name, email, plan, last_updated, provider)
                VALUES ('anthropic-row', 'me@example.com', 'me@example.com', 'Max',
                        '2026-01-01T00:00:00Z', 'anthropic')
            """)

            try db.run("""
                INSERT INTO usage_history (account_id, timestamp, primary_percent, is_synthetic)
                VALUES (?, '2026-01-01T00:00:00Z', 10, 0)
            """, legacyId)
            try db.run("""
                INSERT INTO usage_history (account_id, timestamp, primary_percent, is_synthetic)
                VALUES (?, '2026-06-01T00:00:00Z', 20, 0)
            """, nativeId)
            try db.run("""
                INSERT INTO probe_snapshots (account_id, timestamp, probe_model, http_status, headers)
                VALUES (?, '2026-01-01T00:00:00Z', 'haiku', 200, '{}')
            """, legacyId)
            // named_limits only exists for the legacy row — merge must carry it
            // over even though the native row never had any.
            try db.run("""
                INSERT INTO named_limits (account_id, timestamp, limit_name, used_percent)
                VALUES (?, '2026-01-01T00:00:00Z', 'GPT-5.3-Codex-Spark', 42)
            """, legacyId)

            // The legacy row's credential was renewed more recently than the
            // native row's — the merge must keep the legacy credential's
            // token even though the *native* row is the id that survives.
            try db.run("""
                INSERT INTO oauth_credentials
                    (account_id, label, source, provider, access_token, is_active,
                     created_at, updated_at, token_rolled_at)
                VALUES (?, 'me@example.com', 'codex', 'openai', 'legacy-fresher-token', 1,
                        '2026-01-01T00:00:00Z', '2026-06-20T00:00:00Z', '2026-06-20T00:00:00Z')
            """, legacyId)
            try db.run("""
                INSERT INTO oauth_credentials
                    (account_id, label, source, provider, access_token, is_active,
                     created_at, updated_at, token_rolled_at)
                VALUES (?, 'me@example.com', 'codex', 'openai', 'native-stale-token', 1,
                        '2026-06-01T00:00:00Z', '2026-06-01T00:00:00Z', '2026-01-05T00:00:00Z')
            """, nativeId)

            // The user had pinned the legacy row as their primary account.
            try db.run("INSERT INTO settings (key, value) VALUES ('primary_account_id', ?)", legacyId)

            // --- What the next launch does. ---
            store.ensureDatabase()

            let openaiRows = try db.prepare(
                "SELECT id FROM accounts WHERE email = 'me@example.com' AND provider = 'openai'"
            ).map { $0[0] as? String }
            expectEqual(openaiRows.count, 1, "the openai duplicate pair merges into one row")
            expectEqual(openaiRows.first.flatMap { $0 } ?? "", nativeId,
                        "the provider-native id survives over the locally generated UUID")

            expectEqual(
                try db.scalar("SELECT COUNT(*) FROM accounts WHERE id = ?", legacyId) as? Int64, 0,
                "the losing row is removed")
            expectEqual(
                try db.scalar("SELECT COUNT(*) FROM accounts WHERE email = 'me@example.com'") as? Int64, 2,
                "the anthropic row sharing the email is untouched (provider-scoped)")
            expectEqual(
                try db.scalar("SELECT provider FROM accounts WHERE id = 'anthropic-row'") as? String,
                "anthropic", "the anthropic row keeps its provider")

            expectEqual(
                try db.scalar("SELECT COUNT(*) FROM usage_history WHERE account_id = ?", nativeId) as? Int64, 2,
                "usage_history rows from both accounts land on the survivor")
            expectEqual(
                try db.scalar("SELECT COUNT(*) FROM probe_snapshots WHERE account_id = ?", nativeId) as? Int64, 1,
                "probe_snapshots rows move onto the survivor")
            expectEqual(
                try db.scalar("SELECT COUNT(*) FROM named_limits WHERE account_id = ?", nativeId) as? Int64, 1,
                "named_limits rows move onto the survivor even though the survivor never had any")

            expectEqual(
                try db.scalar("SELECT COUNT(*) FROM oauth_credentials WHERE account_id IN (?, ?)",
                              nativeId, legacyId) as? Int64,
                1, "exactly one credential survives the merge")
            // `access_token` itself can't be the signal any more: both seeded
            // credentials are `provider = 'openai'`, and the same
            // `ensureDatabase()` call nulls OpenAI tokens right after this
            // merge runs (#104). `token_rolled_at` survives that migration
            // untouched, so it is what proves the *more recently renewed* row
            // — not merely "a" row — is the one reassigned to the survivor.
            expectEqual(
                try db.scalar("SELECT token_rolled_at FROM oauth_credentials WHERE account_id = ?", nativeId) as? String,
                "2026-06-20T00:00:00Z",
                "the more recently renewed credential wins, reassigned to the survivor")
            expectEqual(
                try db.scalar("SELECT access_token FROM oauth_credentials WHERE account_id = ?", nativeId) as? String,
                nil, "the surviving OpenAI credential's token is nulled by the same migration pass (#104)")

            expectEqual(
                try db.scalar("SELECT value FROM settings WHERE key = 'primary_account_id'") as? String,
                nativeId, "the primary-account pin follows the merge to the survivor")

            // Idempotent: re-running over an already-healed database changes nothing.
            store.ensureDatabase()
            expectEqual(try db.scalar("SELECT COUNT(*) FROM accounts") as? Int64, 2,
                        "re-running the healed database doesn't merge or remove anything further")
            expectEqual(
                try db.scalar("SELECT COUNT(*) FROM oauth_credentials WHERE account_id IN (?, ?)",
                              nativeId, legacyId) as? Int64,
                1, "re-running doesn't touch the surviving credential")
        } catch {
            checks += 1
            failures.append("duplicate account merge test threw: \(error)")
        }
    }

    // MARK: - Account removal vs. history clear (#106)

    /// Removing an account must take its credential with it. Before #106 the
    /// removal path deleted only `usage_history` and `accounts`, stranding a
    /// plaintext OAuth token under an account id nothing in the app could
    /// reach — never surfaced, never rotated, never revoked.
    ///
    /// The same function also backed the chart window's "Clear History"
    /// button, so that control silently deleted the account too. The two are
    /// now separate operations and this test pins both halves: delete removes
    /// everything, clear-history removes only the time series.
    private static func testAccountDeletionRemovesCredentials() {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("claude-monitor-selftest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let dbPath = dir.appendingPathComponent("usage.db").path

            let store = UsageStore(dbPath: dbPath)
            store.ensureDatabase()
            let db = try openDatabase(dbPath)

            let doomedId = "acct-doomed"
            let keptId = "acct-kept"
            // A third account with no credential at all — deleting it must be
            // a clean no-op on `oauth_credentials`, not an error.
            let bareId = "acct-bare"

            for (id, email) in [(doomedId, "doomed@example.com"),
                                (keptId, "kept@example.com"),
                                (bareId, "bare@example.com")] {
                try db.run("""
                    INSERT INTO accounts (id, account_name, email, plan, last_updated, provider)
                    VALUES (?, ?, ?, 'Max', '2026-06-01T00:00:00Z', 'anthropic')
                """, id, email, email)
            }

            for id in [doomedId, keptId] {
                try db.run("""
                    INSERT INTO usage_history (account_id, timestamp, primary_percent, is_synthetic)
                    VALUES (?, '2026-06-01T00:00:00Z', 12, 0)
                """, id)
                try db.run("""
                    INSERT INTO probe_snapshots (account_id, timestamp, probe_model, http_status, headers)
                    VALUES (?, '2026-06-01T00:00:00Z', 'haiku', 200, '{}')
                """, id)
                try db.run("""
                    INSERT INTO named_limits (account_id, timestamp, limit_name, used_percent)
                    VALUES (?, '2026-06-01T00:00:00Z', 'GPT-5.3-Codex-Spark', 42)
                """, id)
                try db.run("""
                    INSERT INTO oauth_credentials
                        (account_id, label, source, provider, access_token, refresh_token,
                         is_active, created_at, updated_at)
                    VALUES (?, 'label', 'token', 'anthropic', 'token-value', 'refresh-value', 1,
                            '2026-06-01T00:00:00Z', '2026-06-01T00:00:00Z')
                """, id)
            }
            // Two credentials share the doomed account id — both must go.
            try db.run("""
                INSERT INTO oauth_credentials
                    (account_id, label, source, provider, access_token, is_active,
                     created_at, updated_at)
                VALUES (?, 'second', 'token', 'anthropic', 'second-token-value', 0,
                        '2026-06-01T00:00:00Z', '2026-06-01T00:00:00Z')
            """, doomedId)
            // The user had pinned the account they are about to remove.
            try db.run("INSERT INTO settings (key, value) VALUES ('primary_account_id', ?)", doomedId)

            // --- Remove Account. ---
            store.deleteAccount(accountId: doomedId)

            expectEqual(
                try db.scalar("SELECT COUNT(*) FROM accounts WHERE id = ?", doomedId) as? Int64, 0,
                "removing an account deletes its accounts row")
            expectEqual(
                try db.scalar("SELECT COUNT(*) FROM oauth_credentials WHERE account_id = ?",
                              doomedId) as? Int64,
                0, "removing an account deletes every one of its credential rows")
            expectEqual(
                try db.scalar("SELECT COUNT(*) FROM usage_history WHERE account_id = ?",
                              doomedId) as? Int64,
                0, "removing an account deletes its usage_history rows")
            expectEqual(
                try db.scalar("SELECT COUNT(*) FROM probe_snapshots WHERE account_id = ?",
                              doomedId) as? Int64,
                0, "removing an account deletes its probe_snapshots rows")
            expectEqual(
                try db.scalar("SELECT COUNT(*) FROM named_limits WHERE account_id = ?",
                              doomedId) as? Int64,
                0, "removing an account deletes its named_limits rows")
            expectEqual(
                try db.scalar("SELECT COUNT(*) FROM settings WHERE key = 'primary_account_id'")
                    as? Int64,
                0, "removing the pinned account clears the primary-account pin")

            // The detection query from the issue: no credential may reference
            // a missing account after a delete.
            expectEqual(try orphanedCredentialCount(db), 0,
                        "an account delete leaves no orphaned credential rows")

            // Deleting an account that never had a credential is a clean no-op.
            store.deleteAccount(accountId: bareId)
            expectEqual(
                try db.scalar("SELECT COUNT(*) FROM accounts WHERE id = ?", bareId) as? Int64, 0,
                "an account with no credential still deletes cleanly")
            expectEqual(try orphanedCredentialCount(db), 0,
                        "deleting a credential-less account leaves no orphans")

            // The untouched account keeps everything.
            expectEqual(
                try db.scalar("SELECT access_token FROM oauth_credentials WHERE account_id = ?",
                              keptId) as? String,
                "token-value", "the other account's credential is untouched by the delete")

            // --- Clear History (chart window). ---
            store.clearAccountHistory(accountId: keptId)

            expectEqual(
                try db.scalar("SELECT COUNT(*) FROM accounts WHERE id = ?", keptId) as? Int64, 1,
                "clearing history does NOT delete the accounts row")
            expectEqual(
                try db.scalar("SELECT access_token FROM oauth_credentials WHERE account_id = ?",
                              keptId) as? String,
                "token-value", "clearing history does NOT touch the credential")
            expectEqual(
                try db.scalar("SELECT COUNT(*) FROM usage_history WHERE account_id = ?",
                              keptId) as? Int64,
                0, "clearing history empties usage_history")
            expectEqual(
                try db.scalar("SELECT COUNT(*) FROM probe_snapshots WHERE account_id = ?",
                              keptId) as? Int64,
                0, "clearing history empties the probe archive")
            expectEqual(
                try db.scalar("SELECT COUNT(*) FROM named_limits WHERE account_id = ?",
                              keptId) as? Int64,
                0, "clearing history empties the named-limit series")
            expectEqual(try orphanedCredentialCount(db), 0,
                        "clearing history leaves no orphaned credential rows")
        } catch {
            checks += 1
            failures.append("account deletion test threw: \(error)")
        }
    }

    /// The healing migration for databases that already carry an orphan from a
    /// pre-#106 build. Two properties matter as much as the purge itself:
    /// credentials with a NULL (or blank) `account_id` must **survive** — the
    /// column is nullable, and the obvious `LEFT JOIN accounts … WHERE a.id IS
    /// NULL` predicate would silently destroy live token material — and a
    /// second run must be a no-op.
    private static func testPurgeOrphanedCredentialsMigration() {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("claude-monitor-selftest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let dbPath = dir.appendingPathComponent("usage.db").path

            let store = UsageStore(dbPath: dbPath)
            store.ensureDatabase()
            let db = try openDatabase(dbPath)

            try db.run("""
                INSERT INTO accounts (id, account_name, email, plan, last_updated, provider)
                VALUES ('live-account', 'live@example.com', 'live@example.com', 'Max',
                        '2026-06-01T00:00:00Z', 'anthropic')
            """)
            // Belongs to a live account — must be left alone.
            try db.run("""
                INSERT INTO oauth_credentials
                    (account_id, label, source, provider, access_token, is_active,
                     created_at, updated_at)
                VALUES ('live-account', 'live', 'token', 'anthropic', 'live-token', 1,
                        '2026-06-01T00:00:00Z', '2026-06-01T00:00:00Z')
            """)
            // The orphan a pre-#106 removal left behind, token still populated.
            try db.run("""
                INSERT INTO oauth_credentials
                    (account_id, label, source, provider, access_token, refresh_token, is_active,
                     created_at, updated_at)
                VALUES ('gone-account', 'gone', 'token', 'anthropic', 'stranded-token',
                        'stranded-refresh', 0, '2026-02-10T17:16:25Z', '2026-07-22T04:25:07Z')
            """)
            // Never attached to an account. `account_id` is nullable, so these
            // are legitimate rows — the purge must not reach them.
            try db.run("""
                INSERT INTO oauth_credentials
                    (account_id, label, source, provider, access_token, is_active,
                     created_at, updated_at)
                VALUES (NULL, 'unattached', 'keychain', 'anthropic', 'null-account-token', 1,
                        '2026-06-01T00:00:00Z', '2026-06-01T00:00:00Z')
            """)
            try db.run("""
                INSERT INTO oauth_credentials
                    (account_id, label, source, provider, access_token, is_active,
                     created_at, updated_at)
                VALUES ('   ', 'blank', 'keychain', 'anthropic', 'blank-account-token', 1,
                        '2026-06-01T00:00:00Z', '2026-06-01T00:00:00Z')
            """)

            expectEqual(try db.scalar("SELECT COUNT(*) FROM oauth_credentials") as? Int64, 4,
                        "the seeded database starts with four credential rows")

            // --- What the next launch does. ---
            store.ensureDatabase()

            expectEqual(
                try db.scalar("SELECT COUNT(*) FROM oauth_credentials WHERE account_id = 'gone-account'")
                    as? Int64,
                0, "the migration purges the orphaned credential")
            expectEqual(try orphanedCredentialCount(db), 0,
                        "the detection query reports no orphans after the migration")
            expectEqual(
                try db.scalar("SELECT access_token FROM oauth_credentials WHERE account_id = 'live-account'")
                    as? String,
                "live-token", "a credential belonging to a live account is untouched")
            expectEqual(
                try db.scalar("SELECT COUNT(*) FROM oauth_credentials WHERE account_id IS NULL")
                    as? Int64,
                1, "a credential with account_id IS NULL survives the purge")
            expectEqual(
                try db.scalar("SELECT COUNT(*) FROM oauth_credentials WHERE TRIM(account_id) = ''")
                    as? Int64,
                1, "a credential with a blank account_id survives the purge")
            expectEqual(try db.scalar("SELECT COUNT(*) FROM oauth_credentials") as? Int64, 3,
                        "exactly one row — the orphan — is removed")

            // Idempotent: re-running over the healed database changes nothing.
            store.ensureDatabase()
            expectEqual(try db.scalar("SELECT COUNT(*) FROM oauth_credentials") as? Int64, 3,
                        "re-running the migration on a healed database is a no-op")
        } catch {
            checks += 1
            failures.append("orphaned credential purge test threw: \(error)")
        }
    }

    /// The healing migration for #104: `oauth_credentials` rows for
    /// `provider = 'openai'` should carry no `access_token` / `refresh_token`
    /// — this app now reads Codex usage via `codex app-server` / `auth.json`
    /// rather than holding a copy of a credential OpenAI rotates on every
    /// use. Two properties matter as much as the clearing itself: an
    /// Anthropic credential must be untouched (Anthropic tokens are
    /// long-lived and never proactively refreshed, so there is nothing to
    /// clear there), and a second run must be a no-op.
    private static func testNullOutOpenAITokensMigration() {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("claude-monitor-selftest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let dbPath = dir.appendingPathComponent("usage.db").path

            let store = UsageStore(dbPath: dbPath)
            store.ensureDatabase()
            let db = try openDatabase(dbPath)

            try db.run("""
                INSERT INTO accounts (id, account_name, email, plan, last_updated, provider)
                VALUES ('claude-account', 'claude@example.com', 'claude@example.com', 'Max',
                        '2026-06-01T00:00:00Z', 'anthropic')
            """)
            try db.run("""
                INSERT INTO oauth_credentials
                    (account_id, label, source, provider, access_token, refresh_token, is_active,
                     created_at, updated_at)
                VALUES ('claude-account', 'claude@example.com', 'token', 'anthropic',
                        'sk-ant-oat01-selftest', NULL, 1, '2026-06-01T00:00:00Z', '2026-06-01T00:00:00Z')
            """)

            try db.run("""
                INSERT INTO accounts (id, account_name, email, plan, last_updated, provider)
                VALUES ('codex-account', 'codex@example.com', 'codex@example.com', 'pro',
                        '2026-06-01T00:00:00Z', 'openai')
            """)
            // Pre-#104 row: exactly what a build before this migration left
            // behind — a live access/refresh token pair stored for polling.
            try db.run("""
                INSERT INTO oauth_credentials
                    (account_id, label, source, provider, access_token, refresh_token, is_active,
                     created_at, updated_at)
                VALUES ('codex-account', 'codex@example.com', 'codex', 'openai',
                        'openai-access-selftest', 'openai-refresh-selftest', 1,
                        '2026-06-01T00:00:00Z', '2026-06-01T00:00:00Z')
            """)

            // --- What the next launch does. ---
            store.ensureDatabase()

            expectEqual(
                try db.scalar("SELECT access_token FROM oauth_credentials WHERE account_id = 'codex-account'")
                    as? String,
                nil, "the migration clears the OpenAI access token")
            expectEqual(
                try db.scalar("SELECT refresh_token FROM oauth_credentials WHERE account_id = 'codex-account'")
                    as? String,
                nil, "the migration clears the OpenAI refresh token")
            expectEqual(
                try db.scalar("SELECT access_token FROM oauth_credentials WHERE account_id = 'claude-account'")
                    as? String,
                "sk-ant-oat01-selftest", "an Anthropic credential is untouched by the migration")

            // Re-registering a token (e.g. `codex import`) must be nulled
            // again on the very next launch — the migration runs unconditionally.
            try db.run("""
                UPDATE oauth_credentials SET access_token = ?, refresh_token = ?
                WHERE account_id = 'codex-account'
                """, "reimported-access", "reimported-refresh")
            store.ensureDatabase()
            expectEqual(
                try db.scalar("SELECT access_token FROM oauth_credentials WHERE account_id = 'codex-account'")
                    as? String,
                nil, "a freshly (re)written OpenAI token is cleared again on the next launch")

            // Idempotent: re-running over an already-healed database changes nothing.
            store.ensureDatabase()
            expectEqual(
                try db.scalar("SELECT COUNT(*) FROM oauth_credentials") as? Int64, 2,
                "re-running the migration on a healed database is a no-op")
        } catch {
            checks += 1
            failures.append("null-out OpenAI tokens migration test threw: \(error)")
        }
    }

    /// The issue's detection query, narrowed the same way the purge predicate
    /// is: credential rows whose `account_id` *names* an account that isn't
    /// there. A NULL or blank `account_id` is not an orphan — it was never
    /// attached to an account — so those rows are excluded here and asserted
    /// to survive separately by the callers above.
    private static func orphanedCredentialCount(_ db: Connection) throws -> Int64 {
        try db.scalar("""
            SELECT COUNT(*) FROM oauth_credentials c
            LEFT JOIN accounts a ON a.id = c.account_id
            WHERE a.id IS NULL AND c.account_id IS NOT NULL AND TRIM(c.account_id) != ''
        """) as? Int64 ?? -1
    }

    /// The `probe_snapshots` / `named_limits` analog of `orphanedCredentialCount`
    /// (#117): rows whose `account_id` *names* an account that isn't there,
    /// with the same NULL/blank exclusion — a row with no `account_id` at all
    /// was never attached to an account and is not an orphan.
    private static func orphanedAccountRowCount(_ db: Connection, table: String) throws -> Int64 {
        try db.scalar("""
            SELECT COUNT(*) FROM \(table) t
            LEFT JOIN accounts a ON a.id = t.account_id
            WHERE a.id IS NULL AND t.account_id IS NOT NULL AND TRIM(t.account_id) != ''
        """) as? Int64 ?? -1
    }

    /// The healing migration for `probe_snapshots` / `named_limits` rows a
    /// pre-#106 account removal left stranded (#117 — #106 fixed the same
    /// partial-delete bug for `oauth_credentials` but deliberately scoped
    /// these two archive tables out). Mirrors
    /// `testPurgeOrphanedCredentialsMigration`: a row with a NULL or blank
    /// `account_id` must survive, and a second run must be a no-op.
    private static func testPurgeOrphanedProbeAndNamedLimitsMigration() {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("claude-monitor-selftest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let dbPath = dir.appendingPathComponent("usage.db").path

            let store = UsageStore(dbPath: dbPath)
            store.ensureDatabase()
            let db = try openDatabase(dbPath)

            try db.run("""
                INSERT INTO accounts (id, account_name, email, plan, last_updated, provider)
                VALUES ('live-account', 'live@example.com', 'live@example.com', 'Max',
                        '2026-06-01T00:00:00Z', 'anthropic')
            """)
            // Belongs to a live account — must be left alone.
            try db.run("""
                INSERT INTO probe_snapshots (account_id, timestamp, probe_model, http_status, headers)
                VALUES ('live-account', '2026-06-01T00:00:00Z', 'haiku', 200, '{}')
            """)
            try db.run("""
                INSERT INTO named_limits (account_id, timestamp, limit_name, used_percent)
                VALUES ('live-account', '2026-06-01T00:00:00Z', 'GPT-5.3-Codex-Spark', 42)
            """)
            // The orphans a pre-#106 account removal left behind.
            try db.run("""
                INSERT INTO probe_snapshots (account_id, timestamp, probe_model, http_status, headers)
                VALUES ('gone-account', '2026-02-10T17:16:25Z', 'haiku', 200, '{}')
            """)
            try db.run("""
                INSERT INTO named_limits (account_id, timestamp, limit_name, used_percent)
                VALUES ('gone-account', '2026-02-10T17:16:25Z', 'GPT-5.3-Codex-Spark', 7)
            """)
            // Blank `account_id` — never attached to an account. Both tables
            // declare `account_id TEXT NOT NULL`, which rejects NULL but not
            // an empty string, so this is the guard that can actually fire.
            try db.run("""
                INSERT INTO probe_snapshots (account_id, timestamp, probe_model, http_status, headers)
                VALUES ('   ', '2026-06-01T00:00:00Z', 'haiku', 200, '{}')
            """)
            try db.run("""
                INSERT INTO named_limits (account_id, timestamp, limit_name, used_percent)
                VALUES ('   ', '2026-06-01T00:00:00Z', 'GPT-5.3-Codex-Spark', 3)
            """)

            expectEqual(try db.scalar("SELECT COUNT(*) FROM probe_snapshots") as? Int64, 3,
                        "the seeded database starts with three probe_snapshots rows")
            expectEqual(try db.scalar("SELECT COUNT(*) FROM named_limits") as? Int64, 3,
                        "the seeded database starts with three named_limits rows")

            // --- What the next launch does. ---
            store.ensureDatabase()

            expectEqual(
                try db.scalar("SELECT COUNT(*) FROM probe_snapshots WHERE account_id = 'gone-account'")
                    as? Int64,
                0, "the migration purges the orphaned probe_snapshots row")
            expectEqual(
                try db.scalar("SELECT COUNT(*) FROM named_limits WHERE account_id = 'gone-account'")
                    as? Int64,
                0, "the migration purges the orphaned named_limits row")
            expectEqual(try orphanedAccountRowCount(db, table: "probe_snapshots"), 0,
                        "the detection query reports no probe_snapshots orphans after the migration")
            expectEqual(try orphanedAccountRowCount(db, table: "named_limits"), 0,
                        "the detection query reports no named_limits orphans after the migration")
            expectEqual(
                try db.scalar("SELECT http_status FROM probe_snapshots WHERE account_id = 'live-account'")
                    as? Int64,
                200, "a row belonging to a live account is untouched")
            expectEqual(
                try db.scalar("SELECT COUNT(*) FROM probe_snapshots WHERE TRIM(account_id) = ''")
                    as? Int64,
                1, "a probe_snapshots row with a blank account_id survives the purge")
            expectEqual(
                try db.scalar("SELECT COUNT(*) FROM named_limits WHERE TRIM(account_id) = ''")
                    as? Int64,
                1, "a named_limits row with a blank account_id survives the purge")
            expectEqual(try db.scalar("SELECT COUNT(*) FROM probe_snapshots") as? Int64, 2,
                        "exactly one probe_snapshots row — the orphan — is removed")
            expectEqual(try db.scalar("SELECT COUNT(*) FROM named_limits") as? Int64, 2,
                        "exactly one named_limits row — the orphan — is removed")

            // Idempotent: re-running over the healed database changes nothing.
            store.ensureDatabase()
            expectEqual(try db.scalar("SELECT COUNT(*) FROM probe_snapshots") as? Int64, 2,
                        "re-running the migration on a healed database is a no-op (probe_snapshots)")
            expectEqual(try db.scalar("SELECT COUNT(*) FROM named_limits") as? Int64, 2,
                        "re-running the migration on a healed database is a no-op (named_limits)")
        } catch {
            checks += 1
            failures.append("orphaned probe_snapshots/named_limits purge test threw: \(error)")
        }
    }

    // MARK: - Read-only opens of a WAL database

    /// Regression for #105: `accounts export` opens the database read-only, and
    /// a `SQLITE_OPEN_READONLY` connection cannot create the `-shm` shared index
    /// a WAL-mode database needs. Before the fix every read-only open of a
    /// healthy WAL database whose `-shm` was absent — the app not running, or a
    /// plain `cp` of the file — failed with `SQLite error 14`.
    ///
    /// Also pins the two silent-wrong-answer hazards the escalation ladder is
    /// shaped to avoid: WAL content must be *recovered*, never ignored, and no
    /// read path may create a database that isn't there.
    private static func testReadOnlyOpenOfWALDatabaseWithoutSHM() {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("claude-monitor-selftest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let dbPath = dir.appendingPathComponent("usage.db").path

            // --- A WAL database, checkpointed and closed. ---
            do {
                let writer = try openDatabase(dbPath)
                try writer.execute("PRAGMA journal_mode=WAL")
                try writer.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)")
                try writer.run("INSERT INTO t (id, v) VALUES (1, 'one')")
                try writer.run("INSERT INTO t (id, v) VALUES (2, 'two')")
                try writer.execute("PRAGMA wal_checkpoint(TRUNCATE)")
            }

            // The reported reproduction: `cp usage.db <dir>/` — the database
            // alone, no sidecars, exactly what CLAUDE.md's migration-check
            // workflow invites. A read-only connection cannot create the -shm a
            // WAL-mode database needs, so before the fix this failed outright.
            let coldPath = try copyDatabase(from: dbPath, into: dir, named: "cold", withWAL: false)
            expect(!FileManager.default.fileExists(atPath: coldPath + "-shm"),
                   "the copied fixture has no -shm (the #105 condition)")
            expect(!FileManager.default.fileExists(atPath: coldPath + "-wal"),
                   "the copied fixture has no -wal either")

            let readonly = try openDatabase(coldPath, readonly: true)
            expectEqual(try readonly.scalar("SELECT COUNT(*) FROM t") as? Int64, 2,
                        "a read-only open reads a WAL database with no -shm present")
            expectEqual(try readonly.scalar("PRAGMA journal_mode") as? String, "wal",
                        "the read-only open leaves journal_mode unchanged")
            expectEqual(try readonly.scalar("SELECT v FROM t WHERE id = 2") as? String, "two",
                        "no row was modified by the escalation")

            // --- A database copied with a hot -wal but no -shm. `immutable=1`
            // silently drops the WAL here, so this asserts against the
            // stale-data failure mode, not just against the open failing. ---
            let live = try openDatabase(dbPath)
            for i in 3...12 {
                try live.run("INSERT INTO t (id, v) VALUES (?, ?)", i, "row-\(i)")
            }
            let hotPath = try withExtendedLifetime(live) {
                try copyDatabase(from: dbPath, into: dir, named: "hot", withWAL: true)
            }
            let walBytes = FileManager.default.contents(atPath: hotPath + "-wal")?.count ?? 0
            expect(walBytes > 0, "the copied fixture actually carries WAL content")
            expect(!FileManager.default.fileExists(atPath: hotPath + "-shm"),
                   "the hot-WAL fixture has no -shm")
            let hotReader = try openDatabase(hotPath, readonly: true)
            expectEqual(try hotReader.scalar("SELECT COUNT(*) FROM t") as? Int64, 12,
                        "WAL content is recovered, not silently ignored, on a copy with no -shm")

            // --- A non-WAL database is unaffected. ---
            let deletePath = dir.appendingPathComponent("delete-mode.db").path
            do {
                let writer = try openDatabase(deletePath)
                try writer.execute("CREATE TABLE t (id INTEGER PRIMARY KEY)")
                try writer.run("INSERT INTO t (id) VALUES (7)")
            }
            let deleteReader = try openDatabase(deletePath, readonly: true)
            expectEqual(try deleteReader.scalar("SELECT COUNT(*) FROM t") as? Int64, 1,
                        "a journal_mode=delete database still opens read-only")

            // --- No read path may create a database: a typo'd --db must error. ---
            let typoPath = dir.appendingPathComponent("typo.db").path
            var opened = true
            do {
                _ = try openDatabase(typoPath, readonly: true)
            } catch {
                opened = false
            }
            expect(!opened, "a read-only open of a missing database throws")
            expect(!FileManager.default.fileExists(atPath: typoPath),
                   "a read-only open never creates the database (no SQLITE_OPEN_CREATE)")

            // --- The missing-database message names the path actually given. ---
            let missing = AccountSync.SyncError.databaseMissing(typoPath).localizedDescription
            expect(missing.contains(typoPath),
                   "SyncError.databaseMissing reports the given path, got: \(missing)")
        } catch {
            checks += 1
            failures.append("WAL read-only open test threw: \(error)")
        }
    }

    /// Copies a database into a fresh subdirectory of `dir` the way `cp` does —
    /// the database file plus, optionally, its `-wal`, and **never** the `-shm`.
    /// Returns the copy's path.
    private static func copyDatabase(
        from dbPath: String, into dir: URL, named name: String, withWAL: Bool
    ) throws -> String {
        let target = dir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let copyPath = target.appendingPathComponent("usage.db").path
        try FileManager.default.copyItem(atPath: dbPath, toPath: copyPath)
        if withWAL, FileManager.default.fileExists(atPath: dbPath + "-wal") {
            try FileManager.default.copyItem(atPath: dbPath + "-wal", toPath: copyPath + "-wal")
        }
        return copyPath
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
            expect(!tableColumns(legacy, "accounts").contains("codex_home"),
                   "fixture must start without the codex_home column")

            // --- What launching the current build does. ---
            let store = UsageStore(dbPath: dbPath)
            store.ensureDatabase()

            let db = try openDatabase(dbPath, readonly: true)
            expect(tableColumns(db, "accounts").contains("provider"),
                   "migration adds accounts.provider")
            expect(tableColumns(db, "accounts").contains("codex_home"),
                   "migration adds accounts.codex_home")
            // Nullable with no DEFAULT: an existing row must keep meaning "the
            // ambient home", which is exactly its pre-migration behaviour.
            expect((try db.scalar("SELECT codex_home FROM accounts WHERE id = 'org-legacy'")) == nil,
                   "an existing account is left with codex_home NULL — the ambient home, as before")
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

    /// Decode a captured `/backend-api/wham/usage` body and report what the
    /// shared model made of it. This is the offline half of live verification:
    /// capture the body once (`curl -H "Authorization: Bearer …"`), then re-run
    /// this whenever the client changes, with no credential in the loop.
    ///
    /// **Only derived numbers are printed.** The account key is truncated and
    /// the email is reported as present/absent, never echoed — the same
    /// discipline `OpenAIUsageResponse.flatten` applies to the archive.
    private static func testCapturedOpenAIWireBody(at path: String) {
        guard let data = FileManager.default.contents(atPath: path) else {
            checks += 1
            failures.append("--wire: could not read \(path)")
            return
        }
        do {
            let snapshot = try OpenAIAPIClient.snapshot(from: data, httpStatus: 200)
            let windows = snapshot.rateLimit

            expect(!snapshot.accountKey.isEmpty, "--wire: response carried an account key")
            expect(!windows.isEmpty, "--wire: response carried at least one rate-limit window")
            expect(windows.session == nil || windows.session?.kind == .session,
                   "--wire: the session slot holds a session-length window")
            expect(windows.weekly == nil || windows.weekly?.kind == .weekly,
                   "--wire: the weekly slot holds a weekly-length window")
            let serialized = snapshot.rawFields.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
            if let email = snapshot.email, !email.isEmpty {
                expect(!serialized.contains(email), "--wire: the live email never reaches the archive")
            }

            func describe(_ window: RateLimitWindow?) -> String {
                guard let window = window else { return "none" }
                let reset = window.resetAt.map { ISO8601DateFormatter().string(from: $0) } ?? "unknown"
                return String(format: "%.0f%% used, %.0fs window, resets %@",
                              window.usedPercent, window.durationSeconds ?? 0, reset)
            }
            print("""
                selftest --wire: \(path)
                  account:  \(snapshot.accountKey.prefix(8))… (email \(snapshot.email?.isEmpty == false ? "present" : "absent"))
                  plan:     \(snapshot.plan ?? "unknown")
                  status:   \(windows.overallStatus ?? "unknown")
                  session:  \(describe(windows.session))
                  weekly:   \(describe(windows.weekly))
                  headroom: \(windows.headroomScore.map { String(format: "%.0f", $0) } ?? "—")
                  named:    \(windows.named.keys.sorted().joined(separator: ", "))
                  archived: \(snapshot.rawFields.count) field(s), PII redacted
                """)
        } catch {
            checks += 1
            failures.append("--wire: could not map \(path) onto the shared model: \(error)")
        }
    }

    // MARK: - ranking.json

    /// `ranking.json` must carry `provider` for every account, and an OpenAI
    /// account with no session window must omit `utilization["5h"]` rather than
    /// report 0.0 (which a consumer would read as "full session capacity").
    ///
    /// Runs against an explicit scratch database *and* an explicit scratch
    /// output path — never the `$HOME`-relative defaults.
    private static func testRankingExportCarriesProvider() {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("claude-monitor-selftest-ranking-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let dbPath = dir.appendingPathComponent("usage.db").path
            let outPath = dir.appendingPathComponent("ranking.json").path

            UsageStore(dbPath: dbPath).ensureDatabase()
            let db = try openDatabase(dbPath)
            let now = ISO8601DateFormatter().string(from: Date())

            try db.run("""
                INSERT INTO accounts (id, account_name, email, plan, last_updated, sort_order, provider)
                VALUES ('org-anthropic', 'a@example.com', 'a@example.com', 'Max', ?, 0, 'anthropic')
            """, now)
            try db.run("""
                INSERT INTO accounts (id, account_name, email, plan, last_updated, sort_order, provider)
                VALUES ('acct-openai', 'o@example.com', 'o@example.com', 'pro', ?, 1, 'openai')
            """, now)
            try db.run("""
                INSERT INTO usage_history
                    (account_id, timestamp, primary_percent, session_percent,
                     weekly_all_percent, weekly_sonnet_percent, raw_data, is_synthetic)
                VALUES ('org-anthropic', ?, 40, 40, 12, 0,
                        '{"overall_status":"allowed","session_status":"allowed","weekly_status":"allowed"}', 0)
            """, now)
            // The OpenAI shape: NULL session_percent, because the provider
            // reported no session window at all.
            try db.run("""
                INSERT INTO usage_history
                    (account_id, timestamp, primary_percent, session_percent,
                     weekly_all_percent, weekly_sonnet_percent, raw_data, is_synthetic)
                VALUES ('acct-openai', ?, 14, NULL, 14, 0,
                        '{"overall_status":"allowed","weekly_status":"allowed"}', 0)
            """, now)

            RankingExporter.exportNow(dbPath: dbPath, outputPath: outPath)

            guard let data = FileManager.default.contents(atPath: outPath),
                  let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let accounts = root["accounts"] as? [[String: Any]] else {
                checks += 1
                failures.append("ranking export produced no readable accounts array")
                return
            }

            expectEqual(root["schema"] as? Int, RankingExporter.schemaVersion,
                        "provider is additive — the schema version does not change")
            expectEqual(accounts.count, 2, "both accounts exported")

            let byEmail = Dictionary(uniqueKeysWithValues: accounts.compactMap { obj -> (String, [String: Any])? in
                guard let email = obj["email"] as? String else { return nil }
                return (email, obj)
            })

            expectEqual(byEmail["a@example.com"]?["provider"] as? String, "anthropic",
                        "Anthropic account carries provider")
            expectEqual(byEmail["o@example.com"]?["provider"] as? String, "openai",
                        "OpenAI account carries provider")

            // Every field an existing consumer already reads is unchanged.
            expectEqual(byEmail["a@example.com"]?["status"] as? String, "available",
                        "existing status field unaffected")
            let anthropicUtil = byEmail["a@example.com"]?["utilization"] as? [String: Any]
            expectEqual(anthropicUtil?["5h"] as? Double, 0.4, "Anthropic 5h utilization unchanged")
            expectEqual(anthropicUtil?["7d"] as? Double, 0.12, "Anthropic 7d utilization unchanged")

            let openaiUtil = byEmail["o@example.com"]?["utilization"] as? [String: Any]
            expect(openaiUtil?["5h"] == nil,
                   "a provider with no session window omits 5h rather than reporting 0.0")
            expectEqual(openaiUtil?["7d"] as? Double, 0.14, "OpenAI weekly utilization exported")

            // No secret ever reaches ranking.json.
            let text = String(data: data, encoding: .utf8) ?? ""
            expect(!text.contains("access_token") && !text.contains("refresh_token"),
                   "ranking.json never carries credential material")
        } catch {
            checks += 1
            failures.append("ranking export test threw: \(error)")
        }
    }

    /// `--codex`: run the real handshake against the installed Codex CLI once.
    ///
    /// Opt-in, exactly like `--db` and `--wire`: every other check in this suite
    /// is offline, so CI never needs `codex` installed. This is the on-demand
    /// way to re-verify the live wire contract after a Codex release — the
    /// fixtures above are a 2026-08-15 capture and can drift.
    ///
    /// Prints only derived numbers. The email `account/read` returns is never
    /// echoed; only whether one was present.
    private static func testLiveCodexAppServer() {
        let client = CodexAppServerClient()
        guard client.isAvailable else {
            checks += 1
            failures.append("--codex: no codex binary found (set CLAUDE_MONITOR_CODEX_BIN)")
            return
        }

        switch runBlocking({ try await client.fetchUsage() }) {
        case .success(let snapshot):
            let windows = snapshot.rateLimit
            expect(!windows.isEmpty, "--codex: the live reading carried at least one window")
            expect(snapshot.rawFields.values.allSatisfy { !$0.contains("@") },
                   "--codex: no address-shaped value reached the archive")
            let session = windows.session.map { "\(Int($0.usedPercent))%" } ?? "—"
            let weekly = windows.weekly.map { "\(Int($0.usedPercent))%" } ?? "—"
            print("""
                selftest --codex: session \(session), weekly \(weekly) \
                (\(windows.overallStatus ?? "?")), plan \(snapshot.plan ?? "?"), \
                email present: \(snapshot.email != nil), \
                weekly window: \(windows.weekly?.durationSeconds.map { "\(Int($0))s" } ?? "—"), \
                sub-limits: \(windows.named.count), archived fields: \(snapshot.rawFields.count)
                """)
        case .failure(let error):
            checks += 1
            failures.append("--codex: live handshake failed: \(error.localizedDescription)")
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
            expect(tableColumns(db, "accounts").contains("codex_home"),
                   "--db: migration added accounts.codex_home")
            // Every pre-existing row keeps the ambient home. A real database
            // may legitimately have registrations already, so this asserts that
            // the migration itself invented none — count only, never a path.
            expectEqual(try db.scalar(
                "SELECT COUNT(*) FROM accounts WHERE codex_home IS NOT NULL AND COALESCE(provider, 'anthropic') != 'openai'"
            ) as? Int64, 0, "--db: migration registered no home on a non-OpenAI account")

            expectEqual(store.accounts.count, accountsBefore, "--db: account count unchanged by migration")
            // #112: a real host DB can legitimately carry `openai` rows (any
            // account registered since multi-provider support landed), so
            // asserting everything backfilled to `anthropic` is over-strict
            // and fails on exactly that host. The real migration invariant is
            // that every account resolves to a *known* provider — nothing
            // left NULL/empty/unrecognized. `AccountProvider(stored:)` maps
            // unknown strings to `.anthropic` (see RateLimitWindow.swift), so
            // decoding through it can't distinguish "stored anthropic" from
            // "stored garbage" — read the raw column instead, same shape as
            // the `stray` check below.
            let unrecognized = try db.scalar(
                "SELECT COUNT(*) FROM accounts WHERE provider IS NOT NULL AND TRIM(provider) != '' " +
                "AND LOWER(TRIM(provider)) NOT IN ('anthropic', 'openai')"
            ) as? Int64
            expectEqual(unrecognized, 0, "--db: every account resolves to a known provider")
            for account in store.accounts {
                expectEqual(headroomScore(store.latestUsage[account.id]),
                            scoresBefore[account.id] ?? nil,
                            "--db: headroom for \(account.id) unchanged by migration")
            }
            let stray = try db.scalar(
                "SELECT COUNT(*) FROM accounts WHERE provider IS NULL OR TRIM(provider) = ''"
            ) as? Int64
            expectEqual(stray, 0, "--db: no account left without a provider")
            // #106: the healing purge must have cleared any credential row
            // stranded by a pre-fix account removal. Count only — a real
            // database's ids, labels, emails, and tokens are never printed.
            expectEqual(try orphanedCredentialCount(db), 0,
                        "--db: no orphaned credential rows left after migration")
            // #117: same check for the probe_snapshots/named_limits orphans
            // #106 fixed the root cause of but deliberately left unpurged.
            // Count only, same as above.
            expectEqual(try orphanedAccountRowCount(db, table: "probe_snapshots"), 0,
                        "--db: no orphaned probe_snapshots rows left after migration")
            expectEqual(try orphanedAccountRowCount(db, table: "named_limits"), 0,
                        "--db: no orphaned named_limits rows left after migration")
            print("selftest --db: migrated \(store.accounts.count) account(s) at \(path)")
        } catch {
            checks += 1
            failures.append("--db migration check threw: \(error)")
        }
    }
}
