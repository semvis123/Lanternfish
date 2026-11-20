import Foundation

// MARK: - Interval

/// A stretch of time a device was seen online: from its first sighting to its last one.
/// An *open* interval may still grow — the next sighting within the gap threshold extends it;
/// it is closed when a completed scan (or the watch monitor) no longer finds the device.
public struct PresenceInterval: Codable, Sendable, Hashable {
    public var start: Date
    /// The last sighting (for an open interval: so far).
    public var end: Date
    public var isOpen: Bool

    public init(start: Date, end: Date, isOpen: Bool = false) {
        self.start = start
        self.end = max(start, end)
        self.isOpen = isOpen
    }

    public var duration: TimeInterval { end.timeIntervalSince(start) }

    private enum CodingKeys: String, CodingKey {
        case start, end
        case isOpen = "open"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        start = try c.decode(Date.self, forKey: .start)
        end = max(start, try c.decodeIfPresent(Date.self, forKey: .end) ?? start)
        isOpen = try c.decodeIfPresent(Bool.self, forKey: .isOpen) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(start, forKey: .start)
        try c.encode(end, forKey: .end)
        if isOpen { try c.encode(true, forKey: .isOpen) }
    }
}

// MARK: - Policy

/// Thresholds for recording presence.
public enum PresencePolicy {
    /// Smallest gap threshold: sightings further apart than this start a new interval.
    public static let minimumGap: TimeInterval = 10 * 60
    /// A closed interval followed by a sighting within this time is reopened instead of starting a
    /// new one (a scan that briefly missed the device, a ping that answered right after).
    public static let mergeGap: TimeInterval = 2 * 60
    /// Intervals that ended longer ago are dropped.
    public static let retention: TimeInterval = 30 * 86_400
    /// At most this many intervals per device (oldest dropped first).
    public static let maxIntervals = 1_500

    /// Gap threshold for an automatic-scan interval: 2× the interval, at least `minimumGap`.
    /// `nil` / 0 (automatic scans off) gives `minimumGap`.
    public static func gap(autoScanInterval: TimeInterval?) -> TimeInterval {
        max(minimumGap, 2 * (autoScanInterval ?? 0))
    }
}

// MARK: - Recording

extension Array where Element == PresenceInterval {
    /// Records that the device was seen at `date`: extends the open interval when the last sighting
    /// is at most `gap` ago, reopens a closed one that ended at most `PresencePolicy.mergeGap` ago,
    /// otherwise starts a new interval. Sightings older than the last interval's end are ignored.
    /// `reopenWithin` overrides the merge gap (0: never reopen, e.g. after a detected outage).
    public mutating func recordSighting(
        at date: Date, gap: TimeInterval,
        reopenWithin: TimeInterval = PresencePolicy.mergeGap
    ) {
        if var last = self.last {
            // Out of order (a late result, clock change): already covered or too old to place.
            if date < last.end { return }
            let since = date.timeIntervalSince(last.end)
            if (last.isOpen && since <= gap) || (!last.isOpen && since <= Swift.min(gap, reopenWithin)) {
                last.end = date
                last.isOpen = true
                self[endIndex - 1] = last
                return
            }
            if last.isOpen {
                last.isOpen = false
                self[endIndex - 1] = last
            }
        }
        append(PresenceInterval(start: date, end: date, isOpen: true))
        prune(now: date)
    }

    /// Closes the open interval (the device was looked for and not found). Its end stays the last sighting.
    public mutating func closePresence() {
        guard let i = indices.last, self[i].isOpen else { return }
        self[i].isOpen = false
    }

    /// Drops intervals that ended before the retention window and caps the count.
    public mutating func prune(
        now: Date, retention: TimeInterval = PresencePolicy.retention,
        maxCount: Int = PresencePolicy.maxIntervals
    ) {
        let cutoff = now.addingTimeInterval(-retention)
        if let first = first, first.end < cutoff { removeAll { $0.end < cutoff } }
        if count > maxCount { removeFirst(count - maxCount) }
    }

    /// Sorted, non-overlapping copy (merges overlaps and intervals at most `mergeGap` apart).
    /// Repairs data from older files or merged duplicate records.
    public func normalized(mergeGap: TimeInterval = PresencePolicy.mergeGap) -> [PresenceInterval] {
        var out: [PresenceInterval] = []
        for iv in sorted(by: { $0.start < $1.start }) {
            if var last = out.last, iv.start.timeIntervalSince(last.end) <= mergeGap {
                if iv.end >= last.end {
                    last.end = iv.end
                    last.isOpen = iv.isOpen
                } else {
                    last.isOpen = last.isOpen || iv.isOpen
                }
                out[out.count - 1] = last
            } else {
                out.append(iv)
            }
        }
        // Only the newest interval can be open.
        for i in out.indices.dropLast() { out[i].isOpen = false }
        return out
    }

    // MARK: Queries

    /// The intervals as displayed at `now`: an open interval whose last sighting is at most `gap`
    /// ago is shown as lasting until `now` (the device is presumably still there); a stale open one
    /// ends at its last sighting.
    public func effective(now: Date, gap: TimeInterval) -> [DateInterval] {
        compactMap { iv in
            var end = iv.end
            if iv.isOpen, now.timeIntervalSince(iv.end) <= gap, now > end { end = now }
            guard end >= iv.start else { return nil }
            return DateInterval(start: iv.start, end: end)
        }
    }

    /// The effective intervals clipped to `window`.
    public func segments(in window: DateInterval, now: Date, gap: TimeInterval) -> [DateInterval] {
        effective(now: now, gap: gap).compactMap { $0.clipped(to: window) }
    }

    /// Whether the device counts as online at `now`.
    public func isPresent(now: Date, gap: TimeInterval) -> Bool {
        guard let last, last.isOpen else { return false }
        return now.timeIntervalSince(last.end) <= gap
    }

    /// Summary over `window` (e.g. the last 7 days). See `PresenceStats`.
    public func stats(in window: DateInterval, now: Date, gap: TimeInterval) -> PresenceStats {
        let segs = segments(in: window, now: now, gap: gap)
        let online = segs.reduce(0) { $0 + $1.duration }
        // Measure from the first recorded sighting if tracking began inside the window.
        let observedStart = Swift.max(window.start, first?.start ?? window.end)
        let observedEnd = Swift.min(window.end, now)
        let observed = observedEnd > observedStart ? DateInterval(start: observedStart, end: observedEnd) : nil
        var longestOffline: TimeInterval = 0
        for (a, b) in zip(segs, segs.dropFirst()) {
            longestOffline = Swift.max(longestOffline, b.start.timeIntervalSince(a.end))
        }
        if let last = segs.last, observedEnd > last.end {
            longestOffline = Swift.max(longestOffline, observedEnd.timeIntervalSince(last.end))
        }
        return PresenceStats(
            observed: observed, online: online, sessions: segs.count,
            longestOffline: segs.isEmpty ? nil : longestOffline)
    }
}

/// Presence over a window.
public struct PresenceStats: Sendable, Equatable {
    /// Part of the window presence was tracked (from the first sighting, up to now). Nil: none.
    public var observed: DateInterval?
    /// Total time online within the window.
    public var online: TimeInterval
    /// Online stretches overlapping the window.
    public var sessions: Int
    /// Longest offline stretch between (and after) online stretches within the observed part.
    public var longestOffline: TimeInterval?

    public init(observed: DateInterval?, online: TimeInterval, sessions: Int, longestOffline: TimeInterval?) {
        self.observed = observed
        self.online = online
        self.sessions = sessions
        self.longestOffline = longestOffline
    }

    /// Online share of the observed time, 0...1 (nil when nothing was observed).
    public var onlineFraction: Double? {
        guard let observed, observed.duration > 0 else { return nil }
        return Swift.min(1, Swift.max(0, online / observed.duration))
    }
}

extension DateInterval {
    /// The overlap with `window`, or nil when they don't overlap (touching counts only for instants).
    public func clipped(to window: DateInterval) -> DateInterval? {
        let s = Swift.max(start, window.start)
        let e = Swift.min(end, window.end)
        guard e > s || (e == s && duration == 0 && window.contains(s)) else { return nil }
        return DateInterval(start: s, end: e)
    }
}

// MARK: - Days

public enum PresenceCalendar {
    /// The last `count` calendar days (oldest first), the last one being today (until midnight).
    public static func days(count: Int, now: Date, calendar: Calendar = .current) -> [DateInterval] {
        let today = calendar.startOfDay(for: now)
        return (0..<count).reversed().compactMap { back in
            guard let start = calendar.date(byAdding: .day, value: -back, to: today),
                let end = calendar.date(byAdding: .day, value: 1, to: start)
            else { return nil }
            return DateInterval(start: start, end: end)
        }
    }
}

// MARK: - History

extension HistoryStore {
    /// Records a presence sighting for one device (e.g. a successful watch check).
    public mutating func notePresence(
        key: String, networkID: String, at date: Date, gap: TimeInterval,
        reopenWithin: TimeInterval = PresencePolicy.mergeGap
    ) {
        updateDevice(key: key, networkID: networkID) { rec in
            rec.presence.recordSighting(at: date, gap: gap, reopenWithin: reopenWithin)
            rec.lastSeen = max(rec.lastSeen, date)
        }
    }

    /// Closes one device's open presence interval (e.g. the watch monitor declared it down).
    public mutating func closePresence(key: String, networkID: String) {
        updateDevice(key: key, networkID: networkID) { $0.presence.closePresence() }
    }
}

extension KnownDevice {
    /// Folds a duplicate record's presence, watch flag and outages into this one.
    mutating func absorbMonitoring(_ other: KnownDevice) {
        if !other.presence.isEmpty { presence = (presence + other.presence).normalized() }
        if !other.outages.isEmpty { outages = (outages + other.outages).sorted { $0.start < $1.start } }
        if !other.unmonitored.isEmpty { unmonitored = (unmonitored + other.unmonitored).sorted { $0.start < $1.start } }
        if let o = other.watchCheckedAt { watchCheckedAt = max(watchCheckedAt ?? o, o) }
        if other.isWatched && !isWatched {
            isWatched = true
            watchedSince = other.watchedSince
        }
    }
}
