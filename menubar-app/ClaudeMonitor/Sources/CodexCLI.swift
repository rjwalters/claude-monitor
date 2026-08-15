import Foundation

/// `claude-monitor codex` — manage OpenAI/ChatGPT (Codex) accounts.
///
/// - `codex add --home <path>` registers an account **by its `CODEX_HOME`**,
///   storing no token at all. This is the path that makes more than one Codex
///   account possible: `codex login` writes a single `auth.json` per home, so
///   each login overwrites the previous account's credential unless the homes
///   are kept separate.
/// - `codex list` shows every registered account, its home, and whether that
///   home is currently logged in — including **drift**, a registered home that
///   has since been logged in as a *different* account. That is the visible
///   face of the poller's own identity guard (`OAuthPoller.codexHomeDrift`),
///   whose refusal to attribute such a reading is otherwise silent.
/// - `codex import` brings a credential in from Codex CLI's own store — the
///   original path, still supported.
///
/// One-shot CLI operations like `accounts export|import`: no `--headless` flag,
/// no GUI, identical on macOS and Linux, so a headless Loom host can add an
/// OpenAI account with `CODEX_HOME=… codex login --device-auth` followed by
/// `claude-monitor codex add --home …`.
///
/// Nothing here ever prints a token or an email address; accounts are
/// identified in output by the first 8 characters of their OpenAI account id.
/// A home path *is* printed — that is the whole point of `list`, it is what the
/// user typed, and it never reaches `debug.log` or any exported artifact.
// The whole CLI runs synchronously to completion on the process's initial
// thread (see the `dispatchMain()` bridges below) before it ever calls
// `exit()`, so it is the actual main-thread caller `UsageStore` /
// `OAuthPoller` are isolated to — @MainActor makes that explicit rather than
// implicit.
@MainActor
enum CodexCLI {
    /// `args` is everything after the `codex` subcommand itself.
    static func main(_ args: [String]) -> Never {
        guard let sub = args.first else {
            printUsage()
            exit(2)
        }

        switch sub {
        case "import":
            runImport(Array(args.dropFirst()))
        case "add":
            runAdd(Array(args.dropFirst()))
        case "list":
            runList(Array(args.dropFirst()))
        case "provision":
            runProvision(Array(args.dropFirst()))
        case "--help", "-h", "help":
            printUsage()
            exit(0)
        default:
            FileHandle.standardError.write(Data("Unknown 'codex' subcommand '\(sub)'\n\n".utf8))
            printUsage()
            exit(2)
        }
    }

    // MARK: - codex add

    private static func runAdd(_ args: [String]) -> Never {
        var home: String?
        var dbPath: String?

        var i = 0
        while i < args.count {
            switch args[i] {
            case "--home":
                guard i + 1 < args.count else { fail("--home requires a path") }
                home = args[i + 1]
                i += 1
            case "--db":
                guard i + 1 < args.count else { fail("--db requires a path") }
                dbPath = args[i + 1]
                i += 1
            case "--help", "-h":
                printUsage()
                exit(0)
            default:
                fail("Unknown option '\(args[i])' (see --help)")
            }
            i += 1
        }

        guard let rawHome = home else {
            fail("codex add requires --home <path> (e.g. --home ~/.codex-work)")
        }

        // Frozen into immutable bindings before the Task: strict concurrency
        // rejects referencing a captured `var` from concurrently-executing code.
        let storePath = dbPath
        let resolvedHome = OAuthPoller.normalizeCodexHome(rawHome)

        let store = UsageStore(dbPath: storePath)
        store.ensureDatabase()

        let poller = OAuthPoller(dbPath: storePath)

        Task {
            let result = await poller.registerCodexHome(resolvedHome)
            guard let accountId = result.accountId else {
                fail(result.error ?? "Registration failed")
            }
            print("Registered OpenAI account \(accountId.prefix(8))… at CODEX_HOME=\(resolvedHome)")
            print("No token was read, copied, or stored — usage is read through `codex` itself.")
            if let warning = result.error {
                FileHandle.standardError.write(Data("Warning: \(warning)\n".utf8))
            }
            exportRanking(storePath)
            exit(0)
        }
        dispatchMain()
    }

    // MARK: - codex provision

    /// Parsed, validated arguments for `codex provision`. A plain value type
    /// with no I/O so the self-test can exercise every error path without
    /// spawning a process or touching `exit()`.
    struct ProvisionArgs: Equatable {
        let label: String
        let dbPath: String?
    }

    /// Argument-parsing failures for `codex provision`, kept distinct from
    /// the message string so the self-test can assert on the *kind* of
    /// failure rather than fragile prose matching.
    enum ProvisionArgError: Error, Equatable {
        case missingLabel
        case labelContainsSlash(String)
        case unknownOption(String)
        case extraArgument(String)
        case missingValue(String)
    }

    /// Pure parser for `codex provision <label> [--db <path>]` — no I/O, no
    /// `exit()`, no process spawn, so the self-test can drive every error
    /// path (missing label, unknown option, a label that would escape
    /// `~/.codex-<label>`) directly. `--help`/`-h` is handled by the caller,
    /// same as `runAdd`/`runList`/`runImport`, since printing usage and
    /// exiting isn't something a pure function should do.
    static func parseProvisionArgs(_ args: [String]) throws -> ProvisionArgs {
        var label: String?
        var dbPath: String?

        var i = 0
        while i < args.count {
            let arg = args[i]
            switch arg {
            case "--db":
                guard i + 1 < args.count else { throw ProvisionArgError.missingValue("--db") }
                dbPath = args[i + 1]
                i += 1
            default:
                if arg.hasPrefix("-") {
                    throw ProvisionArgError.unknownOption(arg)
                } else if label == nil {
                    label = arg
                } else {
                    throw ProvisionArgError.extraArgument(arg)
                }
            }
            i += 1
        }

        guard let rawLabel = label?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawLabel.isEmpty else {
            throw ProvisionArgError.missingLabel
        }
        // The label becomes the literal suffix of `~/.codex-<label>` — a '/'
        // would escape that directory (e.g. "../../etc").
        guard !rawLabel.contains("/") else {
            throw ProvisionArgError.labelContainsSlash(rawLabel)
        }
        return ProvisionArgs(label: rawLabel, dbPath: dbPath)
    }

    private static func provisionArgErrorMessage(for error: Error) -> String {
        switch error as? ProvisionArgError {
        case .missingLabel:
            return "codex provision requires a <label> (e.g. `codex provision work`)"
        case .labelContainsSlash(let label):
            return "<label> must not contain '/' — got '\(label)' (it becomes the suffix of ~/.codex-<label>)"
        case .unknownOption(let opt):
            return "Unknown option '\(opt)' (see --help)"
        case .extraArgument(let arg):
            return "Unexpected extra argument '\(arg)' — codex provision takes exactly one <label> (see --help)"
        case .missingValue(let opt):
            return "\(opt) requires a path"
        case .none:
            return "Invalid arguments (see --help)"
        }
    }

    /// Whether provisioning `home` would silently repoint an
    /// already-registered identity to a different one.
    ///
    /// `existingAccountId` is the account already registered against this
    /// exact `CODEX_HOME` in the local DB, if any; `observedNativeId` is
    /// `auth.json`'s `tokens.account_id` after the login step (fresh or
    /// skipped because the home was already logged in). Returns a diagnostic
    /// message only when **both** are known and disagree — nil covers every
    /// other case: first-time provisioning of a fresh home, a home whose
    /// `auth.json` carries no account id yet, and the idempotent re-run path
    /// where the observed identity matches what was already registered.
    static func provisionIdentityConflict(
        label: String, home: String, existingAccountId: String?, observedNativeId: String?
    ) -> String? {
        guard let existingAccountId, let observedNativeId, existingAccountId != observedNativeId else {
            return nil
        }
        return """
            CODEX_HOME=\(home) (label '\(label)') is already registered to account \
            \(existingAccountId.prefix(8))…, but is now logged in as a different account \
            (\(observedNativeId.prefix(8))…). Log out and log back in with the identity you \
            intended for '\(label)', or provision a different <label> for this login.
            """
    }

    /// Runs `codex login --device-auth` against `home`, inheriting the
    /// caller's stdio so the operator sees the device code and any prompts
    /// directly — device-auth is inherently interactive, and this is the one
    /// place `provision` orchestrates around it rather than automating it.
    ///
    /// Called from the `Task` in `runProvision`, which — because `CodexCLI`
    /// is `@MainActor` and this closure inherits that isolation — runs on
    /// the main thread, exactly where `Process.waitUntilExit()` must be
    /// called (see CLAUDE.md: calling it off the main thread hangs).
    private static func runDeviceAuthLogin(codexBin: String, home: String) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: codexBin)
        process.arguments = ["login", "--device-auth"]
        var env = ProcessInfo.processInfo.environment
        env["CODEX_HOME"] = home
        process.environment = env
        process.standardInput = FileHandle.standardInput
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        do {
            try process.run()
        } catch {
            fail("Could not launch `codex login --device-auth`: \(error.localizedDescription)")
        }
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// Collapses "pick a home, log in, register it" into one command per
    /// identity per host (#133, decomposed from #130).
    ///
    /// Reuses `OAuthPoller.registerCodexHome`/`normalizeCodexHome` for the
    /// home-naming and registration steps — the same calls `codex add
    /// --home` makes — rather than reimplementing either.
    private static func runProvision(_ args: [String]) -> Never {
        if args.contains("--help") || args.contains("-h") {
            printUsage()
            exit(0)
        }

        let parsed: ProvisionArgs
        do {
            parsed = try parseProvisionArgs(args)
        } catch {
            fail(provisionArgErrorMessage(for: error))
        }

        guard let codexBin = CodexBinary.resolve() else {
            fail("Codex CLI not found — install `@openai/codex`, or set CLAUDE_MONITOR_CODEX_BIN (see --help)")
        }

        let storePath = parsed.dbPath
        let label = parsed.label
        let resolvedHome = OAuthPoller.normalizeCodexHome("~/.codex-\(label)")

        // Idempotent by construction: `withIntermediateDirectories: true`
        // does not throw when the directory already exists.
        do {
            try FileManager.default.createDirectory(
                atPath: resolvedHome, withIntermediateDirectories: true
            )
        } catch {
            fail("Could not create CODEX_HOME at \(resolvedHome): \(error.localizedDescription)")
        }

        let store = UsageStore(dbPath: storePath)
        store.ensureDatabase()
        let poller = OAuthPoller(dbPath: storePath)

        Task {
            let existingAccountId = poller.codexAccounts()
                .first { $0.codexHome == resolvedHome }?.accountId

            var alreadyLoggedIn = false
            do {
                _ = try await CodexAppServerClient(codexHome: resolvedHome).fetchAccountIdentity()
                alreadyLoggedIn = true
            } catch {
                // Not logged in, an old/unresponsive codex, or a transient
                // hiccup — attempt login rather than guess; logging in
                // against an already-logged-in home is harmless.
                alreadyLoggedIn = false
            }

            if alreadyLoggedIn {
                print("CODEX_HOME=\(resolvedHome) is already logged in — skipping `codex login --device-auth`.")
            } else {
                print("Provisioning CODEX_HOME=\(resolvedHome) for label '\(label)'.")
                print("Launching `codex login --device-auth` — follow the printed instructions to finish in a browser.")
                let status = runDeviceAuthLogin(codexBin: codexBin, home: resolvedHome)
                guard status == 0 else {
                    fail("`codex login --device-auth` exited with status \(status) — provisioning aborted, nothing was registered")
                }
            }

            let observedNativeId = CodexAuth.accountId(inHome: resolvedHome)
            if let conflict = provisionIdentityConflict(
                label: label, home: resolvedHome,
                existingAccountId: existingAccountId, observedNativeId: observedNativeId
            ) {
                fail(conflict)
            }

            let result = await poller.registerCodexHome(resolvedHome)
            guard let accountId = result.accountId else {
                fail(result.error ?? "Registration failed")
            }
            print("Registered OpenAI account \(accountId.prefix(8))… at CODEX_HOME=\(resolvedHome)")
            print("No token was read, copied, or stored — usage is read through `codex` itself.")
            if let warning = result.error {
                FileHandle.standardError.write(Data("Warning: \(warning)\n".utf8))
            }
            exportRanking(storePath)
            exit(0)
        }
        dispatchMain()
    }

    // MARK: - codex list

    private static func runList(_ args: [String]) -> Never {
        var dbPath: String?

        var i = 0
        while i < args.count {
            switch args[i] {
            case "--db":
                guard i + 1 < args.count else { fail("--db requires a path") }
                dbPath = args[i + 1]
                i += 1
            case "--help", "-h":
                printUsage()
                exit(0)
            default:
                fail("Unknown option '\(args[i])' (see --help)")
            }
            i += 1
        }

        let storePath = dbPath
        let store = UsageStore(dbPath: storePath)
        store.ensureDatabase()
        let poller = OAuthPoller(dbPath: storePath)
        let accounts = poller.codexAccounts()

        guard !accounts.isEmpty else {
            print("No OpenAI (Codex) accounts registered. Add one with:")
            print("  CODEX_HOME=~/.codex-<label> codex login --device-auth")
            print("  claude-monitor codex add --home ~/.codex-<label>")
            exit(0)
        }

        Task {
            var sawDrift = false
            print("ACCOUNT   PLAN        AUTH               CODEX_HOME")
            for account in accounts {
                let status = await authStatus(for: account)
                if status.hasPrefix(driftLabel) { sawDrift = true }
                let plan = (account.plan ?? "—").padded(to: 11)
                let home = account.codexHome ?? "(default: $CODEX_HOME, else ~/.codex)"
                print("\(account.accountId.prefix(8))… \(plan) \(status.padded(to: 18)) \(home)")
            }
            print("")
            print("`needs login` → run: CODEX_HOME=<home> codex login --device-auth")
            if sawDrift {
                print("`\(driftLabel)` → this CODEX_HOME is now logged in as a different account than the")
                print("          row it is registered against, so its usage is not attributed to that")
                print("          row. Either log the home back in as the original account, or re-run")
                print("          `claude-monitor codex add --home <home>` to register it as its own.")
            }
            exit(0)
        }
        dispatchMain()
    }

    /// The status word for a home whose identity no longer matches its row.
    /// Shared by the row and the footnote so they cannot drift apart.
    private static let driftLabel = "drift"

    /// How one registered account's home currently reads.
    ///
    /// Login state comes from `account/read` and is keyed on `account == null`,
    /// never on `requiresOpenaiAuth` — that flag is `true` even on a logged-in
    /// home. A home that answers *is* logged in, so drift is only ever reported
    /// in place of `logged in`: a logged-out home stays `needs login`, and a
    /// deleted one stays `home missing`, neither of which is drift.
    private static func authStatus(for account: OAuthPoller.CodexAccountRegistration) async -> String {
        do {
            let identity = try await CodexAppServerClient(codexHome: account.codexHome)
                .fetchAccountIdentity()
            return driftStatus(for: account, reportedEmail: identity.email) ?? "logged in"
        } catch let error as CodexAppServerError {
            switch error {
            case .notLoggedIn: return "needs login"
            case .homeMissing: return "home missing"
            case .binaryNotFound: return "unknown (no codex)"
            case .methodUnsupported: return "unknown (old codex)"
            default: return "unknown"
            }
        } catch {
            return "unknown"
        }
    }

    /// The drift status for a logged-in home, or `nil` when nothing
    /// contradicts the registration.
    ///
    /// Only a **registered** home is checked. An account with no home of its
    /// own reads the ambient one, which the poller already declines to let
    /// speak for it on a multi-account host (`resolveCodexHome` →
    /// `.ambiguous`); calling that "drift" would report a mismatch between a
    /// row and a home that was never claimed to be its own.
    ///
    /// The decision itself is `OAuthPoller.codexHomeDrift` — the same
    /// comparison the poller's attribution gate reads, so what is printed here
    /// and what the poller silently refuses to attribute cannot disagree. This
    /// function only does the two reads and formats the answer; the account id
    /// is truncated to 8 characters like every other identifier this CLI
    /// prints, and an email is never printed.
    private static func driftStatus(
        for account: OAuthPoller.CodexAccountRegistration,
        reportedEmail: String?
    ) -> String? {
        guard let home = account.codexHome else { return nil }
        switch OAuthPoller.codexHomeDrift(
            registeredAccountId: account.accountId,
            registeredEmail: account.email,
            homeAccountId: CodexAuth.accountId(inHome: home),
            homeEmail: reportedEmail
        ) {
        case .stable:
            return nil
        case .drifted(let reportedAccountId):
            guard let reported = reportedAccountId else { return driftLabel }
            return "\(driftLabel) → \(reported.prefix(8))…"
        }
    }

    // MARK: - codex import

    private static func runImport(_ args: [String]) -> Never {
        var authPath: String?
        var dbPath: String?

        var i = 0
        while i < args.count {
            switch args[i] {
            case "--auth":
                guard i + 1 < args.count else { fail("--auth requires a path") }
                authPath = args[i + 1]
                i += 1
            case "--db":
                guard i + 1 < args.count else { fail("--db requires a path") }
                dbPath = args[i + 1]
                i += 1
            case "--help", "-h":
                printUsage()
                exit(0)
            default:
                fail("Unknown option '\(args[i])' (see --help)")
            }
            i += 1
        }

        let resolved = authPath ?? CodexAuth.defaultAuthPath
        guard FileManager.default.fileExists(atPath: resolved) else {
            fail("No Codex credential at \(resolved) — run `codex login` first, or pass --auth <path>")
        }

        // Freeze the parsed option into an immutable binding: everything the
        // Task below touches must be a `let`. Strict concurrency checking
        // rejects both mutating *and* merely referencing a captured `var` from
        // concurrently-executing code, and the Xcode toolchain on CI's macOS
        // runner enforces that as an error where newer ones only warn.
        let storePath = dbPath

        // The import validates the credential against the live usage endpoint,
        // so the database must exist before the account row is written.
        let store = UsageStore(dbPath: storePath)
        store.ensureDatabase()

        let poller = OAuthPoller(dbPath: storePath)

        // Bridge sync → async the way HeadlessRunner does: the whole
        // continuation lives inside the Task, which ends the process itself,
        // so no value is handed back across the concurrency boundary.
        Task {
            let result = await poller.importCodexCredential(path: resolved)
            guard let accountId = result.accountId else {
                fail(result.error ?? "Import failed")
            }
            print("Imported OpenAI account \(accountId.prefix(8))… from \(resolved)")
            exportRanking(storePath)
            exit(0)
        }
        dispatchMain()
    }

    // MARK: - Shared helpers

    /// Keep a scratch run entirely inside the scratch directory — never
    /// overwrite the real ranking.json from a test import/registration.
    private static func exportRanking(_ storePath: String?) {
        if let storePath = storePath {
            RankingExporter.exportNow(
                dbPath: storePath,
                outputPath: (storePath as NSString).deletingLastPathComponent + "/ranking.json"
            )
        } else {
            RankingExporter.exportNow()
        }
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("Error: \(message)\n".utf8))
        exit(1)
    }

    private static func printUsage() {
        print("""
            claude-monitor codex — manage OpenAI/ChatGPT (Codex) accounts so
            their usage is polled alongside Anthropic accounts.

            Usage:
              claude-monitor codex provision <label> [--db <path>]
              claude-monitor codex add --home <path> [--db <path>]
              claude-monitor codex list [--db <path>]
              claude-monitor codex import [--auth <path>] [--db <path>]

            provision  Collapse home-create + login + register into one
                    command: creates (or reuses) ~/.codex-<label> as the
                    CODEX_HOME for this identity, drives `codex login
                    --device-auth` against it interactively, and on success
                    registers it exactly as `add --home` does.

                      claude-monitor codex provision work

                    is equivalent to:

                      CODEX_HOME=~/.codex-work codex login --device-auth
                      claude-monitor codex add --home ~/.codex-work

                    `--device-auth` prints a code to paste into a browser on
                    any machine, so this works on a headless Linux host.
                    Re-running for a label that is already logged in skips
                    the login step and just re-registers (idempotent, no
                    duplicate account). Fails if the home is already
                    registered to a different account than the one now
                    logged in there, or if `codex` itself can't be found.

            add     Register an account by its CODEX_HOME. **No token is read,
                    copied, or stored** — usage is read by asking the locally
                    installed `codex` CLI, which keeps the credential itself.

                    Each CODEX_HOME holds exactly one ChatGPT login, so a
                    separate home per account is what makes monitoring more
                    than one Codex account possible at all:

                      CODEX_HOME=~/.codex-work codex login --device-auth
                      claude-monitor codex add --home ~/.codex-work

                    `--device-auth` prints a code to paste into a browser on
                    any machine, so this works on a headless Linux host.

                    Re-running `add` for an account that already exists updates
                    that account's home rather than creating a second row.

            list    Show every registered OpenAI account: its truncated account
                    id, plan, whether its home is currently logged in, and the
                    home itself. An account with no registered home reads the
                    ambient $CODEX_HOME (else ~/.codex) — which is fine as long
                    as it is the only OpenAI account on the host.

            import  Read Codex CLI's credential store — $CODEX_HOME/auth.json
                    when CODEX_HOME is set, otherwise ~/.codex/auth.json —
                    validate it against the ChatGPT usage endpoint, and store
                    the account plus its access/refresh tokens and expiry.

                    Prefer `add`: it stores no credential and therefore cannot
                    go stale or race Codex CLI's own token rotation. `import`
                    remains for hosts without a usable `codex` binary.

                    OpenAI access tokens live about 10 days. The poller renews
                    them proactively from the stored refresh token; if renewal
                    ever fails, the account's token dot turns yellow (still
                    valid, renewal failing) or red (expired). Re-running this
                    command re-imports a fresh credential.

            --db <path> overrides ~/.claude-monitor/usage.db (writing
            ranking.json beside it) — mainly for exercising these commands end
            to end without touching the real store.
            """)
    }
}

private extension String {
    /// Left-aligned, space-padded to `width` — enough table formatting for a
    /// handful of accounts, with no dependency on a formatting library.
    func padded(to width: Int) -> String {
        count >= width ? self : self + String(repeating: " ", count: width - count)
    }
}
