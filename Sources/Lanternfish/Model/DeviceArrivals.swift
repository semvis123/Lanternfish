import Foundation
import LanternfishKit
import Observation

/// Live presence changes of one network worth animating: devices that came online during a scan
/// that weren't online before it (arrivals) and ones the finished scan no longer found
/// (departures). Fed by `ScanStore`; read by the table (row highlight) and the map (pulse rings).
///
/// Its own observable object, so an arrival only re-renders the views that read it, not every
/// observer of the store. Holds no timers: views compare event times with the clock themselves.
@MainActor
@Observable
final class DeviceArrivals {
    struct Event: Equatable, Sendable {
        /// Increases with every event (consumers remember the last one they handled).
        var seq: Int
        /// `DeviceArrivals.key(for:)` of the device.
        var key: String
        /// true: came online; false: went offline.
        var online: Bool
        var at: Date
    }

    /// How long an arrived row stays highlighted.
    static let highlightDuration: TimeInterval = 1.5
    /// Events older than this are dropped (nothing animates them any more).
    private static let retention: TimeInterval = 10
    private static let maxEvents = 64

    /// Recent events, oldest first.
    private(set) var events: [Event] = []
    /// When each recently arrived device came online (departures remove their entry).
    private(set) var arrivedAt: [String: Date] = [:]
    @ObservationIgnored private var seq = 0

    /// The identity presence is tracked by: the history record when there is one, else the address.
    nonisolated static func key(for d: Device) -> String { d.historyKey ?? d.ip.description }

    /// When `d` arrived, if that was recent enough to still highlight it.
    func highlightStart(for d: Device, now: Date = Date()) -> Date? {
        guard d.isOnline, let at = arrivedAt[Self.key(for: d)],
            now.timeIntervalSince(at) < Self.highlightDuration
        else { return nil }
        return at
    }

    func record(_ keys: [String], online: Bool) {
        guard !keys.isEmpty else { return }
        let now = Date()
        var events = self.events.filter { now.timeIntervalSince($0.at) < Self.retention }
        var arrived = arrivedAt.filter { now.timeIntervalSince($0.value) < Self.retention }
        for key in keys {
            seq &+= 1
            events.append(Event(seq: seq, key: key, online: online, at: now))
            arrived[key] = online ? now : nil
        }
        if events.count > Self.maxEvents { events.removeFirst(events.count - Self.maxEvents) }
        self.events = events
        arrivedAt = arrived
    }
}
