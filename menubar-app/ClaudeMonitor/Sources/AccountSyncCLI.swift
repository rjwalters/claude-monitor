import Foundation

/// `claude-monitor accounts export|import|push|pull` — the CLI surface for
/// `AccountSync` (issue #16) and its ssh fan-out (#188). Reachable directly on
/// both macOS and Linux without requiring `--headless` or any GUI code, so it
/// works on headless Loom hosts.
enum AccountSyncCLI {
    /// `args` is everything after the `accounts` subcommand itself.
    static func main(_ args: [String]) -> Never {
        guard let sub = args.first else {
            printUsage()
            exit(2)
        }

        switch sub {
        case "export":
            runExport(Array(args.dropFirst()))
        case "import":
            runImport(Array(args.dropFirst()))
        case "push":
            runRemote(Array(args.dropFirst()), verb: .push)
        case "pull":
            runRemote(Array(args.dropFirst()), verb: .pull)
        case "--help", "-h", "help":
            printUsage()
            exit(0)
        default:
            FileHandle.standardError.write(Data("Unknown 'accounts' subcommand '\(sub)'\n\n".utf8))
            printUsage()
            exit(2)
        }
    }

    // MARK: - export

    private static func runExport(_ args: [String]) -> Never {
        var outputPath: String?
        var pretty = true
        var dbPath = AccountSync.defaultDBPath

        var i = 0
        while i < args.count {
            switch CLIArgs.matchCommon(args, i) {
            case .db(let value):
                dbPath = value
                i += 1
            case .help:
                printUsage()
                exit(0)
            case .notMatched:
                switch args[i] {
                case "--output", "-o":
                    outputPath = CLIArgs.requireValue(args, i, option: "--output")
                    i += 1
                case "--compact":
                    pretty = false
                default:
                    CLIArgs.fail("Unknown option '\(args[i])' (see --help)")
                }
            }
            i += 1
        }

        do {
            let data = try AccountSync.exportJSON(pretty: pretty, dbPath: dbPath)

            FileHandle.standardError.write(Data("""
                WARNING: this export contains OAuth access/refresh tokens in \
                plaintext. Treat it as a credential: keep it off shared/world- \
                readable storage, transfer it over a trusted channel, and \
                delete it once the import completes.

                Codex/OpenAI accounts are host-local and intentionally \
                excluded from this export — register one on each host with \
                `claude-monitor codex add --home <path>` instead of syncing \
                a credential between machines.

                """.utf8))

            if let outputPath = outputPath {
                try data.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: outputPath)
                FileHandle.standardError.write(Data("Wrote \(data.count) bytes to \(outputPath) (mode 0600).\n".utf8))
            } else {
                FileHandle.standardError.write(Data("Writing to stdout — shell redirection does NOT set safe file permissions; run `chmod 600` on the result, or pass --output <path> instead.\n".utf8))
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write(Data("\n".utf8))
            }
            exit(0)
        } catch {
            CLIArgs.fail("Export failed: \(error.localizedDescription)")
        }
    }

    // MARK: - import

    private static func runImport(_ args: [String]) -> Never {
        var path: String?
        var dryRun = false
        var dbPath = AccountSync.defaultDBPath

        var i = 0
        while i < args.count {
            switch CLIArgs.matchCommon(args, i) {
            case .db(let value):
                dbPath = value
                i += 1
            case .help:
                printUsage()
                exit(0)
            case .notMatched:
                switch args[i] {
                case "--dry-run":
                    dryRun = true
                default:
                    if path == nil, !args[i].hasPrefix("-") || args[i] == "-" {
                        path = args[i]
                    } else {
                        CLIArgs.fail("Unknown option '\(args[i])' (see --help)")
                    }
                }
            }
            i += 1
        }

        guard let path = path else {
            CLIArgs.fail("import requires a file path (or '-' for stdin)")
        }

        let data: Data
        do {
            data = (path == "-")
                ? FileHandle.standardInput.readDataToEndOfFile()
                : try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            CLIArgs.fail("Could not read '\(path)': \(error.localizedDescription)")
        }

        let bundle: AccountSync.ExportBundle
        do {
            bundle = try JSONDecoder().decode(AccountSync.ExportBundle.self, from: data)
        } catch {
            CLIArgs.fail("Could not parse import file as an accounts bundle: \(error.localizedDescription)")
        }

        if dryRun {
            print("Dry run: \(bundle.accounts.count) account(s) in bundle from '\(bundle.sourceHost)' (exported \(bundle.exportedAt)). No changes made.")
            exit(0)
        }

        do {
            let summary = try AccountSync.importBundle(bundle, dbPath: dbPath)
            for outcome in summary.outcomes {
                print("\(outcome.email ?? outcome.id): \(outcome.action.rawValue)")
            }
            print("Done: \(summary.created) created, \(summary.updated) updated, \(summary.skipped) skipped (local record was newer or equal), \(summary.excluded) excluded (host-local Codex/OpenAI account).")
            exit(0)
        } catch {
            CLIArgs.fail("Import failed: \(error.localizedDescription)")
        }
    }

    // MARK: - push / pull

    /// Both ssh verbs share one handler: they differ only in which direction
    /// the bundle travels, and `AccountSyncRemote` already owns that
    /// difference. Nothing is written to disk on either side — see
    /// `AccountSyncRemote`'s file comment.
    private static func runRemote(_ args: [String], verb: AccountSyncRemote.Verb) -> Never {
        let options: AccountSyncRemote.Options
        do {
            options = try AccountSyncRemote.parseArgs(args, verb: verb)
        } catch let error as AccountSyncRemote.ArgError {
            CLIArgs.fail(error.message)
        } catch {
            CLIArgs.fail("\(error.localizedDescription)")
        }

        if options.wantsHelp {
            printUsage()
            exit(0)
        }

        switch verb {
        case .push:
            exit(AccountSyncRemote.runPush(options))
        case .pull:
            exit(AccountSyncRemote.runPull(options))
        }
    }

    private static func printUsage() {
        print("""
            claude-monitor accounts — converge account records + OAuth
            credentials across hosts (see README "Multi-Host Sync").

            Usage:
              claude-monitor accounts push <HOST...> [--dry-run] [--then-loom]
                                          [--remote-bin <path>] [--ssh-option <opt>] [--db <path>]
              claude-monitor accounts pull <HOST> [--dry-run] [--then-loom]
                                          [--remote-bin <path>] [--ssh-option <opt>] [--db <path>]
              claude-monitor accounts export [--output <path>] [--compact] [--db <path>]
              claude-monitor accounts import <path|-> [--dry-run] [--db <path>]

            push is the primary path: it exports this host's bundle in memory
            and streams it over ssh straight into `accounts import -` on each
            HOST. No file containing tokens is created on either side, and
            there is nothing to remember to delete. Every HOST is attempted
            even if an earlier one fails; the exit status is non-zero if any
            host failed.

            pull is the same channel in reverse, for a fresh host bootstrapping
            from a peer: it runs `accounts export` on HOST and imports the
            result here. Exactly one HOST.

            --dry-run (push and pull) only checks that each host is reachable
              and that claude-monitor resolves there, reporting its version.
              No bundle is transferred and nothing is written anywhere.
            --then-loom runs `loom-daemon tokens import-from-monitor --shared`
              on whichever host received the bundle, after a successful import
              (the remote host for push, this one for pull).
            --remote-bin <path> names claude-monitor on the far side. Worth
              reaching for first on a "command not found" (exit 127): a
              non-interactive ssh shell does not source the profile that puts
              ~/.local/bin on PATH.
            --ssh-option <opt> is appended to the ssh command line (repeatable),
              e.g. --ssh-option -p --ssh-option 2222. ssh runs with
              BatchMode=yes, so key/agent authentication is required.

            export writes an accounts.json bundle (account records + OAuth
            credentials) to stdout by default, or to --output <path> (written
            with 0600 permissions). The bundle contains plaintext OAuth
            tokens — treat it as a secret. Codex/OpenAI accounts are
            host-local and are never included — register one on each host
            with `claude-monitor codex add --home <path>` instead.

            import upserts accounts by email (falling back to id when email
            is absent), skipping any account whose local last_updated is
            newer than or equal to the imported record — safe to re-run.
            A Codex/OpenAI account present in a bundle from an older version
            is skipped (not an error); it never round-tripped safely.
            Reads from stdin when the path is '-'. Creates
            ~/.claude-monitor/usage.db (and its schema) when the host has
            none yet, so a fresh worker can be converged before it has ever
            polled.

            --db <path> overrides ~/.claude-monitor/usage.db (mainly for
            testing/scripting against an alternate database).
            """)
    }
}
