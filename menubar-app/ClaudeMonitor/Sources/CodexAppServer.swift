import Foundation
// `kill` / `SIGKILL` / `usleep` are POSIX, not Foundation: Linux's
// swift-corelibs-foundation does not re-export them, so the platform module has
// to be imported explicitly for the headless build.
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Codex `app-server` provider client — reads OpenAI/ChatGPT subscription usage
/// by asking the locally-installed Codex CLI, so **this app never reads, stores,
/// or refreshes an OpenAI credential**.
///
/// ```
/// codex -s read-only -a untrusted app-server
/// initialize → initialized (notification) → account/read → account/rateLimits/read
/// ```
///
/// Why this exists: OpenAI rotates the refresh token on every use and states
/// that one `auth.json` must not be shared across machines. A stored copy and
/// Codex CLI's own copy therefore invalidate each other in turn (observed: nine
/// days of `refresh_token_invalidated` on healthy accounts). Handing the whole
/// credential lifecycle back to Codex removes the race at its root.
///
/// ## Verified wire behaviour (codex-cli 0.147.0, macOS arm64, 2026-08-15)
///
/// - **Framing is newline-delimited JSON**, one object per line on stdout —
///   *not* LSP-style `Content-Length:` headers.
/// - **Replies omit the `jsonrpc` member.** A decoder that requires it rejects
///   every reply, so `CodexRPCEnvelope` does not model that key at all.
/// - **Server notifications carry no `id`** (e.g.
///   `{"method":"remoteControl/status/changed","params":{…},"emittedAtMs":…}`)
///   and must be skipped rather than mistaken for a reply.
/// - **Closing the child's stdin makes it exit 0 on its own**, which is why
///   shutdown closes stdin before escalating to SIGTERM/SIGKILL. It writes
///   nothing to stderr.
/// - **`account/read` on a logged-in home returns**
///   `{"account":{"type":"chatgpt","email":…,"planType":…},"requiresOpenaiAuth":true}`
///   — note `requiresOpenaiAuth` is `true` even when logged in, so the
///   "needs login" signal is `account == null`, **not** that flag.
/// - **An unauthenticated `CODEX_HOME` answers `account/read` cleanly with
///   `{"account":null,…}` and then fails `account/rateLimits/read` with
///   `-32600`** — the same code an *unsupported method* returns on codex 0.46.0.
///   The two are disambiguated by `account/read`: a non-null account means the
///   home is fine, so `-32600` there can only mean "this codex is too old".
/// - **`account/read` carries no account id.** `accountKey` therefore comes back
///   empty and the caller keeps the id it already stored; a successful
///   rate-limit read is never discarded over identity.
///
/// Portable core: no AppKit / SwiftUI / Combine / os.Logger — builds on Linux,
/// where `Foundation.Process` is provided by swift-corelibs-foundation.
///
/// ## Security
///
/// `account/read` returns an **email**. Nothing here logs a raw JSON-RPC line, a
/// response body, an email, or a token; archived `rawFields` go through
/// `OpenAIUsageResponse.flatten`, the same every-depth redactor the `wham` path
/// already uses, rather than a second shallower one.

private let flog = FileLogger.shared
private let fcat = "Codex"

// MARK: - Path redaction

/// A filesystem path with the user's home directory collapsed to `~`.
///
/// Every `CODEX_HOME` is under a home directory, and a home directory contains
/// a **username** — so a raw path must never reach `debug.log`, an error string
/// persisted to `oauth_credentials.last_error`, or anything archived. `~/.codex-b`
/// is exactly as actionable as `/Users/alice/.codex-b` and carries no identity.
///
/// Both platform prefixes are handled explicitly rather than only
/// `NSHomeDirectory()`, because a poll may be reasoning about a home under some
/// path the process did not itself resolve.
func redactHomePath(_ path: String) -> String {
    let home = NSHomeDirectory()
    if !home.isEmpty, path == home { return "~" }
    if !home.isEmpty, path.hasPrefix(home + "/") {
        return "~" + path.dropFirst(home.count)
    }
    // A path under some *other* account's home still names a user; collapse the
    // whole `/Users/<name>` or `/home/<name>` prefix rather than echoing it.
    for root in ["/Users/", "/home/"] {
        guard path.hasPrefix(root) else { continue }
        let rest = path.dropFirst(root.count)
        guard let slash = rest.firstIndex(of: "/") else { return "~" }
        return "~" + rest[slash...]
    }
    return path
}

// MARK: - Version diagnostics

/// The `result` payload of an `initialize` reply — the only field the
/// resolved-binary diagnostic log line needs.
struct CodexInitializeResult: Decodable {
    let userAgent: String?
}

/// Extracts the version string from an `initialize` reply's `result` payload
/// (`userAgent`), or nil when the field is absent or the payload doesn't
/// decode at all.
///
/// Verified shape on both tested releases: `{"userAgent":
/// "codex_cli_rs/0.46.0", …}` and `{"userAgent": "codex_cli_rs/0.147.0",
/// "codexHome": …, "platformFamily": …, "platformOs": …}` — see
/// `docs/spikes/2026-07-30-codex-usage-probe.md`. Reading it back here means
/// no separate `codex --version` subprocess is needed just to surface the
/// version in the log. A free function (not private) so the self-test can
/// exercise it directly against both verified wire shapes.
func codexVersionFromInitializeResult(_ data: Data) -> String? {
    (try? JSONDecoder().decode(CodexInitializeResult.self, from: data))?.userAgent
}

// MARK: - Errors

/// Why a `codex app-server` read could not be completed.
///
/// Each case is a *distinct, actionable* degradation — none of them is a crash
/// and none of them ever produces a fabricated 0% reading. `isCapabilityGap`
/// separates "this transport is unavailable here, try the next tier" from "this
/// account is genuinely unhealthy".
enum CodexAppServerError: Error, LocalizedError {
    /// No `codex` executable on any candidate path.
    case binaryNotFound
    /// The child could not be launched (permissions, bad override path, …).
    case launchFailed(String)
    /// `account/read` reported `account: null` — this `CODEX_HOME` has no login.
    case notLoggedIn(String)
    /// A **registered** `CODEX_HOME` no longer exists on disk (renamed, on an
    /// unmounted volume, or removed). Distinct from `notLoggedIn`: there is
    /// nothing to log in *to*, so the fix is to re-register the account rather
    /// than to run `codex login`.
    case homeMissing(String)
    /// The RPC answered `-32600`/`-32601` for a method this codex is too old to
    /// implement. Verified: 0.46.0 returns `-32600` for every unknown method.
    case methodUnsupported(String)
    /// A method did not answer inside its budget.
    case timedOut(String)
    /// Anything else on the wire: undecodable line, early exit, RPC error with
    /// an unexpected code.
    case protocolFailure(String)

    var errorDescription: String? {
        switch self {
        case .binaryNotFound:
            return "Codex CLI not found — install `@openai/codex`, or set CLAUDE_MONITOR_CODEX_BIN"
        case .launchFailed(let detail):
            return "Could not start codex app-server: \(detail)"
        case .notLoggedIn(let home):
            // Redacted: this string is logged and persisted to
            // `oauth_credentials.last_error`, and a raw home path names a user.
            return "Codex home not logged in (\(redactHomePath(home))) — run `CODEX_HOME=\(redactHomePath(home)) codex login --device-auth`"
        case .homeMissing(let home):
            return "Codex home \(redactHomePath(home)) does not exist — re-register with `claude-monitor codex add --home <path>`"
        case .methodUnsupported(let method):
            return "codex app-server does not implement \(method) — upgrade to codex 0.147.0 or newer"
        case .timedOut(let method):
            return "Codex app-server did not respond (timed out on \(method))"
        case .protocolFailure(let detail):
            return "Codex app-server protocol failure: \(detail)"
        }
    }

    /// True when this transport simply isn't available on this host — the
    /// caller should quietly fall back to another tier rather than mark the
    /// account unhealthy.
    var isCapabilityGap: Bool {
        switch self {
        case .binaryNotFound, .methodUnsupported, .launchFailed:
            return true
        // `homeMissing` is emphatically *not* a capability gap: the transport
        // works fine on this host, it is this account's registration that is
        // broken, and silently falling through would hide that forever.
        case .notLoggedIn, .homeMissing, .timedOut, .protocolFailure:
            return false
        }
    }

    /// The per-account health state this degradation should surface when every
    /// fallback tier has also failed.
    var tokenStatus: TokenStatus {
        switch self {
        case .notLoggedIn: return .missing
        case .binaryNotFound, .launchFailed, .methodUnsupported, .homeMissing, .timedOut, .protocolFailure:
            return .error
        }
    }
}

// MARK: - Binary resolution

/// Finds an **absolute** path to the `codex` executable.
///
/// `/usr/bin/env codex` is deliberately *not* used: a Finder-launched `.app`
/// inherits launchd's minimal `PATH` (`/usr/bin:/bin:/usr/sbin:/sbin`), which
/// contains neither Homebrew's nor npm's global bin directory. `env` therefore
/// resolves during `swift run` development and fails inside the shipped bundle
/// — the worst possible place to discover it.
enum CodexBinary {
    /// Explicit override, and the seam the self-test points at a stub binary.
    static let overrideEnvKey = "CLAUDE_MONITOR_CODEX_BIN"

    /// Absolute fallbacks probed after `PATH`, covering Homebrew (both
    /// architectures) and the usual npm global prefixes.
    static let fallbackDirectories = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "~/.local/bin",
        "~/.npm-global/bin",
        "~/.nvm/versions/node/current/bin",
    ]

    /// First executable `codex` among: the override, each `PATH` entry, then
    /// `fallbackDirectories`. Returns nil when none exists.
    ///
    /// `environment` is injected rather than read inline so the self-test can
    /// exercise resolution without mutating the process environment.
    static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> String? {
        if let override = environment[overrideEnvKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty {
            // An override that doesn't resolve is a configuration mistake worth
            // failing on, not something to silently paper over with PATH.
            return fileManager.isExecutableFile(atPath: override) ? override : nil
        }

        let home = environment["HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let pathDirs = (environment["PATH"] ?? "").split(separator: ":").map(String.init)

        for directory in pathDirs + fallbackDirectories {
            guard !directory.isEmpty else { continue }
            var expanded = directory
            if expanded.hasPrefix("~/") {
                guard let home = home, !home.isEmpty else { continue }
                expanded = (home as NSString).appendingPathComponent(String(expanded.dropFirst(2)))
            }
            let candidate = (expanded as NSString).appendingPathComponent("codex")
            if fileManager.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }
}

/// Process-wide dedup for the resolved-binary diagnostic log line below.
///
/// `CodexAppServerClient` is constructed fresh per account on every poll (see
/// `OAuthPoller`), so a per-instance "have I logged this already" flag would
/// reset every cycle and defeat the point. This cache is keyed on the
/// resolved path + reported version, so a poll cycle logs nothing when both
/// are unchanged, and logs again only when the binary itself changes (a
/// Homebrew formula→cask swap, an `npm i -g @openai/codex` upgrade, …).
///
/// `@unchecked Sendable` over an `NSLock`, matching `CodexLineStream`'s
/// established pattern in this file for shared mutable state touched from
/// concurrent call sites. Internal, not `private`, so the self-test can
/// instantiate a scratch instance and exercise the dedup logic directly
/// without touching (or being polluted by) `.shared`.
final class CodexBinaryVersionLog: @unchecked Sendable {
    static let shared = CodexBinaryVersionLog()
    private let lock = NSLock()
    private var lastLoggedKey: String?

    /// Returns true (and records `key`) the first time this exact key is
    /// seen; false on every repeat.
    func shouldLog(_ key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard lastLoggedKey != key else { return false }
        lastLoggedKey = key
        return true
    }
}

// MARK: - JSONL framing

/// Reassembles newline-delimited JSON from arbitrary read chunks.
///
/// A pipe read boundary lands wherever the kernel puts it: one `availableData`
/// chunk may hold half an object, or three whole ones. Split out as a value type
/// with no I/O so the self-test can drive it byte-by-byte.
struct CodexLineFramer {
    /// Hard cap on a single unterminated line, so a wedged or hostile child
    /// cannot grow this buffer without bound. 4 MB is ~40x the largest observed
    /// reply.
    static let maxBufferedBytes = 4 * 1024 * 1024

    private var buffer = Data()
    /// Set once the cap is hit; every later chunk is discarded rather than
    /// accumulated. The caller notices via the missing reply → timeout.
    private(set) var overflowed = false

    /// Feed one read chunk; returns every complete, non-empty line it finished.
    mutating func append(_ chunk: Data) -> [Data] {
        guard !overflowed else { return [] }
        buffer.append(chunk)

        var lines: [Data] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[buffer.startIndex..<newline])
            buffer.removeSubrange(buffer.startIndex...newline)
            if !line.isEmpty { lines.append(line) }
        }

        if buffer.count > Self.maxBufferedBytes {
            overflowed = true
            buffer = Data()
        }
        return lines
    }
}

/// Accumulates stdout lines from the reader callback and hands them to the
/// awaiting request loop.
///
/// `@unchecked Sendable` over an `NSLock`, **not an actor**, and the reason is
/// load-bearing: an actor would force the `@Sendable` readability callback to
/// hop via `Task { await … }`, and those unstructured tasks have **no ordering
/// guarantee**. Two pipe chunks could then be framed out of order, splicing one
/// half-line into another and silently corrupting every reply after it (this
/// was observed as an intermittent handshake timeout before the fix). Foundation
/// delivers readability callbacks serially per file handle, so ingesting
/// synchronously under a lock preserves byte order by construction.
///
/// Invariant the lock protects: `framer`, `pending`, and `sawEOF` are touched
/// only inside `withLock`, from the callback thread (producer) and the polling
/// request loop (consumer).
private final class CodexLineStream: @unchecked Sendable {
    private let lock = NSLock()
    private var framer = CodexLineFramer()
    private var pending: [Data] = []
    private var sawEOF = false
    /// Replies that arrived before the request loop asked for them. Kept for the
    /// whole session — a reply read while waiting on a *different* id must
    /// survive until its own `awaitReply` call, not be scoped to (and discarded
    /// with) the call that happened to observe it.
    private var stashed: [Int: Data] = [:]

    /// An empty chunk is the pipe's EOF signal.
    func ingest(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        if chunk.isEmpty {
            sawEOF = true
        } else {
            pending.append(contentsOf: framer.append(chunk))
        }
    }

    func take() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return pending.isEmpty ? nil : pending.removeFirst()
    }

    func stash(_ id: Int, _ line: Data) {
        lock.lock()
        defer { lock.unlock() }
        stashed[id] = line
    }

    func takeStashed(_ id: Int) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return stashed.removeValue(forKey: id)
    }

    /// True once the child closed stdout and every buffered line was consumed.
    var isDrained: Bool {
        lock.lock()
        defer { lock.unlock() }
        return sawEOF && pending.isEmpty
    }
}

// MARK: - JSON-RPC envelope

/// The parts of a reply this client needs.
///
/// **`jsonrpc` is deliberately absent**: codex app-server does not send it
/// (verified 0.46.0 and 0.147.0), so requiring it would reject every reply.
/// `id` is optional because server notifications legitimately have none.
struct CodexRPCEnvelope: Decodable {
    struct RPCError: Decodable {
        let code: Int?
        let message: String?
    }
    let id: Int?
    let error: RPCError?
}

/// Typed `result` extraction from the same line, decoded separately so the
/// envelope stays usable even when `result`'s shape is unknown.
private struct CodexRPCResult<T: Decodable>: Decodable {
    let result: T?
}

// MARK: - Identity

/// Who a `CODEX_HOME` is logged in as, as reported by `account/read`.
///
/// **Carries no account id** — `account/read` has none on any verified version
/// (spike §4 item 7). Registration keys the row on `auth.json`'s
/// `tokens.account_id`, falling back to matching an existing row by email.
struct CodexAccountIdentity: Sendable {
    let email: String?
    let planType: String?
}

// MARK: - Wire model

/// `account/read` and `account/rateLimits/read` payloads.
///
/// Every field is optional: `app-server` is marked `[experimental]` and its
/// shape has already changed between releases, so a missing key must degrade
/// rather than crash. Keys are already camelCase on the wire — no
/// `convertFromSnakeCase` here (that would mangle `usedPercent`).
enum CodexWire {
    struct AccountRead: Decodable {
        struct Account: Decodable {
            let type: String?
            let email: String?
            let planType: String?
        }
        let account: Account?
        /// Observed `true` even on a logged-in home — do **not** read this as
        /// "needs login"; `account == nil` is the real signal.
        let requiresOpenaiAuth: Bool?
    }

    /// One rate-limit window. `windowDurationMins` is **minutes** — the shared
    /// model wants seconds (see `RateLimitWindow.init(usedPercent:durationSeconds:)`),
    /// and the `wham` contract's `limit_window_seconds` is the same quantity in
    /// a different unit. Treating minutes as seconds would silently file a
    /// 10080-minute weekly window as `.other(10080)` and drop it from the
    /// ranking, so the conversion lives in exactly one place: here.
    struct Window: Decodable {
        let usedPercent: Double?
        let windowDurationMins: Double?
        /// Unix epoch **seconds** (verified: 10 digits on 0.147.0).
        let resetsAt: Double?

        var durationSeconds: TimeInterval? {
            guard let mins = windowDurationMins, mins > 0 else { return nil }
            return mins * 60
        }

        /// Defensive: a provider that switches to milliseconds must not yield a
        /// year-56000 date. Anything past ~2286 in seconds is treated as ms.
        var resolvedResetAt: Date? {
            guard let raw = resetsAt, raw > 0 else { return nil }
            return Date(timeIntervalSince1970: raw > 1e12 ? raw / 1000 : raw)
        }

        /// This window in the shared model, or nil when no usage figure came
        /// back — a window we know nothing about must never read as 0%.
        func asRateLimitWindow(status: String?) -> RateLimitWindow? {
            guard let usedPercent = usedPercent else { return nil }
            return RateLimitWindow(
                usedPercent: usedPercent,
                durationSeconds: durationSeconds,
                resetAt: resolvedResetAt,
                status: status
            )
        }
    }

    struct Credits: Decodable {
        let hasCredits: Bool?
        let unlimited: Bool?
        let balance: String?
    }

    struct Limits: Decodable {
        let limitId: String?
        let limitName: String?
        let primary: Window?
        /// `null` on every observed reply — the already-supported "this account
        /// reports no session window" case, stored as NULL rather than 0.
        let secondary: Window?
        let credits: Credits?
        let spendControlReached: Bool?
        let planType: String?

        /// Account-wide status in the `allowed` / `rejected` vocabulary
        /// `RankingExporter.mapStatus` already parses. Spend control being
        /// reached, or any known window at the cap, is a hard stop.
        var statusString: String {
            if spendControlReached == true { return "rejected" }
            let windows = [primary, secondary].compactMap { $0?.usedPercent }
            if windows.contains(where: { $0 >= 100 }) { return "rejected" }
            return "allowed"
        }

        /// Both windows, unordered — callers file them by duration.
        var windows: [RateLimitWindow] {
            let status = statusString
            return [primary, secondary].compactMap { $0?.asRateLimitWindow(status: status) }
        }
    }

    struct RateLimitsRead: Decodable {
        let rateLimits: Limits?
        /// Per-model / per-feature sub-limits, keyed by limit id (e.g.
        /// `codex_bengalfox` → `limitName: "GPT-5.3-Codex-Spark"`).
        let rateLimitsByLimitId: [String: Limits]?

        /// Map onto the shared snapshot. Window kind is derived from each
        /// window's **duration**, so a weekly `primary` lands in `weekly`
        /// regardless of the slot it arrived in.
        var rateLimitSnapshot: RateLimitSnapshot {
            var named: [String: RateLimitWindow] = [:]
            let topLevelID = rateLimits?.limitId
            for (key, limit) in rateLimitsByLimitId ?? [:] {
                // Skip the entry that merely duplicates the top-level bucket.
                if let topLevelID = topLevelID, key == topLevelID { continue }
                guard let window = limit.windows.max(by: { $0.usedPercent < $1.usedPercent })
                else { continue }
                let label = limit.limitName?.trimmingCharacters(in: .whitespacesAndNewlines)
                named[label?.isEmpty == false ? label! : key] = window
            }
            return RateLimitSnapshot(
                windows: rateLimits?.windows ?? [],
                named: named,
                overallStatus: rateLimits?.statusString
            )
        }
    }

    /// Decode a `result` payload. No key-decoding strategy: the wire is already
    /// camelCase.
    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }
}

// MARK: - Client

/// Reads Codex usage over `codex app-server`.
///
/// `Sendable`: the only stored state is immutable configuration; every
/// subprocess and its buffers are created and torn down inside one call.
final class CodexAppServerClient: Sendable {
    /// Per-method budgets. `initialize` is slower than the rest (the child does
    /// its own start-up work first), and `overall` caps a wedged child so it can
    /// never stall the poll loop.
    struct Timeouts: Sendable {
        var initialize: TimeInterval = 20
        var method: TimeInterval = 10
        var overall: TimeInterval = 45
        /// How long the child gets to exit after stdin closes, before SIGTERM.
        var gracefulExit: TimeInterval = 2
        /// How long it gets after SIGTERM, before SIGKILL.
        var terminateGrace: TimeInterval = 1

        init() {}
    }

    /// `CODEX_HOME` for the child. nil = whatever the app itself inherited
    /// (`$CODEX_HOME`, else `~/.codex`).
    ///
    /// One home speaks for exactly one ChatGPT login, so this is how an account
    /// is told apart from its siblings: `OAuthPoller` builds a **new client per
    /// account** from that account's `accounts.codex_home`, and correct
    /// attribution becomes a property of the construction rather than something
    /// detected after the fact (#103).
    let codexHome: String?
    let timeouts: Timeouts
    /// Environment consulted for binary resolution and inherited by the child.
    private let environment: [String: String]

    init(
        codexHome: String? = nil,
        timeouts: Timeouts = Timeouts(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.codexHome = codexHome
        self.timeouts = timeouts
        self.environment = environment
    }

    /// The `CODEX_HOME` this client will hand the child, for error messages.
    var effectiveCodexHome: String {
        if let codexHome = codexHome, !codexHome.isEmpty { return codexHome }
        if let inherited = environment["CODEX_HOME"], !inherited.isEmpty { return inherited }
        return (environment["HOME"].map { ($0 as NSString).appendingPathComponent(".codex") })
            ?? "~/.codex"
    }

    /// Whether a `codex` executable exists at all. Cheap enough to call before
    /// deciding to try this tier.
    var isAvailable: Bool { CodexBinary.resolve(environment: environment) != nil }

    // MARK: Usage

    /// Run the four-message handshake and map the result.
    ///
    /// Honest signature: this transport needs **no credential**, which is the
    /// entire point of the issue behind it.
    func fetchUsage() async throws -> ProviderUsageSnapshot {
        let (accountLine, rateLimitsLine) = try await handshake(includeRateLimits: true)
        guard let rateLimitsLine = rateLimitsLine else {
            throw CodexAppServerError.protocolFailure("account/rateLimits/read returned nothing")
        }
        return try Self.snapshot(
            accountResult: accountLine,
            rateLimitsResult: rateLimitsLine
        )
    }

    /// Who this home is logged in as, without asking for usage.
    ///
    /// `codex add` and `codex list` need the login state and the plan/email of
    /// one specific home, and nothing else — asking for rate limits too would
    /// make registration fail on a `codex` too old to implement that method
    /// (0.46.0 answers `-32600`) even though the home is perfectly usable.
    ///
    /// Throws `.notLoggedIn` when `account/read` reports `account: null` — the
    /// real "needs login" signal, since `requiresOpenaiAuth` is `true` even on a
    /// logged-in home.
    func fetchAccountIdentity() async throws -> CodexAccountIdentity {
        let (accountLine, _) = try await handshake(includeRateLimits: false)
        // `handshake` swallows a `-32600` on account/read (an old codex) by
        // returning nil, because the rate-limit call is normally the one that
        // decides. There is no such call here, so name the capability gap.
        guard let accountLine = accountLine else {
            throw CodexAppServerError.methodUnsupported("account/read")
        }
        guard let decoded = try? CodexWire.decode(CodexWire.AccountRead.self, from: accountLine),
              let account = decoded.account else {
            // `handshake` already throws `.notLoggedIn` for `account: null`, so
            // reaching here means the reply was undecodable rather than empty.
            throw CodexAppServerError.protocolFailure("account/read reply carried no usable account")
        }
        return CodexAccountIdentity(email: account.email, planType: account.planType)
    }

    // MARK: Mapping (pure — exercised offline by selftest)

    /// Build the shared snapshot from the two `result` payloads.
    ///
    /// `accountKey` comes back **empty**: `account/read` carries no account id
    /// on any verified version, and inventing one would collide across
    /// accounts. `OAuthPoller` keeps the id it already stored, so a good
    /// rate-limit read is never thrown away over identity.
    static func snapshot(accountResult: Data?, rateLimitsResult: Data) throws -> ProviderUsageSnapshot {
        let limits: CodexWire.RateLimitsRead
        do {
            limits = try CodexWire.decode(CodexWire.RateLimitsRead.self, from: rateLimitsResult)
        } catch {
            // Never log the payload — it is provider data of unknown shape.
            throw CodexAppServerError.protocolFailure(
                "could not decode account/rateLimits/read (\(rateLimitsResult.count) bytes)"
            )
        }

        let account = accountResult.flatMap {
            try? CodexWire.decode(CodexWire.AccountRead.self, from: $0)
        }?.account

        let snapshot = limits.rateLimitSnapshot
        guard !snapshot.isEmpty else {
            throw CodexAppServerError.protocolFailure("account/rateLimits/read reported no windows")
        }

        // Redaction: the same every-depth redactor the `wham` path uses, so the
        // email `account/read` volunteers can never reach `usage_history.raw_data`.
        var rawFields = OpenAIUsageResponse.flatten(rateLimitsResult, prefix: "rate_limits")
        if let accountResult = accountResult {
            rawFields.merge(OpenAIUsageResponse.flatten(accountResult, prefix: "account")) { current, _ in current }
        }
        rawFields["transport"] = "codex-app-server"
        rawFields["overall_status"] = snapshot.overallStatus
        rawFields["session_status"] = snapshot.session?.status
        rawFields["weekly_status"] = snapshot.weekly?.status

        let session = snapshot.session.map { String(format: "%.0f%%", $0.usedPercent) } ?? "—"
        let weekly = snapshot.weekly.map { String(format: "%.0f%%", $0.usedPercent) } ?? "—"
        flog.info(
            "codex app-server usage — session: \(session), weekly: \(weekly) (\(snapshot.overallStatus ?? "?"))",
            category: fcat
        )

        return ProviderUsageSnapshot(
            provider: .openai,
            accountKey: "",
            httpStatus: 200,
            rateLimit: snapshot,
            email: account?.email,
            plan: account?.planType ?? limits.rateLimits?.planType,
            rawFields: rawFields
        )
    }

    /// Diagnostic breadcrumb for the stale-Homebrew-formula failure mode
    /// (issue #115): logs the resolved `codex` binary path and reported
    /// version once per distinct (path, version) pair via
    /// `CodexBinaryVersionLog`, not on every poll cycle. The path is always
    /// redacted — it can be `~/.local/bin/codex` or `~/.npm-global/bin/codex`,
    /// both username-bearing once `$HOME` is expanded — matching every other
    /// path-bearing log line in this file.
    ///
    /// Never throws: a reply that fails to decode just yields "version
    /// unknown" rather than aborting a handshake that otherwise succeeded.
    private static func logResolvedBinaryVersionOnce(binaryPath: String, initializeResult: Data) {
        let userAgent = codexVersionFromInitializeResult(initializeResult)
        let redactedPath = redactHomePath(binaryPath)
        let version = userAgent ?? "version unknown"
        guard CodexBinaryVersionLog.shared.shouldLog("\(redactedPath)|\(version)") else { return }
        flog.info("codex binary resolved: \(redactedPath) (\(version))", category: fcat)
    }

    /// Classify an RPC error on `account/rateLimits/read`.
    ///
    /// `-32600`/`-32601` mean "this codex does not implement the method" —
    /// verified: codex 0.46.0 answers `-32600 Invalid request` identically for
    /// `account/rateLimits/read`, `account/read`, and a deliberately bogus
    /// method. It is a **capability gap, never an unhealthy account**. The other
    /// producer of `-32600` (an unauthenticated home) is ruled out earlier, by
    /// `account/read` returning a non-null account.
    static func classify(_ error: CodexRPCEnvelope.RPCError?, method: String) -> CodexAppServerError {
        switch error?.code {
        case -32600, -32601:
            return .methodUnsupported(method)
        default:
            // Message text is provider-controlled; the code is enough to act on.
            return .protocolFailure("\(method) failed with code \(error?.code.map(String.init) ?? "?")")
        }
    }

    // MARK: Transport

    /// Spawn, handshake, and reap. Returns the raw `result` payloads for
    /// `account/read` (nil when that method is unsupported) and
    /// `account/rateLimits/read` (nil when `includeRateLimits` is false).
    private func handshake(includeRateLimits: Bool) async throws -> (account: Data?, rateLimits: Data?) {
        // A *registered* home that has vanished must say so in its own words.
        // Without this, codex resolves the missing directory by creating or
        // ignoring it and answers `account: null`, which would read as "needs
        // login" and send the user off to run a login that isn't the fix.
        if let codexHome = codexHome, !codexHome.isEmpty,
           !FileManager.default.fileExists(atPath: codexHome) {
            throw CodexAppServerError.homeMissing(codexHome)
        }

        guard let binary = CodexBinary.resolve(environment: environment) else {
            throw CodexAppServerError.binaryNotFound
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        // `-s` / `-a` are top-level flags and must precede the subcommand.
        process.arguments = ["-s", "read-only", "-a", "untrusted", "app-server"]

        var childEnv = environment
        if let codexHome = codexHome, !codexHome.isEmpty {
            childEnv["CODEX_HOME"] = codexHome
        }
        process.environment = childEnv

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        // Never a pipe: an undrained stderr fills its ~64 KB buffer and blocks
        // the child forever. (Observed: app-server writes nothing there anyway.)
        process.standardError = FileHandle.nullDevice

        let stream = CodexLineStream()
        let readHandle = stdoutPipe.fileHandleForReading
        // Framed synchronously on the callback's own (serial) delivery — see
        // `CodexLineStream` for why an async hop here would reorder chunks.
        readHandle.readabilityHandler = { handle in
            stream.ingest(handle.availableData)
        }

        do {
            try process.run()
        } catch {
            readHandle.readabilityHandler = nil
            throw CodexAppServerError.launchFailed(error.localizedDescription)
        }

        // Reaping runs on every exit path — success, throw, timeout, and task
        // cancellation — because it is the `defer` of the frame that owns the
        // process.
        defer { Self.reap(process, stdin: stdinPipe.fileHandleForWriting, stdout: readHandle, timeouts: timeouts) }

        let overallDeadline = Date().addingTimeInterval(timeouts.overall)
        let writer = stdinPipe.fileHandleForWriting

        // 1. initialize — `clientInfo{name,version}` is required.
        try Self.send(writer, [
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": ["clientInfo": ["name": "claude-monitor", "version": AppVersion.current]],
        ])
        let initializeResult = try await awaitReply(
            id: 1, method: "initialize", stream: stream, process: process,
            deadline: Self.earliest(Date().addingTimeInterval(timeouts.initialize), overallDeadline)
        )
        Self.logResolvedBinaryVersionOnce(binaryPath: binary, initializeResult: initializeResult)

        // 2. initialized — a notification, so no id and no reply.
        try Self.send(writer, ["jsonrpc": "2.0", "method": "initialized", "params": [:]])

        // 3. account/read — the login probe, and where plan/email come from.
        //    An old codex answers -32600 here too; that is a capability gap, so
        //    carry on and let the rate-limit call make the final call.
        var accountResult: Data?
        try Self.send(writer, ["jsonrpc": "2.0", "id": 2, "method": "account/read", "params": [:]])
        do {
            accountResult = try await awaitReply(
                id: 2, method: "account/read", stream: stream, process: process,
                deadline: Self.earliest(Date().addingTimeInterval(timeouts.method), overallDeadline)
            )
            let decoded = accountResult.flatMap { try? CodexWire.decode(CodexWire.AccountRead.self, from: $0) }
            if decoded?.account == nil {
                // Verified: an unauthenticated home returns `account: null` here
                // and then -32600 on rate limits. Naming it now keeps that -32600
                // from being misread as "codex too old".
                throw CodexAppServerError.notLoggedIn(effectiveCodexHome)
            }
        } catch let error as CodexAppServerError {
            guard case .methodUnsupported = error else { throw error }
            accountResult = nil
        }

        // 4. account/rateLimits/read — the payload this whole path exists for.
        //    Skipped entirely by the identity probe (`codex add` / `codex list`),
        //    which only needs to know who this home is and whether it is logged in.
        guard includeRateLimits else { return (accountResult, nil) }
        try Self.send(writer, ["jsonrpc": "2.0", "id": 3, "method": "account/rateLimits/read", "params": [:]])
        let rateLimits = try await awaitReply(
            id: 3, method: "account/rateLimits/read", stream: stream, process: process,
            deadline: Self.earliest(Date().addingTimeInterval(timeouts.method), overallDeadline)
        )

        return (accountResult, rateLimits)
    }

    private static func earliest(_ a: Date, _ b: Date) -> Date { a < b ? a : b }

    /// Write one newline-terminated JSON object to the child's stdin.
    private static func send(_ handle: FileHandle, _ message: [String: Any]) throws {
        guard var data = try? JSONSerialization.data(withJSONObject: message, options: [.sortedKeys]) else {
            throw CodexAppServerError.protocolFailure("could not encode a request")
        }
        data.append(0x0A)
        do {
            try handle.write(contentsOf: data)
        } catch {
            // A closed pipe means the child is already gone; the awaiting read
            // turns that into the specific per-method failure.
            throw CodexAppServerError.protocolFailure("child stdin closed early")
        }
    }

    /// Wait for the reply carrying `id`.
    ///
    /// Deliberately **no `CheckedContinuation`**: reply-arrival, timeout, and
    /// early-child-exit are three independent completion paths, and resuming a
    /// continuation twice is a crash rather than a warning. Polling a buffer
    /// against a deadline makes that race structurally impossible, and the whole
    /// exchange is sub-second so the wakeups are negligible.
    ///
    /// Replies are matched by **`id`**, never by arrival order: an id-less server
    /// notification is skipped, and a reply for some *other* id is stashed for
    /// its own `awaitReply` rather than discarded.
    private func awaitReply(
        id: Int,
        method: String,
        stream: CodexLineStream,
        process: Process,
        deadline: Date
    ) async throws -> Data {
        // This reply may already have been read while a previous call was
        // waiting on a different id.
        if let stashed = stream.takeStashed(id) {
            return try Self.consume(stashed, method: method)
        }

        while true {
            try Task.checkCancellation()

            if let line = stream.take() {
                guard let envelope = try? JSONDecoder().decode(CodexRPCEnvelope.self, from: line) else {
                    // Not a JSON-RPC object we understand (banner text, a shape
                    // from a future version): skip it rather than fail the poll.
                    continue
                }
                guard let replyID = envelope.id else { continue }  // notification
                if replyID == id { return try Self.consume(line, method: method) }
                stream.stash(replyID, line)
                continue
            }

            if Date() >= deadline { throw CodexAppServerError.timedOut(method) }
            if stream.isDrained, !process.isRunning {
                throw CodexAppServerError.protocolFailure("app-server exited before answering \(method)")
            }
            try await Task.sleep(nanoseconds: 15_000_000)
        }
    }

    /// Turn a matched reply line into its `result` payload, re-encoded as
    /// standalone JSON for the typed decoders and the redacting flattener — or
    /// throw the classified RPC error it carried instead.
    private static func consume(_ line: Data, method: String) throws -> Data {
        if let envelope = try? JSONDecoder().decode(CodexRPCEnvelope.self, from: line),
           let error = envelope.error {
            throw classify(error, method: method)
        }
        guard let wrapper = try? JSONDecoder().decode(CodexRPCResult<JSONValue>.self, from: line),
              let result = wrapper.result,
              let encoded = try? JSONEncoder().encode(result) else {
            throw CodexAppServerError.protocolFailure("\(method) reply carried no usable result")
        }
        return encoded
    }

    // MARK: Reaping

    /// Shut the child down and wait for it, always.
    ///
    /// Order matters and is verified: closing stdin alone makes `app-server`
    /// exit 0 on its own, so that is the polite first step. SIGTERM
    /// (`Process.terminate()`) and then SIGKILL (`kill(pid, SIGKILL)` — there is
    /// no Foundation API for it) escalate only if it doesn't.
    ///
    /// In practice the whole sequence costs microseconds: the child is already
    /// gone by the first `waitForExit`. Only a wedged child reaches the
    /// escalation, and even then this is bounded by
    /// `gracefulExit + terminateGrace + 2`.
    private static func reap(_ process: Process, stdin: FileHandle, stdout: FileHandle, timeouts: Timeouts) {
        stdout.readabilityHandler = nil
        try? stdin.close()

        if !waitForExit(process, within: timeouts.gracefulExit) {
            if process.isRunning { process.terminate() }
            if !waitForExit(process, within: timeouts.terminateGrace) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                // SIGKILL cannot be refused; this only waits for Foundation's
                // own monitor to observe the exit and reap the zombie.
                _ = waitForExit(process, within: 2)
            }
        }
        try? stdout.close()
    }

    /// Poll `isRunning` until the child is gone; true if it exited in time.
    ///
    /// **`Process.waitUntilExit()` is deliberately not used.** On Darwin it
    /// spins a `CFRunLoop` on the *calling* thread, and this runs on a
    /// concurrency-pool thread that has no run loop being serviced — it blocked
    /// in `mach_msg` indefinitely there even after the child had already exited
    /// (caught as an intermittent self-test hang; stack sampled). Foundation's
    /// own termination monitor reaps the child, so `isRunning == false` already
    /// means "no zombie left behind".
    private static func waitForExit(_ process: Process, within seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while process.isRunning {
            if Date() >= deadline { return false }
            usleep(10_000)
        }
        return true
    }
}

// MARK: - UsageProviderClient conformance

/// Conforms even though the protocol is credential-shaped, because the poller's
/// `client(for:)` dispatch is the useful part and widening the protocol for a
/// two-provider app is not worth it (option (b) in the issue). The alternative
/// of smuggling the codex home through `ProviderCredentials.accessToken` is
/// explicitly rejected: it would put a filesystem path in the one field every
/// redaction rule treats as a secret.
extension CodexAppServerClient: UsageProviderClient {
    var provider: AccountProvider { .openai }

    /// **`credentials` is intentionally ignored.** This transport hands the
    /// entire credential lifecycle to the Codex CLI — having nothing to pass is
    /// the whole point, not an oversight. Call `fetchUsage()` directly where the
    /// honest signature is available.
    func fetchUsage(_ credentials: ProviderCredentials) async throws -> ProviderUsageSnapshot {
        try await fetchUsage()
    }

    /// `account/read` carries no account id on any verified version, so this
    /// returns the same empty key `fetchUsage` does. Callers keep the id they
    /// already hold.
    func identifyAccount(_ credentials: ProviderCredentials) async throws -> String {
        try await fetchUsage().accountKey
    }

    // `refreshCredentials` takes the protocol's default nil: there is nothing to
    // refresh, which is this client's entire thesis.
}
