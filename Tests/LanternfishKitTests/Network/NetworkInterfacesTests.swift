import Darwin
import Foundation
import Testing

@testable import LanternfishKit

/// Reads this Mac's real interfaces, routes and ARP cache, so the results depend on the network
/// it is on (CI runners may have no gateway at all). Opt in with `LANTERNFISHKIT_NET=1 swift test`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["LANTERNFISHKIT_NET"] == "1"))
struct NetworkInterfacesTests {
    @Test func activeHasExactlyOnePrimary() {
        let ifaces = NetworkInterfaces.active()
        #expect(!ifaces.isEmpty)
        #expect(ifaces.filter(\.isPrimary).count == 1)
        #expect(ifaces.first?.isPrimary == true)
        for i in ifaces {
            print("iface", i.name, i.displayName, i.address, i.subnet, i.mac as Any, i.gateway as Any, i.isPrimary)
        }
    }

    @Test func defaultGatewayInPrimarySubnet() throws {
        let gw = try #require(NetworkInterfaces.defaultGateway())
        let primary = try #require(NetworkInterfaces.active().first { $0.isPrimary })
        let p = primary.subnet.prefixLength
        let mask: UInt32 = p == 0 ? 0 : ~UInt32(0) << (32 - p)
        #expect(gw.value & mask == primary.address.value & mask)
        #expect(primary.gateway == gw)
    }

    @Test func arpTableContainsGateway() async throws {
        let gw = try #require(NetworkInterfaces.defaultGateway())
        poke(gw)
        try await Task.sleep(for: .milliseconds(300))
        let table = await ARPTableMACProvider().macAddresses()
        print("arp entries:", table.count, "gateway mac:", table[gw] as Any)
        if table.isEmpty {
            // macOS 27 hides the ARP cache from processes without local-network access
            // (e.g. test runners launched from some terminals). The app bundle is granted it.
            withKnownIssue("ARP table hidden from this process by local-network privacy") {
                #expect(table[gw] != nil)
            }
        } else {
            #expect(table[gw] != nil)
        }
        #expect(!table.values.contains { $0.bytes == [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF] })
    }

    /// Sends a UDP datagram to the discard port so the kernel resolves the gateway via ARP.
    private func poke(_ ip: IPv4Address) {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var addr = sockaddr_in.make(ip, port: 9)
        var byte: UInt8 = 0
        _ = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(fd, &byte, 1, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
    }
}
