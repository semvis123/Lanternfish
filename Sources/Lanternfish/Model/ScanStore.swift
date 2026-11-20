import AppKit
import Foundation
import LanternfishKit
import Observation

/// Scan results for one network interface (see `NetworkHub` for the set of all of them).
@MainActor
@Observable
final class ScanStore {
    // MARK: State

    /// Devices sorted by IP: live scan results annotated with their history, plus (when
    /// `showOfflineDevices`) remembered devices of the network that aren't online right now.
    /// While browsing another network (`viewedNetworkID`), that network's stored devices, all offline.
    private(set) var devices: [Device] = []
    /// BSD name of the interface this store scans (nil: a placeholder store while not connected).
    let interfaceID: String?
    /// The interface's current configuration (nil when it went away / not connected).
    private(set) var interface: NetworkInterfaceInfo?
    private(set) var isScanning = false
    /// When the last scan ran to completion (nil until one has).
    private(set) var lastScanFinishedAt: Date?
    /// When the running scan started (nil while not scanning).
    private(set) var scanStartedAt: Date?
    /// How long the last completed scan took.
    private(set) var lastScanDuration: TimeInterval?
    /// Short status line, e.g. "Scanning… 12 online · 3 offline" or "14 online".
    private(set) var statusText = ""
    /// Progress (0...1) of a running full port scan per device. Absent when not scanning.
    private(set) var fullScanProgress: [IPv4Address: Double] = [:]

    /// Same as `interface`.
    var selectedInterface: NetworkInterfaceInfo? { interface }

    /// Hosts probed at once by the discovery sweep; lowered by the hub while several stores scan.
    var discoveryConcurrency = 256

    /// Adopts a new configuration of this store's interface (from the hub). Rescans when it now
    /// reaches another network or address; `rescan: false` only updates the stored info.
    func update(interface new: NetworkInterfaceInfo, rescan: Bool) {
        guard new.id == interfaceID else { return }
        interface = new
        isStopped = false
        if rescan { startScan() }
    }

    /// Stops all work (the interface went away). Pings stop (their results stay), history stays.
    /// The hub may revive the store with `update(interface:rescan:)` when the interface returns.
    func stop() {
        cancelWork(includingFullScans: true)
        for entry in pingTasks.values { entry.task.cancel() }
        pingTasks = [:]
        for ip in pingSessions.keys { pingSessions[ip]?.isRunning = false }
        if isScanning { publish() }
        flushNewDevices()
        isScanning = false
        scanStartedAt = nil
        isStopped = true
        updateStatus()
    }

    /// The store is dropped for good: stop listening to history edits.
    func detach() {
        sharedHistory.removeListener(self)
    }

    func startScan() {
        guard !isPreview else { return }
        // Full port scans are per-IP and independent of discovery: they keep running.
        cancelWork(includingFullScans: false)
        isStopped = false
        flushNewDevices()
        capturePresenceBaseline()
        newDeviceKeys = []
        newDevicesThisScan = []
        notifiedNewDevices = false

        // Pick up address/gateway changes of our interface (the hub also pushes them).
        if let id = interfaceID, let fresh = NetworkInterfaces.active().first(where: { $0.id == id }) {
            interface = fresh
        }

        byIP = [:]
        portScanned = []
        namesResolved = []
        netbiosQueried = []
        localNamesQueried = []
        identificationNotes = [:]
        fingerprintFills = [:]
        awaitingGatewayMAC = false
        guard let iface = selectedInterface else {
            currentNetworkID = nil
            for ip in Array(fullScanTasks.keys) { cancelFullScan(ip) }
            rebuildDevices()
            isScanning = false
            scanStartedAt = nil
            statusText = "Not connected to a network"
            return
        }

        gateway = iface.gateway
        allowed = Set(iface.subnet.scanHosts()).union([iface.address])
        // Full scans of addresses outside the (new) subnet are moot.
        for ip in Array(fullScanTasks.keys) where !allowed.contains(ip) { cancelFullScan(ip) }
        addSelf(iface)
        // Keep showing the same network's history across rescans; otherwise wait for identification.
        if let net = currentNetwork,
            net.gatewayIP != iface.gateway?.description || net.subnet != iface.subnet.description
        {
            currentNetworkID = nil
        }
        rebuildDevices()
        identifyNetwork(iface, generation: generation)

        isScanning = true
        scanStartedAt = Date()
        dirty = true
        historyDirty = true
        let gen = generation
        publishTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.publish()
                try? await Task.sleep(for: Self.publishInterval)
            }
        }
        scanTask = Task { [weak self] in
            await self?.runScan(iface, generation: gen)
        }
    }

    func scanAllPorts(_ ip: IPv4Address) {
        fullScanTasks[ip]?.cancel()
        fullScanProgress[ip] = 0
        fullScanFound[ip] = []
        let token = UUID()
        fullScanTokens[ip] = token
        // Strong capture is fine: the task ends when the scan finishes or is cancelled.
        // Results go to whichever scan generation is current, so a rescan doesn't drop them.
        fullScanTasks[ip] = Task {
            let scanner = PortScanner(concurrency: 1024, timeout: .milliseconds(400))
            let stream = scanner.scan(ip, ports: Array(1...65535)) { value in
                Task { @MainActor in
                    guard self.fullScanTokens[ip] == token else { return }
                    self.fullScanProgress[ip] = value
                }
            }
            for await port in stream {
                guard self.fullScanTokens[ip] == token else { break }
                self.fullScanFound[ip, default: []].insert(port)
                var patch = DevicePatch(ip: ip)
                patch.openPorts = [port]
                self.apply(patch, generation: self.generation)
            }
            guard !Task.isCancelled, self.fullScanTokens[ip] == token else { return }
            self.fullScanProgress[ip] = nil
            self.fullScanTasks[ip] = nil
            self.fullScanTokens[ip] = nil
            self.fullScanFound[ip] = nil
            self.enqueueBanners(ip, generation: self.generation)
        }
    }

    func cancelFullScan(_ ip: IPv4Address) {
        fullScanTasks[ip]?.cancel()
        fullScanTasks[ip] = nil
        fullScanTokens[ip] = nil
        fullScanFound[ip] = nil
        fullScanProgress[ip] = nil
    }

    // MARK: History

    /// Every network seen, most recently seen first.
    var knownNetworks: [KnownNetwork] {
        history.networks.values.sorted { $0.lastSeen > $1.lastSeen }
    }

    /// The network being scanned (nil until identified, or when not connected).
    var currentNetwork: KnownNetwork? { currentNetworkID.flatMap { history.networks[$0] } }
    private(set) var currentNetworkID: String? {
        didSet {
            guard oldValue != currentNetworkID else { return }
            // Keys of the previous network mean nothing on this one.
            newDeviceKeys = []
            newDevicesThisScan = []
            forgottenOnline = []
            // Browsing the network we're now on is just showing the live one (don't stay pinned).
            if viewedNetworkID != nil, viewedNetworkID == currentNetworkID { viewedNetworkID = nil }
        }
    }

    /// A stored network to browse instead of the live one (nil = the current network). Scanning,
    /// recording and watching continue on the live network meanwhile; only `devices` differs.
    var viewedNetworkID: String? {
        didSet {
            // Browsing the live network is just showing it (unpinned). Don't return early: the
            // nested set may not re-run this observer, and `devices` must still be rebuilt.
            if viewedNetworkID != nil, viewedNetworkID == currentNetworkID { viewedNetworkID = nil }
            guard oldValue != viewedNetworkID else { return }
            rebuildDevices()
        }
    }

    /// The network whose devices `devices` shows.
    var displayedNetwork: KnownNetwork? { (viewedNetworkID ?? currentNetworkID).flatMap { history.networks[$0] } }

    /// True while browsing a stored network other than the one being scanned (read-only, all offline).
    var isViewingOtherNetwork: Bool { viewedNetworkID != nil && viewedNetworkID != currentNetworkID }

    /// The live network's online devices, annotated with history, whatever network `devices` shows.
    var liveDevices: [Device] {
        guard isViewingOtherNetwork else { return devices.filter(\.isOnline) }
        return history.merged(online: Array(byIP.values), networkID: currentNetworkID, includeOffline: false)
    }

    /// Whether remembered devices that aren't online are listed. Persisted in user defaults.
    var showOfflineDevices: Bool = UserDefaults.standard.object(forKey: showOfflineDevicesKey) as? Bool ?? true {
        didSet {
            guard oldValue != showOfflineDevices else { return }
            if !isPreview { UserDefaults.standard.set(showOfflineDevices, forKey: Self.showOfflineDevicesKey) }
            rebuildDevices()
        }
    }

    private(set) var onlineCount = 0
    private(set) var offlineCount = 0

    /// Devices seen for the first time during the current scan on a network that had been scanned
    /// before (the very first scan of a network reports none). Updated live; reset by `startScan()`.
    private(set) var newDevicesThisScan: [Device] = []

    /// Called once per scan with the devices first seen during it (same rules as
    /// `newDevicesThisScan`), when the scan finishes or is cancelled by a rescan. Never called
    /// with an empty array.
    var onNewDevices: (([Device]) -> Void)?

    /// Arrivals and departures on the live network, for the table highlight and map pulses.
    /// Only scans after the first one of this session report any (there's nothing to compare with
    /// before that), and only while the network stays the same.
    @ObservationIgnored let arrivals = DeviceArrivals()

    /// Device whose "Rename…" sheet is showing (set from context menus, presented by ContentView).
    var deviceToRename: Device?

    func rename(device: Device, to name: String?) {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        editRecord(device) { $0.customName = trimmed?.isEmpty == false ? trimmed : nil }
    }

    /// nil restores the automatically detected type.
    func setKind(device: Device, to kind: DeviceKind?) {
        editRecord(device) { $0.customKind = kind }
    }

    func setNotes(device: Device, to notes: String?) {
        let trimmed = notes?.trimmingCharacters(in: .whitespacesAndNewlines)
        editRecord(device) { $0.notes = trimmed?.isEmpty == false ? notes : nil }
    }

    /// Clears the "New" badge.
    func acknowledge(device: Device) {
        guard device.isNew else { return }
        editRecord(device) { $0.acknowledged = true }
    }

    /// Removes a remembered device from its network (meant for offline devices; an online one
    /// is recorded again on the next update — as already acknowledged, not as a new device).
    func forgetDevice(_ device: Device) {
        guard let netID = viewedNetworkID ?? currentNetworkID, let key = device.historyKey else { return }
        history.forgetDevice(key: key, networkID: netID)
        if netID == currentNetworkID, device.isOnline {
            forgottenOnline.insert(key)
            newDeviceKeys.removeAll { $0 == key }
            newDevicesThisScan.removeAll { $0.historyKey == key }
        }
        historyChanged()
    }

    func renameNetwork(id: String, to name: String?) {
        history.renameNetwork(id: id, to: name)
        historyChanged()
    }

    /// Deletes a network and all its remembered devices. Forgetting the current network starts
    /// its history afresh from the devices online now.
    func forgetNetwork(id: String) {
        history.forgetNetwork(id: id)
        if viewedNetworkID == id { viewedNetworkID = nil }
        if currentNetworkID == id { reidentifyAfterForget() }
        historyChanged()
    }

    // MARK: Ping

    /// Live and finished ping sessions per device. Sessions survive rescans and interface
    /// changes; their tasks end when stopped or when the app quits.
    private(set) var pingSessions: [IPv4Address: PingSession] = [:]

    /// Starts (or restarts, clearing old results) a continuous ping to `ip`.
    func startPing(_ ip: IPv4Address) {
        pingTasks[ip]?.task.cancel()
        pingSessions[ip] = PingSession(isRunning: true)
        let token = UUID()
        let task = Task { [weak self] in
            for await result in Pinger().ping(ip) {
                guard let self, self.pingTasks[ip]?.token == token else { return }
                self.pingSessions[ip]?.append(result)
            }
            // The stream also ends if no ICMP socket could be opened.
            guard let self, self.pingTasks[ip]?.token == token else { return }
            self.pingTasks[ip] = nil
            self.pingSessions[ip]?.isRunning = false
        }
        pingTasks[ip] = (token, task)
    }

    /// Stops a running ping; its results stay available.
    func stopPing(_ ip: IPv4Address) {
        pingTasks.removeValue(forKey: ip)?.task.cancel()
        pingSessions[ip]?.isRunning = false
    }

    // MARK: Internals

    private static let showOfflineDevicesKey = "ShowOfflineDevices"
    /// How often `devices` is republished while a scan streams in results.
    private static let publishInterval: Duration = .milliseconds(100)
    private static let maxConcurrentBanners = 16

    private var isPreview = false
    /// Stopped by the hub (interface gone); revived by `update(interface:rescan:)` / `startScan()`.
    private var isStopped = false
    private var generation = 0
    private var scanTask: Task<Void, Never>?
    /// While scanning: the 10 Hz publish loop. Otherwise: a pending one-shot publish (late results).
    private var publishTask: Task<Void, Never>?
    private var fullScanTasks: [IPv4Address: Task<Void, Never>] = [:]
    /// Identifies the running full scan per IP (a restarted one ignores the old one's results).
    @ObservationIgnored private var fullScanTokens: [IPv4Address: UUID] = [:]
    /// Ports the running full scan found so far, re-applied when a rescan starts the table afresh.
    @ObservationIgnored private var fullScanFound: [IPv4Address: Set<OpenPort>] = [:]
    private var pingTasks: [IPv4Address: (token: UUID, task: Task<Void, Never>)] = [:]
    private var byIP: [IPv4Address: Device] = [:]
    private var allowed: Set<IPv4Address> = []
    private var gateway: IPv4Address?
    private var portScanned: Set<IPv4Address> = []
    /// `devices` needs rebuilding.
    @ObservationIgnored private var dirty = false
    /// Live results changed since they were last recorded in history.
    @ObservationIgnored private var historyDirty = false
    @ObservationIgnored private var lastRecordAt = Date.distantPast
    /// Live results are recorded in history at most this often (and when a scan completes).
    private static let recordInterval: TimeInterval = 1
    /// The gateway's MAC wasn't known when the scan started and matching by address alone could
    /// pick another router's network: identification waits for it (or for the scan to complete).
    @ObservationIgnored private var awaitingGatewayMAC = false
    /// Banner grabs (HTTP titles, SSH greetings) run after each device's port scan, at most
    /// `maxConcurrentBanners` at once per scan generation. Each removes itself when done.
    @ObservationIgnored private var bannerTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var bannerLimiter = AsyncLimiter(maxConcurrentBanners)

    /// Shared by all stores: the one writer of history.json.
    @ObservationIgnored private let sharedHistory: SharedHistory
    /// In-place access to the shared history (no copy of the whole store per mutation).
    private var history: HistoryStore {
        get { sharedHistory.data }
        _modify { yield &sharedHistory.data }
    }
    /// Who was online on which network when the running scan started (see `arrivals`).
    @ObservationIgnored private var presenceBaseline: (networkID: String?, keys: Set<String>, ips: Set<IPv4Address>)?
    /// Keys already reported as arrived during the running scan.
    @ObservationIgnored private var arrivedThisScan: Set<String> = []
    /// Debug aid: LANTERNFISH_FAKE_ARRIVALS=1 treats the first scan as if nothing had been online before.
    @ObservationIgnored private lazy var fakeArrivals = DebugEnv.values["LANTERNFISH_FAKE_ARRIVALS"] == "1"
    /// Keys of records created as new during this scan, in discovery order.
    private var newDeviceKeys: [String] = []
    private var notifiedNewDevices = false
    /// Devices the user forgot while they were online: re-recorded as acknowledged, not as new.
    @ObservationIgnored private var forgottenOnline: Set<String> = []

    /// A store bound to `interface` (nil: a "not connected" placeholder that can still browse
    /// saved networks). All stores of the app share `history`.
    init(interface: NetworkInterfaceInfo?, history: SharedHistory) {
        interfaceID = interface?.id
        self.interface = interface
        sharedHistory = history
        history.addListener(self) { [weak self] in self?.historyEditedElsewhere() }
    }

    /// Cancels the running scan and its enrichment (and, with `includingFullScans`, full port scans).
    private func cancelWork(includingFullScans: Bool) {
        scanTask?.cancel()
        scanTask = nil
        publishTask?.cancel()
        publishTask = nil
        if includingFullScans {
            for ip in Array(fullScanTasks.keys) { cancelFullScan(ip) }
        }
        for task in bannerTasks.values { task.cancel() }
        bannerTasks = [:]
        bannerLimiter = AsyncLimiter(Self.maxConcurrentBanners)
        generation &+= 1
    }

    private func isCurrent(_ gen: Int) -> Bool { gen == generation && !Task.isCancelled }

    /// Another store renamed/forgot something: refresh, and re-identify if our network was forgotten.
    private func historyEditedElsewhere() {
        if let id = viewedNetworkID, history.networks[id] == nil { viewedNetworkID = nil }
        if let id = currentNetworkID, history.networks[id] == nil { reidentifyAfterForget() }
        rebuildDevices()
    }

    /// Our network was forgotten (here or by another store): start its history afresh from the
    /// devices online now.
    private func reidentifyAfterForget() {
        currentNetworkID = nil
        if let iface = interface, !isStopped {
            currentNetworkID = history.identifyNetwork(
                gatewayMAC: gateway.flatMap { byIP[$0]?.mac },
                gatewayIP: iface.gateway, subnet: iface.subnet)
        }
        dirty = true
        historyDirty = true
        publish()
    }

    /// Reads the gateway's MAC from the ARP cache (usually present), then finds or creates the
    /// network in history and shows its remembered devices. Without the MAC, waits for it when
    /// matching by address could pick the wrong network (see `awaitingGatewayMAC`).
    private func identifyNetwork(_ iface: NetworkInterfaceInfo, generation gen: Int) {
        Task { [weak self] in
            let table = await ARPTableMACProvider().macAddresses()
            guard let self, gen == self.generation else { return }
            let gwMAC = iface.gateway.flatMap { table[$0] ?? self.byIP[$0]?.mac }
            if gwMAC == nil, self.currentNetworkID == nil,
                self.history.identificationNeedsGatewayMAC(gatewayIP: iface.gateway)
            {
                self.awaitingGatewayMAC = true
                return
            }
            self.currentNetworkID = self.history.identifyNetwork(
                gatewayMAC: gwMAC, gatewayIP: iface.gateway,
                subnet: iface.subnet)
            self.dirty = true
            self.historyDirty = true
            self.publish()
        }
    }

    /// Finishes a deferred identification once the gateway's MAC is known, or when the scan
    /// completes without it (then by address alone).
    private func resolvePendingIdentification(scanComplete: Bool) {
        guard awaitingGatewayMAC, let iface = selectedInterface else { return }
        let mac = gateway.flatMap { byIP[$0]?.mac }
        guard mac != nil || scanComplete else { return }
        awaitingGatewayMAC = false
        currentNetworkID = history.identifyNetwork(gatewayMAC: mac, gatewayIP: iface.gateway, subnet: iface.subnet)
        dirty = true
        historyDirty = true
    }

    /// If the gateway's MAC turned up during the scan and the network was matched without it,
    /// match again (adopts the MAC, or switches to the right network).
    private func reidentifyIfNeeded() {
        guard let net = currentNetwork, let gw = gateway, let mac = byIP[gw]?.mac,
            net.gatewayMAC != mac.description, let iface = selectedInterface
        else { return }
        currentNetworkID = history.identifyNetwork(gatewayMAC: mac, gatewayIP: gw, subnet: iface.subnet)
    }

    private func editRecord(_ device: Device, _ body: (inout KnownDevice) -> Void) {
        guard let netID = viewedNetworkID ?? currentNetworkID,
            let key = history.ensureRecord(for: device, networkID: netID)
        else { return }
        history.updateDevice(key: key, networkID: netID, body)
        historyChanged()
    }

    /// After a user edit: refresh, let the other stores refresh, save soon.
    private func historyChanged() {
        rebuildDevices()
        guard !isPreview else { return }
        sharedHistory.edited(by: self)
    }

    /// Recomputes `devices` (and the counts) from live results and history.
    private func rebuildDevices() {
        guard !isPreview else { return }
        let other = isViewingOtherNetwork
        let all = history.merged(
            online: other ? [] : Array(byIP.values),
            networkID: viewedNetworkID ?? currentNetworkID, includeOffline: true)
        onlineCount = all.count { $0.isOnline }
        offlineCount = all.count - onlineCount
        let shown = showOfflineDevices || other ? all : all.filter(\.isOnline)
        if shown != devices { devices = shown }
        if !newDeviceKeys.isEmpty {
            let source =
                other
                ? history.merged(
                    online: Array(byIP.values), networkID: currentNetworkID,
                    includeOffline: false) : all
            let byKey = Dictionary(
                source.compactMap { d in d.historyKey.map { ($0, d) } },
                uniquingKeysWith: { a, _ in a })
            let fresh = newDeviceKeys.compactMap { byKey[$0] }
            if fresh != newDevicesThisScan {
                // A genuinely new device joined the live network mid-scan: the optional chime.
                if isScanning, fresh.count > newDevicesThisScan.count { NewDeviceChime.shared.newDevicesJoined() }
                newDevicesThisScan = fresh
            }
        }
        if isScanning { trackArrivals(liveMerged: other ? nil : all) }
        updateStatus()
    }

    // MARK: Arrivals

    /// Remembers who is online now, before a rescan clears the live results. A scan that is
    /// restarted midway keeps the previous baseline too (its results are partial).
    private func capturePresenceBaseline() {
        arrivedThisScan = []
        let previous = presenceBaseline
        presenceBaseline = nil
        guard !isPreview else { return }
        if fakeArrivals, lastScanFinishedAt == nil {
            presenceBaseline = (nil, [], [])
            return
        }
        guard let netID = currentNetworkID, lastScanFinishedAt != nil else { return }
        let live = liveMerged(netID)
        var keys = Set(live.map(DeviceArrivals.key(for:)))
        var ips = Set(live.map(\.ip))
        if isScanning, let old = previous, old.networkID == netID {
            keys.formUnion(old.keys)
            ips.formUnion(old.ips)
        }
        presenceBaseline = (netID, keys, ips)
    }

    private func liveMerged(_ netID: String?) -> [Device] {
        history.merged(online: Array(byIP.values), networkID: netID, includeOffline: false)
    }

    /// Reports devices that came online during this scan and weren't online before it.
    private func trackArrivals(liveMerged merged: [Device]?) {
        guard let base = presenceBaseline, base.networkID == nil || base.networkID == currentNetworkID else { return }
        let live = merged ?? liveMerged(currentNetworkID)
        var fresh: [String] = []
        for d in live where d.isOnline && !d.isSelf {
            let key = DeviceArrivals.key(for: d)
            // By address too: a device whose MAC isn't known yet may briefly have another key.
            guard !base.keys.contains(key), !base.ips.contains(d.ip) else { continue }
            if arrivedThisScan.insert(key).inserted { fresh.append(key) }
        }
        arrivals.record(fresh, online: true)
    }

    /// After a completed scan: devices online before it that it didn't find.
    private func trackDepartures() {
        defer { presenceBaseline = nil }
        guard let base = presenceBaseline, let netID = base.networkID, netID == currentNetworkID else { return }
        let live = liveMerged(netID)
        let keys = Set(live.map(DeviceArrivals.key(for:)))
        let ips = Set(live.map(\.ip))
        let gone = base.keys.filter { !keys.contains($0) }
        // A device whose key changed but is still at a baseline address isn't gone.
        let byKey = Dictionary(
            history.networks[netID]?.devices.values.map { ($0.key, $0.lastIP) } ?? [],
            uniquingKeysWith: { a, _ in a })
        arrivals.record(
            gone.filter { key in byKey[key].flatMap(IPv4Address.init).map { !ips.contains($0) } ?? true }
                .sorted(),
            online: false)
    }

    private func updateStatus() {
        var parts = ["\(onlineCount) online"]
        if offlineCount > 0 { parts.append("\(offlineCount) offline") }
        let counts = parts.joined(separator: " · ")
        let text = isScanning ? "Scanning… \(counts)" : counts
        if text != statusText { statusText = text }
    }

    /// Reports this scan's new devices once.
    private func flushNewDevices() {
        guard !notifiedNewDevices, !newDevicesThisScan.isEmpty else { return }
        notifiedNewDevices = true
        onNewDevices?(newDevicesThisScan)
    }

    private func addSelf(_ iface: NetworkInterfaceInfo) {
        var me = Device(ip: iface.address)
        me.isSelf = true
        me.name = Host.current().localizedName
        me.mac = iface.mac
        me.manufacturer = "Apple"
        me.vendor = iface.mac.flatMap { VendorDatabase.shared.vendor(for: $0) }
        me.kind = .computer
        me.responseTime = .zero
        byIP[iface.address] = me
    }

    /// Merges a patch into the device table. Ignores stale patches and IPs outside the subnet.
    /// `weak` patches (banners, NetBIOS, heuristics) only fill fields that are still empty.
    /// Only a patch that actually changes the device marks the table for publishing.
    private func apply(_ patch: DevicePatch, generation gen: Int, weak: Bool = false) {
        guard gen == generation, allowed.contains(patch.ip) else { return }
        let old = byIP[patch.ip]
        var device = old ?? Device(ip: patch.ip)
        if old == nil, let found = fullScanFound[patch.ip], !found.isEmpty {
            // A full port scan that outlived the previous scan: keep what it found.
            device.openPorts = Array(Set(device.openPorts).union(found)).sorted()
        }
        if weak { device.fillGaps(from: patch) } else { device.merge(patch) }
        if device.vendor == nil, let mac = device.mac {
            device.vendor = VendorDatabase.shared.vendor(for: mac)
        }
        if device.isSelf {
            device.manufacturer = "Apple"
        } else if let hint = NameHints.patch(for: device) {
            device.fillGaps(from: hint)
        }
        if !device.isSelf {
            NameCleanup.sanitize(&device)
            device.kind = DeviceKindClassifier.classify(device, gateway: gateway)
            identify(&device)
        }
        guard device != old else { return }
        byIP[patch.ip] = device
        dirty = true
        historyDirty = true
        schedulePublish()
    }

    /// After the scan (no publish loop): publish late results (full port scans, …) once, shortly.
    private func schedulePublish() {
        guard publishTask == nil, !isPreview else { return }
        publishTask = Task { [weak self] in
            try? await Task.sleep(for: Self.publishInterval)
            guard let self, !Task.isCancelled else { return }
            self.publishTask = nil
            self.publish()
        }
    }

    /// Rebuilds `devices` when something changed; records live results in history at most once
    /// per `recordInterval` (always when the scan completes).
    private func publish(scanComplete: Bool = false) {
        resolvePendingIdentification(scanComplete: scanComplete)
        let recordDue =
            scanComplete
            || (historyDirty && Date().timeIntervalSince(lastRecordAt) >= Self.recordInterval)
        guard dirty || recordDue else {
            if historyDirty, currentNetworkID != nil { schedulePublish() }
            return
        }
        dirty = false
        reidentifyIfNeeded()
        if recordDue, let netID = currentNetworkID {
            historyDirty = false
            lastRecordAt = Date()
            // Presence: only while scanning are the listed devices really being seen right now.
            let created = history.record(
                Array(byIP.values), networkID: netID, scanComplete: scanComplete,
                presenceGap: isScanning || scanComplete ? AppSettings.presenceGap : nil,
                acknowledging: forgottenOnline)
            if !forgottenOnline.isEmpty, let net = history.networks[netID] {
                forgottenOnline = forgottenOnline.filter { net.devices[$0] == nil }
            }
            newDeviceKeys.append(contentsOf: created)
            if scanComplete { history.completeScan(networkID: netID) }
            if !isPreview { sharedHistory.changed(scanComplete ? .soon : .background) }
        } else if historyDirty, currentNetworkID != nil {
            schedulePublish()
        }
        rebuildDevices()
    }

    private func runScan(_ iface: NetworkInterfaceInfo, generation gen: Int) async {
        let hosts = iface.subnet.scanHosts()
        let discovery = HostDiscovery(concurrency: discoveryConcurrency)

        await withTaskGroup(of: Void.self) { group in
            // 1. Fast sweep, then ARP, reverse DNS and common ports.
            group.addTask { [weak self] in
                // ARP entries that predate the sweep may be stale (the kernel keeps them ~20 min).
                let arpBefore = await ARPTableMACProvider().macAddresses()
                let arpPoller = Task { [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .milliseconds(500))
                        await self?.mergeARP(generation: gen)
                    }
                }
                for await patch in discovery.sweep(hosts) {
                    await self?.apply(patch, generation: gen)
                }
                arpPoller.cancel()
                // After the sweep the ARP cache is warm: also add hosts that ignored our probes
                // but answered the sweep's ARP requests.
                await self?.mergeARP(generation: gen, addRefreshedSince: arpBefore)
                guard !Task.isCancelled else { return }
                await withTaskGroup(of: Void.self) { inner in
                    inner.addTask { [weak self] in await self?.resolveNames(generation: gen) }
                    inner.addTask { [weak self] in await self?.scanCommonPorts(generation: gen) }
                    inner.addTask { [weak self] in await self?.queryNetBIOS(generation: gen) }
                    inner.addTask { [weak self] in await self?.resolveLocalNames(iface, generation: gen) }
                    inner.addTask { [weak self] in await self?.probeGateway(iface, generation: gen) }
                }
            }
            // 2. Bonjour.
            group.addTask { [weak self] in
                for await patch in BonjourScanner().scan(duration: .seconds(6)) {
                    await self?.apply(patch, generation: gen)
                }
            }
            // 3. SSDP / UPnP.
            group.addTask { [weak self] in
                // Multicast leaves via the primary interface unless told otherwise.
                for await patch in SSDPScanner(interfaceAddress: iface.address).scan(duration: .seconds(3)) {
                    await self?.apply(patch, generation: gen)
                }
            }
        }

        guard isCurrent(gen) else { return }
        // Devices that only showed up via Bonjour/SSDP after the port pass.
        await scanCommonPorts(generation: gen)
        await resolveNames(generation: gen)
        await queryNetBIOS(generation: gen)
        await resolveLocalNames(iface, generation: gen)
        // Let in-flight banner grabs land before declaring the scan done (each removes itself).
        while isCurrent(gen), let next = bannerTasks.values.first {
            await next.value
        }
        guard isCurrent(gen) else { return }
        isScanning = false
        lastScanFinishedAt = Date()
        lastScanDuration = scanStartedAt.map { Date().timeIntervalSince($0) }
        scanStartedAt = nil
        publishTask?.cancel()
        publishTask = nil
        dirty = true
        publish(scanComplete: true)
        trackDepartures()
        flushNewDevices()
        dumpIfRequested()
    }

    /// Debug aid: LANTERNFISH_DUMP=/path.txt writes one line per device when a scan finishes.
    private func dumpIfRequested() {
        guard var path = DebugEnv.values["LANTERNFISH_DUMP"] else { return }
        // Several networks: the primary one writes <path>, the others <path>-<interface>.<ext>.
        if let iface = interface, !iface.isPrimary {
            let ns = path as NSString
            path =
                ns.deletingPathExtension + "-\(iface.name)" + (ns.pathExtension.isEmpty ? "" : ".\(ns.pathExtension)")
        }
        let lines = devices.map { d in
            [
                d.ip.description, d.name ?? "-", d.hostname ?? "-", d.brandModel ?? "-", d.osHint ?? "-",
                d.webTitle ?? "-", d.kind.rawValue, d.isPrivateMAC ? "private" : (d.mac?.description ?? "-"),
                d.openPorts.map { String($0.port) }.joined(separator: ","), d.services.sorted().joined(separator: ","),
                d.confidence.map { "\(Int(($0 * 100).rounded()))%" } ?? "-",
                d.identificationReasons.joined(separator: "; "),
            ]
            .joined(separator: " | ")
        }
        try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// MACs from the ARP cache for listed devices whose MAC is missing or changed. With
    /// `addRefreshedSince`, also adds hosts not listed yet whose entry is new or changed since
    /// that earlier snapshot (resolved during this sweep, so they're really there); entries that
    /// were already cached may be stale and are left out.
    private func mergeARP(generation gen: Int, addRefreshedSince before: [IPv4Address: MACAddress]? = nil) async {
        let table = await ARPTableMACProvider().macAddresses()
        guard isCurrent(gen) else { return }
        for (ip, mac) in table {
            if let known = byIP[ip] {
                guard known.mac != mac else { continue }
            } else {
                guard let before, before[ip] != mac else { continue }
            }
            var patch = DevicePatch(ip: ip)
            patch.mac = mac
            apply(patch, generation: gen)
        }
    }

    private var namesResolved: Set<IPv4Address> = []

    private func resolveNames(generation gen: Int) async {
        guard isCurrent(gen) else { return }
        let targets = byIP.keys.filter { !namesResolved.contains($0) }
        namesResolved.formUnion(targets)
        await forEachConcurrently(Array(targets), concurrency: 32) { [weak self] ip in
            guard let name = await ReverseDNS.lookup(ip) else { return }
            var patch = DevicePatch(ip: ip)
            patch.hostname = name
            await self?.apply(patch, generation: gen)
        }
    }

    private func scanCommonPorts(generation gen: Int) async {
        guard isCurrent(gen) else { return }
        let targets = byIP.keys.filter { !portScanned.contains($0) }.sorted()
        portScanned.formUnion(targets)
        let ports = CommonPorts.sortedPorts
        await forEachConcurrently(targets, concurrency: 8) { [weak self] ip in
            for await port in PortScanner(concurrency: 64, timeout: .milliseconds(500)).scan(ip, ports: ports) {
                var patch = DevicePatch(ip: ip)
                patch.openPorts = [port]
                await self?.apply(patch, generation: gen)
            }
            await self?.enqueueBanners(ip, generation: gen)
        }
    }

    // MARK: Enrichment

    /// Grabs HTTP/SSH banners for a device's open ports in the background (bounded by `bannerLimiter`).
    private func enqueueBanners(_ ip: IPv4Address, generation gen: Int) {
        guard isCurrent(gen), let device = byIP[ip], !device.isSelf else { return }
        let ports = device.openPorts.map(\.port)
        guard !ports.isEmpty else { return }
        let limiter = bannerLimiter
        let id = UUID()
        bannerTasks[id] = Task { [weak self] in
            await limiter.wait()
            let patch = Task.isCancelled ? nil : await ServiceBanners.probe(ip, openPorts: ports)
            await limiter.signal()
            guard let self else { return }
            self.bannerTasks[id] = nil
            if let patch, !Task.isCancelled { self.apply(patch, generation: gen, weak: true) }
        }
    }

    private var netbiosQueried: Set<IPv4Address> = []
    private var localNamesQueried: Set<IPv4Address> = []
    /// Source-specific evidence per device (e.g. "Name from router DNS"), shown with the fingerprint reasons.
    private var identificationNotes: [IPv4Address: [String]] = [:]
    /// Manufacturer/model the fingerprint filled in, so they aren't later counted as evidence.
    private var fingerprintFills: [IPv4Address: (manufacturer: String?, model: String?)] = [:]

    /// Fingerprints a device (see `Fingerprint`): records confidence and reasons, fills an empty
    /// manufacturer/model when reasonably sure, and overrides the classifier's kind when sure.
    private func identify(_ device: inout Device) {
        var probe = device
        if let filled = fingerprintFills[device.ip] {
            if filled.manufacturer != nil, probe.manufacturer == filled.manufacturer { probe.manufacturer = nil }
            if filled.model != nil, probe.model == filled.model { probe.model = nil }
        }
        let id = Fingerprint.identify(probe, gateway: gateway, notes: identificationNotes[device.ip] ?? [])
        device.confidence = id.confidence
        device.identificationReasons = id.reasons
        if id.confidence >= 0.5 {
            var fills = fingerprintFills[device.ip] ?? (nil, nil)
            if probe.manufacturer == nil, let m = id.manufacturer {
                device.manufacturer = m
                fills.manufacturer = m
            }
            let placeholder = probe.model.map(Fingerprint.placeholderModels.contains) ?? false
            if probe.model?.isEmpty ?? true || (placeholder && id.confidence >= 0.8), let m = id.model {
                device.model = m
                fills.model = m
            }
            fingerprintFills[device.ip] = fills
        }
        if device.ip == gateway {
            device.kind = .router
        } else if let k = id.kind, id.confidence >= 0.6 || (device.kind == .unknown && id.confidence >= 0.45) {
            device.kind = k
        }
    }

    private func addNote(_ note: String, for ip: IPv4Address) {
        var notes = identificationNotes[ip] ?? []
        guard !notes.contains(note) else { return }
        notes.append(note)
        identificationNotes[ip] = notes
    }

    /// Host names from the LAN's own name services (router DNS, mDNS, LLMNR), for every device
    /// not yet asked. Fills empty hostnames only, so Bonjour/system names keep priority.
    private func resolveLocalNames(_ iface: NetworkInterfaceInfo, generation gen: Int) async {
        guard isCurrent(gen) else { return }
        let targets = byIP.values.filter { !$0.isSelf && !localNamesQueried.contains($0.ip) }.map(\.ip)
        guard !targets.isEmpty else { return }
        localNamesQueried.formUnion(targets)
        var servers: [IPv4Address] = iface.gateway.map { [$0] } ?? []
        let inSubnet = Set(iface.subnet.scanHosts())
        for s in await Task.detached(operation: { DNSConfig.current().servers }).value {
            if let ip = IPv4Address(s), inSubnet.contains(ip), !servers.contains(ip) { servers.append(ip) }
        }
        guard isCurrent(gen) else { return }
        let names = await LocalDNS.lookup(targets, dnsServers: servers, interfaceAddress: iface.address)
        guard isCurrent(gen) else { return }
        for (ip, found) in names {
            guard let (name, source) = LocalDNS.best(found) else { continue }
            addNote("Hostname “\(name)” via \(source.rawValue)", for: ip)
            var patch = DevicePatch(ip: ip)
            patch.hostname = name
            apply(patch, generation: gen, weak: true)
        }
    }

    /// Model/firmware the gateway reveals without login (e.g. Netgear's currentsetting.htm).
    private func probeGateway(_ iface: NetworkInterfaceInfo, generation gen: Int) async {
        guard isCurrent(gen), let gw = iface.gateway, let info = await GatewayInfo.probe(gw) else { return }
        guard isCurrent(gen) else { return }
        for note in info.evidence { addNote(note, for: gw) }
        apply(info.patch, generation: gen, weak: true)
    }

    /// NetBIOS node status for every device not yet asked (32 at a time, 600 ms timeout each).
    private func queryNetBIOS(generation gen: Int) async {
        guard isCurrent(gen) else { return }
        let targets = byIP.values.filter { !$0.isSelf && !netbiosQueried.contains($0.ip) }.map(\.ip)
        netbiosQueried.formUnion(targets)
        await forEachConcurrently(targets, concurrency: 32) { [weak self] ip in
            guard let status = await NetBIOS.nodeStatus(ip) else { return }
            await self?.applyNetBIOS(status, ip: ip, generation: gen)
        }
    }

    private func applyNetBIOS(_ status: NetBIOS.NodeStatus, ip: IPv4Address, generation gen: Int) {
        guard isCurrent(gen), let device = byIP[ip] else { return }
        var patch = DevicePatch(ip: ip)
        patch.name = status.computerName
        patch.osHint = NetBIOS.osHint(status, vendor: device.manufacturer ?? device.vendor)
        if status.computerName?.hasPrefix("DESKTOP-") == true || status.computerName?.hasPrefix("LAPTOP-") == true {
            patch.kind = .computer
        }
        apply(patch, generation: gen, weak: true)
    }

    // MARK: Preview

    /// A static store showing `devices` as given: it never scans and writes nothing to disk.
    /// For previews and screenshots (see `ScanStore.preview`).
    convenience init(
        previewDevices devices: [Device], interface: NetworkInterfaceInfo, history: SharedHistory,
        lastScanFinishedAt: Date?, fullScanProgress: [IPv4Address: Double] = [:]
    ) {
        self.init(interface: interface, history: history)
        isPreview = true
        self.devices = devices
        self.lastScanFinishedAt = lastScanFinishedAt
        self.fullScanProgress = fullScanProgress
        onlineCount = devices.count(where: \.isOnline)
        offlineCount = devices.count - onlineCount
        updateStatus()
    }
}

/// A counting semaphore for async tasks.
private actor AsyncLimiter {
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(_ limit: Int) { available = limit }

    func wait() async {
        if available > 0 {
            available -= 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func signal() {
        if waiters.isEmpty { available += 1 } else { waiters.removeFirst().resume() }
    }
}
