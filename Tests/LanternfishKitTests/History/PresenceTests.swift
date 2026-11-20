import Foundation
import Testing

@testable import LanternfishKit

@Suite struct PresenceTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let gap: TimeInterval = 30 * 60

    func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }

    // MARK: Recording

    @Test func sightingsWithinGapExtendOneInterval() {
        var p: [PresenceInterval] = []
        p.recordSighting(at: at(0), gap: gap)
        p.recordSighting(at: at(1), gap: gap)
        p.recordSighting(at: at(16), gap: gap)
        p.recordSighting(at: at(45), gap: gap)
        #expect(p.count == 1)
        #expect(p[0].start == at(0))
        #expect(p[0].end == at(45))
        #expect(p[0].isOpen)
    }

    @Test func sightingAfterGapStartsNewIntervalAndClosesOld() {
        var p: [PresenceInterval] = []
        p.recordSighting(at: at(0), gap: gap)
        p.recordSighting(at: at(10), gap: gap)
        p.recordSighting(at: at(41), gap: gap)
        #expect(p.count == 2)
        #expect(!p[0].isOpen)
        #expect(p[0].end == at(10))
        #expect(p[1].start == at(41))
        #expect(p[1].isOpen)
    }

    @Test func closedIntervalStartsNewOneUnlessGapIsSmall() {
        var p: [PresenceInterval] = []
        p.recordSighting(at: at(0), gap: gap)
        p.recordSighting(at: at(5), gap: gap)
        p.closePresence()
        #expect(!p[0].isOpen)
        // Back within the merge gap (2 min): reopened, no new session.
        p.recordSighting(at: at(6), gap: gap)
        #expect(p.count == 1)
        #expect(p[0].isOpen)
        #expect(p[0].end == at(6))
        p.closePresence()
        // Back after 10 min (within `gap` but the interval was closed): new session.
        p.recordSighting(at: at(16), gap: gap)
        #expect(p.count == 2)
        #expect(p[1].start == at(16))
    }

    @Test func detectedOutageNeverReopens() {
        var p: [PresenceInterval] = []
        p.recordSighting(at: at(0), gap: gap)
        p.closePresence()
        p.recordSighting(at: at(1), gap: gap, reopenWithin: 0)
        #expect(p.count == 2)
    }

    @Test func outOfOrderSightingIsIgnored() {
        var p: [PresenceInterval] = []
        p.recordSighting(at: at(10), gap: gap)
        p.recordSighting(at: at(20), gap: gap)
        p.recordSighting(at: at(15), gap: gap)
        p.recordSighting(at: at(1), gap: gap)
        #expect(p == [PresenceInterval(start: at(10), end: at(20), isOpen: true)])
    }

    @Test func pruneDropsOldIntervalsAndCapsCount() {
        let day: TimeInterval = 86_400
        var p = [
            PresenceInterval(start: t0, end: t0 + 60),
            PresenceInterval(start: t0 + 40 * day, end: t0 + 40 * day + 60),
        ]
        p.prune(now: t0 + 45 * day)
        #expect(p.count == 1)
        var many = (0..<50).map { PresenceInterval(start: at(Double($0) * 10), end: at(Double($0) * 10 + 1)) }
        many.prune(now: at(500), maxCount: 20)
        #expect(many.count == 20)
        #expect(many.first?.start == at(300))
    }

    @Test func recordingPrunesBeyondRetention() {
        var p = [PresenceInterval(start: t0, end: t0 + 60)]
        p.recordSighting(at: t0 + 31 * 86_400, gap: gap)
        #expect(p.count == 1)
        #expect(p[0].start == t0 + 31 * 86_400)
    }

    @Test func normalizedMergesOverlapsAndSmallGaps() {
        let p = [
            PresenceInterval(start: at(30), end: at(40), isOpen: true),
            PresenceInterval(start: at(0), end: at(10), isOpen: true),
            PresenceInterval(start: at(5), end: at(12)),
            PresenceInterval(start: at(13), end: at(20)),  // 1 min after: merged
        ]
        let n = p.normalized()
        #expect(n.count == 2)
        #expect(n[0] == PresenceInterval(start: at(0), end: at(20)))
        #expect(n[1] == PresenceInterval(start: at(30), end: at(40), isOpen: true))
    }

    // MARK: Queries

    @Test func openRecentIntervalLastsUntilNow() {
        let p = [PresenceInterval(start: at(0), end: at(10), isOpen: true)]
        #expect(p.effective(now: at(20), gap: gap) == [DateInterval(start: at(0), end: at(20))])
        #expect(p.isPresent(now: at(20), gap: gap))
        // Stale (last sighting longer ago than the gap): ends at the last sighting.
        #expect(p.effective(now: at(60), gap: gap) == [DateInterval(start: at(0), end: at(10))])
        #expect(!p.isPresent(now: at(60), gap: gap))
        // Closed: never extended.
        let closed = [PresenceInterval(start: at(0), end: at(10))]
        #expect(closed.effective(now: at(20), gap: gap) == [DateInterval(start: at(0), end: at(10))])
    }

    @Test func segmentsAreClippedToTheWindow() {
        let p = [PresenceInterval(start: at(-30), end: at(30)), PresenceInterval(start: at(100), end: at(200))]
        let window = DateInterval(start: at(0), end: at(150))
        #expect(
            p.segments(in: window, now: at(300), gap: gap) == [
                DateInterval(start: at(0), end: at(30)), DateInterval(start: at(100), end: at(150)),
            ])
    }

    @Test func statsOverWindow() {
        // Tracking started at 0; window 0...100 min, now = 100.
        let p = [
            PresenceInterval(start: at(0), end: at(20)),
            PresenceInterval(start: at(50), end: at(60)),
            PresenceInterval(start: at(80), end: at(95), isOpen: true),
        ]
        let s = p.stats(in: DateInterval(start: at(-1000), end: at(100)), now: at(100), gap: gap)
        #expect(s.observed == DateInterval(start: at(0), end: at(100)))
        #expect(abs(s.online - 50 * 60) < 0.01)  // 20 + 10 + (80→now 100) 20
        #expect(s.sessions == 3)
        #expect(abs((s.longestOffline ?? 0) - 30 * 60) < 0.01)
        #expect(abs((s.onlineFraction ?? 0) - 0.5) < 1e-6)
    }

    @Test func statsCountTrailingOfflineTime() {
        let p = [PresenceInterval(start: at(0), end: at(10))]
        let s = p.stats(in: DateInterval(start: at(0), end: at(100)), now: at(100), gap: gap)
        #expect(abs((s.longestOffline ?? 0) - 90 * 60) < 0.01)
        #expect(abs((s.onlineFraction ?? 0) - 0.1) < 1e-6)
    }

    @Test func statsWithoutDataHaveNoFraction() {
        let s = [PresenceInterval]().stats(in: DateInterval(start: at(0), end: at(100)), now: at(100), gap: gap)
        #expect(s.onlineFraction == nil)
        #expect(s.sessions == 0)
        #expect(s.longestOffline == nil)
    }

    @Test func gapPolicy() {
        #expect(PresencePolicy.gap(autoScanInterval: nil) == 600)
        #expect(PresencePolicy.gap(autoScanInterval: 60) == 600)
        #expect(PresencePolicy.gap(autoScanInterval: 15 * 60) == 30 * 60)
    }

    @Test func daysEndWithToday() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Amsterdam")!
        let days = PresenceCalendar.days(count: 7, now: t0, calendar: cal)
        #expect(days.count == 7)
        #expect(days.last!.contains(t0))
        #expect(days.last!.start == cal.startOfDay(for: t0))
        for (a, b) in zip(days, days.dropFirst()) { #expect(a.end == b.start) }
    }

    // MARK: History integration

    func device(_ ip: String, mac: String) -> Device {
        var d = Device(ip: IPv4Address(ip)!)
        d.mac = MACAddress(mac)
        return d
    }

    func store() -> (HistoryStore, String) {
        var h = HistoryStore()
        let subnet = Subnet(address: IPv4Address("192.168.1.12")!, prefixLength: 24)
        let id = h.identifyNetwork(
            gatewayMAC: MACAddress("00:00:5e:00:53:01"), gatewayIP: IPv4Address("192.168.1.1"),
            subnet: subnet, now: t0)
        return (h, id)
    }

    @Test func recordAddsPresenceOnlyWithGapAndClosesMissingDevicesOnCompletion() {
        var (h, net) = store()
        let a = device("192.168.1.10", mac: "aa:aa:aa:aa:aa:01")
        let b = device("192.168.1.11", mac: "aa:aa:aa:aa:aa:02")
        h.record([a, b], networkID: net, now: at(0), presenceGap: gap)
        h.record([a, b], networkID: net, now: at(1), scanComplete: true, presenceGap: gap)
        // Without a gap (not a sighting, e.g. a port scan result after the scan): no presence change.
        h.record([a, b], networkID: net, now: at(5))
        let ka = KnownDevice.key(for: a)
        let kb = KnownDevice.key(for: b)
        #expect(h.networks[net]?.devices[ka]?.presence == [PresenceInterval(start: at(0), end: at(1), isOpen: true)])
        // Next scan only finds `a`: `b` is closed.
        h.record([a], networkID: net, now: at(15), scanComplete: true, presenceGap: gap)
        #expect(h.networks[net]?.devices[ka]?.presence.last?.end == at(15))
        #expect(h.networks[net]?.devices[ka]?.presence.last?.isOpen == true)
        #expect(h.networks[net]?.devices[kb]?.presence.last?.isOpen == false)
        #expect(h.networks[net]?.devices[kb]?.presence.last?.end == at(1))
        // `b` returns: a new session.
        h.record([a, b], networkID: net, now: at(30), presenceGap: gap)
        #expect(h.networks[net]?.devices[kb]?.presence.count == 2)
    }

    @Test func notePresenceAndClose() {
        var (h, net) = store()
        let a = device("192.168.1.10", mac: "aa:aa:aa:aa:aa:01")
        h.record([a], networkID: net, now: at(0), scanComplete: true, presenceGap: gap)
        let k = KnownDevice.key(for: a)
        h.notePresence(key: k, networkID: net, at: at(3), gap: gap)
        #expect(h.networks[net]?.devices[k]?.lastSeen == at(3))
        #expect(h.networks[net]?.devices[k]?.presence.count == 1)
        h.closePresence(key: k, networkID: net)
        #expect(h.networks[net]?.devices[k]?.presence.last?.isOpen == false)
    }

    @Test func ipKeyedRecordMigratingToMACKeepsPresence() {
        var (h, net) = store()
        var noMAC = Device(ip: IPv4Address("192.168.1.20")!)
        h.record([noMAC], networkID: net, now: at(0), scanComplete: true, presenceGap: gap)
        noMAC.mac = MACAddress("aa:aa:aa:aa:aa:09")
        h.record([noMAC], networkID: net, now: at(10), presenceGap: gap)
        let rec = h.networks[net]?.devices[KnownDevice.key(for: noMAC)]
        #expect(rec?.presence.count == 1)
        #expect(rec?.presence.first?.start == at(0))
        #expect(rec?.presence.first?.end == at(10))
    }

    // MARK: Persistence

    @Test func presenceAndWatchFieldsRoundTrip() throws {
        var (h, net) = store()
        let a = device("192.168.1.10", mac: "aa:aa:aa:aa:aa:01")
        h.record([a], networkID: net, now: at(0), scanComplete: true, presenceGap: gap)
        let k = KnownDevice.key(for: a)
        h.setWatched(true, key: k, networkID: net, now: at(1))
        h.updateDevice(key: k, networkID: net) { $0.outages.begin(at: at(2)) }
        let back = try HistoryStore.decode(try h.encoded())
        let rec = back.networks[net]?.devices[k]
        #expect(rec?.isWatched == true)
        #expect(rec?.watchedSince == at(1))
        #expect(rec?.outages == [OutageEvent(start: at(2))])
        #expect(rec?.presence == [PresenceInterval(start: at(0), end: at(0), isOpen: true)])
    }

    @Test func oldFilesWithoutNewFieldsDecode() throws {
        let json = """
            {"version":1,"networks":[{"id":"n","subnet":"10.0.0.0/24","devices":{
              "mac:AA:AA:AA:AA:AA:01":{"key":"mac:AA:AA:AA:AA:AA:01","lastIP":"10.0.0.5"}}}]}
            """
        let h = try HistoryStore.decode(Data(json.utf8))
        let rec = h.networks["n"]?.devices["mac:AA:AA:AA:AA:AA:01"]
        #expect(rec?.presence == [])
        #expect(rec?.isWatched == false)
        #expect(rec?.outages == [])
    }

    @Test func badPresenceEntriesAreDroppedNotTheDevice() throws {
        let json = """
            {"version":1,"networks":[{"id":"n","subnet":"10.0.0.0/24","devices":{
              "mac:AA:AA:AA:AA:AA:01":{"key":"mac:AA:AA:AA:AA:AA:01","lastIP":"10.0.0.5",
                "presence":[{"start":"2027-01-15T08:00:00Z","end":"2027-01-15T09:00:00Z"},{"start":42},{"bogus":true}],
                "isWatched":"yes","outages":[{"start":"2027-01-15T10:00:00Z"},{"end":"x"}]}}}]}
            """
        let h = try HistoryStore.decode(Data(json.utf8))
        let rec = try #require(h.networks["n"]?.devices["mac:AA:AA:AA:AA:AA:01"])
        #expect(rec.presence.count == 1)
        #expect(rec.presence[0].duration == 3600)
        #expect(rec.isWatched == false)
        #expect(rec.outages.count == 1)
        #expect(rec.outages[0].isOngoing)
    }
}
