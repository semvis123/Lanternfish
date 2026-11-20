import AppKit
import CoreLocation
import Observation

/// Location Services authorization, which macOS requires before CoreWLAN reveals the SSID/BSSID.
/// The app never asks for an actual location fix.
@MainActor
@Observable
final class OverviewLocationAuthorizer: NSObject, CLLocationManagerDelegate {
    enum State { case notDetermined, authorized, denied }

    private(set) var state: State = .notDetermined
    /// Bumped on each authorization change so dependents can re-read Wi-Fi.
    private(set) var changeCount = 0
    @ObservationIgnored private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        state = Self.map(manager.authorizationStatus)
    }

    /// Title for the button that calls `request()`.
    var requestTitle: String { state == .denied ? "Open Privacy Settings…" : "Allow Location Access" }

    func request() {
        switch state {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .denied: openSettings()
        case .authorized: break
        }
    }

    func openSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")!
        NSWorkspace.shared.open(url)
    }

    private static func map(_ status: CLAuthorizationStatus) -> State {
        switch status {
        case .authorizedAlways, .authorizedWhenInUse: .authorized
        case .denied, .restricted: .denied
        case .notDetermined: .notDetermined
        @unknown default: .notDetermined
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.state = Self.map(status)
            self.changeCount += 1
        }
    }
}
