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

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide dock icon
        NSApp.setActivationPolicy(.accessory)

        // Create status bar item with fixed width for consistent layout
        statusItem = NSStatusBar.system.statusItem(withLength: 36)

        if let button = statusItem?.button {
            button.action = #selector(togglePopover)
            button.target = self
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
            rootView: UsagePopoverView(store: usageStore)
        )

        // Start polling for updates
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.refreshData()
        }

        // Initial load
        refreshData()
    }

    func refreshData() {
        usageStore.loadFromDatabase()
        updateStatusButton()
    }

    func updateStatusButton() {
        guard let button = statusItem?.button else { return }

        var percent: Int = 0

        // Find the highest percentage across all accounts (most constrained)
        if let primaryAccount = usageStore.accounts.first,
           let usage = usageStore.latestUsage[primaryAccount.id] {
            // Show the highest of session or weekly percentages (most limiting)
            let sessionPercent = usage.sessionPercent ?? 0
            let weeklyAllPercent = usage.weeklyAllPercent ?? 0
            percent = Int(max(sessionPercent, weeklyAllPercent))
        } else if let primaryAccount = usageStore.accounts.first {
            percent = Int(primaryAccount.latestPercent ?? 0)
        }

        // Create Stats-style image with "LLM" label and percentage
        button.image = createStatsStyleImage(percent: percent)
        button.title = ""
    }

    func createStatsStyleImage(percent: Int) -> NSImage {
        // Match Stats Mini widget exactly
        // Label: 7pt light at y=12, Value: 12pt regular at y=1
        let labelFont = NSFont.systemFont(ofSize: 7, weight: .light)
        let valueFont = NSFont.systemFont(ofSize: 12, weight: .regular)

        let labelText = "LLM"
        let percentText = percent > 0 ? "\(percent)%" : "--"

        // Width: 31 like Stats Mini with label
        let width: CGFloat = 31
        let height: CGFloat = 22

        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
            // Monochrome style: white in dark mode
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

            // Draw label at y=14 (top, shifted up 2px)
            let labelAttrs: [NSAttributedString.Key: Any] = [
                .font: labelFont,
                .foregroundColor: labelColor,
                .paragraphStyle: style
            ]
            let labelRect = CGRect(x: 2, y: 14, width: width - 4, height: 7)
            let labelStr = NSAttributedString(string: labelText, attributes: labelAttrs)
            labelStr.draw(with: labelRect)

            // Draw value at y=3 (bottom, shifted up 2px)
            let valueAttrs: [NSAttributedString.Key: Any] = [
                .font: valueFont,
                .foregroundColor: valueColor,
                .paragraphStyle: style
            ]
            let valueRect = CGRect(x: 2, y: 3, width: width - 4, height: 13)
            let valueStr = NSAttributedString(string: percentText, attributes: valueAttrs)
            valueStr.draw(with: valueRect)

            return true
        }

        image.isTemplate = false
        return image
    }

    @objc func togglePopover() {
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
