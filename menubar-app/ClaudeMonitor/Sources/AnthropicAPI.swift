import Foundation
import os

private let logger = Logger(subsystem: "com.claude-monitor.app", category: "AnthropicAPI")

// MARK: - API Response Types

struct UsageResponse: Codable {
    let fiveHour: UsageBucket?
    let sevenDay: UsageBucket?
    let sevenDaySonnet: UsageBucket?
    let sevenDayOpus: UsageBucket?
    let extraUsage: ExtraUsage?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDaySonnet = "seven_day_sonnet"
        case sevenDayOpus = "seven_day_opus"
        case extraUsage = "extra_usage"
    }
}

struct UsageBucket: Codable {
    let utilization: Double
    let resetsAt: String?

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }
}

struct ExtraUsage: Codable {
    let isEnabled: Bool
    let monthlyLimit: Double?
    let usedCredits: Double?

    enum CodingKeys: String, CodingKey {
        case isEnabled = "is_enabled"
        case monthlyLimit = "monthly_limit"
        case usedCredits = "used_credits"
    }
}

struct TokenRefreshResponse: Codable {
    let accessToken: String
    let tokenType: String?
    let expiresIn: Int?
    let refreshToken: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
    }
}

// MARK: - API Client

enum AnthropicAPIError: Error, LocalizedError {
    case unauthorized
    case httpError(Int)
    case tokenRefreshFailed
    case invalidResponse
    case networkError(Error)

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "Unauthorized — token may be expired or revoked"
        case .httpError(let code):
            return "HTTP error \(code)"
        case .tokenRefreshFailed:
            return "Token refresh failed — re-authenticate with Claude Code"
        case .invalidResponse:
            return "Invalid response from API"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        }
    }

    /// Whether this error is transient and worth retrying
    var isTransient: Bool {
        switch self {
        case .httpError(let code):
            return code == 429 || (500...599).contains(code)
        case .networkError:
            return true
        case .unauthorized, .invalidResponse, .tokenRefreshFailed:
            return false
        }
    }
}

class AnthropicAPIClient {
    private let session = URLSession.shared

    func fetchUsage(accessToken: String) async throws -> UsageResponse {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("claude-code/2.0.32", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            logger.error("Network error fetching usage: \(error.localizedDescription)")
            throw AnthropicAPIError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AnthropicAPIError.invalidResponse
        }

        if httpResponse.statusCode == 401 {
            logger.warning("Unauthorized response from usage API")
            throw AnthropicAPIError.unauthorized
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            logger.warning("HTTP \(httpResponse.statusCode) from usage API")
            throw AnthropicAPIError.httpError(httpResponse.statusCode)
        }

        return try JSONDecoder().decode(UsageResponse.self, from: data)
    }

    func refreshToken(refreshToken: String) async throws -> TokenRefreshResponse {
        var request = URLRequest(url: URL(string: "https://console.anthropic.com/v1/oauth/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = "grant_type=refresh_token&refresh_token=\(refreshToken)&client_id=9d1c250a-e61b-44d9-88ed-5944d1962f5e"
        request.httpBody = body.data(using: .utf8)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            logger.error("Network error refreshing token: \(error.localizedDescription)")
            throw AnthropicAPIError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AnthropicAPIError.tokenRefreshFailed
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            logger.warning("Token refresh failed with HTTP \(httpResponse.statusCode)")
            throw AnthropicAPIError.tokenRefreshFailed
        }

        return try JSONDecoder().decode(TokenRefreshResponse.self, from: data)
    }
}
