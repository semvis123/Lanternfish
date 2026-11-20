import Foundation

/// A network the app has scanned, recognized by its gateway's MAC address
/// (fallback: gateway IP + subnet), with every device ever seen on it.
public struct KnownNetwork: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    /// e.g. "00:00:5E:00:53:01". Nil until the gateway's MAC is known.
    public var gatewayMAC: String?
    public var gatewayIP: String?
    /// CIDR, e.g. "192.168.1.0/24".
    public var subnet: String
    public var customName: String?
    public var firstSeen: Date
    public var lastSeen: Date
    /// Scans that ran to completion. Devices first seen after the first completed scan are "new".
    public var completedScans: Int
    /// Keyed by `KnownDevice.key`.
    public var devices: [String: KnownDevice]

    public init(
        id: String = UUID().uuidString, gatewayMAC: String? = nil, gatewayIP: String? = nil,
        subnet: String, firstSeen: Date, lastSeen: Date? = nil
    ) {
        self.id = id
        self.gatewayMAC = gatewayMAC
        self.gatewayIP = gatewayIP
        self.subnet = subnet
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen ?? firstSeen
        self.completedScans = 0
        self.devices = [:]
    }

    /// The router's remembered record, if any (by gateway MAC, else gateway IP).
    public var gatewayDevice: KnownDevice? {
        if let mac = gatewayMAC, let d = devices[KnownDevice.macKey(mac)] { return d }
        guard let ip = gatewayIP else { return nil }
        return devices.values.filter { $0.lastIP == ip }.max { $0.lastSeen < $1.lastSeen }
    }

    // MARK: Codable (tolerant: missing fields get defaults, undecodable devices are dropped)

    private enum CodingKeys: String, CodingKey {
        case id, gatewayMAC, gatewayIP, subnet, customName, firstSeen, lastSeen, completedScans, devices
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        gatewayMAC = try c.decodeIfPresent(String.self, forKey: .gatewayMAC)
        gatewayIP = try c.decodeIfPresent(String.self, forKey: .gatewayIP)
        subnet = try c.decodeIfPresent(String.self, forKey: .subnet) ?? "?"
        customName = try c.decodeIfPresent(String.self, forKey: .customName)
        let now = Date()
        firstSeen = try c.decodeIfPresent(Date.self, forKey: .firstSeen) ?? now
        lastSeen = try c.decodeIfPresent(Date.self, forKey: .lastSeen) ?? firstSeen
        completedScans = try c.decodeIfPresent(Int.self, forKey: .completedScans) ?? 1
        let stats = decoder.userInfo[DecodeStats.key] as? DecodeStats
        let lossy: [String: Lossy<KnownDevice>]
        do {
            lossy = try c.decodeIfPresent([String: Lossy<KnownDevice>].self, forKey: .devices) ?? [:]
        } catch {
            lossy = [:]
            stats?.droppedDevices += 1
        }
        stats?.droppedDevices += lossy.values.count { $0.value == nil }
        devices = [:]
        for (_, box) in lossy {
            if let d = box.value { devices[d.key] = d }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(gatewayMAC, forKey: .gatewayMAC)
        try c.encodeIfPresent(gatewayIP, forKey: .gatewayIP)
        try c.encode(subnet, forKey: .subnet)
        try c.encodeIfPresent(customName, forKey: .customName)
        try c.encode(firstSeen, forKey: .firstSeen)
        try c.encode(lastSeen, forKey: .lastSeen)
        try c.encode(completedScans, forKey: .completedScans)
        try c.encode(devices, forKey: .devices)
    }
}

/// Decodes a value or nil, so one bad element doesn't fail the whole container.
struct Lossy<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}
