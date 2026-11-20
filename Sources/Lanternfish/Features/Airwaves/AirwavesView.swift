import AppKit
import LanternfishKit
import SwiftUI

/// Hover shared by the channel graph and the table.
struct WiFiHover: Equatable {
    var id: String
    /// Hovering a hill dims the other table rows; hovering a row doesn't.
    var fromGraph: Bool
}

/// The Airwaves window: band picker + channel graph on top, the network table below,
/// your connection, channel advice and signal history in the inspector.
struct AirwavesView: View {
    @State private var model = AirwavesModel.shared
    @State private var band: WiFiBand = .ghz5
    @State private var didPickBand = false
    @State private var hover: WiFiHover?
    @State private var selection: String?
    @State private var searchText = ""
    @State private var showInspector = true
    @State private var isVisible = true
    @State private var window: NSWindow?
    @AppStorage("airwaves.groupByName") private var storedGroupByName = false
    @AppStorage("airwaves.allBands") private var storedAllBands = false
    /// Debug overrides (LANTERNFISH_WIFI_GROUP=1, LANTERNFISH_WIFI_ALLBANDS=1) that don't touch the stored settings.
    @State private var debugGroup = DebugEnv.values["LANTERNFISH_WIFI_GROUP"] == "1"
    @State private var debugAllBands = DebugEnv.values["LANTERNFISH_WIFI_ALLBANDS"] == "1"

    private var groupByName: Binding<Bool> {
        Binding(
            get: { storedGroupByName || debugGroup },
            set: {
                storedGroupByName = $0
                debugGroup = false
            })
    }
    private var allBands: Binding<Bool> {
        Binding(
            get: { storedAllBands || debugAllBands },
            set: {
                storedAllBands = $0
                debugAllBands = false
            })
    }

    private var bandResults: [WiFiScanResult] {
        model.results(in: band).filter { $0.matches(searchText) }
    }

    private var currentSSID: String? { model.current?.ssid ?? model.connection?.ssid }

    private var tableResults: [WiFiScanResult] {
        (allBands.wrappedValue ? model.results : model.results(in: band)).filter { $0.matches(searchText) }
    }

    var body: some View {
        content
            .navigationTitle("Airwaves")
            .navigationSubtitle(subtitle)
            .searchable(text: $searchText, placement: .toolbar, prompt: "Search networks")
            .toolbar { toolbar }
            .inspector(isPresented: $showInspector) {
                AirwavesSidebar(model: model, band: band, selection: selection)
                    .inspectorColumnWidth(min: 280, ideal: 320, max: 420)
            }
            .background {
                WindowVisibilityReader { w, visible in
                    window = w
                    if isVisible != visible { isVisible = visible }
                }
            }
            .task {
                applyDebugEnv()
                await model.run(visible: { isVisible })
            }
            .task { await model.runConnectionRefresh(visible: { isVisible }) }
            // ⌘R (File menu) rescans Wi-Fi while this window is frontmost.
            .focusedSceneValue(
                \.sceneRefresh,
                SceneRefresh(title: "Rescan Wi-Fi", isDisabled: model.isScanning) {
                    [model] in model.rescan()
                }
            )
            .onChange(of: model.lastScan) { pickInitialBand() }
            .onChange(of: isVisible) { _, visible in
                // Coming back into view after a while: refresh right away.
                if visible, !model.isPaused,
                    model.lastScan.map({ Date().timeIntervalSince($0) > AirwavesModel.interval }) ?? true
                {
                    model.rescan()
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch model.status {
        case .wifiOff where model.results.isEmpty:
            ContentUnavailableView {
                Label("Wi-Fi Is Off", systemImage: "wifi.slash")
            } description: {
                Text("Turn on Wi-Fi to see the networks around you.")
            } actions: {
                Button("Open Wi-Fi Settings…") { AirwavesFormat.openWiFiSettings() }
            }
        case .noInterface where model.results.isEmpty:
            ContentUnavailableView(
                "No Wi-Fi Interface", systemImage: "wifi.exclamationmark",
                description: Text("This Mac doesn't have a Wi-Fi interface that can scan."))
        case .idle where model.results.isEmpty:
            VStack(spacing: 10) {
                ProgressView()
                Text("Scanning for networks…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        default:
            graphAndTable
        }
    }

    private var graphAndTable: some View {
        VSplitView {
            VStack(spacing: 0) {
                banners
                WiFiChannelGraph(
                    band: band, networks: bandResults, currentID: model.currentID,
                    currentSSID: currentSSID, hover: $hover, selection: $selection
                )
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 4)
            }
            .frame(minHeight: 250, idealHeight: 340)
            .layoutPriority(1)
            VStack(spacing: 0) {
                tableBar
                Divider()
                WiFiNetworkTable(
                    results: tableResults, currentID: model.currentID, currentSSID: currentSSID,
                    groupByName: groupByName.wrappedValue,
                    hover: $hover, selection: $selection
                )
                .overlay { tableEmptyState }
            }
            .frame(minHeight: 160)
        }
    }

    // MARK: Banners

    @ViewBuilder
    private var banners: some View {
        VStack(spacing: 0) {
            if model.namesRedacted, model.status == .ok {
                WiFiPermissionBanner(location: model.location)
            }
            if let error = model.lastError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("Last scan failed (\(error)). Showing the previous results.")
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                .font(.callout)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(.orange.opacity(0.08))
                .overlay(alignment: .bottom) { Divider() }
            }
        }
    }

    private var tableBar: some View {
        HStack(spacing: 12) {
            let n = tableResults.count
            Text(n == 1 ? "1 network" : "\(n) networks")
                .font(.callout.weight(.medium))
                .monospacedDigit()
            if !allBands.wrappedValue {
                Text("on \(band.label)").font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("Group by network name", isOn: groupByName)
                .toggleStyle(.checkbox)
                .help("Show access points that share a name (mesh nodes, dual-band routers) as one row")
            Picker("Bands", selection: allBands) {
                Text("This Band").tag(false)
                Text("All Bands").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }

    @ViewBuilder
    private var tableEmptyState: some View {
        if tableResults.isEmpty {
            if !searchText.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else {
                ContentUnavailableView(
                    "No Networks on \(band.label)", systemImage: "wifi",
                    description: Text("Nothing heard on this band in the last scan."))
            }
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("Band", selection: $band) {
                ForEach([WiFiBand.ghz2, .ghz5, .ghz6], id: \.self) { b in
                    Text("\(b.label)  \(model.count(in: b))").tag(b)
                }
            }
            .pickerStyle(.segmented)
            .help("Band shown in the channel graph")
            .onChange(of: band) { didPickBand = true }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                model.isPaused.toggle()
            } label: {
                Label(
                    model.isPaused ? "Resume" : "Pause",
                    systemImage: model.isPaused ? "play.fill" : "pause.fill")
            }
            .help(model.isPaused ? "Resume scanning every \(Int(AirwavesModel.interval)) seconds" : "Pause scanning")
            if model.isScanning {
                ProgressView().controlSize(.small).help("Scanning…")
            }
            Button {
                model.rescan()
            } label: {
                Label("Rescan", systemImage: "arrow.clockwise")
            }
            .help("Scan now (⌘R)")
            .disabled(model.isScanning)
            Button {
                showInspector.toggle()
            } label: {
                Label("Inspector", systemImage: "sidebar.right")
            }
            .help(showInspector ? "Hide Inspector" : "Show Inspector")
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        let n = model.results.count
        if model.lastScan != nil { parts.append(n == 1 ? "1 network" : "\(n) networks") }
        if model.isPaused {
            parts.append("Paused")
        } else if model.isScanning {
            parts.append("Scanning…")
        } else if !isVisible, !model.isDemo {
            parts.append("Paused (hidden)")
        }
        if let t = model.lastScan, !model.isScanning {
            parts.append(t.formatted(date: .omitted, time: .standard))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Band & debug

    /// Shows the band you're connected on, once, unless you already picked one.
    private func pickInitialBand() {
        guard !didPickBand else { return }
        let target: WiFiBand? =
            if let b = model.current?.band ?? model.connection?.band, b != .unknown {
                b
            } else {
                [WiFiBand.ghz5, .ghz2, .ghz6].max { model.count(in: $0) < model.count(in: $1) }
            }
        if let target, target != band {
            band = target
        }
        didPickBand = true
    }

    /// Debug aids: LANTERNFISH_WIFI_BAND=2|5|6, LANTERNFISH_WIFI_HOVER=<name>, LANTERNFISH_WIFI_SELECT=<name>,
    /// LANTERNFISH_WIFI_SNAPSHOT=/path.png (+ LANTERNFISH_WIFI_SNAPSHOT_DELAY seconds, default 6).
    private func applyDebugEnv() {
        let env = DebugEnv.values
        if let b = env["LANTERNFISH_WIFI_BAND"] {
            band = b == "2" ? .ghz2 : b == "6" ? .ghz6 : .ghz5
            didPickBand = true
        }
        let hoverName = env["LANTERNFISH_WIFI_HOVER"]
        let selectName = env["LANTERNFISH_WIFI_SELECT"]
        let path = env["LANTERNFISH_WIFI_SNAPSHOT"]
        guard hoverName != nil || selectName != nil || path != nil else { return }
        Task { @MainActor in
            let delay = DebugEnv.seconds("LANTERNFISH_WIFI_SNAPSHOT_DELAY", default: 6)
            try? await Task.sleep(for: .seconds(max(delay - 1.5, 0.5)))
            @MainActor func find(_ name: String) -> WiFiScanResult? {
                if name == "you" { return model.current }
                return model.results(in: band).first { $0.displayName == name }
            }
            if let hoverName, let r = find(hoverName) { hover = WiFiHover(id: r.id, fromGraph: true) }
            if let selectName, let r = find(selectName) { selection = r.id }
            try? await Task.sleep(for: .seconds(1.5))
            if let path { window?.writeSnapshot(to: path) }
        }
    }
}

/// Location Services prompt: without it macOS withholds SSIDs and BSSIDs from scans.
private struct WiFiPermissionBanner: View {
    let location: OverviewLocationAuthorizer

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "location.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Color.blue.gradient, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text("Network names are hidden")
                    .font(.callout.weight(.semibold))
                Text(
                    "macOS shows Wi-Fi names and BSSIDs only to apps allowed to use Location Services, and merges look-alike networks without it. Channels and signal levels are accurate either way."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button(location.requestTitle) {
                location.request()
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.blue.opacity(0.06))
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// Marks your own network in the table, graph labels and tooltip.
struct WiFiYouBadge: View {
    var body: some View {
        Text("You")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(Color.accentColor))
    }
}

// MARK: - Formatting & colours

enum AirwavesFormat {
    /// The signal scale of the graph, meters and history chart, in dBm.
    static let signalRange: ClosedRange<Double> = -100 ... -30

    /// Where `dBm` falls on `signalRange`, 0...1, but at least `minimum` so weak signals still show.
    static func signalFraction(_ dBm: Double, minimum: Double) -> Double {
        let r = signalRange
        return min(max((dBm - r.lowerBound) / (r.upperBound - r.lowerBound), minimum), 1)
    }

    static func openWiFiSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.wifi-settings-extension") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Distinct hues for neighbours; blue is reserved for your own network (accent).
    private static let palette: [Color] = [
        .orange, .green, .pink, .purple, .teal, .yellow, .red, .mint,
        .indigo, .brown, .cyan,
    ]

    /// Stable colour per network name (so a router's bands share a colour), else per BSSID.
    static func color(for r: WiFiScanResult, currentID: String?, currentSSID: String?) -> Color {
        if r.id == currentID || (r.ssid != nil && r.ssid == currentSSID) { return .accentColor }
        let key = r.ssid ?? r.id
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in key.utf8 { h = (h ^ UInt64(b)) &* 0x100_0000_01b3 }
        return palette[Int(h % UInt64(palette.count))]
    }

    static func brand(_ r: WiFiScanResult) -> String? {
        r.brand().map(Device.shortBrand)
    }

    static func width(_ w: Int) -> String { "\(w) MHz" }

    static func beacon(_ tu: Int?) -> String? { tu.map { "\($0) TU" } }
}

extension WiFiScanResult {
    func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return true }
        let fields: [String?] = [
            displayName, bssid, AirwavesFormat.brand(self), "\(channel)",
            security.label, standard?.name, standard?.generation, band.label, countryCode,
        ]
        return fields.contains { $0?.localizedCaseInsensitiveContains(q) == true }
    }
}
