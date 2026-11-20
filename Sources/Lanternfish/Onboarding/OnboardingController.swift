import AppKit
import Network
import Observation
import SwiftUI
import UserNotifications

/// First-launch welcome window: when to show it, and opening it from anywhere.
///
/// Debug aids:
///   LANTERNFISH_ONBOARDING=1               show it on launch (without recording it as seen).
///   LANTERNFISH_ONBOARDING=0               never show it automatically.
///   LANTERNFISH_ONBOARDING_PAGE=<0-3>      page to start on.
///   LANTERNFISH_ONBOARDING_SNAPSHOT=/dir   after LANTERNFISH_ONBOARDING_SNAPSHOT_DELAY seconds (default 3)
///                                      render every page to page-<n>.png, and the live welcome
///                                      window (if open) to window.png.
/// Any other LANTERNFISH_* variable (snapshot and preview runs) suppresses the automatic launch, so
/// debug captures of other windows aren't covered by it.
@MainActor
@Observable
final class OnboardingController {
    static let shared = OnboardingController()
    static let windowID = "onboarding"

    /// Set by the launch check; the first live opener (main window or menu bar label) opens
    /// the welcome window and clears it.
    var pendingOpen = false
    @ObservationIgnored private var launchHandled = false

    static let completedKey = "OnboardingCompleted"
    static let localNetworkRequestedKey = "OnboardingLocalNetworkRequested"

    private static var env: [String: String] { DebugEnv.values }
    static var forced: Bool { env["LANTERNFISH_ONBOARDING"] == "1" }
    static var initialPage: Int { env["LANTERNFISH_ONBOARDING_PAGE"].flatMap(Int.init) ?? 0 }

    static var shouldShowAtLaunch: Bool {
        if forced { return true }
        if env["LANTERNFISH_ONBOARDING"] == "0" { return false }
        let debugRun = env.keys.contains { $0.hasPrefix("LANTERNFISH_") && $0 != "LANTERNFISH_APPEARANCE" }
        if debugRun { return false }
        return !UserDefaults.standard.bool(forKey: completedKey)
    }

    /// Called once from `applicationDidFinishLaunching`.
    func checkAtLaunch() {
        guard !launchHandled, Self.shouldShowAtLaunch else { return }
        launchHandled = true
        Task { @MainActor in
            // Let the main window come up first, so the welcome window sits in front of it.
            try? await Task.sleep(for: .seconds(0.6))
            pendingOpen = true
        }
        OnboardingSnapshot.scheduleIfRequested()
    }

    /// Records the welcome as seen (not in forced debug runs, so they don't hide the real first launch).
    func markCompleted() {
        guard !Self.forced else { return }
        UserDefaults.standard.set(true, forKey: Self.completedKey)
    }
}

/// Opens the welcome window when the launch check asks for it. Attached to the main window
/// and the menu bar label (views that have `openWindow`).
private struct OnboardingOpener: ViewModifier {
    @Environment(\.openWindow) private var openWindow
    private let controller = OnboardingController.shared

    func body(content: Content) -> some View {
        content
            .onAppear(perform: openIfPending)
            .onChange(of: controller.pendingOpen, openIfPending)
    }

    private func openIfPending() {
        guard controller.pendingOpen else { return }
        controller.pendingOpen = false
        openWindow(id: OnboardingController.windowID)
        NSApp.activate()
    }
}

extension View {
    func onboardingOpener() -> some View { modifier(OnboardingOpener()) }
}

/// Help › Show Welcome…
struct OnboardingMenuCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Show Welcome…") {
            openWindow(id: OnboardingController.windowID)
            NSApp.activate()
        }
    }
}

// MARK: - Permission status

/// One permission's state as shown on the welcome window.
enum PermissionStatus: Equatable {
    case notYet, requested, allowed, denied, unavailable

    var label: String {
        switch self {
        case .notYet: "Not yet"
        case .requested: "Requested"
        case .allowed: "Allowed"
        case .denied: "Denied"
        case .unavailable: "Unavailable"
        }
    }

    var symbol: String {
        switch self {
        case .notYet: "circle.dashed"
        case .requested: "clock.fill"
        case .allowed: "checkmark.circle.fill"
        case .denied: "xmark.circle.fill"
        case .unavailable: "minus.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .notYet, .unavailable: .secondary
        case .requested: .orange
        case .allowed: .green
        case .denied: .red
        }
    }
}

/// Local Network privacy has no status API. A Bonjour browse is the cheapest LAN access that
/// triggers the system prompt; its outcome hints at the answer: results mean allowed, a
/// "policy denied" DNS error means denied, silence means undecided (or an empty network).
@MainActor
@Observable
final class LocalNetworkProbe {
    private(set) var status: PermissionStatus
    private(set) var isChecking = false
    @ObservationIgnored private var browser: NWBrowser?

    init() {
        status =
            UserDefaults.standard.bool(forKey: OnboardingController.localNetworkRequestedKey) ? .requested : .notYet
    }

    /// Asks for access (the first time macOS shows its prompt) and starts a scan.
    func request() {
        UserDefaults.standard.set(true, forKey: OnboardingController.localNetworkRequestedKey)
        if status == .notYet { status = .requested }
        AppServices.shared.scanIfStale(maxAge: 30)
        probe()
    }

    /// Browses briefly to read the current answer. Only call once access was requested (or a
    /// scan already ran): on an undecided system this is what makes macOS prompt.
    func probe(timeout: Duration = .seconds(5)) {
        browser?.cancel()
        isChecking = true
        let browser = NWBrowser(for: .bonjour(type: "_http._tcp", domain: "local."), using: NWParameters())
        browser.stateUpdateHandler = { [weak self] state in
            let error: NWError? =
                switch state {
                case .waiting(let e), .failed(let e): e
                default: nil
                }
            guard case .dns(let code)? = error, code == DNSServiceErrorType(kDNSServiceErr_PolicyDenied)
            else { return }
            Task { @MainActor in self?.finish(.denied) }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard !results.isEmpty else { return }
            Task { @MainActor in self?.finish(.allowed) }
        }
        self.browser = browser
        browser.start(queue: .main)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: timeout)
            guard let self, self.browser === browser else { return }
            self.finish(nil)
        }
    }

    private func finish(_ result: PermissionStatus?) {
        if let result {
            status = result
            UserDefaults.standard.set(true, forKey: OnboardingController.localNetworkRequestedKey)
        }
        isChecking = false
        browser?.cancel()
        browser = nil
    }

    static func openSettings() {
        NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")!)
    }
}

enum NotificationPermission {
    static func status() async -> PermissionStatus {
        guard NewDeviceNotifier.center != nil else { return .unavailable }
        switch await AppServices.shared.notifier.authorizationStatus() {
        case .authorized, .provisional, .ephemeral: return .allowed
        case .denied: return .denied
        case .notDetermined: return .notYet
        @unknown default: return .notYet
        }
    }

    static func openSettings() {
        let id = Bundle.main.bundleIdentifier ?? "com.kriyak.lanternfish"
        let urls = [
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)",
            "x-apple.systempreferences:com.apple.preference.notifications",
        ]
        for s in urls {
            if let url = URL(string: s), NSWorkspace.shared.open(url) { return }
        }
    }
}

extension OverviewLocationAuthorizer.State {
    var permission: PermissionStatus {
        switch self {
        case .notDetermined: .notYet
        case .authorized: .allowed
        case .denied: .denied
        }
    }
}

// MARK: - Snapshots

@MainActor
enum OnboardingSnapshot {
    static func scheduleIfRequested() {
        let env = DebugEnv.values
        guard let dir = env["LANTERNFISH_ONBOARDING_SNAPSHOT"] else { return }
        let delay = DebugEnv.seconds("LANTERNFISH_ONBOARDING_SNAPSHOT_DELAY", default: 3)
        let scheme = DebugEnv.colorScheme
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            alertsLog(
                "onboarding snapshot; windows: %@",
                NSApp.windows.map { "\(type(of: $0))/\($0.identifier?.rawValue ?? "-")/\($0.title)(\($0.isVisible))" }
                    .joined(separator: ", "))
            if let window = NSApp.windows.first(where: {
                $0.identifier?.rawValue.hasPrefix(OnboardingController.windowID) == true && $0.isVisible
            }),
                let view = window.contentView?.superview ?? window.contentView
            {
                UISnapshot.writePNG(
                    of: view, scale: window.backingScaleFactor,
                    to: (dir as NSString).appendingPathComponent("window.png"))
            }
            for page in OnboardingPage.allCases {
                OffscreenRenderer.render(
                    OnboardingView(initialPage: page).preferredColorScheme(scheme),
                    to: (dir as NSString).appendingPathComponent("page-\(page.rawValue).png"))
            }
        }
    }
}
