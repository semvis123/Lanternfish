import AppKit
import LanternfishKit
import SwiftUI

/// Menu bar icon: the lanternfish (lights lit while scanning) and, optionally, the number of
/// devices online across all networks.
struct MenuBarLabel: View {
    let hub: NetworkHub
    @AppStorage(AppSettings.menuBarShowsCountKey) private var showCount = true

    var body: some View {
        let online = hub.totalOnline
        HStack(spacing: 3) {
            Image(nsImage: LanternfishGlyph.menuBarImage(lit: hub.isAnyScanning))
            if showCount, online > 0 {
                Text("\(online)")
                    .monospacedDigit()
            }
        }
        .mainWindowOpener()
        .accessibilityLabel("Lanternfish, \(online) devices online")
    }
}

/// The menu bar extra's window: one section per connected network (status and online devices),
/// then rescan-all and app actions.
struct MenuBarContentView: View {
    let hub: NetworkHub
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let stores = hub.stores.isEmpty ? [hub.placeholder] : hub.stores
        // Fewer rows per network when there are several, so the window stays menu-sized.
        let cap = stores.count > 1 ? 8 : 12
        let watched = AppServices.shared.watch.entries
        VStack(alignment: .leading, spacing: 0) {
            if !watched.isEmpty {
                MenuBarWatchSection(entries: watched, hub: hub)
                Divider().padding(.horizontal, 8)
            }
            ForEach(stores, id: \.menuID) { store in
                MenuBarNetworkSection(store: store, hub: hub, maxDevices: cap)
                Divider().padding(.horizontal, 8)
            }
            VStack(spacing: 0) {
                MenuBarRow(action: { hub.rescanAll() }) {
                    HStack {
                        Label(stores.count > 1 ? "Rescan All Networks" : "Rescan", systemImage: "arrow.clockwise")
                        Spacer()
                        if hub.isAnyScanning {
                            ProgressView().controlSize(.mini)
                            Text("Scanning…").foregroundStyle(.secondary)
                        } else {
                            Text("⌘R").foregroundStyle(.tertiary)
                        }
                    }
                }
                .disabled(hub.isAnyScanning)
                .keyboardShortcut("r")
                MenuBarRow(action: { MainWindow.show() }) {
                    Label("Open Lanternfish", systemImage: "macwindow")
                }
                MenuBarRow(action: { AirwavesWindow.show() }) {
                    ShortcutLabel("Airwaves…", systemImage: "wifi", shortcut: AirwavesWindow.shortcutLabel)
                }
            }
            .padding(.vertical, 5)
            Divider().padding(.horizontal, 8)
            VStack(spacing: 0) {
                MenuBarRow(action: {
                    NSApp.activate()
                    openSettings()
                }) {
                    ShortcutLabel("Settings…", systemImage: "gearshape", shortcut: "⌘,")
                }
                .keyboardShortcut(",")
                MenuBarRow(action: { NSApp.terminate(nil) }) {
                    ShortcutLabel("Quit Lanternfish", systemImage: "power", shortcut: "⌘Q")
                }
                .keyboardShortcut("q")
            }
            .padding(.vertical, 5)
        }
        .frame(width: 320)
        .labelStyle(MenuBarLabelStyle())
    }
}

extension ScanStore {
    fileprivate var menuID: String { interfaceID ?? "none" }
}

extension NetworkHub {
    /// Shows `store`'s live network in the main window. The menu bar lists live devices, so a
    /// window browsing a saved network switches back first.
    fileprivate func showLive(_ store: ScanStore) {
        if store.isViewingOtherNetwork { store.viewedNetworkID = nil }
        show(store)
    }
}

/// One network: header (interface, name, counts, last scan) and its online devices.
private struct MenuBarNetworkSection: View {
    let store: ScanStore
    let hub: NetworkHub
    let maxDevices: Int

    /// Online devices of the scanned (live) network, new ones first — even while the main
    /// window browses a saved network.
    private var onlineDevices: [Device] {
        let online = store.liveDevices
        return online.filter(\.isNew) + online.filter { !$0.isNew }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 8)
            deviceList(onlineDevices)
                .padding(.bottom, 6)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: store.selectedInterface?.symbolName ?? "network")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(Color.accentColor.gradient, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(networkName)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if store.isScanning {
                        ProgressView().controlSize(.mini)
                    }
                }
                Text(counts)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                TimelineView(.periodic(from: .now, by: 30)) { _ in
                    Text(lastScanText)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .help(
            store.selectedInterface.map {
                "\($0.displayName) (\($0.name)) · \($0.address.description) · \($0.subnet.description)"
            } ?? "")
    }

    private var networkName: String {
        if let net = store.currentNetwork { return net.shortName }
        if let iface = store.selectedInterface { return iface.subnet.description }
        return "Not Connected"
    }

    private var counts: String {
        // The main window browses a saved network: only the live network's online count is known here.
        guard !store.isViewingOtherNetwork else { return "\(store.liveDevices.count) online" }
        var parts = ["\(store.onlineCount) online"]
        if store.offlineCount > 0 { parts.append("\(store.offlineCount) offline") }
        return parts.joined(separator: " · ")
    }

    private var lastScanText: String {
        let iface = store.selectedInterface.map { "\($0.displayName) · " } ?? ""
        if store.isScanning { return iface + "Scanning…" }
        guard let last = store.lastScanFinishedAt else {
            return store.selectedInterface == nil ? "Connect to a network to scan" : iface + "Not scanned yet"
        }
        let minutes = AppSettings.autoScanMinutes
        let scanned = "Scanned \(RelativeTime.full(last))"
        return iface + (minutes > 0 ? "\(scanned) · every \(minutes) min" : scanned)
    }

    // MARK: Devices

    @ViewBuilder
    private func deviceList(_ devices: [Device]) -> some View {
        if devices.isEmpty {
            if store.selectedInterface != nil {
                Text(store.isScanning ? "Looking for devices…" : "No devices online")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
        } else {
            VStack(spacing: 0) {
                ForEach(devices.prefix(maxDevices)) { d in
                    MenuBarRow(action: { select(d) }) { MenuBarDeviceRow(device: d) }
                }
                if devices.count > maxDevices {
                    MenuBarRow(action: { hub.showLive(store) }) {
                        HStack {
                            Label("Show All…", systemImage: "ellipsis.circle")
                            Spacer()
                            Text("\(devices.count - maxDevices) more").foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
    }

    private func select(_ device: Device) {
        hub.showLive(store)
        Router.shared.pendingSelection = PendingSelection(device: device, interfaceID: store.interfaceID)
    }
}

private struct MenuBarDeviceRow: View {
    let device: Device

    var body: some View {
        HStack(spacing: 8) {
            DeviceIconView(device: device, size: 20)
            Text(device.listName)
                .lineLimit(1)
                .truncationMode(.tail)
            if device.isNew { NewBadge() }
            if device.isSelf { ThisMacTag() }
            Spacer(minLength: 8)
            Text(device.ip.description)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .fixedSize()
        }
    }
}

/// Watched devices of every connected network: status dot, latency and 24 h uptime.
private struct MenuBarWatchSection: View {
    let entries: [WatchMonitor.Entry]
    let hub: NetworkHub

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Watching")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                let down = entries.count { $0.status == .down }
                if down > 0 {
                    Text("\(down) offline")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.red)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 4)
            ForEach(entries.prefix(8)) { e in
                MenuBarRow(action: { select(e) }) { MenuBarWatchRow(entry: e) }
            }
        }
        .padding(.bottom, 6)
    }

    private func select(_ e: WatchMonitor.Entry) {
        hub.showLive(e.store)
        Router.shared.pendingSelection = PendingSelection(device: e.device, interfaceID: e.store.interfaceID)
    }
}

private struct MenuBarWatchRow: View {
    let entry: WatchMonitor.Entry

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(entry.status.color)
                .frame(width: 8, height: 8)
                .frame(width: 20)
            Text(entry.device.listName)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            Group {
                switch entry.status {
                case .up: Text(entry.rtt.map(PingFormat.rtt) ?? "—")
                case .down: Text("Offline").foregroundStyle(.red)
                case .unknown: NoValue()
                }
            }
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .fixedSize()
            Text(entry.uptime24h.map(Uptime.format) ?? "—")
                .monospacedDigit()
                .foregroundStyle(.tertiary)
                .frame(width: 46, alignment: .trailing)
                .help("Uptime over the last 24 hours")
        }
        .help("\(entry.device.listName) · \(entry.device.ip.description) · \(entry.status.label)")
    }
}

/// A full-width menu-style row with a hover highlight.
private struct MenuBarRow<Content: View>: View {
    let action: () -> Void
    @ViewBuilder let content: Content
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .frame(minHeight: 24)
                .contentShape(Rectangle())
                .background {
                    if hovering, isEnabled {
                        RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.quaternary)
                    }
                }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .onHover { hovering = $0 }
    }
}

/// A label with its keyboard shortcut at the trailing edge.
private struct ShortcutLabel: View {
    let title: String
    let systemImage: String
    let shortcut: String

    init(_ title: String, systemImage: String, shortcut: String) {
        self.title = title
        self.systemImage = systemImage
        self.shortcut = shortcut
    }

    var body: some View {
        HStack {
            Label(title, systemImage: systemImage)
            Spacer()
            Text(shortcut).foregroundStyle(.tertiary)
        }
    }
}

private struct MenuBarLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.icon
                .foregroundStyle(.secondary)
                .frame(width: 20)
            configuration.title
        }
    }
}
