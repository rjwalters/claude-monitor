import Foundation

/// Headless poll loop — the AppDelegate cycle without any UI. This is the whole
/// app on Linux (Loom hosts); on macOS it's reachable via `ClaudeMonitor
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
            print("claude-monitor \(AppVersion.current)")
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
        flog.info("claude-monitor headless v\(AppVersion.current) starting (poll interval \(Int(poller.pollInterval))s\(once ? ", single cycle" : ""))", category: "Headless")
        store.ensureDatabase()

        var filesStamp = accountFilesStamp()
        let results = await poller.syncFromAccountFiles()
        if !results.isEmpty {
            let ok = results.filter { $0.success }.count
            flog.info("Imported \(ok)/\(results.count) account(s) from account list files", category: "Headless")
        }

        await poller.pollAll()
        _ = await poller.probeFableDue()
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
            flog.warning("No accounts configured — add ~/.claude-monitor/accounts.env (ACCOUNT_EMAIL_N/ACCOUNT_KEY_N pairs)", category: "Headless")
            return
        }
        let parts = store.sortedAccountsForPopover.map { account -> String in
            let label = "[\(account.provider.shortCode)] \(account.displayName)"
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
        let home = FileManager.default.homeDirectoryForCurrentUser
        return ["accounts.env", "accounts.local.env"].map { name -> String in
            let path = home.appendingPathComponent(".claude-monitor/\(name)").path
            let attrs = try? FileManager.default.attributesOfItem(atPath: path)
            let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            return "\(name):\(mtime)"
        }.joined(separator: ";")
    }

    private static let usage = """
        claude-monitor headless — polls account usage and writes
        ~/.claude-monitor/usage.db and ~/.claude-monitor/ranking.json.

        Usage: ClaudeMonitor [--headless] [options]
          (on Linux the binary is always headless; --headless is implied)

        Options:
          --once              Run one full poll cycle, export ranking.json, exit
          --interval <sec>    Per-account poll interval in seconds (default 600, min 60)
          --version           Print version and exit
          --help              Show this help

        Accounts are read from ~/.claude-monitor/accounts.env and
        accounts.local.env (ACCOUNT_EMAIL_N / ACCOUNT_KEY_N pairs); edits are
        picked up automatically while running.

        For multi-host sync of account records + credentials, see:
          claude-monitor accounts --help

        Subcommands:
          accounts            Export/import accounts + credentials
          codex               Import an OpenAI/Codex credential from
                              ~/.codex/auth.json (honors $CODEX_HOME)
          selftest            Run portable-core assertions (no network, no
                              credentials; exits non-zero on failure)
        """
}
