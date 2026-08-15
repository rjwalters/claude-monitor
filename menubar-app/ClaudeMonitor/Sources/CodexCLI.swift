import Foundation

/// `claude-monitor codex` — manage OpenAI/ChatGPT (Codex) accounts.
///
/// - `codex add --home <path>` registers an account **by its `CODEX_HOME`**,
///   storing no token at all. This is the path that makes more than one Codex
///   account possible: `codex login` writes a single `auth.json` per home, so
///   each login overwrites the previous account's credential unless the homes
///   are kept separate.
/// - `codex list` shows every registered account, its home, and whether that
///   home is currently logged in.
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
            print("ACCOUNT   PLAN        AUTH           CODEX_HOME")
            for account in accounts {
                let status = await authStatus(for: account.codexHome)
                let plan = (account.plan ?? "—").padded(to: 11)
                let home = account.codexHome ?? "(default: $CODEX_HOME, else ~/.codex)"
                print("\(account.accountId.prefix(8))… \(plan) \(status.padded(to: 14)) \(home)")
            }
            print("")
            print("`needs login` → run: CODEX_HOME=<home> codex login --device-auth")
            exit(0)
        }
        dispatchMain()
    }

    /// Whether one home is currently logged in, as `account/read` sees it.
    ///
    /// Keyed on `account == null`, never on `requiresOpenaiAuth` — that flag is
    /// `true` even on a logged-in home.
    private static func authStatus(for home: String?) async -> String {
        do {
            _ = try await CodexAppServerClient(codexHome: home).fetchAccountIdentity()
            return "logged in"
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
              claude-monitor codex add --home <path> [--db <path>]
              claude-monitor codex list [--db <path>]
              claude-monitor codex import [--auth <path>] [--db <path>]

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
