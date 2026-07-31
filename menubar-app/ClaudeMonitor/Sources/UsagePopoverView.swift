#if os(macOS)
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

// MARK: - Column layout

/// Centralized column widths so header + rows stay in lockstep.
enum SummaryColumns {
    static let radio: CGFloat = 30
    static let account: CGFloat = 150
    static let headroom: CGFloat = 80
    static let percent: CGFloat = 60
    static let fable: CGFloat = 66
    static let extra: CGFloat = 62
    static let reset: CGFloat = 80
    static let dot: CGFloat = 40
    static let chart: CGFloat = 46
    static let horizontalPadding: CGFloat = 12
}

// MARK: - Provider column vocabulary

/// A column whose *meaning* is provider-specific — today "Fable Left" and
/// "Extra" are both Anthropic-premium concepts that mean nothing for an
/// OpenAI row. Adding a provider that has something to say for a slot means
/// adding one case to `AccountProvider.columnEntry(for:)`; no conditionals
/// scattered through the header/row views.
enum ProviderColumnSlot {
    /// Anthropic: "Fable Left" — remaining premium-model weekly allowance.
    case premium
    /// Anthropic: "Extra" — overage/extra-usage balance beyond that allowance.
    case extra
}

/// One provider's declared title (and whether the slot applies to it at all)
/// for a `ProviderColumnSlot`.
struct ProviderColumnEntry {
    let title: String
    let isApplicable: Bool
    /// This provider's meaning for the slot, folded into the neutral-title
    /// tooltip whenever a mixed (or not-applicable) table falls back to it.
    let meaning: String
}

extension AccountProvider {
    /// This provider's vocabulary entry for a given column slot. The single
    /// mapping every provider (including a future Gemini client) needs to
    /// touch to make the summary table's headers make sense for its rows.
    func columnEntry(for slot: ProviderColumnSlot) -> ProviderColumnEntry {
        switch (self, slot) {
        case (.anthropic, .premium):
            return ProviderColumnEntry(
                title: "Fable Left",
                isApplicable: true,
                meaning: "Anthropic: Fable/premium weekly allowance remaining. At 0% the account switches to extra usage."
            )
        case (.anthropic, .extra):
            return ProviderColumnEntry(
                title: "Extra",
                isApplicable: true,
                meaning: "Anthropic: extra usage (overage) balance beyond the premium allowance."
            )
        case (.openai, .premium):
            return ProviderColumnEntry(
                title: "Premium",
                isApplicable: false,
                meaning: "OpenAI/Codex: no premium-allowance concept — not applicable."
            )
        case (.openai, .extra):
            return ProviderColumnEntry(
                title: "Extra",
                isApplicable: false,
                meaning: "OpenAI/Codex: no extra-usage concept — not applicable."
            )
        }
    }
}

/// Header title + tooltip for a provider-specific slot, given the providers
/// actually visible in the table right now. When exactly one provider is
/// visible *and* it declares the slot applicable, its own vocabulary wins
/// (unchanged behavior for an Anthropic-only or OpenAI-only table); anything
/// else — a mixed table, or a lone provider with nothing to say — falls back
/// to a neutral title whose tooltip spells out every provider's meaning, so
/// the mixed-table case never presents one provider's concept as if it
/// applied to all rows.
func columnHeading(
    for slot: ProviderColumnSlot,
    neutralTitle: String,
    visibleProviders: Set<AccountProvider>
) -> (title: String, tooltip: String) {
    if visibleProviders.count == 1,
       let only = visibleProviders.first {
        let entry = only.columnEntry(for: slot)
        if entry.isApplicable {
            return (entry.title, entry.meaning)
        }
    }
    let tooltip = AccountProvider.allCases
        .map { $0.columnEntry(for: slot).meaning }
        .joined(separator: " ")
    return (neutralTitle, tooltip)
}

// MARK: - Sorting

enum SummarySort: String {
    case account, headroom, sessionPercent, sessionReset, weeklyPercent, weeklyReset, fablePercent, extraUsage, fresh, token

    /// First-click direction for this column — "best first" intuition.
    var defaultDirection: SortDirection {
        switch self {
        case .headroom: return .desc   // higher score = better, show first
        default: return .asc           // lower % / sooner reset / fresher / better-status first
        }
    }
}

enum SortDirection {
    case asc, desc
    func toggled() -> SortDirection { self == .asc ? .desc : .asc }
}

// `headroomScore` now lives in the portable core (UsageStore.swift) and reads
// through `UsageRecord.rateLimit`, so the headless Linux daemon scores accounts
// the same way this popover does.

/// Sort key for the Extra-usage column. Lower = more attention needed.
/// nil (no probe yet) sorts last.
func extraUsageUrgency(_ usage: UsageRecord?) -> Double? {
    guard let usage = usage else { return nil }
    switch usage.extraUsageState {
    case .unknown:        return nil
    case .empty:          return 0            // depleted — needs a recharge
    case .percent(let r): return 1 + r        // metered: lower remaining sorts first
    case .active:         return 200          // drawing (unmetered/unlimited) — fine
    case .ready:          return 300          // available, unused
    case .off:            return 400          // not configured
    }
}

// Reset-time sorting now reads `RateLimitWindow.resetAt` (already a `Date`) via
// `UsageRecord.rateLimit`, so the string-parsing helper that used to live here
// is gone; `UsageRecord.parseISO` is the single ISO-8601 parse point.

// MARK: - Provider badge

/// Compact per-provider tag shown ahead of the account name, so a row's upstream
/// is visible at a glance in a mixed Anthropic/OpenAI list. It sits inside the
/// existing Account column rather than adding a new one, keeping every other
/// column (and the popover width) exactly where it was.
struct ProviderBadge: View {
    let provider: AccountProvider

    /// Both glyphs are drawn at one point per cell and centred in a common
    /// 16×16 box: it keeps them pixel-crisp (one cell = two device pixels at
    /// 2×) and stops a 16×10 mascot and a 16×16 rosette from ragged-edging the
    /// account names that follow them in the column.
    private static let box: CGFloat = 16
    private static let cell: CGFloat = 1

    private var tint: Color {
        switch provider {
        // The mascot's own terracotta (#B87352) rather than systemOrange, so
        // it reads as the artwork instead of a recoloured approximation.
        case .anthropic: return Color(red: 184 / 255, green: 115 / 255, blue: 82 / 255)
        case .openai: return Color(nsColor: .systemTeal)
        }
    }

    private var glyph: [String] {
        switch provider {
        case .anthropic: return ProviderGlyph.anthropic
        case .openai: return ProviderGlyph.openai
        }
    }

    var body: some View {
        PixelSprite(rows: glyph, color: tint, cell: Self.cell)
            .frame(width: Self.box, height: Self.box, alignment: .center)
            .help(provider.displayName)
            .accessibilityLabel(provider.displayName)
    }
}

/// Pixel-art marks for each upstream, drawn from a bitmap rather than bundled
/// as image assets — the package ships no resources and has no dependencies,
/// and a handful of filled rects stays crisp at any scale factor.
private enum ProviderGlyph {
    /// The Claude Code mascot: eyes in columns 4 and 11, four legs at
    /// 3/5/10/12, drawn 16×13.
    ///
    /// The source art is 16×10. Beside the rosette — which fills its whole
    /// 16×16 box — that read noticeably light, so three rows are added to the
    /// body and arm band. Growing those rather than scaling the whole sprite
    /// keeps one cell = one point (a proportional 1.3× would land on
    /// half-pixels and resample the art), and keeps the legs stubby: lengthening
    /// them instead made the creature spindly.
    static let anthropic = [
        "..############..",
        "..############..",
        "..############..",
        "..##.######.##..",
        "..##.######.##..",
        "################",
        "################",
        "################",
        "..############..",
        "..############..",
        "..############..",
        "...#.#....#.#...",
        "...#.#....#.#...",
    ]

    /// OpenAI's rosette, as a 16×16 outline.
    ///
    /// An earlier pass tried to fit this into the mascot's ten-pixel height and
    /// failed: thin strokes blur to a plain circle and thick ones fill the
    /// centre hole, because the mark's legibility depends on *both* the hole
    /// and the interweaving. Sixteen cells is the first size where the six-fold
    /// structure survives 1-bit rendering, so the box is sized to the harder
    /// glyph and the mascot is centred inside it.
    static let openai = [
        ".......####.....",
        "...#####...#....",
        "..##.##....##...",
        ".##..#..#####...",
        ".#..##.#.....##.",
        ".#..#.#.......##",
        ".#..#.#######..#",
        "###.###...#.##.#",
        "#.##.#...###.###",
        "#..#######.#..#.",
        "##.......#.#..#.",
        ".##.....#.##..#.",
        "...#####..#..##.",
        "...##....##.##..",
        "....#...#####...",
        ".....####.......",
    ]
}

/// Renders a row-per-string bitmap as filled cells. `#` fills, anything else
/// stays clear. One `Canvas` per badge rather than a `ZStack` of ~160
/// `Rectangle`s, since these redraw for every row on every table update.
private struct PixelSprite: View {
    let rows: [String]
    let color: Color
    /// Size of one bitmap cell in points. Fixed rather than derived from a
    /// target height so every glyph lands on whole pixels regardless of its
    /// grid, which is what keeps the art crisp instead of resampled.
    let cell: CGFloat

    var body: some View {
        let columns = rows.map(\.count).max() ?? 0
        Canvas { context, _ in
            for (rowIndex, row) in rows.enumerated() {
                for (columnIndex, character) in row.enumerated() where character == "#" {
                    context.fill(
                        Path(CGRect(
                            x: CGFloat(columnIndex) * cell,
                            y: CGFloat(rowIndex) * cell,
                            width: cell,
                            height: cell
                        )),
                        with: .color(color)
                    )
                }
            }
        }
        .frame(width: cell * CGFloat(columns), height: cell * CGFloat(rows.count))
    }
}

/// Lower rank = "better" status (valid first, missing last).
func tokenStatusRank(_ status: TokenStatus) -> Int {
    switch status {
    case .valid: return 0
    case .refreshing: return 1
    case .expired: return 2
    case .revoked: return 3
    case .error: return 4
    case .missing: return 5
    }
}

struct UsagePopoverView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var oauthPoller: OAuthPoller
    @ObservedObject var heightManager: PopoverHeightManager
    var onAddAccount: (() -> Void)?
    @Environment(\.colorScheme) var colorScheme
    @State private var showGitHubLink = false
    @State private var titleHoverTimer: Timer?
    @State private var showRemoveConfirmation = false
    @State private var accountToRemove: Account?
    @State private var sortBy: SummarySort = .headroom
    @State private var sortDir: SortDirection = .desc
    @State private var clipboardHasAccounts = false
    @State private var transferStatus: String?

    /// Polls the pasteboard so the Copy/Paste toggle reflects clipboard contents.
    private let clipboardTimer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    /// Space available for the scrolling row list = popover height minus fixed chrome.
    private var scrollViewMaxHeight: CGFloat {
        heightManager.currentHeight - PopoverHeightManager.chromeHeight
    }

    /// Row count used to size the popover. The setup/empty/error states show a
    /// guide instead of the table, so they size against zero rows.
    private var effectiveRowCount: Int {
        (store.error != nil || store.accounts.isEmpty) ? 0 : store.accounts.count
    }

    /// Providers represented among the currently-configured accounts. Drives
    /// whether the premium/extra column headers show a provider-specific
    /// title or fall back to a neutral one — see `columnHeading`.
    private var visibleProviders: Set<AccountProvider> {
        Set(store.accounts.map(\.provider))
    }

    /// Accounts paired with latest usage, sorted by the user-selected column.
    /// Recomputed every render so the table sorts live as usage updates.
    private var sortedRows: [(account: Account, usage: UsageRecord?)] {
        let pairs = store.accounts.map { ($0, store.latestUsage[$0.id]) }
        return pairs.sorted { compareRows($0, $1) }
    }

    /// Lookup table for token status by account ID — built once per render
    /// so sorting by Token doesn't scan the array N×log(N) times.
    private var tokenStatusByAccount: [String: TokenStatus] {
        var map: [String: TokenStatus] = [:]
        for cs in oauthPoller.credentialStatuses {
            if let id = cs.accountId { map[id] = cs.status }
        }
        return map
    }

    /// Final tiebreak when a column's primary comparison is exactly equal
    /// (common for freshly-added or idle accounts that all read 0%): order by
    /// natural display name instead of falling through to arbitrary
    /// insertion/UUID order, and only fall back to account id when even the
    /// display names are indistinguishable, so the order stays total and
    /// stable.
    private func stableTiebreak(_ a: Account, _ b: Account) -> Bool {
        let cmp = NaturalSort.compare(a.displayName, b.displayName)
        if cmp != .orderedSame { return cmp == .orderedAscending }
        return a.id < b.id
    }

    /// Sort comparator for two rows under the current column/direction.
    /// Rows without data sort to the bottom regardless of direction.
    private func compareRows(_ a: (Account, UsageRecord?), _ b: (Account, UsageRecord?)) -> Bool {
        // Account name sorts naturally: digit runs compare by value, so
        // agent-10 follows agent-9 instead of landing next to agent-1.
        if case .account = sortBy {
            let cmp = NaturalSort.compare(a.0.displayName, b.0.displayName)
            if cmp == .orderedSame { return stableTiebreak(a.0, b.0) }
            return sortDir == .asc
                ? (cmp == .orderedAscending)
                : (cmp == .orderedDescending)
        }

        let (av, bv) = sortValues(a, b, for: sortBy)
        switch (av, bv) {
        case (nil, nil): return stableTiebreak(a.0, b.0)
        case (nil, _):   return false          // nil rows go last
        case (_, nil):   return true
        case let (.some(x), .some(y)):
            if x == y { return stableTiebreak(a.0, b.0) }
            return sortDir == .asc ? (x < y) : (x > y)
        }
    }

    /// Numeric value to compare for each column. `nil` = no data → sorts last.
    private func sortValues(
        _ a: (Account, UsageRecord?), _ b: (Account, UsageRecord?),
        for column: SummarySort
    ) -> (Double?, Double?) {
        switch column {
        case .headroom:
            return (headroomScore(a.1), headroomScore(b.1))
        case .sessionPercent:
            // Read through the shared window model: a provider that reports no
            // session window yields nil here and sorts last, rather than
            // pretending to be at 0%.
            return (a.1?.rateLimit.session?.usedPercent, b.1?.rateLimit.session?.usedPercent)
        case .weeklyPercent:
            return (a.1?.rateLimit.weekly?.usedPercent, b.1?.rateLimit.weekly?.usedPercent)
        case .fablePercent:
            // Sort by Fable used (asc = most remaining last, matching other % columns).
            return (a.1?.fablePercent, b.1?.fablePercent)
        case .extraUsage:
            // Ascending = "needs attention first": empty → low balance → in use → ready → off.
            return (extraUsageUrgency(a.1), extraUsageUrgency(b.1))
        case .sessionReset:
            return (a.1?.rateLimit.session?.resetAt?.timeIntervalSinceNow,
                    b.1?.rateLimit.session?.resetAt?.timeIntervalSinceNow)
        case .weeklyReset:
            return (a.1?.rateLimit.weekly?.resetAt?.timeIntervalSinceNow,
                    b.1?.rateLimit.weekly?.resetAt?.timeIntervalSinceNow)
        case .fresh:
            // Data age in seconds (lower = fresher). nil usage → nil → sorts last.
            return (a.1.map { -$0.timestamp.timeIntervalSinceNow },
                    b.1.map { -$0.timestamp.timeIntervalSinceNow })
        case .token:
            let lookup = tokenStatusByAccount
            return (Double(tokenStatusRank(lookup[a.0.id] ?? .missing)),
                    Double(tokenStatusRank(lookup[b.0.id] ?? .missing)))
        case .account:
            return (nil, nil)  // handled above
        }
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
            }
            .padding()

            Divider()

            if let error = store.error {
                SetupGuideView(oauthPoller: oauthPoller, store: store, error: error, onAddAccount: onAddAccount)
            } else if store.accounts.isEmpty {
                SetupGuideView(oauthPoller: oauthPoller, store: store, error: nil, onAddAccount: onAddAccount)
            } else {
                SummaryHeaderRow(sortBy: $sortBy, sortDir: $sortDir, visibleProviders: visibleProviders)
                Divider()

                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(sortedRows, id: \.account.id) { item in
                            SummaryRow(
                                account: item.account,
                                usage: item.usage,
                                store: store,
                                oauthPoller: oauthPoller,
                                onRemove: {
                                    accountToRemove = item.account
                                    showRemoveConfirmation = true
                                }
                            )
                        }
                    }
                }
                .frame(maxHeight: scrollViewMaxHeight)
            }

            Divider()

            // Footer
            HStack {
                Button(action: { onAddAccount?() }) {
                    Label("Add Account", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                // Copy accounts to the clipboard for transfer to another machine,
                // or — when the clipboard already holds account data — paste it in.
                if clipboardHasAccounts {
                    Button(action: { pasteAccounts() }) {
                        Label("Paste Accounts", systemImage: "arrow.down.doc.on.clipboard")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                } else {
                    Button(action: { copyAccounts() }) {
                        Label("Copy Accounts", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(store.accounts.isEmpty)
                }

                if let status = transferStatus {
                    Text(status)
                        .font(.caption)
                        .foregroundColor(.secondary)
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
        .frame(width: PopoverHeightManager.popoverWidth, height: heightManager.currentHeight)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            heightManager.update(rowCount: effectiveRowCount)
            clipboardHasAccounts = Self.clipboardContainsAccounts()
        }
        .onReceive(clipboardTimer) { _ in
            clipboardHasAccounts = Self.clipboardContainsAccounts()
        }
        .onChange(of: effectiveRowCount) { _, newCount in
            heightManager.update(rowCount: newCount)
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
        let seconds = -date.timeIntervalSinceNow
        if seconds < 60 { return "just now" }
        return "\(formatInterval(seconds)) ago"
    }

    private func removeAccount(_ account: Account) {
        let credentials = oauthPoller.loadActiveCredentials()
        for cred in credentials where cred.accountId == account.id {
            oauthPoller.deactivateCredential(cred)
        }
        store.clearAccountData(accountId: account.id)
    }

    // MARK: - Copy / Paste Accounts

    /// True when the general pasteboard holds text with ACCOUNT_EMAIL_N /
    /// ACCOUNT_KEY_N pairs — i.e. accounts copied from this or another instance.
    static func clipboardContainsAccounts() -> Bool {
        guard let s = NSPasteboard.general.string(forType: .string) else { return false }
        return s.contains("ACCOUNT_EMAIL_") && s.contains("ACCOUNT_KEY_")
    }

    /// Serialize active accounts into env format and put them on the clipboard so
    /// they can be pasted into a Claude Monitor on another machine.
    private func copyAccounts() {
        guard let env = oauthPoller.exportAccountsEnv() else {
            flashTransferStatus("Nothing to copy")
            return
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(env, forType: .string)
        clipboardHasAccounts = true
        let count = store.accounts.count
        flashTransferStatus("Copied \(count) account\(count == 1 ? "" : "s")")
    }

    /// Import accounts from env-formatted text on the clipboard.
    private func pasteAccounts() {
        guard let content = NSPasteboard.general.string(forType: .string) else { return }
        transferStatus = "Importing…"
        store.ensureDatabase()
        Task {
            let results = await oauthPoller.importFromEnvString(content)
            await MainActor.run {
                let ok = results.filter { $0.success }.count
                guard ok > 0 else {
                    flashTransferStatus(results.first?.error ?? "No accounts imported")
                    return
                }

                store.loadFromDatabase()

                // Replace semantics: the pasted list is now the full set. Remove any
                // account whose email isn't in the paste (compared case-insensitively).
                // Emails come from the paste even for entries whose token failed to
                // import, so a transient failure won't delete an account that's listed.
                //
                // Scoped to Anthropic rows: the env format can only *express*
                // Anthropic credentials (see `exportAccountsEnv`), so an
                // Anthropic-only paste must not silently delete the OpenAI
                // accounts it was never able to describe.
                let pastedEmails = Set(results.map { $0.email.lowercased() })
                let toRemove = store.accounts.filter {
                    $0.provider == .anthropic
                        && !pastedEmails.contains(($0.email ?? "").lowercased())
                }
                for account in toRemove { removeAccount(account) }
                if !toRemove.isEmpty { store.loadFromDatabase() }

                let removedNote = toRemove.isEmpty ? "" : " · removed \(toRemove.count)"
                flashTransferStatus("Imported \(ok) of \(results.count)\(removedNote)")
            }
        }
    }

    /// Show a transient status message next to the button, then clear it.
    private func flashTransferStatus(_ message: String) {
        transferStatus = message
        Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            await MainActor.run { transferStatus = nil }
        }
    }
}

// MARK: - Summary Table — Header

struct SummaryHeaderRow: View {
    @Binding var sortBy: SummarySort
    @Binding var sortDir: SortDirection
    /// Providers represented among the rows currently in the table — see
    /// `columnHeading` for how this picks the premium/extra titles below.
    let visibleProviders: Set<AccountProvider>

    private var premiumHeading: (title: String, tooltip: String) {
        columnHeading(for: .premium, neutralTitle: "Premium Left", visibleProviders: visibleProviders)
    }

    private var extraHeading: (title: String, tooltip: String) {
        columnHeading(for: .extra, neutralTitle: "Extra", visibleProviders: visibleProviders)
    }

    var body: some View {
        HStack(spacing: 0) {
            Text("Bar")
                .frame(width: SummaryColumns.radio, alignment: .center)
                .help("Account shown in the menu bar")
            SortableHeader(title: "Account", column: .account,
                           width: SummaryColumns.account, alignment: .leading,
                           sortBy: $sortBy, sortDir: $sortDir)
            SortableHeader(title: "Headroom", column: .headroom,
                           width: SummaryColumns.headroom, alignment: .trailing,
                           sortBy: $sortBy, sortDir: $sortDir)
            SortableHeader(title: "Session %", column: .sessionPercent,
                           width: SummaryColumns.percent, alignment: .trailing,
                           sortBy: $sortBy, sortDir: $sortDir)
            SortableHeader(title: "Sess Reset", column: .sessionReset,
                           width: SummaryColumns.reset, alignment: .trailing,
                           sortBy: $sortBy, sortDir: $sortDir)
            SortableHeader(title: "Weekly %", column: .weeklyPercent,
                           width: SummaryColumns.percent, alignment: .trailing,
                           sortBy: $sortBy, sortDir: $sortDir)
            SortableHeader(title: "Wk Reset", column: .weeklyReset,
                           width: SummaryColumns.reset, alignment: .trailing,
                           sortBy: $sortBy, sortDir: $sortDir)
            SortableHeader(title: premiumHeading.title, column: .fablePercent,
                           width: SummaryColumns.fable, alignment: .trailing,
                           sortBy: $sortBy, sortDir: $sortDir,
                           tooltip: premiumHeading.tooltip)
            SortableHeader(title: extraHeading.title, column: .extraUsage,
                           width: SummaryColumns.extra, alignment: .trailing,
                           sortBy: $sortBy, sortDir: $sortDir,
                           tooltip: extraHeading.tooltip)
            SortableHeader(title: "Fresh", column: .fresh,
                           width: SummaryColumns.dot, alignment: .center,
                           sortBy: $sortBy, sortDir: $sortDir)
            SortableHeader(title: "Token", column: .token,
                           width: SummaryColumns.dot, alignment: .center,
                           sortBy: $sortBy, sortDir: $sortDir)
            Text("History")
                .frame(width: SummaryColumns.chart, alignment: .center)
        }
        .font(.caption.bold())
        .foregroundColor(.secondary)
        .padding(.horizontal, SummaryColumns.horizontalPadding)
        .padding(.vertical, 8)
    }
}

/// A clickable column header. Tapping switches sort to this column (using
/// the column's default direction); tapping the active column flips direction.
struct SortableHeader: View {
    let title: String
    let column: SummarySort
    let width: CGFloat
    let alignment: Alignment
    @Binding var sortBy: SummarySort
    @Binding var sortDir: SortDirection
    /// Overrides the default "Sort by <title>" tooltip. Used by columns whose
    /// title is a neutral stand-in (see `columnHeading`) so the tooltip can
    /// still explain what each provider means by it.
    var tooltip: String? = nil

    private var isActive: Bool { sortBy == column }

    var body: some View {
        Button(action: handleTap) {
            HStack(spacing: 2) {
                Text(title)
                if isActive {
                    Image(systemName: sortDir == .asc ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                }
            }
            .foregroundColor(isActive ? .primary : .secondary)
        }
        .buttonStyle(.plain)
        .frame(width: width, alignment: alignment)
        .help(tooltip ?? "Sort by \(title)")
        .onHover { hovering in
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }

    private func handleTap() {
        if sortBy == column {
            sortDir = sortDir.toggled()
        } else {
            sortBy = column
            sortDir = column.defaultDirection
        }
    }
}

// MARK: - Summary Table — Row

struct SummaryRow: View {
    let account: Account
    let usage: UsageRecord?
    let store: UsageStore
    let oauthPoller: OAuthPoller
    var onRemove: (() -> Void)? = nil
    @Environment(\.colorScheme) var colorScheme
    @State private var isEditingName = false
    @State private var editedName = ""
    @FocusState private var isFocused: Bool

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

    /// True when this row is the one whose usage is shown in the menubar.
    private var isMenubarSelected: Bool {
        store.effectivePrimaryAccountId == account.id
    }

    /// True when the user has explicitly pinned this row (vs. just being the
    /// auto-sorted first account). Determines whether re-clicking clears.
    private var isExplicitlyPinned: Bool {
        store.primaryAccountId == account.id
    }

    var body: some View {
        HStack(spacing: 0) {
            // Menu-bar source radio
            Button(action: togglePrimary) {
                Image(systemName: isMenubarSelected
                      ? "largecircle.fill.circle"
                      : "circle")
                    .foregroundColor(isMenubarSelected ? .accentColor : .secondary)
                    .opacity(isMenubarSelected && !isExplicitlyPinned ? 0.55 : 1.0)
            }
            .buttonStyle(.plain)
            .frame(width: SummaryColumns.radio, alignment: .center)
            .help(isExplicitlyPinned
                  ? "Pinned to menu bar — click to clear"
                  : (isMenubarSelected
                     ? "Auto-selected (most available) — click to pin"
                     : "Click to show this account in the menu bar"))
            .onHover { hovering in
                if hovering {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }

            // Account name — inline-editable (double-click to rename)
            Group {
                if isEditingName {
                    HStack(spacing: 4) {
                        TextField("Name", text: $editedName)
                            .textFieldStyle(.plain)
                            .focused($isFocused)
                            .onSubmit { saveRename() }
                            .onExitCommand { isEditingName = false }
                        if account.accountName != nil {
                            Button(action: restoreDefaultName) {
                                Image(systemName: "arrow.counterclockwise")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Restore default name")
                        }
                        Button(action: saveRename) {
                            Image(systemName: "checkmark")
                                .font(.caption2)
                                .foregroundColor(.green)
                        }
                        .buttonStyle(.plain)
                        Button(action: { isEditingName = false }) {
                            Image(systemName: "xmark")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                } else {
                    HStack(spacing: 4) {
                        ProviderBadge(provider: account.provider)
                        Text(account.displayName)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { startRename() }
                    .help("\(account.provider.displayName) — double-click to rename")
                }
            }
            .frame(width: SummaryColumns.account, alignment: .leading)

            headroomCell
                .frame(width: SummaryColumns.headroom, alignment: .trailing)

            // Session and weekly cells both read the shared window model. When a
            // provider reports no session window at all, `session` is nil and
            // both cells render "—" rather than a misleading 0% / "now".
            percentText(usage?.rateLimit.session?.usedPercent)
                .frame(width: SummaryColumns.percent, alignment: .trailing)

            Text(resetLabel(usage?.rateLimit.session?.resetAt))
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .frame(width: SummaryColumns.reset, alignment: .trailing)

            percentText(usage?.rateLimit.weekly?.usedPercent)
                .frame(width: SummaryColumns.percent, alignment: .trailing)

            Text(resetLabel(usage?.rateLimit.weekly?.resetAt))
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .frame(width: SummaryColumns.reset, alignment: .trailing)

            fableCell
                .frame(width: SummaryColumns.fable, alignment: .trailing)

            extraCell
                .frame(width: SummaryColumns.extra, alignment: .trailing)

            Circle()
                .fill(freshnessDotColor)
                .frame(width: 8, height: 8)
                .help(freshnessLabel)
                .frame(width: SummaryColumns.dot)

            Circle()
                .fill(tokenDotColor)
                .frame(width: 8, height: 8)
                .help(tokenStatus.rawValue)
                .frame(width: SummaryColumns.dot)

            // History column — opens the detailed chart window
            Button(action: openChart) {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .foregroundColor(.accentColor)
            }
            .buttonStyle(.plain)
            .frame(width: SummaryColumns.chart)
            .help("Open usage history")
            .onHover { hovering in
                if hovering {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }
        }
        .font(.caption)
        .padding(.horizontal, SummaryColumns.horizontalPadding)
        .padding(.vertical, 6)
        .background(colorScheme == .dark ? Color.white.opacity(0.02) : Color.clear)
        .contextMenu {
            Button(action: openChart) {
                Label("Open History", systemImage: "chart.line.uptrend.xyaxis")
            }
            Button(action: startRename) {
                Label("Rename", systemImage: "pencil")
            }
            // The Roll Token wizard drives undocumented claude.ai endpoints, so
            // it only makes sense for Anthropic rows. OpenAI credentials are
            // refreshed automatically and re-imported with `codex import`.
            if account.provider == .anthropic {
                Button(action: openRollToken) {
                    Label("Roll Token…", systemImage: "arrow.triangle.2.circlepath")
                }
            }
            Divider()
            Button(role: .destructive, action: { onRemove?() }) {
                Label("Remove", systemImage: "trash")
            }
        }
    }

    private func openChart() {
        ChartWindowController.showChart(for: account, store: store, oauthPoller: oauthPoller)
    }

    private func openRollToken() {
        RollTokenWindowController.show(for: account, store: store, oauthPoller: oauthPoller)
    }

    private func togglePrimary() {
        // Clicking the currently-pinned row clears the pin (back to auto).
        // Clicking any other row pins it.
        store.setPrimaryAccount(isExplicitlyPinned ? nil : account.id)
    }

    private func startRename() {
        editedName = account.accountName ?? account.displayName
        isEditingName = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            isFocused = true
        }
    }

    private func saveRename() {
        let trimmed = editedName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            store.updateAccountName(accountId: account.id, newName: trimmed)
        }
        isEditingName = false
    }

    private func restoreDefaultName() {
        store.updateAccountName(accountId: account.id, newName: nil)
        isEditingName = false
    }

    /// "—" when the window is absent or carries no reset instant — the same
    /// rendering an OpenAI account with no session window gets.
    private func resetLabel(_ date: Date?) -> String {
        guard let date = date else { return "—" }
        let interval = date.timeIntervalSinceNow
        if interval <= 0 { return "now" }
        return formatInterval(interval)
    }

    @ViewBuilder
    private var headroomCell: some View {
        if let score = headroomScore(usage) {
            Text("\(Int(score.rounded()))")
                .fontWeight(.semibold)
                .foregroundColor(colorForHeadroom(score))
                .help("Higher = more available capacity (100 = none used, 0 = capped)")
        } else {
            Text("—")
                .foregroundColor(.secondary)
        }
    }

    private func colorForHeadroom(_ score: Double) -> Color {
        if score >= 70 { return Color(nsColor: .systemGreen) }
        if score >= 30 { return .primary }
        if score >= 5  { return Color(nsColor: .systemOrange) }
        return Color(nsColor: .systemRed)
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

    /// Fable/premium weekly allowance remaining, colored by how much is left.
    @ViewBuilder
    private var fableCell: some View {
        if let remaining = usage?.fableRemaining {
            Text("\(Int(remaining.rounded()))%")
                .foregroundColor(colorForRemaining(remaining))
                .help("Fable/premium weekly allowance remaining. At 0% the account switches to extra usage.")
        } else {
            Text("—")
                .foregroundColor(.secondary)
                .help("No premium-model probe yet")
        }
    }

    private func colorForRemaining(_ remaining: Double) -> Color {
        if remaining <= 0 { return Color(nsColor: .systemRed) }
        if remaining < 10 { return Color(nsColor: .systemOrange) }
        return .primary
    }

    /// Extra-usage (overage) balance. The API gives no dollar figure, and an
    /// unlimited balance never meters (utilization stays 0), so we show a state
    /// word and a percentage only when the budget is actually metered.
    @ViewBuilder
    private var extraCell: some View {
        let display = extraDisplay
        Text(display.0)
            .foregroundColor(display.1)
            .help(extraUsageTooltip)
    }

    private var extraDisplay: (String, Color) {
        switch usage?.extraUsageState ?? .unknown {
        case .unknown: return ("—", .secondary)
        case .off:     return ("off", .secondary)
        case .empty:   return ("empty", Color(nsColor: .systemRed))
        case .active:  return ("on", Color(nsColor: .systemGreen))
        case .ready:   return ("ready", .primary)
        case .percent(let r):
            let c: Color = r <= 0 ? Color(nsColor: .systemRed)
                         : r < 15 ? Color(nsColor: .systemOrange) : .primary
            return ("\(Int(r.rounded()))%", c)
        }
    }

    private var extraUsageTooltip: String {
        switch usage?.extraUsageState ?? .unknown {
        case .unknown: return "No premium-model probe yet"
        case .off:     return "Extra usage not enabled for this account (org_level_disabled)"
        case .empty:   return "Extra usage exhausted — needs a recharge (out_of_credits)"
        case .active:  return "Currently drawing on extra usage (unlimited/unmetered — no percentage to show)"
        case .ready:   return "Extra usage available, not yet in use"
        case .percent(let r): return "Extra usage: \(Int(r.rounded()))% of the configured budget remaining"
        }
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
    /// Called after a successful add/import so the host can refresh polled state.
    var onImported: (() -> Void)? = nil

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

            Divider()

            // OpenAI / Codex — imported from Codex CLI's own credential store
            // rather than pasted, because a ChatGPT OAuth credential is a
            // three-part (access + refresh + expiry) object, not a single
            // long-lived string.
            VStack(alignment: .leading, spacing: 6) {
                Text("OpenAI (Codex)")
                    .font(.caption.bold())
                    .foregroundColor(.secondary)
                Text("Imports the credential `codex login` stored at \(CodexAuth.defaultAuthPath)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)

                Button(action: importCodex) {
                    Label(isAdding ? "Importing…" : "Import Codex Account",
                          systemImage: "person.badge.key")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isAdding)
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
                    .foregroundColor(msg.contains("Error") || msg.contains("Invalid")
                                     || msg.contains("Failed") || msg.contains("No ") ? .orange : .green)
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
                    onImported?()
                } else {
                    statusMessage = error ?? "Failed to add account"
                }
            }
        }
    }

    private func importCodex() {
        isAdding = true
        statusMessage = nil
        store.ensureDatabase()

        Task {
            let (accountId, error) = await oauthPoller.importCodexCredential()
            await MainActor.run {
                isAdding = false
                if accountId != nil {
                    statusMessage = "Added OpenAI account"
                    store.loadFromDatabase()
                    onImported?()
                } else {
                    statusMessage = error ?? "Failed to import Codex credential"
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
                    onImported?()
                } else {
                    statusMessage = "No accounts imported"
                }
            }
        }
    }
}

#endif  // os(macOS)
