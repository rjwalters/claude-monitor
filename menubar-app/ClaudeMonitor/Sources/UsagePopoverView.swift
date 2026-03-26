import SwiftUI

/// Format a time interval using a single unit with decreasing precision:
/// "34 min" (up to 90 min), "1.5 hrs" (half-hour granularity), "3 days" (rounded up).
func formatInterval(_ seconds: TimeInterval) -> String {
    if seconds <= 0 { return "now" }
    let minutes = seconds / 60
    if minutes < 90 { return "\(Int(minutes)) min" }
    let hours = seconds / 3600
    if hours < 24 {
        let rounded = (hours * 2).rounded() / 2  // nearest 0.5
        if rounded == rounded.rounded() {
            return "\(Int(rounded)) hrs"
        }
        return String(format: "%.1f hrs", rounded)
    }
    let days = Int(ceil(seconds / 86400))
    return "\(days) \(days == 1 ? "day" : "days")"
}

/// Format a reset time string for display.
/// Handles both ISO 8601 timestamps (from API) and relative strings.
func formatResetTime(_ str: String) -> String {
    let isoFormatter = ISO8601DateFormatter()
    isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let date = isoFormatter.date(from: str) ?? ISO8601DateFormatter().date(from: str)

    if let date = date {
        let interval = date.timeIntervalSinceNow
        if interval <= 0 { return "Reset" }
        return "Resets in \(formatInterval(interval))"
    }

    // Already a relative string — return as-is
    return str
}

struct UsagePopoverView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var oauthPoller: OAuthPoller
    @ObservedObject var heightManager: PopoverHeightManager
    var onAddAccount: (() -> Void)?
    var onSummary: (() -> Void)?
    @Environment(\.colorScheme) var colorScheme
    @State private var showGitHubLink = false
    @State private var titleHoverTimer: Timer?
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


            if let error = store.error {
                SetupGuideView(oauthPoller: oauthPoller, store: store, error: error, onAddAccount: onAddAccount)
            } else if store.accounts.isEmpty {
                SetupGuideView(oauthPoller: oauthPoller, store: store, error: nil, onAddAccount: onAddAccount)
            } else {
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(store.sortedAccountsForPopover) { account in
                            ClickableAccountCard(
                                account: account,
                                usage: store.latestUsage[account.id],
                                store: store,
                                oauthPoller: oauthPoller,
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
                Button(action: { onSummary?() }) {
                    Label("Summary", systemImage: "tablecells")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button(action: { onAddAccount?() }) {
                    Label("Add Account", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer()

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
        let seconds = -date.timeIntervalSinceNow
        if seconds < 60 { return "just now" }
        return "\(formatInterval(seconds)) ago"
    }

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

// MARK: - Token Status Dot

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
                        // Token status dot
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

                // Token status warning
                if let poller = oauthPoller,
                   let status = poller.credentialStatuses.first(where: { $0.accountId == account.id }),
                   status.status == .expired || status.status == .revoked || status.status == .missing {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundColor(.orange)
                                .font(.caption)
                            Text("Token \(status.status.rawValue)")
                                .font(.caption)
                                .foregroundColor(.orange)
                        }
                        Text("Re-add with a fresh token from 'claude setup-token'")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .padding(.top, 4)
                }

                // Last updated
                HStack {
                    Spacer()
                    let age = -usage.timestamp.timeIntervalSinceNow
                    if age > 30 * 60 {
                        HStack(spacing: 3) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption2)
                            Text("Updated \(formatDate(usage.timestamp))")
                                .font(.caption2)
                        }
                        .foregroundColor(.orange)
                    } else if age > 10 * 60 {
                        Text("Updated \(formatDate(usage.timestamp))")
                            .font(.caption2)
                            .foregroundColor(.yellow)
                    } else {
                        Text("Updated \(formatDate(usage.timestamp))")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }

            // Remove account button — shown on hover
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
                if let sessionPercent = usage.sessionPercent {
                    UsageRow(
                        label: "Session",
                        percent: sessionPercent,
                        resetTime: usage.sessionReset
                    )
                }

                if let weeklyAll = usage.weeklyAllPercent {
                    UsageRow(
                        label: "Weekly (All)",
                        percent: weeklyAll,
                        resetTime: usage.weeklyReset
                    )
                }

                if let weeklySonnet = usage.weeklySONnetPercent {
                    UsageRow(
                        label: "Weekly (Sonnet)",
                        percent: weeklySonnet,
                        resetTime: nil
                    )
                }

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

// MARK: - Setup Guide

struct SetupGuideView: View {
    @ObservedObject var oauthPoller: OAuthPoller
    let store: UsageStore
    let error: String?
    var onAddAccount: (() -> Void)?
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        VStack(spacing: 16) {
            Spacer()

            VStack(spacing: 8) {
                Image(systemName: "chart.bar.fill")
                    .font(.system(size: 40))
                    .foregroundColor(.accentColor)

                Text("No Usage Data")
                    .font(.headline)

                Text("Add accounts using tokens from 'claude setup-token'")
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

            VStack(spacing: 12) {
                Button(action: { onAddAccount?() }) {
                    Label("Add Account", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
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
}

// MARK: - Add Account View

struct AddAccountView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var oauthPoller: OAuthPoller
    var onDone: () -> Void

    @State private var tokenText = ""
    @State private var statusMessage: String?
    @State private var isAdding = false
    @State private var envImportResults: [EnvImportResult] = []
    @State private var envPathText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Account")
                .font(.headline)

            // Instructions
            VStack(alignment: .leading, spacing: 2) {
                Text("1. Run: claude setup-token")
                    .font(.caption)
                Text("2. Paste the token below")
                    .font(.caption)
            }
            .foregroundColor(.secondary)

            Divider()

            // Token entry
            VStack(alignment: .leading, spacing: 6) {
                Text("Token")
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextField("sk-ant-oat01-...", text: $tokenText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
                    .onSubmit { addToken() }
            }

            Button(action: addToken) {
                Label(isAdding ? "Adding..." : "Add Account", systemImage: "plus.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .disabled(isAdding || tokenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            Divider()

            // Bulk import from .env
            VStack(alignment: .leading, spacing: 6) {
                Text("Bulk Import")
                    .font(.caption.bold())
                    .foregroundColor(.secondary)
                Text("Import ACCOUNT_EMAIL_N / ACCOUNT_KEY_N pairs from a .env file")
                    .font(.caption2)
                    .foregroundColor(.secondary)

                HStack(spacing: 4) {
                    TextField("~/.env or /path/to/.env", text: $envPathText)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.caption, design: .monospaced))
                        .onSubmit { importEnvFile() }
                    Button(action: importEnvFile) {
                        Text(isAdding ? "..." : "Import")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isAdding || envPathText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            // Import results
            if !envImportResults.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(envImportResults, id: \.email) { result in
                        HStack(spacing: 6) {
                            Image(systemName: result.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundColor(result.success ? .green : .red)
                                .font(.caption)
                            Text(result.email)
                                .font(.caption)
                                .lineLimit(1)
                            if let error = result.error {
                                Text(error)
                                    .font(.caption2)
                                    .foregroundColor(.red)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
            }

            if let msg = statusMessage {
                Text(msg)
                    .font(.caption)
                    .foregroundColor(msg.contains("Error") || msg.contains("Invalid") || msg.contains("No ") ? .orange : .green)
            }

            Spacer()

            Divider()

            HStack {
                Spacer()
                Button("Close") { onDone() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding()
        .frame(width: 320)
    }

    private func addToken() {
        let token = tokenText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return }

        isAdding = true
        statusMessage = nil

        store.ensureDatabase()

        Task {
            let (email, error) = await oauthPoller.addAccountWithToken(token)
            await MainActor.run {
                isAdding = false
                if let email = email {
                    statusMessage = "Added \(email)"
                    tokenText = ""
                    store.loadFromDatabase()
                } else {
                    statusMessage = error ?? "Failed to add account"
                }
            }
        }
    }

    private func importEnvFile() {
        let raw = envPathText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }

        // Expand ~ to home directory
        let expanded = (raw as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)

        guard FileManager.default.fileExists(atPath: expanded) else {
            statusMessage = "File not found: \(expanded)"
            return
        }

        isAdding = true
        statusMessage = nil
        envImportResults = []

        store.ensureDatabase()

        Task {
            let results = await oauthPoller.importFromEnvFile(url: url)
            await MainActor.run {
                isAdding = false
                envImportResults = results
                let successCount = results.filter { $0.success }.count
                if successCount > 0 {
                    statusMessage = "Imported \(successCount) of \(results.count) account(s)"
                    store.loadFromDatabase()
                } else {
                    statusMessage = "No accounts imported"
                }
            }
        }
    }
}

// MARK: - Summary Table

struct SummaryTableView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var oauthPoller: OAuthPoller
    var onDone: () -> Void

    /// Accounts sorted by availability: most usable first.
    private var sortedAccounts: [(account: Account, usage: UsageRecord?)] {
        store.accounts.map { account in
            (account: account, usage: store.latestUsage[account.id])
        }.sorted { a, b in
            let aEffective = max(a.usage?.sessionPercent ?? 0, a.usage?.weeklyAllPercent ?? 0)
            let bEffective = max(b.usage?.sessionPercent ?? 0, b.usage?.weeklyAllPercent ?? 0)
            if aEffective != bEffective { return aEffective < bEffective }
            return UsageStore.resetSeconds(a.usage) < UsageStore.resetSeconds(b.usage)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header row
            HStack(spacing: 0) {
                Text("Account")
                    .frame(width: 140, alignment: .leading)
                Text("Session %")
                    .frame(width: 65, alignment: .trailing)
                Text("Session Reset")
                    .frame(width: 90, alignment: .trailing)
                Text("Weekly %")
                    .frame(width: 65, alignment: .trailing)
                Text("Weekly Reset")
                    .frame(width: 90, alignment: .trailing)
                Text("Fresh")
                    .frame(width: 50, alignment: .center)
                Text("Token")
                    .frame(width: 50, alignment: .center)
            }
            .font(.caption.bold())
            .foregroundColor(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            // Rows
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(sortedAccounts, id: \.account.id) { item in
                        SummaryRow(
                            account: item.account,
                            usage: item.usage,
                            oauthPoller: oauthPoller
                        )
                    }
                }
            }

            Divider()

            // Footer
            HStack {
                Spacer()
                Button("Close") { onDone() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            .padding(10)
        }
        .frame(width: 616)
    }
}

struct SummaryRow: View {
    let account: Account
    let usage: UsageRecord?
    let oauthPoller: OAuthPoller
    @Environment(\.colorScheme) var colorScheme

    private var tokenStatus: TokenStatus {
        guard let status = oauthPoller.credentialStatuses.first(where: { $0.accountId == account.id }) else {
            return .missing
        }
        return status.status
    }

    private var tokenDotColor: Color {
        switch tokenStatus {
        case .valid: return .green
        case .refreshing: return .yellow
        case .expired, .revoked, .error: return .red
        case .missing: return .gray
        }
    }

    /// Data age in seconds (nil if no usage data)
    private var dataAge: TimeInterval? {
        guard let usage = usage else { return nil }
        return -usage.timestamp.timeIntervalSinceNow
    }

    /// Freshness dot color: green (<10 min), yellow (<30 min), red (>30 min)
    private var freshnessDotColor: Color {
        guard let age = dataAge else { return .gray }
        if age < 10 * 60 { return .green }
        if age < 30 * 60 { return .yellow }
        return .red
    }

    private var freshnessLabel: String {
        guard let age = dataAge else { return "No data" }
        if age < 10 * 60 { return "Fresh (<10 min)" }
        if age < 30 * 60 { return "Stale (\(Int(age / 60)) min)" }
        return "Very stale (\(Int(age / 60)) min)"
    }

    var body: some View {
        HStack(spacing: 0) {
            Text(account.displayName)
                .lineLimit(1)
                .frame(width: 140, alignment: .leading)

            percentText(usage?.sessionPercent)
                .frame(width: 65, alignment: .trailing)

            Text(resetTimeLabel(usage?.sessionReset))
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .frame(width: 90, alignment: .trailing)

            percentText(usage?.weeklyAllPercent)
                .frame(width: 65, alignment: .trailing)

            Text(resetTimeLabel(usage?.weeklyReset))
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .frame(width: 90, alignment: .trailing)

            Circle()
                .fill(freshnessDotColor)
                .frame(width: 8, height: 8)
                .help(freshnessLabel)
                .frame(width: 50)

            Circle()
                .fill(tokenDotColor)
                .frame(width: 8, height: 8)
                .help(tokenStatus.rawValue)
                .frame(width: 50)
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(colorScheme == .dark ? Color.white.opacity(0.02) : Color.clear)
    }

    private func resetTimeLabel(_ str: String?) -> String {
        guard let str = str else { return "—" }
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = isoFormatter.date(from: str) ?? ISO8601DateFormatter().date(from: str)
        if let date = date {
            let interval = date.timeIntervalSinceNow
            if interval <= 0 { return "now" }
            return formatInterval(interval)
        }
        return str
    }

    @ViewBuilder
    private func percentText(_ value: Double?) -> some View {
        if let pct = value {
            Text("\(Int(pct))%")
                .foregroundColor(colorForPercent(pct))
        } else {
            Text("—")
                .foregroundColor(.secondary)
        }
    }

    private func colorForPercent(_ percent: Double) -> Color {
        if percent > 95 { return Color(nsColor: .systemRed) }
        if percent >= 90 { return Color(nsColor: .systemOrange) }
        return .primary
    }
}
