import Foundation

/// `claude-monitor accounts export|import` — the CLI surface for `AccountSync`
/// (issue #16). Reachable directly on both macOS and Linux without requiring
/// `--headless` or any GUI code, so it works on headless Loom hosts.
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

    private static func printUsage() {
        print("""
            claude-monitor accounts — export/import account records + OAuth
            credentials for multi-host sync (see README "Multi-Host Sync").

            Usage:
              claude-monitor accounts export [--output <path>] [--compact] [--db <path>]
              claude-monitor accounts import <path|-> [--dry-run] [--db <path>]

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
            Reads from stdin when the path is '-'.

            --db <path> overrides ~/.claude-monitor/usage.db (mainly for
            testing/scripting against an alternate database).
            """)
    }
}
