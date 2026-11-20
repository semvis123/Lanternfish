import AppKit
import LanternfishKit
import SwiftUI

/// Builds the palette's searchable items: devices of every network, commands, networks,
/// typed-host quick actions and per-device action lists.
@MainActor
struct PaletteCatalog {
    let hub: NetworkHub
    let model: CommandPaletteModel
    private var router: Router { .shared }

    private var stores: [ScanStore] { hub.stores.isEmpty ? [hub.placeholder] : hub.stores }

    func entries() -> [PaletteEntry] {
        devices() + commands() + networks()
    }

    // MARK: Devices

    private func devices() -> [PaletteEntry] {
        var out: [PaletteEntry] = []
        let displayed = hub.displayedStore
        for store in stores {
            let network = store.displayedNetwork?.id ?? store.interfaceID ?? "none"
            // Name the network only for devices that aren't in the window right now.
            let ifaceName = store === displayed ? nil : store.interface?.displayName
            for d in store.devices {
                let item = deviceItem(d, store: store, network: network, ifaceName: ifaceName)
                out.append(
                    PaletteEntry(
                        item, section: d.isOnline ? .devices : .offline,
                        extra: [
                            d.ip.description, d.mac?.description, d.hostname, d.customName, d.name, d.notes,
                            d.brandModel, d.vendor, d.osHint, d.webTitle, d.effectiveKind.label,
                            d.services.sorted().joined(separator: " "),
                            d.openPorts.map { p in p.service.map { "\(p.port) \($0)" } ?? String(p.port) }.joined(
                                separator: " "),
                        ], exactKeys: [d.ip.description, d.mac?.description, d.listName, d.hostname, d.customName]))
            }
        }
        return out
    }

    private func deviceItem(_ d: Device, store: ScanStore, network: String, ifaceName: String?) -> PaletteItem {
        let brand = d.brandModel ?? (d.effectiveKind == .unknown ? nil : d.effectiveKind.label)
        var subtitle = d.ip.description
        if let brand, brand != d.listName { subtitle += " · \(brand)" }
        if d.isSelf { subtitle += " · This Mac" }
        var hint: [String] = []
        if let ifaceName { hint.append(ifaceName) }
        if !d.isOnline, let seen = d.lastSeenShort { hint.append(seen) }
        if d.isNew { hint.append("New") }
        let id = "device:\(network):\(d.historyKey ?? d.mac?.description ?? d.ip.description)"
        return PaletteItem(
            id: id, title: d.listName, subtitle: subtitle,
            icon: .device(d.effectiveKind, dimmed: !d.isOnline),
            hint: hint.isEmpty ? nil : hint.joined(separator: " · "),
            verb: "Show",
            perform: { show(d, in: store) },
            actions: { deviceActions(d, store: store) })
    }

    private func show(_ d: Device, in store: ScanStore) {
        router.pendingSelection = PendingSelection(device: d, interfaceID: store.interfaceID)
    }

    /// The action sub-list: the device's `DeviceActionSet` (same as the context menus and the
    /// inspector), "Show" first, then one Service Details item per open port.
    func deviceActions(_ d: Device, store: ScanStore) -> [PaletteItem] {
        let set = DeviceActionSet(
            device: d, store: store,
            context: .init(
                showTitle: router.viewMode == .map ? "Show on Map" : "Show in Device List",
                showSubtitle: store === hub.displayedStore
                    ? nil : "Switches to \(store.interface?.displayName ?? "its network")",
                show: { show(d, in: store) }))
        func item(_ a: DeviceAction) -> PaletteItem {
            PaletteItem(
                id: "action:\(a.id)", title: a.title, subtitle: a.subtitle, icon: .symbol(a.symbol, a.tint),
                disabledReason: a.disabledReason, perform: a.perform)
        }
        var list: [PaletteItem] = []
        for a in set.all {
            list.append(item(a))
            list += a.alternates.map(item)
        }
        let ip = d.ip
        for port in d.openPorts {
            let name = port.service.map { "\(port.port) \($0)" } ?? "Port \(port.port)"
            list.append(
                PaletteItem(
                    id: "action:details:\(port.port)", title: "Service Details: \(name)",
                    subtitle: "Banner, TLS certificate and headers of \(ip):\(port.port)",
                    icon: .symbol("info.circle", .teal), disabledReason: store.unreachableReason
                ) {
                    router.serviceDetails = ServiceDetailsTarget(ip: ip, port: port)
                })
        }
        return list
    }

    // MARK: Commands

    private func command(
        _ id: String, _ title: String, _ symbol: String, _ tint: Color, subtitle: String? = nil,
        shortcut: String? = nil, hint: String? = nil, keywords: [String] = [],
        disabledReason: String? = nil,
        _ perform: @escaping @MainActor () -> Void
    ) -> PaletteEntry {
        PaletteEntry(
            PaletteItem(
                id: "cmd:\(id)", title: title, subtitle: subtitle, icon: .symbol(symbol, tint),
                hint: hint, shortcut: shortcut, keywords: keywords, disabledReason: disabledReason,
                perform: perform),
            section: .commands)
    }

    private func commands() -> [PaletteEntry] {
        let hub = hub
        let router = router
        let offline = hub.displayedStore.showOfflineDevices
        let multi = hub.stores.count > 1
        return [
            command(
                "rescan", multi ? "Rescan All Networks" : "Rescan Network", "arrow.clockwise", .blue,
                subtitle: multi ? "Scan all \(hub.stores.count) connected networks again" : "Scan the network again",
                shortcut: "⌘R", keywords: ["refresh", "reload", "scan", "discover"],
                disabledReason: hub.isAnyScanning ? "Scanning…" : nil
            ) { hub.rescanAll() },
            command(
                "view.table", "Switch to Table View", "tablecells", .indigo,
                hint: router.viewMode == .table ? "Current" : nil, keywords: ["list", "rows"]
            ) {
                router.viewMode = .table
            },
            command(
                "view.map", "Switch to Map View", "point.3.connected.trianglepath.dotted", .indigo,
                hint: router.viewMode == .map ? "Current" : nil, keywords: ["graph", "topology", "diagram"]
            ) {
                router.viewMode = .map
            },
            command(
                "overview", "Show Network Overview", "info.circle", .teal,
                subtitle: "Internet, public IP, Wi-Fi, DNS",
                keywords: ["internet", "public ip", "wifi", "dns", "gateway", "isp"]
            ) { router.showOverview = true },
            health(),
            command(
                "wifi", "Airwaves", "wifi", .blue,
                subtitle: "Nearby networks, channel graph and channel advice", shortcut: AirwavesWindow.shortcutLabel,
                keywords: ["wifi", "wi-fi", "wireless", "wlan", "ssid", "channel", "signal", "rssi", "analyzer"]
            ) {
                AirwavesWindow.show()
            },
            command(
                "speedtest", "Run Speed Test", "speedometer", .orange,
                subtitle: "Starts a speed test in the network overview",
                keywords: ["bandwidth", "download", "upload", "internet"]
            ) {
                router.pendingSpeedTest = true
                router.showOverview = true
            },
            command(
                "offline", offline ? "Hide Offline Devices" : "Show Offline Devices",
                offline ? "eye.slash" : "eye", .gray, subtitle: "Remembered devices that aren't online now",
                shortcut: "⇧⌘O", keywords: ["history", "remembered", "toggle"]
            ) {
                hub.setShowOfflineDevices(!offline)
            },
            command(
                "settings", "Settings…", "gearshape", .gray, shortcut: "⌘,",
                keywords: ["preferences", "notifications", "auto scan", "menu bar"]
            ) { [model] in
                model.openSettings?()
            },
        ]
    }

    /// "Network Health", with the displayed network's score.
    private func health() -> PaletteEntry {
        let report = HealthContext(store: hub.displayedStore).report
        let router = router
        return command(
            "health", "Network Health", "checkmark.shield.fill", report.isEmpty ? .green : report.grade.tint,
            subtitle: report.isEmpty
                ? "Security check of open ports, router and unknown devices"
                : "Score \(report.score) · \(report.grade.label). \(report.summary)",
            shortcut: HealthCommand.shortcutLabel,
            keywords: [
                "security", "score", "audit", "risk", "check", "safety", "vulnerability",
                "ports", "telnet", "upnp", "unknown devices",
            ]
        ) {
            router.showHealth = true
        }
    }

    // MARK: Networks

    private func networks() -> [PaletteEntry] {
        var out: [PaletteEntry] = []
        let hub = hub
        let displayed = hub.displayedStore
        if hub.stores.count > 1 {
            for s in hub.stores {
                guard let iface = s.interface, let id = s.interfaceID else { continue }
                var sub = "\(iface.name) · \(iface.address) · \(iface.subnet)"
                if let net = s.currentNetwork?.shortName, net != iface.subnet.description { sub += " · \(net)" }
                let current = s === displayed
                out.append(
                    PaletteEntry(
                        PaletteItem(
                            id: "net:iface:\(id)", title: "Show \(iface.displayName)", subtitle: sub,
                            icon: .symbol(iface.symbolName, .blue),
                            hint: current ? "Current" : "\(s.onlineCount) online",
                            keywords: ["switch", "interface", "network", iface.displayName],
                            perform: {
                                hub.displayedInterfaceID = id
                                hub.displayedStore.viewedNetworkID = nil
                            }), section: .networks))
            }
        }
        if displayed.isViewingOtherNetwork {
            out.append(
                PaletteEntry(
                    PaletteItem(
                        id: "net:current", title: "Show Current Network",
                        subtitle: displayed.currentNetwork?.displayName, icon: .symbol("network", .blue),
                        keywords: ["switch", "live", "back"], perform: { displayed.viewedNetworkID = nil }),
                    section: .networks))
        }
        let live = Set(hub.stores.compactMap(\.currentNetworkID))
        for net in displayed.knownNetworks where !live.contains(net.id) && displayed.viewedNetworkID != net.id {
            let n = net.devices.count
            out.append(
                PaletteEntry(
                    PaletteItem(
                        id: "net:saved:\(net.id)", title: "Browse \(net.displayName)",
                        subtitle:
                            "\(n == 1 ? "1 device" : "\(n) devices") · last seen \(RelativeTime.full(net.lastSeen))",
                        icon: .symbol("clock.arrow.circlepath", .gray), hint: "Saved",
                        keywords: ["switch", "network", "saved", "history", net.subnet],
                        perform: {
                            let s = hub.displayedStore
                            s.viewedNetworkID = net.id
                        }), section: .networks))
        }
        return out
    }

    // MARK: Typed host

    /// "Ping 1.2.3.4", "Traceroute to example.com", "Open http://…" for a query that looks like a host.
    func quickActions(for query: String) -> [PaletteItem] {
        guard let host = HostQuery.parse(query) else { return [] }
        let h = host.host
        var out: [PaletteItem] = []
        let router = router
        if case .ip(let ip) = host {
            let (store, device) = locate(ip)
            out.append(
                PaletteItem(
                    id: "quick:ping:\(h)", title: "Ping \(h)",
                    subtitle: device.map { "\($0.listName) · ICMP echo every second" } ?? "ICMP echo every second",
                    icon: .symbol("waveform.path.ecg", .green), verb: "Ping",
                    perform: { [model] in
                        store.startPing(ip)
                        if let device {
                            router.pendingSelection = PendingSelection(device: device, interfaceID: store.interfaceID)
                        } else {
                            model.hostPing = HostPingTarget(ip: ip, store: store)
                        }
                    }, isRecordable: false))
        }
        out.append(
            PaletteItem(
                id: "quick:trace:\(h)", title: "Traceroute to \(h)", subtitle: "Show every hop on the way",
                icon: .symbol("point.topleft.down.to.point.bottomright.curvepath", .orange), verb: "Trace",
                perform: { router.traceroute = TracerouteTarget(host: h) }, isRecordable: false))
        if let url = URL(string: "http://\(h)") {
            out.append(
                PaletteItem(
                    id: "quick:open:\(h)", title: "Open http://\(h)", subtitle: "In your default browser",
                    icon: .symbol("safari", .blue), verb: "Open",
                    perform: { DeviceActions.open(url) }, isRecordable: false))
        }
        return out
    }

    /// The store whose subnet holds `ip` (else the displayed one), and the device there if known.
    private func locate(_ ip: IPv4Address) -> (ScanStore, Device?) {
        for s in stores where !s.isViewingOtherNetwork {
            if let d = s.devices.first(where: { $0.ip == ip && $0.isOnline }) { return (s, d) }
        }
        for s in stores {
            guard let sub = s.interface?.subnet else { continue }
            let mask: UInt32 = sub.prefixLength == 0 ? 0 : ~UInt32(0) << (32 - sub.prefixLength)
            if ip.value & mask == sub.address.value & mask { return (s, nil) }
        }
        return (hub.displayedStore, nil)
    }
}
