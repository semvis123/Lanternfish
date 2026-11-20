import Foundation
import Testing

@testable import LanternfishKit

@Suite struct BannerParserTests {
    @Test func extractsAndDecodesTitle() {
        #expect(
            BannerParser.extractTitle("<html><head><TITLE>\n  Tom &amp; Jerry&#39;s  NAS </title>")
                == "Tom & Jerry's NAS")
        #expect(BannerParser.extractTitle("<title id=\"main-page-title\"></title>") == nil)
        #expect(
            BannerParser.extractTitle("<title>.::Welcome to the Web-Based Configurator::.</title>")
                == "Welcome to the Web-Based Configurator")
        #expect(BannerParser.extractTitle("<title>caf&#xE9; &lt;3</title>") == "café <3")
        #expect(BannerParser.extractTitle("no title here") == nil)
    }

    @Test(arguments: [
        "", "404", "Index of /", "Login", "Redirecting...", "Default Site", "Welcome to nginx!",
        "Error 500", "Welcome to the Web-Based Configurator", "403 Forbidden", "---",
    ])
    func uselessTitles(_ t: String) {
        #expect(!BannerParser.isUsefulTitle(t))
    }

    @Test(arguments: ["Coolify", "ZPHS01B Air Quality", "Pi-hole Admin Console", "Synology DiskStation"])
    func usefulTitles(_ t: String) {
        #expect(BannerParser.isUsefulTitle(t))
    }

    struct HTMLCase: CustomTestStringConvertible, Sendable {
        var label: String
        var title: String? = nil
        var server: String? = nil
        var body: String = ""
        var webTitle: String? = nil
        var osHint: String? = nil
        var manufacturer: String? = nil
        var model: String? = nil
        var kind: DeviceKind? = nil
        var testDescription: String { label }
    }

    static let htmlCases: [HTMLCase] = [
        HTMLCase(
            label: "Zyxel SPA",
            body:
                "<title>.::Welcome to the Web-Based Configurator::.</title><script src=./static/js/zyxel.js></script>",
            webTitle: "Zyxel", manufacturer: "Zyxel", kind: .router),
        HTMLCase(
            label: "Zyxel model in body", body: "<title>VMG8825-T50</title> zyxel", webTitle: "VMG8825-T50",
            manufacturer: "Zyxel", model: "VMG8825-T50", kind: .router),
        HTMLCase(
            label: "TrueNAS SPA", server: "nginx", body: "<title id=\"main-page-title\"></title><ix-root></ix-root>",
            webTitle: "TrueNAS", osHint: "TrueNAS", kind: .nas),
        HTMLCase(
            label: "TrueNAS theme CSS",
            body: "<title id=\"main-page-title\"></title><style>html .ix-dark{--x:1}</style>",
            webTitle: "TrueNAS", osHint: "TrueNAS", kind: .nas),
        HTMLCase(label: "Coolify", server: "nginx", body: "<title>Coolify</title>", webTitle: "Coolify"),
        HTMLCase(label: "NPM default", server: "openresty", body: "<title>Default Site</title>"),
        HTMLCase(label: "Custom ESP page", body: "<title>ZPHS01B Air Quality</title>", webTitle: "ZPHS01B Air Quality"),
        HTMLCase(
            label: "Synology", body: "<title>Synology DiskStation - DS920+</title>",
            webTitle: "Synology DiskStation - DS920+",
            osHint: "DSM", manufacturer: "Synology", model: "DS920+", kind: .nas),
        HTMLCase(
            label: "FRITZ!Box", body: "<title>FRITZ!Box 7590 AX</title>", webTitle: "FRITZ!Box 7590 AX",
            osHint: "FRITZ!OS", manufacturer: "AVM", model: "FRITZ!Box 7590 AX", kind: .router),
        HTMLCase(
            label: "HP printer", body: "<title>HP OfficeJet Pro 9010 series</title>",
            webTitle: "HP OfficeJet Pro 9010 series",
            manufacturer: "HP", model: "OfficeJet Pro 9010", kind: .printer),
        HTMLCase(
            label: "Kyocera", body: "<title>Kyocera ECOSYS M6026cidn</title>", webTitle: "Kyocera ECOSYS M6026cidn",
            manufacturer: "Kyocera", model: "ECOSYS M6026cidn", kind: .printer),
        HTMLCase(
            label: "Brother", body: "<title>Brother MFC-L2710DW series</title>", webTitle: "Brother MFC-L2710DW series",
            manufacturer: "Brother", model: "MFC-L2710DW", kind: .printer),
        HTMLCase(
            label: "Home Assistant", body: "<title>Home Assistant</title>", webTitle: "Home Assistant",
            osHint: "Home Assistant", kind: .iot),
        HTMLCase(
            label: "OpenWrt LuCI", body: "<title>OpenWrt - LuCI</title>", webTitle: "OpenWrt - LuCI", osHint: "OpenWrt",
            kind: .router),
        HTMLCase(
            label: "lucide icons are not LuCI", body: "<title>Dashboard</title><svg class=lucide-icon>",
            webTitle: "Dashboard"),
        HTMLCase(
            label: "Proxmox", body: "<title>pve - Proxmox Virtual Environment</title>",
            webTitle: "pve - Proxmox Virtual Environment", osHint: "Proxmox VE", kind: .computer),
        HTMLCase(
            label: "Apache Ubuntu", server: "Apache/2.4.58 (Ubuntu)",
            body: "<title>Apache2 Ubuntu Default Page: It works</title>",
            osHint: "Ubuntu"),
        HTMLCase(
            label: "IIS", server: "Microsoft-IIS/10.0", body: "<title>IIS Windows Server</title>", osHint: "Windows"),
        HTMLCase(
            label: "Netgear Orbi", body: "<title>NETGEAR Orbi</title> RBR50", webTitle: "NETGEAR Orbi",
            manufacturer: "NETGEAR", model: "RBR50", kind: .router),
        HTMLCase(
            label: "TP-Link Archer", body: "<title>Archer AX55</title> TP-Link", webTitle: "Archer AX55",
            manufacturer: "TP-Link", model: "Archer AX55", kind: .router),
        HTMLCase(
            label: "ASUS router", body: "<title>ASUS Wireless Router RT-AX88U - Login</title>",
            webTitle: "ASUS Wireless Router RT-AX88U - Login", manufacturer: "ASUS", model: "RT-AX88U", kind: .router),
        HTMLCase(
            label: "WLED", body: "<title>WLED</title><script>wled</script>", webTitle: "WLED", osHint: "WLED",
            kind: .iot),
        HTMLCase(label: "Tasmota", body: "<title>Tasmota</title>", webTitle: "Tasmota", osHint: "Tasmota", kind: .iot),
        HTMLCase(
            label: "Hue bridge", body: "<title>hue personal wireless lighting</title>",
            webTitle: "hue personal wireless lighting", manufacturer: "Philips Hue", model: "Hue Bridge", kind: .iot),
        HTMLCase(label: "AirPlay receiver", server: "AirTunes/870.14.1", body: "", manufacturer: "Apple"),
    ]

    @Test(arguments: htmlCases) func parsesHTML(_ c: HTMLCase) {
        let h = BannerParser.parseHTML(title: c.title, server: c.server, body: c.body)
        #expect(h.webTitle == c.webTitle)
        #expect(h.osHint == c.osHint)
        #expect(h.manufacturer == c.manufacturer)
        #expect(h.model == c.model)
        #expect(h.kind == c.kind)
    }

    @Test func zyxelBasicInformation() {
        let json = #"{"result":"ZCFG_SUCCESS","ModelName":"NR7101","SoftwareVersion":"V1.00(ACJG.0)"}"#
        #expect(BannerParser.parseZyxelBasicInfo(Data(json.utf8)) == "NR7101")
        #expect(BannerParser.parseZyxelBasicInfo(Data(#"{"result":"Invalid"}"#.utf8)) == nil)
        #expect(BannerParser.parseZyxelBasicInfo(Data("<html>".utf8)) == nil)
    }

    @Test func metaRefresh() {
        #expect(BannerParser.metaRefreshTarget(#"<meta http-equiv="refresh" content="0; url=/ui/">"#) == "/ui/")
        #expect(
            BannerParser.metaRefreshTarget(#"<META HTTP-EQUIV=Refresh CONTENT='1;URL=https://10.0.0.1/'>"#)
                == "https://10.0.0.1/")
        #expect(BannerParser.metaRefreshTarget("<meta charset=utf-8>") == nil)
    }

    @Test(arguments: [
        (
            "SSH-2.0-OpenSSH_9.6p1 Ubuntu-3ubuntu13.15\r\n", "Ubuntu 24.04", nil as String?,
            DeviceKind.computer as DeviceKind?
        ),
        ("SSH-2.0-OpenSSH_8.4p1 Ubuntu-1", "Ubuntu", nil, .computer),
        ("SSH-2.0-OpenSSH_9.2p1 Debian-2+deb12u3", "Debian 12", nil, .computer),
        ("SSH-2.0-OpenSSH_8.4p1 Raspbian-5+deb11u3", "Raspberry Pi OS", nil, .computer),
        ("SSH-2.0-dropbear_2022.83", "Embedded Linux", nil, nil),
        ("SSH-2.0-ROSSSH", "RouterOS", "MikroTik", .router),
        ("SSH-2.0-OpenSSH_for_Windows_8.1", "Windows", nil, .computer),
        ("SSH-2.0-OpenSSH_9.7 FreeBSD-20240318", "FreeBSD", nil, nil),
    ])
    func parsesSSH(_ banner: String, _ os: String, _ manufacturer: String?, _ kind: DeviceKind?) {
        let h = BannerParser.parseSSH(banner)
        #expect(h.osHint == os)
        #expect(h.manufacturer == manufacturer)
        #expect(h.kind == kind)
    }

    @Test func sshNoise() {
        #expect(BannerParser.parseSSH("SSH-2.0-OpenSSH_9.8").isEmpty)
        #expect(BannerParser.parseSSH("HTTP/1.1 400 Bad Request").isEmpty)
        #expect(BannerParser.parseSSH("").isEmpty)
    }

    @Test func combineRanksRicherHints() {
        let ssh = BannerHints(osHint: "Debian 12", kind: .computer)
        let web = BannerHints(webTitle: "TrueNAS", osHint: "TrueNAS", kind: .nas, product: "TrueNAS")
        let empty = BannerHints()
        let c = ServiceBanners.combine([empty, ssh, web])
        #expect(c.osHint == "TrueNAS")
        #expect(c.kind == .nas)
        #expect(c.webTitle == "TrueNAS")
        let c2 = ServiceBanners.combine([
            BannerHints(webTitle: "Coolify", product: "Coolify"),
            BannerHints(osHint: "Ubuntu 24.04", kind: .computer),
        ])
        #expect(c2.webTitle == "Coolify")
        #expect(c2.osHint == "Ubuntu 24.04")
        #expect(c2.kind == .computer)
    }

    @Test func privateIPv4() {
        #expect(LANTrustDelegate.isPrivateIPv4("192.168.1.1"))
        #expect(LANTrustDelegate.isPrivateIPv4("10.2.3.4"))
        #expect(LANTrustDelegate.isPrivateIPv4("172.20.0.1"))
        #expect(!LANTrustDelegate.isPrivateIPv4("172.32.0.1"))
        #expect(!LANTrustDelegate.isPrivateIPv4("8.8.8.8"))
        #expect(!LANTrustDelegate.isPrivateIPv4("example.com"))
    }
}

@Suite struct NetBIOSTests {
    static func hex(_ s: String) -> Data {
        var d = Data()
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            d.append(UInt8(s[i..<j], radix: 16)!)
            i = j
        }
        return d
    }

    /// Captured from a TrueNAS (Samba) box.
    static let samba = hex(
        "13378400000000010000000020434b41414141414141414141414141414141414141414141414141414141414100002100010000000000ad07"
            + "545255454e41532020202020202020000400545255454e41532020202020202020030400545255454e41532020202020202020200400"
            + "01025f5f4d5342524f5753455f5f02018400574f524b47524f5550202020202020008400574f524b47524f5550202020202020"
            + "1d0400574f524b47524f55502020202020201e8400000000000000000000000000000000000000000000000000000000000000"
            + "000000000000000000000000000000000000000000")

    @Test func query() {
        let q = NetBIOS.query(transactionID: 0x1337)
        #expect(q.count == 50)
        #expect(Array(q.prefix(2)) == [0x13, 0x37])
        #expect(String(decoding: q[13..<45], as: UTF8.self) == "CK" + String(repeating: "A", count: 30))
        #expect(Array(q.suffix(4)) == [0x00, 0x21, 0x00, 0x01])
    }

    @Test func parsesSamba() throws {
        let s = try #require(NetBIOS.parse(Self.samba))
        #expect(s.computerName == "TRUENAS")
        #expect(s.workgroup == "WORKGROUP")
        #expect(s.names.count == 7)
        #expect(s.isSamba)
        #expect(NetBIOS.osHint(s, vendor: nil) == "Samba")
    }

    @Test func parsesWindows() throws {
        // Constructed: compression pointer answer name, two names, a non-zero unit ID (not Samba).
        var d = Data([0xAB, 0xCD, 0x84, 0x00, 0, 0, 0, 1, 0, 0, 0, 0, 0xC0, 0x0C, 0x00, 0x21, 0x00, 0x01, 0, 0, 0, 0])
        func name(_ n: String, _ suffix: UInt8, group: Bool) -> [UInt8] {
            Array(n.utf8) + Array(repeating: 0x20, count: 15 - n.utf8.count) + [suffix, group ? 0x84 : 0x04, 0x00]
        }
        let rdata =
            [2] + name("DESKTOP-ABC1234", 0x00, group: false) + name("WORKGROUP", 0x00, group: true)
            + [0x00, 0x00, 0x5E, 0x00, 0x53, 0x01]
        d.append(contentsOf: [0x00, UInt8(rdata.count)])
        d.append(contentsOf: rdata)
        let s = try #require(NetBIOS.parse(d))
        #expect(s.computerName == "DESKTOP-ABC1234")
        #expect(s.workgroup == "WORKGROUP")
        #expect(!s.isSamba)
        #expect(NetBIOS.osHint(s, vendor: "Dell Inc.") == "Windows")
        #expect(NetBIOS.osHint(s, vendor: "Apple, Inc.") == nil)
    }

    @Test func rejectsGarbage() {
        #expect(NetBIOS.parse(Data()) == nil)
        #expect(NetBIOS.parse(NetBIOS.query()) == nil)  // a query, not a response
        #expect(NetBIOS.parse(Self.samba.prefix(60)) == nil)
    }
}

@Suite struct NameHintsTests {
    struct Case: CustomTestStringConvertible, Sendable {
        var label: String
        var name: String? = nil
        var hostname: String? = nil
        var vendor: String? = nil
        var services: Set<String> = []
        var ports: [UInt16] = []
        var privateMAC = false
        var manufacturer: String? = nil
        var model: String? = nil
        var kind: DeviceKind? = nil
        var osHint: String? = nil
        var testDescription: String { label }

        var device: Device {
            var d = Device(ip: IPv4Address("192.168.1.20")!)
            d.name = name
            d.hostname = hostname
            d.vendor = vendor
            d.services = services
            d.openPorts = ports.map { OpenPort(port: $0) }
            if privateMAC { d.mac = MACAddress("da:00:5e:00:53:01") }
            return d
        }
    }

    static let cases: [Case] = [
        Case(
            label: "Sams-iPhone", name: "Sams-iPhone", ports: [62078], privateMAC: true,
            manufacturer: "Apple", model: "iPhone", kind: .phone),
        Case(
            label: "iPhone-van-alex", hostname: "iPhone-van-alex.local", manufacturer: "Apple", model: "iPhone",
            kind: .phone),
        Case(
            label: "lockdownd only", ports: [62078], privateMAC: true, manufacturer: "Apple", model: "iPhone or iPad",
            kind: .phone),
        Case(label: "iPad", name: "iPad van Alex", manufacturer: "Apple", model: "iPad", kind: .tablet),
        Case(
            label: "MacBook Pro", name: "MacBook Pro van Sam", manufacturer: "Apple", model: "MacBook Pro",
            kind: .computer),
        Case(
            label: "MBP hostname", hostname: "sams-mbp.local", manufacturer: "Apple", model: "MacBook Pro",
            kind: .computer),
        Case(label: "iMac", hostname: "Kantoor-iMac.local", manufacturer: "Apple", model: "iMac", kind: .computer),
        Case(
            label: "android", hostname: "android-1a2b3c4d5e", model: "Android device", kind: .phone, osHint: "Android"),
        Case(label: "Galaxy", name: "Galaxy-S23", manufacturer: "Samsung", model: "Galaxy", kind: .phone),
        Case(label: "SM- model", hostname: "SM-G991B", manufacturer: "Samsung", model: "Galaxy", kind: .phone),
        Case(label: "ESP8266", hostname: "ESP_1A2B3C", manufacturer: "Espressif", model: "ESP8266", kind: .iot),
        Case(label: "ESP32", hostname: "esp32-kitchen", manufacturer: "Espressif", model: "ESP32", kind: .iot),
        Case(label: "Shelly", hostname: "shellyplus1pm-a8032ab12345", manufacturer: "Shelly", kind: .iot),
        Case(label: "Tasmota", hostname: "tasmota-4F2A11-1234", kind: .iot, osHint: "Tasmota"),
        Case(label: "WLED", hostname: "wled-desk", kind: .iot, osHint: "WLED"),
        Case(
            label: "LG TV", hostname: "LGwebOSTV.local", manufacturer: "LG", model: "webOS TV", kind: .tv,
            osHint: "webOS"),
        Case(label: "Chromecast", name: "Chromecast-Ultra", manufacturer: "Google", model: "Chromecast", kind: .tv),
        Case(
            label: "Roborock", hostname: "roborock-vacuum-a15", manufacturer: "Roborock", model: "Robot vacuum",
            kind: .iot),
        Case(label: "rockrobo", hostname: "rockrobo", manufacturer: "Roborock", model: "Robot vacuum", kind: .iot),
        Case(
            label: "Tuya 6668", vendor: "Tuya Smart Inc.", ports: [6668], manufacturer: "Tuya", model: "Smart device",
            kind: .iot),
        Case(
            label: "TrueNAS", name: "truenas", hostname: "truenas.local", privateMAC: true, kind: .nas,
            osHint: "TrueNAS"),
        Case(
            label: "Synology", hostname: "DiskStation.local", manufacturer: "Synology", model: "DiskStation",
            kind: .nas, osHint: "DSM"),
        Case(label: "Raspberry Pi", hostname: "raspberrypi.lan", manufacturer: "Raspberry Pi", kind: .computer),
        Case(
            label: "Windows desktop", hostname: "DESKTOP-ABC1234", model: "Windows PC", kind: .computer,
            osHint: "Windows"),
        Case(label: "Windows laptop", name: "LAPTOP-QW12ER34", model: "Windows PC", kind: .computer, osHint: "Windows"),
        Case(label: "ESPHome port", vendor: "Espressif Inc.", ports: [6053], kind: .iot, osHint: "ESPHome"),
        Case(label: "Apple service", services: ["Apple Device"], privateMAC: true, manufacturer: "Apple"),
    ]

    @Test(arguments: cases) func hints(_ c: Case) throws {
        let p = try #require(NameHints.patch(for: c.device))
        #expect(p.manufacturer == c.manufacturer)
        #expect(p.model == c.model)
        #expect(p.kind == c.kind)
        #expect(p.osHint == c.osHint)
    }

    @Test(arguments: [
        Case(label: "plain name", name: "Living Room"),
        Case(label: "vendor only", vendor: "Netgear"),
        Case(label: "nothing"),
        Case(label: "IRC not Tuya", vendor: "Dell Inc.", ports: [22, 6668]),
    ])
    func noHints(_ c: Case) {
        #expect(NameHints.patch(for: c.device) == nil)
    }

    @Test func fillGapsNeverOverwrites() {
        var d = Device(ip: IPv4Address("192.168.1.142")!)
        d.name = "truenas"
        d.model = "Real Model"
        d.kind = .nas
        d.osHint = "Samba"
        var p = DevicePatch(ip: d.ip)
        p.name = "TRUENAS"
        p.model = "Guess"
        p.manufacturer = "Acme"
        p.kind = .computer
        p.osHint = "TrueNAS"
        p.webTitle = "TrueNAS"
        p.openPorts = [OpenPort(port: 80)]
        d.fillGaps(from: p)
        #expect(d.name == "truenas")
        #expect(d.model == "Real Model")
        #expect(d.manufacturer == "Acme")
        #expect(d.kind == .nas)
        #expect(d.osHint == "TrueNAS")  // weak "Samba" refined
        #expect(d.webTitle == "TrueNAS")
        #expect(d.openPorts.map(\.port) == [80])

        var q = DevicePatch(ip: d.ip)
        q.osHint = "Windows"
        d.fillGaps(from: q)
        #expect(d.osHint == "TrueNAS")  // strong hint kept
    }
}

@Suite struct BonjourEnrichTests {
    @Test(arguments: [
        ("Mac16,8", "MacBook Pro"), ("Mac14,2", "MacBook Air"), ("Mac16,10", "Mac mini"), ("Mac13,1", "Mac Studio"),
        ("Mac99,1", "Mac"), ("iPhone15,2", "iPhone"), ("AudioAccessory5,1", "HomePod"), ("AppleTV14,1", "Apple TV"),
    ])
    func appleIdentifiers(_ id: String, _ name: String) {
        #expect(BonjourTXT.appleFriendlyName(id) == name)
    }

    @Test func companionLinkModel() {
        #expect(BonjourTXT.model(from: ["rpmd": "iPhone15,2", "rpvr": "715.2"]) == "iPhone")
        #expect(BonjourTXT.model(from: ["rpMac": "1", "rpHN": "10f7190d11f9"]) == nil)
    }

    @Test func appleFamilyNames() {
        #expect(BonjourTXT.isAppleFamilyName("Mac Pro"))
        #expect(BonjourTXT.isAppleFamilyName("MacBook Pro"))
        #expect(!BonjourTXT.isAppleFamilyName("Kyocera ECOSYS"))
    }

    @Test func esphomeTXT() {
        let e = BonjourNaming.esphome([
            "board": "esp32-s3-devkitc-1", "platform": "ESP32", "version": "2025.4.1",
            "mac": "48ca43979890", "network": "wifi",
        ])
        #expect(e.model == "ESP32-S3")
        #expect(e.osHint == "ESPHome 2025.4.1")
        let e2 = BonjourNaming.esphome(["platform": "ESP8266"])
        #expect(e2.model == "ESP8266")
        #expect(e2.osHint == "ESPHome")
    }

    @Test func newServiceKinds() {
        #expect(BonjourNaming.kind(type: "_esphomelib._tcp", model: nil, txt: [:]) == .iot)
        #expect(BonjourNaming.kind(type: "_androidtvremote2._tcp", model: nil, txt: [:]) == .tv)
        #expect(BonjourNaming.kind(type: "_airport._tcp", model: nil, txt: [:]) == .router)
        #expect(BonjourServiceLabels.label(for: "_sleep-proxy._udp") == "Sleep Proxy")
        #expect(BonjourServiceLabels.label(for: "_meshcop._udp.") == "Thread Border Router")
        #expect(BonjourNaming.cleanName("70-35-60-63.1 Woonkamer", type: "_sleep-proxy._udp", txt: [:]) == nil)
    }

    @Test(arguments: [
        ("truenas NAS by osHint", "server", "TrueNAS", DeviceKind.nas),
        ("Ubuntu server", "box", "Ubuntu 24.04", .computer),
        ("Home Assistant", "ha", "Home Assistant", .iot),
    ])
    func classifierUsesOSHint(_ label: String, _ name: String, _ os: String, _ expected: DeviceKind) {
        var d = Device(ip: IPv4Address("192.168.1.9")!)
        d.name = name
        d.osHint = os
        #expect(DeviceKindClassifier.classify(d, gateway: nil) == expected, "\(label)")
    }
}
