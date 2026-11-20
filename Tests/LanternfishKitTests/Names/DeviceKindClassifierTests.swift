import Testing

@testable import LanternfishKit

@Suite struct DeviceKindClassifierTests {
    struct Case: CustomTestStringConvertible, Sendable {
        var label: String
        var name: String? = nil
        var hostname: String? = nil
        var model: String? = nil
        var manufacturer: String? = nil
        var vendor: String? = nil
        var services: Set<String> = []
        var ports: [UInt16] = []
        var preset: DeviceKind = .unknown
        var ip = "192.168.1.50"
        var expected: DeviceKind
        var testDescription: String { label }

        var device: Device {
            var d = Device(ip: IPv4Address(ip)!)
            d.name = name
            d.hostname = hostname
            d.model = model
            d.manufacturer = manufacturer
            d.vendor = vendor
            d.services = services
            d.openPorts = ports.map { OpenPort(port: $0) }
            d.kind = preset
            return d
        }
    }

    static let gateway = IPv4Address("192.168.1.1")!

    static let cases: [Case] = [
        Case(label: "gateway", vendor: "Apple, Inc.", ip: "192.168.1.1", expected: .router),
        Case(label: "Samsung TV", name: "Living Room TV", vendor: "Samsung Electronics", expected: .tv),
        Case(
            label: "HP printer", name: "HP OfficeJet Pro 9010", vendor: "HP Inc.", ports: [80, 9100], expected: .printer
        ),
        Case(label: "iPhone", hostname: "Sams-iPhone.local", vendor: "Apple, Inc.", expected: .phone),
        Case(label: "Espressif", vendor: "Espressif Inc.", expected: .iot),
        Case(label: "Synology", name: "DiskStation", manufacturer: "Synology Inc.", expected: .nas),
        Case(label: "Sonos", name: "Kitchen", manufacturer: "Sonos, Inc.", services: ["UPnP"], expected: .speaker),
        Case(
            label: "PlayStation", hostname: "PS5-123.lan", vendor: "Sony Interactive Entertainment",
            expected: .gameConsole),
        Case(
            label: "Mac SSH+SMB", name: "Studio", vendor: "Apple, Inc.", services: ["SSH", "SMB"], expected: .computer),
        Case(label: "unknown stays unknown", vendor: "Some Vendor Ltd", expected: .unknown),
        Case(label: "preset kept", vendor: "Some Vendor Ltd", preset: .camera, expected: .camera),
        Case(label: "Apple alone", vendor: "Apple, Inc.", expected: .unknown),
        Case(label: "iPad", name: "Sam's iPad", expected: .tablet),
        Case(label: "Apple TV", name: "Woonkamer", model: "Apple TV 4K", services: ["AirPlay", "RAOP"], expected: .tv),
        Case(label: "raop only", name: "Bedroom", services: ["RAOP"], expected: .speaker),
        Case(label: "Chromecast", services: ["_googlecast._tcp"], expected: .tv),
        Case(label: "IPP service", name: "Office", services: ["_ipp._tcp"], expected: .printer),
        Case(label: "Hue bridge", name: "Philips hue", manufacturer: "Signify", expected: .iot),
        Case(label: "nas not in dynastar", name: "Dynastar", expected: .unknown),
        Case(label: "tv not in atv-box", hostname: "atv-box", expected: .unknown),
        Case(label: "RTSP camera", ports: [554], expected: .camera),
        Case(label: "Windows RDP", hostname: "DESKTOP-4F2K9", ports: [3389], expected: .computer),
        Case(label: "Ubiquiti AP", name: "UniFi AP Lite", vendor: "Ubiquiti Inc", expected: .router),
        Case(label: "Roku port", ports: [8060], expected: .tv),
        Case(label: "MacBook hostname", hostname: "Sams-MacBook-Pro.local", expected: .computer),
    ]

    @Test(arguments: cases) func classifies(_ c: Case) {
        #expect(DeviceKindClassifier.classify(c.device, gateway: Self.gateway) == c.expected)
    }
}
