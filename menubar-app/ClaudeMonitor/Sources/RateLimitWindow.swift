import Foundation

/// Provider-agnostic rate-limit model shared by every upstream this app polls.
///
/// Anthropic and OpenAI report the *same* information in different shapes:
///
/// | | Anthropic | OpenAI / Codex |
/// |---|---|---|
/// | transport | `anthropic-ratelimit-unified-{5h,7d}-*` response headers | `GET /backend-api/wham/usage` JSON body |
/// | windows | one header family per window, named `5h` / `7d` | `rate_limit.primary_window` / `.secondary_window` |
/// | usage figure | `-utilization` (0.0–1.0) | `used_percent` (0–100) |
/// | window length | implied by the header name | `limit_window_seconds` |
/// | reset | `-reset` (unix epoch seconds) | `reset_at` (unix epoch seconds) |
///
/// The types below are the common denominator. See
/// `docs/spikes/2026-07-30-codex-usage-probe.md` § "Live verification
/// (AUTHORITATIVE)" for the verified OpenAI wire contract this models.
///
/// Portable core: no AppKit / SwiftUI / Combine / os.Logger — builds on Linux.

// MARK: - Provider identity

/// Which upstream an account belongs to.
enum AccountProvider: String, CaseIterable, Codable {
    case anthropic
    case openai

    /// Every account that predates multi-provider support is Anthropic, so an
    /// absent or unrecognized value resolves here rather than failing.
    static let fallback: AccountProvider = .anthropic

    /// Tolerant parse of a stored/serialized provider value. Unknown values
    /// (a row written by a newer build) and missing values (a row written
    /// before the `provider` column existed) both fall back to `.anthropic`,
    /// so a strange value can never take the poll loop down.
    init(stored: String?) {
        guard let raw = stored?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !raw.isEmpty,
              let parsed = AccountProvider(rawValue: raw) else {
            self = AccountProvider.fallback
            return
        }
        self = parsed
    }

    var displayName: String {
        switch self {
        case .anthropic: return "Anthropic"
        case .openai: return "OpenAI"
        }
    }

    /// Two-letter badge shown in the popover's account column, where there is
    /// no room for the full name. Lives here (portable core) rather than in the
    /// macOS view so the headless daemon's log lines can use the same code.
    var shortCode: String {
        switch self {
        case .anthropic: return "AN"
        case .openai: return "OA"
        }
    }
}

// MARK: - Window kind

/// Which quota bucket a window represents. **Always derived from the window's
/// duration, never from its position in the provider's response**: the
/// live-verified Codex probe returned a *weekly* `primary_window` with
/// `secondary_window: null`, so "primary = session" is wrong.
enum RateLimitWindowKind: Equatable {
    /// The short rolling window (Anthropic's 5h bucket, Codex's session bucket).
    case session
    /// The long rolling window (both providers use 7 days).
    case weekly
    /// A window whose length matches neither bucket; the payload is its length.
    case other(TimeInterval)
    /// The provider gave a usage figure but no window length.
    case unknown

    /// Nominal length of this bucket in seconds, used when a source is
    /// kind-labelled but carries no explicit duration (e.g. Anthropic's
    /// `5h`/`7d` header families, or this app's kind-keyed `usage_history`
    /// columns).
    var nominalDuration: TimeInterval? {
        switch self {
        case .session: return 5 * 3600
        case .weekly: return 7 * 86400
        case .other(let seconds): return seconds
        case .unknown: return nil
        }
    }

    /// Short key used in serialized output (`ranking.json`, logs).
    var key: String {
        switch self {
        case .session: return "5h"
        case .weekly: return "7d"
        case .other(let seconds): return "\(Int(seconds))s"
        case .unknown: return "unknown"
        }
    }
}

// MARK: - Window

/// One rate-limit window: how much of it is spent, how long it is, and when it
/// resets. Both providers populate this type.
struct RateLimitWindow: Equatable {
    let kind: RateLimitWindowKind
    /// Percentage of the window consumed, 0–100. Anthropic reports a 0.0–1.0
    /// utilization fraction (multiply by 100); OpenAI reports `used_percent`
    /// already on this scale.
    let usedPercent: Double
    /// Length of the window in seconds, when the provider states it.
    let durationSeconds: TimeInterval?
    /// When the window rolls over, when the provider states it.
    let resetAt: Date?
    /// Provider status string for this window (`allowed` / `allowed_warning` /
    /// `rejected` on Anthropic), if any.
    let status: String?

    /// Explicit-kind initializer — for sources that already know which bucket a
    /// figure belongs to (Anthropic's `-5h-` / `-7d-` header families, and this
    /// app's kind-keyed `usage_history` columns).
    init(
        kind: RateLimitWindowKind,
        usedPercent: Double,
        durationSeconds: TimeInterval? = nil,
        resetAt: Date? = nil,
        status: String? = nil
    ) {
        self.kind = kind
        self.usedPercent = usedPercent
        self.durationSeconds = durationSeconds ?? kind.nominalDuration
        self.resetAt = resetAt
        self.status = status
    }

    /// Duration-derived initializer — for providers that return an unlabelled
    /// window alongside its length (OpenAI's `primary_window` /
    /// `secondary_window`, each carrying `limit_window_seconds`).
    init(
        usedPercent: Double,
        durationSeconds: TimeInterval?,
        resetAt: Date? = nil,
        status: String? = nil
    ) {
        self.kind = RateLimitWindow.kind(forDuration: durationSeconds)
        self.usedPercent = usedPercent
        self.durationSeconds = durationSeconds
        self.resetAt = resetAt
        self.status = status
    }

    /// Windows at or under this length are session windows. Anthropic's is 5h
    /// and Codex's session bucket is nominally the same; the bound is generous
    /// so a provider re-tuning its short window still classifies correctly.
    static let sessionUpperBound: TimeInterval = 6 * 3600
    /// Windows longer than `sessionUpperBound` and no longer than this are the
    /// weekly bucket (both providers report 604800s today).
    static let weeklyUpperBound: TimeInterval = 14 * 86400

    /// Classify a window by its length. This is the single place the
    /// duration → bucket mapping lives.
    static func kind(forDuration seconds: TimeInterval?) -> RateLimitWindowKind {
        guard let seconds = seconds, seconds > 0 else { return .unknown }
        if seconds <= sessionUpperBound { return .session }
        if seconds <= weeklyUpperBound { return .weekly }
        return .other(seconds)
    }

    /// Capacity left in this window, 0–100.
    var remainingPercent: Double { max(0, 100 - usedPercent) }

    /// Whether this window is spent — either the provider says so outright or
    /// the usage figure is at the cap.
    var isExhausted: Bool { status == "rejected" || usedPercent >= 100 }

    /// Reset instant as an ISO 8601 string, for DB storage.
    var resetAtISO: String? {
        resetAt.map { ISO8601DateFormatter().string(from: $0) }
    }
}

// MARK: - Snapshot

/// A provider's complete rate-limit picture for one account at one instant.
///
/// **Every window is optional.** A missing session window is a first-class,
/// supported state: the live-verified Codex probe returned no session window at
/// all. Consumers must render it as "unknown", never as 0% used.
struct RateLimitSnapshot {
    /// The short rolling window, or nil when the provider reports none.
    var session: RateLimitWindow?
    /// The long rolling window, or nil when the provider reports none.
    var weekly: RateLimitWindow?
    /// Named per-model / per-feature sub-limits: OpenAI's
    /// `additional_rate_limits[]` entries, Anthropic's Fable `7d_oi` bucket.
    var named: [String: RateLimitWindow]
    /// Account-wide status string, when the provider gives one.
    var overallStatus: String?

    init(
        session: RateLimitWindow? = nil,
        weekly: RateLimitWindow? = nil,
        named: [String: RateLimitWindow] = [:],
        overallStatus: String? = nil
    ) {
        self.session = session
        self.weekly = weekly
        self.named = named
        self.overallStatus = overallStatus
    }

    /// Build from an unordered list of windows, filing each into the bucket its
    /// **duration** implies. This is the entry point for providers that return
    /// positional windows (OpenAI): pass
    /// `[primary_window, secondary_window].compactMap { $0 }` and the weekly
    /// window lands in `weekly` regardless of which slot carried it.
    /// When two windows classify the same way the more-used one wins, so a
    /// duplicate can never understate consumption.
    init(
        windows: [RateLimitWindow],
        named: [String: RateLimitWindow] = [:],
        overallStatus: String? = nil
    ) {
        var session: RateLimitWindow?
        var weekly: RateLimitWindow?
        var extras = named
        for window in windows {
            switch window.kind {
            case .session:
                if session == nil || window.usedPercent > session!.usedPercent { session = window }
            case .weekly:
                if weekly == nil || window.usedPercent > weekly!.usedPercent { weekly = window }
            case .other, .unknown:
                extras[window.kind.key] = window
            }
        }
        self.init(session: session, weekly: weekly, named: extras, overallStatus: overallStatus)
    }

    /// True when the provider reported no session and no weekly window — i.e.
    /// there is nothing to score or display.
    var isEmpty: Bool { session == nil && weekly == nil }

    /// "Which account should I use" score, 0–100. 100 = nothing used, 0 =
    /// capped on whichever known window is most consumed.
    ///
    /// Returns **nil** when no window is known, so callers show "—" rather than
    /// a misleading 100 (plenty of capacity) or 0 (exhausted). A snapshot with
    /// only a weekly window scores off the weekly window alone.
    var headroomScore: Double? {
        let used = [session?.usedPercent, weekly?.usedPercent].compactMap { $0 }
        guard let worst = used.max() else { return nil }
        return max(0, min(100, 100 - worst))
    }

    /// The window whose reset actually gates this account's next usable moment.
    ///
    /// An exhausted weekly window is the gate: the session limit rolling over in
    /// twenty minutes buys nothing while the week is spent. Otherwise the
    /// session window is what frees up first, and an account with no session
    /// window (an OpenAI reading may have none) falls back to its weekly one.
    var gatingWindow: RateLimitWindow? {
        if let weekly = weekly, weekly.isExhausted { return weekly }
        return session ?? weekly
    }

    /// Seconds until this account is expected to have capacity again, measured
    /// against `gatingWindow`. Nil when no relevant reset time is known — so
    /// callers rank it as *unknown* rather than *imminent*.
    var secondsUntilRecovery: TimeInterval? {
        gatingWindow?.resetAt?.timeIntervalSinceNow
    }
}
