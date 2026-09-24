import Foundation

/// Cause-independent staleness backstop (#148): the app can lose the ability
/// to poll an account through any number of causes — a dead credential, a
/// missing `codex` binary, a re-logged-in identity, a subprocess that times
/// out every cycle, or a cause nobody has diagnosed yet. In most of them the
/// row simply stops advancing while presenting as healthy. This is the
/// single test every display/ranking path uses to decide whether a reading
/// is old enough that it must no longer be presented as current, regardless
/// of *why* it stopped updating.
///
/// Lives in the portable core (not the macOS-only popover) so `UsageStore`'s
/// ranking/selection, the popover's freshness dot, and `SelfTest` all apply
/// the identical rule — there is exactly one staleness threshold in the app,
/// not one per call site.
enum AccountFreshness {
    /// Multiplier applied to the configured poll interval to derive the
    /// staleness threshold. Large enough that a single missed cycle — a slow
    /// API response, one transient network blip — never trips it; small
    /// enough that a genuinely stuck account doesn't sit "fresh" for hours.
    /// At the default 600s poll interval this reproduces the threshold the
    /// popover's freshness dot already used before it was derived from the
    /// poll interval (10 min fresh / 30 min very-stale boundary).
    static let staleMultiplier: Double = 3

    /// The age, in seconds, past which a reading is considered stale for the
    /// given poll interval.
    static func staleThreshold(pollInterval: TimeInterval) -> TimeInterval {
        pollInterval * staleMultiplier
    }

    /// True when `age` seconds have elapsed since an account's last
    /// successful reading, relative to `pollInterval`. A slower configured
    /// interval raises the threshold along with it, so a deliberately slow
    /// `--interval` does not produce false staleness within a single cycle.
    static func isStale(age: TimeInterval, pollInterval: TimeInterval) -> Bool {
        age >= staleThreshold(pollInterval: pollInterval)
    }

    /// True when `lastUpdated` is old enough, relative to `pollInterval`, that
    /// it should no longer be presented as current. `nil` (never
    /// successfully polled) is deliberately **not** stale — that is a
    /// distinct "no data yet" state the popover already renders differently,
    /// and treating it as stale would penalize a freshly-added account that
    /// simply hasn't completed its first poll.
    static func isStale(lastUpdated: Date?, pollInterval: TimeInterval, now: Date = Date()) -> Bool {
        guard let lastUpdated = lastUpdated else { return false }
        return isStale(age: now.timeIntervalSince(lastUpdated), pollInterval: pollInterval)
    }

    /// True when a single-account summary display (the menubar badge, or any
    /// future surface with the same shape) must suppress its last-known
    /// percentage rather than present a frozen number as current. Two causes
    /// are cause-independent and either alone is sufficient: the staleness
    /// backstop above (#148), or a Codex identity that has drifted out from
    /// under a registered home (`TokenStatus.drifted`, #146) — a drifted
    /// credential's numbers stopped advancing the moment the identity
    /// changed, even if the last poll happened to land inside the staleness
    /// window.
    ///
    /// Mirrors `SummaryRow.displayUsage`'s `(isDrifted || isStale)` gate in
    /// `UsagePopoverView.swift` — same decision, reused rather than
    /// reinvented. Extracted as a pure function of simple inputs (not a
    /// method on `UsageStore` or `OAuthPoller`) so `AppDelegate.updateStatusButton()`
    /// in `main.swift` — `#if os(macOS)`-only AppKit code that cannot run
    /// under `SelfTest` — can call it after computing `isStale` and
    /// `tokenStatus` from its own `usageStore`/`oauthPoller`, while the
    /// decision itself stays covered by `SelfTest` on macOS and Linux alike.
    static func shouldSuppressPercent(isStale: Bool, tokenStatus: TokenStatus?) -> Bool {
        isStale || tokenStatus == .drifted
    }
}
