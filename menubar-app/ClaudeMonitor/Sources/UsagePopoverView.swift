import SwiftUI

struct UsagePopoverView: View {
    @ObservedObject var store: UsageStore
    @StateObject private var installer = ExtensionInstaller()
    @Environment(\.colorScheme) var colorScheme
    @State private var showGitHubLink = false
    @State private var titleHoverTimer: Timer?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                if showGitHubLink {
                    Button(action: {
                        if let url = URL(string: "https://github.com/rjwalters/claude-monitor") {
                            NSWorkspace.shared.open(url)
                        }
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "link")
                                .font(.caption)
                            Text("GitHub")
                                .font(.headline)
                        }
                        .foregroundColor(.accentColor)
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in
                        if hovering {
                            NSCursor.pointingHand.push()
                        } else {
                            NSCursor.pop()
                            showGitHubLink = false
                        }
                    }
                } else {
                    Text("Claude Usage")
                        .font(.headline)
                        .foregroundColor(.primary)
                        .onHover { hovering in
                            if hovering {
                                titleHoverTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { _ in
                                    showGitHubLink = true
                                }
                            } else {
                                titleHoverTimer?.invalidate()
                                titleHoverTimer = nil
                            }
                        }
                }
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
                VStack(spacing: 12) {
                    ForEach(Array(store.accounts.enumerated()), id: \.element.id) { index, account in
                        ClickableAccountCard(account: account, usage: store.latestUsage[account.id], store: store, isFirst: index == 0)
                    }
                }
                .padding()
            }

            Divider()

            // Footer
            HStack {
                // Open Usage Page as a hyperlink
                Button(action: {
                    if let url = URL(string: "https://claude.ai/settings/usage") {
                        NSWorkspace.shared.open(url)
                    }
                }) {
                    Text("Open Usage Page")
                        .underline()
                }
                .buttonStyle(.plain)
                .foregroundColor(.accentColor)
                .onHover { hovering in
                    if hovering {
                        NSCursor.pointingHand.push()
                    } else {
                        NSCursor.pop()
                    }
                }

                Spacer()

                Button("Quit") {
                    NSApp.terminate(nil)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
        }
        .frame(width: 320)
        .fixedSize(horizontal: false, vertical: true)
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
    var onEditTapped: (() -> Void)? = nil
    @Environment(\.colorScheme) var colorScheme
    @State private var isNameHovering = false

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
                    HStack(spacing: 6) {
                        if isNameHovering, let onEdit = onEditTapped {
                            Button(action: onEdit) {
                                Image(systemName: "pencil")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        Text(account.displayName)
                            .font(.headline)
                            .foregroundColor(.primary)
                            .lineLimit(1)
                    }
                    .onHover { hovering in
                        isNameHovering = hovering
                    }
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
    var isFirst: Bool = false
    @State private var isHovering = false
    @State private var isEditing = false
    @State private var editedName = ""

    var body: some View {
        if isEditing {
            EditableAccountCard(
                account: account,
                usage: usage,
                editedName: $editedName,
                isEditing: $isEditing,
                onSave: { newName in
                    store.updateAccountName(accountId: account.id, newName: newName)
                }
            )
        } else {
            ZStack(alignment: .bottomLeading) {
                Button(action: {
                    ChartWindowController.showChart(for: account, store: store)
                }) {
                    AccountCard(
                        account: account,
                        usage: usage,
                        onEditTapped: {
                            editedName = account.accountName ?? account.displayName
                            isEditing = true
                        }
                    )
                }
                .buttonStyle(CardButtonStyle(isHovering: isHovering))

                // Move to top button (only shown on hover for non-first cards)
                if !isFirst && isHovering {
                    Button(action: {
                        store.moveAccountToTop(accountId: account.id)
                    }) {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.up.to.line")
                                .font(.system(size: 9))
                            Text("Pin to top")
                                .font(.system(size: 10))
                        }
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color(nsColor: .controlBackgroundColor).opacity(0.9))
                        .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                    .padding(8)
                    .onHover { hovering in
                        if hovering {
                            NSCursor.pointingHand.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                }
            }
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
}

struct EditableAccountCard: View {
    let account: Account
    let usage: UsageRecord?
    @Binding var editedName: String
    @Binding var isEditing: Bool
    let onSave: (String) -> Void
    @Environment(\.colorScheme) var colorScheme
    @FocusState private var isFocused: Bool

    var cardBackground: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.05)
            : Color.black.opacity(0.03)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Editable account header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        TextField("Account name", text: $editedName)
                            .textFieldStyle(.plain)
                            .font(.headline)
                            .focused($isFocused)
                            .onSubmit {
                                saveAndClose()
                            }
                            .onExitCommand {
                                isEditing = false
                            }

                        Button(action: saveAndClose) {
                            Image(systemName: "checkmark")
                                .font(.caption)
                                .foregroundColor(.green)
                        }
                        .buttonStyle(.plain)

                        Button(action: { isEditing = false }) {
                            Image(systemName: "xmark")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }

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
                .stroke(Color.accentColor.opacity(0.5), lineWidth: 2)
        )
        .onAppear {
            isFocused = true
        }
    }

    func saveAndClose() {
        let trimmed = editedName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            onSave(trimmed)
        }
        isEditing = false
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
    @Environment(\.colorScheme) var colorScheme

    var cardBackground: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.05)
            : Color.black.opacity(0.03)
    }

    var body: some View {
        VStack(spacing: 16) {
            Spacer()

            // Icon and title
            VStack(spacing: 8) {
                Image(systemName: "chart.bar.fill")
                    .font(.system(size: 40))
                    .foregroundColor(.accentColor)

                Text("No Usage Data")
                    .font(.headline)

                Text("Visit the Claude usage page in Firefox to start collecting data")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)

                if let error = error {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.orange)
                        .multilineTextAlignment(.center)
                        .padding(.top, 4)
                }
            }

            // Action buttons
            VStack(spacing: 12) {
                if !installer.nativeHostInstalled {
                    Button(action: { _ = installer.installNativeHost() }) {
                        Label("Install Native Bridge", systemImage: "puzzlepiece.extension")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                }

                Button(action: {
                    if let url = URL(string: "https://claude.ai/settings/usage") {
                        NSWorkspace.shared.open(url)
                    }
                }) {
                    Label("Open Usage Page", systemImage: "safari")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)

                Button(action: { installer.openExtensionDownload() }) {
                    Label("Get Firefox Extension", systemImage: "arrow.down.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }
            .padding(.horizontal)

            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            installer.checkInstallationStatus()
        }
    }
}

