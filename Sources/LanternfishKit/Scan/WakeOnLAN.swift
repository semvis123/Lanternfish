import Darwin
import Foundation

/// Wake-on-LAN: builds and broadcasts "magic packets" (6 × 0xFF, then the target MAC 16 times,
/// optionally followed by a 4- or 6-byte SecureOn password).
public enum WakeOnLAN {
    /// One UDP destination of a wake request.
    public struct Destination: Hashable, Sendable {
        public let address: IPv4Address
        public let port: UInt16
        public init(_ address: IPv4Address, port: UInt16) {
            self.address = address
            self.port = port
        }
    }

    public enum WakeError: Error, CustomStringConvertible {
        case socket(errno: Int32)
        case unknownInterface(String)
        /// Every datagram failed to send; `errno` is the last failure.
        case sendFailed(errno: Int32)

        public var description: String {
            switch self {
            case .socket(let e): "Could not open a UDP socket (\(String(cString: strerror(e))))"
            case .unknownInterface(let n): "Unknown network interface \(n)"
            case .sendFailed(let e): "Could not send the magic packet (\(String(cString: strerror(e))))"
            }
        }
    }

    /// The limited broadcast address 255.255.255.255.
    public static let limitedBroadcast = IPv4Address(0xFFFF_FFFF)

    /// The 102-byte magic packet for `mac` (108 or 106 bytes with a SecureOn password).
    /// Passwords other than 4 or 6 bytes long are ignored.
    public static func magicPacket(for mac: MACAddress, password: [UInt8]? = nil) -> [UInt8] {
        var packet = [UInt8](repeating: 0xFF, count: 6)
        packet.reserveCapacity(6 + 16 * 6 + 6)
        for _ in 0..<16 { packet += mac.bytes }
        if let password, password.count == 4 || password.count == 6 { packet += password }
        return packet
    }

    /// Directed broadcast address of `subnet` (e.g. 192.168.1.255 for 192.168.1.0/24).
    /// /31 and /32 have none; their address is returned unchanged.
    public static func broadcastAddress(of subnet: Subnet) -> IPv4Address {
        guard subnet.prefixLength < 31 else { return subnet.address }
        let mask: UInt32 = subnet.prefixLength == 0 ? 0 : ~UInt32(0) << (32 - subnet.prefixLength)
        return IPv4Address((subnet.address.value & mask) | ~mask)
    }

    /// Wakes `mac`: sends the magic packet to `broadcast` (the subnet's broadcast address) and to
    /// 255.255.255.255, on `port` and on port 7, three times about 100 ms apart. With `interface`
    /// (a BSD name such as "en0") the datagrams leave through that interface (IP_BOUND_IF), which
    /// matters when the Mac is on several networks. Throws only when no datagram could be sent.
    public static func wake(
        _ mac: MACAddress, broadcast: IPv4Address, port: UInt16 = 9,
        interface: String? = nil, password: [UInt8]? = nil
    ) async throws {
        var ifIndex: UInt32?
        if let interface {
            let idx = if_nametoindex(interface)
            guard idx != 0 else { throw WakeError.unknownInterface(interface) }
            ifIndex = idx
        }
        var destinations: [Destination] = []
        for address in [broadcast, limitedBroadcast] {
            for p in [port, 7] {
                let d = Destination(address, port: p)
                if !destinations.contains(d) { destinations.append(d) }
            }
        }
        try await send(magicPacket(for: mac, password: password), to: destinations, interfaceIndex: ifIndex)
    }

    /// Sends `packet` to every destination, `repeats` times `interval` apart, from one UDP socket
    /// with SO_BROADCAST (and IP_BOUND_IF when `interfaceIndex` is set). Returns the number of
    /// datagrams sent; throws when there were none.
    @discardableResult
    public static func send(
        _ packet: [UInt8], to destinations: [Destination], interfaceIndex: UInt32? = nil,
        repeats: Int = 3, interval: Duration = .milliseconds(100)
    ) async throws -> Int {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw WakeError.socket(errno: errno) }
        defer { close(fd) }
        var on: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw WakeError.socket(errno: errno)
        }
        if var idx = interfaceIndex {
            guard setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &idx, socklen_t(MemoryLayout<UInt32>.size)) == 0 else {
                throw WakeError.socket(errno: errno)
            }
        }

        var sent = 0
        var lastError: Int32 = 0
        for round in 0..<max(1, repeats) {
            if round > 0 { try? await Task.sleep(for: interval) }
            if Task.isCancelled { break }
            for d in destinations {
                var addr = sockaddr_in.make(d.address, port: d.port)
                let n = packet.withUnsafeBytes { buf in
                    withUnsafePointer(to: &addr) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            sendto(fd, buf.baseAddress, buf.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                        }
                    }
                }
                if n == packet.count { sent += 1 } else { lastError = errno }
            }
        }
        guard sent > 0 else { throw WakeError.sendFailed(errno: lastError) }
        return sent
    }
}
