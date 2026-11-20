import Foundation
import LanternfishKit
import Observation
import SystemConfiguration

/// Scans every connected network at once: one `ScanStore` per distinct active interface
/// (primary first), all sharing one `SharedHistory`. Follows interface changes (SCDynamicStore,
/// debounced 1 s): new interfaces get a store and a scan, vanished ones are dropped, and an
/// interface that moved to another network rescans. The main window shows one store
/// (`displayedInterfaceID`); the menu bar shows all of them.
@MainActor
@Observable
final class NetworkHub {
    /// One store per distinct network, primary interface first.
    private(set) var stores: [ScanStore] = []
    /// Shown while no interface is connected (it can still browse saved networks).
    let placeholder: ScanStore
    let history: SharedHistory

    /// Interface the main window shows. Persisted; falls back to the primary interface.
    var displayedInterfaceID: String? {
        didSet {
            guard oldValue != displayedInterfaceID, !isPreview else { return }
            UserDefaults.standard.set(displayedInterfaceID, forKey: Self.displayedKey)
        }
    }

    /// Called with a store's new devices once per scan (wired to the notifier).
    @ObservationIgnored var onNewDevices: ((ScanStore, [Device]) -> Void)?

    // MARK: Derived

    var storesByID: [String: ScanStore] {
        Dictionary(stores.compactMap { s in s.interfaceID.map { ($0, s) } }, uniquingKeysWith: { a, _ in a })
    }

    func store(for interfaceID: String?) -> ScanStore? {
        guard let interfaceID else { return nil }
        return stores.first { $0.interfaceID == interfaceID }
    }

    /// The store the main window shows.
    var displayedStore: ScanStore {
        store(for: displayedInterfaceID) ?? stores.first ?? placeholder
    }

    /// Interfaces being scanned (deduplicated), primary first.
    var interfaces: [NetworkInterfaceInfo] { stores.compactMap(\.interface) }

    var primaryStore: ScanStore { stores.first ?? placeholder }

    /// Devices online across all networks (stores browsing a saved network count 0).
    var totalOnline: Int { stores.reduce(0) { $0 + ($1.isViewingOtherNetwork ? 0 : $1.onlineCount) } }

    var isAnyScanning: Bool { stores.contains(where: \.isScanning) }

    /// The store whose live network is `networkID`, if any.
    func store(forNetworkID networkID: String?) -> ScanStore? {
        guard let networkID else { return nil }
        return stores.first { $0.currentNetworkID == networkID }
    }

    // MARK: Lifecycle

    private static let displayedKey = "DisplayedInterface"
    @ObservationIgnored private var isPreview = false
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored private var dynamicStore: SCDynamicStore?
    /// Stores of interfaces that went away recently, revived if the interface comes back within
    /// `parkingGrace` (keeps pings, the identified network and in-progress state across a blip).
    @ObservationIgnored private var parked: [String: (store: ScanStore, since: Date)] = [:]
    @ObservationIgnored private var parkingCleanup: Task<Void, Never>?
    private static let parkingGrace: TimeInterval = 120

    init(history: SharedHistory = SharedHistory(directory: SharedHistory.defaultDirectory())) {
        self.history = history
        placeholder = ScanStore(interface: nil, history: history)
        let env = DebugEnv.values
        // Debug aid: LANTERNFISH_INTERFACE=en0 picks the displayed interface.
        displayedInterfaceID = env["LANTERNFISH_INTERFACE"] ?? UserDefaults.standard.string(forKey: Self.displayedKey)
        // Synchronous first pass (subnet + gateway IP); gateway MACs refine it in `refresh()`.
        apply(NetworkSet.dedupe(NetworkInterfaces.active()), scanNew: false)
        watchNetworkChanges()
    }

    /// A hub with one fake store (LANTERNFISH_PREVIEW=1).
    static func preview() -> NetworkHub {
        NetworkHub(previewHistory: SharedHistory(directory: nil))
    }

    private init(previewHistory: SharedHistory) {
        history = previewHistory
        placeholder = ScanStore(interface: nil, history: previewHistory)
        isPreview = true
        let s = ScanStore.preview(history: previewHistory)
        stores = [s]
        displayedInterfaceID = s.interfaceID
    }

    // MARK: Scanning

    /// Re-reads the interfaces, then rescans every network (new ones included).
    func rescanAll() {
        guard !isPreview else { return }
        refresh(thenScanAll: true)
    }

    /// Starts a scan on every store that isn't scanning and hasn't finished one recently.
    func scanIfStale(maxAge: TimeInterval = 120) {
        for s in stores where !s.isScanning {
            if let last = s.lastScanFinishedAt, Date().timeIntervalSince(last) < maxAge { continue }
            s.startScan()
        }
    }

    /// Re-reads the interface list (with gateway MACs from ARP for dedupe) and updates the stores.
    func refresh(thenScanAll: Bool = false) {
        guard !isPreview else { return }
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            let active = NetworkInterfaces.active()
            let arp = await ARPTableMACProvider().macAddresses()
            guard let self, !Task.isCancelled else { return }
            let gatewayMACs = arp.filter { ip, _ in active.contains { $0.gateway == ip } }
            let rescanned = self.apply(NetworkSet.dedupe(active, gatewayMACs: gatewayMACs), scanNew: true)
            if thenScanAll {
                for s in self.stores where !rescanned.contains(ObjectIdentifier(s)) { s.startScan() }
            }
        }
    }

    /// Brings `stores` in line with `desired`. Returns the stores that started a scan here.
    @discardableResult
    private func apply(_ desired: [NetworkInterfaceInfo], scanNew: Bool) -> Set<ObjectIdentifier> {
        let diff = NetworkSet.diff(current: interfaces, desired: desired)
        var started: Set<ObjectIdentifier> = []
        if !diff.isEmpty {
            alertsLog(
                "interfaces: %@ (added %@, removed %@, changed %@)",
                desired.map { "\($0.name)=\($0.subnet)" }.joined(separator: " "),
                diff.added.map(\.name).joined(separator: ","), diff.removed.joined(separator: ","),
                diff.changed.map(\.name).joined(separator: ","))
        }
        var byID = storesByID
        for id in diff.removed {
            guard let s = byID.removeValue(forKey: id) else { continue }
            s.stop()
            parked[id] = (s, Date())
        }
        dropExpiredParkedStores()
        for iface in diff.changed {
            guard let s = byID[iface.id] else { continue }
            s.update(interface: iface, rescan: scanNew)
            if scanNew { started.insert(ObjectIdentifier(s)) }
        }
        for iface in diff.updated { byID[iface.id]?.update(interface: iface, rescan: false) }
        for iface in diff.added {
            if let p = parked.removeValue(forKey: iface.id) {
                byID[iface.id] = p.store
                p.store.update(interface: iface, rescan: scanNew)
                if scanNew { started.insert(ObjectIdentifier(p.store)) }
                continue
            }
            let s = ScanStore(interface: iface, history: history)
            s.onNewDevices = { [weak self, weak s] devices in
                guard let self, let s else { return }
                self.onNewDevices?(s, devices)
            }
            byID[iface.id] = s
            if scanNew {
                s.startScan()
                started.insert(ObjectIdentifier(s))
            }
        }
        stores = desired.compactMap { byID[$0.id] }
        // Two sweeps at once share the socket budget.
        let share = max(1, stores.count)
        for s in stores { s.discoveryConcurrency = max(96, 256 / share) }
        if !parked.isEmpty, parkingCleanup == nil {
            parkingCleanup = Task { [weak self] in
                try? await Task.sleep(for: .seconds(Self.parkingGrace + 1))
                guard let self else { return }
                self.parkingCleanup = nil
                self.dropExpiredParkedStores()
            }
        }
        return started
    }

    /// Lets go of parked stores whose interface stayed away longer than `parkingGrace`.
    private func dropExpiredParkedStores() {
        let now = Date()
        for (id, p) in parked where now.timeIntervalSince(p.since) >= Self.parkingGrace {
            parked[id] = nil
            p.store.detach()
        }
    }

    // MARK: Network changes

    /// Interface address changes and primary-service changes trigger a debounced refresh.
    private func watchNetworkChanges() {
        var ctx = SCDynamicStoreContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)
        guard
            let store = SCDynamicStoreCreate(
                nil, "Lanternfish" as CFString,
                { _, _, info in
                    guard let info else { return }
                    let hub = Unmanaged<NetworkHub>.fromOpaque(info).takeUnretainedValue()
                    MainActor.assumeIsolated { hub.networkChanged() }
                }, &ctx)
        else { return }
        let patterns = ["State:/Network/Interface/[^/]+/IPv4", "State:/Network/Global/IPv4"] as CFArray
        SCDynamicStoreSetNotificationKeys(store, nil, patterns)
        SCDynamicStoreSetDispatchQueue(store, .main)
        dynamicStore = store
    }

    private func networkChanged() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            alertsLog("network configuration changed")
            self?.refresh()
        }
    }

    // MARK: Main window helpers

    /// Shows a store's network in the main window, e.g. from the menu bar.
    func show(_ store: ScanStore) {
        if let id = store.interfaceID { displayedInterfaceID = id }
        MainWindow.show()
    }

    func setShowOfflineDevices(_ on: Bool) {
        for s in stores + [placeholder] { s.showOfflineDevices = on }
    }
}
