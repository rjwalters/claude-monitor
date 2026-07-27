import AppKit
import SwiftUI

/// Guided "roll token" workflow for one account. The app can't revoke or mint on
/// its own — both require the account's claude.ai web session in a browser — so
/// this walks the user through it: revoke all existing tokens via a pasted console
/// script, mint a fresh one with `claude setup-token`, paste it back. The app bakes
/// in the org id, imports the new token, and independently verifies the old one is
/// dead. See `TokenRoller` for why it works this way.
struct RollTokenView: View {
    let account: Account
    @ObservedObject var store: UsageStore
    @ObservedObject var oauthPoller: OAuthPoller
    var onClose: () -> Void

    /// The token stored when the wizard opened — pinged at the end to confirm the
    /// revoke actually took effect (Anthropic's revoke is known to be unreliable).
    @State private var oldToken: String?
    @State private var rolledAt: Date?
    @State private var newToken = ""
    @State private var importStatus: ImportStatus = .idle
    @State private var revokeCheck: RevokeCheck = .unchecked
    @State private var copiedScript = false
    @State private var copiedCommand = false

    enum ImportStatus: Equatable {
        case idle, working, success(String), failure(String)
    }
    enum RevokeCheck: Equatable {
        case unchecked, checking, dead, alive, indeterminate
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                step(1, "Log in as this account") {
                    Text("Open the Claude Code token page in your browser, signed in as **\(account.displayName)**.")
                        .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button {
                        NSWorkspace.shared.open(TokenRoller.settingsURL)
                    } label: {
                        Label("Open claude.ai token settings", systemImage: "safari")
                    }
                    .controlSize(.small)
                }

                step(2, "Revoke the old tokens") {
                    Text("Copy this script, open the browser console (⌥⌘J), paste it, and press Return. It revokes every authorization token on the account.")
                        .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button {
                        TokenRoller.copyScript(orgId: account.id)
                        copiedScript = true
                    } label: {
                        Label(copiedScript ? "Copied — paste into the console" : "Copy revoke script",
                              systemImage: copiedScript ? "checkmark" : "doc.on.doc")
                    }
                    .controlSize(.small)
                    Text("Warning: this signs out every device using this account. You'll mint a fresh token next.")
                        .font(.caption2).foregroundColor(.orange).fixedSize(horizontal: false, vertical: true)
                }

                step(3, "Mint a new token") {
                    Text("In a terminal, run this and complete the browser login, then paste the `sk-ant-oat01-…` it prints.")
                        .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Text("claude setup-token")
                            .font(.system(.caption, design: .monospaced))
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(Color.secondary.opacity(0.12)).cornerRadius(4)
                        Button {
                            TokenRoller.copySetupTokenCommand()
                            copiedCommand = true
                        } label: {
                            Image(systemName: copiedCommand ? "checkmark" : "doc.on.doc")
                        }
                        .buttonStyle(.plain).help("Copy command")
                    }
                    TextField("sk-ant-oat01-...", text: $newToken)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.caption, design: .monospaced))
                        .onSubmit(importNewToken)
                    Button(action: importNewToken) {
                        Label(importStatus == .working ? "Importing…" : "Import new token",
                              systemImage: "arrow.down.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(importStatus == .working || newToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    importStatusView
                }

                if case .success = importStatus {
                    revokeVerifySection
                }

                Divider()
                HStack {
                    Spacer()
                    Button("Close", action: onClose).controlSize(.small)
                }
            }
            .padding(18)
        }
        .frame(width: 380)
        .onAppear {
            oldToken = oauthPoller.currentToken(for: account.id)
            rolledAt = oauthPoller.tokenRolledAt(for: account.id)
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Roll Token").font(.headline)
            Text(account.displayName).font(.caption).foregroundColor(.secondary)
            Label(lastRolledLabel, systemImage: "clock.arrow.circlepath")
                .font(.caption2).foregroundColor(.secondary)
        }
    }

    private var lastRolledLabel: String {
        guard let rolledAt = rolledAt else { return "Last rolled: unknown" }
        let fmt = RelativeDateTimeFormatter()
        fmt.unitsStyle = .full
        return "Last rolled \(fmt.localizedString(for: rolledAt, relativeTo: Date()))"
    }

    @ViewBuilder
    private var importStatusView: some View {
        switch importStatus {
        case .success(let msg):
            Label(msg, systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundColor(.green)
        case .failure(let msg):
            Label(msg, systemImage: "xmark.circle.fill")
                .font(.caption).foregroundColor(.red).fixedSize(horizontal: false, vertical: true)
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var revokeVerifySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Text("Confirm the old token is dead")
                .font(.caption.bold())
            Text("Pings the token this account used before the roll. It should now be rejected.")
                .font(.caption2).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button(action: verifyOldTokenDead) {
                    Label(revokeCheck == .checking ? "Checking…" : "Verify old token revoked",
                          systemImage: "shield.checkerboard")
                }
                .controlSize(.small)
                .disabled(revokeCheck == .checking || oldToken == nil)
                revokeCheckBadge
            }
            if oldToken == nil {
                Text("No prior token on record to check.")
                    .font(.caption2).foregroundColor(.secondary)
            }
        }
    }

    @ViewBuilder
    private var revokeCheckBadge: some View {
        switch revokeCheck {
        case .dead:
            Label("Revoked ✓", systemImage: "checkmark.seal.fill")
                .font(.caption).foregroundColor(.green)
        case .alive:
            Label("Still valid!", systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundColor(.orange)
        case .indeterminate:
            Label("Couldn't check", systemImage: "questionmark.circle")
                .font(.caption).foregroundColor(.secondary)
        default:
            EmptyView()
        }
    }

    // MARK: - Step scaffold

    @ViewBuilder
    private func step<Content: View>(_ n: Int, _ title: String,
                                     @ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)")
                .font(.caption.bold()).foregroundColor(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.accentColor))
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.subheadline.bold())
                content()
            }
        }
    }

    // MARK: - Actions

    private func importNewToken() {
        let token = newToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return }
        importStatus = .working
        Task {
            let (orgId, error) = await oauthPoller.addAccountWithToken(token, email: account.email)
            await MainActor.run {
                if let error = error {
                    importStatus = .failure(error)
                } else if orgId != account.id {
                    // Guard against pasting a different account's token into this roll.
                    importStatus = .failure("That token belongs to a different account (\(orgId ?? "unknown")).")
                } else {
                    importStatus = .success("New token imported and verified.")
                    revokeCheck = .unchecked
                    rolledAt = oauthPoller.tokenRolledAt(for: account.id)
                }
            }
            await oauthPoller.pollAll()
        }
    }

    private func verifyOldTokenDead() {
        guard let token = oldToken else { return }
        revokeCheck = .checking
        Task {
            let result = await oauthPoller.verifyTokenRevoked(token)
            await MainActor.run {
                switch result {
                case .some(true): revokeCheck = .dead
                case .some(false): revokeCheck = .alive
                case .none: revokeCheck = .indeterminate
                }
            }
        }
    }
}

// MARK: - Window Controller

final class RollTokenWindowController {
    static var windows: [String: NSWindow] = [:]

    static func show(for account: Account, store: UsageStore, oauthPoller: OAuthPoller) {
        if let existing = windows[account.id] {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        var window: NSWindow!
        let view = RollTokenView(account: account, store: store, oauthPoller: oauthPoller, onClose: {
            window?.close()
        })
        let hostingController = NSHostingController(rootView: view)
        if #available(macOS 13.0, *) { hostingController.sizingOptions = [.preferredContentSize] }

        window = NSWindow(contentViewController: hostingController)
        window.title = "Roll Token — \(account.displayName)"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 380, height: 560))
        window.center()
        window.isReleasedWhenClosed = false
        window.level = .floating
        windows[account.id] = window

        // Drop our retained reference when the window closes so a later roll reopens fresh.
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            windows.removeValue(forKey: account.id)
        }

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
