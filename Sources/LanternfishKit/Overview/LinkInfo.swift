import Darwin
import Foundation

/// Link-level details of one interface: medium, MTU, link speed and IPv6 state.
public struct LinkInfo: Sendable, Hashable {
    public enum Medium: String, Sendable {
        case wifi, ethernet, other
        public var label: String {
            switch self {
            case .wifi: "Wi-Fi"
            case .ethernet: "Ethernet"
            case .other: "Other"
            }
        }
    }

    public var name: String
    public var medium: Medium
    public var mtu: Int?
    /// Link speed in bits per second, when the driver reports one.
    public var linkSpeed: UInt64?
    /// Global (non link-local) IPv6 addresses on the interface.
    public var ipv6Addresses: [String]
    public var hasLinkLocalIPv6: Bool
    /// IPv6 default router (from `State:/Network/Global/IPv6`), if this is the IPv6 primary.
    public var ipv6Router: String?

    public init(
        name: String, medium: Medium, mtu: Int? = nil, linkSpeed: UInt64? = nil,
        ipv6Addresses: [String] = [], hasLinkLocalIPv6: Bool = false, ipv6Router: String? = nil
    ) {
        self.name = name
        self.medium = medium
        self.mtu = mtu
        self.linkSpeed = linkSpeed
        self.ipv6Addresses = ipv6Addresses
        self.hasLinkLocalIPv6 = hasLinkLocalIPv6
        self.ipv6Router = ipv6Router
    }

    public var ipv6Status: String {
        if !ipv6Addresses.isEmpty { return ipv6Router != nil ? "Connected" : "No IPv6 router" }
        return hasLinkLocalIPv6 ? "Link-local only" : "Off"
    }

    /// "1 Gbit/s", "100 Mbit/s", "2.5 Gbit/s".
    public static func formatSpeed(_ bps: UInt64) -> String {
        if bps >= 1_000_000_000 {
            let g = Double(bps) / 1e9
            return g == g.rounded() ? "\(Int(g)) Gbit/s" : String(format: "%.1f Gbit/s", g)
        }
        if bps >= 1_000_000 { return "\(bps / 1_000_000) Mbit/s" }
        return "\(bps / 1000) kbit/s"
    }
}

public enum LinkInfoReader {
    public static func read(_ name: String) -> LinkInfo {
        var info = LinkInfo(name: name, medium: medium(of: name))
        var ifap: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&ifap) == 0, let first = ifap {
            defer { freeifaddrs(ifap) }
            for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
                let ifa = ptr.pointee
                guard strcmp(ifa.ifa_name, name) == 0, let sa = ifa.ifa_addr else { continue }
                switch Int32(sa.pointee.sa_family) {
                case AF_LINK:
                    if let data = ifa.ifa_data {
                        let d = data.load(as: if_data.self)
                        info.mtu = Int(d.ifi_mtu)
                        if d.ifi_baudrate > 0 { info.linkSpeed = UInt64(d.ifi_baudrate) }
                    }
                case AF_INET6:
                    guard let s = ipv6String(sa) else { continue }
                    if s.lowercased().hasPrefix("fe80") {
                        info.hasLinkLocalIPv6 = true
                    } else {
                        info.ipv6Addresses.append(s)
                    }
                default: continue
                }
            }
        }
        if let v6 = SystemNetworkStore.value(forKey: SystemNetworkStore.GlobalKey.ipv6),
            v6["PrimaryInterface"] as? String == name
        {
            info.ipv6Router = v6["Router"] as? String
        }
        return info
    }

    static func medium(of name: String) -> LinkInfo.Medium {
        #if os(macOS)
            switch SystemNetworkStore.interfaces().first(where: { $0.bsdName == name })?.type {
            case .wifi: return .wifi
            case .ethernet: return .ethernet
            case .other, nil: return .other
            }
        #else
            return name == "en0" ? .wifi : .other  // iPhone/iPad: en0 is the Wi-Fi interface
        #endif
    }

    private static func ipv6String(_ sa: UnsafeMutablePointer<sockaddr>) -> String? {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let rc = getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
        guard rc == 0 else { return nil }
        let s = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        // Drop the scope suffix ("fe80::1%en0").
        return s.split(separator: "%").first.map(String.init)
    }
}
