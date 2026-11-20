import Foundation

// MARK: - IPv4Address

/// An IPv4 address stored in host byte order, so numeric comparison sorts naturally.
public struct IPv4Address: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let value: UInt32

    public init(_ value: UInt32) { self.value = value }

    public init?(_ string: String) {
        let parts = string.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var v: UInt32 = 0
        for p in parts {
            guard let octet = UInt8(p) else { return nil }
            v = (v << 8) | UInt32(octet)
        }
        value = v
    }

    public var description: String {
        "\(value >> 24 & 0xFF).\(value >> 16 & 0xFF).\(value >> 8 & 0xFF).\(value & 0xFF)"
    }

    public static func < (lhs: IPv4Address, rhs: IPv4Address) -> Bool { lhs.value < rhs.value }
}

// MARK: - Subnet

/// An IPv4 network: an address plus a prefix length clamped to 0...32.
public struct Subnet: Sendable, Hashable, CustomStringConvertible {
    public let address: IPv4Address
    public let prefixLength: Int

    public init(address: IPv4Address, prefixLength: Int) {
        self.address = address
        self.prefixLength = max(0, min(32, prefixLength))
    }

    /// Builds a subnet from an address and a dotted netmask.
    public init(address: IPv4Address, netmask: IPv4Address) {
        self.init(address: address, prefixLength: netmask.value.nonzeroBitCount)
    }

    public var description: String {
        let mask: UInt32 = prefixLength == 0 ? 0 : ~UInt32(0) << (32 - prefixLength)
        return "\(IPv4Address(address.value & mask))/\(prefixLength)"
    }

    /// Hosts to scan. Prefixes shorter than /24 are narrowed to the /24 containing `address`.
    /// Network and broadcast addresses are excluded for prefixes up to /30.
    public func scanHosts() -> [IPv4Address] {
        let effective = max(prefixLength, 24)
        if effective >= 31 {
            let mask: UInt32 = effective == 32 ? ~0 : ~UInt32(1)
            let base = address.value & mask
            return effective == 32 ? [address] : [IPv4Address(base), IPv4Address(base + 1)]
        }
        let mask: UInt32 = ~UInt32(0) << (32 - effective)
        let network = address.value & mask
        let broadcast = network | ~mask
        return (network + 1..<broadcast).map(IPv4Address.init)
    }
}

// MARK: - MACAddress

/// A 6-byte Ethernet hardware address.
public struct MACAddress: Hashable, Sendable, CustomStringConvertible {
    public let bytes: [UInt8]

    public init?(bytes: [UInt8]) {
        guard bytes.count == 6 else { return nil }
        self.bytes = bytes
    }

    /// Accepts `:` or `-` separators and octets with dropped leading zeros (as `arp` prints them).
    public init?(_ string: String) {
        let parts = string.split(whereSeparator: { $0 == ":" || $0 == "-" })
        guard parts.count == 6 else { return nil }
        var out: [UInt8] = []
        for p in parts {
            guard p.count <= 2, let b = UInt8(p, radix: 16) else { return nil }
            out.append(b)
        }
        self.bytes = out
    }

    public var description: String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    /// True for randomized / private addresses (locally-administered bit set).
    public var isLocallyAdministered: Bool { bytes[0] & 0x02 != 0 }

    /// The first three bytes as uppercase hex without separators, e.g. "A483E7".
    public var ouiPrefix: String {
        bytes.prefix(3).map { String(format: "%02X", $0) }.joined()
    }
}

// MARK: - Interface

public struct NetworkInterfaceInfo: Sendable, Hashable, Identifiable {
    public var id: String { name }
    public let name: String  // BSD name, e.g. "en0"
    public let displayName: String  // e.g. "Wi-Fi"
    public let address: IPv4Address
    public let subnet: Subnet
    public let mac: MACAddress?
    public let gateway: IPv4Address?
    public let isPrimary: Bool

    public init(
        name: String, displayName: String, address: IPv4Address, subnet: Subnet,
        mac: MACAddress?, gateway: IPv4Address?, isPrimary: Bool
    ) {
        self.name = name
        self.displayName = displayName
        self.address = address
        self.subnet = subnet
        self.mac = mac
        self.gateway = gateway
        self.isPrimary = isPrimary
    }
}

// MARK: - DeviceKind

public enum DeviceKind: String, Sendable, CaseIterable, Codable {
    case router, computer, phone, tablet, tv, printer, speaker, camera, gameConsole, nas, iot, unknown

    public var symbolName: String {
        switch self {
        case .router: "wifi.router"
        case .computer: "laptopcomputer"
        case .phone: "iphone"
        case .tablet: "ipad"
        case .tv: "tv"
        case .printer: "printer"
        case .speaker: "hifispeaker"
        case .camera: "web.camera"
        case .gameConsole: "gamecontroller"
        case .nas: "externaldrive.connected.to.line.below"
        case .iot: "lightbulb"
        case .unknown: "questionmark.circle"
        }
    }

    /// Unknown raw values (e.g. from a newer app version) decode as `.unknown` instead of failing.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = DeviceKind(rawValue: raw) ?? .unknown
    }

    public var label: String {
        switch self {
        case .gameConsole: "Game Console"
        case .nas: "NAS"
        case .tv: "TV"
        case .iot: "Smart Device"
        default: rawValue.capitalized
        }
    }
}

// MARK: - OpenPort

public struct OpenPort: Hashable, Sendable, Comparable, Codable {
    public let port: UInt16
    public let service: String?

    public init(port: UInt16, service: String? = nil) {
        self.port = port
        self.service = service
    }

    private static let webPorts: Set<UInt16> = [80, 443, 8000, 8008, 8080, 8081, 8443, 8888]
    private static let httpsPorts: Set<UInt16> = [443, 8443]

    public var isWeb: Bool { Self.webPorts.contains(port) }

    public func url(host: IPv4Address) -> URL? {
        guard isWeb else { return nil }
        let scheme = Self.httpsPorts.contains(port) ? "https" : "http"
        let defaultPort = (scheme == "https" && port == 443) || (scheme == "http" && port == 80)
        return URL(string: defaultPort ? "\(scheme)://\(host)" : "\(scheme)://\(host):\(port)")
    }

    public static func < (lhs: OpenPort, rhs: OpenPort) -> Bool { lhs.port < rhs.port }

    // Equality/hash by port only, so the same port from different sources dedupes.
    public static func == (lhs: OpenPort, rhs: OpenPort) -> Bool { lhs.port == rhs.port }
    public func hash(into hasher: inout Hasher) { hasher.combine(port) }
}

// MARK: - DevicePatch

/// Partial information about a device from one source. Merged into `Device` by IP.
public struct DevicePatch: Sendable {
    public var ip: IPv4Address
    public var mac: MACAddress?
    public var vendor: String?
    public var hostname: String?
    public var name: String?
    public var manufacturer: String?
    public var model: String?
    public var kind: DeviceKind?
    public var services: Set<String> = []
    public var openPorts: Set<OpenPort> = []
    public var responseTime: Duration?
    /// Operating system / firmware hint, e.g. "Ubuntu", "TrueNAS", "Windows".
    public var osHint: String?
    /// Title of the device's web interface, if any.
    public var webTitle: String?
    /// How sure the fingerprinter is about the identification (0...1); nil = not assessed.
    public var confidence: Double?
    /// Human-readable evidence behind the identification (see `Fingerprint`).
    public var identificationReasons: [String] = []

    public init(ip: IPv4Address) { self.ip = ip }
}

// MARK: - Device

public struct Device: Identifiable, Sendable, Hashable {
    /// The IP, unless `idOverride` is set (offline history entries whose last IP is now taken).
    public var id: IPv4Address { idOverride ?? ip }
    public var ip: IPv4Address
    public var mac: MACAddress?
    public var vendor: String?
    public var hostname: String?
    public var name: String?
    public var manufacturer: String?
    public var model: String?
    public var kind: DeviceKind = .unknown
    public var services: Set<String> = []
    public var openPorts: [OpenPort] = []
    public var responseTime: Duration?
    public var isSelf: Bool = false
    public var osHint: String?
    public var webTitle: String?
    /// How sure the fingerprinter is about manufacturer/model/kind (0...1); nil = not assessed.
    public var confidence: Double?
    /// Human-readable evidence behind the identification, strongest first (see `Fingerprint`).
    public var identificationReasons: [String] = []

    // History (see `History/`). Live scan results are online; remembered devices may be offline.
    public var isOnline: Bool = true
    public var firstSeen: Date?
    public var lastSeen: Date?
    /// User-assigned name; wins over every discovered name.
    public var customName: String?
    /// User-assigned type; wins over the classifier (see `effectiveKind`).
    public var customKind: DeviceKind?
    public var notes: String?
    /// First seen on a network that had been scanned before, and not yet looked at by the user.
    public var isNew: Bool = false
    /// Key of the device's history record within its network (`KnownDevice.key`).
    public var historyKey: String?
    /// Synthetic identity for rows whose `ip` collides with another row (offline devices only).
    public var idOverride: IPv4Address?

    public init(ip: IPv4Address) { self.ip = ip }

    /// The user's type if set, else the classified one.
    public var effectiveKind: DeviceKind { customKind ?? kind }

    public var isPrivateMAC: Bool { mac?.isLocallyAdministered ?? false }

    /// Best human-readable name.
    public var displayName: String {
        if let customName, !customName.isEmpty { return customName }
        if let name, !name.isEmpty { return name }
        if let hostname, !hostname.isEmpty { return hostname.strippingLocalDomain() }
        if let brand = manufacturer ?? vendor { return brand }
        return ip.description
    }

    /// e.g. "Samsung QLED TV", "Apple", or nil if unknown.
    public var brandModel: String? {
        let brand = manufacturer ?? vendor
        switch (brand, model) {
        case (let b?, let m?):
            return m.localizedCaseInsensitiveContains(b) ? m : "\(b) \(m)"
        case (let b?, nil): return b
        case (nil, let m?): return m
        default: return nil
        }
    }

    /// Non-nil fields in the patch overwrite; services and ports are unioned;
    /// kind only overwrites when the patch has one.
    public mutating func merge(_ p: DevicePatch) {
        precondition(p.ip == ip, "patch for a different device")
        if let v = p.mac { mac = v }
        if let v = p.vendor { vendor = v }
        if let v = p.hostname { hostname = v }
        if let v = p.name, !v.isEmpty { name = v }
        if let v = p.manufacturer { manufacturer = v }
        if let v = p.model, !v.isEmpty { model = v }
        if let v = p.kind, v != .unknown { kind = v }
        services.formUnion(p.services)
        if !p.openPorts.isEmpty {
            openPorts = Array(Set(openPorts).union(p.openPorts)).sorted()
        }
        if let v = p.osHint, !v.isEmpty { osHint = v }
        if let v = p.webTitle, !v.isEmpty { webTitle = v }
        if let v = p.responseTime, responseTime.map({ v < $0 }) ?? true { responseTime = v }
        if let v = p.confidence { confidence = v }
        if !p.identificationReasons.isEmpty { identificationReasons = p.identificationReasons }
    }
}

extension String {
    /// The host name without a trailing home-network domain (".local", ".lan", ".home") or dot.
    func strippingLocalDomain() -> String {
        var h = self
        for suffix in [".local.", ".local", ".lan", ".home", "."] where h.hasSuffix(suffix) {
            h.removeLast(suffix.count)
        }
        return h
    }
}
