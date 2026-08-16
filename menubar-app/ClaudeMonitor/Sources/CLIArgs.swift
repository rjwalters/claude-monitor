import Foundation

/// Shared argument-parsing helpers for the one-shot subcommand CLIs
/// (`CodexCLI`, `AccountSyncCLI`). Every subcommand handler in both files
/// hand-rolls a `while i < args.count { switch args[i] { ... } }` loop, and
/// two option cases were byte-identical everywhere they appeared: `--db
/// <path>` and `--help`/`-h`, plus the `fail(_:) -> Never` used to report
/// every other parse error. This file is the one place those live now, so a
/// fix to either applies everywhere instead of needing N synchronized edits
/// (#176).
///
/// Not an actor/class — a plain `enum` namespace of static functions, same as
/// `NaturalSort`/`PercentSeverity`. No isolation to worry about: every
/// function here is either pure or, for `fail`, touches only stderr/`exit`,
/// so it is safe to call from both the `@MainActor` `CodexCLI` and the
/// non-isolated `AccountSyncCLI`.
enum CLIArgs {
    /// Prints `Error: <message>` to stderr and exits 1 — the shared failure
    /// path for a malformed CLI invocation. Previously duplicated verbatim as
    /// a `private static func` in both `CodexCLI` and `AccountSyncCLI`.
    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("Error: \(message)\n".utf8))
        exit(1)
    }

    /// The value following a value-taking option at `args[i]` (e.g. `args[i]
    /// == "--db"`, so the value is `args[i + 1]`), or `fail()` with a
    /// consistently-worded message if the option is the last argument. Does
    /// not mutate `i` — callers advance it exactly as they did before this
    /// helper existed (one extra `i += 1` inside the matched case, then the
    /// loop's own trailing `i += 1`), so call-site control flow is unchanged.
    static func requireValue(_ args: [String], _ i: Int, option: String) -> String {
        guard i + 1 < args.count else { fail("\(option) requires a path") }
        return args[i + 1]
    }

    /// Outcome of matching one of the CLI-wide common options at `args[i]`.
    /// `.db` carries the already-validated path value; `.help` tells the
    /// caller to print its own usage and exit 0; `.notMatched` tells the
    /// caller to fall through to its command-specific option switch.
    enum CommonOption {
        case db(String)
        case help
        case notMatched
    }

    /// Matches `--db <path>` / `--help`/`-h` at `args[i]` — the two option
    /// cases every subcommand handler previously spelled out itself. Callers
    /// try this first in their argument loop and only fall through to their
    /// own switch on `.notMatched`:
    ///
    /// ```swift
    /// switch CLIArgs.matchCommon(args, i) {
    /// case .db(let value):
    ///     dbPath = value
    ///     i += 1
    /// case .help:
    ///     printUsage()
    ///     exit(0)
    /// case .notMatched:
    ///     switch args[i] {
    ///     // command-specific options
    ///     }
    /// }
    /// i += 1
    /// ```
    static func matchCommon(_ args: [String], _ i: Int) -> CommonOption {
        switch args[i] {
        case "--db":
            return .db(requireValue(args, i, option: "--db"))
        case "--help", "-h":
            return .help
        default:
            return .notMatched
        }
    }
}
