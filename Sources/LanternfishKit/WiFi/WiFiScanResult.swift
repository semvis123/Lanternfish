import Foundation

/// The strongest security a network advertises.
public enum WiFiSecurity: String, Sendable, Hashable, CaseIterable {
    case open, owe, wep, wpa, wpaWPA2, wpa2, wpa2WPA3, wpa3, wpaEnterprise, wpa2Enterprise, wpa3Enterprise, unknown

    public var label: String {
        switch self {
        case .open: "Open"
        case .owe: "Enhanced Open"
        case .wep: "WEP"
        case .wpa: "WPA"
        case .wpaWPA2: "WPA/WPA2"
        case .wpa2: "WPA2"
        case .wpa2WPA3: "WPA2/WPA3"
        case .wpa3: "WPA3"
        case .wpaEnterprise: "WPA Enterprise"
        case .wpa2Enterprise: "WPA2 Enterprise"
        case .wpa3Enterprise: "WPA3 Enterprise"
        case .unknown: "Unknown"
        }
    }

    /// No encryption, or encryption that is broken.
    public var isWeak: Bool { self == .open || self == .wep || self == .wpa }

    /// From the set of `CWSecurity` raw values a network supports (`CWNetwork.supportsSecurity`).
    /// Raw values: 0 none, 1 WEP, 2 WPA, 3 WPA/WPA2, 4 WPA2, 5 personal, 6 dynamic WEP,
    /// 7 WPA Ent., 8 WPA/WPA2 Ent., 9 WPA2 Ent., 10 enterprise, 11 WPA3, 12 WPA3 Ent.,
    /// 13 WPA2/WPA3, 14 OWE, 15 OWE transition (see `WiFiInfo.securityLabel(raw:)`).
    public static func from(supported raw: Set<Int>) -> WiFiSecurity {
        if raw.contains(12) { return .wpa3Enterprise }
        if raw.contains(9) || raw.contains(8) || raw.contains(10) { return .wpa2Enterprise }
        if raw.contains(7) { return .wpaEnterprise }
        if raw.contains(13) { return .wpa2WPA3 }
        if raw.contains(11) { return raw.contains(4) || raw.contains(3) ? .wpa2WPA3 : .wpa3 }
        if raw.contains(4) { return raw.contains(3) || raw.contains(2) ? .wpaWPA2 : .wpa2 }
        if raw.contains(3) { return .wpaWPA2 }
        if raw.contains(2) { return .wpa }
        if raw.contains(1) || raw.contains(6) { return .wep }
        if raw.contains(14) || raw.contains(15) { return .owe }
        if raw.contains(0) { return .open }
        return .unknown
    }
}

/// 802.11 amendment (PHY) generation.
public enum WiFiStandard: Int, Sendable, Hashable, Comparable, CaseIterable {
    case b = 2
    case a = 1
    case g = 3
    case n = 4
    case ac = 5
    case ax = 6
    case be = 7

    /// Ordering by generation (a/b/g share a rank by raw value, close enough).
    public static func < (l: Self, r: Self) -> Bool { l.rank < r.rank }
    private var rank: Int { self == .b ? 0 : rawValue }

    public var name: String {
        switch self {
        case .a: "802.11a"
        case .b: "802.11b"
        case .g: "802.11g"
        case .n: "802.11n"
        case .ac: "802.11ac"
        case .ax: "802.11ax"
        case .be: "802.11be"
        }
    }

    /// Marketing generation, e.g. "Wi-Fi 6"; nil before 802.11n.
    public var generation: String? {
        switch self {
        case .n: "Wi-Fi 4"
        case .ac: "Wi-Fi 5"
        case .ax: "Wi-Fi 6"
        case .be: "Wi-Fi 7"
        default: nil
        }
    }

    /// "802.11ax (Wi-Fi 6)".
    public var label: String { generation.map { "\(name) (\($0))" } ?? name }

    /// The highest of the `CWPHYMode` raw values a network supports.
    public static func highest(supported raw: Set<Int>) -> WiFiStandard? {
        raw.compactMap(WiFiStandard.init(rawValue:)).max()
    }
}

/// One BSS heard in a Wi-Fi scan.
public struct WiFiScanResult: Sendable, Hashable, Identifiable {
    /// The BSSID when known, otherwise a key synthesized from the radio parameters (see `WiFiScanner`).
    public var id: String
    /// nil for hidden networks and when macOS withholds names (no Location permission).
    public var ssid: String?
    /// Lower-case "aa:bb:cc:dd:ee:ff"; nil when withheld.
    public var bssid: String?
    /// macOS withheld SSID and BSSID because the app lacks Location Services authorization.
    public var isNameRedacted: Bool
    public var rssi: Int
    public var noise: Int?
    /// Primary 20 MHz channel.
    public var channel: Int
    public var band: WiFiBand
    /// Channel width in MHz (20 when unknown or not valid for the channel).
    public var width: Int
    /// 40 MHz secondary channel side (2.4 GHz), from the HT Operation element.
    public var secondary: SecondaryChannel?
    public var security: WiFiSecurity
    public var standard: WiFiStandard?
    /// Beacon interval in time units (1 TU = 1.024 ms).
    public var beaconInterval: Int?
    public var countryCode: String?
    public var isIBSS: Bool

    public init(
        id: String? = nil, ssid: String? = nil, bssid: String? = nil, isNameRedacted: Bool = false,
        rssi: Int, noise: Int? = nil, channel: Int, band: WiFiBand, width: Int = 20,
        secondary: SecondaryChannel? = nil, security: WiFiSecurity = .unknown, standard: WiFiStandard? = nil,
        beaconInterval: Int? = nil, countryCode: String? = nil, isIBSS: Bool = false
    ) {
        let ssid = ssid.flatMap { Self.cleanSSID($0) }
        let bssid = bssid.flatMap { MACAddress($0) }.map { $0.description.lowercased() }
        self.ssid = ssid
        self.bssid = bssid
        self.isNameRedacted = isNameRedacted
        self.rssi = rssi
        self.noise = noise
        self.channel = channel
        self.band = band
        self.secondary = secondary
        // Fall back to 20 MHz when the reported width doesn't exist at this channel.
        self.width =
            WiFiChannels.span(primary: channel, width: width, band: band, secondary: secondary) != nil ? width : 20
        self.security = security
        self.standard = standard
        self.beaconInterval = beaconInterval
        self.countryCode = countryCode
        self.isIBSS = isIBSS
        self.id =
            id ?? bssid
            ?? Self.radioKey(
                band: band, channel: channel, width: self.width, security: security,
                standard: standard, beaconInterval: beaconInterval,
                countryCode: countryCode)
    }

    /// Hidden SSIDs are broadcast as empty or all-NUL strings.
    static func cleanSSID(_ s: String) -> String? {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0")))
        return trimmed.isEmpty ? nil : s
    }

    /// Identity used when no BSSID is available; `WiFiScanner.assignIDs` appends "#n" to duplicates.
    static func radioKey(
        band: WiFiBand, channel: Int, width: Int, security: WiFiSecurity,
        standard: WiFiStandard?, beaconInterval: Int?, countryCode: String?
    ) -> String {
        "radio:\(band.rawValue):\(channel):\(width):\(security.rawValue):\(standard?.rawValue ?? 0)"
            + ":\(beaconInterval ?? 0):\(countryCode ?? "")"
    }

    // MARK: Derived

    /// A network that broadcasts no name (as opposed to one macOS redacted).
    public var isHidden: Bool { ssid == nil && !isNameRedacted }

    public var displayName: String {
        if let ssid { return ssid }
        return isNameRedacted ? "Unnamed network" : "Hidden network"
    }

    public var centerChannel: Int {
        WiFiChannels.centerChannel(primary: channel, width: width, band: band, secondary: secondary) ?? channel
    }

    /// Occupied frequencies; a nominal 20 MHz span if the channel is unknown to the channel plan.
    public var span: ChannelSpan {
        WiFiChannels.span(primary: channel, width: width, band: band, secondary: secondary)
            ?? ChannelSpan(center: Double(frequency ?? 0), width: 20)
    }

    /// Primary channel center frequency in MHz.
    public var frequency: Int? { WiFiChannels.frequency(channel: channel, band: band) }

    public var isDFS: Bool { WiFiChannels.touchesDFS(span, band: band) }

    public var mac: MACAddress? { bssid.flatMap(MACAddress.init) }

    /// Randomized / locally-administered BSSID (no meaningful manufacturer).
    public var isLocallyAdministered: Bool { mac?.isLocallyAdministered ?? false }

    public var quality: WiFiInfo.Quality { WiFiInfo.quality(rssi: rssi, noise: noise) }

    public var snr: Int? {
        guard let noise, noise != 0 else { return nil }
        return rssi - noise
    }

    /// Manufacturer from the BSSID's OUI; nil when unknown, withheld or locally administered.
    public func brand(in vendors: VendorDatabase = .shared) -> String? {
        mac.flatMap { vendors.vendor(for: $0) }
    }

    /// Primary channel, plus the center channel of a wide channel: "36 (42)".
    public var channelLabel: String {
        width > 20 && centerChannel != channel ? "\(channel) (\(centerChannel))" : "\(channel)"
    }

    // MARK: Matching the current connection

    /// The scan result that is this Mac's current network: by BSSID when known, otherwise the
    /// closest-RSSI network on the same band and channel (and SSID, when both are known).
    public static func currentID(in results: [WiFiScanResult], connection: WiFiInfo?) -> String? {
        guard let c = connection, c.isAssociated, let channel = c.channel else { return nil }
        if let b = c.bssid.flatMap(MACAddress.init)?.description.lowercased(),
            let hit = results.first(where: { $0.bssid == b })
        {
            return hit.id
        }
        let candidates = results.filter { r in
            r.channel == channel && (c.band == .unknown || r.band == c.band)
                && (r.ssid == nil || c.ssid == nil || r.ssid == c.ssid)
        }
        guard let rssi = c.rssi else { return candidates.count == 1 ? candidates[0].id : nil }
        return
            candidates
            .filter { abs($0.rssi - rssi) <= 12 }
            .min { abs($0.rssi - rssi) < abs($1.rssi - rssi) }?.id
    }
}

// MARK: - Grouping

/// Access points sharing one SSID (mesh nodes, multi-band routers).
public struct WiFiNetworkGroup: Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    /// Strongest first.
    public var members: [WiFiScanResult]

    public var strongest: WiFiScanResult { members[0] }
    public var bands: [WiFiBand] {
        Array(Set(members.map(\.band))).sorted { $0.rawValue < $1.rawValue }
    }

    /// Groups by SSID; hidden and unnamed networks stay on their own. Groups are ordered by
    /// their strongest member.
    public static func group(_ results: [WiFiScanResult]) -> [WiFiNetworkGroup] {
        var named: [String: [WiFiScanResult]] = [:]
        var out: [WiFiNetworkGroup] = []
        for r in results {
            if let ssid = r.ssid {
                named[ssid, default: []].append(r)
            } else {
                out.append(WiFiNetworkGroup(id: "bss:\(r.id)", name: r.displayName, members: [r]))
            }
        }
        for (ssid, members) in named {
            out.append(
                WiFiNetworkGroup(
                    id: "ssid:\(ssid)", name: ssid,
                    members: members.sorted { ($0.rssi, $1.id) > ($1.rssi, $0.id) }))
        }
        return out.sorted { ($0.strongest.rssi, $1.name) > ($1.strongest.rssi, $0.name) }
    }
}

// MARK: - Signal history

/// RSSI samples per network id over a sliding window (default 5 minutes).
public struct WiFiSignalHistory: Sendable {
    public struct Sample: Sendable, Hashable {
        public var date: Date
        public var rssi: Int
        public init(date: Date, rssi: Int) {
            self.date = date
            self.rssi = rssi
        }
    }

    public var window: TimeInterval
    public private(set) var samples: [String: [Sample]] = [:]

    public init(window: TimeInterval = 300) {
        self.window = window
    }

    public mutating func record(_ results: [WiFiScanResult], at date: Date) {
        for r in results { record(id: r.id, rssi: r.rssi, at: date) }
        trim(now: date)
    }

    public mutating func record(id: String, rssi: Int, at date: Date) {
        samples[id, default: []].append(Sample(date: date, rssi: rssi))
    }

    public mutating func trim(now: Date) {
        let cutoff = now.addingTimeInterval(-window)
        for (id, list) in samples {
            let kept = list.filter { $0.date >= cutoff }
            samples[id] = kept.isEmpty ? nil : kept
        }
    }

    public func samples(for id: String) -> [Sample] { samples[id] ?? [] }
}
