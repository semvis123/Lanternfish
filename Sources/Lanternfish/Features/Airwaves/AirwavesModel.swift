import Foundation
import LanternfishKit
import Observation

/// State behind the Airwaves window: periodic CoreWLAN scans (only while the window is
/// open and visible), the current connection, and a 5-minute RSSI history per network.
@MainActor
@Observable
final class AirwavesModel {
    /// Shared so the signal history survives closing and reopening the window.
    static let shared = AirwavesModel()

    enum Status: Equatable {
        case idle, ok, wifiOff, noInterface
    }

    /// Seconds between the end of one scan and the start of the next. A scan takes the radio
    /// off-channel for a moment, so don't go faster.
    static let interval: TimeInterval = 10
    /// How far back the signal history goes, in seconds.
    static let historyWindow: TimeInterval = 300

    private(set) var results: [WiFiScanResult] = []
    private(set) var connection: WiFiInfo?
    private(set) var currentID: String?
    private(set) var history = WiFiSignalHistory(window: AirwavesModel.historyWindow)
    private(set) var lastScan: Date?
    private(set) var lastError: String?
    private(set) var isScanning = false
    private(set) var status: Status = .idle
    var isPaused = false {
        didSet { if !isPaused { wake() } }
    }
    /// Debug: LANTERNFISH_WIFI_DEMO=1 shows made-up networks (for screenshots without Location access).
    let isDemo = DebugEnv.values["LANTERNFISH_WIFI_DEMO"] == "1"

    let location = OverviewModel.shared.location

    /// The scan loop's current wait (see `sleep(_:)`).
    @ObservationIgnored private var sleepTimer: Task<Void, Never>?
    /// Running `run(visible:)` loops (0 while the window is closed).
    @ObservationIgnored private var loops = 0
    /// `rescan()` asked the loop to scan once regardless of pause / visibility.
    @ObservationIgnored private var scanRequested = false
    @ObservationIgnored private var scanCount = 0

    var namesRedacted: Bool {
        if isDemo { return false }
        return location.state != .authorized || (!results.isEmpty && results.allSatisfy(\.isNameRedacted))
    }

    func results(in band: WiFiBand) -> [WiFiScanResult] { results.filter { $0.band == band } }

    func count(in band: WiFiBand) -> Int { results.reduce(0) { $0 + ($1.band == band ? 1 : 0) } }

    func advice(for band: WiFiBand) -> ChannelAdvice {
        ChannelAdvisor.advise(band: band, networks: results, currentID: ownID(in: band), connection: connection)
    }

    /// Your access point on `band`: the connected BSS, or (connected on another band) the
    /// strongest BSS broadcasting your network name there — usually the same router's other radio.
    func ownID(in band: WiFiBand) -> String? {
        if let cur = current, cur.band == band { return cur.id }
        guard let ssid = current?.ssid ?? connection?.ssid else { return nil }
        return results.filter { $0.band == band && $0.ssid == ssid }.max { $0.rssi < $1.rssi }?.id
    }

    /// The current network's scan result.
    var current: WiFiScanResult? { currentID.flatMap { id in results.first { $0.id == id } } }

    // MARK: Loop

    /// Runs until cancelled (the window's `.task`): scans every `interval` unless paused or hidden.
    func run(visible: @escaping @MainActor () -> Bool) async {
        loops += 1
        defer { loops -= 1 }
        while !Task.isCancelled {
            if scanRequested || (!isPaused && visible()) {
                scanRequested = false
                await scanOnce()
            }
            await sleep(.seconds(Self.interval))
        }
    }

    /// Fast refresh of the connection (no scan) so the "Your connection" card stays live; skipped
    /// while the window is hidden (minimized or covered).
    func runConnectionRefresh(visible: @escaping @MainActor () -> Bool) async {
        while !Task.isCancelled {
            if !isDemo, visible() { refreshConnection() }
            try? await Task.sleep(for: .seconds(3))
        }
    }

    /// Manual rescan: ends the loop's current wait so it scans now (even while paused), and the
    /// next automatic scan comes a full interval later. Scans directly when no loop is running.
    func rescan() {
        guard !isScanning else { return }
        if loops > 0 {
            scanRequested = true
            wake()
        } else {
            Task { await scanOnce() }
        }
    }

    /// Sleeps for `d`, or until `wake()` / cancellation. The wait is a plain cancellable task, so
    /// there's no continuation to leak or leave hanging when the window closes and reopens.
    private func sleep(_ d: Duration) async {
        let timer = Task<Void, Never> { try? await Task.sleep(for: d) }
        sleepTimer = timer
        await withTaskCancellationHandler {
            await timer.value
        } onCancel: {
            timer.cancel()
        }
        if sleepTimer == timer { sleepTimer = nil }
    }

    /// Ends the current wait (resume, manual rescan).
    private func wake() {
        sleepTimer?.cancel()
    }

    func scanOnce() async {
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }
        if isDemo {
            scanCount += 1
            apply(AirwavesDemo.results(tick: scanCount), connection: AirwavesDemo.connection(tick: scanCount))
            return
        }
        let iface = connection?.interfaceName
        let outcome: Result<[WiFiScanResult], WiFiScanError> = await Task.detached(priority: .utility) {
            do throws(WiFiScanError) {
                return .success(try await WiFiScanner.scan(interfaceName: iface))
            } catch {
                return .failure(error)
            }
        }.value
        refreshConnection()
        switch outcome {
        case .success(let list):
            apply(list, connection: connection)
        case .failure(.poweredOff):
            status = .wifiOff
            lastError = nil
        case .failure(.noInterface):
            status = .noInterface
            lastError = nil
        case .failure(let e):
            // Busy / throttled: keep showing the last good data.
            lastError = e.localizedDescription
            if status == .idle { status = .ok }
        }
    }

    private func apply(_ list: [WiFiScanResult], connection c: WiFiInfo?) {
        let now = Date()
        connection = c
        results = list
        currentID = WiFiScanResult.currentID(in: list, connection: c)
        history.record(list, at: now)
        lastScan = now
        lastError = nil
        status = .ok
    }

    func refreshConnection() {
        guard !isDemo else { return }
        let name = WiFiReader.interfaceNames().first
        guard let name, let info = WiFiReader.read(name) else {
            connection = nil
            if results.isEmpty { status = .noInterface }
            return
        }
        connection = info
        if !info.powerOn { status = .wifiOff }
        if let id = currentID, let rssi = info.rssi, info.isAssociated {
            // Between scans, the connection's own RSSI keeps your network's line moving.
            history.record(id: id, rssi: rssi, at: Date())
            if let i = results.firstIndex(where: { $0.id == id }) { results[i].rssi = rssi }
        }
    }
}
