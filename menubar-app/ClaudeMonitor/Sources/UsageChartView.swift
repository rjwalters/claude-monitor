import SwiftUI
import Charts

struct UsageChartWindow: View {
    let account: Account
    let dataPoints: [UsageDataPoint]
    let fullDataPoints: [FullUsageDataPoint]
    let store: UsageStore
    @Environment(\.colorScheme) var colorScheme
    @State private var isEditingName = false
    @State private var editedName = ""
    @State private var isNameHovering = false
    @State private var showClearConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    if isEditingName {
                        HStack(spacing: 8) {
                            TextField("Account name", text: $editedName)
                                .textFieldStyle(.plain)
                                .font(.title2)
                                .fontWeight(.semibold)
                                .onSubmit { saveNameEdit() }
                                .onExitCommand { isEditingName = false }

                            Button(action: saveNameEdit) {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.green)
                            }
                            .buttonStyle(.plain)

                            Button(action: { isEditingName = false }) {
                                Image(systemName: "xmark")
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    } else {
                        HStack(spacing: 6) {
                            if isNameHovering {
                                Button(action: {
                                    editedName = account.accountName ?? account.displayName
                                    isEditingName = true
                                }) {
                                    Image(systemName: "pencil")
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                            Text(account.displayName)
                                .font(.title2)
                                .fontWeight(.semibold)
                        }
                        .onHover { hovering in
                            isNameHovering = hovering
                        }
                    }
                    if let plan = account.plan {
                        Text(plan)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
                Spacer()
                // Show session and weekly percentages with labels
                VStack(alignment: .trailing, spacing: 4) {
                    if let sessionPercent = latestSessionPercent {
                        HStack(spacing: 4) {
                            Text("Session")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text("\(Int(sessionPercent))%")
                                .font(.title2)
                                .fontWeight(.bold)
                                .foregroundColor(colorForPercent(sessionPercent))
                        }
                    }
                    if let weeklyPercent = latestWeeklyPercent {
                        HStack(spacing: 4) {
                            Text("Weekly")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text("\(Int(weeklyPercent))%")
                                .font(.title2)
                                .fontWeight(.bold)
                                .foregroundColor(colorForPercent(weeklyPercent))
                        }
                    }
                }
            }
            .padding(.bottom, 8)

            if dataPoints.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .font(.largeTitle)
                        .foregroundColor(.secondary)
                    Text("No usage history yet")
                        .font(.headline)
                    Text("Visit claude.ai/settings/usage periodically\nto build up history data")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Weekly Usage chart with points
                VStack(alignment: .leading, spacing: 8) {
                    Text("Weekly Usage")
                        .font(.headline)

                    Chart(dataPoints) { point in
                        LineMark(
                            x: .value("Time", point.timestamp),
                            y: .value("Usage %", point.weeklyPercent)
                        )
                        .foregroundStyle(Color.blue.gradient)

                        AreaMark(
                            x: .value("Time", point.timestamp),
                            y: .value("Usage %", point.weeklyPercent)
                        )
                        .foregroundStyle(Color.blue.opacity(0.1).gradient)

                        PointMark(
                            x: .value("Time", point.timestamp),
                            y: .value("Usage %", point.weeklyPercent)
                        )
                        .foregroundStyle(Color.blue)
                        .symbolSize(30)
                    }
                    .chartYScale(domain: 0...100)
                    .chartYAxis {
                        AxisMarks(position: .leading, values: [0, 25, 50, 75, 100]) { value in
                            AxisGridLine()
                            AxisValueLabel {
                                if let percent = value.as(Int.self) {
                                    Text("\(percent)%")
                                        .font(.caption)
                                }
                            }
                        }
                    }
                    .chartXAxis {
                        AxisMarks(values: .automatic) { value in
                            AxisGridLine()
                            AxisValueLabel {
                                if let date = value.as(Date.self) {
                                    Text(formatTime(date))
                                        .font(.caption)
                                }
                            }
                        }
                    }
                    .frame(height: 280)
                }

                Spacer()

                // Usage consumed stats
                HStack(spacing: 0) {
                    let (title1, value1) = usageConsumedWithLabel(targetMinutes: 30)
                    let (title2, value2) = usageConsumedWithLabel(targetMinutes: 120)
                    let (title3, value3) = usageConsumedWithLabel(targetMinutes: 1440)

                    UsageConsumedBox(title: title1, value: value1)
                    Spacer()
                    UsageConsumedBox(title: title2, value: value2)
                    Spacer()
                    UsageConsumedBox(title: title3, value: value3)
                }

                // Time until credits run out estimate
                if let estimate = timeUntilCreditsRunOut() {
                    HStack {
                        Spacer()
                        Text(estimate)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                    .padding(.top, 8)
                }

                // Clear data button
                HStack {
                    Spacer()
                    Button(action: {
                        showClearConfirmation = true
                    }) {
                        Text("Clear History")
                            .foregroundColor(.red)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 12)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 56)
        .padding(.bottom, 40)
        .frame(width: 620, height: 600)
        .background(Color(nsColor: .windowBackgroundColor))
        .alert("Clear History?", isPresented: $showClearConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Clear", role: .destructive) {
                store.clearAccountData(accountId: account.id)
                // Close this window
                if let window = ChartWindowController.windows[account.id] {
                    window.close()
                    ChartWindowController.windows.removeValue(forKey: account.id)
                }
            }
        } message: {
            Text("This will delete all usage history for this account. Visit claude.ai/settings/usage to collect new data.")
        }
    }

    var latestSessionPercent: Double? {
        fullDataPoints.last?.sessionPercent
    }

    var latestWeeklyPercent: Double? {
        fullDataPoints.last?.weeklyAllPercent
    }

    func usageConsumedWithLabel(targetMinutes: Int) -> (String, Double) {
        guard let oldestPoint = dataPoints.first else {
            return (formatDuration(minutes: targetMinutes), 0)
        }

        let now = Date()
        let dataAgeMinutes = Int(now.timeIntervalSince(oldestPoint.timestamp) / 60)

        // Use the smaller of target time or available data range
        let effectiveMinutes = min(targetMinutes, dataAgeMinutes)
        let cutoff = now.addingTimeInterval(-Double(effectiveMinutes) * 60)
        let recentPoints = dataPoints.filter { $0.timestamp >= cutoff }
        let consumed = recentPoints.reduce(0) { $0 + $1.usageDelta }

        // Show actual time window if less than target
        let label = effectiveMinutes < targetMinutes
            ? formatDuration(minutes: effectiveMinutes)
            : formatDuration(minutes: targetMinutes)

        return (label, consumed)
    }

    func formatDuration(minutes: Int) -> String {
        if minutes < 60 {
            return "\(minutes) min"
        } else if minutes < 1440 {
            let hours = minutes / 60
            return "\(hours) hr"
        } else {
            let days = minutes / 1440
            let remainingHours = (minutes % 1440) / 60
            if remainingHours > 0 {
                return "\(days)d \(remainingHours)h"
            }
            return "\(days) day"
        }
    }

    func saveNameEdit() {
        let trimmed = editedName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            store.updateAccountName(accountId: account.id, newName: trimmed)
        }
        isEditingName = false
    }

    /// Linear regression result: slope (percent per minute) and intercept
    struct LinearFit {
        let slope: Double      // percent per minute (positive = increasing usage)
        let intercept: Double  // percent at time 0
        let r2: Double         // R-squared (quality of fit)
    }

    /// Fit a line to usage data points, only considering points in an active usage session
    /// (i.e., where usage is monotonically increasing - stops at any reset/decrease)
    func fitLinearModel(points: [(Date, Double)]) -> LinearFit? {
        guard points.count >= 2 else { return nil }

        // Find the active session: work backwards from most recent,
        // include points where usage is increasing or flat
        var activePoints: [(Date, Double)] = []
        for i in stride(from: points.count - 1, through: 0, by: -1) {
            let point = points[i]
            if activePoints.isEmpty {
                activePoints.insert(point, at: 0)
            } else {
                // Check if this point is part of the same session (usage should be <= next point)
                let nextPercent = activePoints.first!.1
                if point.1 <= nextPercent {
                    activePoints.insert(point, at: 0)
                } else {
                    // Reset detected, stop here
                    break
                }
            }
        }

        guard activePoints.count >= 2 else { return nil }

        // Convert to x (minutes from first point) and y (percent)
        let baseTime = activePoints.first!.0.timeIntervalSince1970
        let xs = activePoints.map { ($0.0.timeIntervalSince1970 - baseTime) / 60.0 }
        let ys = activePoints.map { $0.1 }

        // Calculate linear regression
        let n = Double(xs.count)
        let sumX = xs.reduce(0, +)
        let sumY = ys.reduce(0, +)
        let sumXY = zip(xs, ys).map { $0 * $1 }.reduce(0, +)
        let sumX2 = xs.map { $0 * $0 }.reduce(0, +)

        let denom = n * sumX2 - sumX * sumX
        guard denom != 0 else { return nil }

        let slope = (n * sumXY - sumX * sumY) / denom
        let intercept = (sumY - slope * sumX) / n

        // Calculate R-squared
        let meanY = sumY / n
        let ssTotal = ys.map { pow($0 - meanY, 2) }.reduce(0, +)
        let ssResidual = zip(xs, ys).map { x, y in pow(y - (slope * x + intercept), 2) }.reduce(0, +)
        let r2 = ssTotal > 0 ? 1 - ssResidual / ssTotal : 0

        return LinearFit(slope: slope, intercept: intercept, r2: r2)
    }

    /// Estimate time until a usage metric reaches 100%
    func estimateTimeToLimit(points: [(Date, Double)], limitName: String) -> (minutes: Double, limitType: String)? {
        guard let fit = fitLinearModel(points: points) else { return nil }

        // Need positive slope (increasing usage) to estimate exhaustion
        guard fit.slope > 0.001 else { return nil }  // At least 0.001% per minute

        // Get current percent (last point)
        guard let currentPercent = points.last?.1 else { return nil }

        // Time to reach 100%
        let remaining = 100.0 - currentPercent
        guard remaining > 0 else { return (0, limitName) }

        let minutesToExhaust = remaining / fit.slope
        return (minutesToExhaust, limitName)
    }

    func timeUntilCreditsRunOut() -> String? {
        // Build session and weekly data point arrays
        var sessionPoints: [(Date, Double)] = []
        var weeklyPoints: [(Date, Double)] = []

        for point in fullDataPoints {
            if let session = point.sessionPercent {
                sessionPoints.append((point.timestamp, session))
            }
            if let weekly = point.weeklyAllPercent {
                weeklyPoints.append((point.timestamp, weekly))
            }
        }

        // Estimate time for each limit type
        let sessionEstimate = estimateTimeToLimit(points: sessionPoints, limitName: "session limits")
        let weeklyEstimate = estimateTimeToLimit(points: weeklyPoints, limitName: "weekly limits")

        // Find the shorter time
        var bestEstimate: (minutes: Double, limitType: String)? = nil

        if let session = sessionEstimate {
            if bestEstimate == nil || session.minutes < bestEstimate!.minutes {
                bestEstimate = session
            }
        }
        if let weekly = weeklyEstimate {
            if bestEstimate == nil || weekly.minutes < bestEstimate!.minutes {
                bestEstimate = weekly
            }
        }

        guard let estimate = bestEstimate else { return nil }

        let minutes = estimate.minutes
        let limitType = estimate.limitType

        if minutes <= 0 {
            return "Credits exhausted due to \(limitType)"
        } else if minutes < 60 {
            return "At current rate, access will be limited in ~\(Int(minutes)) min due to \(limitType)"
        } else if minutes < 1440 {
            let hours = minutes / 60
            return "At current rate, access will be limited in ~\(String(format: "%.1f", hours)) hr due to \(limitType)"
        } else {
            let days = minutes / 1440
            return "At current rate, access will be limited in ~\(String(format: "%.1f", days)) days due to \(limitType)"
        }
    }

    func colorForPercent(_ percent: Double) -> Color {
        if percent > 95 { return Color(nsColor: .systemRed) }
        if percent >= 90 { return Color(nsColor: .systemOrange) }
        return .primary
    }

    func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}

struct UsageConsumedBox: View {
    let title: String
    let value: Double
    @Environment(\.colorScheme) var colorScheme

    var boxBackground: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.05)
            : Color.black.opacity(0.03)
    }

    var body: some View {
        VStack(spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(String(format: "+%.1f%%", value))
                .font(.title3)
                .fontWeight(.semibold)
                .foregroundColor(value > 0 ? .orange : .secondary)
        }
        .frame(minWidth: 100)
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
        .background(boxBackground)
        .cornerRadius(8)
    }
}

class ChartWindowController {
    static var windows: [String: NSWindow] = [:]

    static func showChart(for account: Account, store: UsageStore) {
        // Close existing window for this account if open
        if let existing = windows[account.id] {
            existing.close()
            windows.removeValue(forKey: account.id)
        }

        let dataPoints = store.loadHistory(for: account.id)
        let fullDataPoints = store.loadFullHistory(for: account.id)

        let chartView = UsageChartWindow(account: account, dataPoints: dataPoints, fullDataPoints: fullDataPoints, store: store)
        let hostingController = NSHostingController(rootView: chartView)

        let window = NSWindow(contentViewController: hostingController)
        window.title = "Usage History - \(account.displayName)"
        window.styleMask = [.titled, .closable, .resizable]
        window.setContentSize(NSSize(width: 620, height: 600))
        window.center()

        windows[account.id] = window

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
