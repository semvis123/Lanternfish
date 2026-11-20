import AppKit
import LanternfishKit
import OSLog
import UserNotifications

/// Posts "New device on …" notifications for every network's `ScanStore.onNewDevices`.
@MainActor
final class NewDeviceNotifier {
    private let hub: NetworkHub

    init(hub: NetworkHub) {
        self.hub = hub
    }

    /// nil when not running from an app bundle (`swift run`), where the center is unavailable.
    nonisolated static var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : .current()
    }

    // MARK: Authorization

    func authorizationStatus() async -> UNAuthorizationStatus {
        guard let center = Self.center else { return .denied }
        return await center.notificationSettings().authorizationStatus
    }

    /// Asks for permission the first time; afterwards returns the current answer.
    /// `userInitiated` (settings toggle, test button) asks again even when the status reads
    /// "denied": that's also the status while a first prompt was left unanswered, and the
    /// system doesn't re-prompt once the user really decided.
    @discardableResult
    func ensureAuthorized(userInitiated: Bool = false) async -> Bool {
        guard let center = Self.center else { return false }
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: return true
        case .denied: if !userInitiated { return false }
        case .notDetermined: break
        @unknown default: break
        }
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            alertsLog("notification authorization %@", granted ? "granted" : "denied")
            return granted
        } catch {
            alertsLog("notification authorization failed: %@", error.localizedDescription)
            return false
        }
    }

    // MARK: Posting

    func notify(newDevices: [Device], store: ScanStore) {
        let devices = newDevices.filter { !$0.isSelf }
        alertsLog(
            "%ld new device(s) this scan on %@ (notify %@)", devices.count, store.interfaceID ?? "-",
            AppSettings.notifyNewDevices ? "on" : "off")
        guard AppSettings.notifyNewDevices, !devices.isEmpty else { return }
        let network = store.currentNetwork
        let netName = network?.shortName ?? store.selectedInterface?.subnet.description ?? "your network"
        let iface = store.interfaceID
        // The in-app chime already announced this burst: don't ding a second time.
        let silent = NewDeviceChime.shared.playedRecently

        if devices.count > 3 {
            // Grouped; clicking selects the first one.
            let names = devices.prefix(3).map(\.listName).joined(separator: ", ")
            post(
                title: "\(devices.count) new devices on \(netName)",
                body: "\(names) and \(devices.count - 3) more",
                ip: devices[0].ip, historyKey: devices[0].historyKey, networkID: network?.id, interfaceID: iface,
                thread: network?.id, silent: silent)
        } else {
            // Up to 3: one notification each, so each can be clicked to select its device.
            for d in devices {
                post(
                    title: "New device on \(netName)", body: Self.summary(d), ip: d.ip, historyKey: d.historyKey,
                    networkID: network?.id, interfaceID: iface, thread: network?.id, silent: silent)
            }
        }
    }

    /// "Espressif Smart Device · 192.168.1.147 · Espressif".
    private static func summary(_ d: Device) -> String {
        var parts = [d.listName, d.ip.description]
        if let b = d.brand { parts.append(Device.shortBrand(b)) }
        return parts.joined(separator: " · ")
    }

    func sendTest() {
        let store = hub.primaryStore
        let sample = store.devices.first { $0.isOnline && !$0.isSelf }
        let netName = store.currentNetwork?.shortName ?? "your network"
        post(
            title: "New device on \(netName)",
            body: sample.map { "Test · " + Self.summary($0) } ?? "This is a test notification from Lanternfish.",
            ip: sample?.ip, historyKey: sample?.historyKey, networkID: store.currentNetwork?.id,
            interfaceID: store.interfaceID,
            thread: "test", userInitiated: true)
    }

    func post(
        title: String, body: String, ip: IPv4Address?, historyKey: String? = nil, networkID: String?,
        interfaceID: String?, thread: String?, userInitiated: Bool = false, silent: Bool = false
    ) {
        guard let center = Self.center else {
            alertsLog("notifications unavailable outside an app bundle")
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = silent ? nil : .default
        if let thread { content.threadIdentifier = thread }
        var info: [String: String] = [:]
        if let ip { info[UserInfoKey.ip] = ip.description }
        // The device's identity: clicking selects it even if its IP has changed since.
        if let historyKey { info[UserInfoKey.historyKey] = historyKey }
        if let networkID { info[UserInfoKey.networkID] = networkID }
        if let interfaceID { info[UserInfoKey.interfaceID] = interfaceID }
        content.userInfo = info
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        Task {
            guard await ensureAuthorized(userInitiated: userInitiated) else {
                alertsLog("notification not posted (not authorized): %@", title)
                return
            }
            do {
                try await center.add(request)
                alertsLog("posted notification: %@ — %@", title, body)
            } catch {
                alertsLog("posting notification failed: %@", error.localizedDescription)
            }
        }
    }
}

/// Keys of a notification's `userInfo`, read back by `NotificationClickHandler`.
private enum UserInfoKey {
    static let ip = "ip"
    static let historyKey = "historyKey"
    static let networkID = "networkID"
    static let interfaceID = "interface"
}

/// UNUserNotificationCenter delegate: banners while frontmost, and clicks select the device.
final class NotificationClickHandler: NSObject, UNUserNotificationCenterDelegate, Sendable {
    private static let shared = NotificationClickHandler()

    static func install() {
        NewDeviceNotifier.center?.delegate = shared
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        let ip = (info[UserInfoKey.ip] as? String).flatMap(IPv4Address.init)
        let networkID = info[UserInfoKey.networkID] as? String
        let interfaceID = info[UserInfoKey.interfaceID] as? String
        let historyKey = info[UserInfoKey.historyKey] as? String
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            Task { @MainActor in
                Self.open(ip: ip, historyKey: historyKey, networkID: networkID, interfaceID: interfaceID)
            }
        }
        completionHandler()
    }

    /// Shows the store that scans the notification's network (by network, else interface) and
    /// selects the device; a network we've since left is browsed from history in the displayed store.
    @MainActor
    static func open(ip: IPv4Address?, historyKey: String? = nil, networkID: String?, interfaceID: String?) {
        let hub = AppServices.shared.hub
        alertsLog("notification clicked (ip %@, interface %@)", ip?.description ?? "-", interfaceID ?? "-")
        let store = hub.store(forNetworkID: networkID) ?? hub.store(for: interfaceID) ?? hub.displayedStore
        var delay = Duration.zero
        // Only browse history once the live network is known: with `currentNetworkID` still nil
        // (just connected), the notification's network may well be the live one.
        if let networkID, store.currentNetworkID != nil {
            if networkID == store.currentNetworkID {
                if store.isViewingOtherNetwork {
                    store.viewedNetworkID = nil
                    delay = .milliseconds(200)
                }
            } else if store.knownNetworks.contains(where: { $0.id == networkID }) {
                // Joined from a network we've since left: show its saved devices.
                store.viewedNetworkID = networkID
                delay = .milliseconds(200)
            }
        }
        hub.show(store)
        guard let ip else { return }
        // After a network switch, let ContentView clear its selection before applying ours.
        Task { @MainActor in
            if delay > .zero { try? await Task.sleep(for: delay) }
            Router.shared.pendingSelection = PendingSelection(
                ip: ip, interfaceID: store.interfaceID,
                historyKey: historyKey)
        }
    }
}

/// The optional "new device joined" sound (Settings › General). Played from `ScanStore` as soon
/// as a scan finds a device that's new to the live network (the same rule as the new-device
/// notifications: never on a network's first scan), at most once per burst of arrivals.
@MainActor
final class NewDeviceChime {
    static let shared = NewDeviceChime()

    /// Arrivals within this window (one scan, several networks) share one sound.
    private static let burst: TimeInterval = 20
    /// Arrivals are gathered this long before the sound plays.
    private static let debounce: Duration = .milliseconds(400)

    private var lastPlayed: Date?
    private var pending: Task<Void, Never>?
    private lazy var sound: NSSound? = {
        let s = NSSound(named: "Pop")
        s?.volume = 0.35
        return s
    }()

    /// The sound played for the current burst (the scan-end notification then stays silent).
    var playedRecently: Bool { lastPlayed.map { Date().timeIntervalSince($0) < 90 } ?? false }

    func newDevicesJoined() {
        guard AppSettings.newDeviceSound, pending == nil,
            lastPlayed.map({ Date().timeIntervalSince($0) >= Self.burst }) ?? true
        else { return }
        pending = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard let self else { return }
            self.pending = nil
            self.play()
        }
    }

    private func play() {
        lastPlayed = Date()
        preview()
    }

    /// Plays the sound without counting it as an announcement (Settings, when switched on).
    func preview() {
        guard let sound, !sound.isPlaying else { return }
        sound.play()
    }
}

private let alertsLogger = Logger(subsystem: "com.kriyak.lanternfish", category: "alerts")

/// printf-style log line, visible in `log show --predicate 'subsystem == "com.kriyak.lanternfish"'`.
/// Lines often hold device and network names, so release builds log them as private: they don't
/// end up readable in the system log or in diagnostics people attach to bug reports.
func alertsLog(_ format: String, _ args: any CVarArg...) {
    let message = String(format: format, arguments: args)
    #if DEBUG || LANTERNFISH_DEBUG_HOOKS
        alertsLogger.notice("\(message, privacy: .public)")
    #else
        alertsLogger.notice("\(message, privacy: .private)")
    #endif
}
