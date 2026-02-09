import SwiftUI

@main
struct ClaudeMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var popover: NSPopover?
    var timer: Timer?
    var usageStore = UsageStore()
    var oauthPoller = OAuthPoller()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Ensure database exists (standalone mode without native host)
        usageStore.ensureDatabase()

        // Hide dock icon
        NSApp.setActivationPolicy(.accessory)

        // Create status bar item with fixed width for consistent layout
        // Width accommodates parentheses for weekly limit display: (XX%)
        statusItem = NSStatusBar.system.statusItem(withLength: 45)

        if let button = statusItem?.button {
            // Handle both left and right clicks (M3.2)
            button.action = #selector(statusBarClicked(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            updateStatusButton()
        }

        // Update menubar when accounts change (e.g., reordering)
        usageStore.onAccountsChanged = { [weak self] in
            self?.updateStatusButton()
        }

        // Create popover
        popover = NSPopover()
        popover?.contentSize = NSSize(width: 320, height: 400)
        popover?.behavior = .transient
        popover?.contentViewController = NSHostingController(
            rootView: UsagePopoverView(store: usageStore, oauthPoller: oauthPoller)
        )

        // Start polling for updates
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.refreshData()
        }

        // Initial load
        refreshData()
    }

    func refreshData() {
        Task {
            await oauthPoller.pollAll()
            await MainActor.run {
                usageStore.loadFromDatabase()
                updateStatusButton()
            }
        }
    }

    // MARK: - M3.4: Show selected (primary) account in menubar

    func updateStatusButton() {
        guard let button = statusItem?.button else { return }

        var percent: Int = 0
        var isWeeklyLimit = false

        // Use primaryAccountId if set, otherwise fall back to first account (M3.4)
        let targetAccount: Account?
        if let primaryId = usageStore.primaryAccountId {
            targetAccount = usageStore.accounts.first(where: { $0.id == primaryId })
        } else {
            targetAccount = usageStore.accounts.first
        }

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

        let width: CGFloat = 40
        let height: CGFloat = 22

        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
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

        // Account list with checkmarks (M3.2)
        let primaryId = usageStore.primaryAccountId ?? usageStore.accounts.first?.id
        for account in usageStore.accounts {
            let item = NSMenuItem(
                title: account.displayName,
                action: #selector(selectAccount(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = account.id
            item.state = account.id == primaryId ? .on : .off
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
        guard let accountId = sender.representedObject as? String else { return }
        usageStore.primaryAccountId = accountId
        updateStatusButton()
    }

    func togglePopover() {
        if let popover = popover {
            if popover.isShown {
                popover.performClose(nil)
            } else if let button = statusItem?.button {
                refreshData()
                popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            }
        }
    }
}
