#if os(macOS)
import SwiftUI

/// Severity band for a percent-used value (e.g. session/weekly rate-limit
/// usage). Centralizes the >95 / >=90 boundaries so the popover table, chart
/// window, and menu-bar icon can't drift out of sync — most call sites share
/// `color` below; the menu-bar icon renderer (`main.swift`) still maps the
/// `.normal` case to its own light/dark-aware `NSColor` instead, since that
/// default isn't shared with the SwiftUI call sites.
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

    /// Shared SwiftUI color mapping used by the popover table and chart window.
    var color: Color {
        switch self {
        case .critical: return Color(nsColor: .systemRed)
        case .warning: return Color(nsColor: .systemOrange)
        case .normal: return .primary
        }
    }
}

#endif
