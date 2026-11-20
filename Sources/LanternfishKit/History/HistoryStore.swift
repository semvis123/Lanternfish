import Foundation

/// Every known network and its devices, plus the pure merge logic between live scan results and
/// history. Persisted as one JSON file (`history.json`) in a directory, written atomically.
public struct HistoryStore: Sendable, Equatable {
    public static let fileName = "history.json"
    public static let currentVersion = 1

    /// Keyed by `KnownNetwork.id`.
    public var networks: [String: KnownNetwork]

    public init(networks: [KnownNetwork] = []) {
        self.networks = Dictionary(networks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    // MARK: Persistence

    /// `~/Library/Application Support/Lanternfish`.
    public static func defaultDirectory() -> URL {
        URL.applicationSupportDirectory.appending(path: "Lanternfish", directoryHint: .isDirectory)
    }

    /// Loads `history.json` from `directory` (see `loadResult(from:)` for the details).
    public static func load(from directory: URL) -> HistoryStore {
        loadResult(from: directory).store
    }

    /// What loading found, and whether the file may be overwritten.
    public struct LoadResult: Sendable {
        public enum Status: Sendable, Equatable {
            /// No file yet.
            case missing
            case loaded
            /// Decoded, but this many networks/devices couldn't be read and were dropped.
            case partial(dropped: Int)
            /// Written by a newer version of the app (fields it added would be lost).
            case newerVersion(Int)
            /// Not valid JSON / not a history file: moved aside to this file name.
            case corrupt(movedTo: String)
            /// Exists but couldn't be read (permissions, I/O): must not be overwritten.
            case unreadable(String)
        }

        public var store: HistoryStore
        public var status: Status
        /// The file's original bytes, to keep as `history-backup-<time>.json` before the first
        /// save would overwrite them with less (partial decode, newer version).
        public var backup: Data?
        /// False when saving would destroy data that couldn't be read.
        public var canSave: Bool { if case .unreadable = status { false } else { true } }
    }

    /// Loads `history.json`. Only a missing file gives a fresh, empty store; an unreadable one
    /// blocks saving; an undecodable one is moved aside (`history-corrupt-<time>.json`); one that
    /// decoded with losses (or comes from a newer version) is returned with a backup to write.
    public static func loadResult(from directory: URL) -> LoadResult {
        let url = directory.appending(path: fileName)
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            if isMissingFile(error) { return LoadResult(store: HistoryStore(), status: .missing) }
            return LoadResult(store: HistoryStore(), status: .unreadable(error.localizedDescription))
        }
        do {
            let (store, stats) = try decodeWithStats(data)
            if let v = stats.version, v > currentVersion {
                return LoadResult(store: store, status: .newerVersion(v), backup: data)
            }
            if stats.dropped > 0 {
                return LoadResult(store: store, status: .partial(dropped: stats.dropped), backup: data)
            }
            return LoadResult(store: store, status: .loaded)
        } catch {
            let name = "history-corrupt-\(Int(Date().timeIntervalSince1970)).json"
            try? FileManager.default.moveItem(at: url, to: directory.appending(path: name))
            return LoadResult(store: HistoryStore(), status: .corrupt(movedTo: name))
        }
    }

    private static func isMissingFile(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain, ns.code == NSFileReadNoSuchFileError { return true }
        if ns.domain == NSPOSIXErrorDomain, ns.code == Int(ENOENT) { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError,
            underlying.domain == NSPOSIXErrorDomain, underlying.code == Int(ENOENT)
        {
            return true
        }
        return false
    }

    public static func decode(_ data: Data) throws -> HistoryStore {
        try decodeWithStats(data).store
    }

    /// Decodes and counts what the tolerant decoding dropped.
    private static func decodeWithStats(_ data: Data) throws -> (
        store: HistoryStore, stats: (version: Int?, dropped: Int)
    ) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let counter = DecodeStats()
        decoder.userInfo[DecodeStats.key] = counter
        let file = try decoder.decode(File.self, from: data)
        let dropped = counter.droppedDevices + file.networks.count { $0.value == nil }
        return (HistoryStore(networks: file.networks.compactMap(\.value)), (file.version, dropped))
    }

    /// Compact JSON (no pretty-printing or key sorting: this is written often and only read back
    /// by the app). Safe to call off the main actor.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let file = FileOut(
            version: Self.currentVersion,
            networks: networks.values.sorted { $0.firstSeen < $1.firstSeen })
        return try encoder.encode(file)
    }

    /// Keeps `data` (an older history file) as `history-backup-<time>.json`. Returns its name.
    @discardableResult
    public static func writeBackup(_ data: Data, to directory: URL, now: Date = Date()) throws -> String {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var name = "history-backup-\(Int(now.timeIntervalSince1970)).json"
        var n = 1
        while FileManager.default.fileExists(atPath: directory.appending(path: name).path) {
            name = "history-backup-\(Int(now.timeIntervalSince1970))-\(n).json"
            n += 1
        }
        try data.write(to: directory.appending(path: name), options: .atomic)
        return name
    }

    /// Atomically writes already-encoded data (safe to call off the main thread).
    public static func write(_ data: Data, to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appending(path: fileName), options: .atomic)
    }

    public func save(to directory: URL) throws {
        try Self.write(try encoded(), to: directory)
    }

    private struct File: Decodable {
        var version: Int?
        var networks: [Lossy<KnownNetwork>]
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            version = try? c.decodeIfPresent(Int.self, forKey: .version)
            networks = try c.decodeIfPresent([Lossy<KnownNetwork>].self, forKey: .networks) ?? []
        }
        enum CodingKeys: String, CodingKey { case version, networks }
    }

    private struct FileOut: Encodable {
        var version: Int
        var networks: [KnownNetwork]
    }

    // MARK: Networks

    /// Finds (or creates) the network for a gateway and subnet and returns its id.
    /// With a gateway MAC: matches that MAC, else adopts a MAC-less network with the same gateway
    /// IP and subnet. Without one: matches gateway IP + subnet (most recently seen first).
    /// A record without a gateway IP but with the same subnet is adopted once a gateway is known.
    public mutating func identifyNetwork(
        gatewayMAC: MACAddress?, gatewayIP: IPv4Address?, subnet: Subnet,
        now: Date = Date()
    ) -> String {
        let cidr = subnet.description
        let ip = gatewayIP?.description
        let byRecency = networks.values.sorted { $0.lastSeen > $1.lastSeen }
        // A record saved before its gateway was known (no gateway IP, e.g. a secondary
        // interface) is the same network once the gateway shows up.
        let sameAddress =
            byRecency.filter { $0.gatewayIP == ip && $0.subnet == cidr }
            + (ip == nil ? [] : byRecency.filter { $0.gatewayIP == nil && $0.subnet == cidr })

        var match: KnownNetwork?
        if let mac = gatewayMAC?.description {
            match = byRecency.first { $0.gatewayMAC == mac } ?? sameAddress.first { $0.gatewayMAC == nil }
        } else {
            match = sameAddress.first { $0.gatewayMAC == nil } ?? sameAddress.first
        }
        var network = match ?? KnownNetwork(subnet: cidr, firstSeen: now)
        if let mac = gatewayMAC?.description { network.gatewayMAC = mac }
        network.gatewayIP = ip
        network.subnet = cidr
        network.lastSeen = now
        networks[network.id] = network
        return network.id
    }

    /// Whether identifying a network with gateway `gatewayIP` should wait for the gateway's MAC:
    /// some remembered network is known by its router's MAC, so matching by address alone could
    /// pick another router's network (same addresses, other place) and record devices into it.
    public func identificationNeedsGatewayMAC(gatewayIP: IPv4Address?) -> Bool {
        gatewayIP != nil && networks.values.contains { $0.gatewayMAC != nil }
    }

    public mutating func renameNetwork(id: String, to name: String?) {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        networks[id]?.customName = trimmed?.isEmpty == false ? trimmed : nil
    }

    public mutating func forgetNetwork(id: String) {
        networks[id] = nil
    }

    public mutating func completeScan(networkID: String, now: Date = Date()) {
        networks[networkID]?.completedScans += 1
        networks[networkID]?.lastSeen = now
    }

    // MARK: Devices

    /// Records live devices as seen `now`. Devices without a MAC are only recorded when
    /// `scanComplete` (by then ARP had its chance); a MAC arriving later migrates the IP-keyed
    /// record. Returns the keys of records created by this call that count as new
    /// (the network had completed a scan before). Records created for `acknowledging` keys (e.g.
    /// devices the user just forgot while they were online) are created already acknowledged.
    ///
    /// `presenceGap` (non-nil while the devices were actually just seen, i.e. during a scan) also
    /// records a presence sighting per device; with `scanComplete` every other device of the network
    /// gets its open presence interval closed (see `Presence.swift`).
    @discardableResult
    public mutating func record(
        _ devices: [Device], networkID: String, now: Date = Date(),
        scanComplete: Bool = false, presenceGap: TimeInterval? = nil,
        acknowledging: Set<String> = []
    ) -> [String] {
        guard var network = networks[networkID] else { return [] }
        var created: [String] = []
        var seenKeys: Set<String> = []
        for d in devices {
            if d.mac == nil && !scanComplete && network.devices[KnownDevice.ipKey(d.ip)] == nil { continue }
            let key = KnownDevice.key(for: d)
            var rec: KnownDevice
            if let existing = network.devices[key] {
                rec = existing
                // A MAC-keyed record exists and an IP-keyed one for the same address was made while
                // the MAC was unknown: fold the latter in.
                if d.mac != nil, let old = network.devices.removeValue(forKey: KnownDevice.ipKey(d.ip)) {
                    rec.absorb(old)
                }
            } else if d.mac != nil, var old = network.devices.removeValue(forKey: KnownDevice.ipKey(d.ip)) {
                old.key = key
                rec = old
            } else {
                rec = KnownDevice(
                    key: key, lastIP: d.ip.description, firstSeen: now, lastSeen: now,
                    acknowledged: network.completedScans == 0 || d.isSelf || acknowledging.contains(key))
                if !rec.acknowledged { created.append(key) }
            }
            rec.lastSeen = max(rec.lastSeen, now)
            rec.updateSnapshot(from: d, replaceCollections: scanComplete)
            if let presenceGap { rec.presence.recordSighting(at: now, gap: presenceGap) }
            seenKeys.insert(key)
            network.devices[key] = rec
        }
        if scanComplete, presenceGap != nil {
            for key in network.devices.keys where !seenKeys.contains(key) {
                network.devices[key]?.presence.closePresence()
            }
        }
        network.lastSeen = max(network.lastSeen, now)
        networks[networkID] = network
        return created
    }

    /// Ensures a record exists for `device` (e.g. before the user renames a device that hasn't
    /// been recorded yet) and returns its key.
    @discardableResult
    public mutating func ensureRecord(for device: Device, networkID: String, now: Date = Date()) -> String? {
        guard networks[networkID] != nil else { return nil }
        if let key = device.historyKey, networks[networkID]?.devices[key] != nil { return key }
        let key = KnownDevice.key(for: device)
        if networks[networkID]?.devices[key] == nil {
            var rec = KnownDevice(
                key: key, lastIP: device.ip.description, firstSeen: device.firstSeen ?? now,
                lastSeen: device.lastSeen ?? now)
            rec.updateSnapshot(from: device, replaceCollections: false)
            networks[networkID]?.devices[key] = rec
        }
        return key
    }

    public mutating func updateDevice(key: String, networkID: String, _ body: (inout KnownDevice) -> Void) {
        guard var rec = networks[networkID]?.devices[key] else { return }
        body(&rec)
        networks[networkID]?.devices[key] = rec
    }

    public mutating func forgetDevice(key: String, networkID: String) {
        networks[networkID]?.devices[key] = nil
    }

    // MARK: Merge

    /// Live devices annotated with their history (custom labels, dates, "new"), plus — when
    /// `includeOffline` — every remembered device of the network that isn't online, as offline rows.
    /// Sorted by IP. Offline rows whose last IP is taken get a synthetic `idOverride` (0.0.x.x).
    public func merged(online: [Device], networkID: String?, includeOffline: Bool) -> [Device] {
        guard let id = networkID, let network = networks[id] else { return online.sorted { $0.ip < $1.ip } }
        var used: Set<String> = []
        var out: [Device] = []
        out.reserveCapacity(online.count + network.devices.count)

        // MAC-less live devices may match a remembered device by last IP (ARP not filled yet).
        var macRecordsByIP: [String: KnownDevice] = [:]
        for rec in network.devices.values where !rec.isIPKeyed {
            if let cur = macRecordsByIP[rec.lastIP], cur.lastSeen >= rec.lastSeen { continue }
            macRecordsByIP[rec.lastIP] = rec
        }
        let onlineMACKeys = Set(online.compactMap { $0.mac.map { KnownDevice.macKey($0.description) } })

        for var d in online {
            var rec: KnownDevice?
            if d.mac != nil {
                rec = network.devices[KnownDevice.key(for: d)]
            } else {
                rec = network.devices[KnownDevice.ipKey(d.ip)]
                if rec == nil, let candidate = macRecordsByIP[d.ip.description],
                    !onlineMACKeys.contains(candidate.key), !used.contains(candidate.key)
                {
                    rec = candidate
                }
            }
            if let rec {
                used.insert(rec.key)
                rec.annotate(&d)
                rec.fillGaps(&d)
            } else {
                d.historyKey = KnownDevice.key(for: d)
            }
            d.isOnline = true
            out.append(d)
        }

        if includeOffline {
            var taken = Set(out.map(\.id))
            var synthetic: UInt32 = 1
            let offline = network.devices.values
                .filter { !used.contains($0.key) && !onlineMACKeys.contains($0.key) }
                .sorted { $0.lastSeen > $1.lastSeen }
            for rec in offline {
                var d = rec.offlineDevice()
                if taken.contains(d.id) {
                    while taken.contains(IPv4Address(synthetic)) { synthetic += 1 }
                    d.idOverride = IPv4Address(synthetic)
                }
                taken.insert(d.id)
                out.append(d)
            }
        }
        return out.sorted { $0.ip != $1.ip ? $0.ip < $1.ip : ($0.isOnline && !$1.isOnline) }
    }
}

extension KnownDevice {
    /// Folds a duplicate record (same device, other key) into this one.
    mutating func absorb(_ other: KnownDevice) {
        firstSeen = min(firstSeen, other.firstSeen)
        lastSeen = max(lastSeen, other.lastSeen)
        acknowledged = acknowledged || other.acknowledged
        if customName == nil { customName = other.customName }
        if customKind == nil { customKind = other.customKind }
        if notes == nil { notes = other.notes }
        absorbMonitoring(other)
    }
}

/// Counts what tolerant decoding dropped (passed through `JSONDecoder.userInfo`; decoding is
/// single-threaded).
final class DecodeStats: @unchecked Sendable {
    static let key = CodingUserInfoKey(rawValue: "LanternfishKit.HistoryDecodeStats")!
    var droppedDevices = 0
}
