import Charts
import LanternfishKit
import SwiftUI

/// The inspector's "Ping" section: live RTT, totals and a chart of recent round trips.
struct PingSection: View {
    let ip: IPv4Address
    let session: PingSession
    let store: ScanStore

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                headline
                PingChart(results: Array(session.results.suffix(PingChart.window)))
                    .frame(height: 84)
                stats
            }
            .padding(.vertical, 4)
        } header: {
            HStack {
                Text("Ping")
                Spacer()
                if session.isRunning {
                    PulsingDot()
                    Text("Live").foregroundStyle(.secondary)
                }
            }
        } footer: {
            HStack {
                Text("ICMP echo every second")
                    .foregroundStyle(.secondary)
                Spacer()
                if session.isRunning {
                    Button("Stop") { store.stopPing(ip) }
                        .controlSize(.small)
                } else {
                    Button("Ping Again") { store.startPing(ip) }
                        .controlSize(.small)
                }
            }
            .padding(.top, 4)
        }
    }

    private var headline: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Group {
                switch session.last {
                case nil:
                    Text("Waiting…").foregroundStyle(.secondary)
                case let r? where r.rtt == nil:
                    Text("Timeout").foregroundStyle(.red)
                case let r?:
                    Text(PingFormat.rtt(r.rtt!))
                }
            }
            .font(.system(size: 28, weight: .semibold, design: .monospaced))
            .contentTransition(.numericText())
            Spacer(minLength: 4)
            if let last = session.last {
                Text("seq \(last.sequence)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var stats: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
            GridRow {
                StatCell(title: "Sent", value: "\(session.sent)")
                StatCell(title: "Received", value: "\(session.received)")
                StatCell(
                    title: "Loss", value: PingFormat.loss(session.lossPercent),
                    tint: session.lossPercent > 0 ? .red : nil)
            }
            GridRow {
                StatCell(title: "Min", value: session.min.map(PingFormat.rtt) ?? "—")
                StatCell(title: "Avg", value: session.avg.map(PingFormat.rtt) ?? "—")
                StatCell(title: "Max", value: session.max.map(PingFormat.rtt) ?? "—")
            }
        }
    }
}

private struct StatCell: View {
    let title: String
    let value: String
    var tint: Color?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout.monospacedDigit())
                .foregroundStyle(tint ?? .primary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Line of the last `window` round trips; timeouts are red vertical bars.
private struct PingChart: View {
    static let window = 60
    let results: [PingResult]

    private struct Point: Identifiable {
        let id: Int
        let ms: Double?
        let segment: Int
    }

    var body: some View {
        // Each timeout starts a new line segment so the line breaks instead of bridging the gap.
        var segment = 0
        let points = results.map { r -> Point in
            if r.rtt == nil { segment += 1 }
            return Point(id: r.sequence, ms: r.rtt.map(PingFormat.ms), segment: segment)
        }
        let peak = points.compactMap(\.ms).max() ?? 1
        let top = Swift.max(peak * 1.25, 1)
        // The visible span grows from 20 to `window` samples, then scrolls.
        let span = Swift.min(Self.window, Swift.max(20, results.count))
        let first = results.first?.sequence ?? 0

        return Chart {
            ForEach(points) { p in
                if let ms = p.ms {
                    AreaMark(x: .value("Seq", p.id), y: .value("RTT", ms), series: .value("Run", p.segment))
                        .foregroundStyle(
                            .linearGradient(
                                colors: [Color.accentColor.opacity(0.25), .clear],
                                startPoint: .top, endPoint: .bottom)
                        )
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Seq", p.id), y: .value("RTT", ms), series: .value("Run", p.segment))
                        .foregroundStyle(Color.accentColor)
                        .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                        .interpolationMethod(.monotone)
                } else {
                    RuleMark(x: .value("Seq", p.id))
                        .foregroundStyle(.red.opacity(0.45))
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                }
            }
            if let p = points.last, let ms = p.ms {
                PointMark(x: .value("Seq", p.id), y: .value("RTT", ms))
                    .foregroundStyle(Color.accentColor)
                    .symbolSize(22)
            }
        }
        .chartXScale(domain: first...first + span - 1)
        .chartYScale(domain: 0...top)
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                AxisValueLabel {
                    if let v = value.as(Double.self) { Text(PingFormat.axis(v)) }
                }
            }
        }
        .accessibilityLabel("Round-trip times of the last \(results.count) pings")
    }
}

/// Small pulsing green dot shown while a ping runs.
struct PulsingDot: View {
    var size: CGFloat = 7

    var body: some View {
        Image(systemName: "circle.fill")
            .font(.system(size: size))
            .foregroundStyle(.green)
            .symbolEffect(.pulse, options: .repeating)
            .accessibilityLabel("Pinging")
    }
}

enum PingFormat {
    static func ms(_ d: Duration) -> Double { Latency.ms(d) }

    /// See `Latency.format`: "<1 ms", "4.2 ms", "128 ms", "1.2 s".
    static func rtt(_ d: Duration) -> String { Latency.format(d) }

    static func loss(_ percent: Double) -> String {
        percent == 0 || percent == 100 ? "\(Int(percent))%" : String(format: "%.1f%%", percent)
    }

    static func axis(_ v: Double) -> String {
        v < 10 && v != v.rounded() ? String(format: "%.1f", v) : "\(Int(v.rounded()))"
    }
}
