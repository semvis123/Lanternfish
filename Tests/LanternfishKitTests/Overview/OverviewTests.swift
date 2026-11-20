import Foundation
import Testing

@testable import LanternfishKit

@Suite struct OverviewTests {
    // MARK: InternetInfo parsing

    @Test func decodesCloudflareMeta() throws {
        let json = """
            {"hostname":"speed.cloudflare.com","clientIp":"203.0.113.7","httpProtocol":"HTTP/1.1",
             "asn":64500,"asOrganization":"Example Telecom","colo":"FRA","country":"DE","city":"Frankfurt",
             "region":"Hesse","postalCode":"60311","latitude":"50.11","longitude":"8.68","timezone":"Europe/Berlin"}
            """
        let info = try InternetInfoService.parseMeta(Data(json.utf8))
        #expect(info.ipv4 == "203.0.113.7")
        #expect(info.ipv6 == nil)
        #expect(info.asn == 64500)
        #expect(info.organization == "Example Telecom")
        #expect(info.city == "Frankfurt")
        #expect(info.region == "Hesse")
        #expect(info.country == "DE")
        #expect(info.colo == "FRA")
    }

    @Test func metaWithIPv6ClientAndStringASN() throws {
        let json = #"{"clientIp":"2001:db8::1","asn":"64500","asOrganization":"  ","city":""}"#
        let info = try InternetInfoService.parseMeta(Data(json.utf8))
        #expect(info.ipv6 == "2001:db8::1")
        #expect(info.ipv4 == nil)
        #expect(info.asn == 64500)
        #expect(info.organization == nil)
        #expect(info.city == nil)
    }

    @Test func metaRejectsEmptyAndNonJSON() {
        #expect(throws: (any Error).self) { try InternetInfoService.parseMeta(Data("{}".utf8)) }
        #expect(throws: (any Error).self) { try InternetInfoService.parseMeta(Data("<html>".utf8)) }
    }

    @Test func parsesDownloadMetaHeaders() {
        let info = InternetInfoService.parseHeaders([
            "cf-meta-ip": "198.51.100.4", "ASN": "64500", "City": "Frankfurt", "country": "DE",
            "colo": "FRA", "timezone": "Europe/Berlin",
        ])
        #expect(info.ipv4 == "198.51.100.4")
        #expect(info.asn == 64500)
        #expect(info.city == "Frankfurt")
        #expect(info.country == "DE")
        #expect(info.colo == "FRA")
        #expect(info.organization == nil)
    }

    @Test func parsesTrace() {
        let t = InternetInfoService.parseTrace("fl=1\nh=1.1.1.1\nip=192.0.2.9\ncolo=AMS\nloc=NL\nwarp=off\n")
        #expect(t["ip"] == "192.0.2.9")
        #expect(t["colo"] == "AMS")
        #expect(t["loc"] == "NL")
        #expect(t["h"] == "1.1.1.1")
    }

    // MARK: DNS

    @Test func parsesDNSDictionary() {
        let c = DNSConfig.parse([
            "ServerAddresses": ["192.168.1.1", "1.1.1.1", "192.168.1.1"],
            "SearchDomains": ["home", ""],
            "DomainName": "home",
        ])
        #expect(c.servers == ["192.168.1.1", "1.1.1.1"])
        #expect(c.searchDomains == ["home"])
        #expect(c.domainName == "home")
        #expect(c.usesRouter(IPv4Address("192.168.1.1")))
        #expect(!c.usesRouter(IPv4Address("192.168.1.254")))
        #expect(!c.usesRouter(nil))
        #expect(DNSConfig.parse([:]).servers.isEmpty)
    }

    @Test func recognizesPublicResolvers() {
        #expect(DNSConfiguration.publicResolverName("1.1.1.1") == "Cloudflare")
        #expect(DNSConfiguration.publicResolverName("8.8.4.4") == "Google")
        #expect(DNSConfiguration.publicResolverName("2606:4700:4700::1001") == "Cloudflare")
        #expect(DNSConfiguration.publicResolverName("192.168.1.1") == nil)
    }

    // MARK: Link / Wi-Fi labels

    @Test func formatsLinkSpeed() {
        #expect(LinkInfo.formatSpeed(1_000_000_000) == "1 Gbit/s")
        #expect(LinkInfo.formatSpeed(2_500_000_000) == "2.5 Gbit/s")
        #expect(LinkInfo.formatSpeed(100_000_000) == "100 Mbit/s")
    }

    @Test func ipv6Status() {
        #expect(LinkInfo(name: "en0", medium: .wifi).ipv6Status == "Off")
        #expect(LinkInfo(name: "en0", medium: .wifi, hasLinkLocalIPv6: true).ipv6Status == "Link-local only")
        #expect(
            LinkInfo(name: "en0", medium: .wifi, ipv6Addresses: ["2001:db8::2"], ipv6Router: "fe80::1")
                .ipv6Status == "Connected")
    }

    @Test func wifiLabels() {
        #expect(WiFiInfo.band(raw: 3, channel: 37) == .ghz6)
        #expect(WiFiInfo.band(raw: 0, channel: 6) == .ghz2)
        #expect(WiFiInfo.band(raw: 0, channel: 36) == .ghz5)
        #expect(WiFiInfo.band(raw: 0, channel: nil) == .unknown)
        #expect(WiFiInfo.widthMHz(raw: 3) == 80)
        #expect(WiFiInfo.widthMHz(raw: 0) == nil)
        #expect(WiFiInfo.phyModeLabel(raw: 6) == "802.11ax (Wi-Fi 6)")
        #expect(WiFiInfo.phyModeLabel(raw: 0) == nil)
        #expect(WiFiInfo.securityLabel(raw: 13) == "WPA2/WPA3 Personal")
        #expect(WiFiInfo.securityLabel(raw: Int.max) == nil)
    }

    @Test func wifiQuality() {
        #expect(WiFiInfo.quality(rssi: -45, noise: -95) == .excellent)
        #expect(WiFiInfo.quality(rssi: -60, noise: -92) == .good)
        #expect(WiFiInfo.quality(rssi: -72, noise: nil) == .fair)
        #expect(WiFiInfo.quality(rssi: -85, noise: -95) == .poor)
        // Low SNR caps the label even with a strong signal.
        #expect(WiFiInfo.quality(rssi: -50, noise: -70) == .fair)
        #expect(WiFiInfo.quality(rssi: -50, noise: -60) == .poor)
        let w = WiFiInfo(interfaceName: "en0", channel: 36, rssi: -58, noise: -90)
        #expect(w.snr == 32)
        #expect(w.isAssociated)
        #expect(!WiFiInfo(interfaceName: "en0").isAssociated)
    }

    // MARK: Speed math

    @Test func mbpsMath() {
        #expect(SpeedMath.mbps(bytes: 12_500_000, seconds: 1) == 100)
        #expect(SpeedMath.mbps(bytes: 125_000_000, seconds: 10) == 100)
        #expect(SpeedMath.mbps(bytes: 0, seconds: 1) == 0)
        #expect(SpeedMath.mbps(bytes: 10, seconds: 0) == 0)
    }

    @Test func jitterAndMedian() {
        #expect(SpeedMath.jitter([10, 12, 11, 15]) == (2 + 1 + 4) / 3.0)
        #expect(SpeedMath.jitter([20, 20, 20]) == 0)
        #expect(SpeedMath.jitter([5]) == nil)
        #expect(SpeedMath.median([3, 1, 2]) == 2)
        #expect(SpeedMath.median([4, 1, 3, 2]) == 2.5)
        #expect(SpeedMath.median([]) == nil)
    }

    @Test func throughputSkipsWarmup() {
        // 1 MB during warm-up, then 12.5 MB/s → 100 Mbps steady state.
        let samples: [(t: Double, bytes: Int64)] = [(0, 0), (1, 1_000_000), (2, 13_500_000), (3, 26_000_000)]
        let rate = SpeedMath.throughput(samples: samples, warmup: 1)
        #expect(rate == 100)
        // Too short for a warm-up cut: whole span.
        #expect(SpeedMath.throughput(samples: [(0, 0), (0.5, 6_250_000)], warmup: 1) == 100)
        #expect(SpeedMath.throughput(samples: [(0, 0)], warmup: 1) == nil)
        let live = SpeedMath.windowRate(samples: samples, window: 1)
        #expect(live == 100)
    }

    @Test func serverTimingAndRamp() {
        #expect(SpeedMath.serverTimeMs("cfSpeedEdge;dur=4, cfSpeedWorker;dur=23") == 23)
        #expect(SpeedMath.serverTimeMs(#"cfL4;desc="?proto=TCP&rtt=26024", cfSpeedWorker;dur=9.5"#) == 9.5)
        #expect(SpeedMath.serverTimeMs(nil) == nil)
        #expect(SpeedMath.nextSize(current: 1_000_000, lastDuration: 0.3, cap: 50_000_000) == 4_000_000)
        #expect(SpeedMath.nextSize(current: 40_000_000, lastDuration: 0.3, cap: 50_000_000) == 50_000_000)
        #expect(SpeedMath.nextSize(current: 4_000_000, lastDuration: 2, cap: 50_000_000) == 4_000_000)
    }

    // MARK: Live (LANTERNFISHKIT_NET=1)

    static var netEnabled: Bool { ProcessInfo.processInfo.environment["LANTERNFISHKIT_NET"] == "1" }

    private static func redact(_ ip: String?) -> String {
        guard let ip else { return "nil" }
        if ip.contains(":") { return ip.split(separator: ":").prefix(2).joined(separator: ":") + ":…" }
        return ip.split(separator: ".").prefix(2).joined(separator: ".") + ".x.x"
    }

    @Test(.enabled(if: netEnabled), .timeLimit(.minutes(1)))
    func liveInternetInfo() async throws {
        let info = try await InternetInfoService.fetch()
        print(
            "[overview] ipv4=\(Self.redact(info.ipv4)) ipv6=\(Self.redact(info.ipv6)) asn=\(info.asn.map(String.init) ?? "nil") org=\(info.organization ?? "nil") city=\(info.city ?? "nil") country=\(info.country ?? "nil") colo=\(info.colo ?? "nil")"
        )
        #expect(info.ipv4 != nil || info.ipv6 != nil)
        let pings = await InternetLatency.measure(count: 4)
        print(
            "[overview] ping 1.1.1.1: \(pings.map { $0.map { String(format: "%.1f ms", $0.seconds * 1000) } ?? "timeout" })"
        )
    }

    @Test(.enabled(if: netEnabled))
    func liveLocalInfo() {
        let dns = DNSConfig.current()
        print("[overview] dns servers=\(dns.servers) search=\(dns.searchDomains)")
        for iface in NetworkInterfaces.active() {
            let link = LinkInfoReader.read(iface.name)
            print(
                "[overview] \(iface.name) \(iface.displayName) \(link.medium) mtu=\(link.mtu.map(String.init) ?? "nil") speed=\(link.linkSpeed.map(LinkInfo.formatSpeed) ?? "nil") ipv6=\(link.ipv6Status) gw=\(iface.gateway?.description ?? "nil") dnsIsRouter=\(dns.usesRouter(iface.gateway))"
            )
        }
        for name in WiFiReader.interfaceNames() {
            if let w = WiFiReader.read(name) {
                print(
                    "[overview] wifi \(name) power=\(w.powerOn) ssid=\(w.ssid ?? "nil") bssid=\(w.bssid == nil ? "nil" : "present") ch=\(w.channel.map(String.init) ?? "nil") \(w.band.label) width=\(w.channelWidth.map(String.init) ?? "nil") rssi=\(w.rssi.map(String.init) ?? "nil") noise=\(w.noise.map(String.init) ?? "nil") tx=\(w.txRate.map { String($0) } ?? "nil") sec=\(w.security ?? "nil") phy=\(w.phyMode ?? "nil") cc=\(w.countryCode ?? "nil")"
                )
            }
        }
    }

    @Test(.enabled(if: netEnabled), .timeLimit(.minutes(1)))
    func liveSpeedTest() async {
        var last: SpeedTestProgress?
        var result: SpeedTestResult?
        var failure: String?
        var updates = 0
        for await event in SpeedTest().run() {
            switch event {
            case .progress(let p):
                last = p
                updates += 1
            case .finished(let r): result = r
            case .failed(let m): failure = m
            }
        }
        print("[overview] speed updates=\(updates) lastFraction=\(last?.fraction ?? -1) failure=\(failure ?? "nil")")
        if let r = result {
            print(
                String(
                    format:
                        "[overview] speed latency=%.1f ms jitter=%.1f ms down=%.1f Mbps up=%.1f Mbps (%.1f MB down, %.1f MB up)",
                    r.latencyMs ?? -1, r.jitterMs ?? -1, r.downloadMbps ?? -1, r.uploadMbps ?? -1,
                    Double(r.downloadedBytes) / 1e6, Double(r.uploadedBytes) / 1e6))
        }
        #expect(result != nil)
    }
}
