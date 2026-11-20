import LanternfishKit
import SwiftUI

/// The inspector's "Presence" section: when the device was online today (24 h strip) and over the
/// last 7 days (one thin strip per day), with hover read-outs and a summary.
struct PresenceSection: View {
    let record: KnownDevice?

    var body: some View {
        Section {
            if let record, !record.presence.isEmpty {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    PresenceTimeline(presence: record.presence, now: context.date, gap: AppSettings.presenceGap)
                }
            } else {
                Text("No presence recorded yet. Each scan and each watch check records when the device is online.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("Presence")
        } footer: {
            if record?.presence.isEmpty == false {
                Text(
                    "From scans and watch checks. Sightings less than \(WatchFormat.duration(AppSettings.presenceGap)) apart count as online in between."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            }
        }
    }
}

/// Summary, today strip and 7-day stack sharing one hover read-out.
private struct PresenceTimeline: View {
    let presence: [PresenceInterval]
    let now: Date
    let gap: TimeInterval

    @State private var hover: Date?

    var body: some View {
        let days = PresenceCalendar.days(count: 7, now: now)
        let effective = presence.effective(now: now, gap: gap)
        let week = DateInterval(start: days.first?.start ?? now, end: now)
        let stats = presence.stats(in: week, now: now, gap: gap)
        let today = days.last ?? DateInterval(start: now, duration: 86_400)
        let todayOnline = presence.segments(in: today, now: now, gap: gap).reduce(0) { $0 + $1.duration }

        VStack(alignment: .leading, spacing: 10) {
            summary(stats)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Today").font(.subheadline.weight(.medium))
                    Spacer()
                    Text("\(WatchFormat.duration(todayOnline)) online")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                PresenceStrip(day: today, segments: effective, now: now, height: 18, hover: $hover)
                HourAxis()
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Last 7 Days").font(.subheadline.weight(.medium))
                ForEach(days.reversed(), id: \.start) { day in
                    HStack(spacing: 8) {
                        Text(dayLabel(day))
                            .font(.caption)
                            .foregroundStyle(day == today ? .primary : .secondary)
                            .frame(width: 38, alignment: .leading)
                        PresenceStrip(day: day, segments: effective, now: now, height: 8, hover: $hover)
                    }
                }
                HStack(spacing: 8) {
                    Color.clear.frame(width: 38, height: 1)
                    HourAxis()
                }
            }

            hoverLine(effective)
        }
        .padding(.vertical, 4)
    }

    // MARK: Summary

    @ViewBuilder
    private func summary(_ s: PresenceStats) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let f = s.onlineFraction, let observed = s.observed {
                let span =
                    observed.duration >= 6.5 * 86_400
                    ? "the last 7 days"
                    : "the last \(WatchFormat.duration(observed.duration)) (since tracking began)"
                Text(
                    "Online \(Text("\(Int((f * 100).rounded()))%").foregroundStyle(.green).fontWeight(.semibold)) of \(span)"
                )
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 2) {
                GridRow {
                    caption("Sessions")
                    caption("Online")
                    caption("Longest Offline")
                }
                GridRow {
                    value("\(s.sessions)")
                    value(WatchFormat.duration(s.online))
                    value(s.longestOffline.map(WatchFormat.duration) ?? "—")
                }
            }
        }
    }

    private func caption(_ s: String) -> some View {
        Text(s).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
    }

    private func value(_ s: String) -> some View {
        Text(s).font(.callout.monospacedDigit()).frame(maxWidth: .infinity, alignment: .leading)
    }

    private func dayLabel(_ day: DateInterval) -> String {
        if Calendar.current.isDateInToday(day.start) { return "Today" }
        return day.start.formatted(.dateTime.weekday(.abbreviated))
    }

    // MARK: Hover

    /// "Thu 13:05 — online 08:12 – now (4 h 53 min)". Reserved height so the layout doesn't jump.
    private func hoverLine(_ effective: [DateInterval]) -> some View {
        Group {
            if let t = hover {
                Text(describe(t, effective))
            } else {
                Text("Hover over the timeline for times.")
                    .foregroundStyle(.tertiary)
            }
        }
        .font(.caption.monospacedDigit())
        .lineLimit(1)
        .truncationMode(.middle)
        .frame(maxWidth: .infinity, minHeight: 16, alignment: .leading)
    }

    private func describe(_ t: Date, _ effective: [DateInterval]) -> String {
        let at = "\(Self.dayTime(t, relativeTo: now))"
        if t > now { return "\(at) — later today" }
        if let seg = effective.first(where: { $0.start <= t && t <= $0.end }) {
            return "\(at) — online \(span(seg.start, seg.end))"
        }
        let prev = effective.last { $0.end < t }
        let next = effective.first { $0.start > t }
        guard let prev else {
            return next.map { "\(at) — not seen yet (first seen \(Self.dayTime($0.start, relativeTo: now)))" }
                ?? "\(at) — not seen"
        }
        return "\(at) — offline \(span(prev.end, next?.start ?? now, ongoing: next == nil))"
    }

    private func span(_ a: Date, _ b: Date, ongoing: Bool = false) -> String {
        let end = (ongoing || abs(b.timeIntervalSince(now)) < 30) ? "now" : Self.dayTime(b, relativeTo: a)
        return "\(Self.dayTime(a, relativeTo: now)) – \(end) (\(WatchFormat.duration(b.timeIntervalSince(a))))"
    }

    /// "13:05" for today (or the same day as `reference`), else "Thu 13:05".
    private static func dayTime(_ d: Date, relativeTo reference: Date) -> String {
        let time = d.formatted(date: .omitted, time: .shortened)
        if Calendar.current.isDate(d, inSameDayAs: reference) { return time }
        return "\(d.formatted(.dateTime.weekday(.abbreviated))) \(time)"
    }
}

/// One day as a horizontal bar: green where online, a "now" tick on today, the future dimmed.
struct PresenceStrip: View {
    let day: DateInterval
    /// Effective presence intervals (any range; clipped here).
    let segments: [DateInterval]
    let now: Date
    var height: CGFloat = 12
    @Binding var hover: Date?

    var body: some View {
        GeometryReader { geo in
            canvas
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let p):
                        let f = min(1, max(0, p.x / max(geo.size.width, 1)))
                        hover = day.start.addingTimeInterval(day.duration * f)
                    case .ended:
                        hover = nil
                    }
                }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel(accessibilityText)
    }

    private var canvas: some View {
        Canvas { ctx, size in
            let w = size.width
            let total = day.duration
            func x(_ d: Date) -> CGFloat { CGFloat(d.timeIntervalSince(day.start) / total) * w }
            let radius = min(height / 2, 4)
            let track = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: radius)
            ctx.fill(track, with: .color(.secondary.opacity(0.16)))
            ctx.clip(to: track)
            if now < day.end {
                let fx = max(0, x(now))
                ctx.fill(
                    Path(CGRect(x: fx, y: 0, width: w - fx, height: size.height)),
                    with: .color(.secondary.opacity(0.07)))
            }
            for seg in segments {
                guard let c = seg.clipped(to: day) else { continue }
                // At least 2 pt wide, so short sightings stay visible.
                let x0 = x(c.start)
                let width = max(2, x(c.end) - x0)
                ctx.fill(Path(CGRect(x: x0, y: 0, width: width, height: size.height)), with: .color(.green))
            }
            for hourMark in [6.0, 12, 18] {
                let hx = CGFloat(hourMark / 24) * w
                ctx.fill(
                    Path(CGRect(x: hx - 0.25, y: 0, width: 0.5, height: size.height)),
                    with: .color(.primary.opacity(0.12)))
            }
            if day.contains(now) {
                let nx = x(now)
                ctx.fill(
                    Path(CGRect(x: nx - 0.75, y: 0, width: 1.5, height: size.height)),
                    with: .color(.primary.opacity(0.7)))
            }
            if let hover, day.contains(hover) {
                let hx = x(hover)
                ctx.fill(Path(CGRect(x: hx - 0.5, y: 0, width: 1, height: size.height)), with: .color(.accentColor))
            }
        }
    }

    private var accessibilityText: String {
        let online = segments.compactMap { $0.clipped(to: day) }.reduce(0) { $0 + $1.duration }
        return "Online \(WatchFormat.duration(online)) on \(day.start.formatted(date: .abbreviated, time: .omitted))"
    }
}

/// 00 · 06 · 12 · 18 · 24 labels under a day strip, each centred on its hour (ends aligned to the edges).
private struct HourAxis: View {
    var body: some View {
        GeometryReader { geo in
            ForEach([0, 6, 12, 18, 24], id: \.self) { h in
                Text(String(format: "%02d", h))
                    .fixedSize()
                    .frame(width: 24, alignment: h == 0 ? .leading : h == 24 ? .trailing : .center)
                    .position(x: min(max(12, geo.size.width * CGFloat(h) / 24), geo.size.width - 12), y: 6)
            }
        }
        .frame(height: 12)
        .font(.system(size: 9).monospacedDigit())
        .foregroundStyle(.tertiary)
    }
}

/// Today's presence as a compact strip for the device table's optional "Today" column.
struct PresenceTodayCell: View {
    let presence: [PresenceInterval]

    var body: some View {
        TimelineView(.periodic(from: .now, by: 300)) { context in
            let now = context.date
            let day = PresenceCalendar.days(count: 1, now: now).last ?? DateInterval(start: now, duration: 86_400)
            PresenceStrip(
                day: day, segments: presence.effective(now: now, gap: AppSettings.presenceGap), now: now,
                height: 8, hover: .constant(nil)
            )
            .help(helpText(now: now, day: day))
        }
    }

    private func helpText(now: Date, day: DateInterval) -> String {
        let online = presence.segments(in: day, now: now, gap: AppSettings.presenceGap).reduce(0) { $0 + $1.duration }
        return presence.isEmpty ? "No presence recorded" : "Online \(WatchFormat.duration(online)) today"
    }
}
