import AppKit
import LanternfishKit
import SwiftUI

/// The main window: shows the hub's displayed network. Switching interfaces swaps the store
/// instantly (no rescan). Selection and search start fresh per network; sort order, the
/// inspector and each network's map viewport are window state and survive the switch.
struct MainWindowView: View {
    let hub: NetworkHub
    @Bindable private var router = Router.shared
    @State private var sortOrder = [KeyPathComparator(\Device.ip)]
    @SceneStorage("MainWindow.showInspector") private var showInspector = false
    @State private var maps = MapControllers()

    var body: some View {
        let store = hub.displayedStore
        let map = maps.controller(for: store)
        ContentView(
            store: store, hub: hub, sortOrder: $sortOrder, showInspector: $showInspector,
            mapController: map
        )
        .id(ObjectIdentifier(store))
        .onAppear(perform: followPendingSelection)
        .onChange(of: router.pendingSelection) { followPendingSelection() }
        .commandPalette(hub: hub)
        .focusedSceneValue(\.sceneRefresh, router.refreshOverride ?? hub.rescanRefresh)
        .focusedSceneValue(
            \.mainWindow,
            MainWindowActions(
                showInspector: $showInspector,
                map: router.viewMode == .map ? map : nil)
        )
        // A ⌘K request must not linger and pop the palette up the next time the window opens.
        .onDisappear { router.showCommandPalette = false }
    }

    /// A device on another network was picked (menu bar, notification): show that network.
    private func followPendingSelection() {
        guard let id = router.pendingSelection?.interfaceID, hub.store(for: id) != nil,
            id != hub.displayedStore.interfaceID
        else { return }
        hub.displayedInterfaceID = id
    }
}

/// One map controller per interface, kept while the window is open: each network keeps its
/// viewport when you switch views or networks and come back.
@MainActor
private final class MapControllers {
    private var byInterface: [String: MapController] = [:]

    func controller(for store: ScanStore) -> MapController {
        let key = store.interfaceID ?? "none"
        if let c = byInterface[key] { return c }
        let c = MapController()
        byInterface[key] = c
        return c
    }
}

struct ContentView: View {
    @Bindable var store: ScanStore
    let hub: NetworkHub
    @Binding var sortOrder: [KeyPathComparator<Device>]
    @Binding var showInspector: Bool
    let mapController: MapController

    @State private var selection: IPv4Address?
    @State private var searchText = ""
    @State private var didAutoSelect = false
    @State private var networkToRename: KnownNetwork?
    @State private var networkToForget: KnownNetwork?
    /// Ticks every 30 s while browsing a saved network, so "last seen …" stays current.
    @State private var clock = 0
    @Bindable private var router = Router.shared

    private var filteredDevices: [Device] {
        store.devices.filter { $0.matches(searchText) }.sorted(using: sortOrder)
    }

    private var selectedDevice: Device? {
        selection.flatMap { ip in store.devices.first { $0.id == ip } }
    }

    var body: some View {
        let rows = filteredDevices
        Group {
            switch router.viewMode {
            case .table:
                DeviceTable(devices: rows, selection: $selection, sortOrder: $sortOrder, store: store)
            case .map:
                NetworkMapView(devices: rows, selection: $selection, store: store, controller: mapController)
            }
        }
        .onCopyCommand(perform: copySelection)
        .overlay { emptyState(rows: rows) }
        .overlay { firstScanState(rows: rows) }
        .sheet(item: $router.serviceDetails) { ServiceDetailsView(target: $0) }
        .sheet(item: $router.traceroute) { TracerouteView(target: $0) }
        .sheet(item: $store.deviceToRename) { RenameSheet(device: $0, store: store) }
        .sheet(item: $networkToRename) { RenameSheet(network: $0, store: store) }
        .confirmationDialog(
            "Forget \(networkToForget?.displayName ?? "network")?",
            isPresented: Binding(
                get: { networkToForget != nil },
                set: { if !$0 { networkToForget = nil } }),
            presenting: networkToForget
        ) { net in
            Button("Forget Network", role: .destructive) { store.forgetNetwork(id: net.id) }
        } message: { net in
            Text("All \(net.devices.count) remembered devices, their names and notes will be removed.")
        }
        .safeAreaInset(edge: .top, spacing: 0) { otherNetworkBanner }
        .inspector(isPresented: $showInspector) {
            Group {
                if let d = selectedDevice {
                    DeviceInspector(device: d, store: store)
                        .id(d.id)
                } else {
                    ContentUnavailableView(
                        "No Selection", systemImage: "sidebar.right",
                        description: Text("Select a device to see its details."))
                }
            }
            .inspectorColumnWidth(min: 280, ideal: 320, max: 460)
        }
        .navigationTitle(title)
        .navigationSubtitle(subtitle)
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search devices")
        .toolbar { toolbar }
        .onChange(of: selection) { _, new in
            if new != nil { showInspector = true }
            if let d = selectedDevice, d.isNew { store.acknowledge(device: d) }
        }
        .onChange(of: store.viewedNetworkID) { selection = nil }
        .onChange(of: router.pendingSelection) { consumePendingSelection() }
        .onAppear {
            autoSelectIfRequested(rows)
            consumePendingSelection()
            runLaunchHooks()
        }
        .onChange(of: rows.count) {
            autoSelectIfRequested(rows)
            consumePendingSelection()
        }
        .task(id: store.isViewingOtherNetwork) {
            guard store.isViewingOtherNetwork else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                clock &+= 1
            }
        }
    }

    /// ⌘C with a device selected (and nothing else focused that copies): its IP address.
    private func copySelection() -> [NSItemProvider] {
        guard let d = selectedDevice else { return [] }
        PaletteToastCenter.shared.show("Copied IP Address", detail: d.ip.description, symbol: "doc.on.doc")
        return [NSItemProvider(object: d.ip.description as NSString)]
    }

    /// Launch hooks run once per app run, not on every network switch.
    @MainActor private static var ranLaunchHooks = false

    /// Debug aids:
    ///   LANTERNFISH_PING=<ip>                 start pinging that address.
    ///   LANTERNFISH_VIEW_NETWORK=<network id> browse that stored network.
    ///   LANTERNFISH_TRACE=<host>              open traceroute to that host.
    ///   LANTERNFISH_OVERVIEW=1                open the network overview.
    /// Plus the map and window snapshot hooks (`MapSnapshot`, `UISnapshot`).
    private func runLaunchHooks() {
        guard !Self.ranLaunchHooks else { return }
        Self.ranLaunchHooks = true
        let env = DebugEnv.values
        if let ip = env["LANTERNFISH_PING"].flatMap(IPv4Address.init) { store.startPing(ip) }
        if let id = env["LANTERNFISH_VIEW_NETWORK"] { store.viewedNetworkID = id }
        MapDebug.applyEnv()
        MapSnapshot.renderIfRequested(store: store)
        if let host = env["LANTERNFISH_TRACE"] { router.traceroute = TracerouteTarget(host: host) }
        if env["LANTERNFISH_OVERVIEW"] == "1" { router.showOverview = true }
        UISnapshot.scheduleIfRequested()
    }

    /// Selects `Router.pendingSelection` (notification click, menu bar) once that device is
    /// listed: by its history identity first (its IP may have changed, or it may be an offline
    /// row with a stand-in id), else by IP. Requests expire on their own (see `Router`).
    private func consumePendingSelection() {
        guard let pending = router.pendingSelection,
            pending.interfaceID == nil || pending.interfaceID == store.interfaceID
                || hub.store(for: pending.interfaceID) == nil
        else { return }
        let byKey = pending.historyKey.flatMap { key in store.devices.first { $0.historyKey == key } }
        guard let device = byKey ?? store.devices.first(where: { $0.id == pending.ip }) else { return }
        if !filteredDevices.contains(where: { $0.id == device.id }) { searchText = "" }
        selection = device.id
        showInspector = true
        router.pendingSelection = nil
    }

    /// Debug aid: LANTERNFISH_PREVIEW_SELECT=1 selects the first device once one exists;
    /// LANTERNFISH_PREVIEW_SELECT=<ip> selects that device once it appears.
    private func autoSelectIfRequested(_ rows: [Device]) {
        guard selection == nil, !didAutoSelect,
            let value = DebugEnv.values["LANTERNFISH_PREVIEW_SELECT"]
        else { return }
        let target: Device?
        if let ip = IPv4Address(value) {
            target = rows.first { $0.ip == ip }
        } else if value == "1" {
            target = rows.first { !$0.isSelf }
        } else {
            target = nil
        }
        guard let target else { return }
        didAutoSelect = true
        selection = target.id
    }

    private var title: String {
        if store.isViewingOtherNetwork, let net = store.displayedNetwork { return net.subnet }
        return store.selectedInterface?.subnet.description ?? "Lanternfish"
    }

    private var subtitle: String {
        _ = clock
        if store.isViewingOtherNetwork, let net = store.displayedNetwork {
            return "\(Self.deviceCount(net.devices.count)) · last seen \(RelativeTime.full(net.lastSeen))"
        }
        var parts = ["\(store.onlineCount) online"]
        if store.offlineCount > 0 { parts.append("\(store.offlineCount) offline") }
        if store.isScanning { parts.append("Scanning…") }
        return parts.joined(separator: " · ")
    }

    /// Shown while browsing a stored network: what you're looking at and the way back.
    @ViewBuilder
    private var otherNetworkBanner: some View {
        if store.isViewingOtherNetwork, let net = store.displayedNetwork {
            HStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundStyle(.secondary)
                RelativeTimeRefresh {
                    Text(
                        "Saved devices of **\(net.displayName)**, last seen \(RelativeTime.full(net.lastSeen)). Not scanning this network."
                    )
                    .lineLimit(1)
                    .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                Button("Show Current Network") { store.viewedNetworkID = nil }
                    .controlSize(.small)
            }
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.bar)
            .overlay(alignment: .bottom) { Divider() }
        }
    }

    private var networksMenu: some View {
        Menu {
            let current = store.currentNetwork
            let others = store.knownNetworks.filter { $0.id != current?.id }
            Section("Current Network") {
                if let current {
                    // Buttons, not Toggles: SwiftUI pushed menu-item state back into Toggle
                    // bindings when the list changed, switching networks without a click.
                    networkItem(current, live: true, checked: !store.isViewingOtherNetwork) {
                        store.viewedNetworkID = nil
                    }
                } else {
                    Text(store.selectedInterface == nil ? "Not connected" : "Identifying…")
                }
            }
            if !others.isEmpty {
                Section("Other Networks") {
                    ForEach(others) { net in
                        if let live = hub.store(forNetworkID: net.id), live !== store, let id = live.interfaceID {
                            // Scanned right now on another interface: switch to it.
                            networkItem(net, live: true, checked: false, via: live.interface?.displayName) {
                                hub.displayedInterfaceID = id
                            }
                        } else {
                            networkItem(net, live: false, checked: store.viewedNetworkID == net.id) {
                                store.viewedNetworkID = net.id
                            }
                        }
                    }
                }
            }
            Divider()
            Toggle(
                "Show Offline Devices",
                isOn: Binding(
                    get: { store.showOfflineDevices },
                    set: { hub.setShowOfflineDevices($0) }))
            Divider()
            if let net = store.displayedNetwork {
                Button("Rename Network…") { networkToRename = net }
                Button("Forget Network…", role: .destructive) { networkToForget = net }
            }
        } label: {
            Label(
                store.displayedNetwork?.shortName ?? "Networks",
                systemImage: store.isViewingOtherNetwork ? "clock.arrow.circlepath" : "network"
            )
            .labelStyle(.titleAndIcon)
        }
        .help(
            store.displayedNetwork.map { "\($0.displayName) — known networks and their remembered devices" }
                ?? "Known networks and their remembered devices")
    }

    private func networkItem(
        _ net: KnownNetwork, live: Bool, checked: Bool, via: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        let detail = networkDetail(net, live: live) + (via.map { " on \($0)" } ?? "")
        return Button(action: action) {
            if checked {
                Label {
                    Text(net.displayName)
                    Text(detail)
                } icon: {
                    Image(systemName: "checkmark")
                }
            } else {
                Text(net.displayName)
                Text(detail)
            }
        }
    }

    private func networkDetail(_ net: KnownNetwork, live: Bool) -> String {
        let count = Self.deviceCount(net.devices.count)
        return live ? "\(count) · live" : "\(count) · last seen \(RelativeTime.full(net.lastSeen))"
    }

    private static func deviceCount(_ n: Int) -> String { n == 1 ? "1 device" : "\(n) devices" }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if hub.interfaces.count > 1 {
            ToolbarItem(placement: .navigation) {
                Picker(
                    selection: Binding(
                        get: { store.interfaceID },
                        set: { hub.displayedInterfaceID = $0 })
                ) {
                    ForEach(hub.interfaces) { iface in
                        Label(iface.displayName, systemImage: iface.symbolName)
                            .tag(Optional(iface.id))
                    }
                } label: {
                    Label("Interface", systemImage: store.selectedInterface?.symbolName ?? "network")
                }
                .pickerStyle(.menu)
                .labelStyle(.titleAndIcon)
                .help(
                    store.selectedInterface.map {
                        "Showing \($0.displayName) (\($0.name)), \($0.address.description). All \(hub.interfaces.count) networks are scanned."
                    } ?? "Network interface")
            }
        }
        ToolbarItem(placement: .navigation) {
            networksMenu
        }
        ToolbarItem(placement: .principal) {
            Picker("View", selection: $router.viewMode) {
                Label("Table", systemImage: "tablecells").tag(Router.ViewMode.table)
                Label("Map", systemImage: "point.3.connected.trianglepath.dotted").tag(Router.ViewMode.map)
            }
            .pickerStyle(.segmented)
            .labelStyle(.iconOnly)
            .help("Show devices as a table or a map")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                router.showOverview.toggle()
            } label: {
                Label("Network Overview", systemImage: "info.circle")
            }
            .help("Network overview: internet, Wi-Fi, DNS, speed test")
            .popover(isPresented: $router.showOverview, arrowEdge: .bottom) {
                NetworkOverviewView(store: store)
            }
            AirwavesToolbarButton()
            if hub.isAnyScanning {
                LanternPulse(size: 16)
                    .padding(.horizontal, 3)
                    .help(hub.stores.count > 1 ? "Scanning networks…" : "Scanning…")
                    .transition(.opacity)
            }
            Button {
                hub.rescanAll()
            } label: {
                Label(hub.stores.count > 1 ? "Rescan All Networks" : "Rescan", systemImage: "arrow.clockwise")
            }
            .help(
                hub.isAnyScanning
                    ? "Scanning…"
                    : hub.stores.count > 1 ? "Rescan all networks (⌘R)" : "Rescan the network (⌘R)"
            )
            .disabled(hub.isAnyScanning)
            Button {
                showInspector.toggle()
            } label: {
                Label(showInspector ? "Hide Inspector" : "Show Inspector", systemImage: "sidebar.right")
            }
            .help(showInspector ? "Hide Inspector (⌥⌘I)" : "Show Inspector (⌥⌘I)")
        }
    }

    /// The first scan of this network has found nothing but this Mac yet: a larger radar over
    /// the (nearly empty) table or map. Fades away as soon as the first device answers.
    private func firstScanState(rows: [Device]) -> some View {
        let show =
            store.isScanning && store.lastScanFinishedAt == nil && !store.isViewingOtherNetwork
            && searchText.isEmpty && store.devices.allSatisfy(\.isSelf)
            && (router.viewMode == .table || rows.isEmpty)
        return ZStack {
            if show {
                ScanningPlaceholder(subnet: store.selectedInterface?.subnet.description)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        // Shown only if the sweep takes a moment, so a fast network doesn't flash it.
        .animation(.easeInOut(duration: 0.35).delay(show ? 0.6 : 0), value: show)
    }

    @ViewBuilder
    private func emptyState(rows: [Device]) -> some View {
        if rows.isEmpty {
            if !searchText.isEmpty, !store.devices.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else if store.devices.isEmpty, store.isViewingOtherNetwork {
                ContentUnavailableView("No Remembered Devices", systemImage: "clock.arrow.circlepath")
            } else if store.devices.isEmpty, store.isScanning {
                // A rescan that cleared everything: `firstScanState` covers the first scan.
                if store.lastScanFinishedAt != nil {
                    ScanningPlaceholder(subnet: store.selectedInterface?.subnet.description)
                }
            } else if store.devices.isEmpty {
                ContentUnavailableView {
                    Label("No Devices Found", systemImage: "network.slash")
                } description: {
                    Text("Make sure this Mac is connected to a network.")
                } actions: {
                    Button("Rescan") { hub.rescanAll() }
                        .disabled(hub.isAnyScanning)
                }
            }
        }
    }
}
