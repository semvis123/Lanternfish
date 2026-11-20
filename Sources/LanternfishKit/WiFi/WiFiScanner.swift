import Foundation

#if os(macOS)
    import CoreWLAN
#endif

public enum WiFiScanError: Error, Sendable, Equatable, LocalizedError {
    /// This Mac has no Wi-Fi interface (or CoreWLAN can't see it).
    case noInterface
    /// The Wi-Fi radio is turned off.
    case poweredOff
    /// CoreWLAN refused or failed the scan (busy, throttled, …).
    case failed(code: Int, message: String)

    public var errorDescription: String? {
        switch self {
        case .noInterface: "This Mac has no Wi-Fi interface."
        case .poweredOff: "Wi-Fi is turned off."
        case .failed(_, let message): message
        }
    }
}

/// Active Wi-Fi scans via CoreWLAN (macOS only; elsewhere every scan throws `.noInterface`).
/// A scan briefly takes the radio off-channel, so callers should scan sparingly.
public enum WiFiScanner {
    /// Blocking scans run here, never on the cooperative pool.
    private static let queue = DispatchQueue(label: "LanternfishKit.WiFiScanner", qos: .utility)

    /// Scans without blocking the caller: the multi-second CoreWLAN call runs on a dedicated queue.
    public static func scan(interfaceName: String? = nil) async throws(WiFiScanError) -> [WiFiScanResult] {
        let result: Result<[WiFiScanResult], WiFiScanError> = await withCheckedContinuation { c in
            queue.async {
                do throws(WiFiScanError) {
                    c.resume(returning: .success(try scan(interfaceName: interfaceName)))
                } catch {
                    c.resume(returning: .failure(error))
                }
            }
        }
        return try result.get()
    }

    /// Scans on `interfaceName` (default: the primary Wi-Fi interface), hidden networks included.
    /// Blocks for a few seconds; prefer the async overload.
    public static func scan(interfaceName: String? = nil) throws(WiFiScanError) -> [WiFiScanResult] {
        #if os(macOS)
            let client = CWWiFiClient.shared()
            guard let iface = interfaceName.map({ client.interface(withName: $0) }) ?? client.interface() else {
                throw .noInterface
            }
            guard iface.powerOn() else { throw .poweredOff }
            let networks: Set<CWNetwork>
            do {
                networks = try iface.scanForNetworks(withName: nil, includeHidden: true)
            } catch {
                let ns = error as NSError
                throw .failed(code: ns.code, message: ns.localizedDescription)
            }
            return assignIDs(networks.map(result(from:)))
        #else
            throw .noInterface
        #endif
    }

    #if os(macOS)
        static func result(from n: CWNetwork) -> WiFiScanResult {
            let channel = n.wlanChannel
            let number = channel?.channelNumber ?? 0
            let band = WiFiInfo.band(raw: channel?.channelBand.rawValue ?? 0, channel: number)
            let ies = n.informationElementData.map { WiFiInformationElements(data: $0) }
            let securities = Set(
                (0...15).filter { raw in
                    CWSecurity(rawValue: raw).map { n.supportsSecurity($0) } ?? false
                })
            let phys = Set(
                (1...7).filter { raw in
                    CWPHYMode(rawValue: raw).map { n.supportsPHYMode($0) } ?? false
                })
            let ssid = n.ssid
            let bssid = n.bssid
            let noise = n.noiseMeasurement
            let beacon = n.beaconInterval
            return WiFiScanResult(
                ssid: ssid, bssid: bssid,
                // A real BSS always has a BSSID; a nil one means macOS redacted the identifiers.
                isNameRedacted: bssid == nil,
                rssi: n.rssiValue, noise: noise == 0 ? nil : noise,
                channel: number, band: band,
                width: channel.flatMap { WiFiInfo.widthMHz(raw: $0.channelWidth.rawValue) } ?? 20,
                secondary: ies?.htSecondaryChannel,
                security: WiFiSecurity.from(supported: securities),
                standard: WiFiStandard.highest(supported: phys) ?? ies?.standard,
                beaconInterval: beacon > 0 ? beacon : nil,
                countryCode: n.countryCode.trimmedNonEmpty,
                isIBSS: n.ibss)
        }
    #endif

    /// Makes ids unique: networks without a BSSID share radio keys, so duplicates get "#2", "#3"…
    /// in descending RSSI order (the strongest keeps the bare key, which keeps ids mostly stable
    /// from scan to scan). Duplicate BSSIDs keep only the strongest entry.
    public static func assignIDs(_ results: [WiFiScanResult]) -> [WiFiScanResult] {
        var seen: [String: Int] = [:]
        var out: [WiFiScanResult] = []
        for var r in results.sorted(by: { ($0.rssi, $1.id) > ($1.rssi, $0.id) }) {
            let n = seen[r.id, default: 0] + 1
            seen[r.id] = n
            if n > 1 {
                if r.bssid != nil { continue }
                r.id += "#\(n)"
            }
            out.append(r)
        }
        return out
    }
}

/// The tagged information elements of a beacon / probe response.
public struct WiFiInformationElements: Sendable {
    /// Element id → body (first occurrence). Extension elements (255) are keyed by `extensions`.
    public private(set) var elements: [UInt8: Data] = [:]
    /// Element id extension → body (for id 255).
    public private(set) var extensions: [UInt8: Data] = [:]

    /// Element ids from IEEE 802.11 (9.4.2).
    private enum ID {
        static let htCapabilities: UInt8 = 45
        static let htOperation: UInt8 = 61
        static let vhtCapabilities: UInt8 = 191
        static let extensionElement: UInt8 = 255
        // Extension ids (first body byte of element 255).
        static let heCapabilities: UInt8 = 35
        static let ehtCapabilities: UInt8 = 108
    }

    public init(data: Data) {
        let bytes = [UInt8](data)
        var i = 0
        while i + 2 <= bytes.count {
            let id = bytes[i]
            let len = Int(bytes[i + 1])
            let start = i + 2
            let end = start + len
            guard end <= bytes.count else { break }
            let body = Data(bytes[start..<end])
            if id == ID.extensionElement, let ext = body.first {
                if extensions[ext] == nil { extensions[ext] = body.dropFirst() }
            } else if elements[id] == nil {
                elements[id] = body
            }
            i = end
        }
    }

    /// HT Operation (61), byte 1 bits 0–1: 1 = secondary above, 3 = below.
    public var htSecondaryChannel: SecondaryChannel? {
        guard let ht = elements[ID.htOperation], ht.count >= 2 else { return nil }
        switch ht[ht.startIndex + 1] & 0x03 {
        case 1: return .above
        case 3: return .below
        default: return nil
        }
    }

    /// Highest standard implied by capability elements (EHT, HE, VHT, HT).
    public var standard: WiFiStandard? {
        if extensions[ID.ehtCapabilities] != nil { return .be }
        if extensions[ID.heCapabilities] != nil { return .ax }
        if elements[ID.vhtCapabilities] != nil { return .ac }
        if elements[ID.htCapabilities] != nil { return .n }
        return nil
    }
}
