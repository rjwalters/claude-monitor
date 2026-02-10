import SwiftUI

/// Format a reset time string for display.
/// Handles both ISO 8601 timestamps (from API) and relative strings (from extension).
func formatResetTime(_ str: String) -> String {
    // Try ISO 8601 parse
    let isoFormatter = ISO8601DateFormatter()
    isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let date = isoFormatter.date(from: str) ?? ISO8601DateFormatter().date(from: str)

    if let date = date {
        let interval = date.timeIntervalSinceNow
        if interval <= 0 { return "Reset" }
        let hours = Int(interval) / 3600
        let minutes = (Int(interval) % 3600) / 60
        if hours > 0 {
            return "Resets in \(hours) hr \(minutes) min"
        }
        return "Resets in \(minutes) min"
    }

    // Already a relative string (e.g. "in 23 hr 57 min") — return as-is
    return str
}

struct UsagePopoverView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var oauthPoller: OAuthPoller
    @ObservedObject var heightManager: PopoverHeightManager
    var onLoginToAll: (() -> Void)?
    @Environment(\.colorScheme) var colorScheme
    @State private var showGitHubLink = false
    @State private var titleHoverTimer: Timer?
    @State private var showMigrationBanner = false
    @State private var showRemoveConfirmation = false
    @State private var accountToRemove: Account?

    /// Chrome height: header (~50) + dividers (~2) + footer (~42) + resize handle (~14)
    private var scrollViewMaxHeight: CGFloat {
        heightManager.currentHeight - 108
    }


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

            // Migration notice (M5.3)
            if showMigrationBanner {
                HStack {
                    Image(systemName: "info.circle")
                        .foregroundColor(.blue)
                    Text("The browser extension is no longer needed. OAuth is now the default.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button(action: dismissMigrationBanner) {
                        Image(systemName: "xmark")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal)
                .padding(.vertical, 6)
                .background(Color.blue.opacity(0.1))

                Divider()
            }

            if let error = store.error {
                SetupGuideView(oauthPoller: oauthPoller, store: store, error: error)
            } else if store.accounts.isEmpty {
                SetupGuideView(oauthPoller: oauthPoller, store: store, error: nil)
            } else {
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(Array(store.accounts.enumerated()), id: \.element.id) { index, account in
                            ClickableAccountCard(
                                account: account,
                                usage: store.latestUsage[account.id],
                                store: store,
                                oauthPoller: oauthPoller,
                                isFirst: index == 0,
                                isLast: index == store.accounts.count - 1,
                                onRemove: {
                                    accountToRemove = account
                                    showRemoveConfirmation = true
                                }
                            )
                        }
                    }
                    .padding()
                }
                .frame(maxHeight: scrollViewMaxHeight)
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

                Text("·")
                    .foregroundColor(.secondary)

                Button(action: openLoginWizard) {
                    Text("Login to All")
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

                // Add account button (M2.2)
                if !store.accounts.isEmpty {
                    Button(action: addAccount) {
                        Image(systemName: "plus")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Import credentials from Keychain")
                }

                Button("Quit") {
                    NSApp.terminate(nil)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal)
            .padding(.vertical, 10)

            PopoverResizeHandle(heightManager: heightManager)
        }
        .frame(width: 320, height: heightManager.currentHeight)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            // Check migration banner (M5.3)
            if store.hasNativeHostManifests && store.getSetting("migration_banner_dismissed") == nil {
                showMigrationBanner = true
            }
        }
        .alert("Remove Account?", isPresented: $showRemoveConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Remove", role: .destructive) {
                if let account = accountToRemove {
                    removeAccount(account)
                }
            }
        } message: {
            Text("This will deactivate the credential and remove usage data for \(accountToRemove?.displayName ?? "this account").")
        }
    }

    func timeAgo(_ date: Date) -> String {
        let seconds = Int(-date.timeIntervalSinceNow)
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        return "\(seconds / 3600)h ago"
    }

    private func openLoginWizard() {
        onLoginToAll?()
    }

    // M2.2: Re-scan keychain and import new credentials
    private func addAccount() {
        let results = oauthPoller.importAllFromKeychain()
        var imported = 0
        for result in results {
            if case .success(let credential) = result {
                store.ensureDatabase()
                oauthPoller.saveCredential(credential)
                imported += 1
            }
        }
        if imported > 0 {
            store.loadFromDatabase()
        }
    }

    private func dismissMigrationBanner() {
        showMigrationBanner = false
        store.setSetting("migration_banner_dismissed", value: "1")
    }

    // M4.3: Remove account
    private func removeAccount(_ account: Account) {
        // Deactivate credential
        let credentials = oauthPoller.loadActiveCredentials()
        for cred in credentials where cred.accountId == account.id {
            oauthPoller.deactivateCredential(cred)
        }
        // Clear account data
        store.clearAccountData(accountId: account.id)
    }
}

// MARK: - Popover Resize Handle

struct PopoverResizeHandle: View {
    @ObservedObject var heightManager: PopoverHeightManager
    @State private var dragStartHeight: CGFloat = 0

    var body: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(Color.secondary.opacity(0.4))
            .frame(width: 36, height: 4)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .onChanged { value in
                        if dragStartHeight == 0 {
                            dragStartHeight = heightManager.currentHeight
                        }
                        let newHeight = (dragStartHeight + value.translation.height)
                            .clamped(to: PopoverHeightManager.minHeight...PopoverHeightManager.maxHeight)
                        heightManager.currentHeight = newHeight
                        heightManager.popover?.contentSize = NSSize(width: 320, height: newHeight)
                    }
                    .onEnded { _ in
                        dragStartHeight = 0
                        heightManager.persist()
                    }
            )
            .onHover { hovering in
                if hovering {
                    NSCursor.resizeUpDown.push()
                } else {
                    NSCursor.pop()
                }
            }
    }
}

// MARK: - Token Status Dot (M1.3)

struct TokenStatusDot: View {
    let accountId: String?
    @ObservedObject var oauthPoller: OAuthPoller

    var statusForAccount: CredentialStatus? {
        guard let accountId = accountId else { return nil }
        return oauthPoller.credentialStatuses.first(where: { $0.accountId == accountId })
    }

    var dotColor: Color {
        guard let status = statusForAccount else { return .gray }
        switch status.status {
        case .valid: return .green
        case .refreshing: return .yellow
        case .expired, .revoked, .error: return .red
        case .missing: return .gray
        }
    }

    var body: some View {
        Circle()
            .fill(dotColor)
            .frame(width: 8, height: 8)
            .help(statusForAccount?.lastError ?? statusForAccount?.status.rawValue ?? "unknown")
    }
}

struct AccountCard: View {
    let account: Account
    let usage: UsageRecord?
    var oauthPoller: OAuthPoller? = nil
    var store: UsageStore? = nil
    var onEditTapped: (() -> Void)? = nil
    var onRemove: (() -> Void)? = nil
    @Environment(\.colorScheme) var colorScheme
    @State private var isNameHovering = false
    @State private var isReauthenticating = false

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
                        // Token status dot (M1.3)
                        if let poller = oauthPoller {
                            TokenStatusDot(accountId: account.id, oauthPoller: poller)
                        }

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

                // Re-auth prompt (M4.2)
                if let poller = oauthPoller,
                   let status = poller.credentialStatuses.first(where: { $0.accountId == account.id }),
                   status.status == .expired || status.status == .revoked {
                    HStack {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundColor(.orange)
                            .font(.caption)
                        Text("Token \(status.status.rawValue)")
                            .font(.caption)
                            .foregroundColor(.orange)
                        Spacer()
                        Button(isReauthenticating ? "Scanning..." : "Re-authenticate") {
                            guard !isReauthenticating else { return }
                            isReauthenticating = true
                            Task {
                                if let scanStore = store {
                                    // Try keychain re-scan first
                                    if let _ = await poller.scanKeychainWithProfile() {
                                        await MainActor.run {
                                            scanStore.loadFromDatabase()
                                            isReauthenticating = false
                                        }
                                    } else {
                                        // Keychain scan failed — fall back to browser
                                        await MainActor.run {
                                            isReauthenticating = false
                                            if let url = URL(string: "https://claude.ai/login") {
                                                NSWorkspace.shared.open(url)
                                            }
                                        }
                                    }
                                } else {
                                    // No store — fall back to browser
                                    await MainActor.run {
                                        isReauthenticating = false
                                        if let url = URL(string: "https://claude.ai/login") {
                                            NSWorkspace.shared.open(url)
                                        }
                                    }
                                }
                            }
                        }
                        .font(.caption)
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .disabled(isReauthenticating)
                    }
                    .padding(.top, 4)
                }

                // Last updated + last poll time (M1.3)
                HStack {
                    Spacer()
                    Text("Updated \(formatDate(usage.timestamp))")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            // Remove account button (M4.3) — shown on hover
            if isNameHovering, let onRemove = onRemove {
                HStack {
                    Spacer()
                    Button(action: onRemove) {
                        HStack(spacing: 3) {
                            Image(systemName: "trash")
                                .font(.system(size: 9))
                            Text("Remove")
                                .font(.system(size: 10))
                        }
                        .foregroundColor(.red)
                    }
                    .buttonStyle(.plain)
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
                Text(formatResetTime(reset))
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
    var oauthPoller: OAuthPoller? = nil
    var isFirst: Bool = false
    var isLast: Bool = false
    var onRemove: (() -> Void)? = nil
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
                        oauthPoller: oauthPoller,
                        store: store,
                        onEditTapped: {
                            editedName = account.accountName ?? account.displayName
                            isEditing = true
                        },
                        onRemove: onRemove
                    )
                }
                .buttonStyle(CardButtonStyle(isHovering: isHovering))

                // Move to top / pin button (only shown on hover for non-first cards)
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

                // Send to bottom button (only shown on hover for the first card when not also last)
                if isFirst && !isLast && isHovering {
                    Button(action: {
                        store.moveAccountToBottom(accountId: account.id)
                    }) {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.down.to.line")
                                .font(.system(size: 9))
                            Text("Send to bottom")
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

// MARK: - Setup Guide (M5.1: extension buttons removed)

struct SetupGuideView: View {
    @ObservedObject var oauthPoller: OAuthPoller
    let store: UsageStore
    let error: String?
    @Environment(\.colorScheme) var colorScheme
    @State private var importError: String?

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

                Text("Import your Claude Code credentials to get started")
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

                if let importError = importError {
                    Text(importError)
                        .font(.caption)
                        .foregroundColor(.orange)
                        .multilineTextAlignment(.center)
                        .padding(.top, 4)
                }
            }

            // Action buttons (M5.1: extension buttons removed)
            VStack(spacing: 12) {
                Button(action: importFromClaudeCode) {
                    Label("Import from Claude Code", systemImage: "key")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)

                Button(action: {
                    if let url = URL(string: "https://claude.ai/login") {
                        NSWorkspace.shared.open(url)
                    }
                }) {
                    Label("Add Account (Login)", systemImage: "person.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)

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
            }
            .padding(.horizontal)

            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func importFromClaudeCode() {
        importError = nil
        let results = oauthPoller.importAllFromKeychain()
        var importedCount = 0
        var lastErrorMsg: String?

        for result in results {
            switch result {
            case .success(let credential):
                store.ensureDatabase()
                oauthPoller.saveCredential(credential)
                importedCount += 1
            case .failure(let error):
                lastErrorMsg = error.localizedDescription
            }
        }

        if importedCount > 0 {
            store.loadFromDatabase()
        } else {
            importError = lastErrorMsg ?? "Could not read Claude Code credentials from Keychain. Is Claude Code installed and signed in?"
        }
    }
}

// MARK: - Login Wizard

struct LoginWizardView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var oauthPoller: OAuthPoller
    var onDone: () -> Void

    @State private var statusMessage: String?
    @State private var isScanning = false

    /// Accounts that have an active credential
    private var linkedIds: Set<String> {
        Set(oauthPoller.loadActiveCredentials().compactMap { $0.accountId })
    }

    private var allLinked: Bool {
        !store.accounts.isEmpty && linkedIds.count == store.accounts.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Login to All Accounts")
                .font(.headline)

            VStack(alignment: .leading, spacing: 2) {
                Text("1. In Claude Code, type /login")
                Text("2. Sign in as the next account")
                Text("3. Click Scan Keychain below")
                Text("4. Repeat for each account")
            }
            .font(.caption)
            .foregroundColor(.secondary)

            Divider()

            // Account list with checkmarks
            VStack(alignment: .leading, spacing: 6) {
                ForEach(store.accounts) { account in
                    HStack(spacing: 8) {
                        Image(systemName: linkedIds.contains(account.id) ? "checkmark.circle.fill" : "circle")
                            .foregroundColor(linkedIds.contains(account.id) ? .green : .secondary)
                            .font(.caption)
                        Text(account.displayName)
                            .font(.caption)
                            .lineLimit(1)
                        Spacer()
                        if linkedIds.contains(account.id),
                           let usage = store.latestUsage[account.id] {
                            let pct = Int(max(usage.sessionPercent ?? 0, usage.weeklyAllPercent ?? 0))
                            Text("\(pct)%")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }

            if let msg = statusMessage {
                Text(msg)
                    .font(.caption)
                    .foregroundColor(msg.contains("No token") ? .orange : .green)
            }

            Divider()

            HStack {
                Button(action: scanKeychain) {
                    Label(isScanning ? "Scanning..." : "Scan Keychain", systemImage: "key")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(isScanning)

                Spacer()

                Button("Close") {
                    onDone()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding()
        .frame(width: 280)
    }

    // MARK: - Helpers

    private func scanKeychain() {
        isScanning = true
        statusMessage = nil

        store.ensureDatabase()

        Task {
            // Import token and identify account via profile API
            if let email = await oauthPoller.scanKeychainWithProfile() {
                await MainActor.run {
                    // Reload accounts — may include a newly discovered account
                    store.loadFromDatabase()
                    isScanning = false
                    if allLinked {
                        statusMessage = "All accounts linked!"
                    } else {
                        statusMessage = "Linked \(email)."
                    }
                }
            } else {
                await MainActor.run {
                    isScanning = false
                    statusMessage = "No token found. Use /login in Claude Code first."
                }
            }
        }
    }
}
