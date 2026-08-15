#if os(macOS)

/// Severity band for a percent-used value (e.g. session/weekly rate-limit
/// usage). Centralizes the >95 / >=90 boundaries so the popover table, chart
/// window, and menu-bar icon can't drift out of sync — each call site maps
/// the band to its own color type (SwiftUI `Color` vs. `NSColor`) and keeps
/// its own default color for `.normal`.
enum PercentSeverity {
    case critical
    case warning
    case normal

    init(percent: Double) {
        if percent > 95 {
            self = .critical
        } else if percent >= 90 {
            self = .warning
        } else {
            self = .normal
        }
    }
}

#endif
