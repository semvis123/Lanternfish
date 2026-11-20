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
