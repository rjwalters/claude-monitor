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
        // Width accommodates parentheses for weekly limit display: (XX%)
        statusItem = NSStatusBar.system.statusItem(withLength: 45)

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
        var isWeeklyLimit = false

        // Find the highest percentage across all accounts (most constrained)
        if let primaryAccount = usageStore.accounts.first,
           let usage = usageStore.latestUsage[primaryAccount.id] {
            // Show the highest of session or weekly percentages (most limiting)
            let sessionPercent = usage.sessionPercent ?? 0
            let weeklyAllPercent = usage.weeklyAllPercent ?? 0
            percent = Int(max(sessionPercent, weeklyAllPercent))
            isWeeklyLimit = weeklyAllPercent >= sessionPercent
        } else if let primaryAccount = usageStore.accounts.first {
            percent = Int(primaryAccount.latestPercent ?? 0)
            isWeeklyLimit = true  // Default to weekly if we only have primary percent
        }


        // Create Stats-style image with "LLM" label and percentage
        // Weekly limit shown in parentheses: (XX%), session limit without: XX%
        button.image = createStatsStyleImage(percent: percent, isWeeklyLimit: isWeeklyLimit)
        button.title = ""
    }

    func createStatsStyleImage(percent: Int, isWeeklyLimit: Bool) -> NSImage {
        // Match Stats Mini widget exactly
        // Label: 7pt light at y=12, Value: 12pt regular at y=1
        let labelFont = NSFont.systemFont(ofSize: 7, weight: .light)
        let valueFont = NSFont.systemFont(ofSize: 12, weight: .regular)

        let labelText = "LLM"
        // Weekly limit shown in parentheses: (XX%), session limit without: XX%
        let percentText: String
        if percent > 0 {
            percentText = isWeeklyLimit ? "(\(percent)%)" : "\(percent)%"
        } else {
            percentText = "--"
        }

        // Width accommodates parentheses for weekly limit display: (XX%)
        let width: CGFloat = 40
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

            // Measure text widths to center the block
            let labelSize = (labelText as NSString).size(withAttributes: labelAttrs)
            let valueSize = (percentText as NSString).size(withAttributes: valueAttrs)
            let blockWidth = max(labelSize.width, valueSize.width)
            let xOffset = (width - blockWidth) / 2

            // Draw label at y=14 (top, shifted up 2px)
            let labelRect = CGRect(x: xOffset, y: 14, width: blockWidth, height: 7)
            let labelStr = NSAttributedString(string: labelText, attributes: labelAttrs)
            labelStr.draw(with: labelRect)

            // Draw value at y=3 (bottom, shifted up 2px)
            let valueRect = CGRect(x: xOffset, y: 3, width: blockWidth, height: 13)
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
