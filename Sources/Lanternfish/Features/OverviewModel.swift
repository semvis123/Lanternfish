import Foundation
import LanternfishKit
import Observation

/// State behind the Network Overview popover. Shared so the last speed test survives the
/// popover closing.
@MainActor
@Observable
final class OverviewModel {
    static let shared = OverviewModel()

    // Internet
    private(set) var internet: InternetInfo?
    private(set) var internetFailed = false
    private(set) var isLoadingInternet = false
    /// One entry per ICMP echo to 1.1.1.1 (nil = timeout).
    private(set) var pings: [Duration?] = []
    private(set) var isPinging = false

    // Local
    private(set) var dns = DNSConfiguration()
    private(set) var link: LinkInfo?
    private(set) var wifi: WiFiInfo?

    // Speed test
    private(set) var speedProgress: SpeedTestProgress?
    private(set) var lastSpeedResult: SpeedTestResult?
    private(set) var speedError: String?
    var isSpeedTesting: Bool { speedTask != nil }

    let location = OverviewLocationAuthorizer()

    @ObservationIgnored private var internetTask: Task<Void, Never>?
    private var speedTask: Task<Void, Never>?
    @ObservationIgnored private var lastLoad: Date?
    @ObservationIgnored private var speedRun = 0

    var latencyMs: Double? {
        let ok = pings.compactMap { $0 }.map(Latency.ms)
        return ok.isEmpty ? nil : ok.reduce(0, +) / Double(ok.count)
    }

    /// nil while unknown.
    var isOnline: Bool? {
        if internet != nil || pings.contains(where: { $0 != nil }) { return true }
        if internetFailed, !isPinging, !pings.isEmpty { return false }
        return nil
    }

    /// Loads everything. Internet info is re-fetched at most every 30 s unless `force`.
    func load(interface: NetworkInterfaceInfo?, force: Bool = false) {
        if DebugEnv.isPreview { return loadDemo() }
        refreshLocal(interface: interface)
        if !force, let lastLoad, Date().timeIntervalSince(lastLoad) < 30, internet != nil { return }
        lastLoad = Date()
        internetTask?.cancel()
        isLoadingInternet = true
        isPinging = true
        internetFailed = false
        pings = []
        internetTask = Task { [weak self] in
            async let info = try? InternetInfoService.fetch()
            async let rtts = InternetLatency.measure(count: 4)
            let (i, r) = await (info, rtts)
            guard let self, !Task.isCancelled else { return }
            self.internet = i ?? self.internet
            self.internetFailed = i == nil
            self.pings = r
            self.isLoadingInternet = false
            self.isPinging = false
        }
    }

    func refreshLocal(interface: NetworkInterfaceInfo?) {
        if DebugEnv.isPreview { return loadDemo() }
        dns = DNSConfig.current()
        guard let interface else {
            link = nil
            wifi = nil
            return
        }
        link = LinkInfoReader.read(interface.name)
        refreshWiFi(interface: interface)
    }

    func refreshWiFi(interface: NetworkInterfaceInfo?) {
        if DebugEnv.isPreview { return loadDemo() }
        guard let interface, link?.medium == .wifi else {
            wifi = nil
            return
        }
        wifi = WiFiReader.read(interface.name)
    }

    /// LANTERNFISH_PREVIEW=1: made-up values, and no network requests.
    private func loadDemo() {
        internet = OverviewDemo.internet
        pings = OverviewDemo.pings
        dns = OverviewDemo.dns
        link = OverviewDemo.link
        wifi = OverviewDemo.wifi
        lastSpeedResult = OverviewDemo.speed
    }

    // MARK: Speed test

    func startSpeedTest() {
        guard speedTask == nil, !DebugEnv.isPreview else { return }
        speedError = nil
        speedProgress = SpeedTestProgress(phase: .latency, fraction: 0)
        speedRun &+= 1
        let run = speedRun
        speedTask = Task { [weak self] in
            for await event in SpeedTest().run() {
                guard let self, self.speedRun == run else { return }
                switch event {
                case .progress(let p): self.speedProgress = p
                case .finished(let r): self.lastSpeedResult = r
                case .failed(let message): self.speedError = message
                }
            }
            guard let self, self.speedRun == run else { return }
            self.speedTask = nil
            self.speedProgress = nil
        }
    }

    func cancelSpeedTest() {
        speedTask?.cancel()
        speedTask = nil
        speedRun &+= 1
        speedProgress = nil
    }
}
