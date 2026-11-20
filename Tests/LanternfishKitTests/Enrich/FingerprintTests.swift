import Foundation
import Testing

@testable import LanternfishKit

@Suite struct FingerprintTests {
    static func device(
        _ ip: String = "10.0.0.50", mac: String? = nil, vendor: String? = nil, name: String? = nil,
        hostname: String? = nil, manufacturer: String? = nil, model: String? = nil,
        services: Set<String> = [], ports: [UInt16] = [], os: String? = nil, title: String? = nil,
        kind: DeviceKind = .unknown
    ) -> Device {
        var d = Device(ip: IPv4Address(ip)!)
        d.mac = mac.flatMap(MACAddress.init)
        d.vendor = vendor
        d.name = name
        d.hostname = hostname
        d.manufacturer = manufacturer
        d.model = model
        d.services = services
        d.openPorts = ports.map { OpenPort(port: $0, service: CommonPorts.all[$0]) }
        d.osHint = os
        d.webTitle = title
        d.kind = kind
        return d
    }

    struct Case: CustomTestStringConvertible, Sendable {
        var label: String
        var device: Device
        var manufacturer: String?
        var model: String?
        var kind: DeviceKind?
        var minConfidence: Double = 0.5
        var testDescription: String { label }
    }

    static let cases: [Case] = [
        Case(
            label: "Sony KD-55A8 with Android hostname is a TV",
            device: device(
                vendor: "Sony", name: "SONY KD-55A8", hostname: "Android.local", manufacturer: "Sony",
                model: "KD-55A8", services: ["AirPlay", "Android TV", "Chromecast", "HomeKit", "UPnP"],
                ports: [80, 7000, 8008, 8009, 8443, 9000]),
            manufacturer: "Sony", model: "KD-55A8", kind: .tv, minConfidence: 0.9),
        Case(
            label: "Archer_AX10 router name",
            device: device(vendor: "TP-Link", hostname: "Archer_AX10"),
            manufacturer: "TP-Link", model: "Archer AX10", kind: .router, minConfidence: 0.8),
        Case(
            label: "Netgear RAX40 behind another router",
            device: device(vendor: "Netgear", hostname: "RAX40.home"),
            manufacturer: "Netgear", model: "RAX40", kind: .router, minConfidence: 0.8),
        Case(
            label: "Galaxy XCover with private MAC",
            device: device(mac: "02:11:22:33:44:55", hostname: "Galaxy-XCover-5"),
            manufacturer: "Samsung", model: "Galaxy XCover 5", kind: .phone),
        Case(
            label: "Bambu printer via SSDP service",
            device: device(
                vendor: "Fn-Link Technology", manufacturer: "Bambu Lab", model: "3D Printer (N6)",
                services: ["Bambu Lab"], ports: [53, 3000, 8883]),
            manufacturer: "Bambu Lab", kind: .printer, minConfidence: 0.9),
        Case(
            label: "Quby Toon thermostat",
            device: device(
                vendor: "Murata", hostname: "qb-659916001600-1815A03VJJ", ports: [22, 80], os: "Embedded Linux",
                title: "Z-Wave advanced"),
            manufacturer: "Quby", model: "Toon thermostat", kind: .iot, minConfidence: 0.8),
        Case(
            label: "Apple Watch hostname",
            device: device(mac: "02:00:00:00:00:01", hostname: "Watch.home"),
            manufacturer: "Apple", model: "Apple Watch", kind: .phone, minConfidence: 0.7),
        Case(
            label: "iPad from router DNS",
            device: device(mac: "02:00:00:00:00:02", hostname: "iPad"),
            manufacturer: "Apple", model: "iPad", kind: .tablet, minConfidence: 0.85),
        Case(
            label: "iOS lockdown port only",
            device: device(mac: "02:00:00:00:00:03", ports: [62078]),
            manufacturer: "Apple", model: "iPhone or iPad", kind: .phone),
        Case(
            label: "Kyocera printer",
            device: device(
                vendor: "Kyocera Display", name: "Kyocera ECOSYS M6026cidn", hostname: "Printer.local",
                services: ["Printer", "Web"], ports: [80, 443, 515, 631, 9100]),
            manufacturer: "Kyocera", model: "ECOSYS M6026cidn", kind: .printer, minConfidence: 0.9),
        Case(
            label: "Synology by title",
            device: device(vendor: "Synology", ports: [5000, 5001], title: "Synology DiskStation DS920+"),
            manufacturer: "Synology", model: "DS920+", kind: .nas, minConfidence: 0.9),
        Case(
            label: "Sonos by port and vendor",
            device: device(vendor: "Sonos", ports: [1400]),
            manufacturer: "Sonos", kind: .speaker, minConfidence: 0.8),
        Case(
            label: "Chromecast service only",
            device: device(vendor: "Google", services: ["Chromecast"], ports: [8008, 8009]),
            manufacturer: "Google", kind: .tv),
        Case(
            label: "Google Nest speaker beats Chromecast",
            device: device(vendor: "Google", name: "Google-Nest-Mini", services: ["Chromecast"], ports: [8008, 8009]),
            manufacturer: "Google", kind: .speaker),
        Case(
            label: "Windows desktop name",
            device: device(name: "DESKTOP-AB12CDE", ports: [135, 445]),
            model: "Windows PC", kind: .computer, minConfidence: 0.85),
        Case(
            label: "Tuya port",
            device: device(vendor: "Tuya Smart", ports: [6668]),
            manufacturer: "Tuya", kind: .iot, minConfidence: 0.8),
        Case(
            label: "ESPHome",
            device: device(vendor: "Espressif", hostname: "sensor.local", services: ["ESPHome"], ports: [6053]),
            kind: .iot, minConfidence: 0.9),
        Case(
            label: "Shelly",
            device: device(vendor: "Espressif", hostname: "shellyplus1pm-a8032ab12345.local"),
            manufacturer: "Shelly", kind: .iot),
        Case(
            label: "Hue bridge",
            device: device(vendor: "Signify", services: ["Philips Hue", "HomeKit"]),
            manufacturer: "Philips Hue", model: "Hue Bridge", kind: .iot, minConfidence: 0.9),
        Case(
            label: "PlayStation",
            device: device(vendor: "Sony Interactive Entertainment", hostname: "PS5-123"),
            manufacturer: "Sony", kind: .gameConsole, minConfidence: 0.9),
        Case(
            label: "Nintendo by OUI",
            device: device(vendor: "Nintendo"),
            manufacturer: "Nintendo", kind: .gameConsole, minConfidence: 0.8),
        Case(
            label: "Raspberry Pi",
            device: device(vendor: "Raspberry Pi Trading", ports: [22]),
            manufacturer: "Raspberry Pi", kind: .computer, minConfidence: 0.8),
        Case(
            label: "Hikvision camera",
            device: device(vendor: "Hangzhou Hikvision Digital Technology", ports: [80, 554, 8000]),
            manufacturer: "Hikvision", kind: .camera, minConfidence: 0.7),
        Case(
            label: "Generic IP camera by ports",
            device: device(ports: [80, 554, 8899]),
            kind: .camera),
        Case(
            label: "HP printer hostname",
            device: device(
                vendor: "HP", name: "HP OfficeJet Pro 9010 series", hostname: "HP9C7BEF123456.local",
                ports: [631, 9100]),
            manufacturer: "HP", kind: .printer, minConfidence: 0.9),
        Case(
            label: "Roborock",
            device: device(hostname: "roborock-vacuum-a15_miio123"),
            kind: .iot),
        Case(
            label: "Gateway is a router",
            device: device("10.0.0.1", vendor: "Arcadyan"),
            kind: .router, minConfidence: 0.85),
        Case(
            label: "Garmin watch",
            device: device(vendor: "Garmin", hostname: "Garmin-WiFi"),
            manufacturer: "Garmin", kind: .phone, minConfidence: 0.7),
        Case(
            label: "AI-Link module with nothing else is a smart device",
            device: device(vendor: "Sichuan AI-Link Technology", hostname: "J10806277", ports: [8000]),
            kind: .iot, minConfidence: 0.45),
    ]

    @Test(arguments: cases) func identifies(_ c: Case) {
        let id = Fingerprint.identify(c.device, gateway: IPv4Address("10.0.0.1"))
        if let m = c.manufacturer { #expect(id.manufacturer == m, "\(id)") }
        if let m = c.model { #expect(id.model == m, "\(id)") }
        #expect(id.kind == c.kind, "\(id)")
        #expect(id.confidence >= c.minConfidence, "\(id)")
        #expect(!id.reasons.isEmpty)
    }

    @Test func reasonsAreReadableAndStrongestFirst() {
        let d = Self.device(vendor: "Sony", name: "SONY KD-55A8", services: ["Android TV"])
        let id = Fingerprint.identify(d)
        #expect(id.reasons.first?.contains("KD-55A8") == true)
        #expect(id.reasons.contains("Advertises Android TV"))
        #expect(id.reasons.contains("MAC vendor: Sony"))
    }

    @Test func placeholderModelIsNotEvidence() {
        let quiet = Self.device(mac: "02:00:00:00:00:04", manufacturer: "Apple", model: "iPhone or iPad")
        #expect(Fingerprint.identify(quiet).confidence < 0.6)
        let named = Self.device(
            mac: "02:00:00:00:00:04", hostname: "Sams-iPhone.local", manufacturer: "Apple",
            model: "iPhone or iPad", ports: [62078])
        let id = Fingerprint.identify(named)
        #expect(id.model == "iPhone")
        #expect(id.confidence >= 0.9)
    }

    @Test func notesAreAppended() {
        let d = Self.device(hostname: "iPad")
        let id = Fingerprint.identify(d, notes: ["Name “iPad” from router DNS"])
        #expect(id.reasons.last == "Name “iPad” from router DNS")
    }

    @Test func nothingKnownIsLowConfidence() {
        let d = Self.device(mac: "02:00:00:00:00:09")
        let id = Fingerprint.identify(d)
        #expect(id.kind == nil)
        #expect(id.confidence < Fingerprint.threshold)
        #expect(id.reasons == ["Private MAC address and no names, services or open ports"])
    }

    @Test func vendorOnlyIsGenericAndWeak() {
        let id = Fingerprint.identify(Self.device(vendor: "Some Unknown Corp"))
        #expect(id.signature == nil)
        #expect(id.confidence == 0.2)
        #expect(id.reasons == ["MAC vendor: Some Unknown Corp"])
    }

    @Test func confidenceIsBounded() {
        for c in Self.cases {
            let id = Fingerprint.identify(c.device, gateway: IPv4Address("10.0.0.1"))
            #expect((0...1).contains(id.confidence))
        }
    }

    @Test func allSignaturesHaveClues() {
        for s in Fingerprint.signatures {
            #expect(!s.clues.isEmpty, "\(s.label)")
            #expect(s.clues.allSatisfy { (0...1).contains($0.weight) }, "\(s.label)")
        }
        #expect(Fingerprint.signatures.count >= 80)
    }

    // The classifier alone (no fingerprint) must not call an Android TV a phone either.
    @Test func classifierSonyTV() {
        let d = Self.device(
            vendor: "Sony", name: "SONY KD-55A8", hostname: "Android.local", manufacturer: "Sony",
            services: ["Android TV", "Chromecast"])
        #expect(DeviceKindClassifier.classify(d, gateway: nil) == .tv)
    }
}
