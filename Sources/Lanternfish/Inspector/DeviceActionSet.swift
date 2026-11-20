import LanternfishKit
import SwiftUI

/// One thing you can do with a device (see `DeviceActionSet`).
struct DeviceAction: Identifiable {
    let id: String
    let title: String
    let symbol: String
    var tint: Color = .secondary
    var subtitle: String?
    /// Non-nil: the action is shown but disabled, and this explains why.
    var disabledReason: String?
    var isDestructive = false
    /// More targets for the same action (other web ports); menus show them in a submenu.
    var alternates: [DeviceAction] = []
    /// The page an "Open" action goes to.
    var url: URL?
    let perform: @MainActor () -> Void

    var isEnabled: Bool { disabledReason == nil }
}

/// Every action for a device, grouped, with availability — the single source for the table's
/// context menu, the map's context menu, the inspector and the ⌘K palette's action list.
///
/// Live actions (browser, ping, traceroute, port scan) need the device's network to be the one
/// being scanned; while browsing a saved network they're disabled with a reason. Ping and
/// traceroute aren't offered for this Mac itself.
@MainActor
struct DeviceActionSet {
    /// How the host reveals the device ("Show in Inspector" in the window, "Show on Map" in ⌘K).
    struct Context {
        var showTitle = "Show in Inspector"
        var showSubtitle: String?
        /// Reveals (selects) the device, switching the window to its network if needed.
        var show: @MainActor () -> Void
    }

    let groups: [[DeviceAction]]

    var all: [DeviceAction] { groups.flatMap { $0 } }

    func action(_ id: String) -> DeviceAction? { all.first { $0.id == id } }

    init(device d: Device, store: ScanStore, context: Context) {
        let ip = d.ip
        let reason = store.unreachableReason
        let preferred = d.preferredWebURL
        let show = context.show

        var groups: [[DeviceAction]] = []
        groups.append([
            DeviceAction(
                id: "show", title: context.showTitle, symbol: "scope", tint: .accentColor,
                subtitle: context.showSubtitle, perform: show)
        ])

        // Browser.
        if let preferred {
            let others = d.webURLs.map(\.url).filter { $0 != preferred }
            let offline = d.isOnline ? nil : "The device is offline; the page may not load"
            groups.append([
                DeviceAction(
                    id: "open", title: "Open in Browser", symbol: "safari", tint: .blue,
                    subtitle: [preferred.absoluteString, offline].compactMap { $0 }.joined(separator: " — "),
                    disabledReason: reason,
                    alternates: others.map { url in
                        DeviceAction(
                            id: "open:\(url.absoluteString)", title: "Open \(url.absoluteString)",
                            symbol: "safari", tint: .blue, subtitle: url.absoluteString, disabledReason: reason,
                            url: url, perform: { DeviceActions.open(url) })
                    },
                    url: preferred, perform: { DeviceActions.open(preferred) })
            ])
        }

        // Live diagnostics.
        var live: [DeviceAction] = []
        if !d.isSelf {
            if store.pingSessions[ip]?.isRunning == true {
                live.append(
                    DeviceAction(
                        id: "stopping", title: "Stop Ping", symbol: "stop.fill",
                        disabledReason: reason, perform: { store.stopPing(ip) }))
            } else {
                live.append(
                    DeviceAction(
                        id: "ping", title: "Ping", symbol: "waveform.path.ecg", tint: .green,
                        subtitle: "Ping \(ip) every second", disabledReason: reason
                    ) {
                        store.startPing(ip)
                        show()
                    })
            }
            live.append(
                DeviceAction(
                    id: "trace", title: "Traceroute", symbol: "point.topleft.down.to.point.bottomright.curvepath",
                    tint: .orange, subtitle: "Hops between this Mac and \(ip)", disabledReason: reason
                ) {
                    Router.shared.traceroute = TracerouteTarget(host: ip.description)
                })
        }
        if let wake = WakeController.availability(of: d, in: store) {
            live.append(
                DeviceAction(
                    id: "wake", title: d.isOnline ? "Wake (Send Magic Packet)" : "Wake", symbol: "power",
                    tint: .yellow, subtitle: wake.canWake ? wake.help : nil,
                    disabledReason: wake.canWake ? nil : wake.help
                ) {
                    WakeController.shared.wake(d, in: store)
                })
        }
        if store.fullScanProgress[ip] != nil {
            live.append(
                DeviceAction(
                    id: "stopscan", title: "Stop Port Scan", symbol: "stop.circle",
                    disabledReason: reason, perform: { store.cancelFullScan(ip) }))
        } else {
            live.append(
                DeviceAction(
                    id: "scanports", title: "Scan All Ports", symbol: "magnifyingglass", tint: .purple,
                    subtitle: "Probe all 65,535 TCP ports", disabledReason: reason
                ) {
                    store.scanAllPorts(ip)
                    show()
                })
        }
        groups.append(live)

        // Keeping track.
        let watch = AppServices.shared.watch
        let watched = watch.isWatched(d, in: store)
        groups.append([
            DeviceAction(
                id: watched ? "unwatch" : "watch", title: watched ? "Stop Watching" : "Watch",
                symbol: watched ? "eye.slash" : "eye", tint: .indigo,
                subtitle: watched ? nil : "Alert when it goes offline or comes back"
            ) {
                watch.setWatched(!watched, device: d, store: store)
            },
            DeviceAction(id: "rename", title: "Rename…", symbol: "pencil") {
                if store !== AppServices.shared.hub.displayedStore { AppServices.shared.hub.show(store) }
                store.deviceToRename = d
            },
        ])

        // Copy.
        var copy = [
            DeviceAction(id: "copyip", title: "Copy IP Address", symbol: "doc.on.doc", subtitle: ip.description) {
                DeviceActions.copy(ip.description, what: "IP Address")
            }
        ]
        if let mac = d.mac {
            copy.append(
                DeviceAction(id: "copymac", title: "Copy MAC Address", symbol: "doc.on.doc", subtitle: mac.description)
                {
                    DeviceActions.copy(mac.description, what: "MAC Address")
                })
        }
        let name = d.listName
        copy.append(
            DeviceAction(id: "copyname", title: "Copy Name", symbol: "doc.on.doc", subtitle: name) {
                DeviceActions.copy(name, what: "Name")
            })
        if let h = d.hostname, !h.isEmpty {
            copy.append(
                DeviceAction(id: "copyhost", title: "Copy Hostname", symbol: "doc.on.doc", subtitle: h) {
                    DeviceActions.copy(h, what: "Hostname")
                })
        }
        if let url = preferred {
            copy.append(
                DeviceAction(id: "copyurl", title: "Copy URL", symbol: "link", subtitle: url.absoluteString) {
                    DeviceActions.copy(url.absoluteString, what: "URL")
                })
        }
        groups.append(copy)

        if !d.isOnline, d.historyKey != nil {
            groups.append([
                DeviceAction(
                    id: "forget", title: "Forget Device", symbol: "trash", tint: .red,
                    subtitle: "Remove it and its name and notes from this network's history",
                    isDestructive: true
                ) {
                    store.forgetDevice(d)
                }
            ])
        }
        self.groups = groups.filter { !$0.isEmpty }
    }
}

/// A device action set as SwiftUI menu items (context menus).
struct DeviceActionMenuItems: View {
    let actions: DeviceActionSet
    /// Action ids to leave out (e.g. "show" where the device already is what's shown).
    var excluding: Set<String> = []

    var body: some View {
        let groups = actions.groups.map { $0.filter { !excluding.contains($0.id) } }.filter { !$0.isEmpty }
        ForEach(Array(groups.enumerated()), id: \.offset) { i, group in
            if i > 0 { Divider() }
            ForEach(group) { a in DeviceActionMenuItem(action: a) }
        }
    }
}

/// One action as a menu item (a submenu when it has alternates).
private struct DeviceActionMenuItem: View {
    let action: DeviceAction

    var body: some View {
        if action.alternates.isEmpty {
            button(action, title: action.title)
        } else {
            Menu {
                button(action, title: action.url.map { "Open \($0.absoluteString)" } ?? action.title)
                ForEach(action.alternates) { button($0, title: $0.title) }
            } label: {
                Label(action.title, systemImage: action.symbol)
            }
            .disabled(!action.isEnabled)
            .help(action.disabledReason ?? "")
        }
    }

    private func button(_ a: DeviceAction, title: String) -> some View {
        Button(title, systemImage: a.symbol, role: a.isDestructive ? .destructive : nil) { a.perform() }
            .disabled(!a.isEnabled)
            .help(a.disabledReason ?? a.subtitle ?? "")
    }
}
