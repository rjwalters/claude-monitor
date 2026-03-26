import Foundation
import os

private let logger = Logger(subsystem: "com.claude-monitor.app", category: "AnthropicAPI")
private let flog = FileLogger.shared
private let fcat = "API"

// Auto-updated by build script from installed claude-code version
private let claudeCodeUserAgent = "claude-code/2.0.37"

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

    /// Session utilization as percentage (0–100)
    var sessionPercent: Double { (sessionUtilization ?? 0) * 100 }

    /// Weekly utilization as percentage (0–100)
    var weeklyPercent: Double { (weeklyUtilization ?? 0) * 100 }

    /// Whether this account is currently rate-limited
    var isRateLimited: Bool { overallStatus == "rejected" }

    /// Session reset as ISO 8601 string (for DB storage)
    var sessionResetISO: String? {
        sessionReset.map { ISO8601DateFormatter().string(from: $0) }
    }

    /// Weekly reset as ISO 8601 string (for DB storage)
    var weeklyResetISO: String? {
        weeklyReset.map { ISO8601DateFormatter().string(from: $0) }
    }
}

// MARK: - API Errors

enum AnthropicAPIError: Error, LocalizedError {
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

// MARK: - API Client

class AnthropicAPIClient {
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

        let headers = httpResponse.allHeaderFields

        let orgId = headers["anthropic-organization-id"] as? String ?? ""

        let pingResponse = PingResponse(
            organizationId: orgId,
            httpStatus: status,
            sessionUtilization: parseDouble(headers["anthropic-ratelimit-unified-5h-utilization"]),
            sessionReset: parseEpoch(headers["anthropic-ratelimit-unified-5h-reset"]),
            sessionStatus: headers["anthropic-ratelimit-unified-5h-status"] as? String,
            weeklyUtilization: parseDouble(headers["anthropic-ratelimit-unified-7d-utilization"]),
            weeklyReset: parseEpoch(headers["anthropic-ratelimit-unified-7d-reset"]),
            weeklyStatus: headers["anthropic-ratelimit-unified-7d-status"] as? String,
            overallStatus: headers["anthropic-ratelimit-unified-status"] as? String
        )

        let pct5h = String(format: "%.0f%%", pingResponse.sessionPercent)
        let pct7d = String(format: "%.0f%%", pingResponse.weeklyPercent)
        flog.info("Ping \(status) — org: \(orgId.prefix(8))... session: \(pct5h) (\(pingResponse.sessionStatus ?? "?")), weekly: \(pct7d) (\(pingResponse.weeklyStatus ?? "?"))", category: fcat)

        return pingResponse

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

        guard let orgId = httpResponse.allHeaderFields["anthropic-organization-id"] as? String, !orgId.isEmpty else {
            throw AnthropicAPIError.invalidResponse
        }

        flog.info("Token identified — org: \(orgId)", category: fcat)
        return orgId
    }

    // MARK: - Helpers

    private func parseDouble(_ value: Any?) -> Double? {
        if let str = value as? String { return Double(str) }
        if let num = value as? Double { return num }
        if let num = value as? NSNumber { return num.doubleValue }
        return nil
    }

    private func parseEpoch(_ value: Any?) -> Date? {
        let epoch: TimeInterval?
        if let str = value as? String { epoch = TimeInterval(str) }
        else if let num = value as? NSNumber { epoch = num.doubleValue }
        else { return nil }
        guard let epoch = epoch else { return nil }
        return Date(timeIntervalSince1970: epoch)
    }
}
