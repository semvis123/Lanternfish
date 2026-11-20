import LanternfishKit
import SwiftUI

/// The device inspector's hero: a large icon, the name, brand and model, a status pill, a 24-hour
/// presence sparkline and the primary actions.
///
/// It never reads the store's ping sessions itself: `HeaderStatusPill` and `HeaderActionRow` do, so a
/// ping tick (every second) re-renders only those two small views.
struct InspectorHeader: View {
    let device: Device
    let store: ScanStore
    let record: KnownDevice?

    var body: some View {
        VStack(spacing: 0) {
            DeviceIconView(device: device, size: 64, dimmed: !device.isOnline)
                .shadow(color: .black.opacity(0.14), radius: 5, y: 2)
                .padding(.bottom, 10)

            Text(device.listName)
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .textSelection(.enabled)
                .accessibilityAddTraits(.isHeader)

            if let line = Self.brandLine(device) {
                Text(line)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .textSelection(.enabled)
                    .padding(.top, 2)
            }
            if let meta = Self.metaLine(device) {
                Text(meta)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .textSelection(.enabled)
                    .padding(.top, 1)
            }

            HeaderTags(device: device, store: store, record: record)
                .padding(.top, 10)

            if let record, !record.presence.isEmpty {
                PresenceSparkline(presence: record.presence)
                    .padding(.top, 16)
            }

            HeaderActionRow(device: device, store: store)
                .padding(.top, 16)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
        .padding(.bottom, 2)
    }

    /// "Apple · Apple TV 4K". Nil when it would only repeat the name.
    private static func brandLine(_ d: Device) -> String? {
        let brand = d.brand.map(Device.shortBrand)
        var model = d.model?.trimmingCharacters(in: .whitespaces)
        if model?.isEmpty == true { model = nil }
        let name = d.listName.lowercased()
        // Skip what the name already says ("Netgear RAX40" needs no "Netgear · RAX40").
        if let m = model, name.contains(m.lowercased()) { model = nil }
        switch (brand, model) {
        case (let b?, let m?):
            return m.lowercased() == b.lowercased() ? b : "\(b) · \(m)"
        case (let b?, nil):
            // The fallback name ("Espressif Smart Device") already says the brand.
            return d.hasRealName && !name.contains(b.lowercased()) ? b : nil
        case (nil, let m?):
            return m
        default:
            return nil
        }
    }

    /// "Router · Linux · Firmware 1.2.3": the type, the OS and the firmware, where known.
    private static func metaLine(_ d: Device) -> String? {
        var parts: [String] = []
        let kind = d.effectiveKind
        if kind != .unknown, !d.listName.localizedCaseInsensitiveContains(kind.label) {
            parts.append(kind.label)
        }
        let os = d.osHint?.trimmingCharacters(in: .whitespaces)
        if let os, !os.isEmpty { parts.append(os) }
        if os?.localizedCaseInsensitiveContains("firmware") != true,
            let fw = d.identificationReasons.first(where: { $0.hasPrefix("Firmware ") })
        {
            parts.append(fw)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

// MARK: - Status

/// The status pill plus the "New" and "Watched" tags; wraps onto two lines when narrow.
private struct HeaderTags: View {
    let device: Device
    let store: ScanStore
    let record: KnownDevice?

    var body: some View {
        let watched = record?.isWatched == true
        let status = watched ? AppServices.shared.watch.live(for: device, in: store)?.state.status : nil
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { content(watched: watched, status: status) }
            VStack(spacing: 6) {
                HeaderStatusPill(device: device, store: store)
                HStack(spacing: 6) { tags(watched: watched, status: status) }
            }
        }
    }

    @ViewBuilder
    private func content(watched: Bool, status: WatchStatus?) -> some View {
        HeaderStatusPill(device: device, store: store)
        tags(watched: watched, status: status)
    }

    @ViewBuilder
    private func tags(watched: Bool, status: WatchStatus?) -> some View {
        if device.isNew {
            HeaderPill(tint: .accentColor) {
                Text("New")
            }
            .help("First seen on this network recently")
        }
        if watched {
            HeaderPill(tint: .indigo) {
                Image(systemName: "eye.fill").imageScale(.small)
                Text("Watched")
            }
            .help(
                status == .down
                    ? "Watched — the monitor sees it offline"
                    : "Watched — you get an alert when it goes offline or comes back"
            )
            .accessibilityElement(children: .combine)
        }
    }
}

/// "● Online · 3 ms", "● Offline · last seen 2 hr. ago" or "This Mac". Reads the device's ping
/// session itself so the live latency updates without re-rendering the inspector.
private struct HeaderStatusPill: View {
    let device: Device
    let store: ScanStore

    var body: some View {
        if device.isSelf {
            HeaderPill(tint: .accentColor) {
                Image(systemName: "laptopcomputer").imageScale(.small)
                Text("This Mac")
            }
            .help("The Mac you're using")
        } else if device.isOnline {
            HeaderPill(tint: .green, neutralText: true) {
                Dot(color: .green)
                Text("Online")
                if let latency {
                    Text("·").foregroundStyle(.secondary)
                    Text(latency)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .foregroundStyle(timedOut ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                }
            }
            .help(help)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(latency.map { "Online, \($0)" } ?? "Online")
        } else {
            RelativeTimeRefresh {
                HeaderPill(tint: .gray, neutralText: true) {
                    Dot(color: .gray)
                    Text(device.lastSeen.map { "Offline · last seen \(RelativeTime.short($0))" } ?? "Offline")
                        .foregroundStyle(.secondary)
                }
            }
            .help(device.lastSeen.map { "Last seen \($0.formatted(date: .complete, time: .shortened))" } ?? "Offline")
            .accessibilityElement(children: .combine)
        }
    }

    private var session: PingSession? {
        store.canReachDevices ? store.pingSessions[device.ip] : nil
    }

    private var timedOut: Bool {
        guard let s = session, s.isRunning, let last = s.last else { return false }
        return last.rtt == nil
    }

    /// The live ping's last round trip while pinging, else the scan's response time.
    private var latency: String? {
        if let s = session, s.isRunning, let last = s.last {
            return last.rtt.map(Latency.format) ?? "no reply"
        }
        return device.responseTime.map(Latency.format)
    }

    private var help: String {
        if let s = session, s.isRunning { return "Live ping of \(device.ip.description), every second" }
        return device.responseTime == nil ? "Answered the last scan" : "Response time in the last scan"
    }
}

private struct Dot: View {
    let color: Color
    var body: some View {
        Circle().fill(color).frame(width: 7, height: 7).accessibilityHidden(true)
    }
}

/// A capsule tag in the header, tinted; `neutralText` keeps the text primary (status pill).
private struct HeaderPill<Content: View>: View {
    let tint: Color
    var neutralText = false
    @ViewBuilder let content: Content
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 5) { content }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(neutralText ? AnyShapeStyle(.primary) : AnyShapeStyle(tint))
            .lineLimit(1)
            .padding(.horizontal, 9)
            .padding(.vertical, 3.5)
            .background(tint.opacity(scheme == .dark ? 0.22 : 0.13), in: Capsule())
            .fixedSize()
    }
}

// MARK: - Presence sparkline

/// The last 24 hours as 48 half-hour bars: tall green where the device was online (height = share
/// of the half hour), a low stub where it was offline, fainter before tracking began. Hover shows
/// the half hour; the help text and the caption give the online percentage.
private struct PresenceSparkline: View {
    let presence: [PresenceInterval]

    private static let buckets = 48
    @State private var hovered: Int?
    @State private var stripWidth: CGFloat = 1

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            content(now: context.date)
        }
    }

    private func content(now: Date) -> some View {
        let gap = AppSettings.presenceGap
        let window = DateInterval(start: now.addingTimeInterval(-86_400), end: now)
        let segments = presence.segments(in: window, now: now, gap: gap)
        let stats = presence.stats(in: window, now: now, gap: gap)
        let tracked = presence.first?.start ?? now
        let step = window.duration / Double(Self.buckets)
        let bars: [Bar] = (0..<Self.buckets).map { i in
            let b = DateInterval(start: window.start.addingTimeInterval(Double(i) * step), duration: step)
            let online = segments.compactMap { $0.clipped(to: b) }.reduce(0) { $0 + $1.duration }
            return Bar(interval: b, fraction: min(1, online / step), tracked: b.end > tracked)
        }
        let percent = stats.onlineFraction.map { Int(($0 * 100).rounded()) }

        return VStack(spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                if let i = hovered, bars.indices.contains(i) {
                    Text(describe(bars[i]))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                } else {
                    Text("Last 24 Hours")
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 6)
                    if let percent {
                        Text("\(percent)% online")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .font(.caption)
            .lineLimit(1)

            BarStrip(bars: bars, hovered: hovered)
                .frame(height: 20)
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    // Bars span the full width, so the index is a straight proportion.
                    switch phase {
                    case .active(let p): hovered = Self.index(at: p.x, width: stripWidth)
                    case .ended: hovered = nil
                    }
                }
                .background(
                    GeometryReader { g in
                        Color.clear.onAppear { stripWidth = g.size.width }
                            .onChange(of: g.size.width) { _, w in stripWidth = w }
                    })

            HStack {
                Text(window.start.formatted(date: .omitted, time: .shortened))
                Spacer()
                Text("Now")
            }
            .font(.system(size: 9).monospacedDigit())
            .foregroundStyle(.tertiary)
        }
        .help(helpText(stats: stats, percent: percent))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Presence, last 24 hours")
        .accessibilityValue(helpText(stats: stats, percent: percent))
    }

    private static func index(at x: CGFloat, width: CGFloat) -> Int {
        min(buckets - 1, max(0, Int(x / max(width, 1) * CGFloat(buckets))))
    }

    private func helpText(stats: PresenceStats, percent: Int?) -> String {
        guard let percent, let observed = stats.observed else { return "Not seen in the last 24 hours" }
        let span =
            observed.duration >= 86_000
            ? "the last 24 hours"
            : "the last \(WatchFormat.duration(observed.duration)) (since tracking began)"
        return "Online \(percent)% of \(span) — \(WatchFormat.duration(stats.online)) in \(stats.sessions) "
            + (stats.sessions == 1 ? "session" : "sessions")
    }

    private func describe(_ bar: Bar) -> String {
        let from = bar.interval.start.formatted(date: .omitted, time: .shortened)
        let to = bar.interval.end.formatted(date: .omitted, time: .shortened)
        let state: String
        if !bar.tracked {
            state = "not tracked yet"
        } else if bar.fraction >= 0.99 {
            state = "online"
        } else if bar.fraction <= 0 {
            state = "offline"
        } else {
            state = "online \(WatchFormat.duration(bar.fraction * bar.interval.duration))"
        }
        return "\(from) – \(to) · \(state)"
    }

    struct Bar {
        let interval: DateInterval
        let fraction: Double
        let tracked: Bool
    }
}

/// The bars themselves, drawn in one Canvas.
private struct BarStrip: View {
    let bars: [PresenceSparkline.Bar]
    let hovered: Int?

    var body: some View {
        Canvas { ctx, size in
            let n = CGFloat(bars.count)
            let spacing: CGFloat = size.width / n > 5 ? 1.5 : 1
            let w = max(1, (size.width - spacing * (n - 1)) / n)
            let stub: CGFloat = 3
            for (i, bar) in bars.enumerated() {
                let x = CGFloat(i) * (w + spacing)
                let h: CGFloat
                let style: GraphicsContext.Shading
                if bar.fraction > 0 {
                    h = max(stub + 2, size.height * CGFloat(0.3 + 0.7 * bar.fraction))
                    style = .color(.green.opacity(0.55 + 0.45 * bar.fraction))
                } else {
                    h = stub
                    style = .color(.secondary.opacity(bar.tracked ? 0.35 : 0.14))
                }
                let rect = CGRect(x: x, y: size.height - h, width: w, height: h)
                ctx.fill(Path(roundedRect: rect, cornerRadius: min(w / 2, 1.5)), with: style)
                if i == hovered {
                    let full = CGRect(x: x - 0.5, y: 0, width: w + 1, height: size.height)
                    ctx.fill(Path(roundedRect: full, cornerRadius: 2), with: .color(.primary.opacity(0.08)))
                }
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Actions

/// Open / Ping / Watch / Copy IP / More, from the device's `DeviceActionSet` (the same actions the
/// table, map and ⌘K offer). Live actions follow `store.canReachDevices`: shown disabled with the
/// reason as help while browsing a saved network.
private struct HeaderActionRow: View {
    let device: Device
    let store: ScanStore
    private let wake = WakeController.shared

    var body: some View {
        let set = DeviceActionSet(device: device, store: store, context: .init(show: {}))
        let pinging = store.pingSessions[device.ip]?.isRunning == true
        // Offline: Wake takes Open's place (Open stays in More).
        let wakeAction = device.isOnline ? nil : set.action("wake")
        let open = wakeAction == nil ? set.action("open") : nil
        let ping = set.action(pinging ? "stopping" : "ping")
        let watch = set.action("watch") ?? set.action("unwatch")
        let inRow: Set<String> = Set(
            [open?.id, ping?.id, watch?.id, wakeAction?.id].compactMap { $0 } + ["copyip", "show"])
        // "Open" keeps its menu entry when it has other web ports to choose from.
        let excluded = inRow.subtracting(open?.alternates.isEmpty == false ? ["open"] : [])

        HStack(alignment: .top, spacing: 4) {
            if let open {
                HeroButton(action: open, title: "Open")
            }
            if let wakeAction {
                wakeButton(wakeAction)
            }
            if let ping {
                HeroButton(
                    action: ping, title: pinging ? "Stop" : "Ping", active: pinging,
                    help: pinging
                        ? "Stop pinging \(device.ip.description)"
                        : device.isOnline
                            ? "Ping \(device.ip.description) every second"
                            : "Ping \(device.ip.description) to check whether the device is back")
            }
            if let watch {
                let on = watch.id == "unwatch"
                HeroButton(
                    action: watch, title: "Watch", active: on,
                    symbol: on ? "eye.fill" : "eye",
                    accessibility: on ? "Stop Watching" : "Watch",
                    help: on
                        ? "Stop monitoring this device"
                        : "Monitor this device continuously and get an alert when it goes offline or comes back")
            }
            CopyButton("Copy IP", help: "Copy \(device.ip.description)", showsTitle: true) { device.ip.description }
                .labelStyle(HeroLabelStyle(tint: .accentColor))
                .buttonStyle(HeroButtonStyle())
                .accessibilityLabel("Copy IP Address")
            Menu {
                DeviceActionMenuItems(actions: set, excluding: excluded)
            } label: {
                Label("More", systemImage: "ellipsis")
                    .labelStyle(HeroLabelStyle(tint: .accentColor))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .frame(maxWidth: .infinity)
            .help("More actions")
            .accessibilityLabel("More Actions")
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func wakeButton(_ action: DeviceAction) -> some View {
        let key = device.mac?.description ?? "-"
        let sent = wake.recentlySent.contains(key)
        let sending = wake.sending.contains(key)
        Button {
            action.perform()
        } label: {
            Label {
                Text(sent ? "Sent" : "Wake")
            } icon: {
                if sending {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: sent ? "checkmark" : "power")
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .labelStyle(HeroLabelStyle(tint: sent ? .green : .accentColor))
        }
        .buttonStyle(HeroButtonStyle())
        .disabled(!action.isEnabled || sending)
        .help(
            sent
                ? "Magic packet sent. Pinging \(device.ip) to see the device come up."
                : action.disabledReason ?? action.subtitle ?? "Send a Wake-on-LAN magic packet"
        )
        .accessibilityLabel(sent ? "Magic packet sent" : "Wake")
    }
}

/// One action as a round icon with a short title below.
private struct HeroButton: View {
    let action: DeviceAction
    let title: String
    var active = false
    var symbol: String?
    var accessibility: String?
    var help: String?

    var body: some View {
        Button {
            action.perform()
        } label: {
            Label(title, systemImage: symbol ?? action.symbol)
                .labelStyle(HeroLabelStyle(tint: .accentColor, active: active))
        }
        .buttonStyle(HeroButtonStyle())
        .disabled(!action.isEnabled)
        // The reason a live action is unavailable wins over the description.
        .help(action.disabledReason ?? help ?? action.subtitle ?? action.title)
        .accessibilityLabel(accessibility ?? action.title)
        .accessibilityHint(action.disabledReason ?? "")
    }
}

/// Icon in a tinted circle, title in small type below (Contacts / Find My style).
private struct HeroLabelStyle: LabelStyle {
    var tint: Color
    var active = false

    func makeBody(configuration: Configuration) -> some View {
        HeroLabel(configuration: configuration, tint: tint, active: active)
    }

    private struct HeroLabel: View {
        let configuration: LabelStyleConfiguration
        let tint: Color
        let active: Bool
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.colorScheme) private var scheme

        var body: some View {
            VStack(spacing: 4) {
                configuration.icon
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(active ? AnyShapeStyle(.white) : AnyShapeStyle(tint))
                    .frame(width: 34, height: 34)
                    .background {
                        Circle().fill(
                            active
                                ? AnyShapeStyle(tint.gradient)
                                : AnyShapeStyle(Color.primary.opacity(scheme == .dark ? 0.1 : 0.06)))
                    }
                configuration.title
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(Rectangle())
        }
    }
}

private struct HeroButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.6 : 1)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .frame(maxWidth: .infinity)
    }
}
