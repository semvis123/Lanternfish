import Foundation
import Testing

@testable import LanternfishKit

@Suite struct SSDPTests {
    @Test func parsesMSearchResponse() {
        let response =
            "HTTP/1.1 200 OK\r\n"
            + "CACHE-CONTROL: max-age=1800\r\n"
            + "Date: Sat, 07 Nov 2026 10:00:00 GMT\r\n"
            + "EXT:\r\n"
            + "Location: http://192.168.1.20:1400/xml/device_description.xml\r\n"
            + "Server: Linux UPnP/1.0 Sonos/70.3-35220 (ZPS9)\r\n"
            + "st: upnp:rootdevice\r\n"
            + "USN: uuid:RINCON_000E58A1B2C301400::upnp:rootdevice\r\n"
            + "\r\n"
        let h = SSDP.parseHeaders(response)
        #expect(h["location"] == "http://192.168.1.20:1400/xml/device_description.xml")
        #expect(h["server"] == "Linux UPnP/1.0 Sonos/70.3-35220 (ZPS9)")
        #expect(h["st"] == "upnp:rootdevice")
        #expect(h["usn"] == "uuid:RINCON_000E58A1B2C301400::upnp:rootdevice")
        #expect(h["ext"] == "")
        #expect(h["http/1.1 200 ok"] == nil)
        #expect(h["date"] == "Sat, 07 Nov 2026 10:00:00 GMT")
    }

    @Test func parsesBareNewlines() {
        let h = SSDP.parseHeaders("HTTP/1.1 200 OK\nLOCATION: http://10.0.0.1:5000/rootDesc.xml\nST: ssdp:all\n\n")
        #expect(h["location"] == "http://10.0.0.1:5000/rootDesc.xml")
        #expect(h["st"] == "ssdp:all")
    }

    static let sampleXML = """
        <?xml version="1.0" encoding="utf-8"?>
        <root xmlns="urn:schemas-upnp-org:device-1-0">
          <specVersion><major>1</major><minor>0</minor></specVersion>
          <device>
            <deviceType>urn:schemas-upnp-org:device:InternetGatewayDevice:1</deviceType>
            <friendlyName>FRITZ!Box 7590</friendlyName>
            <manufacturer>AVM Berlin</manufacturer>
            <manufacturerURL>http://www.avm.de</manufacturerURL>
            <modelName>FRITZ!Box 7590</modelName>
            <modelNumber>avm</modelNumber>
            <UDN>uuid:75802409-bccb-40e7-8e6c-3431C4A1B2C3</UDN>
            <deviceList>
              <device>
                <deviceType>urn:schemas-upnp-org:device:WANDevice:1</deviceType>
                <friendlyName>WANDevice - FRITZ!Box 7590</friendlyName>
                <manufacturer>Embedded Inc</manufacturer>
                <modelName>WANDevice - FRITZ!Box 7590</modelName>
                <modelNumber>avm-wan</modelNumber>
              </device>
            </deviceList>
            <serialNumber>3431C4A1B2C3</serialNumber>
          </device>
        </root>
        """

    @Test func parsesRootDeviceOnly() throws {
        let d = try #require(UPnPDescription.parse(Data(Self.sampleXML.utf8)))
        #expect(
            d
                == UPnPDescription(
                    friendlyName: "FRITZ!Box 7590", manufacturer: "AVM Berlin",
                    modelName: "FRITZ!Box 7590", modelNumber: "avm",
                    deviceType: "urn:schemas-upnp-org:device:InternetGatewayDevice:1"))
        #expect(SSDP.kind(for: d) == .router)
    }

    @Test func embeddedDeviceFieldsAfterRootFieldsAreIgnored() throws {
        let xml = """
            <root><device><deviceList><device><friendlyName>Child</friendlyName></device></deviceList>
            <friendlyName>Root</friendlyName></device></root>
            """
        let d = try #require(UPnPDescription.parse(Data(xml.utf8)))
        #expect(d.friendlyName == "Root")
    }

    @Test func garbageIsNil() {
        #expect(UPnPDescription.parse(Data("not xml at all {".utf8)) == nil)
        #expect(UPnPDescription.parse(Data()) == nil)
        #expect(UPnPDescription.parse(Data("<root><specVersion/></root>".utf8)) == nil)
    }

    @Test func kindsFromDeviceType() {
        func k(_ t: String, _ m: String? = nil) -> DeviceKind? {
            SSDP.kind(for: UPnPDescription(manufacturer: m, deviceType: "urn:schemas-upnp-org:device:\(t):1"))
        }
        #expect(k("MediaRenderer", "Sonos, Inc.") == .speaker)
        #expect(k("MediaRenderer", "Samsung Electronics") == .tv)
        #expect(k("MediaServer", "Synology") == .nas)
        #expect(k("MediaServer", "Microsoft Corporation") == .computer)
        #expect(k("Printer") == .printer)
        #expect(k("DigitalSecurityCamera") == .camera)
        #expect(k("Basic") == nil)
    }

    @Test func modelCombinesNameAndNumber() {
        #expect(SSDP.model(name: "OfficeJet Pro", number: "9010") == "OfficeJet Pro 9010")
        #expect(SSDP.model(name: "FRITZ!Box 7590", number: "7590") == "FRITZ!Box 7590")
        #expect(SSDP.model(name: "Sonos One", number: "S18") == "Sonos One S18")
        #expect(SSDP.model(name: "DS920+", number: "001132A1B2C3D4") == "DS920+")
        #expect(SSDP.model(name: nil, number: nil) == nil)
    }

    @Test func patchWithoutDescriptionStillMarksUPnP() {
        let p = SSDP.patch(ip: IPv4Address("10.0.0.5")!, description: nil, server: "Linux/5.4 UPnP/1.0 MiniUPnPd/2.2")
        #expect(p.services == ["UPnP"])
        #expect(p.name == nil)
    }

    @Test(.timeLimit(.minutes(1))) func liveScanSmoke() async {
        let start = ContinuousClock.now
        var patches: [DevicePatch] = []
        for await p in SSDPScanner().scan() { patches.append(p) }
        let elapsed = ContinuousClock.now - start
        print("SSDP live: \(patches.count) device(s) in \(elapsed)")
        for p in patches.sorted(by: { $0.ip < $1.ip }) where verboseNet {
            print(
                "  \(p.ip)  name=\(p.name ?? "-")  maker=\(p.manufacturer ?? "-")  model=\(p.model ?? "-")  kind=\(p.kind.map(\.rawValue) ?? "-")"
            )
        }
        #expect(elapsed < .seconds(6))
        #expect(Set(patches.map(\.ip)).count == patches.count)
    }
}

@Suite struct SSDPSocketTests {
    @Test func sendAfterCloseNeverTouchesAReusedDescriptor() throws {
        // A sender waking up after the socket closed must not write to the descriptor number,
        // which may by then belong to another socket.
        let socket = try #require(UDPSocket.open())
        let number = socket.rawFD
        socket.close()
        // Something else gets the freed number (as another scanner's socket would).
        var fds: [Int32] = [0, 0]
        try #require(pipe(&fds) == 0)
        defer {
            Darwin.close(fds[0])
            Darwin.close(fds[1])
        }
        #expect(fds.contains(number))
        // The stale wrapper must neither send on nor close the reused descriptor.
        socket.send("M-SEARCH * HTTP/1.1\r\n\r\n")
        socket.close()
        #expect(fcntl(fds[0], F_GETFD) != -1 && fcntl(fds[1], F_GETFD) != -1)
        _ = fcntl(fds[0], F_SETFL, fcntl(fds[0], F_GETFL) | O_NONBLOCK)
        var byte: UInt8 = 0
        #expect(read(fds[0], &byte, 1) == -1)  // nothing was written into the pipe
    }

    @Test func scanCancelledImmediatelyFinishesCleanly() async {
        let stream = SSDPScanner().scan(duration: .seconds(5))
        let task = Task { for await _ in stream {} }
        task.cancel()
        await task.value
    }

    @Test func descriptionURLMustBeServedByTheResponder() {
        let ip = IPv4Address("192.168.1.20")!
        #expect(SSDPScanner.descriptionURL("http://192.168.1.20:49152/desc.xml", ip: ip) != nil)
        #expect(SSDPScanner.descriptionURL("http://192.168.1.21/desc.xml", ip: ip) == nil)
        #expect(SSDPScanner.descriptionURL("http://example.com/desc.xml", ip: ip) == nil)
        #expect(SSDPScanner.descriptionURL("file:///etc/passwd", ip: ip) == nil)
        #expect(SSDPScanner.descriptionURL(nil, ip: ip) == nil)
    }
}
