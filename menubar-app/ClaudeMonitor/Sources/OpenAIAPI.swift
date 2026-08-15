import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// OpenAI / ChatGPT-subscription (Codex) provider client.
///
/// Implements the contract live-verified in
/// `docs/spikes/2026-07-30-codex-usage-probe.md` § "Live verification
/// (AUTHORITATIVE)":
///
/// ```
/// GET https://chatgpt.com/backend-api/wham/usage
/// Authorization: Bearer <access_token>
/// ```
///
/// Structural differences from the Anthropic client this file deliberately
/// preserves:
///
/// - **Usage is a dedicated GET, not a piggybacked completion.** No inference
///   request is burned; the same endpoint Codex CLI's own `/usage` command hits.
/// - **Windows are named fields, not an array.** `rate_limit.primary_window` /
///   `.secondary_window`, each with `limit_window_seconds`. The window's *kind*
///   is derived from that duration — never from which slot it arrived in. The
///   probe returned a **weekly** `primary_window` with a **null**
///   `secondary_window`, so "primary = session" is provably wrong.
/// - **Identity rides along.** `email` / `plan_type` / `account_id` come back in
///   the same response; there is no separate profile call.
/// - **Access tokens expire (~10 days).** `refresh(_:)` renews one via
///   `POST https://auth.openai.com/oauth/token`. This app no longer stores an
///   OpenAI credential to poll with (#104), so nothing calls this proactively
///   any more — `addOpenAIAccount` is the one remaining caller, renewing an
///   already-stale credential once, up front, at import time.
///
/// The `/backend-api/codex/usage` route is **not** used: it is Cloudflare
/// bot-challenged and answers 403 with an HTML interstitial.
///
/// Portable core: no AppKit / SwiftUI / Combine / os.Logger — builds on Linux.
///
/// ## Security
///
/// The response body carries PII (`email`, `account_id`, `user_id`) and the
/// request carries a live bearer token. Nothing in this file ever logs a token
/// or a raw response body; `OpenAIUsageResponse.flatten` redacts credential and
/// PII keys **at every level of the JSON tree**, not just the top one (the
/// exact miss called out in spike #26's process note).

private let flog = FileLogger.shared
private let fcat = "OpenAI"

// MARK: - Wire model

/// Decoded `GET /backend-api/wham/usage` body. Every field is optional: this is
/// an undocumented endpoint and a missing key must degrade, never crash.
struct OpenAIUsageResponse: Decodable {
    /// One rate-limit window as OpenAI reports it.
    struct Window: Decodable {
        let usedPercent: Double?
        let limitWindowSeconds: Double?
        let resetAfterSeconds: Double?
        /// Unix epoch seconds.
        let resetAt: Double?

        /// When this window rolls over. Prefers the absolute `reset_at`; falls
        /// back to `now + reset_after_seconds` when only the relative form came
        /// back.
        var resolvedResetAt: Date? {
            if let resetAt = resetAt, resetAt > 0 { return Date(timeIntervalSince1970: resetAt) }
            if let after = resetAfterSeconds, after > 0 { return Date().addingTimeInterval(after) }
            return nil
        }

        /// This window in the shared model, or nil when the provider gave no
        /// usage figure (a window we know nothing about must not read as 0%).
        func asRateLimitWindow(status: String?) -> RateLimitWindow? {
            guard let usedPercent = usedPercent else { return nil }
            return RateLimitWindow(
                usedPercent: usedPercent,
                durationSeconds: limitWindowSeconds,
                resetAt: resolvedResetAt,
                status: status
            )
        }
    }

    struct RateLimit: Decodable {
        let allowed: Bool?
        let limitReached: Bool?
        let primaryWindow: Window?
        let secondaryWindow: Window?

        /// `allowed` / `limit_reached` expressed in the same vocabulary
        /// Anthropic's `-status` headers use, so downstream status mapping
        /// (`RankingExporter.mapStatus`) is provider-agnostic.
        var statusString: String {
            if limitReached == true || allowed == false { return "rejected" }
            return "allowed"
        }

        /// Both windows, unordered. Callers file them by duration.
        var windows: [RateLimitWindow] {
            let status = statusString
            return [primaryWindow, secondaryWindow]
                .compactMap { $0 }
                .compactMap { $0.asRateLimitWindow(status: status) }
        }
    }

    /// A named per-model / per-feature sub-limit, e.g.
    /// `{"limit_name": "GPT-5.3-Codex-Spark", "metered_feature": "codex_bengalfox"}`.
    struct AdditionalRateLimit: Decodable {
        let limitName: String?
        let meteredFeature: String?
        let rateLimit: RateLimit?

        /// Stable key for the `named` sub-limit map.
        var key: String? {
            for candidate in [limitName, meteredFeature] {
                if let candidate = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !candidate.isEmpty {
                    return candidate
                }
            }
            return nil
        }
    }

    let accountId: String?
    let email: String?
    let planType: String?
    let rateLimit: RateLimit?
    let additionalRateLimits: [AdditionalRateLimit]?

    // MARK: Mapping to the shared model

    /// This response in the provider-agnostic window model.
    ///
    /// Windows are filed by **duration**, so a weekly `primary_window` lands in
    /// `weekly` and a null `secondary_window` simply leaves `session` nil —
    /// never a fabricated 0% session figure.
    var rateLimitSnapshot: RateLimitSnapshot {
        var named: [String: RateLimitWindow] = [:]
        for entry in additionalRateLimits ?? [] {
            guard let key = entry.key,
                  let limit = entry.rateLimit,
                  let window = limit.windows.max(by: { $0.usedPercent < $1.usedPercent })
            else { continue }
            named[key] = window
        }
        return RateLimitSnapshot(
            windows: rateLimit?.windows ?? [],
            named: named,
            overallStatus: rateLimit?.statusString
        )
    }

    /// Decode a `/wham/usage` body. Snake-case keys map onto the camelCase
    /// properties above (`limit_window_seconds` → `limitWindowSeconds`).
    static func decode(_ data: Data) throws -> OpenAIUsageResponse {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(OpenAIUsageResponse.self, from: data)
    }

    // MARK: Raw-field capture (moving-target archive, PII-redacted)

    /// Keys whose **values** are never stored or logged, matched at every depth
    /// of the JSON tree. Credentials plus the PII the endpoint volunteers.
    ///
    /// The account's email *is* persisted — to `accounts.email`, the documented
    /// join key — but it is deliberately kept out of this verbatim archive,
    /// which is dumped into logs and `probe_snapshots` far more freely.
    static let redactedKeys: Set<String> = [
        "access_token", "refresh_token", "id_token", "token", "api_key",
        "email", "account_id", "user_id", "id", "name", "given_name",
        "family_name", "picture", "phone_number", "sub",
    ]

    /// Upper bound on archived entries, so a response that grows an enormous
    /// array can't bloat every `usage_history` row.
    static let maxFlattenedFields = 200

    /// Flatten the raw JSON body into the `[String: String]` archive shape the
    /// rest of the app stores (mirroring Anthropic's header map), redacting
    /// every key in `redactedKeys` at any nesting depth.
    ///
    /// "Capture wide, interpret narrow": fields OpenAI adds later are archived
    /// even before this app understands them.
    static func flatten(_ data: Data) -> [String: String] {
        flatten(data, prefix: "")
    }

    /// Same redacting flatten, with every key prefixed — so a second transport
    /// can archive more than one payload into a single `raw_data` map without
    /// collisions (`codex app-server` archives both `account/read` and
    /// `account/rateLimits/read`). Shared rather than reimplemented so there is
    /// exactly one redaction rule set to keep correct.
    static func flatten(_ data: Data, prefix: String) -> [String: String] {
        // Decoded through `JSONValue` rather than `JSONSerialization` so booleans
        // stay distinguishable from 0/1 without CoreFoundation type checks,
        // which don't exist on Linux.
        guard let root = try? JSONDecoder().decode(JSONValue.self, from: data) else { return [:] }
        var out: [String: String] = [:]
        flattenValue(root, prefix: prefix, into: &out)
        return out
    }

    private static func flattenValue(_ value: JSONValue, prefix: String, into out: inout [String: String]) {
        guard out.count < maxFlattenedFields else { return }
        switch value {
        case .object(let dict):
            for (key, child) in dict {
                let path = prefix.isEmpty ? key : "\(prefix).\(key)"
                if redactedKeys.contains(key.lowercased()) {
                    out[path] = "[redacted]"
                } else {
                    flattenValue(child, prefix: path, into: &out)
                }
                if out.count >= maxFlattenedFields { return }
            }
        case .array(let items):
            for (index, child) in items.enumerated() {
                flattenValue(child, prefix: "\(prefix).\(index)", into: &out)
                if out.count >= maxFlattenedFields { return }
            }
        case .null:
            out[prefix] = "null"
        case .bool(let flag):
            out[prefix] = flag ? "true" : "false"
        case .number(let number):
            // Render whole numbers without a decimal tail, so
            // `limit_window_seconds` archives as "604800", not "604800.0".
            out[prefix] = (number == number.rounded() && abs(number) < 1e15)
                ? "\(Int64(number))"
                : "\(number)"
        case .string(let string):
            out[prefix] = string
        }
    }
}

/// A fully-general JSON value, used only to walk an arbitrary response body for
/// archiving. `JSONDecoder` keeps booleans and numbers distinct here, which
/// `JSONSerialization` does not do portably (on Darwin both arrive as
/// `NSNumber` and telling them apart needs CoreFoundation, which Linux lacks).
///
/// `Encodable` too, so a decoded subtree can be handed back out as standalone
/// JSON — how `CodexAppServerClient` lifts a JSON-RPC reply's `result` member
/// out of its envelope for the typed decoders and this flattener.
indirect enum JSONValue: Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value):
            // Round-trip whole numbers as integers so a re-encoded epoch stays
            // `1785967226`, not `1785967226.0` (which a strict consumer of the
            // re-encoded payload could read differently).
            if value == value.rounded(), abs(value) < 1e15 {
                try container.encode(Int64(value))
            } else {
                try container.encode(value)
            }
        case .string(let value): try container.encode(value)
        case .array(let values): try container.encode(values)
        case .object(let values): try container.encode(values)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Unsupported JSON value"
            )
        }
    }
}

// MARK: - Refresh-token response

/// `POST https://auth.openai.com/oauth/token` reply.
struct OpenAITokenRefreshResponse: Decodable {
    let accessToken: String?
    let refreshToken: String?
    /// Lifetime of the new access token in seconds, when stated.
    let expiresIn: Double?

    static func decode(_ data: Data) throws -> OpenAITokenRefreshResponse {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(OpenAITokenRefreshResponse.self, from: data)
    }
}

// MARK: - API client

// Genuinely Sendable: the only stored property is `URLSession` (itself
// Sendable), every method is a pure function of its arguments plus that
// session, and there is no other instance-level mutable state.
final class OpenAIAPIClient: Sendable {
    /// The live-verified usage endpoint. The `/backend-api/codex/usage` variant
    /// is Cloudflare-challenged (403) and must not be used.
    static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    /// Refresh endpoint, confirmed from Codex CLI's own login log.
    static let tokenURL = URL(string: "https://auth.openai.com/oauth/token")!
    /// Codex CLI's public OAuth client id — a public identifier, not a secret.
    static let oauthClientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    static let oauthScope = "openid profile email"

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: Usage

    /// `GET /backend-api/wham/usage`. Read-only; no completion quota is spent.
    func fetchUsage(accessToken: String) async throws -> ProviderUsageSnapshot {
        var request = URLRequest(url: Self.usageURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // No `chatgpt-account-id` header: the bearer token carries identity
        // (verified — the probe succeeded without it).

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            flog.error("Network error fetching OpenAI usage: \(error.localizedDescription)", category: fcat)
            throw ProviderAPIError.networkError(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw ProviderAPIError.invalidResponse
        }

        if http.statusCode == 401 || http.statusCode == 403 {
            // 403 here is either a revoked token or the Cloudflare interstitial
            // the `/codex/` route returns; both mean "this credential can't read
            // usage right now", which is the unauthorized path.
            flog.warning("OpenAI usage returned \(http.statusCode) — token expired, revoked, or challenged", category: fcat)
            throw ProviderAPIError.unauthorized
        }
        guard (200..<300).contains(http.statusCode) else {
            flog.warning("Unexpected HTTP \(http.statusCode) from OpenAI usage", category: fcat)
            throw ProviderAPIError.httpError(http.statusCode)
        }

        return try Self.snapshot(from: data, httpStatus: http.statusCode)
    }

    /// Map a raw `/wham/usage` body onto the shared snapshot type. Split out
    /// from the network call so the self-test can exercise it against a
    /// recorded fixture with no network and no credentials.
    static func snapshot(from data: Data, httpStatus: Int) throws -> ProviderUsageSnapshot {
        let decoded: OpenAIUsageResponse
        do {
            decoded = try OpenAIUsageResponse.decode(data)
        } catch {
            // Never log the body — it carries PII.
            flog.error("Could not decode OpenAI usage response (\(data.count) bytes)", category: fcat)
            throw ProviderAPIError.invalidResponse
        }

        guard let accountKey = decoded.accountId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !accountKey.isEmpty else {
            flog.error("OpenAI usage response carried no account_id", category: fcat)
            throw ProviderAPIError.invalidResponse
        }

        let snapshot = decoded.rateLimitSnapshot
        var rawFields = OpenAIUsageResponse.flatten(data)
        // Normalized status keys, in the compact form `RankingExporter`
        // already parses out of `usage_history.raw_data`. Additive: the
        // verbatim `rate_limit.*` paths are archived alongside them. Assigning
        // nil simply omits the key — an absent window contributes no status.
        rawFields["overall_status"] = snapshot.overallStatus
        rawFields["session_status"] = snapshot.session?.status
        rawFields["weekly_status"] = snapshot.weekly?.status

        let session = snapshot.session.map { String(format: "%.0f%%", $0.usedPercent) } ?? "—"
        let weekly = snapshot.weekly.map { String(format: "%.0f%%", $0.usedPercent) } ?? "—"
        flog.info(
            "OpenAI usage \(httpStatus) — account: \(accountKey.prefix(8))... session: \(session), weekly: \(weekly) (\(snapshot.overallStatus ?? "?"))",
            category: fcat
        )

        return ProviderUsageSnapshot(
            provider: .openai,
            accountKey: accountKey,
            httpStatus: httpStatus,
            rateLimit: snapshot,
            email: decoded.email,
            plan: decoded.planType,
            rawFields: rawFields
        )
    }

    // MARK: Token refresh

    /// Renew an access token with the stored refresh token.
    ///
    /// Returns nil when there is nothing to refresh (no refresh token stored) so
    /// callers keep using the current credential; throws when the endpoint
    /// rejects the exchange, which is the loud-failure path the poller turns
    /// into a visible token-health state.
    ///
    /// OpenAI rotates refresh tokens: the reply may carry a *new* `refresh_token`
    /// that must replace the stored one, so the result is always persisted whole
    /// rather than merged field-by-field.
    func refresh(_ credentials: ProviderCredentials) async throws -> ProviderCredentials? {
        guard let refreshToken = credentials.refreshToken, !refreshToken.isEmpty else {
            return nil
        }

        var request = URLRequest(url: Self.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let body: [String: String] = [
            "client_id": Self.oauthClientID,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "scope": Self.oauthScope,
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            flog.error("Network error refreshing OpenAI token: \(error.localizedDescription)", category: fcat)
            throw ProviderAPIError.networkError(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw ProviderAPIError.invalidResponse
        }

        guard (200..<300).contains(http.statusCode) else {
            // Log only the OAuth error *code*, never the body (it echoes the
            // request, refresh token included).
            let code = Self.oauthErrorCode(data) ?? "http_\(http.statusCode)"
            flog.error("OpenAI token refresh rejected (\(http.statusCode)/\(code))", category: fcat)
            throw http.statusCode == 400 || http.statusCode == 401
                ? ProviderAPIError.unauthorized
                : ProviderAPIError.httpError(http.statusCode)
        }

        let decoded: OpenAITokenRefreshResponse
        do {
            decoded = try OpenAITokenRefreshResponse.decode(data)
        } catch {
            flog.error("Could not decode OpenAI token refresh response", category: fcat)
            throw ProviderAPIError.invalidResponse
        }

        guard let accessToken = decoded.accessToken, !accessToken.isEmpty else {
            flog.error("OpenAI token refresh returned no access_token", category: fcat)
            throw ProviderAPIError.invalidResponse
        }

        // Prefer the stated lifetime; fall back to the token's own `exp` claim,
        // which is what `~/.codex/auth.json` gives us on import.
        let expiresAt = decoded.expiresIn.map { Date().addingTimeInterval($0) }
            ?? Self.accessTokenExpiry(accessToken)

        flog.info(
            "Refreshed OpenAI access token (expires \(expiresAt.map { ISO8601DateFormatter().string(from: $0) } ?? "unknown"))",
            category: fcat
        )

        return ProviderCredentials(
            accessToken: accessToken,
            // Rotation: keep the new refresh token when one came back.
            refreshToken: decoded.refreshToken?.isEmpty == false ? decoded.refreshToken : refreshToken,
            expiresAt: expiresAt
        )
    }

    /// The `error` field of an OAuth error body (e.g. `invalid_grant`), or nil.
    /// Only this short machine-readable code is ever surfaced.
    static func oauthErrorCode(_ data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let error = obj["error"] as? String, !error.isEmpty { return error }
        if let error = obj["error"] as? [String: Any], let code = error["code"] as? String { return code }
        return nil
    }

    // MARK: JWT expiry

    /// Read the `exp` claim out of a JWT access token **without verifying it** —
    /// we are reading an already-issued token's stated lifetime, not trusting
    /// it for authorization.
    ///
    /// `~/.codex/auth.json` stores no expiry of its own, so this is how an
    /// imported credential gets a `token_expires_at`. Only the numeric `exp`
    /// claim is read; no other claim (all of which are PII) is decoded, logged,
    /// or returned.
    static func accessTokenExpiry(_ token: String) -> Date? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2, let payload = base64URLDecode(String(parts[1])) else { return nil }
        guard let claims = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { return nil }
        guard let exp = claims["exp"] as? Double ?? (claims["exp"] as? NSNumber)?.doubleValue, exp > 0 else {
            return nil
        }
        return Date(timeIntervalSince1970: exp)
    }

    static func base64URLDecode(_ string: String) -> Data? {
        var s = string.replacingOccurrences(of: "-", with: "+")
                      .replacingOccurrences(of: "_", with: "/")
        let remainder = s.count % 4
        if remainder > 0 { s += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: s)
    }
}

// MARK: - UsageProviderClient conformance

extension OpenAIAPIClient: UsageProviderClient {
    var provider: AccountProvider { .openai }

    func fetchUsage(_ credentials: ProviderCredentials) async throws -> ProviderUsageSnapshot {
        try await fetchUsage(accessToken: credentials.accessToken)
    }

    /// Identity comes back with usage, so identification is the same (free,
    /// read-only) call rather than a separate profile fetch.
    func identifyAccount(_ credentials: ProviderCredentials) async throws -> String {
        try await fetchUsage(credentials).accountKey
    }

    func refreshCredentials(_ credentials: ProviderCredentials) async throws -> ProviderCredentials? {
        try await refresh(credentials)
    }
}

// MARK: - Codex credential import

/// Reads Codex CLI's ChatGPT-OAuth credential store, `~/.codex/auth.json`
/// (or `$CODEX_HOME/auth.json`) — the practical way to get an OpenAI
/// credential into this app, mirroring how bulk import reads `accounts.env`.
///
/// Nothing here logs or returns a token value beyond the caller that stores it.
enum CodexAuth {
    /// Codex CLI's credential path, honoring `$CODEX_HOME`.
    ///
    /// Note `FileManager.homeDirectoryForCurrentUser` ignores a `HOME`
    /// override on macOS, so tests must pass an explicit scratch path rather
    /// than relying on an environment override (issue #16).
    static var defaultAuthPath: String {
        let env = ProcessInfo.processInfo.environment["CODEX_HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let env = env, !env.isEmpty {
            return (env as NSString).appendingPathComponent("auth.json")
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/auth.json").path
    }

    struct Credential {
        let accessToken: String
        let refreshToken: String?
        let accountId: String?
        let expiresAt: Date?
    }

    enum ImportError: Error, LocalizedError {
        case notFound(String)
        case unreadable(String)
        case malformed
        case noAccessToken

        var errorDescription: String? {
            switch self {
            case .notFound(let path):
                return "No Codex credential at \(path) — run `codex login` first, or pass --auth <path>"
            case .unreadable(let path):
                return "Could not read \(path)"
            case .malformed:
                return "Not a Codex auth.json (expected a `tokens` object)"
            case .noAccessToken:
                return "Codex auth.json has no access_token"
            }
        }
    }

    /// Parse an `auth.json` body. Shape (values elided):
    /// `{"OPENAI_API_KEY": null, "tokens": {"id_token": …, "access_token": …,
    ///   "refresh_token": …, "account_id": …}, "last_refresh": …}`
    static func parse(_ data: Data) throws -> Credential {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ImportError.malformed
        }
        guard let tokens = root["tokens"] as? [String: Any] else {
            throw ImportError.malformed
        }
        guard let accessToken = (tokens["access_token"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !accessToken.isEmpty else {
            throw ImportError.noAccessToken
        }
        let refreshToken = (tokens["refresh_token"] as? String)
            .flatMap { $0.isEmpty ? nil : $0 }
        let accountId = (tokens["account_id"] as? String)
            .flatMap { $0.isEmpty ? nil : $0 }
        return Credential(
            accessToken: accessToken,
            refreshToken: refreshToken,
            accountId: accountId,
            // auth.json states no expiry; the access token's own `exp` claim does.
            expiresAt: OpenAIAPIClient.accessTokenExpiry(accessToken)
        )
    }

    /// The `auth.json` inside a specific `CODEX_HOME`, or `defaultAuthPath`
    /// when no home is registered for the account (#103).
    static func authPath(inHome home: String?) -> String {
        guard let home = home?.trimmingCharacters(in: .whitespacesAndNewlines),
              !home.isEmpty else { return defaultAuthPath }
        return (home as NSString).appendingPathComponent("auth.json")
    }

    /// **Only** `tokens.account_id` out of a home's `auth.json` — never a token.
    ///
    /// `codex add --home` needs a stable key for the account row, and
    /// `account/read` carries no account id on any verified `app-server`
    /// version (spike §4 item 7), so this one opaque identifier is the only
    /// thing that can supply it. An opaque account id is not a credential: it
    /// authenticates nothing, it is already what every existing OpenAI row is
    /// keyed on, and it is what `ranking.json` publishes today.
    ///
    /// Deliberately **not** `load(path:)`: that returns the whole `Credential`
    /// (tokens included) and throws `.noAccessToken` on a home that has been
    /// created but not logged into. This returns nil for every "can't tell"
    /// case instead, so registration can fall back to matching on email.
    static func accountId(inHome home: String?) -> String? {
        let path = authPath(inHome: home)
        guard let data = FileManager.default.contents(atPath: path),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = root["tokens"] as? [String: Any],
              let id = (tokens["account_id"] as? String)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !id.isEmpty else { return nil }
        return id
    }

    /// Load and parse a credential file. `path` defaults to `defaultAuthPath`.
    static func load(path: String? = nil) throws -> Credential {
        let path = path ?? defaultAuthPath
        guard FileManager.default.fileExists(atPath: path) else {
            throw ImportError.notFound(path)
        }
        guard let data = FileManager.default.contents(atPath: path) else {
            throw ImportError.unreadable(path)
        }
        return try parse(data)
    }
}
