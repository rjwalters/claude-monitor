import SwiftUI

struct UsagePopoverView: View {
    @ObservedObject var store: UsageStore
    @StateObject private var installer = ExtensionInstaller()
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Claude Usage")
                    .font(.headline)
                    .foregroundColor(.primary)
                Spacer()
                if let lastRefresh = store.lastRefresh {
                    Text(timeAgo(lastRefresh))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Button(action: { store.loadFromDatabase() }) {
                    Image(systemName: "arrow.clockwise")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .onHover { hovering in }
            }
            .padding()

            Divider()

            if let error = store.error {
                SetupGuideView(installer: installer, error: error)
            } else if store.accounts.isEmpty {
                SetupGuideView(installer: installer, error: nil)
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(store.accounts) { account in
                            ClickableAccountCard(account: account, usage: store.latestUsage[account.id], store: store)
                        }
                    }
                    .padding()
                }
            }

            Divider()

            // Footer
            HStack {
                Button("Open Usage Page") {
                    if let url = URL(string: "https://claude.ai/settings/usage") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.plain)
                .foregroundColor(.accentColor)

                Spacer()

                Button("Quit") {
                    NSApp.terminate(nil)
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .frame(width: 320, height: 400)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    func timeAgo(_ date: Date) -> String {
        let seconds = Int(-date.timeIntervalSinceNow)
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        return "\(seconds / 3600)h ago"
    }
}

struct AccountCard: View {
    let account: Account
    let usage: UsageRecord?
    @Environment(\.colorScheme) var colorScheme

    var cardBackground: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.05)
            : Color.black.opacity(0.03)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Account header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.email ?? account.id)
                        .font(.headline)
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    if let plan = account.plan {
                        Text(plan)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                Spacer()
                if let percent = account.latestPercent {
                    Text("\(Int(percent))%")
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundColor(colorForPercent(percent))
                }
            }

            if let usage = usage {
                // Session usage
                if let sessionPercent = usage.sessionPercent {
                    UsageRow(
                        label: "Session",
                        percent: sessionPercent,
                        resetTime: usage.sessionReset
                    )
                }

                // Weekly - All models
                if let weeklyAll = usage.weeklyAllPercent {
                    UsageRow(
                        label: "Weekly (All)",
                        percent: weeklyAll,
                        resetTime: usage.weeklyReset
                    )
                }

                // Weekly - Sonnet
                if let weeklySonnet = usage.weeklySONnetPercent {
                    UsageRow(
                        label: "Weekly (Sonnet)",
                        percent: weeklySonnet,
                        resetTime: nil
                    )
                }

                // Last updated
                HStack {
                    Spacer()
                    Text("Updated \(formatDate(usage.timestamp))")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding()
        .background(cardBackground)
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
        )
    }

    func colorForPercent(_ percent: Double) -> Color {
        if percent > 95 { return Color(nsColor: .systemRed) }
        if percent >= 90 { return Color(nsColor: .systemOrange) }
        return .primary
    }

    func formatDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

struct UsageRow: View {
    let label: String
    let percent: Double
    let resetTime: String?
    @Environment(\.colorScheme) var colorScheme

    var trackColor: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.1)
            : Color.black.opacity(0.1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(Int(percent))%")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.primary)
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(trackColor)
                        .frame(height: 6)

                    RoundedRectangle(cornerRadius: 3)
                        .fill(colorForPercent(percent))
                        .frame(width: geometry.size.width * CGFloat(min(percent, 100) / 100), height: 6)
                }
            }
            .frame(height: 6)

            if let reset = resetTime {
                Text(reset)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }

    func colorForPercent(_ percent: Double) -> Color {
        if percent > 95 { return Color(nsColor: .systemRed) }
        if percent >= 90 { return Color(nsColor: .systemOrange) }
        return .primary
    }
}

struct ClickableAccountCard: View {
    let account: Account
    let usage: UsageRecord?
    let store: UsageStore
    @State private var isHovering = false

    var body: some View {
        Button(action: {
            ChartWindowController.showChart(for: account, store: store)
        }) {
            AccountCard(account: account, usage: usage)
        }
        .buttonStyle(CardButtonStyle(isHovering: isHovering))
        .onHover { hovering in
            isHovering = hovering
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}

struct CardButtonStyle: ButtonStyle {
    let isHovering: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : (isHovering ? 1.01 : 1.0))
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
            .animation(.easeInOut(duration: 0.15), value: isHovering)
    }
}

struct SetupGuideView: View {
    @ObservedObject var installer: ExtensionInstaller
    let error: String?
    @State private var currentStep = 1
    @Environment(\.colorScheme) var colorScheme

    var cardBackground: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.05)
            : Color.black.opacity(0.03)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Icon and title
                VStack(spacing: 8) {
                    Image(systemName: "puzzlepiece.extension")
                        .font(.system(size: 40))
                        .foregroundColor(.accentColor)

                    Text("Setup Required")
                        .font(.headline)

                    if let error = error {
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.orange)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(.top, 8)

                // Step 1: Native Host
                SetupStepView(
                    step: 1,
                    title: "Install Native Bridge",
                    description: "Connects Firefox extension to this app",
                    isComplete: installer.nativeHostInstalled,
                    isCurrent: currentStep == 1
                ) {
                    if installer.installNativeHost() {
                        currentStep = 2
                    }
                }

                // Step 2: Extension
                SetupStepView(
                    step: 2,
                    title: "Install Firefox Extension",
                    description: "Captures usage data from claude.ai",
                    isComplete: installer.extensionInstalled,
                    isCurrent: currentStep == 2 && installer.nativeHostInstalled
                ) {
                    installer.openExtensionFolder()
                }

                // Step 3: Visit usage page
                SetupStepView(
                    step: 3,
                    title: "Visit Claude Usage Page",
                    description: "Open claude.ai/settings/usage in Firefox",
                    isComplete: false,
                    isCurrent: currentStep >= 2 && installer.nativeHostInstalled
                ) {
                    if let url = URL(string: "https://claude.ai/settings/usage") {
                        NSWorkspace.shared.open(url)
                    }
                }

                // Instructions
                VStack(alignment: .leading, spacing: 8) {
                    Text("Extension Installation:")
                        .font(.caption)
                        .fontWeight(.medium)

                    Text("Download the .xpi file from GitHub releases and drag it into Firefox to install permanently.")
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    Button("Download Extension") {
                        if let url = URL(string: "https://github.com/rjwalters/claude-monitor/releases") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(cardBackground)
                .cornerRadius(8)

                Spacer()
            }
            .padding()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            installer.checkInstallationStatus()
            if installer.nativeHostInstalled {
                currentStep = 2
            }
        }
    }
}

struct SetupStepView: View {
    let step: Int
    let title: String
    let description: String
    let isComplete: Bool
    let isCurrent: Bool
    let action: () -> Void
    @Environment(\.colorScheme) var colorScheme

    var cardBackground: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.05)
            : Color.black.opacity(0.03)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                // Step number or checkmark
                ZStack {
                    Circle()
                        .fill(isComplete ? Color.green : (isCurrent ? Color.accentColor : Color.secondary.opacity(0.3)))
                        .frame(width: 28, height: 28)

                    if isComplete {
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.white)
                    } else {
                        Text("\(step)")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(isCurrent ? .white : .secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(isComplete ? .secondary : .primary)

                    Text(description)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                Spacer()

                if !isComplete && isCurrent {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(12)
            .background(cardBackground)
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isCurrent && !isComplete ? Color.accentColor : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(isComplete)
    }
}
