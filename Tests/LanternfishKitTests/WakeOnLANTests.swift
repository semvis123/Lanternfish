import Darwin
import Foundation
import Testing

@testable import LanternfishKit

@Suite(.timeLimit(.minutes(1)))
struct WakeOnLANTests {
    private let mac = MACAddress("00:11:32:AB:CD:EF")!

    @Test func magicPacketIsSyncStreamThenSixteenMACs() {
        let p = WakeOnLAN.magicPacket(for: mac)
        #expect(p.count == 102)
        #expect(Array(p[0..<6]) == [UInt8](repeating: 0xFF, count: 6))
        for i in 0..<16 {
            let start = 6 + i * 6
            #expect(Array(p[start..<start + 6]) == mac.bytes)
        }
    }

    @Test func secureOnPasswordIsAppended() {
        let six: [UInt8] = [1, 2, 3, 4, 5, 6]
        let p6 = WakeOnLAN.magicPacket(for: mac, password: six)
        #expect(p6.count == 108)
        #expect(Array(p6.suffix(6)) == six)

        let four: [UInt8] = [192, 168, 1, 9]
        let p4 = WakeOnLAN.magicPacket(for: mac, password: four)
        #expect(p4.count == 106)
        #expect(Array(p4.suffix(4)) == four)
        #expect(Array(p4.prefix(102)) == WakeOnLAN.magicPacket(for: mac))
    }

    @Test func invalidPasswordLengthsAreIgnored() {
        #expect(WakeOnLAN.magicPacket(for: mac, password: [1, 2, 3]).count == 102)
        #expect(WakeOnLAN.magicPacket(for: mac, password: []).count == 102)
    }

    @Test func broadcastAddresses() {
        let s24 = Subnet(address: IPv4Address("192.168.1.12")!, prefixLength: 24)
        #expect(WakeOnLAN.broadcastAddress(of: s24).description == "192.168.1.255")
        let s16 = Subnet(address: IPv4Address("10.0.42.7")!, prefixLength: 16)
        #expect(WakeOnLAN.broadcastAddress(of: s16).description == "10.0.255.255")
        let s22 = Subnet(address: IPv4Address("172.16.5.1")!, prefixLength: 22)
        #expect(WakeOnLAN.broadcastAddress(of: s22).description == "172.16.7.255")
        let s32 = Subnet(address: IPv4Address("10.1.2.3")!, prefixLength: 32)
        #expect(WakeOnLAN.broadcastAddress(of: s32).description == "10.1.2.3")
    }

    /// A UDP socket on 127.0.0.1 with an OS-assigned port, read with a timeout.
    private final class Receiver {
        let fd: Int32
        let port: UInt16

        init() throws {
            let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
            self.fd = fd
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
            let ok = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard fd >= 0, ok == 0 else {
                close(fd)
                throw WakeOnLAN.WakeError.socket(errno: errno)
            }
            var bound = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            _ = withUnsafeMutablePointer(to: &bound) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
            }
            port = UInt16(bigEndian: bound.sin_port)
            var tv = timeval(tv_sec: 1, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        }

        deinit { close(fd) }

        /// Every datagram that arrives before a 1 s silence.
        func drain() -> [[UInt8]] {
            var out: [[UInt8]] = []
            var buf = [UInt8](repeating: 0, count: 2048)
            while true {
                let n = recv(fd, &buf, buf.count, 0)
                if n <= 0 { break }
                out.append(Array(buf[0..<n]))
            }
            return out
        }
    }

    @Test func sendDeliversRepeatedPacketsToLoopbackReceiver() async throws {
        let rx = try Receiver()
        let packet = WakeOnLAN.magicPacket(for: mac)
        let start = ContinuousClock.now
        let sent = try await WakeOnLAN.send(
            packet, to: [.init(IPv4Address("127.0.0.1")!, port: rx.port)],
            repeats: 3, interval: .milliseconds(100))
        let elapsed = ContinuousClock.now - start
        #expect(sent == 3)
        #expect(elapsed >= .milliseconds(190))
        let got = rx.drain()
        #expect(got.count == 3)
        #expect(got.allSatisfy { $0 == packet })
    }

    @Test func sendBoundToLoopbackInterface() async throws {
        let rx = try Receiver()
        let lo0 = if_nametoindex("lo0")
        #expect(lo0 != 0)
        let packet = WakeOnLAN.magicPacket(for: mac, password: [9, 8, 7, 6])
        let sent = try await WakeOnLAN.send(
            packet, to: [.init(IPv4Address("127.0.0.1")!, port: rx.port)],
            interfaceIndex: lo0, repeats: 2, interval: .milliseconds(10))
        #expect(sent == 2)
        #expect(rx.drain() == [packet, packet])
    }

    @Test func wakeRejectsUnknownInterface() async {
        await #expect(throws: WakeOnLAN.WakeError.self) {
            try await WakeOnLAN.wake(mac, broadcast: IPv4Address("127.255.255.255")!, interface: "nosuch99")
        }
    }
}
