import Foundation

/// `llm-monitor tokens sync` — the one-shot CLI over `TranscriptImporter`
/// (#197). Like `accounts` and `codex`, it is reachable on both macOS and
/// Linux without `--headless` and without any GUI code, so a headless Loom
/// host can backfill its transcript token history on demand instead of
/// waiting for the poll loop's slower cadence.
///
/// Prints counts only. The transcript root is echoed with the home directory
/// collapsed to `~` (a transcript path names a user and their projects), and
/// no message content is ever read into a printable value — see
/// `TranscriptImporter`'s privacy note.
enum TokensCLI {
    /// `args` is everything after the `tokens` subcommand itself.
    static func main(_ args: [String]) -> Never {
        guard let sub = args.first else {
            printUsage()
            exit(2)
        }

        switch sub {
        case "sync":
            runSync(Array(args.dropFirst()))
        case "--help", "-h", "help":
            printUsage()
            exit(0)
        default:
            FileHandle.standardError.write(Data("Unknown 'tokens' subcommand '\(sub)'\n\n".utf8))
            printUsage()
            exit(2)
        }
    }

    private static func runSync(_ args: [String]) -> Never {
        var dbPath = TranscriptImporter.defaultDBPath
        var root: String?
        var fileBudget = TranscriptImporter.defaultFileBudget

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
                case "--root":
                    root = CLIArgs.requireValue(args, i, option: "--root")
                    i += 1
                case "--limit":
                    let raw = CLIArgs.requireValue(args, i, option: "--limit")
                    guard let value = Int(raw), value >= 0 else {
                        CLIArgs.fail("--limit requires a non-negative number of files")
                    }
                    fileBudget = value
                    i += 1
                case "--all":
                    // A full backfill: no per-run file cap. Deliberately opt-in
                    // — a cold host has a five-figure transcript backlog and
                    // reading all of it takes minutes.
                    fileBudget = 0
                default:
                    CLIArgs.fail("Unknown option '\(args[i])' (see --help)")
                }
            }
            i += 1
        }

        let resolvedRoot = root ?? TranscriptImporter.defaultTranscriptRoot()
        print("Scanning \(TranscriptImporter.redactPath(resolvedRoot))"
            + (fileBudget > 0 ? " (up to \(fileBudget) file(s) this run)" : " (no file limit)"))

        do {
            let stats = try TranscriptImporter.sync(dbPath: dbPath, root: resolvedRoot, fileBudget: fileBudget)
            print(stats.summary)
            if stats.filesDeferred > 0 {
                print("\(stats.filesDeferred) file(s) deferred to a later run — "
                    + "re-run `llm-monitor tokens sync` (or pass --all) to continue the backfill.")
            }
            exit(0)
        } catch {
            CLIArgs.fail("\(error)")
        }
    }

    private static func printUsage() {
        print("""
            llm-monitor tokens — import Claude Code transcript token counters
            into the token_sessions / token_usage tables of usage.db.

            Usage:
              llm-monitor tokens sync [--root <dir>] [--limit <n> | --all] [--db <path>]

            Options:
              --root <dir>   Transcript tree to scan
                             (default: $LLM_MONITOR_TRANSCRIPT_ROOT, else
                             $CLAUDE_CONFIG_DIR/projects, else ~/.claude/projects)
              --limit <n>    Maximum transcripts to open this run
                             (default \(TranscriptImporter.defaultFileBudget); newest first)
              --all          No per-run limit — full backfill, may take minutes
              --db <path>    Database to write (default ~/.llm-monitor/usage.db)
              --help, -h     Show this help

            The scan is incremental: a transcript is opened only when its mtime
            is newer than the stamp recorded for it, so a re-run over an
            unchanged tree reads nothing. Imports are idempotent — each record
            is keyed by its message uuid.

            Only per-message counters, the model name, the uuid and the
            timestamp are stored. Message content is never read into the
            database or the log.
            """)
    }
}
