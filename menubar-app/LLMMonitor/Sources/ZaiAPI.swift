import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// z.ai (Zhipu) GLM Coding Plan usage client.
///
/// ### Wire contract (live-verified 2026-09-24 against three Max-plan keys)
///
/// `GET https://api.z.ai/api/monitor/usage/quota/limit` with
/// `Authorization: Bearer <api key>` (the bare key is accepted too). Read-only;
/// no completion quota is spent.
///
/// ```json
/// {"code":200,"msg":"Operation successful","success":true,
///  "data":{"level":"max","limits":[
///    {"type":"CREDIT_LIMIT","unit":3,"number":5,"usage":28000,
///     "currentValue":0,"remaining":28000,"percentage":0},
///    {"type":"CREDIT_LIMIT","unit":6,"number":1,"usage":140000,
///     "currentValue":140045,"remaining":0,"percentage":100,
///     "nextResetTime":1790617927983}]}}
/// ```
///
/// - **`usage` is the window's cap, `currentValue` is what was spent** — the
///   names read backwards. `percentage` is an integer rounding of the same
///   ratio, so the ratio is preferred when both halves are present.
/// - The window length is `number × unit`: unit `3` = hours (the 5h bucket),
///   unit `6` = weeks (confirmed by `nextResetTime` always landing < 7 days
///   out). Other unit codes are unverified and yield an unknown duration
///   rather than a guess.
/// - `nextResetTime` is **epoch milliseconds**, and is omitted for a window
///   nothing has been spent in yet (it starts rolling at first use).
/// - **Errors come back as HTTP 200** with `success: false` and the real code
///   in the body (`401` "token expired or incorrect", `1001` no auth header),
///   so the HTTP status alone must never be read as success.
/// - The response carries **no identity** (no email, no account id), so the
///   account key is supplied by whoever registered the key — see
///   `ZaiKeyFile`.
///
/// Portable core: no AppKit / SwiftUI / Combine / os.Logger — builds on Linux.

private let flog = FileLogger.shared
private let fcat = "Zai"

// MARK: - Wire types

struct ZaiQuotaResponse: Decodable {
    let code: Int?
    let msg: String?
    let success: Bool?
    let data: DataBody?

    struct DataBody: Decodable {
        let level: String?
        let limits: [Limit]?
    }

    struct Limit: Decodable {
        let type: String?
        let unit: Int?
        let number: Int?
        /// The window's cap (despite the name).
        let usage: Double?
        /// Amount spent in the current window.
        let currentValue: Double?
        let remaining: Double?
        let percentage: Double?
        /// Epoch milliseconds.
        let nextResetTime: Double?

        /// Seconds per `unit` code. Only the verified codes are mapped.
        static func secondsPerUnit(_ unit: Int?) -> TimeInterval? {
            switch unit {
            case 3: return 3600
            case 6: return 7 * 86400
            default: return nil
            }
        }

        var durationSeconds: TimeInterval? {
            guard let perUnit = Self.secondsPerUnit(unit), let number = number, number > 0 else { return nil }
            return perUnit * TimeInterval(number)
        }

        var usedPercent: Double? {
            if let cap = usage, cap > 0, let spent = currentValue {
                return min(100, max(0, spent / cap * 100))
            }
            return percentage
        }

        func asRateLimitWindow() -> RateLimitWindow? {
            guard let usedPercent = usedPercent else { return nil }
            let duration = durationSeconds
            let reset = nextResetTime.flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0 / 1000) : nil }
            return RateLimitWindow(
                kind: RateLimitWindow.kind(forDuration: duration),
                usedPercent: usedPercent,
                durationSeconds: duration,
                resetAt: reset,
                status: usedPercent >= 100 ? "rejected" : "allowed"
            )
        }
    }
}

// MARK: - Client

final class ZaiAPIClient: Sendable {
    static let usageURL = URL(string: "https://api.z.ai/api/monitor/usage/quota/limit")!

    /// Limit types that are the plan's prompt/token quota and so belong in the
    /// session/weekly buckets. Anything else (e.g. a monthly MCP tool-call
    /// `TIME_LIMIT`) is kept as a named sub-limit so it can never masquerade as
    /// the coding quota.
    static let quotaLimitTypes: Set<String> = ["CREDIT_LIMIT", "TOKENS_LIMIT"]

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Read one key's quota. `accountKey` is the caller's stable id for the
    /// account, because the response carries none.
    func fetchUsage(apiKey: String, accountKey: String) async throws -> ProviderUsageSnapshot {
        var request = URLRequest(url: Self.usageURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en", forHTTPHeaderField: "Accept-Language")
        request.timeoutInterval = 30

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            flog.error("Network error fetching z.ai quota: \(error.localizedDescription)", category: fcat)
            throw ProviderAPIError.networkError(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw ProviderAPIError.invalidResponse
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw ProviderAPIError.unauthorized
        }
        guard (200..<300).contains(http.statusCode) else {
            flog.warning("Unexpected HTTP \(http.statusCode) from z.ai quota", category: fcat)
            throw ProviderAPIError.httpError(http.statusCode)
        }

        return try Self.snapshot(from: data, httpStatus: http.statusCode, accountKey: accountKey)
    }

    /// Map a raw quota body onto the shared snapshot type. Split out from the
    /// network call so the self-test can exercise it offline.
    static func snapshot(from data: Data, httpStatus: Int, accountKey: String) throws -> ProviderUsageSnapshot {
        let decoded: ZaiQuotaResponse
        do {
            decoded = try JSONDecoder().decode(ZaiQuotaResponse.self, from: data)
        } catch {
            flog.error("Could not decode z.ai quota response (\(data.count) bytes)", category: fcat)
            throw ProviderAPIError.invalidResponse
        }

        // The real status lives in the body; HTTP is 200 either way.
        guard decoded.success == true, let body = decoded.data else {
            let code = decoded.code ?? 0
            flog.warning("z.ai quota rejected: code \(code) (\(decoded.msg ?? "no message"))", category: fcat)
            if code == 401 || code == 403 || (1000...1099).contains(code) {
                throw ProviderAPIError.unauthorized
            }
            throw ProviderAPIError.httpError(code == 200 || code == 0 ? httpStatus : code)
        }

        var windows: [RateLimitWindow] = []
        var named: [String: RateLimitWindow] = [:]
        var raw: [String: String] = [:]
        if let level = body.level { raw["level"] = level }

        for (index, limit) in (body.limits ?? []).enumerated() {
            // Archive only the known numeric/enum fields — never `msg` or
            // anything free-form the provider might add later.
            let prefix = "limits[\(index)]."
            if let v = limit.type { raw[prefix + "type"] = v }
            for (key, value) in [("unit", limit.unit.map(Double.init)), ("number", limit.number.map(Double.init)),
                                 ("usage", limit.usage), ("currentValue", limit.currentValue),
                                 ("remaining", limit.remaining), ("percentage", limit.percentage),
                                 ("nextResetTime", limit.nextResetTime)] {
                if let value = value { raw[prefix + key] = String(format: "%.0f", value) }
            }

            guard let window = limit.asRateLimitWindow() else { continue }
            if Self.quotaLimitTypes.contains(limit.type ?? "") {
                windows.append(window)
            } else {
                named["\(limit.type ?? "limit").\(window.kind.key)"] = window
            }
        }

        let rateLimit = RateLimitSnapshot(windows: windows, named: named)
        let overall = [rateLimit.session, rateLimit.weekly].compactMap { $0 }.contains { $0.isExhausted }
            ? "rejected" : "allowed"
        // The same derived status keys the Anthropic ping blob carries, so
        // `RankingExporter.mapStatus` reports an exhausted key as `exhausted` /
        // `rate_limited` rather than `available`.
        raw["overall_status"] = overall
        if let s = rateLimit.session?.status { raw["session_status"] = s }
        if let s = rateLimit.weekly?.status { raw["weekly_status"] = s }

        return ProviderUsageSnapshot(
            provider: .zai,
            accountKey: accountKey,
            httpStatus: httpStatus,
            rateLimit: RateLimitSnapshot(session: rateLimit.session, weekly: rateLimit.weekly,
                                         named: rateLimit.named, overallStatus: overall),
            email: nil,
            plan: body.level,
            rawFields: raw
        )
    }
}

// MARK: - Key files

/// One z.ai key as registered on disk: `~/.zai/coding-plan-<label>.env`,
/// holding a single `ZAI_API_KEY=…` line (the same line `loom-daemon api-keys
/// add zai <label>` consumes) and, by convention, an `(account: <email>)`
/// header comment.
struct ZaiKeyFile: Equatable {
    let label: String
    let email: String?
    let apiKey: String

    /// Stable `accounts.id` for a z.ai key. Keyed on identity (email, else the
    /// Loom pool label) rather than on the key, so rotating a key rolls the
    /// credential in place instead of creating a second account.
    var accountId: String { Self.accountId(email: email, label: label) }

    static func accountId(email: String?, label: String) -> String {
        if let email = email?.trimmingCharacters(in: .whitespaces).lowercased(), !email.isEmpty {
            return "zai:\(email)"
        }
        return "zai:\(label)"
    }

    /// Where key files are read from: `$LLM_MONITOR_ZAI_DIR`, else `~/.zai`.
    static var defaultDirectory: String {
        if let override = AppPaths.environment("ZAI_DIR") {
            return override
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".zai").path
    }

    /// Parse one file's content. Returns nil when it carries no `ZAI_API_KEY`
    /// (e.g. opencode's `coding-plan.env`, which holds the same key under
    /// `ZHIPU_API_KEY` and must not register a duplicate account).
    static func parse(_ content: String, label: String) -> ZaiKeyFile? {
        var key: String?
        var email: String?
        for rawLine in content.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") {
                if email == nil, let range = line.range(of: "(account: ") {
                    let rest = line[range.upperBound...]
                    if let end = rest.firstIndex(of: ")") {
                        let candidate = rest[..<end].trimmingCharacters(in: .whitespaces)
                        if candidate.contains("@") { email = candidate }
                    }
                }
                continue
            }
            var assignment = line
            if assignment.hasPrefix("export ") { assignment = String(assignment.dropFirst(7)) }
            guard assignment.hasPrefix("ZAI_API_KEY=") else { continue }
            var value = String(assignment.dropFirst("ZAI_API_KEY=".count)).trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let first = value.first, first == value.last, first == "\"" || first == "'" {
                value = String(value.dropFirst().dropLast())
            }
            if !value.isEmpty { key = value }
        }
        guard let apiKey = key else { return nil }
        return ZaiKeyFile(label: label, email: email, apiKey: apiKey)
    }

    /// Every `coding-plan-<label>.env` in `directory` that carries a key,
    /// sorted by label. A missing directory is simply empty.
    static func scan(directory: String = defaultDirectory) -> [ZaiKeyFile] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory) else { return [] }
        let prefix = "coding-plan-", suffix = ".env"
        var seenKeys = Set<String>()
        return names.sorted().compactMap { name -> ZaiKeyFile? in
            guard name.hasPrefix(prefix), name.hasSuffix(suffix), name.count > prefix.count + suffix.count else { return nil }
            let label = String(name.dropFirst(prefix.count).dropLast(suffix.count))
            let path = (directory as NSString).appendingPathComponent(name)
            guard let content = try? String(contentsOfFile: path, encoding: .utf8),
                  let file = parse(content, label: label),
                  seenKeys.insert(file.apiKey).inserted else { return nil }
            return file
        }
    }
}
