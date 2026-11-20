import Foundation
import LanternfishKit

/// Made-up home network for SwiftUI previews and `LANTERNFISH_PREVIEW=1` screenshots. Addresses are in
/// a private range, MAC suffixes are invented, and names are generic.
extension ScanStore {
    static func preview(history: SharedHistory = SharedHistory(directory: nil)) -> ScanStore {
        let address = IPv4Address("192.168.1.12")!
        let iface = NetworkInterfaceInfo(
            name: "en0", displayName: "Wi-Fi", address: address,
            subnet: Subnet(address: address, prefixLength: 24), mac: MACAddress("a4:83:e7:00:00:0c"),
            gateway: IPv4Address("192.168.1.1"), isPrimary: true)

        let now = Date()
        let day: TimeInterval = 86_400
        var devices = [
            device(
                "192.168.1.1", "50:c7:bf:11:22:33", vendor: "TP-Link", name: "Router", model: "Archer AX55",
                kind: .router, ports: [(53, "DNS"), (80, "HTTP"), (443, "HTTPS")], ms: 1),
            device(
                "192.168.1.12", "a4:83:e7:00:00:0c", vendor: "Apple", name: "Sam's MacBook Pro",
                host: "sams-mbp.local", model: "MacBook Pro", kind: .computer,
                ports: [(22, "SSH"), (445, "SMB"), (5000, "AirPlay"), (7000, "AirPlay")],
                services: ["SSH", "AirPlay", "File Sharing"], ms: 0),
            device(
                "192.168.1.20", "8c:79:f5:aa:bb:cc", vendor: "Samsung Electronics", name: "Living Room TV",
                model: "QLED TV", kind: .tv, ports: [(8001, "Samsung TV"), (9197, "DLNA")],
                services: ["AirPlay"], ms: 6),
            device("192.168.1.31", "da:00:5e:00:53:01", vendor: nil, name: "iPhone", kind: .phone, ms: 12),
            device(
                "192.168.1.44", "3c:52:82:01:02:03", vendor: "HP", name: "HP-Printer", model: "OfficeJet 8015",
                kind: .printer, ports: [(80, "HTTP"), (631, "IPP"), (9100, "Raw Print")],
                services: ["Printer", "Scanner"], ms: 4),
            device("192.168.1.57", "24:0a:c4:de:ad:01", vendor: "Espressif", name: nil, kind: .iot, ms: 20),
            device("192.168.1.102", nil, vendor: nil, name: nil, kind: .unknown, ms: 30),
            device(
                "192.168.1.10", "00:11:32:5a:00:10", vendor: "Synology", name: "Storage", model: "DS923+",
                kind: .nas, ports: [(21, "FTP"), (80, "HTTP"), (443, "HTTPS"), (445, "SMB"), (5000, "DSM")],
                services: ["File Sharing", "Time Machine"], ms: 2),
            device(
                "192.168.1.23", "3c:22:fb:00:00:23", vendor: "Apple", name: "Bedroom TV", model: "Apple TV 4K",
                kind: .tv, ports: [(7000, "AirPlay")], services: ["AirPlay"], ms: 5),
            device(
                "192.168.1.25", "48:a6:b8:00:00:25", vendor: "Sonos", name: "Kitchen", model: "Era 100",
                kind: .speaker, ports: [(1400, "Sonos")], services: ["AirPlay", "Spotify Connect"], ms: 7),
            device(
                "192.168.1.38", "70:9e:29:00:00:38", vendor: "Sony", name: "PS5",
                model: "PlayStation 5", kind: .gameConsole, ms: 9),
            device(
                "192.168.1.41", "00:17:88:00:00:41", vendor: "Signify", name: "Hue Bridge", model: "Hue Bridge",
                kind: .iot, ports: [(80, "HTTP"), (443, "HTTPS")], services: ["HomeKit"], ms: 3),
            device(
                "192.168.1.70", "f4:f5:d8:00:00:70", vendor: "Google", name: "Front Door", model: "Nest Cam",
                kind: .camera, ms: 14),
            device(
                "192.168.1.88", "b8:27:eb:00:00:88", vendor: "Raspberry Pi", name: "pihole", host: "pihole.local",
                model: "Raspberry Pi 4", kind: .computer,
                ports: [(22, "SSH"), (23, "Telnet"), (53, "DNS"), (80, "HTTP")],
                ms: 2),
        ]
        devices[1].isSelf = true
        devices[3].isNew = true
        devices[3].firstSeen = now.addingTimeInterval(-600)
        devices[5].customName = "Kitchen Sensor"
        devices[5].notes = "ESP32 behind the fridge"
        for i in devices.indices {
            if devices[i].firstSeen == nil { devices[i].firstSeen = now.addingTimeInterval(-40 * day) }
            devices[i].lastSeen = now
        }

        var tablet = device(
            "192.168.1.66", "f0:18:98:44:55:66", vendor: "Apple", name: "Sam's iPad", model: "iPad Air",
            kind: .tablet, services: ["AirPlay"])
        tablet.isOnline = false
        tablet.responseTime = nil
        tablet.firstSeen = now.addingTimeInterval(-30 * day)
        tablet.lastSeen = now.addingTimeInterval(-3 * day)
        devices.append(tablet)

        return ScanStore(
            previewDevices: devices, interface: iface, history: history,
            lastScanFinishedAt: now.addingTimeInterval(-4 * 60),
            fullScanProgress: [IPv4Address("192.168.1.44")!: 0.4])
    }

    private static func device(
        _ ip: String, _ mac: String?, vendor: String?, name: String?, host: String? = nil,
        model: String? = nil, kind: DeviceKind, ports: [(UInt16, String)] = [],
        services: Set<String> = [], ms: Int = 3
    ) -> Device {
        var d = Device(ip: IPv4Address(ip)!)
        d.mac = mac.flatMap(MACAddress.init)
        d.vendor = vendor
        d.name = name
        d.hostname = host
        d.model = model
        d.kind = kind
        d.openPorts = ports.map { OpenPort(port: $0.0, service: $0.1) }.sorted()
        d.services = services
        d.responseTime = .milliseconds(ms)
        return d
    }
}
