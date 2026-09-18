import Foundation

/// `claude-monitor calibrate` — recompute and print the daily quota-calibration
/// series (#198).
///
/// Like `accounts`, `codex` and `tokens`, this is a one-shot CLI reachable on
/// both macOS and Linux without `--headless` and without touching any GUI code,
/// so a headless Loom host can hand the series to its own consumer
/// (rjwalters/loom#8063) without the app running.
///
/// The output goes to **stdout** and carries no identity beyond the opaque
/// account ids already present in the database — no email, no path, no token.
/// A database path is only ever echoed through `QuotaCalibration.redactPath`.
enum CalibrationCLI {
    /// `args` is everything after the `calibrate` subcommand itself.
    static func main(_ args: [String]) -> Never {
        var dbPath = QuotaCalibration.defaultDBPath
        var days = QuotaCalibration.defaultWindowDays
        var minPoints = QuotaCalibration.defaultMinPointsForRatio
        var format = OutputFormat.json
        var scope: QuotaCalibration.Scope?
        var recompute = true

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
                case "--days":
                    let raw = CLIArgs.requireValue(args, i, option: "--days")
                    guard let value = Int(raw), value >= 1 else {
                        CLIArgs.fail("--days requires a positive number of days")
                    }
                    days = value
                    i += 1
                case "--min-points":
                    let raw = CLIArgs.requireValue(args, i, option: "--min-points")
                    guard let value = Double(raw), value >= 0 else {
                        CLIArgs.fail("--min-points requires a non-negative number")
                    }
                    minPoints = value
                    i += 1
                case "--format":
                    let raw = CLIArgs.requireValue(args, i, option: "--format")
                    guard let value = OutputFormat(rawValue: raw.lowercased()) else {
                        CLIArgs.fail("--format must be 'json' or 'csv'")
                    }
                    format = value
                    i += 1
                case "--json":
                    format = .json
                case "--csv":
                    format = .csv
                case "--scope":
                    let raw = CLIArgs.requireValue(args, i, option: "--scope").lowercased()
                    if raw == "all" {
                        scope = nil
                    } else if let value = QuotaCalibration.Scope(rawValue: raw) {
                        scope = value
                    } else {
                        CLIArgs.fail("--scope must be 'pool', 'account' or 'all'")
                    }
                    i += 1
                case "--no-recompute":
                    // Read the stored series as-is. For a consumer that polls
                    // frequently and does not want each read to pay for (or
                    // race with) a rewrite of the window.
                    recompute = false
                default:
                    CLIArgs.fail("Unknown option '\(args[i])' (see --help)")
                }
            }
            i += 1
        }

        do {
            if recompute {
                let result = try QuotaCalibration.recompute(
                    dbPath: dbPath, days: days, minPointsForRatio: minPoints)
                // Diagnostics go to stderr so `--format json` stdout stays a
                // single valid document a consumer can pipe straight into jq.
                FileHandle.standardError.write(
                    Data("calibrate: \(result.summary)\n".utf8))
            }
            let rows = try QuotaCalibration.loadSeries(
                dbPath: dbPath, days: days, scope: scope)
            switch format {
            case .json:
                print(try QuotaCalibration.jsonString(
                    rows: rows, windowDays: days, minPointsForRatio: minPoints))
            case .csv:
                // Already newline-terminated.
                FileHandle.standardOutput.write(Data(QuotaCalibration.csv(rows: rows).utf8))
            }
            exit(0)
        } catch {
            CLIArgs.fail("\(error)")
        }
    }

    enum OutputFormat: String {
        case json
        case csv
    }

    private static func printUsage() {
        print("""
            claude-monitor calibrate — daily quota-calibration series: what one
            weekly rate-limit point costs, per UTC day, pool-wide and per account.

            Usage:
              claude-monitor calibrate [--days <n>] [--format json|csv]
                                       [--scope pool|account|all] [--min-points <p>]
                                       [--no-recompute] [--db <path>]

            Options:
              --days <n>        Trailing window, in UTC days, including today
                                (default \(QuotaCalibration.defaultWindowDays))
              --format <fmt>    json (default) or csv; --json/--csv are shorthands
              --scope <scope>   pool, account, or all (default)
              --min-points <p>  Minimum points accumulated in a day before a
                                per-point ratio is reported at all
                                (default \(QuotaCalibration.defaultMinPointsForRatio))
              --no-recompute    Print the stored series without recomputing first
              --db <path>       Database to read/write (default ~/.claude-monitor/usage.db)
              --help, -h        Show this help

            The window is recomputed from the source series on every run and the
            whole trailing window is rewritten, so repeated runs are idempotent
            rather than accumulating drift.

            An unknown value is an OMITTED JSON key (or an empty CSV field) —
            never 0. A day with fewer than --min-points accumulated points keeps
            its point count but reports no per-point ratio, because one weekly
            point is the measurement quantum and a smaller denominator produces
            a precise-looking number that is not.

            Per-account token attribution is written only where an explicit
            session -> account mapping exists (token_sessions.override_account_id,
            inherited by subagent transcripts through parent_session_id). There is
            deliberately no fallback to "whichever account polled most recently".
            """)
    }
}
