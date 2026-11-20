import Testing

@testable import LanternfishKit

@Suite struct NetworkSetTests {
    func iface(
        _ name: String, _ ip: String, gw: String?, prefix: Int = 24, primary: Bool = false,
        display: String? = nil, mac: String? = nil
    ) -> NetworkInterfaceInfo {
        let addr = IPv4Address(ip)!
        return NetworkInterfaceInfo(
            name: name, displayName: display ?? name, address: addr,
            subnet: Subnet(address: addr, prefixLength: prefix),
            mac: mac.flatMap(MACAddress.init), gateway: gw.flatMap(IPv4Address.init),
            isPrimary: primary)
    }

    // MARK: Dedupe

    @Test func distinctNetworksAreAllKept() {
        let en8 = iface("en8", "192.168.1.150", gw: "192.168.1.1", primary: true)
        let en0 = iface("en0", "10.0.0.8", gw: "10.0.0.1")
        #expect(NetworkSet.dedupe([en0, en8]).map(\.name) == ["en8", "en0"])
    }

    @Test func sameSubnetAndGatewayKeepsPrimary() {
        let wifi = iface("en0", "192.168.1.12", gw: "192.168.1.1")
        let eth = iface("en7", "192.168.1.13", gw: "192.168.1.1", primary: true)
        #expect(NetworkSet.dedupe([wifi, eth]).map(\.name) == ["en7"])
    }

    @Test func sameGatewayMACIsOneNetwork() {
        // Same router seen through two addresses (e.g. two VLAN-less subnets on one gateway).
        let a = iface("en0", "192.168.1.12", gw: "192.168.1.1", primary: true)
        let b = iface("en7", "192.168.2.12", gw: "192.168.2.1")
        let mac = MACAddress("00:00:5e:00:53:01")!
        #expect(NetworkSet.dedupe([a, b]).count == 2)
        let macs = [IPv4Address("192.168.1.1")!: mac, IPv4Address("192.168.2.1")!: mac]
        #expect(NetworkSet.dedupe([a, b], gatewayMACs: macs).map(\.name) == ["en0"])
    }

    @Test func differentGatewayMACsWithSameAddressesStayOneNetwork() {
        // Same subnet + gateway IP can't be routed separately anyway.
        let a = iface("en0", "192.168.1.12", gw: "192.168.1.1", primary: true)
        let b = iface("en7", "192.168.1.40", gw: "192.168.1.1")
        #expect(NetworkSet.dedupe([a, b]).count == 1)
    }

    @Test func noGatewaySameSubnetIsDuplicate() {
        let a = iface("en5", "198.51.100.2", gw: nil, primary: true)
        let b = iface("en6", "198.51.100.3", gw: nil)
        let c = iface("en9", "172.16.0.3", gw: nil)
        #expect(NetworkSet.dedupe([a, b, c]).map(\.name) == ["en5", "en9"])
    }

    @Test func dedupeIsStableForNonPrimaries() {
        let p = iface("en8", "192.168.1.150", gw: "192.168.1.1", primary: true)
        let x = iface("en0", "10.0.0.8", gw: "10.0.0.1")
        let y = iface("en3", "10.0.1.8", gw: "10.0.1.1")
        #expect(NetworkSet.dedupe([x, y, p]).map(\.name) == ["en8", "en0", "en3"])
    }

    // MARK: Diff

    @Test func diffAddsAndRemoves() {
        let en8 = iface("en8", "192.168.1.150", gw: "192.168.1.1", primary: true)
        let en0 = iface("en0", "10.0.0.8", gw: "10.0.0.1")
        let d = NetworkSet.diff(current: [en8], desired: [en0])
        #expect(d.added.map(\.name) == ["en0"])
        #expect(d.removed == ["en8"])
        #expect(d.changed.isEmpty && d.updated.isEmpty)
    }

    @Test func diffDetectsRescanAndCosmeticChanges() {
        let old0 = iface("en0", "10.0.0.8", gw: "10.0.0.1")
        let moved0 = iface("en0", "10.0.5.8", gw: "10.0.5.1")
        let old8 = iface("en8", "192.168.1.150", gw: "192.168.1.1")
        let promoted8 = iface("en8", "192.168.1.150", gw: "192.168.1.1", primary: true)
        let d = NetworkSet.diff(current: [old0, old8], desired: [promoted8, moved0])
        #expect(d.changed.map(\.name) == ["en0"])
        #expect(d.updated.map(\.name) == ["en8"])
        #expect(d.added.isEmpty && d.removed.isEmpty)
    }

    @Test func diffOfIdenticalSetsIsEmpty() {
        let a = [
            iface("en8", "192.168.1.150", gw: "192.168.1.1", primary: true), iface("en0", "10.0.0.8", gw: "10.0.0.1"),
        ]
        #expect(NetworkSet.diff(current: a, desired: a).isEmpty)
        #expect(NetworkSet.diff(current: a, desired: a.reversed()).isEmpty)
    }

    @Test func gatewayChangeNeedsRescan() {
        let a = iface("en0", "10.0.0.8", gw: nil)
        let b = iface("en0", "10.0.0.8", gw: "10.0.0.1")
        #expect(NetworkSet.needsRescan(from: a, to: b))
        #expect(!NetworkSet.needsRescan(from: a, to: a))
    }

    // MARK: Per-interface gateway

    @Test func secondaryInterfaceUsesItsScopedDefaultRoute() {
        let routes = [
            RouteTable.DefaultRoute(gateway: IPv4Address("192.168.1.1"), interface: "en8"),
            RouteTable.DefaultRoute(gateway: IPv4Address("10.0.0.1"), interface: "en0"),
            RouteTable.DefaultRoute(gateway: nil, interface: "bridge100"),
        ]
        let global = IPv4Address("192.168.1.1")
        let mask = IPv4Address("255.255.255.0")!
        #expect(
            NetworkInterfaces.gateway(
                forInterface: "en0", address: IPv4Address("10.0.0.8")!, netmask: mask,
                defaultRoutes: routes, globalGateway: global) == IPv4Address("10.0.0.1"))
        #expect(
            NetworkInterfaces.gateway(
                forInterface: "en8", address: IPv4Address("192.168.1.150")!, netmask: mask,
                defaultRoutes: routes, globalGateway: global) == global)
        // No own route: the global gateway only if it's in the subnet.
        #expect(
            NetworkInterfaces.gateway(
                forInterface: "en7", address: IPv4Address("192.168.1.50")!, netmask: mask,
                defaultRoutes: routes, globalGateway: global) == global)
        #expect(
            NetworkInterfaces.gateway(
                forInterface: "en9", address: IPv4Address("172.16.0.5")!, netmask: mask,
                defaultRoutes: routes, globalGateway: global) == nil)
    }

    @Test func scopedRouteOutsideSubnetIsIgnored() {
        let routes = [RouteTable.DefaultRoute(gateway: IPv4Address("10.9.9.1"), interface: "en0")]
        #expect(
            NetworkInterfaces.gateway(
                forInterface: "en0", address: IPv4Address("10.0.0.8")!,
                netmask: IPv4Address("255.255.255.0")!, defaultRoutes: routes,
                globalGateway: nil) == nil)
    }
}
