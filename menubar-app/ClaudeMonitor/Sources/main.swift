import SwiftUI

// MARK: - Popover Height Manager

extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        return Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

class PopoverHeightManager: ObservableObject {
    static let minHeight: CGFloat = 200
    static let maxHeight: CGFloat = 800
    static let defaultHeight: CGFloat = 400

    @Published var currentHeight: CGFloat
    weak var popover: NSPopover?

    private let store: UsageStore

    init(store: UsageStore) {
        self.store = store
        if let saved = store.getSetting("popover_height"),
           let value = Double(saved) {
            self.currentHeight = CGFloat(value).clamped(to: Self.minHeight...Self.maxHeight)
        } else {
            self.currentHeight = Self.defaultHeight
        }
    }

    func persist() {
        store.setSetting("popover_height", value: String(Int(currentHeight)))
    }
}

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
    var loginWizardWindow: NSWindow?
    var summaryWindow: NSWindow?
    var heightManager: PopoverHeightManager!

    private let flog = FileLogger.shared

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        flog.info("ClaudeMonitor launched (v\(AppVersion.current))", category: "App")

        // Ensure database exists (standalone mode without native host)
        usageStore.ensureDatabase()

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

        // Update menubar when accounts change (e.g., reordering)
        usageStore.onAccountsChanged = { [weak self] in
            self?.updateStatusButton()
        }

        // Create height manager (reads persisted height from DB)
        heightManager = PopoverHeightManager(store: usageStore)

        // Create popover
        popover = NSPopover()
        popover?.contentSize = NSSize(width: 320, height: heightManager.currentHeight)
        popover?.behavior = .transient
        popover?.contentViewController = NSHostingController(
            rootView: UsagePopoverView(store: usageStore, oauthPoller: oauthPoller, heightManager: heightManager, onAddAccount: { [weak self] in
                self?.openAddAccountWindow()
            }, onSummary: { [weak self] in
                self?.openSummaryWindow()
            })
        )
        heightManager.popover = popover

        // Start round-robin polling — one account per tick, 60s apart
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.refreshNext()
        }

        // Initial load — poll all accounts once
        refreshAll()
    }

    /// Poll all accounts (startup and manual refresh)
    func refreshAll() {
        flog.info("refreshAll: polling all accounts", category: "App")
        Task {
            await oauthPoller.pollAll()
            await MainActor.run {
                usageStore.loadFromDatabase()
                updateStatusButton()
                flog.info("refreshAll: loaded \(usageStore.accounts.count) account(s)", category: "App")
            }
        }
    }

    /// Poll one account (round-robin, called by timer)
    func refreshNext() {
        Task {
            await oauthPoller.pollNext()
            await MainActor.run {
                usageStore.loadFromDatabase()
                updateStatusButton()
            }
        }
    }

    // MARK: - Menubar shows top card (first account)

    func updateStatusButton() {
        guard let button = statusItem?.button else { return }

        var percent: Int = 0
        var isWeeklyLimit = false

        // Top card in popover = menubar account (active account or most available)
        let targetAccount = usageStore.sortedAccountsForPopover.first

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
                popover.contentSize = NSSize(width: 320, height: heightManager.currentHeight)
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

    // MARK: - Summary Window

    func openSummaryWindow() {
        flog.info("openSummaryWindow called", category: "App")

        popover?.performClose(nil)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self = self else { return }

            if let window = self.summaryWindow, window.isVisible {
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                return
            }

            let summaryView = SummaryTableView(store: self.usageStore, oauthPoller: self.oauthPoller, onDone: { [weak self] in
                self?.summaryWindow?.close()
                self?.summaryWindow = nil
            })

            let hostingController = NSHostingController(rootView: summaryView)
            if #available(macOS 13.0, *) {
                hostingController.sizingOptions = []
            }
            let window = NSWindow(contentViewController: hostingController)
            window.title = "Account Summary"
            window.styleMask = [.titled, .closable]
            window.setContentSize(NSSize(width: 640, height: 400))
            window.center()
            window.isReleasedWhenClosed = false
            window.level = .floating
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            self.summaryWindow = window

            self.flog.info("Summary window opened", category: "App")
        }
    }
}
