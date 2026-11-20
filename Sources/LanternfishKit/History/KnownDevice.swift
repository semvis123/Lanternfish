import Foundation

/// A device remembered on one network: identity, the user's labels, and a snapshot of what
/// the last scans found, so offline devices still show useful information.
public struct KnownDevice: Codable, Sendable, Hashable, Identifiable {
    /// `"mac:AA:BB:CC:DD:EE:FF"`, or `"ip:192.168.1.5"` while the MAC is unknown.
    public var key: String
    public var id: String { key }
    public var mac: String?
    public var lastIP: String
    public var customName: String?
    public var customKind: DeviceKind?
    public var notes: String?
    public var firstSeen: Date
    public var lastSeen: Date
    /// False for devices that showed up on an already-known network and haven't been looked at.
    public var acknowledged: Bool
    public var isSelf: Bool

    // Snapshot of the last identification.
    public var vendor: String?
    public var manufacturer: String?
    public var model: String?
    public var hostname: String?
    public var name: String?
    public var kind: DeviceKind
    public var osHint: String?
    public var webTitle: String?
    public var openPorts: [OpenPort]
    public var services: [String]
    /// Fingerprint confidence (0...1) and evidence from the last identification.
    public var confidence: Double?
    public var identificationReasons: [String] = []

    // MARK: Presence & watching (see Presence.swift, Watch.swift)

    /// When the device was online, oldest first (at most 30 days).
    public var presence: [PresenceInterval] = []
    /// Monitored continuously by the watch monitor.
    public var isWatched: Bool = false
    /// When watching (last) started; uptime is measured from here.
    public var watchedSince: Date?
    /// Outages the watch monitor detected, oldest first (at most 30 days).
    public var outages: [OutageEvent] = []
    /// The watch monitor's last check (success or not). Nil until one ran since watching started.
    public var watchCheckedAt: Date?
    /// Stretches while watched during which nothing was checked (app off, asleep, disconnected);
    /// left out of uptime. Oldest first (at most 30 days).
    public var unmonitored: [DateInterval] = []

    public init(
        key: String, mac: String? = nil, lastIP: String, firstSeen: Date, lastSeen: Date,
        acknowledged: Bool = true
    ) {
        self.key = key
        self.mac = mac
        self.lastIP = lastIP
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
        self.acknowledged = acknowledged
        self.isSelf = false
        self.kind = .unknown
        self.openPorts = []
        self.services = []
    }

    private static let macKeyPrefix = "mac:"
    private static let ipKeyPrefix = "ip:"

    /// History key for a live device: its MAC, else its IP.
    public static func key(for device: Device) -> String {
        if let mac = device.mac { return macKey(mac.description) }
        return ipKey(device.ip)
    }

    /// History key for a MAC address string (as stored in `mac` / `KnownNetwork.gatewayMAC`).
    static func macKey(_ mac: String) -> String { macKeyPrefix + mac }

    public static func ipKey(_ ip: IPv4Address) -> String { ipKeyPrefix + ip.description }

    public var isIPKeyed: Bool { key.hasPrefix(Self.ipKeyPrefix) }

    /// Ports a normal scan checks: a completed scan replaces only these, so ports a full port scan
    /// found elsewhere survive the next normal scan.
    static let normallyScannedPorts = Set(CommonPorts.sortedPorts)

    /// Updates the identification snapshot from a live device. Non-empty values overwrite;
    /// ports and services are unioned, or replaced when `replaceCollections` (after a completed
    /// scan; ports only within `normallyScannedPorts`).
    public mutating func updateSnapshot(from d: Device, replaceCollections: Bool) {
        func set(_ field: inout String?, _ value: String?) {
            if let value, !value.isEmpty { field = value }
        }
        if let m = d.mac { mac = m.description }
        lastIP = d.ip.description
        isSelf = d.isSelf
        set(&vendor, d.vendor)
        set(&manufacturer, d.manufacturer)
        set(&model, d.model)
        set(&hostname, d.hostname)
        set(&name, d.name)
        set(&osHint, d.osHint)
        set(&webTitle, d.webTitle)
        if d.kind != .unknown { kind = d.kind }
        // A weak re-identification (e.g. the device is quiet right now) doesn't replace a good one.
        if let c = d.confidence, !d.identificationReasons.isEmpty, c >= 0.5 || c >= (confidence ?? 0) {
            confidence = c
            identificationReasons = d.identificationReasons
        }
        if replaceCollections {
            let kept = openPorts.filter { !Self.normallyScannedPorts.contains($0.port) }
            openPorts = Array(Set(kept).union(d.openPorts)).sorted()
            services = d.services.sorted()
        } else {
            openPorts = Array(Set(openPorts).union(d.openPorts)).sorted()
            services = Array(Set(services).union(d.services)).sorted()
        }
    }

    /// Copies the user's labels and history dates onto a device.
    public func annotate(_ d: inout Device) {
        d.historyKey = key
        d.customName = customName
        d.customKind = customKind
        d.notes = notes
        d.firstSeen = firstSeen
        d.lastSeen = lastSeen
        d.isNew = !acknowledged
    }

    /// Fills a live device's empty identification fields from the snapshot (for display while a
    /// scan is still discovering names). Ports and services stay live-only.
    public func fillGaps(_ d: inout Device) {
        func fill(_ field: inout String?, _ value: String?) {
            if field?.isEmpty ?? true, let value, !value.isEmpty { field = value }
        }
        fill(&d.vendor, vendor)
        fill(&d.manufacturer, manufacturer)
        fill(&d.model, model)
        fill(&d.hostname, hostname)
        fill(&d.name, name)
        fill(&d.osHint, osHint)
        fill(&d.webTitle, webTitle)
        if d.kind == .unknown { d.kind = kind }
        if d.mac == nil, let mac { d.mac = MACAddress(mac) }
        if let confidence, confidence > (d.confidence ?? -1), !identificationReasons.isEmpty {
            d.confidence = confidence
            d.identificationReasons = identificationReasons
        }
        NameCleanup.sanitize(&d)
    }

    /// The remembered device as an offline row.
    public func offlineDevice() -> Device {
        var d = Device(ip: IPv4Address(lastIP) ?? IPv4Address(0))
        d.mac = mac.flatMap(MACAddress.init)
        d.vendor = vendor
        d.manufacturer = manufacturer
        d.model = model
        d.hostname = hostname
        d.name = name
        d.kind = kind
        d.osHint = osHint
        d.webTitle = webTitle
        d.openPorts = openPorts.sorted()
        d.services = Set(services)
        d.isSelf = isSelf
        d.isOnline = false
        d.confidence = confidence
        d.identificationReasons = identificationReasons
        NameCleanup.sanitize(&d)
        // Recorded before fingerprinting existed: identify from the snapshot now.
        if confidence == nil, !isSelf {
            let id = Fingerprint.identify(d)
            if id.signature != nil {
                d.confidence = id.confidence
                d.identificationReasons = id.reasons
                if id.confidence >= 0.5 {
                    if d.manufacturer == nil { d.manufacturer = id.manufacturer }
                    if d.model?.isEmpty ?? true { d.model = id.model }
                }
                if d.kind == .unknown, let k = id.kind, id.confidence >= 0.45 { d.kind = k }
            }
        }
        annotate(&d)
        return d
    }

    // MARK: Codable (every field but the key is optional on decode, so new fields never break old files)

    private enum CodingKeys: String, CodingKey {
        case key, mac, lastIP, customName, customKind, notes, firstSeen, lastSeen, acknowledged, isSelf
        case vendor, manufacturer, model, hostname, name, kind, osHint, webTitle, openPorts, services
        case confidence, identificationReasons
        case presence, isWatched, watchedSince, outages, watchCheckedAt, unmonitored
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        mac = try c.decodeIfPresent(String.self, forKey: .mac)
        lastIP =
            try c.decodeIfPresent(String.self, forKey: .lastIP)
            ?? (key.hasPrefix(Self.ipKeyPrefix) ? String(key.dropFirst(Self.ipKeyPrefix.count)) : "0.0.0.0")
        customName = try c.decodeIfPresent(String.self, forKey: .customName)
        customKind = try c.decodeIfPresent(DeviceKind.self, forKey: .customKind)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        let now = Date()
        firstSeen = try c.decodeIfPresent(Date.self, forKey: .firstSeen) ?? now
        lastSeen = try c.decodeIfPresent(Date.self, forKey: .lastSeen) ?? firstSeen
        acknowledged = try c.decodeIfPresent(Bool.self, forKey: .acknowledged) ?? true
        isSelf = try c.decodeIfPresent(Bool.self, forKey: .isSelf) ?? false
        vendor = try c.decodeIfPresent(String.self, forKey: .vendor)
        manufacturer = try c.decodeIfPresent(String.self, forKey: .manufacturer)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        hostname = try c.decodeIfPresent(String.self, forKey: .hostname)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        kind = try c.decodeIfPresent(DeviceKind.self, forKey: .kind) ?? .unknown
        osHint = try c.decodeIfPresent(String.self, forKey: .osHint)
        webTitle = try c.decodeIfPresent(String.self, forKey: .webTitle)
        openPorts = (try? c.decodeIfPresent([OpenPort].self, forKey: .openPorts)) ?? []
        services = (try? c.decodeIfPresent([String].self, forKey: .services)) ?? []
        confidence = try? c.decodeIfPresent(Double.self, forKey: .confidence)
        identificationReasons = (try? c.decodeIfPresent([String].self, forKey: .identificationReasons)) ?? []
        presence = ((try? c.decodeIfPresent([Lossy<PresenceInterval>].self, forKey: .presence)) ?? [])
            .compactMap(\.value).normalized()
        isWatched = (try? c.decodeIfPresent(Bool.self, forKey: .isWatched)) ?? false
        watchedSince = try? c.decodeIfPresent(Date.self, forKey: .watchedSince)
        outages = ((try? c.decodeIfPresent([Lossy<OutageEvent>].self, forKey: .outages)) ?? [])
            .compactMap(\.value).sorted { $0.start < $1.start }
        watchCheckedAt = try? c.decodeIfPresent(Date.self, forKey: .watchCheckedAt)
        unmonitored = ((try? c.decodeIfPresent([Lossy<DateInterval>].self, forKey: .unmonitored)) ?? [])
            .compactMap(\.value).sorted { $0.start < $1.start }
    }
}
