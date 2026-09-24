import Foundation

/// The provider-agnostic usage-fetch surface. `AnthropicAPIClient` is the first
/// conformer; the OpenAI/Codex client (`GET /backend-api/wham/usage`) lands in
/// epic phase 3 as a second one.
///
/// Portable core: no AppKit / SwiftUI / Combine / os.Logger — builds on Linux.

// MARK: - Credentials

/// The credential material one account needs to talk to its provider.
///
/// `refreshToken` / `expiresAt` are mandatory infrastructure rather than a
/// nicety: OpenAI access tokens live ~10 days (verified in spike #26), so a
/// poller that assumes an indefinitely-valid bearer silently starts failing.
/// Anthropic's `sk-ant-oat01` tokens carry no expiry, so both stay nil there.
struct ProviderCredentials {
    let accessToken: String
    let refreshToken: String?
    /// When `accessToken` stops working. nil = unknown, or does not expire.
    let expiresAt: Date?

    init(accessToken: String, refreshToken: String? = nil, expiresAt: Date? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }

    /// Whether the access token is at or near expiry and should be renewed
    /// before the next usage fetch. Credentials with no stated expiry
    /// (Anthropic) never report as expiring.
    func isExpiring(within lead: TimeInterval = 3600, now: Date = Date()) -> Bool {
        guard let expiresAt = expiresAt else { return false }
        return expiresAt.timeIntervalSince(now) <= lead
    }

    /// Whether a renewal is even possible for this credential.
    var isRefreshable: Bool {
        guard let refreshToken = refreshToken else { return false }
        return !refreshToken.isEmpty
    }
}

// MARK: - Usage snapshot

/// One provider-agnostic usage reading for one account.
struct ProviderUsageSnapshot {
    let provider: AccountProvider
    /// Stable per-provider account key — Anthropic's organization id, OpenAI's
    /// `account_id`. This is what the `accounts.id` column holds.
    let accountKey: String
    let httpStatus: Int
    let rateLimit: RateLimitSnapshot
    /// Identity the provider volunteered alongside usage. OpenAI's usage
    /// response carries `email` / `plan_type`; Anthropic's headers carry
    /// neither, so both are nil there.
    let email: String?
    let plan: String?
    /// Verbatim wire fields (Anthropic: every `anthropic-*` response header;
    /// OpenAI: the flattened JSON body). Archived per poll so fields the
    /// provider adds are captured even before we interpret them.
    let rawFields: [String: String]

    init(
        provider: AccountProvider,
        accountKey: String,
        httpStatus: Int,
        rateLimit: RateLimitSnapshot,
        email: String? = nil,
        plan: String? = nil,
        rawFields: [String: String] = [:]
    ) {
        self.provider = provider
        self.accountKey = accountKey
        self.httpStatus = httpStatus
        self.rateLimit = rateLimit
        self.email = email
        self.plan = plan
        self.rawFields = rawFields
    }
}

// MARK: - Errors

/// Errors any provider client can raise. Historically named
/// `AnthropicAPIError`; that name survives as a typealias (see
/// `AnthropicAPI.swift`) so existing `catch AnthropicAPIError.unauthorized`
/// sites keep working unchanged.
///
/// Not `Equatable` — match with `if case .unauthorized = error`.
enum ProviderAPIError: Error, LocalizedError {
    case unauthorized
    case httpError(Int)
    case invalidResponse
    case networkError(Error)

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "Unauthorized — token may be expired or revoked"
        case .httpError(let code):
            return "HTTP error \(code)"
        case .invalidResponse:
            return "Invalid response from API"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        }
    }

    var isTransient: Bool {
        switch self {
        case .httpError(let code):
            return (500...599).contains(code)
        case .networkError:
            return true
        case .unauthorized, .invalidResponse:
            return false
        }
    }
}

// MARK: - Protocol

/// A client that can read one provider's subscription usage.
/// `Sendable`: every conformer is a stateless (or immutable-state) API client
/// safe to call from any isolation domain — see `AnthropicAPIClient` /
/// `OpenAIAPIClient`.
protocol UsageProviderClient: AnyObject, Sendable {
    /// Which provider this client speaks to.
    var provider: AccountProvider { get }

    /// Fetch the current rate-limit state for a credential.
    ///
    /// A conformer whose **transport owns the credential** may ignore
    /// `credentials` entirely, and that is a supported shape rather than a bug:
    /// `CodexAppServerClient` shells out to the Codex CLI, which holds and
    /// renews the OpenAI token itself, so there is nothing for this app to pass
    /// in. Such a conformer must say so at its override, and should also expose
    /// a method with the honest signature for callers that can use it.
    func fetchUsage(_ credentials: ProviderCredentials) async throws -> ProviderUsageSnapshot

    /// Determine which account a credential belongs to, ideally without
    /// consuming quota. Returns the provider's stable account key.
    func identifyAccount(_ credentials: ProviderCredentials) async throws -> String

    /// Renew an access token that is at or near expiry. Returns nil for
    /// providers whose tokens don't expire — callers keep using the current
    /// credential rather than treating nil as a failure.
    func refreshCredentials(_ credentials: ProviderCredentials) async throws -> ProviderCredentials?
}

extension UsageProviderClient {
    /// Default: nothing to refresh. Providers with expiring tokens override.
    func refreshCredentials(_ credentials: ProviderCredentials) async throws -> ProviderCredentials? {
        nil
    }
}
