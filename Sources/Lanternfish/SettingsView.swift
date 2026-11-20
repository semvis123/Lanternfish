import AppKit
import LanternfishKit
import ServiceManagement
import SwiftUI
import UserNotifications

/// The Settings window (⌘,): General, Notifications and Monitoring tabs.
struct SettingsView: View {
    fileprivate static let width: CGFloat = 480

    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralSettingsTab() }
            Tab("Notifications", systemImage: "bell.badge") { NotificationSettingsTab() }
            Tab("Monitoring", systemImage: "eye") { MonitoringSettingsTab() }
        }
        .frame(width: Self.width)
        .fixedSize(horizontal: false, vertical: true)
        .mainWindowOpener()
    }
}

struct GeneralSettingsTab: View {
    @AppStorage(AppSettings.showInMenuBarKey) private var showInMenuBar = true
    @AppStorage(AppSettings.menuBarShowsCountKey) private var showCount = true
    @AppStorage(AppSettings.autoScanMinutesKey) private var autoScanMinutes = AppSettings.defaultAutoScanMinutes
    @AppStorage(AppSettings.newDeviceSoundKey) private var newDeviceSound = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginStatus = SMAppService.mainApp.status
    @State private var loginError: String?

    var body: some View {
        Form {
            Section {
                Toggle("Show in menu bar", isOn: $showInMenuBar)
                Toggle("Show online device count", isOn: $showCount)
                    .disabled(!showInMenuBar)
            } footer: {
                Text(
                    showInMenuBar
                        ? "Lanternfish keeps running in the menu bar when its window is closed."
                        : "Closing the window quits Lanternfish."
                )
                .settingsFootnote()
            }
            Section {
                Picker("Scan automatically", selection: $autoScanMinutes) {
                    ForEach(AppSettings.autoScanChoices, id: \.self) { m in
                        Text(m == 0 ? "Off" : "Every \(m) minutes").tag(m)
                    }
                }
            } footer: {
                Text(
                    "Background scans run while the app is open, also from the menu bar. They're skipped during a full port scan or while you browse another network."
                )
                .settingsFootnote()
            }
            Section {
                Toggle("Play sound when a new device joins", isOn: $newDeviceSound)
                    .onChange(of: newDeviceSound) { _, on in
                        // A preview, so you know what to listen for.
                        if on { NewDeviceChime.shared.preview() }
                    }
            } footer: {
                Text("A quiet sound while a scan finds a device that hasn't been seen on this network before.")
                    .settingsFootnote()
            }
            Section {
                Toggle("Launch at login", isOn: Binding(get: { launchAtLogin }, set: setLaunchAtLogin))
                if loginStatus == .requiresApproval {
                    HStack {
                        Text("Allow Lanternfish in Login Items to finish.")
                            .settingsFootnote()
                        Spacer()
                        Button("Open Login Items…") { SMAppService.openSystemSettingsLoginItems() }
                            .controlSize(.small)
                    }
                }
                if let loginError {
                    Label {
                        Text(loginError).settingsFootnote()
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshLoginStatus()
        }
    }

    private func refreshLoginStatus() {
        loginStatus = SMAppService.mainApp.status
        launchAtLogin = loginStatus == .enabled || loginStatus == .requiresApproval
    }

    private func setLaunchAtLogin(_ on: Bool) {
        loginError = nil
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            var message = "Couldn't \(on ? "enable" : "disable") launch at login: \(error.localizedDescription)"
            if on, !Bundle.main.bundlePath.hasPrefix("/Applications/") {
                message += " Move Lanternfish to the Applications folder and try again."
            }
            loginError = message
        }
        refreshLoginStatus()
    }
}

private struct NotificationSettingsTab: View {
    @AppStorage(AppSettings.notifyNewDevicesKey) private var notify = true
    @State private var status: UNAuthorizationStatus?
    @State private var sentTest = false

    var body: some View {
        Form {
            Section {
                Toggle("Notify about new devices", isOn: $notify)
                    .onChange(of: notify) { _, on in
                        if on {
                            Task {
                                await AppServices.shared.notifier.ensureAuthorized(userInitiated: true)
                                await refresh()
                            }
                        }
                    }
            } footer: {
                Text(
                    "Get a notification when a device joins that hasn't been seen on this network before. Click it to show the device."
                )
                .settingsFootnote()
            }
            Section {
                LabeledContent("Permission") {
                    HStack(spacing: 6) {
                        Image(systemName: statusSymbol.name).foregroundStyle(statusSymbol.color)
                        Text(statusText)
                    }
                }
                if status == .denied {
                    HStack {
                        Text("Notifications are turned off for Lanternfish in System Settings.")
                            .settingsFootnote()
                        Spacer()
                        Button("Open System Settings…", action: NotificationPermission.openSettings)
                            .controlSize(.small)
                    }
                }
                HStack {
                    Spacer()
                    if sentTest {
                        Text("Sent").foregroundStyle(.secondary).transition(.opacity)
                    }
                    Button("Send Test Notification") {
                        AppServices.shared.notifier.sendTest()
                        withAnimation { sentTest = true }
                        Task {
                            try? await Task.sleep(for: .seconds(1.5))
                            await refresh()
                            try? await Task.sleep(for: .seconds(1.5))
                            withAnimation { sentTest = false }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .task { await refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refresh() }
        }
    }

    private func refresh() async {
        status = await AppServices.shared.notifier.authorizationStatus()
    }

    private var statusText: String {
        switch status {
        case nil: "Checking…"
        case .authorized: "Allowed"
        case .provisional: "Delivered quietly"
        case .ephemeral: "Allowed temporarily"
        case .denied: NewDeviceNotifier.center == nil ? "Unavailable (not running as an app)" : "Not allowed"
        case .notDetermined: "Not requested yet"
        @unknown default: "Unknown"
        }
    }

    private var statusSymbol: (name: String, color: Color) {
        switch status {
        case .authorized, .provisional, .ephemeral: ("checkmark.circle.fill", .green)
        case .denied: ("xmark.circle.fill", .red)
        default: ("questionmark.circle", .secondary)
        }
    }
}

/// Watch list checks and uptime alerts.
private struct MonitoringSettingsTab: View {
    @AppStorage(AppSettings.watchIntervalKey) private var interval = AppSettings.defaultWatchInterval
    @AppStorage(AppSettings.watchFailuresKey) private var failures = AppSettings.defaultWatchFailures
    @AppStorage(AppSettings.notifyWatchDownKey) private var notifyDown = true
    @AppStorage(AppSettings.notifyWatchUpKey) private var notifyUp = true

    var body: some View {
        Form {
            Section {
                Picker("Check watched devices", selection: $interval) {
                    ForEach(WatchPolicy.intervalChoices, id: \.self) { s in
                        Text(Self.intervalLabel(s)).tag(s)
                    }
                }
                .onChange(of: interval) { AppServices.shared.watch.checkSoon() }
                Picker("Offline after", selection: $failures) {
                    ForEach(Array(WatchPolicy.failureThresholdRange), id: \.self) { n in
                        Text("\(n) failed checks").tag(n)
                    }
                }
            } footer: {
                Text(
                    "Watch a device from its inspector or the device list's context menu. Watched devices on connected networks are pinged continuously (with a TCP check for devices that ignore ping), also with the main window closed. A device counts as offline after \(failures) checks in a row get no answer — about \(WatchFormat.duration(TimeInterval(interval * failures)))."
                )
                .settingsFootnote()
            }
            Section {
                Toggle("Notify when a watched device goes offline", isOn: $notifyDown)
                Toggle("Notify when it's back online", isOn: $notifyUp)
            } footer: {
                Text("Alerts use the same notification permission as new-device alerts. Click one to show the device.")
                    .settingsFootnote()
            }
            .onChange(of: notifyDown || notifyUp) { _, on in
                if on { Task { await AppServices.shared.notifier.ensureAuthorized(userInitiated: true) } }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
    }

    private static func intervalLabel(_ seconds: Int) -> String {
        switch seconds {
        case ..<60: "Every \(seconds) seconds"
        case 60: "Every minute"
        default: "Every \(seconds / 60) minutes"
        }
    }
}

extension Text {
    fileprivate func settingsFootnote() -> some View {
        font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

/// Debug aid: LANTERNFISH_SETTINGS_SNAPSHOT=/dir renders the settings tabs to general.png,
/// notifications.png and monitoring.png in that directory after LANTERNFISH_SETTINGS_SNAPSHOT_DELAY seconds (default 3).
@MainActor
enum SettingsSnapshot {
    static func scheduleIfRequested() {
        guard let dir = DebugEnv.values["LANTERNFISH_SETTINGS_SNAPSHOT"] else { return }
        let delay = DebugEnv.seconds("LANTERNFISH_SETTINGS_SNAPSHOT_DELAY", default: 3)
        func render(_ tab: some View, _ name: String) {
            OffscreenRenderer.render(
                tab.frame(width: SettingsView.width), to: (dir as NSString).appendingPathComponent(name))
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            render(GeneralSettingsTab(), "general.png")
            render(NotificationSettingsTab(), "notifications.png")
            render(MonitoringSettingsTab(), "monitoring.png")
        }
    }
}
