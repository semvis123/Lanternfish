import Foundation

#if os(macOS)
    import CoreWLAN
#endif

/// Current association of a Wi-Fi interface, via CoreWLAN.
///
/// `ssid` / `bssid` are nil unless the app holds Location Services authorization
/// (macOS 14+ redacts them otherwise); the radio fields are available regardless.
public struct WiFiInfo: Sendable, Hashable {
    public enum Band: Int, Sendable {
        case unknown = 0
        case ghz2 = 1
        case ghz5 = 2
        case ghz6 = 3
        public var label: String {
            switch self {
            case .unknown: "Unknown band"
            case .ghz2: "2.4 GHz"
            case .ghz5: "5 GHz"
            case .ghz6: "6 GHz"
            }
        }
    }

    public enum Quality: Int, Sendable, Comparable {
        case poor = 1
        case fair, good, excellent
        public var label: String {
            switch self {
            case .poor: "Poor"
            case .fair: "Fair"
            case .good: "Good"
            case .excellent: "Excellent"
            }
        }
        /// Signal bars, 1...4.
        public var bars: Int { rawValue }
        public static func < (a: Quality, b: Quality) -> Bool { a.rawValue < b.rawValue }
    }

    public var interfaceName: String
    public var powerOn: Bool
    public var ssid: String?
    public var bssid: String?
    public var channel: Int?
    public var band: Band
    /// Channel width in MHz (20/40/80/160), nil when unknown.
    public var channelWidth: Int?
    public var rssi: Int?
    public var noise: Int?
    /// Tx rate in Mbit/s.
    public var txRate: Double?
    public var security: String?
    public var phyMode: String?
    public var countryCode: String?

    public init(
        interfaceName: String, powerOn: Bool = true, ssid: String? = nil, bssid: String? = nil,
        channel: Int? = nil, band: Band = .unknown, channelWidth: Int? = nil, rssi: Int? = nil,
        noise: Int? = nil, txRate: Double? = nil, security: String? = nil, phyMode: String? = nil,
        countryCode: String? = nil
    ) {
        self.interfaceName = interfaceName
        self.powerOn = powerOn
        self.ssid = ssid
        self.bssid = bssid
        self.channel = channel
        self.band = band
        self.channelWidth = channelWidth
        self.rssi = rssi
        self.noise = noise
        self.txRate = txRate
        self.security = security
        self.phyMode = phyMode
        self.countryCode = countryCode
    }

    /// Associated to a network (CoreWLAN reports a channel and a non-zero RSSI).
    public var isAssociated: Bool { channel != nil && (rssi ?? 0) != 0 }

    public var snr: Int? {
        guard let rssi, let noise, noise != 0 else { return nil }
        return rssi - noise
    }

    public var quality: Quality? { rssi.map { Self.quality(rssi: $0, noise: noise) } }

    /// RSSI thresholds (dBm), tightened when the SNR is low.
    public static func quality(rssi: Int, noise: Int?) -> Quality {
        var q: Quality =
            switch rssi {
            case (-55)...: .excellent
            case (-67)...: .good
            case (-75)...: .fair
            default: .poor
            }
        if let noise, noise != 0 {
            let snr = rssi - noise
            if snr < 15 { q = min(q, .poor) } else if snr < 25 { q = min(q, .fair) }
        }
        return q
    }

    // MARK: - Raw CoreWLAN values → labels (pure)

    public static func widthMHz(raw: Int) -> Int? {
        switch raw {
        case 1: 20
        case 2: 40
        case 3: 80
        case 4: 160
        case 5: 320
        default: nil
        }
    }

    public static func phyModeLabel(raw: Int) -> String? {
        switch raw {
        case 1: "802.11a"
        case 2: "802.11b"
        case 3: "802.11g"
        case 4: "802.11n (Wi-Fi 4)"
        case 5: "802.11ac (Wi-Fi 5)"
        case 6: "802.11ax (Wi-Fi 6)"
        case 7: "802.11be (Wi-Fi 7)"
        default: nil
        }
    }

    public static func securityLabel(raw: Int) -> String? {
        switch raw {
        case 0: "None"
        case 1: "WEP"
        case 2: "WPA Personal"
        case 3: "WPA/WPA2 Personal"
        case 4: "WPA2 Personal"
        case 5: "Personal"
        case 6: "Dynamic WEP"
        case 7: "WPA Enterprise"
        case 8: "WPA/WPA2 Enterprise"
        case 9: "WPA2 Enterprise"
        case 10: "Enterprise"
        case 11: "WPA3 Personal"
        case 12: "WPA3 Enterprise"
        case 13: "WPA2/WPA3 Personal"
        case 14: "Enhanced Open (OWE)"
        case 15: "OWE Transition"
        default: nil
        }
    }

    /// Converts a band raw value; when unknown, derives it from the channel number.
    public static func band(raw: Int, channel: Int?) -> Band {
        if let b = Band(rawValue: raw), b != .unknown { return b }
        guard let channel else { return .unknown }
        return (1...14).contains(channel) ? .ghz2 : .ghz5
    }
}

/// Reads the current Wi-Fi association. CoreWLAN on macOS; other platforms (no public API for
/// this) report no Wi-Fi interfaces.
public enum WiFiReader {
    /// Names of Wi-Fi interfaces CoreWLAN knows about (usually just "en0").
    public static func interfaceNames() -> [String] {
        #if os(macOS)
            CWWiFiClient.shared().interfaceNames() ?? []
        #else
            []
        #endif
    }

    /// Reads the current state of `name`, or nil if it isn't a Wi-Fi interface.
    public static func read(_ name: String) -> WiFiInfo? {
        #if os(macOS)
            guard let iface = CWWiFiClient.shared().interface(withName: name) else { return nil }
            let channel = iface.wlanChannel()
            let rssi = iface.rssiValue()
            let noise = iface.noiseMeasurement()
            let tx = iface.transmitRate()
            let channelNumber = channel.map { $0.channelNumber }
            return WiFiInfo(
                interfaceName: name,
                powerOn: iface.powerOn(),
                ssid: iface.ssid().trimmedNonEmpty,
                bssid: iface.bssid().trimmedNonEmpty,
                channel: channelNumber,
                band: WiFiInfo.band(raw: channel?.channelBand.rawValue ?? 0, channel: channelNumber),
                channelWidth: channel.flatMap { WiFiInfo.widthMHz(raw: $0.channelWidth.rawValue) },
                rssi: rssi == 0 ? nil : rssi,
                noise: noise == 0 ? nil : noise,
                txRate: tx > 0 ? tx : nil,
                security: channel == nil ? nil : WiFiInfo.securityLabel(raw: iface.security().rawValue),
                phyMode: WiFiInfo.phyModeLabel(raw: iface.activePHYMode().rawValue),
                countryCode: iface.countryCode().trimmedNonEmpty)
        #else
            return nil
        #endif
    }
}
