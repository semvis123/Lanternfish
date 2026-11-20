import Darwin
import Foundation

/// Enumerates the Mac's IPv4 interfaces and their gateways.
public enum NetworkInterfaces {
    /// Active IPv4 interfaces (up, running, non-loopback, no tunnels/AWDL/bridges). Primary first.
    public static func active() -> [NetworkInterfaceInfo] {
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return [] }
        defer { freeifaddrs(ifap) }

        struct V4 {
            let name: String
            let address: IPv4Address
            let netmask: IPv4Address
        }
        var v4: [V4] = []
        var macs: [String: MACAddress] = [:]

        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let sa = ifa.ifa_addr else { continue }
            let name = String(cString: ifa.ifa_name)
            switch Int32(sa.pointee.sa_family) {
            case AF_LINK:
                if let mac = RouteSockaddr.mac(fromLink: UnsafeRawPointer(sa)) { macs[name] = mac }
            case AF_INET:
                let flags = Int32(bitPattern: ifa.ifa_flags)
                guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0,
                    flags & IFF_LOOPBACK == 0, flags & IFF_POINTOPOINT == 0,
                    !isExcluded(name),
                    let addr = RouteSockaddr.ipv4(UnsafeRawPointer(sa))
                else { continue }
                let mask =
                    ifa.ifa_netmask.flatMap { RouteSockaddr.ipv4(UnsafeRawPointer($0)) }
                    ?? IPv4Address(0xFFFF_FF00)
                // Skip link-local 169.254/16 self-assigned addresses.
                if addr.value & 0xFFFF_0000 == 0xA9FE_0000 { continue }
                v4.append(V4(name: name, address: addr, netmask: mask))
            default:
                continue
            }
        }

        // macOS 27 redacts AF_LINK addresses to 02:00:00:00:00:00 for non-platform binaries.
        let redacted = MACAddress(bytes: [0x02, 0, 0, 0, 0, 0])
        if v4.contains(where: { macs[$0.name] == nil || macs[$0.name] == redacted }) {
            // Fall back to the burned-in hardware address (may differ from a private Wi-Fi MAC).
            let fallback = hardwareMACs()
            for entry in v4 where macs[entry.name] == nil || macs[entry.name] == redacted {
                macs[entry.name] = fallback[entry.name]
            }
        }

        let displayNames = localizedDisplayNames()
        let allRoutes = RouteTable.defaultRoutes()
        let route = RouteTable.preferred(in: allRoutes)
        let primaryName = primaryInterfaceFromDynamicStore() ?? route?.interface

        var seen = Set<String>()
        var result: [NetworkInterfaceInfo] = []
        for entry in v4 where seen.insert(entry.name).inserted {
            let subnet = Subnet(address: entry.address, netmask: entry.netmask)
            let gw = gateway(
                forInterface: entry.name, address: entry.address, netmask: entry.netmask,
                defaultRoutes: allRoutes, globalGateway: route?.gateway)
            result.append(
                NetworkInterfaceInfo(
                    name: entry.name,
                    displayName: displayNames[entry.name] ?? entry.name,
                    address: entry.address,
                    subnet: subnet,
                    mac: macs[entry.name],
                    gateway: gw,
                    isPrimary: entry.name == primaryName
                ))
        }
        // If no interface matched the primary name, promote the first one with a gateway (or the first).
        if !result.contains(where: \.isPrimary), !result.isEmpty {
            let idx = result.firstIndex(where: { $0.gateway != nil }) ?? 0
            let r = result[idx]
            result[idx] = NetworkInterfaceInfo(
                name: r.name, displayName: r.displayName, address: r.address,
                subnet: r.subnet, mac: r.mac, gateway: r.gateway, isPrimary: true)
        }
        result.sort { a, b in
            if a.isPrimary != b.isPrimary { return a.isPrimary }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        return result
    }

    /// Gateway of the IPv4 default route, from the kernel routing table.
    public static func defaultGateway() -> IPv4Address? {
        RouteTable.defaultRoute()?.gateway
    }

    /// An interface's gateway: its own (interface-scoped) default route's gateway, else the
    /// global default gateway — either only when it lies inside the interface's subnet.
    /// Secondary interfaces (e.g. Wi-Fi while Ethernet is primary) only have a scoped route.
    static func gateway(
        forInterface name: String, address: IPv4Address, netmask: IPv4Address,
        defaultRoutes: [RouteTable.DefaultRoute], globalGateway: IPv4Address?
    ) -> IPv4Address? {
        func inSubnet(_ g: IPv4Address) -> Bool {
            g.value & netmask.value == address.value & netmask.value && g != address
        }
        if let own = defaultRoutes.first(where: { $0.interface == name && $0.gateway.map(inSubnet) == true }) {
            return own.gateway
        }
        if let g = globalGateway, inSubnet(g) { return g }
        return nil
    }

    // MARK: - Helpers

    private static let excludedPrefixes = ["utun", "awdl", "llw", "bridge", "anpi", "ipsec", "ppp", "gif", "stf", "ap"]

    private static func isExcluded(_ name: String) -> Bool {
        excludedPrefixes.contains { name.hasPrefix($0) }
    }

    // The helpers below read `SystemNetworkStore` (SystemConfiguration, macOS only). Elsewhere it
    // returns nothing: the BSD name doubles as the display name and the primary interface comes
    // from the routing table.

    private static func localizedDisplayNames() -> [String: String] {
        var out: [String: String] = [:]
        for iface in SystemNetworkStore.interfaces() {
            if let display = iface.displayName { out[iface.bsdName] = display }
        }
        return out
    }

    /// Burned-in hardware addresses from SystemConfiguration (last resort; may differ from the
    /// private Wi-Fi address actually used on the wire).
    private static func hardwareMACs() -> [String: MACAddress] {
        var out: [String: MACAddress] = [:]
        for iface in SystemNetworkStore.interfaces() {
            if let hw = iface.hardwareAddress, let mac = MACAddress(hw) { out[iface.bsdName] = mac }
        }
        return out
    }

    private static func primaryInterfaceFromDynamicStore() -> String? {
        SystemNetworkStore.value(forKey: SystemNetworkStore.GlobalKey.ipv4)?["PrimaryInterface"] as? String
    }
}

// MARK: - Routing table

/// The kernel routing table via `sysctl(NET_RT_FLAGS)`. The `rt_msghdr` layout is only in the
/// macOS SDK; elsewhere there are no routes (callers then fall back to heuristics).
enum RouteTable {
    struct DefaultRoute {
        let gateway: IPv4Address?
        let interface: String?
        /// Interface-scoped (`RTF_IFSCOPE`): only used for traffic bound to `interface`.
        var isScoped = false
    }

    /// The system-wide default route: the first global one, else the first scoped one.
    static func preferred(in routes: [DefaultRoute]) -> DefaultRoute? {
        routes.first { !$0.isScoped } ?? routes.first
    }

    #if !os(macOS)
        static func defaultRoutes() -> [DefaultRoute] { [] }
        static func defaultRoute() -> DefaultRoute? { nil }
    #else

        /// Dumps routes via sysctl; `flags` filters on rt_flags (NET_RT_FLAGS).
        static func dump(flags: Int32) -> [UInt8]? {
            var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_FLAGS, flags]
            for _ in 0..<3 {
                var len = 0
                guard sysctl(&mib, UInt32(mib.count), nil, &len, nil, 0) == 0 else { return nil }
                if len == 0 { return [] }
                len += len / 8  // table may grow between calls
                var buf = [UInt8](repeating: 0, count: len)
                let rc = buf.withUnsafeMutableBytes { sysctl(&mib, UInt32(mib.count), $0.baseAddress, &len, nil, 0) }
                if rc == 0 { return Array(buf.prefix(len)) }
                if errno != ENOMEM { return nil }
            }
            return nil
        }

        /// Iterates rt_msghdr records, passing the header and the sockaddr pointers indexed by RTAX_*.
        static func walk(_ buf: [UInt8], _ body: (rt_msghdr, [UnsafeRawPointer?]) -> Void) {
            buf.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                var offset = 0
                let hdrSize = MemoryLayout<rt_msghdr>.size
                while offset + hdrSize <= raw.count {
                    let hdr = base.loadUnaligned(fromByteOffset: offset, as: rt_msghdr.self)
                    let msgLen = Int(hdr.rtm_msglen)
                    guard msgLen > 0, offset + msgLen <= raw.count else { break }
                    var addrs = [UnsafeRawPointer?](repeating: nil, count: Int(RTAX_MAX))
                    var sp = offset + hdrSize
                    let end = offset + msgLen
                    for i in 0..<Int(RTAX_MAX) where hdr.rtm_addrs & (1 << i) != 0 {
                        guard sp < end else { break }
                        let saLen = Int(base.load(fromByteOffset: sp, as: UInt8.self))
                        addrs[i] = base + sp
                        sp += RouteSockaddr.roundup(saLen)
                    }
                    body(hdr, addrs)
                    offset += msgLen
                }
            }
        }

        /// Every IPv4 default route (global and interface-scoped), in table order.
        static func defaultRoutes() -> [DefaultRoute] {
            guard let buf = dump(flags: RTF_GATEWAY) else { return [] }
            var out: [DefaultRoute] = []
            walk(buf) { hdr, addrs in
                guard let dst = addrs[Int(RTAX_DST)], RouteSockaddr.isIPv4(dst),
                    RouteSockaddr.ipv4(dst)?.value == 0
                else { return }
                // Netmask must be absent or all-zero for 0.0.0.0/0.
                if let m = addrs[Int(RTAX_NETMASK)], let mask = RouteSockaddr.maskValue(m), mask != 0 { return }
                let gw = addrs[Int(RTAX_GATEWAY)].flatMap { RouteSockaddr.isIPv4($0) ? RouteSockaddr.ipv4($0) : nil }
                var nameBuf = [CChar](repeating: 0, count: Int(IF_NAMESIZE) + 1)
                let ifName =
                    if_indextoname(UInt32(hdr.rtm_index), &nameBuf) != nil
                    ? String(decoding: nameBuf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) : nil
                out.append(
                    DefaultRoute(gateway: gw, interface: ifName, isScoped: hdr.rtm_flags & RTF_IFSCOPE != 0))
            }
            return out
        }

        static func defaultRoute() -> DefaultRoute? { preferred(in: defaultRoutes()) }
    #endif
}

// MARK: - Sockaddr helpers

enum RouteSockaddr {
    /// macOS routing-socket alignment: round up to 4 bytes, a zero length occupies 4 bytes.
    static func roundup(_ len: Int) -> Int {
        len > 0 ? 1 + ((len - 1) | (MemoryLayout<UInt32>.size - 1)) : MemoryLayout<UInt32>.size
    }

    static func isIPv4(_ p: UnsafeRawPointer) -> Bool {
        p.load(fromByteOffset: 1, as: UInt8.self) == UInt8(AF_INET)
    }

    /// Reads sin_addr (offset 4) of a sockaddr_in / sockaddr_inarp. Returns host byte order.
    static func ipv4(_ p: UnsafeRawPointer) -> IPv4Address? {
        let len = Int(p.load(fromByteOffset: 0, as: UInt8.self))
        guard len >= 8 else { return len == 0 ? IPv4Address(0) : nil }
        let raw = p.loadUnaligned(fromByteOffset: 4, as: UInt32.self)
        return IPv4Address(UInt32(bigEndian: raw))
    }

    /// Netmask sockaddrs may be truncated (sa_len < 8); missing bytes are zero.
    static func maskValue(_ p: UnsafeRawPointer) -> UInt32? {
        let len = Int(p.load(fromByteOffset: 0, as: UInt8.self))
        var bytes: [UInt8] = [0, 0, 0, 0]
        for i in 0..<4 where 4 + i < len {
            bytes[i] = p.load(fromByteOffset: 4 + i, as: UInt8.self)
        }
        return bytes.reduce(0) { $0 << 8 | UInt32($1) }
    }

    /// Reads a 6-byte link-layer address from a sockaddr_dl.
    static func mac(fromLink p: UnsafeRawPointer) -> MACAddress? {
        guard p.load(fromByteOffset: 1, as: UInt8.self) == UInt8(AF_LINK) else { return nil }
        // sockaddr_dl header: len, family, index(2), type, nlen, alen, slen, then data.
        let saLen = Int(p.load(fromByteOffset: 0, as: UInt8.self))
        let nlen = Int(p.load(fromByteOffset: 5, as: UInt8.self))
        let alen = Int(p.load(fromByteOffset: 6, as: UInt8.self))
        let start = 8 + nlen
        guard alen == 6, start + 6 <= saLen else { return nil }
        let bytes = (0..<6).map { p.load(fromByteOffset: start + $0, as: UInt8.self) }
        guard bytes.contains(where: { $0 != 0 }) else { return nil }
        return MACAddress(bytes: bytes)
    }
}
