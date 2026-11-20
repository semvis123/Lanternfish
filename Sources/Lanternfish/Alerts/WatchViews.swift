import Charts
import LanternfishKit
import SwiftUI

extension WatchStatus {
    var color: Color {
        switch self {
        case .up: .green
        case .down: .red
        case .unknown: .gray
        }
    }

    var label: String {
        switch self {
        case .up: "Online"
        case .down: "Offline"
        case .unknown: "Checking…"
        }
    }
}

/// The inspector's "Uptime" section for a watched device: live status, a latency sparkline from
/// the monitor's recent checks, uptime over 24 h / 7 days and recent outages.
struct UptimeSection: View {
    let device: Device
    let store: ScanStore
    let record: KnownDevice
    private let monitor = AppServices.shared.watch

    // Observed so the footer follows changes in Settings.
    @AppStorage(AppSettings.watchIntervalKey) private var interval = AppSettings.defaultWatchInterval
    @AppStorage(AppSettings.watchFailuresKey) private var failures = AppSettings.defaultWatchFailures

    private static let day: TimeInterval = 86_400

    private var isMonitored: Bool { store.interface != nil && store.displayedNetwork?.id == store.currentNetworkID }

    var body: some View {
        let live = monitor.live(for: device, in: store)
        Section {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                content(live: live, now: context.date)
            }
        } header: {
            HStack {
                Text("Uptime")
                Spacer()
                if isMonitored {
                    StatusCapsule(status: live?.state.status ?? .unknown)
                }
            }
        } footer: {
            HStack {
                Text(
                    isMonitored
                        ? "Checked every \(WatchFormat.duration(AppSettings.watchInterval)) · offline after \(failures) failed checks"
                        : "Not monitored while this network isn't connected."
                )
                .foregroundStyle(.secondary)
                Spacer()
                Button("Stop Watching") { monitor.setWatched(false, device: device, store: store) }
                    .controlSize(.small)
            }
            .font(.caption)
            .padding(.top, 4)
        }
    }

    @ViewBuilder
    private func content(live: WatchMonitor.Live?, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            statusLine(live: live, now: now)
            if let samples = live?.samples, !samples.isEmpty {
                LatencySparkline(samples: samples)
                    .frame(height: 40)
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 2) {
                GridRow {
                    caption("Last 24 Hours")
                    caption("Last 7 Days")
                    caption("Outages (7 d)")
                }
                GridRow {
                    uptimeValue(record.uptime(last: Self.day, now: now))
                    uptimeValue(record.uptime(last: 7 * Self.day, now: now))
                    Text("\(record.outages.filter { ($0.end ?? now) > now.addingTimeInterval(-7 * Self.day) }.count)")
                        .font(.callout.monospacedDigit())
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if !record.outages.isEmpty {
                outageList(now: now)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func statusLine(live: WatchMonitor.Live?, now: Date) -> some View {
        let status = isMonitored ? (live?.state.status ?? .unknown) : .unknown
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle().fill(status.color).frame(width: 9, height: 9)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            VStack(alignment: .leading, spacing: 1) {
                Text(statusTitle(status, live: live, now: now))
                    .font(.headline)
                if let since = record.watchedSince {
                    Text("Watching since \(PresenceTimelineFormat.dayTime(since, now: now))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if status == .up, let rtt = live?.lastRTT {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(PingFormat.rtt(rtt)).font(.headline.monospacedDigit())
                    if live?.answersOnlyTCP == true {
                        Text("via TCP").font(.caption).foregroundStyle(.secondary)
                            .help(
                                "The device doesn't answer ping (ICMP); it is checked by connecting to one of its open ports."
                            )
                    }
                }
            }
        }
    }

    private func statusTitle(_ status: WatchStatus, live: WatchMonitor.Live?, now: Date) -> String {
        guard isMonitored else { return "Not monitored" }
        switch status {
        case .up: return "Online"
        case .down:
            let since = live?.state.downSince ?? record.outages.ongoing?.start
            return since.map { "Offline for \(WatchFormat.duration(now.timeIntervalSince($0)))" } ?? "Offline"
        case .unknown:
            if let f = live?.state.consecutiveFailures, f > 0 { return "Not answering (\(f) failed)" }
            return "Checking…"
        }
    }

    private func outageList(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Recent Outages").font(.caption).foregroundStyle(.secondary)
            ForEach(record.outages.suffix(5).reversed(), id: \.start) { o in
                HStack {
                    Image(systemName: o.isOngoing ? "exclamationmark.circle.fill" : "minus.circle")
                        .foregroundStyle(o.isOngoing ? .red : .secondary)
                        .font(.caption)
                    Text(outageSpan(o, now: now))
                        .font(.callout.monospacedDigit())
                    Spacer()
                    Text(
                        o.isOngoing
                            ? "Ongoing · \(WatchFormat.duration(o.duration(now: now)))"
                            : WatchFormat.duration(o.duration(now: now))
                    )
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(o.isOngoing ? .red : .secondary)
                }
            }
        }
    }

    private func outageSpan(_ o: OutageEvent, now: Date) -> String {
        let start = PresenceTimelineFormat.dayTime(o.start, now: now)
        guard let end = o.end else { return "Since \(start)" }
        let sameDay = Calendar.current.isDate(o.start, inSameDayAs: end)
        let endText =
            sameDay ? end.formatted(date: .omitted, time: .shortened) : PresenceTimelineFormat.dayTime(end, now: now)
        return "\(start) – \(endText)"
    }

    private func caption(_ s: String) -> some View {
        Text(s).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
    }

    private func uptimeValue(_ f: Double?) -> some View {
        Text(f.map(Uptime.format) ?? "—")
            .font(.callout.monospacedDigit())
            .foregroundStyle(f.map { $0 < 0.99 ? Color.orange : Color.primary } ?? .secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

enum PresenceTimelineFormat {
    /// "13:05" today, "Yesterday 13:05", else "Thu 13:05" (within a week) or "12 Mar 13:05".
    static func dayTime(_ d: Date, now: Date) -> String {
        let cal = Calendar.current
        let time = d.formatted(date: .omitted, time: .shortened)
        if cal.isDate(d, inSameDayAs: now) { return time }
        if cal.isDateInYesterday(d) { return "Yesterday \(time)" }
        if now.timeIntervalSince(d) < 6 * 86_400 { return "\(d.formatted(.dateTime.weekday(.abbreviated))) \(time)" }
        return "\(d.formatted(.dateTime.day().month(.abbreviated))) \(time)"
    }
}

/// "● Online" capsule.
private struct StatusCapsule: View {
    let status: WatchStatus

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(status.color).frame(width: 6, height: 6)
            Text(status.label)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
    }
}

/// Round-trip times of the monitor's recent checks; failed checks are red ticks.
private struct LatencySparkline: View {
    let samples: [WatchMonitor.Sample]

    private struct Point: Identifiable {
        let id: Int
        let ms: Double?
        let segment: Int
    }

    var body: some View {
        var segment = 0
        let points = samples.enumerated().map { i, s -> Point in
            if s.rtt == nil { segment += 1 }
            return Point(id: i, ms: s.rtt.map(PingFormat.ms), segment: segment)
        }
        let peak = points.compactMap(\.ms).max() ?? 1
        let span = max(20, samples.count)
        return Chart {
            ForEach(points) { p in
                if let ms = p.ms {
                    AreaMark(x: .value("Check", p.id), y: .value("RTT", ms), series: .value("Run", p.segment))
                        .foregroundStyle(
                            .linearGradient(
                                colors: [Color.green.opacity(0.22), .clear],
                                startPoint: .top, endPoint: .bottom)
                        )
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Check", p.id), y: .value("RTT", ms), series: .value("Run", p.segment))
                        .foregroundStyle(Color.green)
                        .lineStyle(StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round))
                        .interpolationMethod(.monotone)
                } else {
                    RuleMark(x: .value("Check", p.id))
                        .foregroundStyle(.red.opacity(0.55))
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                }
            }
        }
        .chartXScale(domain: 0...span - 1)
        .chartYScale(domain: 0...max(peak * 1.25, 1))
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 2)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                AxisValueLabel {
                    if let v = value.as(Double.self) { Text(PingFormat.axis(v)) }
                }
            }
        }
        .accessibilityLabel("Round-trip times of the last \(samples.count) checks")
    }
}

/// Small eye shown next to a watched device's name (tinted by its status).
struct WatchIndicator: View {
    let status: WatchStatus?

    var body: some View {
        Image(systemName: "eye.fill")
            .font(.caption)
            .foregroundStyle(status == .down ? Color.red : status == .up ? Color.green : Color.secondary)
            .help(status == .down ? "Watched — offline" : status == .up ? "Watched — online" : "Watched")
            .accessibilityLabel(status == .down ? "Watched, offline" : status == .up ? "Watched, online" : "Watched")
    }
}

/// Debug aid: LANTERNFISH_WATCH_SNAPSHOT=/path.png renders the header, Uptime and Presence sections of the
/// device at LANTERNFISH_PREVIEW_SELECT=<ip> after LANTERNFISH_WATCH_SNAPSHOT_DELAY seconds (default 30).
@MainActor
enum WatchSnapshot {
    static func scheduleIfRequested(hub: NetworkHub) {
        let env = DebugEnv.values
        guard let path = env["LANTERNFISH_WATCH_SNAPSHOT"],
            let ip = env["LANTERNFISH_PREVIEW_SELECT"].flatMap(IPv4Address.init)
        else { return }
        let delay = DebugEnv.seconds("LANTERNFISH_WATCH_SNAPSHOT_DELAY", default: 30)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            guard let store = hub.stores.first(where: { $0.devices.contains { $0.ip == ip } }),
                let device = store.devices.first(where: { $0.ip == ip })
            else {
                alertsLog("watch snapshot: %@ not found", ip.description)
                return
            }
            let record = AppServices.shared.watch.record(for: device, in: store)
            let view = Form {
                Section { InspectorHeader(device: device, store: store, record: record) }
                if let record, record.isWatched {
                    UptimeSection(device: device, store: store, record: record)
                }
                PresenceSection(record: record)
            }
            .formStyle(.grouped)
            .frame(width: 340, height: 900)
            OffscreenRenderer.render(view, to: path)
        }
    }
}
