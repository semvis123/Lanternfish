import Foundation

/// Rescans every network periodically while the app runs (also with the main window closed).
/// Interval comes from the "Scan automatically" setting; each network is skipped while it is
/// scanning or running a full port scan. Browsing another network's saved devices doesn't pause it
/// (the store keeps scanning its live network). A scan running far longer than expected is
/// restarted (hang guard).
///
/// Debug aid: LANTERNFISH_AUTOSCAN_SECONDS=<n> overrides the interval.
@MainActor
final class AutoScanScheduler {
    private let hub: NetworkHub
    private var task: Task<Void, Never>?
    /// When the scheduler started (stores that never scanned count from here).
    private var startedAt = Date()
    /// When the scheduler last started a scan per store (covers scans that never complete).
    private var lastAttempt: [ObjectIdentifier: Date] = [:]

    init(hub: NetworkHub) {
        self.hub = hub
    }

    private var interval: TimeInterval? {
        if let s = DebugEnv.values["LANTERNFISH_AUTOSCAN_SECONDS"].flatMap(Double.init), s > 0 {
            return s
        }
        let minutes = AppSettings.autoScanMinutes
        return minutes > 0 ? TimeInterval(minutes * 60) : nil
    }

    func start() {
        guard task == nil else { return }
        startedAt = Date()
        task = Task { [weak self] in
            while !Task.isCancelled {
                let step = min(30, max(1, (self?.interval ?? 30) / 4))
                try? await Task.sleep(for: .seconds(step))
                self?.tick()
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    /// A scan running longer than this is considered hung: 3× the last one, at least 3 min.
    static func hangLimit(lastScanDuration: TimeInterval?) -> TimeInterval {
        max(180, 3 * (lastScanDuration ?? 60))
    }

    private func tick() {
        let now = Date()
        for store in hub.stores where store.isScanning {
            guard let started = store.scanStartedAt,
                now.timeIntervalSince(started) > Self.hangLimit(lastScanDuration: store.lastScanDuration)
            else { continue }
            alertsLog(
                "scan of %@ running for %.0f s; restarting", store.interfaceID ?? "-", now.timeIntervalSince(started))
            lastAttempt[ObjectIdentifier(store)] = now
            store.startScan()
        }
        guard let interval else { return }
        var due: [ScanStore] = []
        for store in hub.stores where !store.isScanning && store.fullScanProgress.isEmpty {
            let id = ObjectIdentifier(store)
            let last = max(store.lastScanFinishedAt ?? .distantPast, lastAttempt[id] ?? startedAt)
            if now.timeIntervalSince(last) >= interval { due.append(store) }
        }
        guard !due.isEmpty else { return }
        let live = Set(hub.stores.map(ObjectIdentifier.init))
        lastAttempt = lastAttempt.filter { live.contains($0.key) }
        for store in due {
            lastAttempt[ObjectIdentifier(store)] = now
            alertsLog("automatic scan of %@ (every %.0f s)", store.interfaceID ?? "-", interval)
            store.startScan()
        }
    }
}
