import LanternfishKit
import SwiftUI

struct DeviceTable: View {
    let devices: [Device]
    @Binding var selection: IPv4Address?
    @Binding var sortOrder: [KeyPathComparator<Device>]
    let store: ScanStore

    @SceneStorage("DeviceTableColumns") private var columnCustomization = TableColumnCustomization<Device>()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let arrivals = store.arrivals
        Table(devices, selection: $selection, sortOrder: $sortOrder, columnCustomization: $columnCustomization) {
            TableColumn("Name", value: \.nameSortKey) { d in
                NameCell(device: d, watch: watchStatus(d))
                    .arrivalHighlight(d, arrivals, edge: .leading)
            }
            .width(min: 170, ideal: 230)
            .customizationID("name")
            .disabledCustomizationBehavior(.visibility)

            TableColumn("IP Address", value: \.ip) { d in
                Text(d.ip.description)
                    .monospacedDigit()
                    .offlineDimmed(d)
                    .arrivalHighlight(d, arrivals)
            }
            .width(min: 100, ideal: 112)
            .customizationID("ip")

            TableColumn("Brand / Model", value: \.brandSortKey) { d in
                BrandCell(device: d)
                    .offlineDimmed(d)
                    .arrivalHighlight(d, arrivals)
            }
            .width(min: 110, ideal: 190)
            .customizationID("brand")

            TableColumn("MAC Address", value: \.macSortKey) { d in
                MACCell(device: d)
                    .offlineDimmed(d)
                    .arrivalHighlight(d, arrivals)
            }
            .width(min: 120, ideal: 145)
            .customizationID("mac")

            TableColumn("Open Ports", value: \.portCount) { d in
                PortChips(ports: d.openPorts, host: d.ip, reachable: store.canReachDevices)
                    .offlineDimmed(d)
                    .arrivalHighlight(d, arrivals)
            }
            .width(min: 120, ideal: 215)
            .customizationID("ports")

            TableColumn("Response", value: \.responseSortKey) { d in
                ResponseCell(device: d, store: store)
                    .arrivalHighlight(d, arrivals, alignment: .trailing, edge: .trailing)
            }
            .width(min: 56, ideal: 72, max: 140)
            .alignment(.trailing)
            .customizationID("response")

            TableColumn("Today") { d in
                PresenceTodayCell(presence: record(d)?.presence ?? [])
                    .offlineDimmed(d)
                    .arrivalHighlight(d, arrivals, edge: .trailing)
            }
            .width(min: 60, ideal: 96, max: 200)
            .customizationID("presenceToday")
            .defaultVisibility(.hidden)
        }
        // Rows found during a scan fade in; the first load, sorting and idle refreshes don't animate.
        .animation(store.isScanning && !reduceMotion ? .default : nil, value: devices.map(\.id))
        .contextMenu(forSelectionType: IPv4Address.self) { ids in
            if let ip = ids.first, let d = devices.first(where: { $0.id == ip }) {
                DeviceMenuItems(device: d, store: store) { selection = ip }
            }
        } primaryAction: { ids in
            // Double-click / Return: open the device's web page when it's reachable.
            guard let ip = ids.first, let d = devices.first(where: { $0.id == ip }) else { return }
            if store.canReachDevices, let url = d.preferredWebURL { DeviceActions.open(url) }
        }
    }
}

extension DeviceTable {
    fileprivate func record(_ d: Device) -> KnownDevice? {
        d.historyKey.flatMap { store.displayedNetwork?.devices[$0] }
    }

    /// nil: not watched; else the monitor's status (unknown while browsing another network).
    fileprivate func watchStatus(_ d: Device) -> WatchStatus? {
        guard record(d)?.isWatched == true else { return nil }
        return AppServices.shared.watch.live(for: d, in: store)?.state.status ?? .unknown
    }
}

extension View {
    fileprivate func offlineDimmed(_ d: Device) -> some View {
        opacity(d.isOnline ? 1 : 0.5)
    }

    /// The soft accent wash a row gets for a moment when its device arrives during a scan.
    /// Each cell draws its part, bleeding into the gaps between columns so they read as one band.
    fileprivate func arrivalHighlight(
        _ d: Device, _ arrivals: DeviceArrivals, alignment: Alignment = .leading,
        edge: HorizontalEdge? = nil
    ) -> some View {
        modifier(ArrivalHighlight(device: d, arrivals: arrivals, alignment: alignment, edge: edge))
    }
}

/// Reads only the arrivals (not the store), so an arrival re-renders these small wrappers and not
/// the cells inside them. Each wrapper runs one short task when its device has just arrived.
private struct ArrivalHighlight: ViewModifier {
    let device: Device
    let arrivals: DeviceArrivals
    let alignment: Alignment
    /// The row's first or last column: rounds that end of the band.
    let edge: HorizontalEdge?
    @State private var lit = false

    /// Gap between columns the band bleeds into (half on each side of a cell).
    private static let bleed: CGFloat = 17

    func body(content: Content) -> some View {
        let start = arrivals.highlightStart(for: device)
        content
            .frame(maxWidth: .infinity, alignment: alignment)
            .background {
                if lit {
                    band
                        .transition(.opacity)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .task(id: start) {
                guard let start else {
                    lit = false
                    return
                }
                let remaining = DeviceArrivals.highlightDuration - Date().timeIntervalSince(start)
                guard remaining > 0.3 else { return }
                withAnimation(.easeOut(duration: 0.25)) { lit = true }
                try? await Task.sleep(for: .seconds(max(0.2, remaining - 0.7)))
                withAnimation(.easeInOut(duration: 0.7)) { lit = false }
            }
    }

    private var band: some View {
        let r: CGFloat = 5
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: edge == .leading ? r : 0,
            bottomLeadingRadius: edge == .leading ? r : 0,
            bottomTrailingRadius: edge == .trailing ? r : 0,
            topTrailingRadius: edge == .trailing ? r : 0)
        return
            shape
            .fill(Color.accentColor.opacity(0.13))
            .padding(.leading, edge == .leading ? -4 : -Self.bleed / 2)
            .padding(.trailing, edge == .trailing ? -4 : -Self.bleed / 2)
            .padding(.vertical, -3)
    }
}

/// A device's context menu (table rows), built from `DeviceActionSet`.
struct DeviceMenuItems: View {
    let device: Device
    let store: ScanStore
    /// Selects the device (which reveals the inspector).
    var select: (() -> Void)?

    var body: some View {
        DeviceActionMenuItems(
            actions: DeviceActionSet(
                device: device, store: store,
                context: .init(show: { select?() })))
    }
}

private struct NameCell: View {
    let device: Device
    /// Watch status when the device is watched.
    var watch: WatchStatus?

    var body: some View {
        HStack(spacing: 7) {
            DeviceIconView(device: device, size: 18, dimmed: !device.isOnline)
                .help(device.isOnline ? device.effectiveKind.label : "\(device.effectiveKind.label) — offline")
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if device.hasRealName {
                    Text(device.displayName)
                        .foregroundStyle(device.isOnline ? .primary : .tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else {
                    Text(device.fallbackLabel)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if device.isSelf {
                    ThisMacTag()
                }
                if device.isNew {
                    NewBadge()
                }
                if let watch {
                    WatchIndicator(status: watch)
                }
                if device.notes?.isEmpty == false {
                    Image(systemName: "note.text")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .help(device.notes ?? "")
                }
            }
        }
        .help(device.hasRealName ? device.displayName : "\(device.fallbackLabel) — no name announced")
    }
}

private struct BrandCell: View {
    let device: Device

    var body: some View {
        let parts = device.brandDetail
        Group {
            switch (parts.primary, parts.secondary) {
            case (let p?, let s?):
                Text("\(p)  \(Text(s).foregroundStyle(.secondary))")
            case (let p?, nil):
                Text(p)
            case (nil, let s?):
                Text(s).foregroundStyle(.secondary)
            case (nil, nil):
                NoValue()
            }
        }
        .lineLimit(1)
        .truncationMode(.tail)
        .help([parts.primary, parts.secondary].compactMap { $0 }.joined(separator: " "))
    }
}

private struct MACCell: View {
    let device: Device

    var body: some View {
        if let mac = device.mac {
            if device.isPrivateMAC {
                Label("Private", systemImage: "lock.fill")
                    .labelStyle(PrivateMACLabelStyle())
                    .foregroundStyle(.secondary)
                    .help(
                        "Randomized private address — the manufacturer can't be identified from it.\n\(mac.description)"
                    )
            } else {
                Text(mac.description)
                    .font(.body.monospaced())
                    .help(device.vendor.map { "\(mac) — \($0)" } ?? mac.description)
            }
        } else {
            NoValue()
        }
    }
}

private struct PrivateMACLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.font(.caption2).imageScale(.small)
            configuration.title
        }
    }
}

/// Reads the store's ping sessions itself, so a ping tick re-renders these cells, not the table.
private struct ResponseCell: View {
    let device: Device
    let store: ScanStore

    var body: some View {
        let ping = store.pingSessions[device.ip]
        HStack(spacing: 5) {
            if let ping, ping.isRunning {
                PulsingDot(size: 6)
                    .help("Pinging \(device.ip.description)")
                if let rtt = ping.last?.rtt {
                    Text(Latency.format(rtt))
                        .monospacedDigit()
                } else if ping.last != nil {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.red)
                        .help("Request timed out")
                        .accessibilityLabel("Request timed out")
                } else {
                    NoValue()
                }
            } else if !device.isOnline {
                if let lastSeen = device.lastSeen {
                    RelativeTimeRefresh {
                        ViewThatFits {
                            Text("Last seen \(RelativeTime.short(lastSeen))")
                            Text(RelativeTime.short(lastSeen))
                        }
                    }
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
                    .help("Offline — last seen \(lastSeen.formatted(date: .abbreviated, time: .shortened))")
                } else {
                    Text("Offline").foregroundStyle(.secondary)
                }
            } else if let t = device.responseTime {
                Text(Latency.format(t))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            } else {
                NoValue()
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

/// The "Rename Device" / "Rename Network" sheet: a name field (empty restores the automatic
/// name), a footnote, Cancel / Rename.
struct RenameSheet<Icon: View>: View {
    let title: String
    var subtitle: String?
    /// Shown as the field's placeholder: the name used when the field is empty.
    let automaticName: String
    let footnote: String
    let save: (String) -> Void
    @ViewBuilder var icon: Icon
    @State private var text: String
    @Environment(\.dismiss) private var dismiss

    init(
        title: String, subtitle: String? = nil, current: String?, automaticName: String, footnote: String,
        save: @escaping (String) -> Void, @ViewBuilder icon: () -> Icon
    ) {
        self.title = title
        self.subtitle = subtitle
        self.automaticName = automaticName
        self.footnote = footnote
        self.save = save
        self.icon = icon()
        _text = State(initialValue: current ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                icon
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.headline)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }
            TextField("Name", text: $text, prompt: Text(automaticName))
                .textFieldStyle(.roundedBorder)
                .onSubmit(commit)
            Text(footnote)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Rename", action: commit)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 400)
    }

    private func commit() {
        save(text)
        dismiss()
    }
}

extension RenameSheet where Icon == DeviceIconView {
    /// "Rename…" for a device: its custom name, remembered on this network.
    init(device: Device, store: ScanStore) {
        self.init(
            title: "Rename Device",
            subtitle: "\(device.ip.description)\(device.mac.map { " · \($0)" } ?? "")",
            current: device.customName, automaticName: device.automaticName,
            footnote: "Leave empty to use the detected name. The name is remembered for this device on this network.",
            save: { store.rename(device: device, to: $0) },
            icon: { DeviceIconView(device: device, size: 32, dimmed: !device.isOnline) })
    }
}

extension RenameSheet where Icon == EmptyView {
    /// "Rename Network…".
    init(network: KnownNetwork, store: ScanStore) {
        self.init(
            title: "Rename Network", current: network.customName, automaticName: network.defaultName,
            footnote:
                "Recognized by its router\(network.gatewayMAC.map { " (\($0))" } ?? ""). Leave empty for the default name.",
            save: { store.renameNetwork(id: network.id, to: $0) },
            icon: { EmptyView() })
    }
}
