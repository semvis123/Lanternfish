import Foundation
import Testing

@testable import LanternfishKit

/// Retention, persistence safety and monitoring gaps.
@Suite struct HistoryRobustnessTests {
    let subnet = Subnet(address: IPv4Address("192.168.1.12")!, prefixLength: 24)
    let gw = IPv4Address("192.168.1.1")!
    let gwMAC = MACAddress("00:00:5e:00:53:01")!
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let day: TimeInterval = 86_400

    func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "history-robust-\(UUID().uuidString)")
    }

    func device(_ ip: String, mac: String? = nil, ports: [UInt16] = []) -> Device {
        var d = Device(ip: IPv4Address(ip)!)
        d.mac = mac.flatMap(MACAddress.init)
        d.openPorts = ports.map { OpenPort(port: $0) }
        return d
    }

    func rec(
        _ key: String, mac: String? = nil, ip: String = "192.168.1.50", first: Date, last: Date,
        hostname: String? = nil
    ) -> KnownDevice {
        var r = KnownDevice(key: key, mac: mac, lastIP: ip, firstSeen: first, lastSeen: last)
        r.hostname = hostname
        return r
    }

    // MARK: Retention

    @Test func compactDropsStaleDevicesWithoutUserData() {
        var net = KnownNetwork(id: "n", subnet: "192.168.1.0/24", firstSeen: t0, lastSeen: t0 + 100 * day)
        let now = t0 + 100 * day
        net.devices["mac:a"] = rec("mac:a", first: t0, last: t0)  // stale
        var labeled = rec("mac:b", first: t0, last: t0)
        labeled.customName = "Printer"
        net.devices["mac:b"] = labeled  // stale but labeled
        var watched = rec("mac:c", first: t0, last: t0)
        watched.isWatched = true
        net.devices["mac:c"] = watched  // stale but watched
        net.devices["mac:d"] = rec("mac:d", first: t0, last: now - day)  // recent
        var h = HistoryStore(networks: [net])
        let report = h.compact(now: now)
        #expect(report.droppedDevices == 1)
        #expect(Set(h.networks["n"]!.devices.keys) == ["mac:b", "mac:c", "mac:d"])
    }

    @Test func compactDropsOldNetworksUnlessRenamedOrLabeled() {
        let now = t0 + 200 * day
        let plain = KnownNetwork(id: "plain", subnet: "10.0.0.0/24", firstSeen: t0)
        var renamed = KnownNetwork(id: "renamed", subnet: "10.0.1.0/24", firstSeen: t0)
        renamed.customName = "Office"
        var labeled = KnownNetwork(id: "labeled", subnet: "10.0.2.0/24", firstSeen: t0)
        var r = rec("mac:x", first: t0, last: t0)
        r.notes = "NAS"
        labeled.devices[r.key] = r
        let recent = KnownNetwork(id: "recent", subnet: "10.0.3.0/24", firstSeen: t0, lastSeen: now - day)
        var h = HistoryStore(networks: [plain, renamed, labeled, recent])
        let report = h.compact(now: now)
        #expect(report.droppedNetworks == 1)
        #expect(Set(h.networks.keys) == ["renamed", "labeled", "recent"])
    }

    @Test func compactCapsDevicesPerNetworkOldestUnlabeledFirst() {
        var net = KnownNetwork(id: "n", subnet: "10.0.0.0/16", firstSeen: t0)
        let cap = HistoryRetention.maxDevicesPerNetwork
        for i in 0..<(cap + 5) {
            let key = "mac:\(i)"
            net.devices[key] = rec(key, first: t0, last: t0 + TimeInterval(i))
        }
        var oldestLabeled = rec("mac:0", first: t0, last: t0)
        oldestLabeled.customKind = .printer
        net.devices["mac:0"] = oldestLabeled
        var h = HistoryStore(networks: [net])
        let report = h.compact(now: t0 + day)
        let left = h.networks["n"]!.devices
        #expect(report.droppedDevices == 5)
        #expect(left.count == cap)
        #expect(left["mac:0"] != nil)  // labeled survives
        #expect((1...5).allSatisfy { left["mac:\($0)"] == nil })
        #expect(left["mac:6"] != nil)
    }

    @Test func foldsRotatedPrivateMACsBySpecificHostname() {
        // 0x02 bit set: locally administered (private Wi-Fi address).
        let old = rec(
            "mac:02:00:00:00:00:01", mac: "02:00:00:00:00:01", first: t0, last: t0 + day,
            hostname: "Sams-iPhone.local")
        let new = rec(
            "mac:06:00:00:00:00:02", mac: "06:00:00:00:00:02", first: t0 + 2 * day, last: t0 + 3 * day,
            hostname: "sams-iphone")
        // Generic names and overlapping lifetimes are left alone.
        let genericA = rec(
            "mac:0a:00:00:00:00:03", mac: "0a:00:00:00:00:03", first: t0, last: t0 + day, hostname: "iPhone")
        let genericB = rec(
            "mac:0a:00:00:00:00:04", mac: "0a:00:00:00:00:04", first: t0 + 2 * day, last: t0 + 3 * day,
            hostname: "iphone")
        let overlapA = rec(
            "mac:0e:00:00:00:00:05", mac: "0e:00:00:00:00:05", first: t0, last: t0 + 2 * day, hostname: "kitchen-pad")
        let overlapB = rec(
            "mac:0e:00:00:00:00:06", mac: "0e:00:00:00:00:06", first: t0 + day, last: t0 + 3 * day,
            hostname: "kitchen-pad")
        var net = KnownNetwork(id: "n", subnet: "192.168.1.0/24", firstSeen: t0)
        for r in [old, new, genericA, genericB, overlapA, overlapB] { net.devices[r.key] = r }
        var h = HistoryStore(networks: [net])
        let report = h.compact(now: t0 + 3 * day)
        let devices = h.networks["n"]!.devices
        #expect(report.foldedDevices == 1)
        #expect(devices[old.key] == nil)
        #expect(devices[new.key]?.firstSeen == t0)  // keeps the older history
        #expect(devices.count == 5)
    }

    @Test func rotationFoldingRespectsConflictingLabels() {
        var a = rec(
            "mac:02:00:00:00:00:01", mac: "02:00:00:00:00:01", first: t0, last: t0 + day, hostname: "living-room-tv")
        a.customName = "TV"
        var b = rec(
            "mac:06:00:00:00:00:02", mac: "06:00:00:00:00:02", first: t0 + 2 * day, last: t0 + 3 * day,
            hostname: "living-room-tv")
        b.customName = "Other TV"
        var devices = [a.key: a, b.key: b]
        #expect(HistoryStore.foldRotatedMACs(&devices) == 0)
        #expect(devices.count == 2)
    }

    // MARK: Persistence

    @Test func encodingIsCompact() throws {
        var h = HistoryStore()
        let id = h.identifyNetwork(gatewayMAC: gwMAC, gatewayIP: gw, subnet: subnet, now: t0)
        h.record([device("192.168.1.20", mac: "aa:bb:cc:dd:ee:01")], networkID: id, now: t0, scanComplete: true)
        let data = try h.encoded()
        #expect(!data.contains(UInt8(ascii: "\n")))
        #expect(try HistoryStore.decode(data) == h)
    }

    @Test func missingFileLoadsEmptyAndMaySave() {
        let r = HistoryStore.loadResult(from: tempDir())
        #expect(r.status == .missing)
        #expect(r.canSave)
        #expect(r.store.networks.isEmpty)
    }

    @Test func unreadableFileBlocksSaving() throws {
        let dir = tempDir()
        // A directory where the file should be: reading fails with something other than ENOENT.
        try FileManager.default.createDirectory(
            at: dir.appending(path: HistoryStore.fileName),
            withIntermediateDirectories: true)
        let r = HistoryStore.loadResult(from: dir)
        guard case .unreadable = r.status else {
            Issue.record("expected .unreadable, got \(r.status)")
            return
        }
        #expect(!r.canSave)
    }

    @Test func corruptFileIsMovedAside() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: dir.appending(path: HistoryStore.fileName))
        let r = HistoryStore.loadResult(from: dir)
        guard case .corrupt(let name) = r.status else {
            Issue.record("expected .corrupt, got \(r.status)")
            return
        }
        #expect(FileManager.default.fileExists(atPath: dir.appending(path: name).path))
        #expect(!FileManager.default.fileExists(atPath: dir.appending(path: HistoryStore.fileName).path))
    }

    @Test func lossyDecodeAndNewerVersionKeepABackup() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: HistoryStore.fileName)
        // One device record lacks required fields: dropped by the tolerant decoder.
        let lossy = """
            {"version":1,"networks":[{"id":"n","subnet":"192.168.1.0/24","firstSeen":"2027-01-15T08:00:00Z",
            "devices":{"mac:a":{"key":"mac:a","lastIP":"192.168.1.2","firstSeen":"2027-01-15T08:00:00Z","lastSeen":"2027-01-15T08:00:00Z"},
            "broken":{"nope":1}}}]}
            """
        try Data(lossy.utf8).write(to: url)
        let r = HistoryStore.loadResult(from: dir)
        #expect(r.status == .partial(dropped: 1))
        #expect(r.backup == Data(lossy.utf8))
        #expect(r.store.networks["n"]?.devices.count == 1)

        let newer = #"{"version":999,"networks":[]}"#
        try Data(newer.utf8).write(to: url)
        let r2 = HistoryStore.loadResult(from: dir)
        #expect(r2.status == .newerVersion(999))
        #expect(r2.backup != nil)

        let name = try HistoryStore.writeBackup(Data(newer.utf8), to: dir, now: t0)
        let name2 = try HistoryStore.writeBackup(Data(newer.utf8), to: dir, now: t0)
        #expect(name != name2)
        #expect(try Data(contentsOf: dir.appending(path: name)) == Data(newer.utf8))
    }

    @Test func historyLockIsExclusive() {
        let dir = tempDir()
        let first = HistoryFileLock.acquire(in: dir)
        #expect(first != nil)
        #expect(HistoryFileLock.acquire(in: dir) == nil)
        _ = first
        withExtendedLifetime(first) {}
    }

    @Test func historyLockIsReleasedOnDeinit() {
        let dir = tempDir()
        do {
            let lock = HistoryFileLock.acquire(in: dir)
            #expect(lock != nil)
            withExtendedLifetime(lock) {}
        }
        #expect(HistoryFileLock.acquire(in: dir) != nil)
    }

    // MARK: Recording

    @Test func forgottenOnlineDeviceIsRecreatedAcknowledged() {
        var h = HistoryStore()
        let id = h.identifyNetwork(gatewayMAC: gwMAC, gatewayIP: gw, subnet: subnet, now: t0)
        let d = device("192.168.1.20", mac: "aa:bb:cc:dd:ee:01")
        h.record([d], networkID: id, now: t0, scanComplete: true)
        h.completeScan(networkID: id, now: t0)
        let key = KnownDevice.key(for: d)
        h.forgetDevice(key: key, networkID: id)
        let created = h.record([d], networkID: id, now: t0 + 60, acknowledging: [key])
        #expect(created.isEmpty)
        #expect(h.networks[id]?.devices[key]?.acknowledged == true)
        // Without acknowledging it would have been "new".
        h.forgetDevice(key: key, networkID: id)
        let again = h.record([d], networkID: id, now: t0 + 120)
        #expect(again == [key])
    }

    @Test func identificationWaitsForGatewayMACOnlyWhenNeeded() {
        var h = HistoryStore()
        #expect(!h.identificationNeedsGatewayMAC(gatewayIP: gw))
        _ = h.identifyNetwork(gatewayMAC: nil, gatewayIP: gw, subnet: subnet, now: t0)
        #expect(!h.identificationNeedsGatewayMAC(gatewayIP: gw))
        _ = h.identifyNetwork(gatewayMAC: gwMAC, gatewayIP: gw, subnet: subnet, now: t0)
        #expect(h.identificationNeedsGatewayMAC(gatewayIP: gw))
        #expect(!h.identificationNeedsGatewayMAC(gatewayIP: nil))
    }

    @Test func completedScanKeepsPortsOnlyAFullScanFound() {
        var h = HistoryStore()
        let id = h.identifyNetwork(gatewayMAC: gwMAC, gatewayIP: gw, subnet: subnet, now: t0)
        let mac = "aa:bb:cc:dd:ee:01"
        let rare: UInt16 = 31_337
        #expect(!CommonPorts.sortedPorts.contains(rare))
        h.record([device("192.168.1.20", mac: mac, ports: [22, 80, rare])], networkID: id, now: t0)
        // The next normal scan finds 22 only: 80 (scanned, now closed) goes, the rare one stays.
        h.record([device("192.168.1.20", mac: mac, ports: [22])], networkID: id, now: t0 + 60, scanComplete: true)
        let key = KnownDevice.key(for: device("192.168.1.20", mac: mac))
        let ports = h.networks[id]?.devices[key]?.openPorts.map(\.port)
        #expect(ports == [22, rare])
    }

    // MARK: Monitoring gaps

    @Test func lapseClosesOutageAtLastCheckAndRecordsGap() {
        var r = rec("mac:a", first: t0, last: t0)
        r.isWatched = true
        r.watchedSince = t0
        let lapse = WatchPolicy.monitoringLapse(interval: 30)
        let first = r.noteWatchCheck(at: t0, lapse: lapse)  // first check: fresh start
        #expect(first)
        let second = r.noteWatchCheck(at: t0 + 30, lapse: lapse)
        #expect(!second)
        r.outages.begin(at: t0 + 30)
        let third = r.noteWatchCheck(at: t0 + 60, lapse: lapse)
        #expect(!third)
        // App off for two days.
        let back = t0 + 2 * day
        let afterGap = r.noteWatchCheck(at: back, lapse: lapse)
        #expect(afterGap)
        #expect(r.outages.ongoing == nil)
        #expect(r.outages.last?.end == t0 + 60)
        #expect(r.unmonitored == [DateInterval(start: t0 + 60, end: back)])
        #expect(r.watchCheckedAt == back)
        // The gap counts neither as up nor down: 30 s down of the 60 s monitored.
        let up = r.uptime(last: 3 * day, now: back, lapse: lapse)!
        #expect(abs(up - (1 - 30.0 / 60.0)) < 0.01)
    }

    @Test func pauseMonitoringEndsOngoingOutageAtLastCheck() {
        var r = rec("mac:a", first: t0, last: t0)
        r.isWatched = true
        r.watchedSince = t0
        _ = r.noteWatchCheck(at: t0, lapse: 120)
        r.outages.begin(at: t0)
        _ = r.noteWatchCheck(at: t0 + 30, lapse: 120)
        r.pauseMonitoring()
        #expect(r.outages.ongoing == nil)
        #expect(r.outages.last?.end == t0 + 30)
    }

    @Test func uptimeIgnoresTimeSinceAStaleLastCheck() {
        var r = rec("mac:a", first: t0, last: t0)
        r.isWatched = true
        r.watchedSince = t0
        r.watchCheckedAt = t0 + 3600
        // Nothing checked for a day after that: only the first hour counts (all up).
        #expect(r.uptime(last: 2 * day, now: t0 + day, lapse: 120) == 1)
        r.unmonitored = [DateInterval(start: t0, end: t0 + 3600)]
        #expect(r.uptime(last: 2 * day, now: t0 + day, lapse: 120) == nil)
    }

    @Test func uptimeFractionExcludesUnmonitoredOverlap() {
        let window = DateInterval(start: t0, end: t0 + 100)
        let outages = [OutageEvent(start: t0 + 40, end: t0 + 60)]
        let gaps = [DateInterval(start: t0 + 50, end: t0 + 80)]
        // Monitored 70 s; down 10 s of it (40...50).
        let f = Uptime.fraction(outages: outages, window: window, monitoredSince: t0, now: t0 + 100, unmonitored: gaps)!
        #expect(abs(f - (1 - 10.0 / 70.0)) < 1e-9)
    }

    @Test func decodesFilesWithoutMonitoringFields() throws {
        let json =
            #"{"key":"mac:a","lastIP":"192.168.1.2","firstSeen":"2027-01-15T08:00:00Z","lastSeen":"2027-01-15T08:00:00Z"}"#
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let r = try dec.decode(KnownDevice.self, from: Data(json.utf8))
        #expect(r.watchCheckedAt == nil)
        #expect(r.unmonitored.isEmpty)
    }
}
