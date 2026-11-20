import Foundation
import LanternfishKit
import Observation

/// App-wide presentation state, so deep views (port menus, inspector) can open
/// feature sheets without threading bindings through every layer.
@MainActor
@Observable
final class Router {
    static let shared = Router()

    /// Service Details sheet for one open port.
    var serviceDetails: ServiceDetailsTarget?
    /// Traceroute sheet; the target is an IP address or hostname.
    var traceroute: TracerouteTarget?
    /// Network Overview popover.
    var showOverview = false
    /// ⌘K command palette.
    var showCommandPalette = false
    /// Network Health sheet for the displayed network (⇧⌘H, see `HealthPresentation`).
    var showHealth = false
    /// Main window content: device table or network map.
    var viewMode: ViewMode = .table

    /// A device to select in the main window (set by notification clicks and the menu bar);
    /// the main window switches to its interface, selects it once it is listed, then clears this.
    /// Expires after `PendingSelection.lifetime` so a device that never shows up isn't selected
    /// much later out of the blue.
    var pendingSelection: PendingSelection? {
        didSet {
            guard let p = pendingSelection, p != oldValue else { return }
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(PendingSelection.lifetime))
                if self?.pendingSelection?.token == p.token { self?.pendingSelection = nil }
            }
        }
    }
    /// Start the speed test when the overview popover next opens (⌘K "Run Speed Test").
    var pendingSpeedTest = false

    /// What ⌘R does while a sheet or popover is up on the main window (service details,
    /// overview); nil: rescan. Set with `setRefresh(_:owner:)`.
    private(set) var refreshOverride: SceneRefresh?
    @ObservationIgnored private var refreshOwner: UUID?

    /// Sets (or with nil, clears) the ⌘R override owned by `owner`.
    func setRefresh(_ refresh: SceneRefresh?, owner: UUID) {
        if let refresh {
            refreshOwner = owner
            refreshOverride = refresh
        } else if refreshOwner == owner {
            refreshOwner = nil
            refreshOverride = nil
        }
    }
    /// Incremented to ask a live view with `openWindow` to open/focus the main window.
    var mainWindowRequest = 0
    /// Incremented to open/focus the Airwaves window (see `AirwavesWindow.show()`).
    var airwavesRequest = 0

    enum ViewMode: String, CaseIterable, Identifiable {
        case table, map
        var id: Self { self }
    }
}

struct PendingSelection: Equatable {
    static let lifetime: Double = 5

    let ip: IPv4Address
    /// Interface whose store lists the device (nil: whichever store is displayed).
    var interfaceID: String?
    /// The device's identity in history; matched before the IP (which may have changed hands).
    var historyKey: String?
    /// Distinguishes repeated requests for the same device.
    let token = UUID()

    init(ip: IPv4Address, interfaceID: String? = nil, historyKey: String? = nil) {
        self.ip = ip
        self.interfaceID = interfaceID
        self.historyKey = historyKey
    }

    /// Selects `device` (by its history identity, falling back to its row id).
    init(device: Device, interfaceID: String?) {
        self.init(ip: device.id, interfaceID: interfaceID, historyKey: device.historyKey)
    }
}

struct ServiceDetailsTarget: Identifiable, Hashable {
    let ip: IPv4Address
    let port: OpenPort
    var id: String { "\(ip):\(port.port)" }
}

struct TracerouteTarget: Identifiable, Hashable {
    let host: String
    var id: String { host }
}
