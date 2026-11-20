import Foundation
import Testing

@testable import LanternfishKit

@Suite struct BonjourTests {
    private func txt(_ entries: [String]) -> Data {
        var d = Data()
        for e in entries {
            let b = Array(e.utf8)
            d.append(UInt8(b.count))
            d.append(contentsOf: b)
        }
        return d
    }

    @Test func parseTXT() {
        let data = txt(["md=Chromecast Ultra", "fn=Living Room", "flag", "Empty=", "md=dup", "url=a=b"])
        let parsed = BonjourTXT.parse(data)
        #expect(parsed["md"] == "Chromecast Ultra")
        #expect(parsed["fn"] == "Living Room")
        #expect(parsed["flag"] == "")
        #expect(parsed["empty"] == "")
        #expect(parsed["url"] == "a=b")
        #expect(parsed.count == 5)
    }

    @Test func parseTXTMalformed() {
        #expect(BonjourTXT.parse(Data()).isEmpty)
        #expect(BonjourTXT.parse(Data([0])).isEmpty)  // single empty string
        #expect(BonjourTXT.parse(Data([10, 0x61, 0x3D, 0x62]))["a"] == "b")  // truncated length
    }

    @Test func modelKeyPrecedence() {
        #expect(BonjourTXT.model(from: ["ty": "HP LaserJet", "md": "Chromecast", "model": "X1"]) == "X1")
        #expect(BonjourTXT.model(from: ["ty": "HP LaserJet", "am": "Samsung TV"]) == "Samsung TV")
        #expect(BonjourTXT.model(from: ["usb_MDL": "OfficeJet", "ty": "HP OfficeJet 8015"]) == "HP OfficeJet 8015")
        #expect(BonjourTXT.model(from: ["usb_MDL": "OfficeJet 8015"]) == "OfficeJet 8015")
        #expect(BonjourTXT.model(from: ["model": "", "md": "Nest Hub"]) == "Nest Hub")
        #expect(BonjourTXT.model(from: ["fn": "x"]) == nil)
    }

    @Test func productParentheses() {
        #expect(BonjourTXT.model(from: ["product": "(HP OfficeJet 8015)"]) == "HP OfficeJet 8015")
        #expect(BonjourTXT.model(from: ["product": "()", "usb_MDL": "M1"]) == "M1")
    }

    @Test(arguments: [
        ("MacBookPro18,3", "MacBook Pro"), ("MacBookAir10,1", "MacBook Air"), ("Mac14,2", "MacBook Air"),
        ("Mac99,1", "Mac"),
        ("iMac21,1", "iMac"), ("Macmini9,1", "Mac mini"), ("iPhone15,2", "iPhone"), ("iPad13,4", "iPad"),
        ("AppleTV6,2", "Apple TV"), ("AudioAccessory5,1", "HomePod"),
    ])
    func appleModelMapping(id: String, expected: String) {
        #expect(BonjourTXT.model(from: ["model": id]) == expected)
    }

    @Test func nonAppleModelsPassThrough() {
        #expect(BonjourTXT.model(from: ["model": "MacGyver"]) == "MacGyver")
        #expect(BonjourTXT.model(from: ["md": "iPhone-ish"]) == "iPhone-ish")
        #expect(BonjourTXT.model(from: ["model": "MacPro7,1@ECOLOR=226,226,224"]) == "Mac Pro")
    }

    @Test func labels() {
        #expect(BonjourServiceLabels.label(for: "_airplay._tcp") == "AirPlay")
        #expect(BonjourServiceLabels.label(for: "_raop._tcp.") == "AirPlay Audio")
        #expect(BonjourServiceLabels.label(for: "_googlecast._tcp") == "Chromecast")
        for t in ["_ipp._tcp", "_ipps._tcp", "_printer._tcp", "_pdl-datastream._tcp"] {
            #expect(BonjourServiceLabels.label(for: t) == "Printer")
        }
        #expect(BonjourServiceLabels.label(for: "_uscan._tcp") == "Scanner")
        #expect(BonjourServiceLabels.label(for: "_smb._tcp") == "File Sharing (SMB)")
        #expect(BonjourServiceLabels.label(for: "_sftp-ssh._tcp") == "SSH")
        #expect(BonjourServiceLabels.label(for: "_rfb._tcp") == "Screen Sharing")
        #expect(BonjourServiceLabels.label(for: "_hap._tcp") == "HomeKit")
        #expect(BonjourServiceLabels.label(for: "_amzn-wplay._tcp") == "Amazon Fire TV")
        #expect(BonjourServiceLabels.label(for: "_device-info._tcp") == "")
        #expect(BonjourServiceLabels.label(for: "_foo-bar._tcp") == "foo-bar")
        for t in BonjourScanner.serviceTypes where t != "_device-info._tcp" {
            #expect(!BonjourServiceLabels.label(for: t).isEmpty)
        }
    }

    @Test func nameCleaning() {
        #expect(BonjourNaming.cleanName("A1B2C3D4E5F6@Kitchen", type: "_raop._tcp", txt: [:]) == "Kitchen")
        #expect(BonjourNaming.cleanName("Sam's MacBook (2)", type: "_airplay._tcp", txt: [:]) == "Sam's MacBook")
        #expect(BonjourNaming.cleanName("Model (X)", type: "_airplay._tcp", txt: [:]) == "Model (X)")
        #expect(BonjourNaming.cleanName("studio [aa:bb:cc:dd:ee:ff]", type: "_workstation._tcp", txt: [:]) == "studio")
        #expect(BonjourNaming.cleanName("Chromecast-abc123", type: "_googlecast._tcp", txt: ["fn": "TV"]) == "TV")
        #expect(BonjourNaming.cleanName("aa:bb@fe80::1", type: "_apple-mobdev2._tcp", txt: [:]) == nil)
    }

    @Test func kindHints() {
        #expect(BonjourNaming.kind(type: "_ipp._tcp", model: nil, txt: [:]) == .printer)
        #expect(BonjourNaming.kind(type: "_googlecast._tcp", model: nil, txt: ["md": "Chromecast"]) == .tv)
        #expect(BonjourNaming.kind(type: "_sonos._tcp", model: nil, txt: [:]) == .speaker)
        #expect(BonjourNaming.kind(type: "_companion-link._tcp", model: "iPhone", txt: [:]) == .phone)
        #expect(BonjourNaming.kind(type: "_apple-mobdev2._tcp", model: "iPad", txt: [:]) == .tablet)
        #expect(BonjourNaming.kind(type: "_workstation._tcp", model: nil, txt: [:]) == .computer)
        #expect(BonjourNaming.kind(type: "_hap._tcp", model: nil, txt: [:]) == .iot)
        #expect(BonjourNaming.kind(type: "_http._tcp", model: nil, txt: [:]) == nil)
        #expect(BonjourNaming.kind(type: "_device-info._tcp", model: "Mac Pro", txt: [:]) == nil)
    }

    @Test(.timeLimit(.minutes(1))) func liveScanCompletes() async {
        let start = ContinuousClock.now
        var patches: [DevicePatch] = []
        for await p in BonjourScanner().scan(duration: .seconds(3)) { patches.append(p) }
        let elapsed = ContinuousClock.now - start
        #expect(elapsed < .seconds(6))
        let ips = Set(patches.map(\.ip))
        print("bonjour: \(patches.count) patches, \(ips.count) IPs in \(elapsed)")
        // Device details only on request (LANTERNFISHKIT_NET=1): they describe whatever LAN runs the tests.
        for p in patches.sorted(by: { $0.ip < $1.ip }) where verboseNet {
            print(
                "bonjour", p.ip, p.name ?? "-", p.hostname ?? "-", p.model ?? "-",
                p.kind?.rawValue ?? "-", p.services.sorted())
        }
    }

    @Test(.timeLimit(.minutes(1))) func liveScanCancels() async {
        let task = Task {
            var n = 0
            for await _ in BonjourScanner().scan(duration: .seconds(30)) { n += 1 }
            return n
        }
        try? await Task.sleep(for: .milliseconds(500))
        task.cancel()
        _ = await task.value
    }

    @Test func reverseDNSGateway() async throws {
        // Use the per-interface gateway (the system default route may be a VPN without one).
        guard let gw = NetworkInterfaces.active().compactMap(\.gateway).first else {
            print("reverse dns: no LAN gateway, skipping")
            return
        }
        let start = ContinuousClock.now
        let name = await ReverseDNS.lookup(gw)
        if verboseNet { print("reverse dns", gw, "->", name ?? "nil", "in", ContinuousClock.now - start) }
        #expect(ContinuousClock.now - start < .seconds(3))
        #expect(name?.hasSuffix(".") != true)
    }

    @Test func reverseDNSTimeout() async {
        // TEST-NET-1 should not resolve; must return promptly.
        let start = ContinuousClock.now
        let name = await ReverseDNS.lookup(IPv4Address("192.0.2.1")!, timeout: .milliseconds(300))
        #expect(ContinuousClock.now - start < .seconds(2))
        _ = name
    }
}

/// Live tests print the devices they find only with `LANTERNFISHKIT_NET=1`, so CI logs don't list the
/// runner's network.
let verboseNet = ProcessInfo.processInfo.environment["LANTERNFISHKIT_NET"] == "1"
