import Foundation

/// `claude-monitor codex import` — bring an OpenAI/ChatGPT (Codex) credential
/// into the app from Codex CLI's own credential store.
///
/// A one-shot CLI operation like `accounts export|import`: no `--headless`
/// flag, no GUI, identical on macOS and Linux, so a headless Loom host can add
/// an OpenAI account with `codex login && claude-monitor codex import`.
///
/// Nothing here ever prints a token or an email address; the account is
/// identified in output by the first 8 characters of its OpenAI `account_id`.
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
        case "--help", "-h", "help":
            printUsage()
            exit(0)
        default:
            FileHandle.standardError.write(Data("Unknown 'codex' subcommand '\(sub)'\n\n".utf8))
            printUsage()
            exit(2)
        }
    }

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

        // The import validates the credential against the live usage endpoint,
        // so the database must exist before the account row is written.
        let store = UsageStore(dbPath: dbPath)
        store.ensureDatabase()

        let poller = OAuthPoller(dbPath: dbPath)
        let semaphore = DispatchSemaphore(value: 0)
        var result: (accountId: String?, error: String?) = (nil, nil)

        Task {
            result = await poller.importCodexCredential(path: resolved)
            semaphore.signal()
        }
        semaphore.wait()

        if let accountId = result.accountId {
            print("Imported OpenAI account \(accountId.prefix(8))… from \(resolved)")
            if let dbPath = dbPath {
                // Keep a scratch run entirely inside the scratch directory —
                // never overwrite the real ranking.json from a test import.
                RankingExporter.exportNow(
                    dbPath: dbPath,
                    outputPath: (dbPath as NSString).deletingLastPathComponent + "/ranking.json"
                )
            } else {
                RankingExporter.exportNow()
            }
            exit(0)
        }
        fail(result.error ?? "Import failed")
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("Error: \(message)\n".utf8))
        exit(1)
    }

    private static func printUsage() {
        print("""
            claude-monitor codex — import an OpenAI/ChatGPT (Codex) credential
            so its usage is polled alongside Anthropic accounts.

            Usage:
              claude-monitor codex import [--auth <path>] [--db <path>]

            Reads Codex CLI's credential store — $CODEX_HOME/auth.json when
            CODEX_HOME is set, otherwise ~/.codex/auth.json — validates it
            against the ChatGPT usage endpoint, and stores the account plus its
            access/refresh tokens and expiry. Run `codex login` first if the
            file doesn't exist yet.

            OpenAI access tokens live about 10 days. The poller renews them
            proactively from the stored refresh token; if renewal ever fails,
            the account's token dot turns yellow (still valid, renewal failing)
            or red (expired) rather than silently going stale. Re-running this
            command re-imports a fresh credential.

            --auth <path> reads an alternate auth.json, and --db <path>
            overrides ~/.claude-monitor/usage.db (writing ranking.json beside
            it) — both mainly for testing the import end to end without
            touching the real store.
            """)
    }
}
