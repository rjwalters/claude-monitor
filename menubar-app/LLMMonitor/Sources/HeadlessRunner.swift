import Foundation

/// Headless poll loop — the AppDelegate cycle without any UI. This is the whole
/// app on Linux (Loom hosts); on macOS it's reachable via `LLMMonitor
/// --headless` for testing. Same behavior as the menubar app: import accounts
/// from the account list files, ping each account on a 10-minute cadence, probe
/// the Fable tier on a 20-minute cadence, and emit ranking.json after each
/// round of polls. Additionally re-imports the account list files whenever
/// their mtime changes, since a daemon has no "relaunch to pick up new
/// accounts" moment.
// `main()` bridges its synchronous entry to `dispatchMain()` pumping the
// process's initial thread, and every call into `UsageStore`/`OAuthPoller`
// happens either directly there or from the single `Task` it spawns — the
// same main-thread caller those two classes are isolated to.
@MainActor
enum HeadlessRunner {
    private static let flog = FileLogger.shared
    private static let tickSeconds: UInt64 = 30

    static func main() -> Never {
        let args = CommandLine.arguments

        if args.contains("--help") || args.contains("-h") {
            print(usage)
            exit(0)
        }
        if args.contains("--version") {
            print("llm-monitor \(AppVersion.current)")
            exit(0)
        }

        let once = args.contains("--once")

        var pollInterval: TimeInterval? = nil
        if let idx = args.firstIndex(of: "--interval") {
            guard idx + 1 < args.count, let seconds = TimeInterval(args[idx + 1]), seconds >= 60 else {
                FileHandle.standardError.write(Data("--interval requires a number of seconds (min 60)\n".utf8))
                exit(2)
            }
            pollInterval = seconds
        }

        flog.echoToStdout = true

        let store = UsageStore()
        let poller = OAuthPoller()
        if let pollInterval = pollInterval {
            poller.pollInterval = pollInterval
        }
        // Tell the store the actual poll cadence so its staleness threshold
        // (#148) scales with `--interval` instead of assuming the default —
        // a slower configured interval must not produce false staleness.
        store.pollIntervalHint = poller.pollInterval

        Task {
            await run(store: store, poller: poller, once: once)
            exit(0)
        }
        dispatchMain()
    }

    private static func run(store: UsageStore, poller: OAuthPoller, once: Bool) async {
        flog.info("llm-monitor headless v\(AppVersion.current) starting (poll interval \(Int(poller.pollInterval))s\(once ? ", single cycle" : ""))", category: "Headless")
        store.ensureDatabase()

        var filesStamp = accountFilesStamp()
        let results = await poller.syncFromAccountFiles()
        if !results.isEmpty {
            let ok = results.filter { $0.success }.count
            flog.info("Imported \(ok)/\(results.count) account(s) from account list files", category: "Headless")
        }

        await poller.pollAll()
        _ = await poller.probeFableDue()
        // Transcript token ingest (#197) runs on its own, much slower cadence
        // (see `OAuthPoller.tokenSyncInterval`); this first call is what makes
        // `--once` do a useful slice of the backfill too.
        _ = await poller.syncTranscriptTokensIfDue()
        // Quota calibration (#198) is derived from the two series above, on the
        // same slow cadence. Runs after the ingest so a `--once` invocation
        // calibrates against the tokens it just imported.
        _ = await poller.recomputeQuotaCalibrationIfDue()
        RankingExporter.exportNow()
        logSummary(store: store)

        if once { return }

        while true {
            try? await Task.sleep(nanoseconds: tickSeconds * 1_000_000_000)

            // Pick up edits to accounts.env / accounts.local.env without a restart.
            let stamp = accountFilesStamp()
            if stamp != filesStamp {
                filesStamp = stamp
                flog.info("Account list files changed — re-importing", category: "Headless")
                _ = await poller.syncFromAccountFiles()
            }

            let polled = await poller.pollDue()
            let probed = await poller.probeFableDue()
            // Self-throttling: a no-op on most ticks, one transcript scan per
            // `tokenSyncInterval`. Its result deliberately does not gate the
            // ranking export below — token ingest feeds the history tables,
            // not the live quota figures ranking.json publishes.
            _ = await poller.syncTranscriptTokensIfDue()
            _ = await poller.recomputeQuotaCalibrationIfDue()
            if polled > 0 || probed > 0 {
                RankingExporter.exportNow()
                logSummary(store: store)
            }
        }
    }

    /// One log line per cycle so journald shows live state without the popover.
    private static func logSummary(store: UsageStore) {
        store.loadFromDatabase()
        guard !store.accounts.isEmpty else {
            flog.warning("No accounts configured — add ~/.llm-monitor/accounts.env (ACCOUNT_EMAIL_N/ACCOUNT_KEY_N pairs)", category: "Headless")
            return
        }
        let parts = store.sortedAccountsForPopover.map { account -> String in
            let label = "[\(account.provider.shortCode)] \(account.displayName)"
            // A declared-but-unprovisioned identity (#135) is named, not
            // scored: a bare "?" here would read as "we failed to poll it",
            // when in fact there is nothing on this host to poll.
            if account.isAbsent { return "\(label): \(CodexCLI.absentLabel)" }
            // Read through the shared window model: an account whose provider
            // reports only a weekly window shows that figure rather than a
            // fabricated 0% session.
            guard let windows = store.latestUsage[account.id]?.rateLimit,
                  let used = [windows.session?.usedPercent, windows.weekly?.usedPercent]
                      .compactMap({ $0 }).max() else {
                return "\(label): ?"
            }
            return "\(label): \(Int(used))%"
        }
        flog.info("Usage — " + parts.joined(separator: ", "), category: "Headless")
    }

    /// Concatenated mtimes of the account list files; changes when either is edited.
    private static func accountFilesStamp() -> String {
        return ["accounts.env", "accounts.local.env"].map { name -> String in
            let path = AppPaths.path(name)
            let attrs = try? FileManager.default.attributesOfItem(atPath: path)
            let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            return "\(name):\(mtime)"
        }.joined(separator: ";")
    }

    private static let usage = """
        llm-monitor headless — polls account usage and writes
        ~/.llm-monitor/usage.db and ~/.llm-monitor/ranking.json.

        Usage: llm-monitor [--headless] [options]
          (on Linux the binary is always headless; --headless is implied)

        Options:
          --once              Run one full poll cycle, export ranking.json, exit
          --interval <sec>    Per-account poll interval in seconds (default 600, min 60)
          --version           Print version and exit
          --help              Show this help

        Accounts are read from ~/.llm-monitor/accounts.env and
        accounts.local.env (ACCOUNT_EMAIL_N / ACCOUNT_KEY_N pairs); edits are
        picked up automatically while running.

        For multi-host sync of account records + credentials, see:
          llm-monitor accounts --help

        Subcommands:
          accounts            Export/import accounts + credentials
          tokens              Import Claude Code transcript token counters into
                              token_sessions/token_usage (`tokens sync`); also
                              runs automatically on a slow cadence
          calibrate           Daily quota-calibration series (tokens and cost
                              per weekly rate-limit point) as JSON or CSV on
                              stdout; also recomputed on a slow cadence
          codex               Manage OpenAI/Codex accounts by their CODEX_HOME
                              (provision|add|list|import; no credential is
                              stored — codex itself is asked for usage)
          zai                 Register z.ai GLM Coding Plan keys from ~/.zai and
                              show their 5h/weekly quota (import|add|list)
          selftest            Run portable-core assertions (no network, no
                              credentials; exits non-zero on failure)
        """
}
