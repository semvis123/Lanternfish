import Foundation

/// Limits on how much history is kept, so `history.json` doesn't grow without bound.
public enum HistoryRetention {
    /// Devices without user data unseen for longer are dropped.
    public static let deviceMaxAge: TimeInterval = 90 * 86_400
    /// Networks unseen for longer are dropped, unless renamed or holding labeled devices.
    public static let networkMaxAge: TimeInterval = 180 * 86_400
    /// At most this many devices per network (the oldest ones without user data go first).
    public static let maxDevicesPerNetwork = 2_000
    /// Host names too generic to tell two devices apart (left alone by private-MAC folding).
    fileprivate static let genericNames: Set<String> = [
        "iphone", "ipad", "ipod", "android", "localhost", "unknown", "galaxy", "macbook", "macbook-pro",
        "macbook-air", "imac", "mac", "watch", "apple-watch", "espressif", "esp32", "esp8266", "phone",
        "tablet", "laptop", "desktop", "pc", "tv", "chromecast", "printer", "host", "device",
    ]
}

/// What `HistoryStore.compact` removed.
public struct CompactionReport: Sendable, Equatable {
    public var droppedNetworks = 0
    public var droppedDevices = 0
    /// Records of rotated private MACs folded into the device's newer record.
    public var foldedDevices = 0

    public init() {}

    public var isEmpty: Bool { droppedNetworks == 0 && droppedDevices == 0 && foldedDevices == 0 }
}

extension KnownDevice {
    /// Something the user set (name, type, notes, watching): never dropped automatically.
    public var hasUserData: Bool { customName != nil || customKind != nil || notes != nil || isWatched }

    /// Host name or name identifying a device across private-MAC rotations (lowercased, without
    /// ".local" & co.), when specific enough.
    fileprivate var rotationIdentity: String? {
        for raw in [hostname, name] {
            guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !trimmed.isEmpty
            else { continue }
            let s = trimmed.strippingLocalDomain()
            guard s.count >= 4, !HistoryRetention.genericNames.contains(s) else { continue }
            return s
        }
        return nil
    }

    fileprivate var hasPrivateMAC: Bool { !isIPKeyed && (mac.flatMap(MACAddress.init)?.isLocallyAdministered ?? false) }
}

extension HistoryStore {
    /// Applies `HistoryRetention`:
    /// - folds records of a device that rotated its private MAC (same specific host name, never
    ///   seen at the same time, no conflicting labels) into the newest one;
    /// - drops devices without user data unseen for `deviceMaxAge`, then the oldest of those
    ///   beyond `maxDevicesPerNetwork`;
    /// - drops networks unseen for `networkMaxAge` unless renamed or holding labeled devices.
    @discardableResult
    public mutating func compact(now: Date = Date()) -> CompactionReport {
        var report = CompactionReport()
        let deviceCutoff = now.addingTimeInterval(-HistoryRetention.deviceMaxAge)
        let networkCutoff = now.addingTimeInterval(-HistoryRetention.networkMaxAge)
        for id in Array(networks.keys) {
            guard var net = networks[id] else { continue }
            if net.lastSeen < networkCutoff, net.customName == nil, !net.devices.values.contains(where: \.hasUserData) {
                networks[id] = nil
                report.droppedNetworks += 1
                continue
            }
            var changed = false
            let folded = Self.foldRotatedMACs(&net.devices)
            if folded > 0 {
                report.foldedDevices += folded
                changed = true
            }

            let stale = net.devices.values.filter { !$0.hasUserData && $0.lastSeen < deviceCutoff }.map(\.key)
            for key in stale { net.devices[key] = nil }
            report.droppedDevices += stale.count
            changed = changed || !stale.isEmpty

            let excess = net.devices.count - HistoryRetention.maxDevicesPerNetwork
            if excess > 0 {
                let victims = net.devices.values.filter { !$0.hasUserData && !$0.isSelf }
                    .sorted { $0.lastSeen < $1.lastSeen }.prefix(excess).map(\.key)
                for key in victims { net.devices[key] = nil }
                report.droppedDevices += victims.count
                changed = changed || !victims.isEmpty
            }
            if changed { networks[id] = net }
        }
        return report
    }

    /// Folds chains of private-MAC records sharing a rotation identity, where each one was last
    /// seen before the next was first seen. Returns how many records were folded away.
    static func foldRotatedMACs(_ devices: inout [String: KnownDevice]) -> Int {
        var groups: [String: [KnownDevice]] = [:]
        for d in devices.values where d.hasPrivateMAC && !d.isSelf {
            if let id = d.rotationIdentity { groups[id, default: []].append(d) }
        }
        var folded = 0
        for (_, group) in groups where group.count > 1 {
            let ordered = group.sorted { $0.firstSeen != $1.firstSeen ? $0.firstSeen < $1.firstSeen : $0.key < $1.key }
            var acc = ordered[0]
            for next in ordered.dropFirst() {
                guard acc.lastSeen < next.firstSeen, labelsCompatible(acc, next) else {
                    acc = next
                    continue
                }
                var merged = next
                merged.absorb(acc)
                devices[acc.key] = nil
                devices[merged.key] = merged
                acc = merged
                folded += 1
            }
        }
        return folded
    }

    private static func labelsCompatible(_ a: KnownDevice, _ b: KnownDevice) -> Bool {
        func ok<T: Equatable>(_ x: T?, _ y: T?) -> Bool { x == nil || y == nil || x == y }
        return ok(a.customName, b.customName) && ok(a.customKind, b.customKind) && ok(a.notes, b.notes)
    }
}
