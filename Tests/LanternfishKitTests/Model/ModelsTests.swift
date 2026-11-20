import Testing

@testable import LanternfishKit

@Suite struct ModelsTests {
    @Test func subnetContains() {
        let net = Subnet(address: IPv4Address("192.168.1.12")!, prefixLength: 24)
        #expect(net.contains(IPv4Address("192.168.1.200")!))
        #expect(!net.contains(IPv4Address("192.168.2.1")!))
        #expect(!net.contains(IPv4Address("8.8.8.8")!))
        #expect(Subnet(address: IPv4Address("10.0.0.1")!, prefixLength: 0).contains(IPv4Address("8.8.8.8")!))
    }

    @Test func ipParsesAndPrints() {
        #expect(IPv4Address("192.168.1.12")?.description == "192.168.1.12")
        #expect(IPv4Address("192.168.1") == nil)
        #expect(IPv4Address("192.168.1.256") == nil)
    }

    @Test func ipSortsNumerically() {
        let ips = ["192.168.1.100", "192.168.1.9", "192.168.1.20"].compactMap(IPv4Address.init)
        #expect(ips.sorted().map(\.description) == ["192.168.1.9", "192.168.1.20", "192.168.1.100"])
    }

    @Test func slash24ExcludesNetworkAndBroadcast() {
        let s = Subnet(address: IPv4Address("192.168.1.12")!, prefixLength: 24)
        let hosts = s.scanHosts()
        #expect(hosts.count == 254)
        #expect(hosts.first?.description == "192.168.1.1")
        #expect(hosts.last?.description == "192.168.1.254")
    }

    @Test func slash16NarrowsToSurroundingSlash24() {
        let s = Subnet(address: IPv4Address("10.0.42.7")!, netmask: IPv4Address("255.255.0.0")!)
        #expect(s.prefixLength == 16)
        let hosts = s.scanHosts()
        #expect(hosts.count == 254)
        #expect(hosts.first?.description == "10.0.42.1")
        #expect(hosts.last?.description == "10.0.42.254")
    }

    @Test func subnetDescriptionIsCIDR() {
        #expect(Subnet(address: IPv4Address("192.168.1.12")!, prefixLength: 24).description == "192.168.1.0/24")
    }

    @Test func macParsesArpStyleDroppedZeros() {
        #expect(MACAddress("a4:83:e7:1:2:c")?.description == "A4:83:E7:01:02:0C")
        #expect(MACAddress("A4-83-E7-01-02-0C")?.ouiPrefix == "A483E7")
        #expect(MACAddress("a4:83:e7") == nil)
    }

    @Test func macLocallyAdministeredBit() {
        #expect(MACAddress("a4:83:e7:01:02:0c")!.isLocallyAdministered == false)
        #expect(MACAddress("da:00:5e:00:53:01")!.isLocallyAdministered == true)
    }

    @Test func mergeUnionsPortsAndServices() {
        let ip = IPv4Address("192.168.1.5")!
        var d = Device(ip: ip)
        var p1 = DevicePatch(ip: ip)
        p1.openPorts = [OpenPort(port: 80), OpenPort(port: 22)]
        p1.services = ["SSH"]
        p1.mac = MACAddress("da:00:5e:00:53:01")
        d.merge(p1)
        var p2 = DevicePatch(ip: ip)
        p2.openPorts = [OpenPort(port: 443, service: "HTTPS"), OpenPort(port: 80)]
        p2.services = ["AirPlay"]
        p2.name = "Living Room TV"
        d.merge(p2)
        #expect(d.openPorts.map(\.port) == [22, 80, 443])
        #expect(d.services == ["SSH", "AirPlay"])
        #expect(d.displayName == "Living Room TV")
        #expect(d.isPrivateMAC)
    }

    @Test func displayNameFallbacks() {
        var d = Device(ip: IPv4Address("192.168.1.5")!)
        #expect(d.displayName == "192.168.1.5")
        d.vendor = "Apple"
        #expect(d.displayName == "Apple")
        d.hostname = "sams-mbp.local"
        #expect(d.displayName == "sams-mbp")
    }

    @Test func brandModelAvoidsDuplication() {
        var d = Device(ip: IPv4Address("192.168.1.5")!)
        d.vendor = "Samsung"
        d.model = "Samsung QLED TV"
        #expect(d.brandModel == "Samsung QLED TV")
        d.model = "OfficeJet 8015"
        d.manufacturer = "HP"
        #expect(d.brandModel == "HP OfficeJet 8015")
    }

    @Test func webPortURLs() {
        let ip = IPv4Address("192.168.1.1")!
        #expect(OpenPort(port: 80).url(host: ip)?.absoluteString == "http://192.168.1.1")
        #expect(OpenPort(port: 443).url(host: ip)?.absoluteString == "https://192.168.1.1")
        #expect(OpenPort(port: 8080).url(host: ip)?.absoluteString == "http://192.168.1.1:8080")
        #expect(OpenPort(port: 22).url(host: ip) == nil)
    }
}
