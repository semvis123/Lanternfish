import AppKit
import LanternfishKit
import SwiftUI
import UserNotifications

/// App-lifetime objects shared by the main window, the menu bar extra and the app delegate.
/// They outlive the main window, so scans and alerts keep working with it closed.
@MainActor
final class AppServices {
    static let shared = AppServices()

    /// Every connected network's scan results (one `ScanStore` each).
    let hub: NetworkHub
    let notifier: NewDeviceNotifier
    let autoScan: AutoScanScheduler
    /// Continuous checks of watched devices (uptime alerts).
    let watch: WatchMonitor

    /// The store the main window shows.
    var store: ScanStore { hub.displayedStore }

    private init() {
        hub = DebugEnv.isPreview ? .preview() : NetworkHub()
        notifier = NewDeviceNotifier(hub: hub)
        autoScan = AutoScanScheduler(hub: hub)
        watch = WatchMonitor(hub: hub, notifier: notifier)
        hub.onNewDevices = { [notifier] store, devices in notifier.notify(newDevices: devices, store: store) }
    }

    /// Starts a scan on each network unless one is running or finished recently (re-opening the
    /// main window shouldn't throw away fresh results or the selection).
    func scanIfStale(maxAge: TimeInterval = 120) {
        hub.scanIfStale(maxAge: maxAge)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Must be set before launch finishes so a click that launched the app is delivered.
        NotificationClickHandler.install()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let services = AppServices.shared
        // Pick up gateway MACs (dedupe) and interfaces that appeared since init.
        services.hub.refresh()
        // The main window normally kicks off the first scan; cover launches without one.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            services.scanIfStale()
        }
        services.autoScan.start()
        if !DebugEnv.isPreview { services.watch.start() }
        if DebugEnv.values["LANTERNFISH_TEST_NOTIFICATION"] == "1" {
            // After the first scan, so the test names the network and a real device.
            Task { @MainActor in
                for _ in 0..<30 where services.hub.primaryStore.lastScanFinishedAt == nil {
                    try? await Task.sleep(for: .seconds(1))
                }
                services.notifier.sendTest()
            }
        }
        MenuBarSnapshot.scheduleIfRequested(hub: services.hub)
        WatchSnapshot.scheduleIfRequested(hub: services.hub)
        SettingsSnapshot.scheduleIfRequested()
        Self.runDebugHooks(services)
        OnboardingController.shared.checkAtLaunch()
        Task { @MainActor in
            let status = await services.notifier.authorizationStatus()
            alertsLog("notification authorization status at launch: %ld", status.rawValue)
        }
    }

    /// Debug aids:
    ///   LANTERNFISH_FAKE_NEW_DEVICES=<n>  after the first scan, notify as if n devices were new.
    ///   LANTERNFISH_CLICK_TEST=<ip>       after 12 s close the main window, after 15 s act as if a
    ///                                 notification for <ip> was clicked.
    private static func runDebugHooks(_ services: AppServices) {
        let env = DebugEnv.values
        if let n = env["LANTERNFISH_FAKE_NEW_DEVICES"].flatMap(Int.init), n > 0 {
            Task { @MainActor in
                let store = services.hub.displayedStore
                while store.lastScanFinishedAt == nil { try? await Task.sleep(for: .seconds(1)) }
                let devices = store.devices.filter { $0.isOnline && !$0.isSelf }
                services.notifier.notify(newDevices: Array(devices.suffix(n)), store: store)
            }
        }
        if let ip = env["LANTERNFISH_CLICK_TEST"].flatMap(IPv4Address.init) {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(12))
                for window in NSApp.windows where window.identifier?.rawValue.hasPrefix(MainWindow.id) == true {
                    window.close()
                }
                alertsLog(
                    "click test closed main window; windows now: %@",
                    NSApp.windows.map { "\($0.identifier?.rawValue ?? "-")(\($0.isVisible))" }.joined(separator: ", "))
                try? await Task.sleep(for: .seconds(3))
                let store =
                    services.hub.stores.first { $0.interface?.subnet.scanHosts().contains(ip) == true }
                    ?? services.hub.displayedStore
                NotificationClickHandler.open(ip: ip, networkID: store.currentNetworkID, interfaceID: store.interfaceID)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Close open watch outages at their last check, then write history synchronously.
        let services = AppServices.shared
        services.watch.stop()
        services.hub.history.save(waitUntilWritten: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // With the menu bar extra the app keeps scanning and alerting in the background.
        !AppSettings.showInMenuBar
    }
}

/// Opening and focusing the single main window from anywhere (menu bar, notifications).
@MainActor
enum MainWindow {
    static let id = "main"

    /// Activates the app and opens/focuses the main window. Views that have `openWindow`
    /// (main window, menu bar label, settings) observe `Router.mainWindowRequest`.
    static func show() {
        NSApp.activate()
        Router.shared.mainWindowRequest &+= 1
    }
}

/// Opens the main window when `Router.mainWindowRequest` changes. Attached to every
/// long-lived view so at least one with an `openWindow` action is alive.
private struct MainWindowOpener: ViewModifier {
    @Environment(\.openWindow) private var openWindow
    private let router = Router.shared

    func body(content: Content) -> some View {
        content.onChange(of: router.mainWindowRequest) {
            openWindow(id: MainWindow.id)
            NSApp.activate()
        }
    }
}

extension View {
    func mainWindowOpener() -> some View { modifier(MainWindowOpener()) }
}
