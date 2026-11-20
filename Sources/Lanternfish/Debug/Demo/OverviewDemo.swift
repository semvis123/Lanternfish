import Foundation
import LanternfishKit

/// Made-up overview for LANTERNFISH_PREVIEW=1 snapshots, so screenshots never show a real public IP,
/// provider or location. Addresses come from the documentation ranges (RFC 5737, RFC 3849).
enum OverviewDemo {
    static let internet = InternetInfo(
        ipv4: "203.0.113.42", ipv6: "2001:db8:4f21::1a", asn: 64500, organization: "Example Telecom",
        city: "Frankfurt", region: "Hesse", country: "DE", colo: "FRA", timezone: "Europe/Berlin")

    static let pings: [Duration?] = [.milliseconds(9), .milliseconds(8), .milliseconds(11), .milliseconds(9)]

    static let dns = DNSConfiguration(servers: ["192.168.1.1", "1.1.1.1"], searchDomains: ["home"], domainName: "home")

    static let link = LinkInfo(
        name: "en0", medium: .wifi, mtu: 1500, linkSpeed: 1_201_000_000,
        ipv6Addresses: ["2001:db8:4f21::1a"], hasLinkLocalIPv6: true, ipv6Router: "fe80::1")

    static var wifi: WiFiInfo { AirwavesDemo.connection(tick: 0) }

    static let speed = SpeedTestResult(
        date: Date().addingTimeInterval(-600), latencyMs: 9.4, jitterMs: 1.2, downloadMbps: 487.3,
        uploadMbps: 94.8, downloadedBytes: 548_000_000, uploadedBytes: 106_000_000)
}
