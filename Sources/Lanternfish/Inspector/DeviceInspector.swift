import LanternfishKit
import SwiftUI

struct DeviceInspector: View {
    let device: Device
    let store: ScanStore

    @State private var nameDraft: String
    @State private var notesDraft: String
    @FocusState private var focus: Field?

    private enum Field { case name, notes }

    init(device: Device, store: ScanStore) {
        self.device = device
        self.store = store
        _nameDraft = State(initialValue: device.customName ?? "")
        _notesDraft = State(initialValue: device.notes ?? "")
    }

    /// Live actions (ping, port scans, browser) only target the network being scanned.
    private var canReach: Bool { store.canReachDevices }

    var body: some View {
        let record = watchRecord
        Form {
            Section {
                InspectorHeader(device: device, store: store, record: record)
            }

            PingSectionHost(device: device, store: store)

            if let record, record.isWatched {
                UptimeSection(device: device, store: store, record: record)
            }

            deviceSection
            networkSection

            PresenceSection(record: record)

            Section("Notes") {
                TextField("Notes", text: $notesDraft, prompt: Text("Add notes…"), axis: .vertical)
                    .labelsHidden()
                    .lineLimit(3...10)
                    .focused($focus, equals: .notes)
            }

            if !device.services.isEmpty {
                Section("Services") {
                    FlowLayout(spacing: 5, lineSpacing: 5) {
                        ForEach(device.services.sorted(), id: \.self) { s in
                            TagView(text: s, font: .callout)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            portsSection
        }
        .formStyle(.grouped)
        .onChange(of: focus) { old, _ in
            if old == .name { commitName() }
            if old == .notes { commitNotes() }
        }
        .onChange(of: device.customName) { _, new in
            if focus != .name { nameDraft = new ?? "" }
        }
        .onChange(of: device.notes) { _, new in
            if focus != .notes { notesDraft = new ?? "" }
        }
        .onDisappear {
            commitName()
            commitNotes()
        }
    }

    // MARK: Sections

    /// Name and type (editable), how the device was identified and when it was first seen. Brand,
    /// model, OS, status and response time are in the header.
    private var deviceSection: some View {
        Section("Device") {
            LabeledContent("Name") {
                TextField("Name", text: $nameDraft, prompt: Text(device.automaticName))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .focused($focus, equals: .name)
                    .onSubmit(commitName)
                    .help(
                        "Your name for this device, remembered by its MAC address. Leave empty for the detected name.")
            }
            Picker("Type", selection: kindBinding) {
                Label("Automatic (\(device.kind.label))", systemImage: device.kind.symbolName)
                    .tag(DeviceKind?.none)
                Divider()
                ForEach(DeviceKind.allCases.filter { $0 != .unknown }, id: \.self) { k in
                    Label(k.label, systemImage: k.symbolName).tag(Optional(k))
                }
            }
            .pickerStyle(.menu)
            if let title = device.webTitle {
                LabeledContent("Web Page Title") {
                    Text(title).multilineTextAlignment(.trailing).textSelection(.enabled)
                }
            }
            if let confidence = device.confidence, !device.identificationReasons.isEmpty {
                DisclosureGroup {
                    ForEach(device.identificationReasons, id: \.self) { reason in
                        Label(reason, systemImage: "checkmark.circle")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                } label: {
                    LabeledContent("Identification") {
                        Text("\(Int((confidence * 100).rounded()))% sure")
                            .monospacedDigit()
                    }
                }
                .help("How the device was recognized, and how sure the scanner is")
            }
            LabeledContent("First Seen") { dateText(device.firstSeen) }
        }
    }

    private var networkSection: some View {
        Section("Network") {
            LabeledContent(device.isOnline ? "IP Address" : "Last IP Address") {
                Text(device.ip.description).monospacedDigit().textSelection(.enabled)
            }
            LabeledContent("MAC Address") {
                if let mac = device.mac {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(mac.description).font(.body.monospaced()).textSelection(.enabled)
                        if device.isPrivateMAC {
                            Label("Private address", systemImage: "lock.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .help("Randomized private address — the manufacturer can't be identified from it.")
                        }
                    }
                } else {
                    NoValue()
                }
            }
            // The header shows the brand; the MAC vendor only adds something when it differs.
            if let vendor = device.vendor, !vendor.isEmpty, device.manufacturer != nil, vendor != device.manufacturer {
                LabeledContent("MAC Vendor") { valueText(vendor) }
            }
            LabeledContent("Hostname") { valueText(device.hostname) }
        }
    }

    private var portsSection: some View {
        Section {
            if device.openPorts.isEmpty {
                Text(store.fullScanProgress[device.ip] == nil ? "No open ports found" : "None found yet")
                    .foregroundStyle(.secondary)
            }
            ForEach(device.openPorts, id: \.port) { p in
                PortRow(port: p, host: device.ip, reachable: canReach)
            }
        } header: {
            HStack {
                Text("Open Ports")
                Spacer()
                if !device.openPorts.isEmpty {
                    Text("\(device.openPorts.count)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        } footer: {
            if device.isOnline && canReach {
                fullScan
            } else {
                Text("As of the last scan that saw this device.")
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
        }
    }

    /// The device's history record (presence, watch state, outages).
    private var watchRecord: KnownDevice? { AppServices.shared.watch.record(for: device, in: store) }

    // MARK: Editing

    private var kindBinding: Binding<DeviceKind?> {
        Binding(get: { device.customKind }, set: { store.setKind(device: device, to: $0) })
    }

    private func commitName() {
        let new = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard new != (device.customName ?? "") else { return }
        store.rename(device: device, to: new)
    }

    private func commitNotes() {
        guard
            notesDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                != (device.notes ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        else { return }
        store.setNotes(device: device, to: notesDraft)
    }

    // MARK: Full scan

    @ViewBuilder
    private var fullScan: some View {
        if let progress = store.fullScanProgress[device.ip] {
            HStack(spacing: 10) {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                Text("\(Int(progress * 100))%")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .trailing)
                Button("Stop") { store.cancelFullScan(device.ip) }
                    .controlSize(.small)
            }
            .padding(.top, 4)
            .help("Scanning all 65,535 TCP ports…")
        } else {
            HStack {
                Text("Common ports only")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Scan All Ports") { store.scanAllPorts(device.ip) }
                    .controlSize(.small)
                    .help("Check all 65,535 TCP ports")
            }
            .padding(.top, 4)
        }
    }

    // MARK: Helpers

    @ViewBuilder
    private func valueText(_ s: String?) -> some View {
        if let s, !s.isEmpty {
            Text(s).textSelection(.enabled)
        } else {
            NoValue()
        }
    }

    @ViewBuilder
    private func dateText(_ date: Date?) -> some View {
        if let date {
            RelativeTimeRefresh { Text(RelativeTime.full(date).capitalizedFirst) }
                .help(date.formatted(date: .complete, time: .shortened))
        } else {
            NoValue()
        }
    }
}

/// The Ping section, when a session exists. Reads the store's ping sessions itself, so a ping
/// tick re-renders this section rather than the whole inspector.
private struct PingSectionHost: View {
    let device: Device
    let store: ScanStore

    var body: some View {
        if store.canReachDevices, let session = store.pingSessions[device.ip] {
            PingSection(ip: device.ip, session: session, store: store)
        }
    }
}

extension String {
    fileprivate var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

/// An open port in the inspector: number, service, default action and a "…" action menu.
private struct PortRow: View {
    let port: OpenPort
    let host: IPv4Address
    var reachable = true

    var body: some View {
        let actions = PortActionSet(port: port, host: host, reachable: reachable)
        HStack(spacing: 8) {
            Circle()
                .fill(port.isWeb ? Color.green : Color.clear)
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)
            if let primary = actions.primary {
                Button {
                    primary.perform()
                } label: {
                    Text(String(port.port)).monospacedDigit()
                }
                .buttonStyle(.link)
                .pointerStyle(.link)
                .help(port.tooltip(actions))
                .accessibilityLabel(port.accessibilityName)
                .accessibilityHint(primary.title)
            } else {
                Text(String(port.port)).monospacedDigit()
                    .accessibilityLabel(port.accessibilityName)
            }
            Text(port.service ?? "Unknown service")
                .foregroundStyle(port.service == nil ? .tertiary : .secondary)
                .lineLimit(1)
                .accessibilityHidden(port.service != nil)
            Spacer(minLength: 4)
            Menu {
                PortMenuItems(actions: actions)
            } label: {
                Label("Actions for port \(port.port)", systemImage: "ellipsis.circle")
                    .labelStyle(.iconOnly)
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(.secondary)
            .help("Actions for port \(port.port)")
        }
        .contextMenu { PortMenuItems(actions: actions) }
    }
}
