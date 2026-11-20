import Foundation
import Testing

@testable import LanternfishKit

@Suite struct NameCleanupTests {
    @Test(arguments: [
        "GRX350_1600_MR_AXEPOINT_6X_WAV60", "SOC_7621_V2_REV3", "5U9193WKA1115", "a1b2c3d4e5f6", "00:11:22:33:44:55",
        "BCM_4908_AX_REF", "GRX350_1600_MR_AXEPOINT_6X_WAV60 5U9193WKA1115",
    ])
    func firmwareish(_ s: String) {
        #expect(NameCleanup.isFirmwareish(s))
    }

    @Test(arguments: [
        "RAX40", "RAX40 (Gateway)", "SONY KD-55A8", "Living Room TV", "MacBook_Pro", "Archer_AX10", "DIRIGERA",
        "READYSHARE", "J10806277", "Kyocera ECOSYS M6026cidn", "DS920+", "FRITZ!Box 7590", "Sonos One S18",
    ])
    func notFirmwareish(_ s: String) {
        #expect(!NameCleanup.isFirmwareish(s))
    }

    @Test func manufacturers() {
        #expect(NameCleanup.manufacturer("NETGEAR, Inc.") == "Netgear")
        #expect(NameCleanup.manufacturer("Netgear, Inc.") == "Netgear")
        #expect(NameCleanup.manufacturer("Sony Corporation") == "Sony")
        #expect(NameCleanup.manufacturer("Samsung Electronics Co.,Ltd.") == "Samsung")
        #expect(NameCleanup.manufacturer("AVM Berlin") == "AVM")
        #expect(NameCleanup.manufacturer("Philips Hue") == "Philips Hue")
        #expect(NameCleanup.manufacturer("Acme Widgets, Inc.") == "Acme Widgets")
        #expect(NameCleanup.manufacturer("Foo Technologies Co., Ltd.") == "Foo")
        #expect(NameCleanup.manufacturer("  ") == nil)
    }

    @Test func models() {
        #expect(NameCleanup.model("GRX350_1600_MR_AXEPOINT_6X_WAV60 RAX40") == "RAX40")
        #expect(NameCleanup.model("OfficeJet Pro 9010") == "OfficeJet Pro 9010")
        #expect(NameCleanup.model("GRX350_1600_MR_AXEPOINT_6X_WAV60") == nil)
    }

    @Test func friendlyNames() {
        #expect(
            NameCleanup.friendlyName(
                "GRX350_1600_MR_AXEPOINT_6X_WAV60", manufacturer: "NETGEAR, Inc.",
                model: "GRX350_1600_MR_AXEPOINT_6X_WAV60 RAX40") == "Netgear RAX40")
        #expect(
            NameCleanup.friendlyName("RAX40 (Gateway)", manufacturer: "Netgear", model: "RAX40") == "RAX40 (Gateway)")
        #expect(NameCleanup.friendlyName("Living Room", manufacturer: "Sonos", model: "One") == "Living Room")
        #expect(NameCleanup.friendlyName("SOC_7621_V2_REV3", manufacturer: nil, model: nil) == nil)
        #expect(NameCleanup.friendlyName("SOC_7621_V2_REV3", manufacturer: "Acme", model: nil) == "Acme")
    }

    @Test func ssdpPatchUsesCleanNames() {
        let desc = UPnPDescription(
            friendlyName: "GRX350_1600_MR_AXEPOINT_6X_WAV60", manufacturer: "NETGEAR, Inc.",
            modelName: "GRX350_1600_MR_AXEPOINT_6X_WAV60", modelNumber: "RAX40",
            deviceType: "urn:schemas-upnp-org:device:InternetGatewayDevice:1")
        let p = SSDP.patch(ip: IPv4Address("10.0.0.1")!, description: desc, server: nil)
        #expect(p.name == "Netgear RAX40")
        #expect(p.manufacturer == "Netgear")
        #expect(p.model == "RAX40")
        #expect(p.kind == .router)
    }

    @Test func sanitizeStoredDevice() {
        var d = Device(ip: IPv4Address("10.0.0.1")!)
        d.name = "GRX350_1600_MR_AXEPOINT_6X_WAV60"
        d.manufacturer = "NETGEAR, Inc."
        d.model = "GRX350_1600_MR_AXEPOINT_6X_WAV60 RAX40"
        NameCleanup.sanitize(&d)
        #expect(d.name == "Netgear RAX40")
        #expect(d.manufacturer == "Netgear")
        #expect(d.model == "RAX40")
        #expect(d.brandModel == "Netgear RAX40")
    }

    @Test func historySnapshotIsSanitizedAndKeepsConfidence() throws {
        var k = KnownDevice(key: "mac:02:00:5E:00:53:10", lastIP: "10.0.0.1", firstSeen: Date(), lastSeen: Date())
        k.name = "GRX350_1600_MR_AXEPOINT_6X_WAV60"
        k.manufacturer = "NETGEAR, Inc."
        k.model = "GRX350_1600_MR_AXEPOINT_6X_WAV60 RAX40"
        k.confidence = 0.93
        k.identificationReasons = ["Default gateway of this network"]
        let data = try JSONEncoder().encode(k)
        let back = try JSONDecoder().decode(KnownDevice.self, from: data)
        #expect(back.confidence == 0.93)
        #expect(back.identificationReasons == ["Default gateway of this network"])
        let offline = back.offlineDevice()
        #expect(offline.name == "Netgear RAX40")
        #expect(offline.confidence == 0.93)
        // Files saved without the identification keys still decode.
        let old = try JSONDecoder().decode(KnownDevice.self, from: Data(#"{"key":"ip:10.0.0.9"}"#.utf8))
        #expect(old.confidence == nil && old.identificationReasons.isEmpty)
    }

    @Test func oldOfflineRecordsAreFingerprinted() {
        var k = KnownDevice(key: "mac:00:00:5E:00:53:03", lastIP: "10.0.0.14", firstSeen: Date(), lastSeen: Date())
        k.vendor = "Garmin"
        let d = k.offlineDevice()
        #expect(d.kind == .phone)
        #expect(d.manufacturer == "Garmin")
        #expect((d.confidence ?? 0) >= 0.5)
    }

    @Test func snapshotUpdateCarriesIdentification() {
        var k = KnownDevice(key: "ip:10.0.0.4", lastIP: "10.0.0.4", firstSeen: Date(), lastSeen: Date())
        var d = Device(ip: IPv4Address("10.0.0.4")!)
        d.confidence = 0.97
        d.identificationReasons = ["Advertises Bambu Lab"]
        k.updateSnapshot(from: d, replaceCollections: true)
        #expect(k.confidence == 0.97)
        var live = Device(ip: IPv4Address("10.0.0.4")!)
        k.fillGaps(&live)
        #expect(live.identificationReasons == ["Advertises Bambu Lab"])
        // A quiet rescan (weak, generic identification) neither replaces nor hides the good one.
        var quiet = Device(ip: IPv4Address("10.0.0.4")!)
        quiet.confidence = 0
        quiet.identificationReasons = ["Private MAC address and no names, services or open ports"]
        k.updateSnapshot(from: quiet, replaceCollections: false)
        #expect(k.confidence == 0.97)
        k.fillGaps(&quiet)
        #expect(quiet.confidence == 0.97)
        // A decent new identification does replace it.
        var better = Device(ip: IPv4Address("10.0.0.4")!)
        better.confidence = 0.6
        better.identificationReasons = ["Port 631 open (IPP)"]
        k.updateSnapshot(from: better, replaceCollections: false)
        #expect(k.confidence == 0.6)
    }

    @Test func fingerprintIsCheapEnoughForEveryPatch() {
        let d = FingerprintTests.device(
            vendor: "Sony", name: "SONY KD-55A8", hostname: "Android.local",
            services: ["AirPlay", "Android TV", "Chromecast"], ports: [80, 8008, 8009, 8443])
        let start = ContinuousClock.now
        for _ in 0..<200 { _ = Fingerprint.identify(d) }
        let per = (ContinuousClock.now - start) / 200
        #expect(per < .milliseconds(5))
    }
}

@Suite struct EnrichSourcesTests {
    @Test func bambuAnnouncement() throws {
        let text = """
            HTTP/1.1 200 OK\r
            Server: UPnP/1.0\r
            Location: 10.0.0.4\r
            ST: urn:bambulab-com:device:3dprinter:1\r
            USN: 20P9BJ5C3101898\r
            DevModel.bambu.com: C12\r
            DevName.bambu.com: Workshop\r
            DevVersion.bambu.com: 01.02.00.00\r
            \r

            """
        let p = try #require(BambuSSDP.patch(ip: IPv4Address("10.0.0.4")!, headers: SSDP.parseHeaders(text)))
        #expect(p.manufacturer == "Bambu Lab")
        #expect(p.model == "P1S 3D Printer")
        #expect(p.name == "Workshop")
        #expect(p.kind == .printer)
        #expect(p.services == ["Bambu Lab"])
        let unknown = BambuSSDP.patch(ip: IPv4Address("10.0.0.5")!, headers: ["devmodel.bambu.com": "N6"])
        #expect(unknown?.model == "3D Printer (N6)")
        #expect(BambuSSDP.patch(ip: IPv4Address("10.0.0.5")!, headers: ["st": "upnp:rootdevice"]) == nil)
        #expect(BambuSSDP.mSearch().contains("ST: urn:bambulab-com:device:3dprinter:1\r\n"))
    }

    @Test func netgearCurrentSetting() throws {
        let body =
            "Firmware=V1.0.6.106_1.0.1\r\nRegionTag=RAX40_WW\r\nRegion=WW\r\nModel=RAX40\r\nInternetConnectionStatus=Up\r\n"
        let info = try #require(GatewayInfo.parseNetgearCurrentSetting(body))
        #expect(info.model == "RAX40")
        #expect(info.firmware == "V1.0.6.106_1.0.1")
        #expect(GatewayInfo.parseNetgearCurrentSetting("<html>Login</html>") == nil)
        #expect(GatewayInfo.parseNetgearCurrentSetting("Model=<script>alert(1)</script>") == nil)
    }

    @Test func faviconHashes() {
        #expect(FaviconFingerprint.md5(Data("abc".utf8)) == "900150983cd24fb0d6963f7d28e17f72")
        #expect(FaviconFingerprint.looksLikeImage(Data([0, 0, 1, 0, 1, 0])))
        #expect(FaviconFingerprint.looksLikeImage(Data([0x89, 0x50, 0x4E, 0x47])))
        #expect(!FaviconFingerprint.looksLikeImage(Data("<html>404</html>".utf8)))
        #expect(FaviconFingerprint.identify(Data("<html>404</html>".utf8)) == nil)
        #expect(FaviconFingerprint.table.count >= 10)
    }

    @Test func dialDeviceIsTV() {
        let d = UPnPDescription(
            friendlyName: "SONY KD-55A8", manufacturer: "Sony", modelName: "BRAVIA 4K UR3",
            deviceType: "urn:dial-multiscreen-org:device:dial:1")
        #expect(SSDP.kind(for: d) == .tv)
    }
}
