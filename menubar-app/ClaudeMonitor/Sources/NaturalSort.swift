import Foundation

/// Hybrid lexical/numeric ("natural") ordering for account names.
///
/// A plain string compare puts `agent-10` between `agent-1` and `agent-2`,
/// because `'1' < '2'` character-wise. Natural ordering splits each name into
/// alternating text and digit runs — `agent-10` becomes `[text("agent-"),
/// number("10")]` — and compares run-by-run, so digit runs compare by value
/// and `agent-9` sorts before `agent-10`.
///
/// Lives in the portable core (Foundation only, no AppKit/SwiftUI) so the
/// headless Linux build compiles it too.
enum NaturalSort {

    /// One run of a name: either a maximal digit run or a maximal non-digit run.
    enum Token: Equatable {
        case text(String)
        /// The raw digit run, leading zeros preserved so ordering stays
        /// deterministic between `007` and `7`.
        case number(String)
    }

    /// Splits a string into alternating text/number runs.
    ///
    /// Only ASCII digits start a number run. Digits in other scripts stay in
    /// text runs rather than being half-parsed — an account name is not a place
    /// to guess at numeral systems.
    static func tokenize(_ string: String) -> [Token] {
        var tokens: [Token] = []
        var current = ""
        var currentIsDigits = false

        for character in string {
            let isDigit = character.isASCII && character.isNumber
            if current.isEmpty {
                current.append(character)
                currentIsDigits = isDigit
                continue
            }
            if isDigit == currentIsDigits {
                current.append(character)
            } else {
                tokens.append(currentIsDigits ? .number(current) : .text(current))
                current = String(character)
                currentIsDigits = isDigit
            }
        }
        if !current.isEmpty {
            tokens.append(currentIsDigits ? .number(current) : .text(current))
        }
        return tokens
    }

    /// Compares two digit runs by value without parsing to an integer, so a
    /// pathologically long run (or one past `Int.max`) can't overflow or
    /// silently collapse to a fallback.
    ///
    /// Leading zeros carry no value: significant-digit count decides first,
    /// then a plain lexical compare of the stripped digits.
    static func compareDigitRuns(_ a: String, _ b: String) -> ComparisonResult {
        let strippedA = Substring(a).drop(while: { $0 == "0" })
        let strippedB = Substring(b).drop(while: { $0 == "0" })

        if strippedA.count != strippedB.count {
            return strippedA.count < strippedB.count ? .orderedAscending : .orderedDescending
        }
        if strippedA != strippedB {
            return strippedA < strippedB ? .orderedAscending : .orderedDescending
        }
        return .orderedSame   // equal in value; leading-zero tie broken by the caller
    }

    /// Natural-order comparison of two display names.
    ///
    /// Text runs use `localizedCaseInsensitiveCompare`, preserving the casing
    /// and locale behaviour of the plain string compare this replaced. Returns
    /// `.orderedSame` only for strings that are genuinely indistinguishable, so
    /// callers can apply their own stable tiebreak.
    static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let tokensA = tokenize(a)
        let tokensB = tokenize(b)

        for (tokenA, tokenB) in zip(tokensA, tokensB) {
            switch (tokenA, tokenB) {
            case let (.number(x), .number(y)):
                let result = compareDigitRuns(x, y)
                if result != .orderedSame { return result }
            case let (.text(x), .text(y)):
                let result = x.localizedCaseInsensitiveCompare(y)
                if result != .orderedSame { return result }
            case (.number, .text):
                return .orderedAscending    // digits before letters at the same position
            case (.text, .number):
                return .orderedDescending
            }
        }

        // One name is a prefix of the other under natural rules: shorter first.
        if tokensA.count != tokensB.count {
            return tokensA.count < tokensB.count ? .orderedAscending : .orderedDescending
        }

        // Equal run-for-run — differing only by leading zeros or letter case.
        // Fall back to an exact compare so the order is total and stable.
        return a.compare(b)
    }

    /// Self-checks for the ordering rules above.
    ///
    /// Returns the number of assertions run alongside any failure descriptions,
    /// so the caller's total check count stays honest. Kept self-contained
    /// rather than using `SelfTest`'s private helpers so this file carries its
    /// own verification; `SelfTest` calls it.
    static func selfCheck() -> (checks: Int, failures: [String]) {
        var failures: [String] = []
        var checks = 0

        func expectOrder(_ ordered: [String], _ label: String) {
            checks += 1
            // Feed the comparator the reverse of the expected order, so a
            // comparator that ignored its arguments entirely would fail.
            let sorted = ordered.reversed().sorted { compare($0, $1) == .orderedAscending }
            if sorted != ordered {
                failures.append("\(label): expected \(ordered), got \(sorted)")
            }
        }

        func expectSame(_ a: String, _ b: String, _ label: String) {
            checks += 1
            if compare(a, b) != .orderedSame {
                failures.append("\(label): expected '\(a)' == '\(b)'")
            }
        }

        // The case that prompted this: agent-10 must follow agent-9, and the
        // two-digit run must not sort between the two one-digit runs.
        expectOrder(
            ["agent-1", "agent-2", "agent-9", "agent-10", "agent-11", "agent-100"],
            "agent numbering"
        )

        // Digit runs compare by value, not width.
        expectOrder(["a2", "a10"], "value not width")
        // Leading zeros carry no value, but still give a deterministic order.
        expectOrder(["a007", "a7z"], "leading zeros then differing suffix")
        expectSame("a7", "a7", "identical")

        // Multiple numeric segments compare left to right.
        expectOrder(["v1.9.0", "v1.10.0", "v2.1.0"], "multi-segment versions")

        // Pure text keeps its old case-insensitive ordering.
        expectOrder(["alpha", "Beta", "gamma"], "case-insensitive text")

        // A name that is a prefix of another sorts first.
        expectOrder(["agent", "agent-1"], "prefix first")

        // Realistic mixed account names, including emails.
        expectOrder(
            ["agent-2@2amlogic.com", "agent-10@2amlogic.com", "robb@2amlogic.com"],
            "email account names"
        )

        // Degenerate inputs must not crash or mis-order.
        expectOrder(["", "0", "1", "a"], "empty and single characters")

        // A digit run far past Int.max must still compare by value, not
        // overflow or fall back to string order.
        let huge = String(repeating: "9", count: 40)
        let hugePlus = String(repeating: "9", count: 41)
        expectOrder(["x\(huge)", "x\(hugePlus)"], "digit run beyond Int.max")

        return (checks, failures)
    }
}
