import Foundation
import LanternfishKit
import Observation

/// Continuously checks watched devices on every connected network, independent of full scans.
///
/// Every `AppSettings.watchInterval` seconds each watched device of each store's live network is
/// probed in parallel (one ICMP echo, then TCP connects to its known open ports for devices that
/// drop ICMP). `WatchState` turns results into up/down transitions; outages are recorded in history
/// (`KnownDevice.outages`), successful checks count as presence sightings, and transitions post
/// notifications. Recent samples stay in memory for the inspector's sparkline.
///
/// Monitoring gaps (app not running, Mac asleep, network disconnected) are recorded per device
/// (`KnownDevice.noteWatchCheck`): an outage open at the time ends at the last failed check, the
/// gap counts neither as up nor down, and the first check after it starts from a fresh state (no
/// "back online after 2 d"). A device whose address another device now holds counts as down
/// without being probed; a probe answered by another MAC (ARP) counts as failed.
///
/// Debug aids:
///   LANTERNFISH_WATCH_SECONDS=<n>            check interval override.
///   LANTERNFISH_WATCH_IPS=<ip>[,<ip>…]       watch these devices once a scan lists them.
///   LANTERNFISH_WATCH_FAKE_DOWN=<ip>[,<ip>…] treat checks of these IPs as failed…
///   LANTERNFISH_WATCH_FAKE_DOWN_WINDOW=<from>-<to>  …only between these seconds after launch.
@MainActor
@Observable
final class WatchMonitor {
    struct Target: Hashable, Sendable {
        let networkID: String
        let key: String
    }

    struct Sample: Hashable, Sendable {
        let date: Date
        /// nil: no answer.
        let rtt: Duration?
        /// Answered over TCP (the device drops ICMP).
        let viaTCP: Bool
    }

    /// Live monitoring state of one watched device.
    struct Live {
        var state: WatchState
        var ip: IPv4Address
        var interfaceID: String?
        /// Most recent checks, oldest first (at most `WatchMonitor.sampleCapacity`).
        var samples: [Sample] = []

        var lastRTT: Duration? { samples.last?.rtt }
        var answersOnlyTCP: Bool { samples.last?.viaTCP == true }
    }

    static let sampleCapacity = 60

    /// Keyed by watched device. Only devices on currently connected networks have an entry.
    private(set) var live: [Target: Live] = [:]
    /// True while a round of checks is running.
    private(set) var isChecking = false

    @ObservationIgnored private let hub: NetworkHub
    @ObservationIgnored private let notifier: NewDeviceNotifier
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var sleeper: Task<Void, Never>?
    @ObservationIgnored private let launchedAt = Date()
    @ObservationIgnored private var autoWatchIPs: Set<IPv4Address>
    @ObservationIgnored private let fakeDown: Set<IPv4Address>
    @ObservationIgnored private let fakeDownWindow: ClosedRange<TimeInterval>?

    private var history: SharedHistory { hub.history }

    init(hub: NetworkHub, notifier: NewDeviceNotifier) {
        self.hub = hub
        self.notifier = notifier
        let env = DebugEnv.values
        func ips(_ name: String) -> Set<IPv4Address> {
            Set(
                (env[name] ?? "").split(separator: ",").compactMap {
                    IPv4Address(String($0).trimmingCharacters(in: .whitespaces))
                })
        }
        autoWatchIPs = ips("LANTERNFISH_WATCH_IPS")
        fakeDown = ips("LANTERNFISH_WATCH_FAKE_DOWN")
        let window = (env["LANTERNFISH_WATCH_FAKE_DOWN_WINDOW"] ?? "").split(separator: "-").compactMap { Double($0) }
        fakeDownWindow = window.count == 2 && window[0] <= window[1] ? window[0]...window[1] : nil
    }

    // MARK: Lifecycle

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            // Let the first scans identify the networks.
            try? await Task.sleep(for: .seconds(3))
            while !Task.isCancelled {
                guard let self else { return }
                await self.runRound()
                let wait = Task<Void, Never> { try? await Task.sleep(for: .seconds(AppSettings.watchInterval)) }
                self.sleeper = wait
                await wait.value
            }
        }
    }

    /// Stops checking (e.g. on quit): open outages end at their last failed check.
    func stop() {
        loop?.cancel()
        loop = nil
        sleeper?.cancel()
        guard !live.isEmpty else { return }
        for t in live.keys { pause(t) }
        live = [:]
        history.changed(.background)
    }

    /// Monitoring of `t` stops for now (its network went away, the app quits).
    private func pause(_ t: Target) {
        history.data.updateDevice(key: t.key, networkID: t.networkID) { $0.pauseMonitoring() }
    }

    /// Runs the next round now (e.g. right after a device was watched).
    func checkSoon() {
        sleeper?.cancel()
    }

    // MARK: Watching

    /// The network a store's device belongs to (the browsed one, else the live one).
    private func networkID(of store: ScanStore) -> String? {
        store.displayedNetwork?.id
    }

    func record(for device: Device, in store: ScanStore) -> KnownDevice? {
        guard let key = device.historyKey else { return nil }
        return store.displayedNetwork?.devices[key]
    }

    func isWatched(_ device: Device, in store: ScanStore) -> Bool {
        record(for: device, in: store)?.isWatched == true
    }

    func live(for device: Device, in store: ScanStore) -> Live? {
        guard let net = networkID(of: store), let key = device.historyKey else { return nil }
        return live[Target(networkID: net, key: key)]
    }

    func setWatched(_ on: Bool, device: Device, store: ScanStore) {
        guard let net = networkID(of: store),
            let key = history.data.ensureRecord(for: device, networkID: net)
        else { return }
        history.data.setWatched(on, key: key, networkID: net)
        if !on { live[Target(networkID: net, key: key)] = nil }
        history.edited(by: self)
        alertsLog("%@ watching %@ (%@)", on ? "started" : "stopped", device.listName, device.ip.description)
        if on {
            if AppSettings.notifyWatchDown || AppSettings.notifyWatchUp {
                Task { await notifier.ensureAuthorized(userInitiated: true) }
            }
            checkSoon()
        }
    }

    // MARK: Menu bar

    /// A watched device on a connected network, for the menu bar.
    struct Entry: Identifiable {
        let target: Target
        let device: Device
        let store: ScanStore
        let status: WatchStatus
        let rtt: Duration?
        let uptime24h: Double?
        var id: Target { target }
    }

    /// Watched devices of every connected network, down ones first, then by name.
    var entries: [Entry] {
        let now = Date()
        var out: [Entry] = []
        for store in hub.stores {
            guard let net = store.currentNetwork else { continue }
            let byKey = Dictionary(
                store.liveDevices.compactMap { d in d.historyKey.map { ($0, d) } },
                uniquingKeysWith: { a, _ in a })
            for rec in net.devices.values where rec.isWatched {
                let target = Target(networkID: net.id, key: rec.key)
                let l = live[target]
                let device = byKey[rec.key] ?? rec.offlineDevice()
                out.append(
                    Entry(
                        target: target, device: device, store: store, status: l?.state.status ?? .unknown,
                        rtt: l?.lastRTT, uptime24h: rec.uptime(last: 86_400, now: now)))
            }
        }
        func rank(_ s: WatchStatus) -> Int { s == .down ? 0 : s == .up ? 1 : 2 }
        return out.sorted {
            rank($0.status) != rank($1.status)
                ? rank($0.status) < rank($1.status)
                : $0.device.listName.localizedStandardCompare($1.device.listName) == .orderedAscending
        }
    }

    // MARK: Checking

    private struct Job: Sendable {
        let target: Target
        let ip: IPv4Address
        let ports: [UInt16]
        let interfaceID: String?
        /// The record's MAC: a probe answered from another MAC (ARP) reached someone else.
        let expectedMAC: MACAddress?
        /// Fail without probing: debug fake, or another device holds the device's last address.
        let fail: Bool
    }

    private func runRound() async {
        applyAutoWatch()
        let jobs = currentJobs()
        // Forget devices no longer watched or whose network went away.
        let active = Set(jobs.map(\.target))
        let gone = live.keys.filter { !active.contains($0) }
        if !gone.isEmpty {
            for t in gone { pause(t) }
            live = live.filter { active.contains($0.key) }
            history.changed(.background)
        }
        guard !jobs.isEmpty else { return }
        isChecking = true
        let results = await withTaskGroup(of: (Job, Sample).self) { group in
            for job in jobs {
                group.addTask {
                    (
                        job,
                        job.fail
                            ? Sample(date: Date(), rtt: nil, viaTCP: false)
                            : await Self.probe(job.ip, ports: job.ports)
                    )
                }
            }
            var out: [(Job, Sample)] = []
            for await r in group { out.append(r) }
            return out
        }
        // An answer from another MAC means the address now belongs to someone else.
        let verify = results.contains { $0.1.rtt != nil && $0.0.expectedMAC != nil }
        let arp = verify ? await ARPTableMACProvider().macAddresses() : [:]
        isChecking = false
        for (job, sample) in results {
            if sample.rtt != nil, let want = job.expectedMAC, let got = arp[job.ip], got != want {
                alertsLog(
                    "watch: %@ answered from %@, not %@; counting as failed", job.ip.description,
                    got.description, want.description)
                apply(Sample(date: sample.date, rtt: nil, viaTCP: false), to: job)
            } else {
                apply(sample, to: job)
            }
        }
        history.changed(.background)
    }

    /// Watched devices of every store's live network, with the address to probe.
    private func currentJobs() -> [Job] {
        let elapsed = Date().timeIntervalSince(launchedAt)
        let faking = fakeDownWindow.map { $0.contains(elapsed) } ?? true
        var jobs: [Job] = []
        var seen: Set<Target> = []
        for store in hub.stores where store.interface != nil {
            guard let net = store.currentNetwork else { continue }
            // The live network's devices, also while the window browses a saved network.
            let liveDevices = store.liveDevices
            let liveIPs = Dictionary(
                liveDevices.compactMap { d in d.historyKey.map { ($0, d.ip) } },
                uniquingKeysWith: { a, _ in a })
            let holders = Dictionary(
                liveDevices.compactMap { d in d.historyKey.map { (d.ip, $0) } },
                uniquingKeysWith: { a, _ in a })
            for rec in net.devices.values where rec.isWatched {
                let target = Target(networkID: net.id, key: rec.key)
                guard !seen.contains(target) else { continue }
                var taken = false
                let ip: IPv4Address
                if let liveIP = liveIPs[rec.key] {
                    ip = liveIP
                } else if let last = IPv4Address(rec.lastIP) {
                    ip = last
                    // Another device answers at the last address now: this one isn't there.
                    if let holder = holders[last], holder != rec.key { taken = true }
                } else {
                    continue
                }
                seen.insert(target)
                jobs.append(
                    Job(
                        target: target, ip: ip, ports: rec.openPorts.map(\.port),
                        interfaceID: store.interfaceID, expectedMAC: rec.mac.flatMap(MACAddress.init),
                        fail: taken || (faking && fakeDown.contains(ip))))
            }
        }
        return jobs
    }

    private func apply(_ sample: Sample, to job: Job) {
        let t = job.target
        guard history.data.networks[t.networkID]?.devices[t.key]?.isWatched == true else { return }
        // A lapse in monitoring (app off, asleep, disconnected) closes an open outage at the last
        // check and records the gap; evaluation then starts afresh.
        var lapsed = false
        let lapse = WatchPolicy.monitoringLapse(interval: AppSettings.watchInterval)
        history.data.updateDevice(key: t.key, networkID: t.networkID) {
            lapsed = $0.noteWatchCheck(at: sample.date, lapse: lapse)
        }
        guard let rec = history.data.networks[t.networkID]?.devices[t.key] else { return }
        var entry =
            live[t]
            ?? Live(
                state: WatchState(ongoingOutageSince: lapsed ? nil : rec.outages.ongoing?.start),
                ip: job.ip)
        if lapsed, live[t] != nil {
            alertsLog(
                "watch: %@ not monitored since %@; starting afresh", rec.displayLabel,
                rec.unmonitored.last?.start.description ?? "-")
            entry.state = WatchState()
        }
        entry.ip = job.ip
        entry.interfaceID = job.interfaceID
        entry.samples.append(sample)
        if entry.samples.count > Self.sampleCapacity {
            entry.samples.removeFirst(entry.samples.count - Self.sampleCapacity)
        }
        let success = sample.rtt != nil
        let transition = entry.state.observe(success: success, at: sample.date, threshold: AppSettings.watchFailures)
        live[t] = entry

        if success {
            // Back after a detected outage: a new presence session even if the outage was short.
            let backFromOutage = if case .cameBack? = transition { true } else { false }
            history.data.notePresence(
                key: t.key, networkID: t.networkID, at: sample.date, gap: AppSettings.presenceGap,
                reopenWithin: backFromOutage ? 0 : PresencePolicy.mergeGap)
        }
        switch transition {
        case .wentDown(let since)?:
            history.data.updateDevice(key: t.key, networkID: t.networkID) { rec in
                rec.outages.begin(at: since, now: sample.date)
                rec.presence.closePresence()
            }
            alertsLog("watch: %@ (%@) is down since %@", rec.displayLabel, job.ip.description, since.description)
            history.changed(.soon)
            notify(.wentDown(since: since), record: rec, job: job)
        case .cameBack(let since, let at)?:
            history.data.updateDevice(key: t.key, networkID: t.networkID) { $0.outages.end(at: at) }
            alertsLog(
                "watch: %@ (%@) is back after %.0f s", rec.displayLabel, job.ip.description, at.timeIntervalSince(since)
            )
            history.changed(.soon)
            notify(.cameBack(downSince: since, at: at), record: rec, job: job)
        case .firstUp?, nil:
            break
        }
    }

    private func notify(_ transition: WatchTransition, record rec: KnownDevice, job: Job) {
        let network = history.data.networks[job.target.networkID]
        let store = hub.store(forNetworkID: job.target.networkID)
        let device = store?.devices.first { $0.historyKey == rec.key } ?? rec.offlineDevice()
        notifier.notifyWatch(transition, device: device, ip: job.ip, network: network, interfaceID: job.interfaceID)
    }

    /// LANTERNFISH_WATCH_IPS: watch those devices once a store lists them.
    private func applyAutoWatch() {
        guard !autoWatchIPs.isEmpty else { return }
        for store in hub.stores where store.currentNetworkID != nil {
            for d in store.devices where d.isOnline && autoWatchIPs.contains(d.ip) {
                autoWatchIPs.remove(d.ip)
                if !isWatched(d, in: store) { setWatched(true, device: d, store: store) }
            }
        }
    }

    // MARK: Probing

    nonisolated private static let probeTimeout: Duration = .milliseconds(1500)
    /// TCP ports tried for a device with no known open ports (62078: iPhone sync).
    nonisolated private static let fallbackProbePorts: [UInt16] = [80, 443, 22, 445, 62078, 8080]
    nonisolated private static let maxProbePorts = 4

    /// One check: an ICMP echo, else TCP connects to up to `maxProbePorts` known open ports (or a
    /// few common ones). An accepted or refused connection both prove the device is there.
    nonisolated private static func probe(_ ip: IPv4Address, ports: [UInt16]) async -> Sample {
        let date = Date()
        for await result in Pinger(interval: .seconds(1), timeout: probeTimeout).ping(ip) {
            if let rtt = result.rtt { return Sample(date: date, rtt: rtt, viaTCP: false) }
            break
        }
        let candidates = ports.isEmpty ? fallbackProbePorts : Array(ports.prefix(maxProbePorts))
        let clock = ContinuousClock()
        let start = clock.now
        let rtt: Duration? = await withTaskGroup(of: Duration?.self) { group in
            for port in candidates {
                group.addTask {
                    let r = await TCPProbe.probe(ip, port: port, timeout: probeTimeout)
                    return r == .timeout ? nil : clock.now - start
                }
            }
            for await r in group {
                if let r {
                    group.cancelAll()
                    return r
                }
            }
            return nil
        }
        return Sample(date: date, rtt: rtt, viaTCP: rtt != nil)
    }
}

extension KnownDevice {
    /// A name for logs and fallbacks.
    var displayLabel: String { customName ?? name ?? hostname ?? lastIP }
}

/// Short durations for monitoring UI and alerts: "45 s", "4 min", "1 h 5 min", "2 d 3 h".
enum WatchFormat {
    static func duration(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded()))
        switch s {
        case ..<60: return "\(s) s"
        case ..<3600: return "\(max(1, Int((Double(s) / 60).rounded()))) min"
        case ..<86_400:
            let m = (s % 3600) / 60
            return m == 0 ? "\(s / 3600) h" : "\(s / 3600) h \(m) min"
        default:
            let h = (s % 86_400) / 3600
            return h == 0 ? "\(s / 86_400) d" : "\(s / 86_400) d \(h) h"
        }
    }
}
