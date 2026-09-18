import Foundation

/// Daily quota-calibration series: how much *spend* one weekly rate-limit
/// point actually buys (#198, phase 2 of #196).
///
/// The question this answers is "what is a weekly point worth?" — in tokens, in
/// cost-equivalent tokens, and in dollars — so a downstream consumer
/// (rjwalters/loom#8063) can watch that figure for a step change and notice
/// that Anthropic re-priced the quota underneath the fleet.
///
/// ## Why a rolling daily series, and not at-reset rows
///
/// The pre-v2.0 native host computed calibration **only** inside its
/// reset-detection branch (`b9db622^:native-host/claude_monitor_host.cjs:698`),
/// which is at best one row per account per weekly reset and in practice was
/// never populated at all. Worse, its period start came from
/// `getLastCalibrationReset`, which fell back to `1970-01-01T00:00:00Z` on an
/// empty table — so the first row it would ever have written summed every token
/// the host had ever seen. Neither defect is reproduced here: the primary
/// artifact is a per-UTC-day series, recomputed over a trailing window from
/// scratch every run.
///
/// ## How points are counted
///
/// `usage_history.weekly_all_percent` is integer-valued (0.0, 1.0, … 100.0 —
/// 101 distinct values observed over a multi-week window), so **one weekly
/// point is the measurement quantum**. Consumption for a day is the sum of the
/// *positive* deltas between consecutive samples, which discards the drop to
/// zero at a weekly reset while keeping every real increment.
///
/// Two details make that sum correct rather than approximately correct:
///
/// * **Ordering ties are real and must break on `(timestamp, id)`.** When a
///   reset is detected, `OAuthPoller.writeUsageToDB` inserts a synthetic
///   carry-forward row and a synthetic `0` row, and that `0` row shares its
///   whole-second timestamp with the real row written immediately after it
///   (observed live: `2026-09-17T18:07:09Z|0.0|is_synthetic=1` followed by
///   `2026-09-17T18:07:09Z|0.0|is_synthetic=0`). Ordering by timestamp alone
///   leaves that pair's order unspecified, and the wrong order manufactures a
///   spurious positive delta at exactly the boundary where the series is most
///   fragile. Rows are therefore sorted by `(parsed timestamp, rowid)` — and
///   parsed, not compared as text, because this codebase writes ISO 8601 both
///   with and without fractional seconds and those two shapes do **not** sort
///   lexically against each other.
/// * **Synthetic rows are kept, not filtered.** The synthetic carry-forward row
///   is what makes the drop to zero a single negative delta instead of a lost
///   increment; dropping it would under-count every reset day.
///
/// ## Why the account denominator moves
///
/// The number of accounts reporting on a given day is not constant (19 → 15 →
/// 19 → 20 across one measured window, as accounts are added, retired, or
/// simply fail to poll). A bare pool total is therefore not comparable across
/// days, so every pool row carries `accountsReporting` and `pointsPerAccount`
/// alongside it. "Reported" means *produced at least one `weekly_all_percent`
/// reading that day* — not "consumed something", because an idle account is
/// still part of the pool it is being averaged over.
///
/// ## Anthropic accounts only
///
/// A `provider = 'openai'` account also stores a `weekly_all_percent`, but it
/// is a percentage of a completely different quota and its spend does not
/// appear in Claude Code transcripts at all. Summing the two pools would
/// produce a number with no meaning, so the points series is restricted to
/// Anthropic accounts (a `usage_history` row whose account row is missing
/// entirely is treated as Anthropic, matching `AccountProvider.fallback`).
///
/// ## Isolation
///
/// A plain `enum` namespace of pure static functions over a database path — no
/// shared mutable state and no actor isolation, so the CLI, the poll loop's
/// detached task, and `SelfTest` can all call it directly.
enum QuotaCalibration {

    // MARK: - Configuration

    /// Days recomputed by default, including today. Every run rewrites this
    /// whole trailing window from the source series rather than appending to
    /// it, so repeated runs converge instead of accumulating drift.
    static let defaultWindowDays = 14

    /// Minimum points accumulated in a day before a per-point ratio is
    /// reported at all.
    ///
    /// One weekly point is the measurement quantum (see the type comment), so a
    /// day that accumulated 1 point carries ±50% quantization error and a day
    /// that accumulated 0.0 carries an undefined one. Dividing a day's token
    /// total by a denominator that small produces a number that looks precise
    /// and is not — exactly the "wildly-scaled ratio" this floor exists to
    /// suppress. Below the floor the row is still written (the point count
    /// itself is real and worth keeping), but every `…PerPoint` column is NULL.
    ///
    /// 5.0 caps the quantization error of the ratio at ±10%.
    static let defaultMinPointsForRatio: Double = 5.0

    /// How far back before the window start to read source rows purely to seed
    /// the first in-window delta.
    ///
    /// The first sample of the window's first day needs its predecessor to
    /// produce a delta, and that predecessor is on the previous day. One day of
    /// lookback covers the 10-minute poll cadence with four orders of magnitude
    /// to spare. If the host was offline for longer than that, the opening
    /// delta of the window is dropped rather than attributing a multi-day
    /// accumulation to a single day — the conservative choice, and the one that
    /// keeps the series from showing a fake spike on the day a host came back.
    private static let seedLookbackDays = 1

    static var defaultDBPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude-monitor/usage.db").path
    }

    // MARK: - Cost weights

    /// List price for one model family, in USD per million tokens.
    ///
    /// The four rates are not independent: across every Claude model the cache
    /// write rate is 1.25× the input rate and the cache read rate is 0.1× it
    /// (that is the ratio #196 measured), so only the *base* rate really varies
    /// per family. They are spelled out individually anyway rather than derived
    /// from a multiplier, because a price table that has to be re-derived to be
    /// checked against a public price list is a price table nobody checks.
    struct ModelPrice: Sendable, Equatable {
        let inputUSDPerMTok: Double
        let outputUSDPerMTok: Double
        let cacheWriteUSDPerMTok: Double
        let cacheReadUSDPerMTok: Double

        func costUSD(input: Int, output: Int, cacheCreation: Int, cacheRead: Int) -> Double {
            (Double(input) * inputUSDPerMTok
                + Double(output) * outputUSDPerMTok
                + Double(cacheCreation) * cacheWriteUSDPerMTok
                + Double(cacheRead) * cacheReadUSDPerMTok) / 1_000_000.0
        }
    }

    /// One entry of the ordered match table: the first `pattern` found inside a
    /// normalized model id wins, so the most specific pattern must come first.
    struct PricedFamily: Sendable, Equatable {
        let pattern: String
        let price: ModelPrice
    }

    /// A dated snapshot of the published per-model list prices, plus the
    /// baseline the cost-equivalent token unit is denominated in.
    ///
    /// **These go stale.** They are a copy of a public price list taken on
    /// `version`, not a live lookup, and Anthropic re-prices models (Opus 4.5
    /// launched at a third of Opus 4.1's rate). A calibration series computed
    /// against a stale table drifts silently, which is the one failure mode
    /// this whole feature exists to detect — so when a price changes, add a new
    /// dated table rather than editing this one in place, and leave the old
    /// `version` string recoverable in git history. Every written row records
    /// the `version` it was computed under for exactly this reason.
    struct CostWeights: Sendable, Equatable {
        /// Date the prices below were copied, `YYYY-MM-DD`. Stored on every
        /// calibration row.
        let version: String
        /// Where they were copied from, for the next person to re-check.
        let source: String
        /// The rate one "cost-equivalent token" is worth. Cost-equivalent
        /// tokens are a *cost* expressed in token units: the number of baseline
        /// input tokens that would have cost the same. Using a token unit
        /// rather than raw dollars keeps the headline figure comparable with
        /// the raw token counts sitting beside it in the same row.
        let baselineInputUSDPerMTok: Double
        /// What `baselineInputUSDPerMTok` is the rate *of*, for the docs.
        let baselineLabel: String
        /// Ordered most-specific-first; see `PricedFamily`.
        let families: [PricedFamily]
        /// Price used for a model id that matches nothing above.
        let fallback: ModelPrice
        /// Human-readable name of `fallback`, for the "unknown model" warning.
        let fallbackLabel: String

        /// Lowercased, with `.` folded to `-`, so `claude-opus-4.5` and
        /// `claude-opus-4-5-20251101` normalize to the same shape.
        static func normalize(_ model: String) -> String {
            model.lowercased().replacingOccurrences(of: ".", with: "-")
        }

        /// The price for `model`, and whether it was actually recognized.
        /// Unrecognized models are **priced at the fallback and counted**, not
        /// dropped: a new model id appearing mid-window would otherwise make
        /// the day it appeared look cheap, which reads exactly like the price
        /// improvement this series is watching for. The caller reports the
        /// unrecognized ids so the table can be extended.
        func price(for model: String) -> (price: ModelPrice, recognized: Bool) {
            let normalized = Self.normalize(model)
            for family in families where normalized.contains(family.pattern) {
                return (family.price, true)
            }
            return (fallback, false)
        }

        /// Cost expressed in baseline input tokens — see
        /// `baselineInputUSDPerMTok`.
        func costEquivalentTokens(usd: Double) -> Double {
            guard baselineInputUSDPerMTok > 0 else { return 0 }
            return usd * 1_000_000.0 / baselineInputUSDPerMTok
        }
    }

    /// The price table in force. Dated; see `CostWeights`.
    ///
    /// Source: Anthropic's published API pricing page, read 2026-09-18. Rates
    /// are the standard (≤200K context) tier in USD per million tokens, and
    /// cache-write rates are the 5-minute TTL tier — `token_usage` records a
    /// single `cache_creation_tokens` counter with no TTL breakdown, and the
    /// 5-minute tier is what Claude Code writes by default.
    ///
    /// | Family        | input | output | cache write | cache read |
    /// |---------------|-------|--------|-------------|------------|
    /// | Opus 4.5      |  5.00 |  25.00 |        6.25 |       0.50 |
    /// | Opus 4 / 4.1  | 15.00 |  75.00 |       18.75 |       1.50 |
    /// | Sonnet 4/4.5  |  3.00 |  15.00 |        3.75 |       0.30 |
    /// | Haiku 4.5     |  1.00 |   5.00 |        1.25 |       0.10 |
    /// | Haiku 3.5     |  0.80 |   4.00 |        1.00 |       0.08 |
    static let currentWeights = CostWeights(
        version: "2026-09-18",
        source: "Anthropic published API list prices (standard ≤200K context tier, "
            + "5-minute cache-write TTL), read 2026-09-18",
        baselineInputUSDPerMTok: 3.00,
        baselineLabel: "Sonnet-class input tokens at $3.00/MTok",
        families: [
            // Most specific first: "opus-4-5" must be tested before "opus-4",
            // and "opus-4" before the bare "opus" catch-all.
            PricedFamily(pattern: "opus-4-5", price: ModelPrice(
                inputUSDPerMTok: 5.00, outputUSDPerMTok: 25.00,
                cacheWriteUSDPerMTok: 6.25, cacheReadUSDPerMTok: 0.50)),
            PricedFamily(pattern: "opus-4-1", price: ModelPrice(
                inputUSDPerMTok: 15.00, outputUSDPerMTok: 75.00,
                cacheWriteUSDPerMTok: 18.75, cacheReadUSDPerMTok: 1.50)),
            PricedFamily(pattern: "opus-4", price: ModelPrice(
                inputUSDPerMTok: 15.00, outputUSDPerMTok: 75.00,
                cacheWriteUSDPerMTok: 18.75, cacheReadUSDPerMTok: 1.50)),
            PricedFamily(pattern: "opus", price: ModelPrice(
                inputUSDPerMTok: 15.00, outputUSDPerMTok: 75.00,
                cacheWriteUSDPerMTok: 18.75, cacheReadUSDPerMTok: 1.50)),
            PricedFamily(pattern: "sonnet", price: ModelPrice(
                inputUSDPerMTok: 3.00, outputUSDPerMTok: 15.00,
                cacheWriteUSDPerMTok: 3.75, cacheReadUSDPerMTok: 0.30)),
            PricedFamily(pattern: "haiku-4", price: ModelPrice(
                inputUSDPerMTok: 1.00, outputUSDPerMTok: 5.00,
                cacheWriteUSDPerMTok: 1.25, cacheReadUSDPerMTok: 0.10)),
            // Claude 3.5 Haiku's id reads `claude-3-5-haiku-…`, so the version
            // precedes the family name and "haiku-3-5" would never match.
            PricedFamily(pattern: "3-5-haiku", price: ModelPrice(
                inputUSDPerMTok: 0.80, outputUSDPerMTok: 4.00,
                cacheWriteUSDPerMTok: 1.00, cacheReadUSDPerMTok: 0.08)),
            PricedFamily(pattern: "haiku", price: ModelPrice(
                inputUSDPerMTok: 1.00, outputUSDPerMTok: 5.00,
                cacheWriteUSDPerMTok: 1.25, cacheReadUSDPerMTok: 0.10)),
        ],
        // Sonnet, not zero and not the cheapest: an unpriced model billed at 0
        // would silently deflate the series, and the fleet's dominant model is
        // Sonnet-class, so this is the least-wrong stand-in until the id is
        // added above.
        fallback: ModelPrice(
            inputUSDPerMTok: 3.00, outputUSDPerMTok: 15.00,
            cacheWriteUSDPerMTok: 3.75, cacheReadUSDPerMTok: 0.30),
        fallbackLabel: "Sonnet-class"
    )

    // MARK: - Model

    /// Whether a row describes the whole pool or one account.
    enum Scope: String, Sendable, Equatable {
        case pool
        case account
    }

    /// One computed calibration row: a `(day, scope, account)` triple.
    ///
    /// Every ratio is optional, and `nil` means **unknown** — never zero. A
    /// consumer that reads a missing `costUSDPerPoint` as 0 would report a
    /// quota that had become free, which is the inverse of the alarm this
    /// series exists to raise.
    struct DailyRow: Sendable, Equatable {
        /// UTC calendar day, `YYYY-MM-DD`.
        let day: String
        let scope: Scope
        /// `nil` exactly when `scope == .pool`.
        let accountId: String?

        /// Sum of positive `weekly_all_percent` deltas attributed to this day.
        let pointsConsumed: Double
        /// Distinct accounts that produced a reading this day (always 1 for an
        /// account-scoped row).
        let accountsReporting: Int
        /// `pointsConsumed / accountsReporting` — the figure that is comparable
        /// across days as the pool grows and shrinks.
        let pointsPerAccount: Double

        /// `nil` when no session→account mapping attributes tokens to this row
        /// (see `TokenTotals` and the per-account attribution note below).
        let tokens: TokenTotals?

        /// Cost of `tokens` under the weights named by `weightsVersion`.
        let costUSD: Double?
        /// `costUSD` re-expressed in baseline input tokens.
        let costEquivalentTokens: Double?

        /// Raw `input + output + cache_creation + cache_read` per point. Kept
        /// beside the cost-equivalent figure precisely because they are *not*
        /// the same quantity — the deleted native host conflated them.
        let rawTokensPerPoint: Double?
        let costEquivalentTokensPerPoint: Double?
        let costUSDPerPoint: Double?

        let weightsVersion: String
        let computedAt: String

        var rawTokens: Int { tokens?.raw ?? 0 }
    }

    /// The four `token_usage` counters, summed.
    struct TokenTotals: Sendable, Equatable {
        var input = 0
        var output = 0
        var cacheCreation = 0
        var cacheRead = 0

        var raw: Int { input + output + cacheCreation + cacheRead }
        var isEmpty: Bool { raw == 0 }

        static func += (lhs: inout TokenTotals, rhs: TokenTotals) {
            lhs.input += rhs.input
            lhs.output += rhs.output
            lhs.cacheCreation += rhs.cacheCreation
            lhs.cacheRead += rhs.cacheRead
        }
    }

    /// Token counters **plus the cost they were priced at**.
    ///
    /// The two travel together deliberately. Pricing is per model, so cost has
    /// to be accumulated while the per-model breakdown is still in hand; once a
    /// day's models are summed into one `TokenTotals` the information needed to
    /// price it is gone. Re-deriving a cost from collapsed totals at some
    /// single "representative" rate is exactly the kind of quietly-wrong number
    /// this feature exists to catch, so the type makes it impossible to carry
    /// one without the other.
    struct TokenAggregate: Sendable, Equatable {
        var totals = TokenTotals()
        var costUSD: Double = 0

        var isEmpty: Bool { totals.isEmpty }

        static func += (lhs: inout TokenAggregate, rhs: TokenAggregate) {
            lhs.totals += rhs.totals
            lhs.costUSD += rhs.costUSD
        }
    }

    /// What one `recompute` run did. Counts and identifiers only — no account
    /// id, email, or path is ever placed in here, because this is what gets
    /// logged.
    struct RecomputeResult: Sendable, Equatable {
        var windowStartDay = ""
        var daysComputed = 0
        var poolRows = 0
        var accountRows = 0
        /// Account rows that carry token attribution (i.e. an explicit
        /// session→account mapping existed). Zero is the normal state today.
        var attributedAccountRows = 0
        /// Distinct `token_usage.model` values that matched no priced family.
        /// Model ids are product identifiers, not user data, so naming them is
        /// safe and is the only way an operator learns the table needs a row.
        var unknownModels: [String] = []

        var summary: String {
            "\(daysComputed) day(s) from \(windowStartDay): "
                + "\(poolRows) pool row(s), \(accountRows) account row(s)"
                + (attributedAccountRows > 0 ? " (\(attributedAccountRows) token-attributed)" : "")
                + (unknownModels.isEmpty ? "" : "; unpriced model(s): \(unknownModels.joined(separator: ", "))")
        }
    }

    enum CalibrationError: Error, LocalizedError, CustomStringConvertible {
        case databaseMissing(String)
        case database(String)

        var description: String {
            switch self {
            case .databaseMissing(let path):
                return "No usage database at \(path) — nothing to calibrate."
            case .database(let message):
                return "Quota calibration failed: \(message)"
            }
        }
        var errorDescription: String? { description }
    }

    // MARK: - Recompute

    /// Recomputes the trailing `days`-day calibration series and rewrites it
    /// into `quota_calibration_daily`.
    ///
    /// **Idempotent by construction**: the window's existing rows are deleted
    /// and the freshly derived ones inserted inside one transaction, so a
    /// second run over unchanged inputs produces byte-identical rows and can
    /// never duplicate them. Nothing is read back from the table to decide what
    /// to write — there is no incremental state to drift.
    ///
    /// - Parameters:
    ///   - dbPath: database to read and write. Must already exist.
    ///   - days: trailing window length, including today (UTC).
    ///   - minPointsForRatio: see `defaultMinPointsForRatio`.
    ///   - weights: price table; every row records `weights.version`.
    ///   - now: injectable clock, so tests are not time-of-day dependent.
    @discardableResult
    static func recompute(
        dbPath: String = defaultDBPath,
        days: Int = defaultWindowDays,
        minPointsForRatio: Double = defaultMinPointsForRatio,
        weights: CostWeights = currentWeights,
        now: Date = Date()
    ) throws -> RecomputeResult {
        guard FileManager.default.fileExists(atPath: dbPath) else {
            throw CalibrationError.databaseMissing(redactPath(dbPath))
        }

        let db: Connection
        do {
            db = try openDatabase(dbPath)
            try UsageStore.applySchema(db)
        } catch {
            throw CalibrationError.database(redactPath("\(error)"))
        }

        let window = Window(days: max(1, days), now: now)
        let computed = try computeRows(
            db: db, window: window, minPointsForRatio: minPointsForRatio,
            weights: weights, now: now)

        do {
            try db.execute("BEGIN")
            try db.run("DELETE FROM quota_calibration_daily WHERE day >= ?", window.startDay)
            let insert = try db.prepare("""
                INSERT INTO quota_calibration_daily (
                    day, scope, account_id, points_consumed, accounts_reporting,
                    points_per_account, input_tokens, output_tokens,
                    cache_creation_tokens, cache_read_tokens, raw_tokens,
                    cost_equivalent_tokens, cost_usd, raw_tokens_per_point,
                    cost_equivalent_tokens_per_point, cost_usd_per_point,
                    weights_version, computed_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """)
            for row in computed.rows {
                try insert.bind(values: [
                    row.day, row.scope.rawValue, row.accountId,
                    row.pointsConsumed, row.accountsReporting, row.pointsPerAccount,
                    row.tokens?.input, row.tokens?.output,
                    row.tokens?.cacheCreation, row.tokens?.cacheRead, row.tokens?.raw,
                    row.costEquivalentTokens, row.costUSD, row.rawTokensPerPoint,
                    row.costEquivalentTokensPerPoint, row.costUSDPerPoint,
                    row.weightsVersion, row.computedAt,
                ]).run()
            }
            try db.execute("COMMIT")
        } catch {
            try? db.execute("ROLLBACK")
            throw CalibrationError.database(redactPath("\(error)"))
        }

        var result = RecomputeResult()
        result.windowStartDay = window.startDay
        result.daysComputed = Set(computed.rows.map(\.day)).count
        result.poolRows = computed.rows.filter { $0.scope == .pool }.count
        result.accountRows = computed.rows.filter { $0.scope == .account }.count
        result.attributedAccountRows = computed.rows
            .filter { $0.scope == .account && $0.tokens != nil }.count
        result.unknownModels = computed.unknownModels.sorted()
        return result
    }

    // MARK: - Pure computation

    /// The trailing window, resolved to UTC calendar days once so every query
    /// and every row key agrees about where a day starts.
    ///
    /// The bounds are **bare `YYYY-MM-DD` day strings, deliberately not ISO
    /// instants**, because they are used as SQL `timestamp >= ?` predicates
    /// against a TEXT column. Every timestamp this codebase stores begins with
    /// `YYYY-MM-DDT…`, so `"2026-09-04T00:00:05Z" > "2026-09-04"` and
    /// `"2026-09-03T23:59:00Z" < "2026-09-04"` — an exact, index-usable prefix
    /// comparison. A full ISO bound would not be: `"2026-09-04T00:00:00.123Z"`
    /// sorts *below* `"2026-09-04T00:00:00Z"` as text (`.` < `Z`), so a
    /// fractional-second record in the window's opening second would be
    /// silently dropped.
    struct Window: Sendable, Equatable {
        /// First day included in the output, `YYYY-MM-DD` UTC.
        let startDay: String
        /// Last day included (today, UTC).
        let endDay: String
        /// `seedLookbackDays` before `startDay` — the cutoff for *reading* the
        /// source series, so the first in-window delta has a predecessor. Rows
        /// between `seedDay` and `startDay` seed the delta pass and are never
        /// themselves emitted.
        let seedDay: String

        init(days: Int, now: Date) {
            let endOfDay = QuotaCalibration.utcDayStart(now)
            let start = endOfDay.addingTimeInterval(-Double(days - 1) * 86400)
            startDay = QuotaCalibration.utcDayString(start)
            endDay = QuotaCalibration.utcDayString(endOfDay)
            seedDay = QuotaCalibration.utcDayString(
                start.addingTimeInterval(-Double(QuotaCalibration.seedLookbackDays) * 86400))
        }
    }

    struct ComputedSeries: Sendable {
        var rows: [DailyRow] = []
        var unknownModels: Set<String> = []
    }

    /// Reads the source series and derives every calibration row for `window`.
    /// Separated from `recompute` so `SelfTest` can assert the arithmetic
    /// without inspecting the table it is written to.
    static func computeRows(
        db: Connection,
        window: Window,
        minPointsForRatio: Double = defaultMinPointsForRatio,
        weights: CostWeights = currentWeights,
        now: Date = Date()
    ) throws -> ComputedSeries {
        let points = try dailyPoints(db: db, window: window)
        let tokens = try dailyTokens(db: db, window: window, weights: weights)
        let computedAt = isoString(now)

        var series = ComputedSeries()
        series.unknownModels = tokens.unknownModels

        // Every day that either source has something to say about, plus every
        // day in between — a day with no data at all is simply absent, which is
        // how a consumer tells "nothing happened" from "0 tokens per point".
        let days = Set(points.byDay.keys).union(tokens.pool.keys).sorted()

        for day in days where day >= window.startDay && day <= window.endDay {
            let dayPoints = points.byDay[day] ?? DayPoints()

            // --- Pool row -------------------------------------------------
            let poolTokens = tokens.pool[day]
            series.rows.append(makeRow(
                day: day, scope: .pool, accountId: nil,
                pointsConsumed: dayPoints.total,
                accountsReporting: max(dayPoints.reportingAccounts.count, 0),
                tokens: poolTokens,
                minPointsForRatio: minPointsForRatio,
                weights: weights, computedAt: computedAt))

            // --- Per-account rows ----------------------------------------
            //
            // Points are genuinely per-account (they come from that account's
            // own `usage_history`), so an account row is written for every
            // account that reported. Token attribution is a different matter:
            // it is written **only** when an explicit session→account mapping
            // exists (`token_sessions.override_account_id`, or a subagent
            // transcript's parent session's). The last-polled-account
            // inference the deleted native host used — and which #197
            // deliberately leaves NULL in `inferred_account_id` — is never
            // consulted, because across ~20 staggered accounts it is close to
            // uniform noise and a plausible-looking wrong attribution is worse
            // than an honest NULL.
            for accountId in dayPoints.reportingAccounts.sorted() {
                series.rows.append(makeRow(
                    day: day, scope: .account, accountId: accountId,
                    pointsConsumed: dayPoints.perAccount[accountId] ?? 0,
                    accountsReporting: 1,
                    tokens: tokens.byAccount[day]?[accountId],
                    minPointsForRatio: minPointsForRatio,
                    weights: weights, computedAt: computedAt))
            }
        }

        return series
    }

    private static func makeRow(
        day: String,
        scope: Scope,
        accountId: String?,
        pointsConsumed: Double,
        accountsReporting: Int,
        tokens: TokenAggregate?,
        minPointsForRatio: Double,
        weights: CostWeights,
        computedAt: String
    ) -> DailyRow {
        let divisor = max(accountsReporting, 1)

        // A zero-token aggregate means "this day has no transcript coverage",
        // which is unknown — not "this day cost nothing". Collapsing it to nil
        // here is what keeps every downstream column absent rather than zero.
        let aggregate = (tokens?.isEmpty == false) ? tokens : nil
        let costEquivalent = aggregate.map { weights.costEquivalentTokens(usd: $0.costUSD) }

        // Ratios additionally require a denominator worth dividing by.
        let usable = (aggregate != nil && pointsConsumed >= minPointsForRatio)

        return DailyRow(
            day: day, scope: scope, accountId: accountId,
            pointsConsumed: pointsConsumed,
            accountsReporting: accountsReporting,
            pointsPerAccount: pointsConsumed / Double(divisor),
            tokens: aggregate?.totals,
            costUSD: aggregate?.costUSD,
            costEquivalentTokens: costEquivalent,
            rawTokensPerPoint: usable ? Double(aggregate!.totals.raw) / pointsConsumed : nil,
            costEquivalentTokensPerPoint: usable ? costEquivalent! / pointsConsumed : nil,
            costUSDPerPoint: usable ? aggregate!.costUSD / pointsConsumed : nil,
            weightsVersion: weights.version,
            computedAt: computedAt
        )
    }

    // MARK: - Points series

    struct DayPoints: Sendable {
        /// Pool total for the day.
        var total: Double = 0
        /// Positive-delta sum per account.
        var perAccount: [String: Double] = [:]
        /// Every account that produced a reading this day, whether or not it
        /// consumed anything.
        var reportingAccounts: Set<String> = []
    }

    struct PointsSeries: Sendable {
        var byDay: [String: DayPoints] = [:]
    }

    /// One `usage_history` sample, reduced to what the delta pass needs.
    private struct Sample {
        let rowid: Int64
        let at: Date
        let percent: Double
    }

    /// Sums positive `weekly_all_percent` deltas per (UTC day, account).
    ///
    /// The delta between two samples is attributed to the day of the **later**
    /// sample, so a poll at 00:04Z that first observes spend from 23:58Z the
    /// night before lands on the new day. That is the only choice that keeps
    /// each day's figure derivable from that day's own rows plus one
    /// predecessor, which is what makes the trailing-window recompute stable.
    static func dailyPoints(db: Connection, window: Window) throws -> PointsSeries {
        var series = PointsSeries()
        guard !tableColumns(db, "usage_history").isEmpty else { return series }

        // Synthetic rows are deliberately included — see the type comment.
        // The account filter keeps OpenAI's unrelated weekly percentage out of
        // an Anthropic-quota series; a `usage_history` row with no surviving
        // account row is treated as Anthropic (`AccountProvider.fallback`).
        // A database old enough to have no `provider` column at all predates
        // multi-provider support entirely, so every row there *is* Anthropic
        // and the filter degrades to a no-op rather than throwing.
        let accountColumns = tableColumns(db, "accounts")
        let providerFilter = accountColumns.contains("provider")
            ? "COALESCE(a.provider, '\(AccountProvider.fallback.rawValue)') "
                + "= '\(AccountProvider.anthropic.rawValue)'"
            : "1"
        let sql = """
            SELECT u.account_id, u.id, u.timestamp, u.weekly_all_percent
            FROM usage_history u
            LEFT JOIN accounts a ON a.id = u.account_id
            WHERE u.weekly_all_percent IS NOT NULL
              AND u.timestamp >= ?
              AND \(providerFilter)
            ORDER BY u.account_id, u.timestamp, u.id
        """
        var byAccount: [String: [Sample]] = [:]
        let stmt = try db.prepare(sql)
        for row in stmt.bind(window.seedDay) {
            guard let accountId = row[0] as? String,
                  let rowid = row[1] as? Int64,
                  let timestamp = row[2] as? String,
                  let at = UsageRecord.parseISO(timestamp) else { continue }
            let percent: Double
            if let value = row[3] as? Double { percent = value }
            else if let value = row[3] as? Int64 { percent = Double(value) }
            else { continue }
            byAccount[accountId, default: []].append(
                Sample(rowid: rowid, at: at, percent: percent))
        }

        for (accountId, rows) in byAccount {
            // Re-sorted in Swift on the *parsed* instant rather than trusting
            // SQL's text ordering: this codebase writes ISO 8601 both with and
            // without fractional seconds, and `…:09.500Z` sorts *before*
            // `…:09Z` as text (because "." < "Z") while being a later instant.
            // The `rowid` tiebreak is the load-bearing half — see the ordering
            // note in the type comment.
            let ordered = rows.sorted {
                $0.at == $1.at ? $0.rowid < $1.rowid : $0.at < $1.at
            }
            var previous: Sample?
            for sample in ordered {
                defer { previous = sample }
                let day = utcDayString(sample.at)
                guard day >= window.startDay else { continue }
                // Any sample inside the window means this account reported
                // that day, even if it consumed nothing.
                series.byDay[day, default: DayPoints()].reportingAccounts.insert(accountId)
                guard let last = previous else { continue }
                let delta = sample.percent - last.percent
                // Negative deltas are resets (or a provider correction) and are
                // discarded; the synthetic carry-forward row is what makes the
                // reset exactly one negative delta instead of a lost increment.
                guard delta > 0 else { continue }
                series.byDay[day, default: DayPoints()].total += delta
                series.byDay[day, default: DayPoints()].perAccount[accountId, default: 0] += delta
            }
        }
        return series
    }

    // MARK: - Token series

    struct TokenSeries: Sendable {
        /// Pool totals + cost per UTC day.
        var pool: [String: TokenAggregate] = [:]
        /// `day → accountId → aggregate`, populated only for sessions carrying
        /// an explicit mapping.
        var byAccount: [String: [String: TokenAggregate]] = [:]
        var unknownModels: Set<String> = []
    }

    /// Sums `token_usage` per UTC day, pool-wide and (where an explicit
    /// mapping exists) per account.
    ///
    /// The attribution join is `COALESCE(session.override_account_id,
    /// parent.override_account_id)`: `token_sessions` is keyed per transcript
    /// *file*, so a subagent transcript's own row has no mapping of its own and
    /// inherits the one on the session it belongs to — which is precisely what
    /// #197's `parent_session_id` column was added to make possible.
    /// `inferred_account_id` is never read (see `computeRows`).
    static func dailyTokens(
        db: Connection,
        window: Window,
        weights: CostWeights = currentWeights
    ) throws -> TokenSeries {
        var series = TokenSeries()
        guard !tableColumns(db, "token_usage").isEmpty else { return series }

        let hasParent = tableColumns(db, "token_sessions").contains("parent_session_id")
        let mapping = hasParent
            ? "COALESCE(s.override_account_id, p.override_account_id)"
            : "s.override_account_id"
        let parentJoin = hasParent
            ? "LEFT JOIN token_sessions p ON p.session_id = s.parent_session_id"
            : ""

        // Grouped in SQL: a fleet host holds ~10^5 `token_usage` rows and the
        // distinct (day, model, account) triples number in the hundreds.
        // `substr(timestamp, 1, 10)` is the UTC day because transcript
        // timestamps are written by Claude Code as ISO 8601 with a `Z` offset
        // and stored verbatim by `TranscriptImporter`; the LIKE guard drops
        // anything that is not that shape rather than mis-bucketing it.
        let sql = """
            SELECT substr(u.timestamp, 1, 10) AS day,
                   COALESCE(u.model, '') AS model,
                   \(mapping) AS mapped_account,
                   SUM(u.input_tokens), SUM(u.output_tokens),
                   SUM(u.cache_creation_tokens), SUM(u.cache_read_tokens)
            FROM token_usage u
            LEFT JOIN token_sessions s ON s.session_id = u.session_id
            \(parentJoin)
            WHERE u.timestamp >= ?
              AND u.timestamp LIKE '____-__-__T%'
            GROUP BY day, model, mapped_account
        """
        let stmt = try db.prepare(sql)
        for row in stmt.bind(window.startDay) {
            guard let day = row[0] as? String, day >= window.startDay, day <= window.endDay
            else { continue }
            let model = (row[1] as? String) ?? ""
            let account = (row[2] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let totals = TokenTotals(
                input: intValue(row[3]), output: intValue(row[4]),
                cacheCreation: intValue(row[5]), cacheRead: intValue(row[6]))
            guard !totals.isEmpty else { continue }

            let resolved = weights.price(for: model)
            if !resolved.recognized && !model.isEmpty {
                series.unknownModels.insert(model)
            }
            // Priced here, while the model is still known — see
            // `TokenAggregate`.
            let aggregate = TokenAggregate(
                totals: totals,
                costUSD: resolved.price.costUSD(
                    input: totals.input, output: totals.output,
                    cacheCreation: totals.cacheCreation, cacheRead: totals.cacheRead))

            series.pool[day, default: TokenAggregate()] += aggregate
            if let account = account {
                series.byAccount[day, default: [:]][account, default: TokenAggregate()] += aggregate
            }
        }
        return series
    }

    // MARK: - Reading back

    /// Reads the stored series back, newest day last. `scope` filters to pool
    /// rows, account rows, or both.
    static func loadSeries(
        dbPath: String = defaultDBPath,
        days: Int = defaultWindowDays,
        scope: Scope? = nil,
        now: Date = Date()
    ) throws -> [DailyRow] {
        guard FileManager.default.fileExists(atPath: dbPath) else {
            throw CalibrationError.databaseMissing(redactPath(dbPath))
        }
        let db: Connection
        do {
            db = try openDatabase(dbPath, readonly: true)
        } catch {
            throw CalibrationError.database(redactPath("\(error)"))
        }
        guard !tableColumns(db, "quota_calibration_daily").isEmpty else { return [] }
        let window = Window(days: max(1, days), now: now)

        var rows: [DailyRow] = []
        let scopeClause = scope.map { " AND scope = '\($0.rawValue)'" } ?? ""
        let stmt = try db.prepare("""
            SELECT day, scope, account_id, points_consumed, accounts_reporting,
                   points_per_account, input_tokens, output_tokens,
                   cache_creation_tokens, cache_read_tokens,
                   cost_equivalent_tokens, cost_usd, raw_tokens_per_point,
                   cost_equivalent_tokens_per_point, cost_usd_per_point,
                   weights_version, computed_at
            FROM quota_calibration_daily
            WHERE day >= ?\(scopeClause)
            ORDER BY day ASC, scope DESC, account_id ASC
        """)
        for row in stmt.bind(window.startDay) {
            guard let day = row[0] as? String,
                  let scopeValue = (row[1] as? String).flatMap(Scope.init(rawValue:))
            else { continue }
            // A NULL `input_tokens` is the stored form of "no token coverage
            // for this row"; it must read back as nil, not as a zero total.
            let tokens: TokenTotals? = (row[6] as? Int64) == nil ? nil : TokenTotals(
                input: intValue(row[6]), output: intValue(row[7]),
                cacheCreation: intValue(row[8]), cacheRead: intValue(row[9]))
            rows.append(DailyRow(
                day: day, scope: scopeValue, accountId: row[2] as? String,
                pointsConsumed: doubleValue(row[3]) ?? 0,
                accountsReporting: intValue(row[4]),
                pointsPerAccount: doubleValue(row[5]) ?? 0,
                tokens: tokens,
                costUSD: doubleValue(row[11]),
                costEquivalentTokens: doubleValue(row[10]),
                rawTokensPerPoint: doubleValue(row[12]),
                costEquivalentTokensPerPoint: doubleValue(row[13]),
                costUSDPerPoint: doubleValue(row[14]),
                weightsVersion: (row[15] as? String) ?? "",
                computedAt: (row[16] as? String) ?? ""))
        }
        return rows
    }

    // MARK: - Export

    /// Schema of the exported document. Stays **1** while fields are added —
    /// same contract as `ranking.json`: a version bump means a *breaking*
    /// change, and an absent key means **unknown**, never zero.
    static let exportSchemaVersion = 1

    /// JSON document for `claude-monitor calibrate --format json`.
    ///
    /// Every optional ratio is **omitted** rather than emitted as `null` when
    /// unknown, so a consumer that reaches for a missing key gets nothing
    /// rather than a plausible-looking zero.
    static func jsonPayload(
        rows: [DailyRow],
        windowDays: Int,
        minPointsForRatio: Double,
        weights: CostWeights = currentWeights,
        now: Date = Date()
    ) -> [String: Any] {
        let today = utcDayString(now)
        var dayObjects: [[String: Any]] = []
        for row in rows {
            var obj: [String: Any] = [
                "day": row.day,
                "scope": row.scope.rawValue,
                "points_consumed": rounded(row.pointsConsumed, 4),
                "accounts_reporting": row.accountsReporting,
                "points_per_account": rounded(row.pointsPerAccount, 4),
                "weights_version": row.weightsVersion,
            ]
            if let accountId = row.accountId { obj["account_id"] = accountId }
            // The current UTC day is only partially observed; a consumer
            // comparing it against completed days would otherwise see a step
            // change every morning.
            if row.day == today { obj["partial"] = true }
            if let tokens = row.tokens {
                obj["input_tokens"] = tokens.input
                obj["output_tokens"] = tokens.output
                obj["cache_creation_tokens"] = tokens.cacheCreation
                obj["cache_read_tokens"] = tokens.cacheRead
                obj["raw_tokens"] = tokens.raw
            }
            if let value = row.costEquivalentTokens { obj["cost_equivalent_tokens"] = rounded(value, 2) }
            if let value = row.costUSD { obj["cost_usd"] = rounded(value, 6) }
            if let value = row.rawTokensPerPoint { obj["raw_tokens_per_point"] = rounded(value, 2) }
            if let value = row.costEquivalentTokensPerPoint {
                obj["cost_equivalent_tokens_per_point"] = rounded(value, 2)
            }
            if let value = row.costUSDPerPoint { obj["cost_usd_per_point"] = rounded(value, 6) }
            dayObjects.append(obj)
        }

        return [
            "schema": exportSchemaVersion,
            "generated_at": isoString(now),
            "window_days": windowDays,
            "min_points_for_ratio": minPointsForRatio,
            "weights_version": weights.version,
            "weights_source": weights.source,
            "cost_equivalent_token_baseline": weights.baselineLabel,
            "rows": dayObjects,
        ]
    }

    static func jsonString(
        rows: [DailyRow],
        windowDays: Int,
        minPointsForRatio: Double,
        weights: CostWeights = currentWeights,
        now: Date = Date()
    ) throws -> String {
        let payload = jsonPayload(rows: rows, windowDays: windowDays,
                                  minPointsForRatio: minPointsForRatio,
                                  weights: weights, now: now)
        let data = try JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    /// Column order of the CSV export. Declared once so the header and every
    /// row are generated from the same list and cannot drift apart.
    static let csvColumns = [
        "day", "scope", "account_id", "partial", "points_consumed",
        "accounts_reporting", "points_per_account", "input_tokens",
        "output_tokens", "cache_creation_tokens", "cache_read_tokens",
        "raw_tokens", "cost_equivalent_tokens", "cost_usd",
        "raw_tokens_per_point", "cost_equivalent_tokens_per_point",
        "cost_usd_per_point", "weights_version",
    ]

    /// CSV for `claude-monitor calibrate --format csv`. An unknown value is an
    /// **empty field**, never `0` — the CSV analogue of an omitted JSON key.
    static func csv(rows: [DailyRow], now: Date = Date()) -> String {
        let today = utcDayString(now)
        var lines = [csvColumns.joined(separator: ",")]
        for row in rows {
            let fields: [String] = [
                row.day,
                row.scope.rawValue,
                row.accountId ?? "",
                row.day == today ? "true" : "false",
                format(row.pointsConsumed, 4),
                String(row.accountsReporting),
                format(row.pointsPerAccount, 4),
                row.tokens.map { String($0.input) } ?? "",
                row.tokens.map { String($0.output) } ?? "",
                row.tokens.map { String($0.cacheCreation) } ?? "",
                row.tokens.map { String($0.cacheRead) } ?? "",
                row.tokens.map { String($0.raw) } ?? "",
                row.costEquivalentTokens.map { format($0, 2) } ?? "",
                row.costUSD.map { format($0, 6) } ?? "",
                row.rawTokensPerPoint.map { format($0, 2) } ?? "",
                row.costEquivalentTokensPerPoint.map { format($0, 2) } ?? "",
                row.costUSDPerPoint.map { format($0, 6) } ?? "",
                row.weightsVersion,
            ]
            lines.append(fields.map(csvEscape).joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Account ids are opaque identifiers, but they are not guaranteed
    /// comma-free, and a weights version is free text — quote anything that
    /// could break the row structure.
    private static func csvEscape(_ field: String) -> String {
        guard field.contains(",") || field.contains("\"") || field.contains("\n") else {
            return field
        }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    // MARK: - Step-change alerts (#199, phase 3 of #196)

    /// One pool-wide quota-calibration step-change alert: the day
    /// `rawTokensPerPoint`'s `recentWindowDays`-trailing average fell to at or
    /// below `1 / threshold` of its trailing baseline median — evidence the
    /// pool's quota *accounting* shifted (fewer tokens buying the same weekly
    /// point), not that workload moved. See `evaluateStepChangeAlerts` for the
    /// full rule.
    struct StepChangeAlert: Sendable, Equatable {
        /// UTC day the alert fired on (the last day of the "recent" window).
        let day: String
        /// `recentWindowDays`-trailing average of `rawTokensPerPoint` ending on `day`.
        let recentTokensPerPoint: Double
        /// Median `rawTokensPerPoint` over the `baselineWindowDays` immediately
        /// preceding the recent window (non-overlapping with it).
        let baselineTokensPerPoint: Double
        /// `recentTokensPerPoint / baselineTokensPerPoint`. Always `<= 1 /
        /// threshold` for an emitted alert — the rule is direction-aware, see below.
        let ratio: Double
    }

    /// Evaluates a pool-scope `rawTokensPerPoint` series for step-change
    /// alerts (#199).
    ///
    /// **The rule, and why it needs to be more than "1.5x the trailing
    /// median"**: #196's motivating incident was a *drop* in tokens-per-point
    /// (the pool started burning weekly-limit points faster for the same
    /// token spend) that **partially reverted** ten days later. A naive
    /// symmetric "moved more than 1.5x" rule fires correctly on the initial
    /// step but fires *again* on the recovery — which is backwards, since the
    /// recovery is the pool getting healthier, not worse. Two properties fix
    /// that, and both are required (either alone reproduces the bug against
    /// the reference series below):
    ///
    /// 1. **Direction-aware.** Only a *decrease* past the threshold
    ///    (`ratio <= 1 / threshold`) is ever an alert. An *increase* (quota
    ///    accounting got more generous, or a depressed regime is recovering)
    ///    never alerts, no matter how large — there is nothing to warn about.
    /// 2. **Edge-triggered with a latch ("hysteretic" per #199's ask), not
    ///    level-triggered.** An alert fires only the first day the ratio
    ///    crosses at/below `1 / threshold` (`armed → disarmed`); it does not
    ///    repeat on every subsequent day the ratio stays depressed, and it can
    ///    only fire again after the ratio actually recovers back above
    ///    `1 / threshold` (`disarmed → armed`) and later drops a second time.
    ///    Re-arming this way — an actual recovery, not a fixed cooldown —
    ///    is what lets a hovering-near-the-line ratio neither spam nor
    ///    silently miss a later, second drop.
    ///
    /// The baseline for day `i` is the median of the `baselineWindowDays` days
    /// immediately **preceding** the `recentWindowDays`-day recent window
    /// (non-overlapping with it, so a step doesn't dilute the very baseline it
    /// is compared against). A day is only evaluated once at least
    /// `minBaselineDays` of that baseline is available — the earliest days of
    /// a freshly-populated table cannot see a full baseline, and a median over
    /// a handful of points is not evidence of anything.
    ///
    /// Verified against #198's reference series
    /// (`SelfTest.calibrationReferenceSeries`, a live 20-account host,
    /// 2026-08-24…09-17, under the assumption stated in #196's incident
    /// report that the account-side token workload was flat across it, which
    /// makes `rawTokensPerPoint` move inversely with the reported
    /// points-per-account): the 09-05/09-06 step (points/account/day ~15→35)
    /// produces exactly **one** alert, on 2026-09-06, and the partial
    /// reversion starting 2026-09-10 — an *increase* back toward baseline —
    /// never re-triggers it (`SelfTest`'s calibration alert tests pin this).
    ///
    /// - Parameters:
    ///   - poolRows: `DailyRow`s to evaluate; only `scope == .pool` rows are
    ///     used (account-scope rows are ignored — a single account's ratio is
    ///     far noisier than the pool's), in any order (sorted here by `day`).
    ///   - recentWindowDays: length of the "now" window (default 3, #199's ask).
    ///   - baselineWindowDays: length of the trailing baseline window (default 14).
    ///   - minBaselineDays: minimum populated baseline days required before a
    ///     day is evaluated at all (default 7, half of `baselineWindowDays`).
    ///   - threshold: the alert threshold (default 1.5, #199's ask).
    static func evaluateStepChangeAlerts(
        poolRows: [DailyRow],
        recentWindowDays: Int = 3,
        baselineWindowDays: Int = 14,
        minBaselineDays: Int = 7,
        threshold: Double = 1.5
    ) -> [StepChangeAlert] {
        guard threshold > 0, recentWindowDays > 0, baselineWindowDays > 0 else { return [] }

        let values: [(day: String, value: Double)] = poolRows
            .filter { $0.scope == .pool }
            .sorted { $0.day < $1.day }
            .compactMap { row in row.rawTokensPerPoint.map { (row.day, $0) } }

        guard values.count >= recentWindowDays else { return [] }
        let disarmRatio = 1.0 / threshold

        var alerts: [StepChangeAlert] = []
        var armed = true

        for i in (recentWindowDays - 1)..<values.count {
            let recentSlice = values[(i - recentWindowDays + 1)...i]
            let recent = recentSlice.reduce(0.0) { $0 + $1.value } / Double(recentWindowDays)

            // The baseline window ends the day before the recent window
            // starts — deliberately non-overlapping (see the doc comment).
            let baselineEndExclusive = i - recentWindowDays + 1
            let baselineStart = max(0, baselineEndExclusive - baselineWindowDays)
            guard baselineEndExclusive - baselineStart >= minBaselineDays else { continue }
            let baseline = median(values[baselineStart..<baselineEndExclusive].map(\.value))
            guard baseline > 0 else { continue }

            let ratio = recent / baseline
            if ratio <= disarmRatio {
                if armed {
                    alerts.append(StepChangeAlert(
                        day: values[i].day, recentTokensPerPoint: recent,
                        baselineTokensPerPoint: baseline, ratio: ratio))
                    armed = false
                }
            } else {
                armed = true
            }
        }
        return alerts
    }

    /// The median of `values`. `values` must be non-empty (every call site
    /// guards a minimum count first).
    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let count = sorted.count
        if count % 2 == 1 { return sorted[count / 2] }
        return (sorted[count / 2 - 1] + sorted[count / 2]) / 2
    }

    // MARK: - Helpers

    /// Midnight UTC of the day containing `date`.
    static func utcDayStart(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 86400).rounded(.down) * 86400)
    }

    /// Parses a `YYYY-MM-DD` UTC day string (as produced by `utcDayString`)
    /// back into midnight UTC of that day. `nil` for anything not in that
    /// exact shape.
    static func parseUTCDay(_ day: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: day)
    }

    /// `YYYY-MM-DD` in UTC. Pinned to `en_US_POSIX` and GMT rather than left to
    /// the ambient locale/calendar: the day boundary here is a wire contract
    /// (it must equal `substr(token_usage.timestamp, 1, 10)`), not a display
    /// choice, and a non-Gregorian device calendar would otherwise silently
    /// rekey the whole series.
    static func utcDayString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// ISO 8601, whole seconds, UTC — the shape `usage_history.timestamp`
    /// already holds, so a string comparison against it in SQL is valid.
    static func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    private static func intValue(_ value: Any?) -> Int {
        if let v = value as? Int64 { return Int(v) }
        if let v = value as? Double { return Int(v) }
        if let v = value as? Int { return v }
        return 0
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let v = value as? Double { return v }
        if let v = value as? Int64 { return Double(v) }
        return nil
    }

    private static func rounded(_ value: Double, _ places: Int) -> Double {
        let scale = pow(10.0, Double(places))
        return (value * scale).rounded() / scale
    }

    private static func format(_ value: Double, _ places: Int) -> String {
        String(format: "%.\(places)f", rounded(value, places))
    }

    /// Collapses the user's home directory to `~`. Error strings from here are
    /// logged, and a database path names a user — same rule as
    /// `TranscriptImporter.redactPath`.
    static func redactPath(_ path: String) -> String {
        TranscriptImporter.redactPath(path)
    }
}
