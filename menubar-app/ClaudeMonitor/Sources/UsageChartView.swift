import SwiftUI
import Charts

struct UsageChartWindow: View {
    let account: Account
    let dataPoints: [UsageDataPoint]
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(account.email ?? account.id)
                        .font(.title2)
                        .fontWeight(.semibold)
                    if let plan = account.plan {
                        Text(plan)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
                Spacer()
                if let percent = account.latestPercent {
                    Text("\(Int(percent))%")
                        .font(.title)
                        .fontWeight(.bold)
                        .foregroundColor(colorForPercent(percent))
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
                // Weekly usage over time chart
                VStack(alignment: .leading, spacing: 8) {
                    Text("Weekly Usage Over Time")
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
                            AxisValueLabel(format: .dateTime.month().day().hour())
                        }
                    }
                    .frame(height: 200)
                }

                // Usage consumption chart (deltas)
                if dataPoints.contains(where: { $0.usageDelta > 0 }) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Usage Consumed Per Reading")
                            .font(.headline)

                        Chart(dataPoints.filter { $0.usageDelta > 0 }) { point in
                            BarMark(
                                x: .value("Time", point.timestamp),
                                y: .value("Delta %", point.usageDelta)
                            )
                            .foregroundStyle(Color.orange.gradient)
                        }
                        .chartYAxis {
                            AxisMarks(position: .leading) { value in
                                AxisGridLine()
                                AxisValueLabel {
                                    if let percent = value.as(Double.self) {
                                        Text("+\(Int(percent))%")
                                            .font(.caption)
                                    }
                                }
                            }
                        }
                        .chartXAxis {
                            AxisMarks(values: .automatic) { value in
                                AxisGridLine()
                                AxisValueLabel(format: .dateTime.month().day().hour())
                            }
                        }
                        .frame(height: 150)
                    }
                }

                Spacer()

                // Stats summary
                HStack(spacing: 24) {
                    StatBox(title: "Data Points", value: "\(dataPoints.count)")
                    if let first = dataPoints.first, let last = dataPoints.last {
                        StatBox(title: "Time Range", value: timeRange(from: first.timestamp, to: last.timestamp))
                    }
                    let totalUsage = dataPoints.reduce(0) { $0 + $1.usageDelta }
                    StatBox(title: "Total Consumed", value: String(format: "%.1f%%", totalUsage))
                }
            }
        }
        .padding(20)
        .frame(width: 600, height: 500)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    func colorForPercent(_ percent: Double) -> Color {
        if percent > 95 { return Color(nsColor: .systemRed) }
        if percent >= 90 { return Color(nsColor: .systemOrange) }
        return .primary
    }

    func timeRange(from start: Date, to end: Date) -> String {
        let interval = end.timeIntervalSince(start)
        let hours = Int(interval / 3600)
        let days = hours / 24
        if days > 0 {
            return "\(days)d \(hours % 24)h"
        }
        return "\(hours)h"
    }
}

struct StatBox: View {
    let title: String
    let value: String

    var body: some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(value)
                .font(.headline)
        }
        .frame(minWidth: 80)
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

        let chartView = UsageChartWindow(account: account, dataPoints: dataPoints)
        let hostingController = NSHostingController(rootView: chartView)

        let window = NSWindow(contentViewController: hostingController)
        window.title = "Usage History - \(account.email ?? account.id)"
        window.styleMask = [.titled, .closable, .resizable]
        window.setContentSize(NSSize(width: 600, height: 500))
        window.center()

        windows[account.id] = window

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
