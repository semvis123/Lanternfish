import Foundation
import LanternfishKit

/// Made-up neighbourhood for LANTERNFISH_WIFI_DEMO=1 snapshots (real scans need Location access to
/// show names). RSSI wobbles a little per tick so the animation can be seen.
enum AirwavesDemo {
    private struct Spec {
        let ssid: String?
        let mac: String
        let rssi: Int
        let channel: Int
        let band: WiFiBand
        let width: Int
        var secondary: SecondaryChannel?
        let security: WiFiSecurity
        let standard: WiFiStandard
    }

    private static let specs: [Spec] = [
        Spec(
            ssid: "Harbor", mac: "00:09:5b:12:34:51", rssi: -47, channel: 36, band: .ghz5, width: 80,
            security: .wpa2WPA3, standard: .ax),
        Spec(
            ssid: "Harbor", mac: "00:09:5b:12:34:50", rssi: -52, channel: 8, band: .ghz2, width: 20,
            security: .wpa2WPA3, standard: .ax),
        Spec(
            ssid: "Harbor", mac: "00:09:5b:12:34:52", rssi: -58, channel: 37, band: .ghz6, width: 160,
            security: .wpa3, standard: .ax),
        Spec(
            ssid: "Netlink-4F21", mac: "00:0e:59:aa:10:01", rssi: -61, channel: 6, band: .ghz2, width: 20,
            security: .wpa2, standard: .n),
        Spec(
            ssid: "Netlink-4F21", mac: "00:0e:59:aa:10:02", rssi: -66, channel: 44, band: .ghz5, width: 80,
            security: .wpa2, standard: .ac),
        Spec(
            ssid: "FRITZ!Box 7590 XZ", mac: "00:04:0e:7f:20:11", rssi: -68, channel: 11, band: .ghz2, width: 40,
            secondary: .below, security: .wpa2, standard: .ax),
        Spec(
            ssid: "FRITZ!Box 7590 XZ", mac: "00:04:0e:7f:20:12", rssi: -73, channel: 100, band: .ghz5, width: 160,
            security: .wpa2, standard: .ax),
        Spec(
            ssid: "TP-Link_5G_8A2C", mac: "00:0a:eb:8a:2c:01", rssi: -76, channel: 149, band: .ghz5, width: 80,
            security: .wpa2, standard: .ac),
        Spec(
            ssid: "TP-Link_8A2C", mac: "00:0a:eb:8a:2c:00", rssi: -71, channel: 9, band: .ghz2, width: 20,
            security: .wpaWPA2, standard: .n),
        Spec(
            ssid: nil, mac: "02:1a:11:44:55:66", rssi: -79, channel: 1, band: .ghz2, width: 20,
            security: .wpa2, standard: .n),
        Spec(
            ssid: "Free Public Wi-Fi", mac: "00:13:49:01:02:03", rssi: -83, channel: 6, band: .ghz2, width: 20,
            security: .open, standard: .n),
        Spec(
            ssid: "Ubiquiti Office", mac: "00:15:6d:33:44:55", rssi: -81, channel: 52, band: .ghz5, width: 40,
            security: .wpa2Enterprise, standard: .ac),
        Spec(
            ssid: "eero-guest", mac: "00:ab:48:01:aa:bb", rssi: -86, channel: 157, band: .ghz5, width: 20,
            security: .owe, standard: .ax),
        Spec(
            ssid: "Pixel_4821", mac: "da:00:5e:00:53:44", rssi: -88, channel: 11, band: .ghz2, width: 20,
            security: .wpa3, standard: .ax),
        Spec(
            ssid: "Apartment 4B", mac: "00:1a:11:66:77:88", rssi: -84, channel: 101, band: .ghz6, width: 320,
            security: .wpa3, standard: .be),
    ]

    static func results(tick: Int) -> [WiFiScanResult] {
        specs.enumerated().map { i, s in
            let wobble = Int((sin(Double(tick) * 0.9 + Double(i) * 1.7) * 3).rounded())
            return WiFiScanResult(
                ssid: s.ssid, bssid: s.mac, rssi: s.rssi + wobble, noise: -94,
                channel: s.channel, band: s.band, width: s.width, secondary: s.secondary,
                security: s.security, standard: s.standard, beaconInterval: 100,
                countryCode: "DE")
        }
    }

    static func connection(tick: Int) -> WiFiInfo {
        let r = results(tick: tick)[0]
        return WiFiInfo(
            interfaceName: "en0", ssid: r.ssid, bssid: r.bssid, channel: r.channel, band: r.band,
            channelWidth: r.width, rssi: r.rssi, noise: -94, txRate: 864, security: "WPA2/WPA3 Personal",
            phyMode: "802.11ax (Wi-Fi 6)", countryCode: "DE")
    }
}
