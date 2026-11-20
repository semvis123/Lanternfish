import Foundation

// MARK: - Outages

/// A stretch during which a watched device didn't answer. `end` is nil while it is ongoing.
public struct OutageEvent: Codable, Sendable, Hashable {
    public var start: Date
    public var end: Date?

    public init(start: Date, end: Date? = nil) {
        self.start = start
        self.end = end.map { max(start, $0) }
    }

    public var isOngoing: Bool { end == nil }

    public func duration(now: Date) -> TimeInterval {
        max(0, (end ?? now).timeIntervalSince(start))
    }

    public func interval(now: Date) -> DateInterval {
        DateInterval(start: start, end: max(start, end ?? now))
    }
}

public enum WatchPolicy {
    public static let defaultInterval: TimeInterval = 30
    public static let defaultFailureThreshold = 3
    public static let intervalChoices: [Int] = [15, 30, 60, 120]
    public static let failureThresholdRange = 2...5
    /// Outages that ended longer ago are dropped.
    public static let retention: TimeInterval = 30 * 86_400
    public static let maxOutages = 500
    /// At most this many "not monitored" stretches per device (oldest dropped first).
    public static let maxUnmonitored = 500

    /// A check arriving longer than this after the previous one means monitoring lapsed in
    /// between (app not running, Mac asleep, network disconnected): 3 intervals, at least 2 min.
    public static func monitoringLapse(interval: TimeInterval) -> TimeInterval {
        max(120, 3 * interval)
    }

    /// Lapse used when the check interval isn't known (the longest selectable one).
    public static var defaultMonitoringLapse: TimeInterval {
        monitoringLapse(interval: TimeInterval(intervalChoices.max() ?? 120))
    }
}

extension Array where Element == OutageEvent {
    /// The ongoing outage, if any (always the last one).
    public var ongoing: OutageEvent? { last.flatMap { $0.isOngoing ? $0 : nil } }

    /// Starts an outage at `start` unless one is already ongoing.
    public mutating func begin(at start: Date, now: Date? = nil) {
        guard ongoing == nil else { return }
        if let lastEnd = last?.end, start < lastEnd {
            append(OutageEvent(start: lastEnd))
        } else {
            append(OutageEvent(start: start))
        }
        prune(now: now ?? start)
    }

    /// Ends the ongoing outage at `end`. Returns it (closed), or nil when none was ongoing.
    @discardableResult
    public mutating func end(at end: Date) -> OutageEvent? {
        guard let i = indices.last, self[i].isOngoing else { return nil }
        self[i].end = Swift.max(self[i].start, end)
        return self[i]
    }

    public mutating func prune(
        now: Date, retention: TimeInterval = WatchPolicy.retention,
        maxCount: Int = WatchPolicy.maxOutages
    ) {
        let cutoff = now.addingTimeInterval(-retention)
        removeAll { ($0.end ?? now) < cutoff }
        if count > maxCount { removeFirst(count - maxCount) }
    }
}

// MARK: - Uptime

public enum Uptime {
    /// Share of `window` the device was up (0...1), counting only the part since monitoring began
    /// (`monitoredSince`) and up to `now`. Nil when none of the window was monitored.
    /// Time in `unmonitored` (the app wasn't checking) counts neither as up nor as down.
    public static func fraction(
        outages: [OutageEvent], window: DateInterval, monitoredSince: Date?,
        now: Date, unmonitored: [DateInterval] = []
    ) -> Double? {
        let start = max(window.start, monitoredSince ?? window.start)
        let end = min(window.end, now)
        guard end > start else { return nil }
        let observed = DateInterval(start: start, end: end)
        let gaps = union(unmonitored.compactMap { $0.clipped(to: observed) })
        let monitored = observed.duration - gaps.reduce(0) { $0 + $1.duration }
        guard monitored > 0 else { return nil }
        let down = union(outages.compactMap { $0.interval(now: now).clipped(to: observed) })
        let downTotal = down.reduce(0) { $0 + $1.duration } - overlap(down, gaps)
        return max(0, min(1, 1 - downTotal / monitored))
    }

    /// Sorted, non-overlapping cover of `intervals`.
    private static func union(_ intervals: [DateInterval]) -> [DateInterval] {
        var out: [DateInterval] = []
        for iv in intervals.filter({ $0.duration > 0 }).sorted(by: { $0.start < $1.start }) {
            if let last = out.last, iv.start <= last.end {
                out[out.count - 1] = DateInterval(start: last.start, end: max(last.end, iv.end))
            } else {
                out.append(iv)
            }
        }
        return out
    }

    /// Total overlap of two sorted, non-overlapping interval lists.
    private static func overlap(_ a: [DateInterval], _ b: [DateInterval]) -> TimeInterval {
        var i = 0
        var j = 0
        var total: TimeInterval = 0
        while i < a.count, j < b.count {
            let s = max(a[i].start, b[j].start)
            let e = min(a[i].end, b[j].end)
            if e > s { total += e.timeIntervalSince(s) }
            if a[i].end < b[j].end { i += 1 } else { j += 1 }
        }
        return total
    }

    /// Total outage time within `window` (overlapping outages counted once).
    public static func downtime(outages: [OutageEvent], in window: DateInterval, now: Date) -> TimeInterval {
        let clipped = outages.compactMap { $0.interval(now: now).clipped(to: window) }
            .filter { $0.duration > 0 }
            .sorted { $0.start < $1.start }
        var total: TimeInterval = 0
        var cursor = window.start
        for iv in clipped {
            let s = max(iv.start, cursor)
            if iv.end > s { total += iv.end.timeIntervalSince(s) }
            cursor = max(cursor, iv.end)
        }
        return total
    }

    /// "99.8%", "100%", "0%".
    public static func format(_ fraction: Double) -> String {
        let p = fraction * 100
        if p >= 100 { return "100%" }
        if p <= 0 { return "0%" }
        // Never round a real outage up to "100%".
        return String(format: "%.1f%%", min(p, 99.9))
    }
}

// MARK: - State machine

public enum WatchStatus: String, Sendable, Codable {
    /// Not checked yet (or not monitored right now).
    case unknown
    case up
    case down
}

/// What a check result changed.
public enum WatchTransition: Sendable, Equatable {
    /// Became reachable for the first time since monitoring started (no alert).
    case firstUp
    /// Declared down after the failure threshold; `since` is the first failed check.
    case wentDown(since: Date)
    /// Answered again after being down since `since`.
    case cameBack(downSince: Date, at: Date)

    public var outageDuration: TimeInterval? {
        if case .cameBack(let since, let at) = self { return at.timeIntervalSince(since) }
        return nil
    }
}

/// Up/down detection for one watched device: DOWN after `threshold` consecutive failed checks
/// (dated from the first of them), UP on the first successful check after that.
public struct WatchState: Sendable, Equatable {
    public private(set) var status: WatchStatus
    public private(set) var consecutiveFailures = 0
    /// First failure of the current failing run.
    public private(set) var firstFailureAt: Date?
    /// Set while `status == .down`.
    public private(set) var downSince: Date?
    public private(set) var lastSuccessAt: Date?
    public private(set) var lastCheckAt: Date?

    /// Fresh state; resumes as down when `ongoingOutageSince` is set (an outage left open by a
    /// previous run), so it isn't announced again.
    public init(ongoingOutageSince: Date? = nil) {
        status = ongoingOutageSince == nil ? .unknown : .down
        downSince = ongoingOutageSince
    }

    /// Feeds one check result. Returns the transition it caused, if any.
    public mutating func observe(
        success: Bool, at date: Date,
        threshold: Int = WatchPolicy.defaultFailureThreshold
    ) -> WatchTransition? {
        lastCheckAt = date
        if success {
            lastSuccessAt = date
            consecutiveFailures = 0
            firstFailureAt = nil
            switch status {
            case .up: return nil
            case .unknown:
                status = .up
                return .firstUp
            case .down:
                let since = downSince ?? date
                status = .up
                downSince = nil
                return .cameBack(downSince: since, at: date)
            }
        }
        consecutiveFailures += 1
        if firstFailureAt == nil { firstFailureAt = date }
        guard status != .down, consecutiveFailures >= max(1, threshold) else { return nil }
        let since = firstFailureAt ?? date
        status = .down
        downSince = since
        return .wentDown(since: since)
    }
}

// MARK: - History

extension HistoryStore {
    /// Watches or unwatches a device. Starting a watch resets `watchedSince`; stopping closes an
    /// ongoing outage.
    public mutating func setWatched(_ on: Bool, key: String, networkID: String, now: Date = Date()) {
        updateDevice(key: key, networkID: networkID) { rec in
            guard rec.isWatched != on else { return }
            rec.isWatched = on
            if on {
                rec.watchedSince = now
                rec.watchCheckedAt = nil
            } else {
                rec.outages.end(at: now)
            }
        }
    }

    /// Every watched device, as (network id, device key).
    public var watchedDevices: [(networkID: String, key: String)] {
        networks.values.flatMap { net in
            net.devices.values.filter(\.isWatched).map { (net.id, $0.key) }
        }
    }
}

extension KnownDevice {
    /// Uptime over the `seconds` before `now` (nil: not watched during that time). Stretches the
    /// app wasn't checking — recorded gaps, and the time since the last check once it is older
    /// than `lapse` — are left out.
    public func uptime(
        last seconds: TimeInterval, now: Date,
        lapse: TimeInterval = WatchPolicy.defaultMonitoringLapse
    ) -> Double? {
        var gaps = unmonitored
        if let last = watchCheckedAt, now.timeIntervalSince(last) > lapse {
            gaps.append(DateInterval(start: last, end: now))
        }
        return Uptime.fraction(
            outages: outages, window: DateInterval(start: now.addingTimeInterval(-seconds), end: now),
            monitoredSince: watchedSince, now: now, unmonitored: gaps)
    }

    /// Feeds the time of a watch check, before its result is evaluated. When the previous check
    /// is more than `lapse` ago (the app was off, the Mac asleep, the network disconnected), the
    /// stretch in between is recorded as not monitored and an outage still open is closed at that
    /// last (failed) check. Returns true when monitoring lapsed: evaluate from a fresh state, so
    /// the device isn't announced as "back after 2 d".
    @discardableResult
    public mutating func noteWatchCheck(at date: Date, lapse: TimeInterval) -> Bool {
        defer { watchCheckedAt = max(watchCheckedAt ?? date, date) }
        guard let last = watchCheckedAt else {
            // No check on record (just watched, or a file from before checks were recorded):
            // an outage left open can't be dated further than its start.
            if let open = outages.ongoing { outages.end(at: open.start) }
            return true
        }
        guard date.timeIntervalSince(last) > lapse else { return false }
        pauseMonitoring()
        unmonitored.append(DateInterval(start: last, end: date))
        pruneUnmonitored(now: date)
        presence.closePresence()
        return true
    }

    /// Monitoring stops (the network went away, the app quits): an ongoing outage ends at the last
    /// check, which failed. The time until checks resume is recorded by `noteWatchCheck`.
    public mutating func pauseMonitoring() {
        guard outages.ongoing != nil else { return }
        outages.end(at: watchCheckedAt ?? outages.ongoing?.start ?? Date())
    }

    private mutating func pruneUnmonitored(now: Date) {
        let cutoff = now.addingTimeInterval(-WatchPolicy.retention)
        unmonitored.removeAll { $0.end < cutoff }
        if unmonitored.count > WatchPolicy.maxUnmonitored {
            unmonitored.removeFirst(unmonitored.count - WatchPolicy.maxUnmonitored)
        }
    }
}
