import Darwin
import Foundation

public protocol MACProvider: Sendable {
    func macAddresses() async -> [IPv4Address: MACAddress]
}

/// Reads the kernel ARP cache (no root, no `arp` subprocess).
public struct ARPTableMACProvider: MACProvider {
    public init() {}

    public func macAddresses() async -> [IPv4Address: MACAddress] {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: Self.read())
            }
        }
    }

    private static func read() -> [IPv4Address: MACAddress] {
        #if !os(macOS)
            return [:]  // no routing-socket ARP access outside macOS
        #else
            // On macOS 27 the kernel returns zero RTF_LLINFO entries to processes that lack
            // local-network access (the sysctl still succeeds). Child processes such as
            // /usr/sbin/arp inherit the restriction, so a subprocess fallback does not help.
            guard let buf = RouteTable.dump(flags: RTF_LLINFO) else { return [:] }
            var out: [IPv4Address: MACAddress] = [:]
            RouteTable.walk(buf) { _, addrs in
                guard let dst = addrs[Int(RTAX_DST)], RouteSockaddr.isIPv4(dst),
                    let ip = RouteSockaddr.ipv4(dst),
                    let link = addrs[Int(RTAX_GATEWAY)],
                    let mac = RouteSockaddr.mac(fromLink: link)  // nil when sdl_alen != 6 (incomplete)
                else { return }
                if mac.bytes[0] & 0x01 != 0 { return }  // multicast and ff:ff:ff:ff:ff:ff
                out[ip] = mac
            }
            return out
        #endif
    }
}
