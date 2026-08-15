import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private let flog = FileLogger.shared
private let fcat = "API"

// Auto-updated by build script from installed claude-code version
private let claudeCodeUserAgent = "claude-code/2.1.212"

// MARK: - Ping Response (parsed from rate-limit headers)

struct PingResponse {
    let organizationId: String
    let httpStatus: Int

    let sessionUtilization: Double?   // 0.0–1.0
    let sessionReset: Date?
    let sessionStatus: String?        // "allowed", "rejected"

    let weeklyUtilization: Double?    // 0.0–1.0
    let weeklyReset: Date?
    let weeklyStatus: String?         // "allowed", "allowed_warning", "rejected"

    let overallStatus: String?        // "allowed", "allowed_warning", "rejected"

    /// Every `anthropic-*` response header, verbatim. Archived per poll so new
    /// fields the API introduces are captured even before we interpret them.
    let rawHeaders: [String: String]

    /// Session utilization as percentage (0–100)
    var sessionPercent: Double { (sessionUtilization ?? 0) * 100 }

    /// Weekly utilization as percentage (0–100)
    var weeklyPercent: Double { (weeklyUtilization ?? 0) * 100 }

    /// This ping expressed in the shared, provider-agnostic window model.
    ///
    /// A window is present only when the corresponding header family actually
    /// came back — an absent `-5h-utilization` header yields `session == nil`
    /// rather than a fabricated 0%, which is the same "no session window"
    /// state OpenAI accounts can legitimately be in.
    var rateLimit: RateLimitSnapshot {
        RateLimitSnapshot(
            session: sessionUtilization.map {
                RateLimitWindow(
                    kind: .session,
                    usedPercent: $0 * 100,
                    resetAt: sessionReset,
                    status: sessionStatus
                )
            },
            weekly: weeklyUtilization.map {
                RateLimitWindow(
                    kind: .weekly,
                    usedPercent: $0 * 100,
                    resetAt: weeklyReset,
                    status: weeklyStatus
                )
            },
            overallStatus: overallStatus
        )
    }
}

// MARK: - API Errors

/// Historical name for the shared provider error type. Kept so the many
/// existing `catch AnthropicAPIError.unauthorized` / `if case
/// AnthropicAPIError.unauthorized = error` sites keep compiling unchanged.
typealias AnthropicAPIError = ProviderAPIError

// MARK: - API Client

// Genuinely Sendable: the only stored property is `URLSession` (itself
// Sendable), every method is a pure function of its arguments plus that
// session, and there is no other instance-level mutable state.
final class AnthropicAPIClient: Sendable {
    private let session = URLSession.shared

    /// Ping a token with a minimal Haiku inference call.
    /// Both 200 and 429 responses include rate-limit headers with exact utilization data.
    /// Cost: ~1 Haiku output token per call (essentially free).
    func pingToken(accessToken: String) async throws -> PingResponse {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue(claudeCodeUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = """
        {"model":"claude-haiku-4-5-20251001","max_tokens":1,"messages":[{"role":"user","content":"x"}]}
        """
        request.httpBody = body.data(using: .utf8)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            flog.error("Network error pinging token: \(error.localizedDescription)", category: fcat)
            throw AnthropicAPIError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AnthropicAPIError.invalidResponse
        }

        let status = httpResponse.statusCode

        // 401 = invalid/expired token
        if status == 401 {
            flog.warning("Unauthorized (401) from ping", category: fcat)
            throw AnthropicAPIError.unauthorized
        }

        // 200 and 429 both include rate-limit headers — parse them
        guard status == 200 || status == 429 else {
            flog.warning("Unexpected HTTP \(status) from ping", category: fcat)
            throw AnthropicAPIError.httpError(status)
        }

        // Parse from the lowercased captured map, not allHeaderFields directly:
        // on Linux allHeaderFields lookups are case-sensitive, so header-name
        // casing from the server would otherwise change behavior per platform.
        let rawHeaders = Self.extractAnthropicHeaders(httpResponse.allHeaderFields)
        Self.logUnknownHeaderKeys(rawHeaders.keys)

        let orgId = rawHeaders["anthropic-organization-id"] ?? ""

        let pingResponse = PingResponse(
            organizationId: orgId,
            httpStatus: status,
            sessionUtilization: parseDouble(rawHeaders["anthropic-ratelimit-unified-5h-utilization"]),
            sessionReset: parseEpoch(rawHeaders["anthropic-ratelimit-unified-5h-reset"]),
            sessionStatus: rawHeaders["anthropic-ratelimit-unified-5h-status"],
            weeklyUtilization: parseDouble(rawHeaders["anthropic-ratelimit-unified-7d-utilization"]),
            weeklyReset: parseEpoch(rawHeaders["anthropic-ratelimit-unified-7d-reset"]),
            weeklyStatus: rawHeaders["anthropic-ratelimit-unified-7d-status"],
            overallStatus: rawHeaders["anthropic-ratelimit-unified-status"],
            rawHeaders: rawHeaders
        )

        let pct5h = String(format: "%.0f%%", pingResponse.sessionPercent)
        let pct7d = String(format: "%.0f%%", pingResponse.weeklyPercent)
        flog.info("Ping \(status) — org: \(orgId.prefix(8))... session: \(pct5h) (\(pingResponse.sessionStatus ?? "?")), weekly: \(pct7d) (\(pingResponse.weeklyStatus ?? "?"))", category: fcat)

        return pingResponse

    }

    // MARK: - Raw Header Capture (moving-target archive)

    /// Pull every `anthropic-*` response header into a plain [String:String],
    /// lowercasing keys. This is the "capture wide" half — we store all of it and
    /// interpret only the fields we understand.
    static func extractAnthropicHeaders(_ headers: [AnyHashable: Any]) -> [String: String] {
        var out: [String: String] = [:]
        for (k, v) in headers {
            guard let key = (k as? String)?.lowercased(), key.hasPrefix("anthropic-") else { continue }
            out[key] = "\(v)"
        }
        return out
    }

    /// Header suffixes we already understand. Anything outside this set is logged
    /// once per process so an API change surfaces instead of passing silently.
    private static let knownHeaderKeys: Set<String> = [
        "anthropic-organization-id",
        "anthropic-ratelimit-unified-status",
        "anthropic-ratelimit-unified-reset",
        "anthropic-ratelimit-unified-5h-status",
        "anthropic-ratelimit-unified-5h-reset",
        "anthropic-ratelimit-unified-5h-utilization",
        "anthropic-ratelimit-unified-7d-status",
        "anthropic-ratelimit-unified-7d-reset",
        "anthropic-ratelimit-unified-7d-utilization",
        "anthropic-ratelimit-unified-7d-surpassed-threshold",
        // Premium/Opus-Fable weekly allocation — only present on premium-model probes
        "anthropic-ratelimit-unified-7d_oi-status",
        "anthropic-ratelimit-unified-7d_oi-reset",
        "anthropic-ratelimit-unified-7d_oi-utilization",
        "anthropic-ratelimit-unified-7d_oi-surpassed-threshold",
        "anthropic-ratelimit-unified-representative-claim",
        "anthropic-ratelimit-unified-fallback-percentage",
        "anthropic-ratelimit-unified-overage-status",
        "anthropic-ratelimit-unified-overage-utilization",
        "anthropic-ratelimit-unified-overage-reset",
        "anthropic-ratelimit-unified-overage-disabled-reason",
        "anthropic-ratelimit-unified-overage-in-use",
        "anthropic-ratelimit-unified-upgrade-paths",
    ]
    // Log-dedup only (never read for correctness); OAuthPoller processes
    // credentials sequentially in an `await`-ed for loop, never concurrently,
    // so this is genuinely single-threaded in practice.
    private nonisolated(unsafe) static var loggedUnknownKeys: Set<String> = []

    private static func logUnknownHeaderKeys<S: Sequence>(_ keys: S) where S.Element == String {
        for key in keys where !knownHeaderKeys.contains(key) && !loggedUnknownKeys.contains(key) {
            loggedUnknownKeys.insert(key)
            flog.warning("New rate-limit header seen from API: \(key) — archived but not yet interpreted", category: fcat)
        }
    }

    /// Fire a minimal request at an arbitrary model and return its status + all
    /// `anthropic-*` headers, never throwing. Used for the Fable probe: we want to
    /// record whatever the API says (including rejections) rather than fail.
    func rawProbe(accessToken: String, model: String) async -> (httpStatus: Int, headers: [String: String]) {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue(claudeCodeUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Premium models (Opus/Fable) reject subscription-OAuth requests that lack
        // the Claude Code identity system prompt — they return a masked 429
        // rate_limit_error. With it, they return 200 and expose the premium-tier
        // "7d_oi" weekly allocation headers (invisible on the cheap Haiku ping).
        request.httpBody = """
        {"model":"\(model)","max_tokens":1,"system":"You are Claude Code, Anthropic's official CLI for Claude.","messages":[{"role":"user","content":"x"}]}
        """.data(using: .utf8)

        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return (0, [:])
            }
            let raw = Self.extractAnthropicHeaders(http.allHeaderFields)
            Self.logUnknownHeaderKeys(raw.keys)
            return (http.statusCode, raw)
        } catch {
            flog.error("rawProbe(\(model)) network error: \(error.localizedDescription)", category: fcat)
            return (0, [:])
        }
    }

    /// Identify which org a token belongs to via the count_tokens endpoint (no quota cost).
    func identifyToken(accessToken: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages/count_tokens")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("oauth-2025-04-20,token-counting-2024-11-01", forHTTPHeaderField: "anthropic-beta")
        request.setValue(claudeCodeUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = """
        {"model":"claude-sonnet-4-20250514","messages":[{"role":"user","content":"x"}]}
        """
        request.httpBody = body.data(using: .utf8)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw AnthropicAPIError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AnthropicAPIError.invalidResponse
        }

        if httpResponse.statusCode == 401 {
            throw AnthropicAPIError.unauthorized
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw AnthropicAPIError.httpError(httpResponse.statusCode)
        }

        let idHeaders = Self.extractAnthropicHeaders(httpResponse.allHeaderFields)
        guard let orgId = idHeaders["anthropic-organization-id"], !orgId.isEmpty else {
            throw AnthropicAPIError.invalidResponse
        }

        flog.info("Token identified — org: \(orgId)", category: fcat)
        return orgId
    }

    // MARK: - Helpers

    private func parseDouble(_ value: String?) -> Double? {
        value.flatMap { Double($0) }
    }

    private func parseEpoch(_ value: String?) -> Date? {
        guard let epoch = value.flatMap({ TimeInterval($0) }) else { return nil }
        return Date(timeIntervalSince1970: epoch)
    }
}

// MARK: - UsageProviderClient conformance

/// Anthropic as one provider among several. This is a pure adaptation layer —
/// `fetchUsage` is `pingToken` and `identifyAccount` is `identifyToken`, both
/// re-expressed in the shared types. Behavior for Anthropic accounts is
/// unchanged; the poll loop still calls `pingToken` directly today.
extension AnthropicAPIClient: UsageProviderClient {
    var provider: AccountProvider { .anthropic }

    func fetchUsage(_ credentials: ProviderCredentials) async throws -> ProviderUsageSnapshot {
        let ping = try await pingToken(accessToken: credentials.accessToken)
        return ProviderUsageSnapshot(
            provider: .anthropic,
            accountKey: ping.organizationId,
            httpStatus: ping.httpStatus,
            rateLimit: ping.rateLimit,
            // Anthropic's rate-limit headers carry no identity beyond the org
            // id; email/plan come from elsewhere (the account list files).
            email: nil,
            plan: nil,
            rawFields: ping.rawHeaders
        )
    }

    func identifyAccount(_ credentials: ProviderCredentials) async throws -> String {
        try await identifyToken(accessToken: credentials.accessToken)
    }

    // refreshCredentials: the protocol's default (nil) is correct here —
    // Anthropic subscription OAuth tokens are long-lived (~1yr) and this app
    // never refreshes them; a dead token is rolled by the user instead.
}
