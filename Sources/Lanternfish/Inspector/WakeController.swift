import Foundation
import LanternfishKit
import Observation

/// Sends Wake-on-LAN packets for devices and remembers recent sends for button feedback.
/// After a send it pings the device's last IP and selects it, so the inspector shows it come up.
@MainActor
@Observable
final class WakeController {
    static let shared = WakeController()

    /// Whether a device can be woken, and how / why not.
    struct Availability {
        /// The store whose interface sends the packet (nil: can't wake).
        let store: ScanStore?
        let mac: MACAddress?
        let help: String
        var canWake: Bool { store != nil && mac != nil }
    }

    /// MACs (description) with a send in progress.
    private(set) var sending: Set<String> = []
    /// MACs (description) whose packet went out in the last few seconds.
    private(set) var recentlySent: Set<String> = []

    /// nil: no Wake action for this device (this Mac itself).
    static func availability(of device: Device, in store: ScanStore) -> Availability? {
        guard !device.isSelf else { return nil }
        guard let mac = device.mac else {
            return Availability(
                store: nil, mac: nil, help: "Wake-on-LAN needs the device's MAC address, which isn't known")
        }
        guard let live = liveStore(for: store), let iface = live.interface else {
            let name = store.displayedNetwork?.displayName ?? "this device's network"
            return Availability(store: nil, mac: mac, help: "Connect to \(name) to wake this device")
        }
        var help = "Send a Wake-on-LAN magic packet to \(mac) via \(iface.displayName) (\(iface.name))"
        if device.isOnline { help += ". The device is already online." }
        if device.isPrivateMAC {
            help += ". This is a private (randomized) address; it only works if the device uses it on this network."
        }
        help += " Wake-on-LAN often doesn't work for devices on Wi-Fi."
        return Availability(store: live, mac: mac, help: help)
    }

    /// The store scanning the network `store` shows: itself, or (while it browses a saved network
    /// that another interface is connected to) that interface's store.
    static func liveStore(for store: ScanStore) -> ScanStore? {
        if !store.isViewingOtherNetwork { return store.interface == nil ? nil : store }
        return AppServices.shared.hub.store(forNetworkID: store.viewedNetworkID)
    }

    func wake(_ device: Device, in store: ScanStore) {
        guard let a = Self.availability(of: device, in: store), let live = a.store, let mac = a.mac,
            let iface = live.interface
        else { return }
        let key = mac.description
        guard !sending.contains(key) else { return }
        sending.insert(key)
        let name = device.listName
        let broadcast = WakeOnLAN.broadcastAddress(of: iface.subnet)
        Task {
            do {
                try await WakeOnLAN.wake(mac, broadcast: broadcast, interface: iface.name)
                sending.remove(key)
                recentlySent.insert(key)
                PaletteToastCenter.shared.show(
                    "Magic packet sent to \(name)",
                    detail: "Pinging \(device.ip) to see it come up…",
                    symbol: "power")
                if live.pingSessions[device.ip]?.isRunning != true { live.startPing(device.ip) }
                let selectID = live === store ? device.id : device.ip
                Router.shared.pendingSelection = PendingSelection(
                    ip: selectID, interfaceID: live.interfaceID,
                    historyKey: device.historyKey)
                try? await Task.sleep(for: .seconds(4))
                recentlySent.remove(key)
            } catch {
                sending.remove(key)
                PaletteToastCenter.shared.show(
                    "Couldn't wake \(name)", detail: "\(error)",
                    symbol: "exclamationmark.triangle.fill", isError: true)
            }
        }
    }
}
