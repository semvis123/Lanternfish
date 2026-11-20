import AppKit
import LanternfishKit
import SwiftUI

/// What the Health check judges for one store: the live network's online devices, or the
/// remembered snapshot of a saved network being browsed.
@MainActor
struct HealthContext {
    let store: ScanStore
    let isLive: Bool
    let devices: [Device]
    let report: HealthReport

    init(store: ScanStore) {
        self.store = store
        isLive = !store.isViewingOtherNetwork && store.interface != nil
        devices = isLive ? store.devices.filter(\.isOnline) : store.devices
        let gateway = isLive ? store.interface?.gateway : store.displayedNetwork?.gatewayIP.flatMap(IPv4Address.init)
        let wifi = isLive ? store.interface.flatMap { HealthWiFi.security(interface: $0.name) } : nil
        report = HealthCheck.evaluate(devices: devices, gateway: gateway, wifiSecurity: wifi)
    }

    func device(_ id: IPv4Address) -> Device? { devices.first { $0.id == id } }

    var networkName: String {
        store.displayedNetwork?.displayName ?? store.interface?.subnet.description ?? "This Network"
    }

    /// "Saved · last seen 3 days ago" for saved networks; nil when live.
    var savedLabel: String? {
        guard !isLive else { return nil }
        guard let seen = store.displayedNetwork?.lastSeen else { return "Saved network" }
        return "Saved · last seen \(RelativeTime.full(seen))"
    }

    /// The scan hasn't finished yet, so ports and names may still be coming in.
    var isPartial: Bool { isLive && store.isScanning }

    /// Selects the device in the main window (closing the sheet and the overview).
    func select(_ device: Device) {
        let router = Router.shared
        router.showHealth = false
        router.showOverview = false
        router.pendingSelection = PendingSelection(device: device, interfaceID: store.interfaceID)
    }
}

/// Wi-Fi security of an interface, read at most every 15 s (the card and palette re-render often).
@MainActor
private enum HealthWiFi {
    private static var cache: [String: (at: Date, security: String?)] = [:]

    static func security(interface name: String) -> String? {
        if let c = cache[name], Date().timeIntervalSince(c.at) < 15 { return c.security }
        let info = DebugEnv.isPreview ? OverviewDemo.wifi : WiFiReader.read(name)
        let security = info?.isAssociated == true ? info?.security : nil
        cache[name] = (Date(), security)
        return security
    }
}

/// Attaches the Network Health sheet to the main window (applied by `commandPalette(hub:)`,
/// outside `ContentView`, so it follows whichever network is displayed).
///
/// Debug aid: LANTERNFISH_HEALTH=1 opens it 2 s after launch (LANTERNFISH_HEALTH=overview opens the
/// overview popover instead); LANTERNFISH_HEALTH_SNAPSHOT=/path.png then renders the sheet / popover.
private struct HealthSheetModifier: ViewModifier {
    let hub: NetworkHub
    @Bindable private var router = Router.shared

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $router.showHealth) {
                HealthView(hub: hub)
            }
            .onAppear(perform: runDebugHook)
    }

    @MainActor private static var ranDebugHook = false

    private func runDebugHook() {
        let mode = DebugEnv.values["LANTERNFISH_HEALTH"]
        guard mode == "1" || mode == "overview", !Self.ranDebugHook else { return }
        Self.ranDebugHook = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            if mode == "overview" { router.showOverview = true } else { router.showHealth = true }
            // LANTERNFISH_HEALTH_SNAPSHOT=/path.png renders the sheet itself after
            // LANTERNFISH_HEALTH_SNAPSHOT_DELAY seconds (default 10); LANTERNFISH_SNAPSHOT only sees the window.
            let env = DebugEnv.values
            guard let path = env["LANTERNFISH_HEALTH_SNAPSHOT"] else { return }
            let delay = DebugEnv.seconds("LANTERNFISH_HEALTH_SNAPSHOT_DELAY", default: 10)
            try? await Task.sleep(for: .seconds(delay))
            // LANTERNFISH_HEALTH_SNAPSHOT_HEIGHT=<points> makes the sheet taller first, to see everything.
            if let h = env["LANTERNFISH_HEALTH_SNAPSHOT_HEIGHT"].flatMap(Double.init),
                let sheet = NSApp.windows.lazy.compactMap(\.attachedSheet).first
            {
                sheet.setContentSize(NSSize(width: sheet.contentLayoutRect.width, height: h))
                try? await Task.sleep(for: .seconds(1))
            }
            if mode == "overview" {
                // Popover windows snapshot with broken glass effects, so render the content on its own.
                OffscreenRenderer.render(NetworkOverviewView(store: hub.displayedStore), to: path)
            } else {
                NSApp.windows.lazy.compactMap(\.attachedSheet).first?.writeSnapshot(to: path)
            }
        }
    }
}

extension View {
    func healthSheet(hub: NetworkHub) -> some View { modifier(HealthSheetModifier(hub: hub)) }
}

// MARK: - Styling

extension HealthSeverity {
    var tint: Color {
        switch self {
        case .critical: .red
        case .warning: .orange
        case .info: .blue
        case .passed: .green
        }
    }

    var symbol: String {
        switch self {
        case .critical: "xmark.octagon.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .info: "info.circle.fill"
        case .passed: "checkmark.circle.fill"
        }
    }
}

extension HealthGrade {
    var tint: Color {
        switch self {
        case .excellent: .green
        case .good: .mint
        case .fair: .orange
        case .atRisk: .red
        }
    }
}

extension HealthRule {
    var symbol: String {
        switch self {
        case .wifiSecurity: "wifi"
        case .telnet: "terminal"
        case .ftp: "arrow.up.arrow.down.circle"
        case .fileSharing: "folder"
        case .remoteDesktop: "display"
        case .developerServices: "hammer"
        case .routerAdminHTTP: "wifi.router"
        case .webWithoutHTTPS: "lock.open"
        case .mqttPlaintext: "dot.radiowaves.left.and.right"
        case .routerUPnP: "arrow.left.arrow.right"
        case .newDevices: "sparkles"
        case .unidentified: "questionmark.circle"
        case .privateMACs: "eye.slash"
        }
    }

    /// The ports a device row should mention for this rule.
    var ports: Set<UInt16> {
        switch self {
        case .telnet: [23]
        case .ftp: [21]
        case .fileSharing: [445]
        case .remoteDesktop: [3389, 5900, 5901]
        case .developerServices: [2375, 5555]
        case .routerAdminHTTP, .webWithoutHTTPS: [80, 81, 5000, 8000, 8080, 8081, 8888]
        case .mqttPlaintext: [1883]
        default: []
        }
    }
}
