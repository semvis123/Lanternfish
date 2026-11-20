import Foundation
import Testing

@testable import LanternfishKit

@Suite struct WatchTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }

    // MARK: State machine

    @Test func firstSuccessIsUpWithoutAlert() {
        var s = WatchState()
        #expect(s.status == .unknown)
        #expect(s.observe(success: true, at: at(0)) == .firstUp)
        #expect(s.status == .up)
        #expect(s.observe(success: true, at: at(1)) == nil)
    }

    @Test func downAfterThresholdConsecutiveFailures() {
        var s = WatchState()
        _ = s.observe(success: true, at: at(0))
        #expect(s.observe(success: false, at: at(1), threshold: 3) == nil)
        #expect(s.observe(success: false, at: at(2), threshold: 3) == nil)
        #expect(s.status == .up)
        #expect(s.observe(success: false, at: at(3), threshold: 3) == .wentDown(since: at(1)))
        #expect(s.status == .down)
        #expect(s.downSince == at(1))
        // Further failures don't re-alert.
        #expect(s.observe(success: false, at: at(4), threshold: 3) == nil)
        let back = s.observe(success: true, at: at(5), threshold: 3)
        #expect(back == .cameBack(downSince: at(1), at: at(5)))
        #expect(abs((back?.outageDuration ?? 0) - 4 * 60) < 0.01)
        #expect(s.status == .up)
        #expect(s.downSince == nil)
    }

    @Test func aSuccessResetsTheFailureCount() {
        var s = WatchState()
        _ = s.observe(success: true, at: at(0))
        _ = s.observe(success: false, at: at(1), threshold: 2)
        _ = s.observe(success: true, at: at(2), threshold: 2)
        #expect(s.consecutiveFailures == 0)
        #expect(s.observe(success: false, at: at(3), threshold: 2) == nil)
        #expect(s.observe(success: false, at: at(4), threshold: 2) == .wentDown(since: at(3)))
    }

    @Test func unknownDeviceThatNeverAnswersGoesDown() {
        var s = WatchState()
        #expect(s.observe(success: false, at: at(0), threshold: 2) == nil)
        #expect(s.status == .unknown)
        #expect(s.observe(success: false, at: at(1), threshold: 2) == .wentDown(since: at(0)))
    }

    @Test func resumesOngoingOutageWithoutRealerting() {
        var s = WatchState(ongoingOutageSince: at(0))
        #expect(s.status == .down)
        #expect(s.observe(success: false, at: at(10), threshold: 1) == nil)
        #expect(s.observe(success: true, at: at(20)) == .cameBack(downSince: at(0), at: at(20)))
    }

    // MARK: Outages

    @Test func outageBeginEnd() {
        var o: [OutageEvent] = []
        o.begin(at: at(0))
        o.begin(at: at(1))  // already ongoing: ignored
        #expect(o.count == 1)
        #expect(o.ongoing?.start == at(0))
        let ended = o.end(at: at(4))
        #expect(ended?.duration(now: at(100)) == 240)
        #expect(o.ongoing == nil)
        #expect(o.end(at: at(5)) == nil)
        o.begin(at: at(10))
        #expect(o.count == 2)
    }

    @Test func outagesArePruned() {
        var o = [OutageEvent(start: t0, end: t0 + 60)]
        o.begin(at: t0 + 31 * 86_400)
        #expect(o.count == 1)
        #expect(o[0].isOngoing)
    }

    // MARK: Uptime

    @Test func uptimeFractionClipsToWindowAndMonitoring() {
        let window = DateInterval(start: at(0), end: at(100))
        let outages = [OutageEvent(start: at(-10), end: at(10)), OutageEvent(start: at(50), end: at(60))]
        #expect(
            abs((Uptime.fraction(outages: outages, window: window, monitoredSince: nil, now: at(100)) ?? 0) - 0.8)
                < 1e-6)
        // Monitoring began at 50: observed 50...100, down 10 → 80 %.
        #expect(
            abs((Uptime.fraction(outages: outages, window: window, monitoredSince: at(50), now: at(100)) ?? 0) - 0.8)
                < 1e-6)
        // Monitoring began at 60: no downtime since.
        #expect(Uptime.fraction(outages: outages, window: window, monitoredSince: at(60), now: at(100)) == 1)
        // Not monitored during the window at all.
        #expect(Uptime.fraction(outages: outages, window: window, monitoredSince: at(200), now: at(100)) == nil)
    }

    @Test func ongoingOutageCountsUntilNow() {
        let window = DateInterval(start: at(0), end: at(100))
        let outages = [OutageEvent(start: at(75))]
        #expect(
            abs((Uptime.fraction(outages: outages, window: window, monitoredSince: at(0), now: at(100)) ?? 0) - 0.75)
                < 1e-6)
    }

    @Test func overlappingOutagesCountOnce() {
        let window = DateInterval(start: at(0), end: at(100))
        let outages = [OutageEvent(start: at(10), end: at(30)), OutageEvent(start: at(20), end: at(40))]
        #expect(abs(Uptime.downtime(outages: outages, in: window, now: at(100)) - 30 * 60) < 0.01)
    }

    @Test func uptimeFormatting() {
        #expect(Uptime.format(1) == "100%")
        #expect(Uptime.format(0) == "0%")
        #expect(Uptime.format(0.9999) == "99.9%")
        #expect(Uptime.format(0.823) == "82.3%")
    }

    // MARK: History

    @Test func watchingAndUnwatching() {
        var h = HistoryStore()
        let net = h.identifyNetwork(
            gatewayMAC: nil, gatewayIP: IPv4Address("10.0.0.1"),
            subnet: Subnet(address: IPv4Address("10.0.0.5")!, prefixLength: 24), now: t0)
        var d = Device(ip: IPv4Address("10.0.0.9")!)
        d.mac = MACAddress("aa:aa:aa:aa:aa:01")
        h.record([d], networkID: net, now: t0, scanComplete: true)
        let k = KnownDevice.key(for: d)
        h.setWatched(true, key: k, networkID: net, now: at(1))
        #expect(h.watchedDevices.map(\.key) == [k])
        h.updateDevice(key: k, networkID: net) { $0.outages.begin(at: at(2)) }
        #expect(abs((h.networks[net]?.devices[k]?.uptime(last: 86_400, now: at(4)) ?? 0) - 1.0 / 3) < 1e-6)
        h.setWatched(false, key: k, networkID: net, now: at(5))
        #expect(h.watchedDevices.isEmpty)
        #expect(h.networks[net]?.devices[k]?.outages.ongoing == nil)
        // Re-watching restarts the uptime window.
        h.setWatched(true, key: k, networkID: net, now: at(10))
        #expect(h.networks[net]?.devices[k]?.uptime(last: 86_400, now: at(20)) == 1)
    }

    @Test func absorbKeepsWatchAndPresence() {
        var h = HistoryStore()
        let net = h.identifyNetwork(
            gatewayMAC: nil, gatewayIP: IPv4Address("10.0.0.1"),
            subnet: Subnet(address: IPv4Address("10.0.0.5")!, prefixLength: 24), now: t0)
        // MAC-keyed record exists; an IP-keyed duplicate made while the MAC was unknown gets folded in.
        var withMAC = Device(ip: IPv4Address("10.0.0.9")!)
        withMAC.mac = MACAddress("aa:aa:aa:aa:aa:01")
        h.record([withMAC], networkID: net, now: t0, scanComplete: true, presenceGap: 600)
        let noMAC = Device(ip: IPv4Address("10.0.0.9")!)
        h.networks[net]?.devices[KnownDevice.ipKey(noMAC.ip)] = {
            var r = KnownDevice(
                key: KnownDevice.ipKey(noMAC.ip), lastIP: "10.0.0.9", firstSeen: at(-100), lastSeen: at(-50))
            r.isWatched = true
            r.watchedSince = at(-100)
            r.presence = [PresenceInterval(start: at(-100), end: at(-50))]
            return r
        }()
        h.record([withMAC], networkID: net, now: at(1), presenceGap: 600)
        let rec = h.networks[net]?.devices[KnownDevice.key(for: withMAC)]
        #expect(rec?.isWatched == true)
        #expect(rec?.watchedSince == at(-100))
        #expect(rec?.presence.count == 2)
        #expect(h.networks[net]?.devices[KnownDevice.ipKey(noMAC.ip)] == nil)
    }
}
