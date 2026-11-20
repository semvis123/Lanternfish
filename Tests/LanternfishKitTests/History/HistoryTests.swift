import Foundation
import Testing

@testable import LanternfishKit

@Suite struct HistoryTests {
    let subnet = Subnet(address: IPv4Address("192.168.1.12")!, prefixLength: 24)
    let gw = IPv4Address("192.168.1.1")!
    let gwMAC = MACAddress("00:00:5e:00:53:01")!
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func device(
        _ ip: String, mac: String? = nil, name: String? = nil, kind: DeviceKind = .unknown,
        ports: [UInt16] = []
    ) -> Device {
        var d = Device(ip: IPv4Address(ip)!)
        d.mac = mac.flatMap(MACAddress.init)
        d.name = name
        d.kind = kind
        d.openPorts = ports.map { OpenPort(port: $0) }
        return d
    }

    func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "history-tests-\(UUID().uuidString)")
    }

    // MARK: Networks

    @Test func adoptsGatewaylessNetworkOnceGatewayIsKnown() {
        var h = HistoryStore()
        let wifi = Subnet(address: IPv4Address("10.0.0.8")!, prefixLength: 24)
        let old = h.identifyNetwork(gatewayMAC: nil, gatewayIP: nil, subnet: wifi, now: t0)
        let gw10 = IPv4Address("10.0.0.1")!
        let mac = MACAddress("aa:bb:cc:00:11:22")!
        let byIP = h.identifyNetwork(gatewayMAC: nil, gatewayIP: gw10, subnet: wifi, now: t0 + 60)
        #expect(byIP == old)
        let byMAC = h.identifyNetwork(gatewayMAC: mac, gatewayIP: gw10, subnet: wifi, now: t0 + 120)
        #expect(byMAC == old)
        #expect(h.networks.count == 1)
        #expect(h.networks[old]?.gatewayIP == "10.0.0.1")
        #expect(h.networks[old]?.gatewayMAC == mac.description)
        // Another subnet stays separate.
        _ = h.identifyNetwork(gatewayMAC: gwMAC, gatewayIP: gw, subnet: subnet, now: t0 + 180)
        #expect(h.networks.count == 2)
    }

    @Test func identifiesNetworkByGatewayMAC() {
        var h = HistoryStore()
        let a = h.identifyNetwork(gatewayMAC: gwMAC, gatewayIP: gw, subnet: subnet, now: t0)
        let b = h.identifyNetwork(gatewayMAC: gwMAC, gatewayIP: gw, subnet: subnet, now: t0 + 60)
        #expect(a == b)
        // Same addresses, different router: a different network.
        let other = h.identifyNetwork(gatewayMAC: MACAddress("00:00:5e:00:53:02"), gatewayIP: gw, subnet: subnet)
        #expect(other != a)
        #expect(h.networks.count == 2)
        #expect(h.networks[a]?.subnet == "192.168.1.0/24")
    }

    @Test func fallbackNetworkAdoptsGatewayMACLater() {
        var h = HistoryStore()
        let a = h.identifyNetwork(gatewayMAC: nil, gatewayIP: gw, subnet: subnet, now: t0)
        #expect(h.networks[a]?.gatewayMAC == nil)
        let b = h.identifyNetwork(gatewayMAC: gwMAC, gatewayIP: gw, subnet: subnet, now: t0 + 1)
        #expect(a == b)
        #expect(h.networks[a]?.gatewayMAC == gwMAC.description)
        // Without MAC, still matches by gateway IP + subnet.
        #expect(h.identifyNetwork(gatewayMAC: nil, gatewayIP: gw, subnet: subnet) == a)
    }

    @Test func renameAndForgetNetwork() {
        var h = HistoryStore()
        let a = h.identifyNetwork(gatewayMAC: gwMAC, gatewayIP: gw, subnet: subnet)
        h.renameNetwork(id: a, to: "  Home  ")
        #expect(h.networks[a]?.customName == "Home")
        h.renameNetwork(id: a, to: "")
        #expect(h.networks[a]?.customName == nil)
        h.forgetNetwork(id: a)
        #expect(h.networks.isEmpty)
    }

    // MARK: Devices

    @Test func firstScanDevicesAreNotNewLaterOnesAre() {
        var h = HistoryStore()
        let n = h.identifyNetwork(gatewayMAC: gwMAC, gatewayIP: gw, subnet: subnet, now: t0)
        let created = h.record([device("192.168.1.1", mac: "00:00:5e:00:53:01")], networkID: n, now: t0)
        #expect(created.isEmpty)
        h.completeScan(networkID: n)
        let created2 = h.record([device("192.168.1.50", mac: "00:00:5e:00:53:02")], networkID: n, now: t0 + 10)
        #expect(created2 == ["mac:00:00:5E:00:53:02"])
        let merged = h.merged(
            online: [device("192.168.1.50", mac: "00:00:5e:00:53:02")], networkID: n,
            includeOffline: true)
        #expect(merged.first { $0.ip.description == "192.168.1.50" }?.isNew == true)
        #expect(merged.first { $0.ip.description == "192.168.1.1" }?.isNew == false)
        h.updateDevice(key: "mac:00:00:5E:00:53:02", networkID: n) { $0.acknowledged = true }
        #expect(h.merged(online: [], networkID: n, includeOffline: true).allSatisfy { !$0.isNew })
    }

    @Test func offlineDevicesKeepSnapshotAndLastSeen() {
        var h = HistoryStore()
        let n = h.identifyNetwork(gatewayMAC: gwMAC, gatewayIP: gw, subnet: subnet, now: t0)
        var tv = device("192.168.1.20", mac: "8c:79:f5:aa:bb:cc", name: "Living Room TV", kind: .tv, ports: [8001])
        tv.manufacturer = "Samsung"
        h.record([tv], networkID: n, now: t0, scanComplete: true)
        h.completeScan(networkID: n)

        let later = t0 + 3 * 86_400
        h.record([device("192.168.1.1", mac: "00:00:5e:00:53:01")], networkID: n, now: later)
        let rows = h.merged(
            online: [device("192.168.1.1", mac: "00:00:5e:00:53:01")], networkID: n,
            includeOffline: true)
        #expect(rows.count == 2)
        let off = rows.first { !$0.isOnline }
        #expect(off?.displayName == "Living Room TV")
        #expect(off?.kind == .tv)
        #expect(off?.manufacturer == "Samsung")
        #expect(off?.openPorts.map(\.port) == [8001])
        #expect(off?.lastSeen == t0)
        #expect(off?.firstSeen == t0)
        #expect(rows.first { $0.isOnline }?.lastSeen == later)
        // Hidden when offline devices are excluded.
        #expect(h.merged(online: [], networkID: n, includeOffline: false).isEmpty)
    }

    @Test func customLabelsApplyToLiveDevices() {
        var h = HistoryStore()
        let n = h.identifyNetwork(gatewayMAC: gwMAC, gatewayIP: gw, subnet: subnet, now: t0)
        let d = device("192.168.1.57", mac: "24:0a:c4:de:ad:01", kind: .iot)
        let key = h.ensureRecord(for: d, networkID: n)!
        h.updateDevice(key: key, networkID: n) {
            $0.customName = "Kitchen Sensor"
            $0.customKind = .camera
            $0.notes = "Behind the fridge"
        }
        // Same MAC on a new IP keeps the labels.
        let moved = device("192.168.1.99", mac: "24:0a:c4:de:ad:01", kind: .iot)
        let row = h.merged(online: [moved], networkID: n, includeOffline: true)
        #expect(row.count == 1)
        #expect(row[0].displayName == "Kitchen Sensor")
        #expect(row[0].effectiveKind == .camera)
        #expect(row[0].kind == .iot)
        #expect(row[0].notes == "Behind the fridge")
        #expect(row[0].historyKey == key)
    }

    @Test func ipKeyedRecordMigratesWhenMACArrives() {
        var h = HistoryStore()
        let n = h.identifyNetwork(gatewayMAC: gwMAC, gatewayIP: gw, subnet: subnet, now: t0)
        // Without MAC, only recorded once the scan completes.
        #expect(h.record([device("192.168.1.102")], networkID: n, now: t0).isEmpty)
        #expect(h.networks[n]?.devices.isEmpty == true)
        h.record([device("192.168.1.102")], networkID: n, now: t0, scanComplete: true)
        h.updateDevice(key: "ip:192.168.1.102", networkID: n) { $0.customName = "Mystery" }
        h.completeScan(networkID: n)

        let created = h.record([device("192.168.1.102", mac: "aa:bb:cc:00:11:22")], networkID: n, now: t0 + 5)
        #expect(created.isEmpty)  // migrated, not new
        let devices = h.networks[n]!.devices
        #expect(devices.keys.sorted() == ["mac:AA:BB:CC:00:11:22"])
        #expect(devices["mac:AA:BB:CC:00:11:22"]?.customName == "Mystery")
        #expect(devices["mac:AA:BB:CC:00:11:22"]?.firstSeen == t0)
    }

    @Test func macLessLiveDeviceMatchesRememberedDeviceByIP() {
        var h = HistoryStore()
        let n = h.identifyNetwork(gatewayMAC: gwMAC, gatewayIP: gw, subnet: subnet, now: t0)
        h.record([device("192.168.1.44", mac: "3c:52:82:01:02:03", name: "HP-Printer")], networkID: n, now: t0)
        // ARP not filled yet: no duplicate offline row, and the name is filled in.
        let rows = h.merged(online: [device("192.168.1.44")], networkID: n, includeOffline: true)
        #expect(rows.count == 1)
        #expect(rows[0].isOnline)
        #expect(rows[0].displayName == "HP-Printer")
    }

    @Test func offlineRowsWithTakenIPGetDistinctIDs() {
        var h = HistoryStore()
        let n = h.identifyNetwork(gatewayMAC: gwMAC, gatewayIP: gw, subnet: subnet, now: t0)
        h.record([device("192.168.1.31", mac: "da:00:5e:00:53:01")], networkID: n, now: t0)
        // Another device now has .31.
        let rows = h.merged(
            online: [device("192.168.1.31", mac: "da:00:5e:00:53:02")], networkID: n,
            includeOffline: true)
        #expect(rows.count == 2)
        #expect(Set(rows.map(\.id)).count == 2)
        #expect(rows.allSatisfy { $0.ip.description == "192.168.1.31" })
        #expect(rows.first { !$0.isOnline }?.idOverride != nil)
    }

    @Test func snapshotUnionsDuringScanAndReplacesOnCompletion() {
        var h = HistoryStore()
        let n = h.identifyNetwork(gatewayMAC: gwMAC, gatewayIP: gw, subnet: subnet, now: t0)
        h.record([device("192.168.1.5", mac: "aa:aa:aa:aa:aa:01", ports: [22, 80])], networkID: n, scanComplete: true)
        h.record([device("192.168.1.5", mac: "aa:aa:aa:aa:aa:01", ports: [443])], networkID: n)
        #expect(h.networks[n]!.devices["mac:AA:AA:AA:AA:AA:01"]!.openPorts.map(\.port) == [22, 80, 443])
        h.record([device("192.168.1.5", mac: "aa:aa:aa:aa:aa:01", ports: [443])], networkID: n, scanComplete: true)
        #expect(h.networks[n]!.devices["mac:AA:AA:AA:AA:AA:01"]!.openPorts.map(\.port) == [443])
    }

    @Test func forgetDevice() {
        var h = HistoryStore()
        let n = h.identifyNetwork(gatewayMAC: gwMAC, gatewayIP: gw, subnet: subnet, now: t0)
        h.record([device("192.168.1.5", mac: "aa:aa:aa:aa:aa:01")], networkID: n)
        h.forgetDevice(key: "mac:AA:AA:AA:AA:AA:01", networkID: n)
        #expect(h.networks[n]!.devices.isEmpty)
    }

    // MARK: Persistence

    @Test func roundTripsThroughDisk() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        var h = HistoryStore()
        let n = h.identifyNetwork(gatewayMAC: gwMAC, gatewayIP: gw, subnet: subnet, now: t0)
        var d = device("192.168.1.20", mac: "8c:79:f5:aa:bb:cc", name: "TV", kind: .tv, ports: [8001])
        d.services = ["AirPlay"]
        h.record([d], networkID: n, now: t0)
        h.updateDevice(key: "mac:8C:79:F5:AA:BB:CC", networkID: n) {
            $0.customKind = .speaker
            $0.notes = "line 1\nline 2"
        }
        h.renameNetwork(id: n, to: "Home")
        try h.save(to: dir)

        let loaded = HistoryStore.load(from: dir)
        #expect(loaded == h)
        let rec = loaded.networks[n]!.devices["mac:8C:79:F5:AA:BB:CC"]!
        #expect(rec.customKind == .speaker)
        #expect(rec.openPorts.map(\.port) == [8001])
        #expect(rec.services == ["AirPlay"])
        #expect(loaded.networks[n]!.customName == "Home")
    }

    @Test func missingFileIsEmpty() {
        #expect(HistoryStore.load(from: tempDir()).networks.isEmpty)
    }

    @Test func toleratesMissingAndUnknownFields() throws {
        let json = """
            {"version": 99, "futureField": true, "networks": [
              {"id": "n1", "subnet": "10.0.0.0/24", "devices": {
                "mac:AA:BB:CC:DD:EE:FF": {"key": "mac:AA:BB:CC:DD:EE:FF", "kind": "hologram", "extra": 1},
                "bad": {"nokey": 1}
              }},
              {"garbage": [1, 2, 3], "id": 5}
            ]}
            """
        let h = try HistoryStore.decode(Data(json.utf8))
        let n = try #require(h.networks["n1"])
        #expect(n.devices.count == 1)
        let d = try #require(n.devices["mac:AA:BB:CC:DD:EE:FF"])
        #expect(d.kind == .unknown)
        #expect(d.acknowledged)
        #expect(d.lastIP == "0.0.0.0")
    }

    @Test func corruptFileIsMovedAside() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: dir.appending(path: HistoryStore.fileName))
        #expect(HistoryStore.load(from: dir).networks.isEmpty)
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(files.contains { $0.hasPrefix("history-corrupt-") })
        #expect(!files.contains(HistoryStore.fileName))
    }

    // MARK: Device model

    @Test func customNameWinsInDisplayName() {
        var d = device("192.168.1.5", name: "esp32")
        #expect(d.displayName == "esp32")
        d.customName = "Doorbell"
        #expect(d.displayName == "Doorbell")
        d.customName = ""
        #expect(d.displayName == "esp32")
    }
}
