import LanternfishKit
import SwiftUI

/// "Speed Test" card: start/cancel, live gauges while running, last result afterwards.
struct OverviewSpeedTestSection: View {
    let model: OverviewModel

    var body: some View {
        OverviewCard(title: "Speed Test", symbol: "speedometer", tint: .orange) {
            if model.isSpeedTesting {
                Button("Cancel", role: .cancel) { model.cancelSpeedTest() }
                    .controlSize(.small)
            } else {
                Button(model.lastSpeedResult == nil ? "Run Speed Test" : "Run Again") {
                    model.startSpeedTest()
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
            }
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                if let p = model.speedProgress {
                    running(p)
                } else if let r = model.lastSpeedResult {
                    result(r)
                } else {
                    Text(
                        "Measures latency, download and upload speed to Cloudflare's nearest server. Takes about 20 seconds and transfers up to a few hundred MB on fast connections."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                if let error = model.speedError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .padding(.vertical, 8)
        }
    }

    private func running(_ p: SpeedTestProgress) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                SpeedGauge(
                    title: "Download", symbol: "arrow.down.circle.fill", tint: .blue,
                    mbps: p.downloadMbps, active: p.phase == .download)
                SpeedGauge(
                    title: "Upload", symbol: "arrow.up.circle.fill", tint: .purple,
                    mbps: p.uploadMbps, active: p.phase == .upload)
            }
            latencyRow(latency: p.latencyMs, jitter: p.jitterMs, active: p.phase == .latency)
            VStack(alignment: .leading, spacing: 3) {
                ProgressView(value: p.fraction)
                    .progressViewStyle(.linear)
                Text("Measuring \(p.phase.label.lowercased())…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func result(_ r: SpeedTestResult) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                SpeedGauge(
                    title: "Download", symbol: "arrow.down.circle.fill", tint: .blue,
                    mbps: r.downloadMbps, active: false)
                SpeedGauge(
                    title: "Upload", symbol: "arrow.up.circle.fill", tint: .purple,
                    mbps: r.uploadMbps, active: false)
            }
            latencyRow(latency: r.latencyMs, jitter: r.jitterMs, active: false)
            Text(
                "Last run \(r.date.formatted(date: .omitted, time: .shortened)) · \(r.date.formatted(.relative(presentation: .named)))"
            )
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
    }

    private func latencyRow(latency: Double?, jitter: Double?, active: Bool) -> some View {
        HStack(spacing: 16) {
            metric("Latency", latency.map(OverviewFormat.ms), active: active && latency == nil)
            metric("Jitter", jitter.map(OverviewFormat.ms), active: active && jitter == nil)
            Spacer()
        }
    }

    private func metric(_ title: String, _ value: String?, active: Bool) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            if active {
                ProgressView().controlSize(.mini)
            } else {
                Text(value ?? "—")
                    .font(.callout.monospacedDigit())
                    .contentTransition(.numericText())
            }
        }
    }
}

/// Half-ring gauge on a log scale (1 Mbps … 1 Gbps) with the number in the middle.
private struct SpeedGauge: View {
    let title: String
    let symbol: String
    let tint: Color
    let mbps: Double?
    let active: Bool

    private var fill: Double {
        guard let mbps, mbps > 0 else { return 0 }
        return min(max(log10(mbps + 1) / 3.0, 0.02), 1)  // 0 → 1000 Mbps
    }

    var body: some View {
        VStack(spacing: 2) {
            ZStack {
                Arc().stroke(.quaternary, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                Arc().trim(from: 0, to: fill)
                    .stroke(tint.gradient, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .animation(.easeOut(duration: 0.25), value: fill)
                VStack(spacing: 0) {
                    Text(mbps.map(OverviewFormat.mbps) ?? "—")
                        .font(.system(size: 22, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(mbps == nil ? .tertiary : .primary)
                        .contentTransition(.numericText())
                        .animation(.default, value: mbps)
                    Text("Mbps").font(.caption2).foregroundStyle(.secondary)
                }
                .offset(y: 10)
            }
            .frame(height: 64)
            HStack(spacing: 3) {
                Image(systemName: symbol).foregroundStyle(tint)
                Text(title)
                if active { PulsingDot(size: 6) }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(mbps.map { "\(OverviewFormat.mbps($0)) megabits per second" } ?? "Not measured")
    }

    /// 240° arc opening at the bottom.
    private struct Arc: Shape {
        func path(in rect: CGRect) -> Path {
            let r = min(rect.width / 2, rect.height * 0.62) - 4
            let c = CGPoint(x: rect.midX, y: rect.minY + r + 4)
            var p = Path()
            p.addArc(center: c, radius: r, startAngle: .degrees(150), endAngle: .degrees(30), clockwise: false)
            return p
        }
    }
}
