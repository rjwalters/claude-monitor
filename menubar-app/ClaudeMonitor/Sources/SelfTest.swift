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
        testSchemaMigrationFromPreMigrationDatabase()
        testRankingExportCarriesProvider()
        testNamedLimitsRoundTrip()
        testOpenAIImportResolvesExistingAccountByEmail()
        testAccountSyncImportIsProviderScoped()
        testMergeDuplicateAccountsSharingEmail()

        if let idx = arguments.firstIndex(of: "--db"), idx + 1 < arguments.count {
            testMigrationOfExistingDatabase(at: arguments[idx + 1])
        }

        if let idx = arguments.firstIndex(of: "--wire"), idx + 1 < arguments.count {
            testCapturedOpenAIWireBody(at: arguments[idx + 1])
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

    /// OpenAI access tokens expire (~10 days) and `auth.json` states no expiry,
    /// so the token's own `exp` claim is the only source. Only `exp` is read.
    private static func testOpenAITokenExpiryParsing() {
        func b64url(_ json: String) -> String {
            Data(json.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
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

            func b64url(_ json: String) -> String {
                Data(json.utf8).base64EncodedString()
                    .replacingOccurrences(of: "+", with: "-")
                    .replacingOccurrences(of: "/", with: "_")
                    .replacingOccurrences(of: "=", with: "")
            }
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

    // MARK: - AccountSync provider scoping

    /// A multi-host `accounts import` whose bundle carries an OpenAI account
    /// must never land on an Anthropic row that shares the email. An unscoped
    /// email match flips the Claude row's provider and overwrites its
    /// credential in place — destroying the Claude token (this happened).
    private static func testAccountSyncImportIsProviderScoped() {
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

            let bundle = AccountSync.ExportBundle(
                formatVersion: AccountSync.formatVersion,
                exportedAt: "2026-07-01T00:00:00Z",
                sourceHost: "selftest",
                accounts: [AccountSync.ExportedAccount(
                    id: "user-native-openai",
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
                )]
            )
            let summary = try AccountSync.importBundle(bundle, dbPath: dbPath)
            expectEqual(summary.created, 1, "the OpenAI account is created as its own row")

            let claudeProvider = try db.scalar(
                "SELECT provider FROM accounts WHERE id = 'claude-org-uuid'") as? String
            expectEqual(claudeProvider, "anthropic",
                        "the Anthropic row sharing the email keeps its provider")
            let claudeToken = try db.scalar(
                "SELECT access_token FROM oauth_credentials WHERE account_id = 'claude-org-uuid'") as? String
            expectEqual(claudeToken, "sk-ant-claude-token",
                        "the Claude credential is not overwritten by the OpenAI import")
            let openaiRow = try db.scalar(
                "SELECT id FROM accounts WHERE email = 'me@example.com' AND provider = 'openai'") as? String
            expectEqual(openaiRow, "user-native-openai",
                        "the OpenAI account lands under its own id")

            // Same-provider re-import must still match by email and update in
            // place (the multi-host convergence contract), not fork a row.
            var again = bundle
            again.accounts[0].id = "user-native-openai-renamed"
            again.accounts[0].lastUpdated = "2026-07-02T00:00:00Z"
            let summary2 = try AccountSync.importBundle(again, dbPath: dbPath)
            expectEqual(summary2.updated, 1, "same-provider re-import updates the existing row")
            let openaiCount = try db.scalar(
                "SELECT COUNT(*) FROM accounts WHERE email = 'me@example.com' AND provider = 'openai'") as? Int64
            expectEqual(openaiCount, 1, "same-provider re-import does not fork a second row")
        } catch {
            checks += 1
            failures.append("account sync provider scoping test threw: \(error)")
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
            expectEqual(
                try db.scalar("SELECT access_token FROM oauth_credentials WHERE account_id = ?", nativeId) as? String,
                "legacy-fresher-token",
                "the more recently renewed credential wins, reassigned to the survivor")

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
