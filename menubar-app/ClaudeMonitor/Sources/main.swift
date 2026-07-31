#if os(macOS)
import SwiftUI

// MARK: - Popover Height Manager

extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        return Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

/// Sizes the popover to hug its content: the window height tracks the number
/// of account rows so there is no empty space below the table. Height is
/// clamped to [minHeight, maxHeight]; when rows would exceed maxHeight the row
/// list scrolls. There is no manual resize — the fit is automatic.
class PopoverHeightManager: ObservableObject {
    static let popoverWidth: CGFloat = 818
    static let minHeight: CGFloat = 200
    static let maxHeight: CGFloat = 800

    /// Fixed chrome around the scrolling row list: header (~50) + column
    /// header (~28) + dividers (~3) + footer (~42).
    static let chromeHeight: CGFloat = 123
    /// Height of a single account row: caption text (~16) + 6pt vertical
    /// padding × 2. Keep in sync with `SummaryRow`'s `.padding(.vertical, 6)`.
    static let rowHeight: CGFloat = 28
    /// Height for the setup/empty/error state (no table rows to size against).
    static let setupHeight: CGFloat = 360

    @Published var currentHeight: CGFloat = PopoverHeightManager.minHeight
    weak var popover: NSPopover?

    /// Content-fitted popover height for `rowCount` account rows, clamped to
    /// [minHeight, maxHeight]. With no rows (setup/empty/error state) a fixed
    /// setup height is used so the guide isn't cramped.
    func fittedHeight(rowCount: Int) -> CGFloat {
        guard rowCount > 0 else { return Self.setupHeight }
        let content = Self.chromeHeight + CGFloat(rowCount) * Self.rowHeight
        return content.clamped(to: Self.minHeight...Self.maxHeight)
    }

    /// Recompute `currentHeight` from the row count and resize the live popover
    /// so the window hugs its content.
    func update(rowCount: Int) {
        let h = fittedHeight(rowCount: rowCount)
        if h != currentHeight { currentHeight = h }
        popover?.contentSize = NSSize(width: Self.popoverWidth, height: h)
    }
}

@main
enum ClaudeMonitorEntry {
    static func main() {
        // `accounts export|import` is a one-shot CLI operation, not a launch
        // mode — route it before the --headless/GUI dispatch so it works
        // without also passing --headless.
        if CommandLine.arguments.dropFirst().first == "accounts" {
            AccountSyncCLI.main(Array(CommandLine.arguments.dropFirst(2)))
        } else if CommandLine.arguments.dropFirst().first == "codex" {
            CodexCLI.main(Array(CommandLine.arguments.dropFirst(2)))
        } else if CommandLine.arguments.dropFirst().first == "selftest" {
            SelfTest.main(Array(CommandLine.arguments.dropFirst(2)))
        } else if CommandLine.arguments.contains("--version") {
            // Dispatched at top level (not just inside HeadlessRunner) so
            // `ClaudeMonitor --version` never falls through to the GUI branch
            // below — see #46.
            print("claude-monitor \(AppVersion.current)")
            exit(0)
        } else if CommandLine.arguments.contains("--headless") {
            HeadlessRunner.main()
        } else if CommandLine.arguments.contains("--once") || CommandLine.arguments.contains("--interval") {
            // These are headless-loop flags handled inside HeadlessRunner; bare
            // (without --headless) they must fail fast rather than silently
            // launching a duplicate GUI instance — see #46.
            FileHandle.standardError.write(Data("--once/--interval require --headless on macOS, e.g. `ClaudeMonitor --headless --once`\n".utf8))
            exit(2)
        } else {
            ClaudeMonitorApp.main()
        }
    }
}

struct ClaudeMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set at launch so windows opened deep in the SwiftUI view tree can reach the
    /// popover to dismiss it. `NSApp.delegate as? AppDelegate` is unreliable under
    /// the SwiftUI @NSApplicationDelegateAdaptor lifecycle, so we hold it directly.
    static weak var shared: AppDelegate?

    var statusItem: NSStatusItem?
    var popover: NSPopover?
    var timer: Timer?
    var usageStore = UsageStore()
    var oauthPoller = OAuthPoller()
    var loginWizardWindow: NSWindow?
    var heightManager: PopoverHeightManager!

    private let flog = FileLogger.shared

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        flog.info("ClaudeMonitor launched (v\(AppVersion.current))", category: "App")

        // Ensure database exists (standalone mode without native host)
        usageStore.ensureDatabase()
        flog.info("Database ready", category: "App")

        // Hide dock icon
        NSApp.setActivationPolicy(.accessory)

        // Variable length so the highlight auto-fits the rendered text
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            // Handle both left and right clicks (M3.2)
            button.action = #selector(statusBarClicked(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            updateStatusButton()
        }
        flog.info("Status item created", category: "App")

        // Update menubar when accounts change (e.g., reordering)
        usageStore.onAccountsChanged = { [weak self] in
            self?.updateStatusButton()
        }

        // Create height manager (auto-fits the popover to its content)
        heightManager = PopoverHeightManager()

        // Create popover
        popover = NSPopover()
        popover?.contentSize = NSSize(width: PopoverHeightManager.popoverWidth, height: heightManager.fittedHeight(rowCount: usageStore.accounts.count))
        // .semitransient keeps the popover open while user interacts with other
        // windows in this app (e.g. multiple chart windows launched from rows).
        popover?.behavior = .semitransient
        popover?.contentViewController = NSHostingController(
            rootView: UsagePopoverView(store: usageStore, oauthPoller: oauthPoller, heightManager: heightManager, onAddAccount: { [weak self] in
                self?.openAddAccountWindow()
            })
        )
        heightManager.popover = popover
        flog.info("Popover ready, starting poll timer", category: "App")

        // Tick every 30s; each account is polled once per 10 min (staggered)
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.refreshDue()
        }

        // Initial load — sync accounts from the master + local list files, then
        // poll all accounts once (staggers their next-poll times).
        syncThenRefreshAll()
    }

    /// Import accounts from ~/.claude-monitor/accounts.env (+ accounts.local.env)
    /// additively, then poll everything. Runs once at launch.
    func syncThenRefreshAll() {
        Task {
            let results = await oauthPoller.syncFromAccountFiles()
            if !results.isEmpty {
                let ok = results.filter { $0.success }.count
                flog.info("syncThenRefreshAll: imported \(ok)/\(results.count) account(s) from list files", category: "App")
            }
            await oauthPoller.pollAll()
            await MainActor.run {
                usageStore.loadFromDatabase()
                updateStatusButton()
                flog.info("syncThenRefreshAll: loaded \(usageStore.accounts.count) account(s)", category: "App")
            }
        }
    }

    /// Poll all accounts (startup and manual refresh)
    func refreshAll() {
        flog.info("refreshAll: polling all accounts", category: "App")
        Task {
            await oauthPoller.pollAll()
            await MainActor.run {
                usageStore.loadFromDatabase()
                updateStatusButton()
                // Emit ~/.claude-monitor/ranking.json for external load balancers (#2)
                RankingExporter.export()
                flog.info("refreshAll: loaded \(usageStore.accounts.count) account(s)", category: "App")
            }
        }
    }

    /// Poll any accounts that are due (called by 30s timer)
    func refreshDue() {
        Task {
            let polled = await oauthPoller.pollDue()
            // Fable-tier probe runs on its own (slower) cadence and writes the
            // premium/overage headers the UI reads.
            let fableProbed = await oauthPoller.probeFableDue()
            if polled > 0 || fableProbed > 0 {
                await MainActor.run {
                    usageStore.loadFromDatabase()
                    updateStatusButton()
                    // Emit ~/.claude-monitor/ranking.json for external load balancers (#2)
                    RankingExporter.export()
                }
            }
        }
    }

    // MARK: - Menubar shows top card (first account)

    func updateStatusButton() {
        guard let button = statusItem?.button else { return }

        var percent: Int = 0
        var isWeeklyLimit = false

        // Menubar follows the user's pinned account, or falls back to most-available.
        let targetAccount = usageStore.accounts.first(where: { $0.id == usageStore.effectivePrimaryAccountId })

        if let account = targetAccount,
           let usage = usageStore.latestUsage[account.id] {
            let sessionPercent = usage.sessionPercent ?? 0
            let weeklyAllPercent = usage.weeklyAllPercent ?? 0
            percent = Int(max(sessionPercent, weeklyAllPercent))
            isWeeklyLimit = weeklyAllPercent >= sessionPercent
        } else if let account = targetAccount {
            percent = Int(account.latestPercent ?? 0)
            isWeeklyLimit = true
        }

        // Create Stats-style image with "LLM" label and percentage
        button.image = createStatsStyleImage(percent: percent, isWeeklyLimit: isWeeklyLimit)
        button.title = ""
    }

    func createStatsStyleImage(percent: Int, isWeeklyLimit: Bool) -> NSImage {
        let labelFont = NSFont.systemFont(ofSize: 7, weight: .light)
        let valueFont = NSFont.systemFont(ofSize: 12, weight: .regular)

        let labelText = "LLM"
        let percentText: String
        if percent > 0 {
            percentText = isWeeklyLimit ? "(\(percent)%)" : "\(percent)%"
        } else {
            percentText = "--"
        }

        let height: CGFloat = 22

        // Measure actual text width so the image (and highlight) fits tightly
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let labelColor: NSColor = isDark ? .white : .textColor

        let valueColor: NSColor
        if percent > 95 {
            valueColor = .systemRed
        } else if percent >= 90 {
            valueColor = .systemOrange
        } else {
            valueColor = isDark ? .white : .black
        }

        let style = NSMutableParagraphStyle()
        style.alignment = .left

        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: labelFont,
            .foregroundColor: labelColor,
            .paragraphStyle: style
        ]
        let valueAttrs: [NSAttributedString.Key: Any] = [
            .font: valueFont,
            .foregroundColor: valueColor,
            .paragraphStyle: style
        ]

        let labelSize = (labelText as NSString).size(withAttributes: labelAttrs)
        let valueSize = (percentText as NSString).size(withAttributes: valueAttrs)
        let blockWidth = max(labelSize.width, valueSize.width)
        // 2pt padding on each side for breathing room
        let width = ceil(blockWidth) + 4

        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
            let xOffset = (width - blockWidth) / 2

            let labelRect = CGRect(x: xOffset, y: 14, width: blockWidth, height: 7)
            let labelStr = NSAttributedString(string: labelText, attributes: labelAttrs)
            labelStr.draw(with: labelRect)

            let valueRect = CGRect(x: xOffset, y: 3, width: blockWidth, height: 13)
            let valueStr = NSAttributedString(string: percentText, attributes: valueAttrs)
            valueStr.draw(with: valueRect)

            return true
        }

        image.isTemplate = false
        return image
    }

    // MARK: - M3.2: Right-click context menu

    @objc func statusBarClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else {
            togglePopover()
            return
        }

        if event.type == .rightMouseUp {
            showContextMenu()
        } else {
            togglePopover()
        }
    }

    private func showContextMenu() {
        let menu = NSMenu()

        // Account list sorted by availability
        for account in usageStore.sortedAccountsForPopover {
            let item = NSMenuItem(
                title: account.displayName,
                action: #selector(selectAccount(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = account.id
            if let usage = usageStore.latestUsage[account.id] {
                let pct = Int(max(usage.sessionPercent ?? 0, usage.weeklyAllPercent ?? 0))
                item.title = "\(account.displayName) (\(pct)%)"
            }
            menu.addItem(item)
        }

        if !usageStore.accounts.isEmpty {
            menu.addItem(.separator())
        }

        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        // Reset menu so left-click still shows popover
        statusItem?.menu = nil
    }

    @objc func selectAccount(_ sender: NSMenuItem) {
        guard let accountId = sender.representedObject as? String,
              let account = usageStore.accounts.first(where: { $0.id == accountId }) else { return }
        ChartWindowController.showChart(for: account, store: usageStore)
    }

    func togglePopover() {
        if let popover = popover {
            if popover.isShown {
                popover.performClose(nil)
            } else if let button = statusItem?.button {
                heightManager.update(rowCount: usageStore.accounts.count)
                refreshAll()
                popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            }
        }
    }

    // MARK: - Add Account Window

    func openAddAccountWindow() {
        flog.info("openAddAccountWindow called", category: "App")

        // Close the popover first, then open window after a delay
        // to avoid AppKit layout crash during popover dismissal
        popover?.performClose(nil)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self = self else { return }

            if let window = self.loginWizardWindow, window.isVisible {
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                return
            }

            let addAccountView = AddAccountView(store: self.usageStore, oauthPoller: self.oauthPoller, onDone: { [weak self] in
                self?.loginWizardWindow?.close()
                self?.loginWizardWindow = nil
            }, onImported: { [weak self] in
                // Poll the freshly-added credentials so credentialStatuses populates
                // (the import only pings — it doesn't update poller status), and the
                // popover sees an up-to-date snapshot when it next opens.
                self?.refreshAll()
            })

            let hostingController = NSHostingController(rootView: addAccountView)
            if #available(macOS 13.0, *) {
                hostingController.sizingOptions = []
            }
            let window = NSWindow(contentViewController: hostingController)
            window.title = "Add Account"
            window.styleMask = [.titled, .closable]
            window.setContentSize(NSSize(width: 360, height: 420))
            window.center()
            window.isReleasedWhenClosed = false
            window.level = .floating
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            self.loginWizardWindow = window

            self.flog.info("Add Account window opened", category: "App")
        }
    }

}

#endif  // os(macOS)
