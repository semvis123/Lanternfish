import Foundation
import LanternfishKit

/// "NAS is offline" / "NAS is back online after 4 min" alerts for watched devices. Same delivery
/// and click routing as the new-device alerts (clicking selects the device).
extension NewDeviceNotifier {
    func notifyWatch(
        _ transition: WatchTransition, device: Device, ip: IPv4Address, network: KnownNetwork?,
        interfaceID: String?
    ) {
        let name = device.listName
        let netName = network?.shortName
        let place = [ip.description, netName].compactMap { $0 }.joined(separator: " · ")
        switch transition {
        case .wentDown(let since):
            guard AppSettings.notifyWatchDown else { return }
            let time = since.formatted(date: .omitted, time: .shortened)
            post(
                title: "\(name) is offline",
                body: "Not answering since \(time) · \(place)",
                ip: ip, historyKey: device.historyKey, networkID: network?.id, interfaceID: interfaceID,
                thread: "watch")
        case .cameBack(let since, let at):
            guard AppSettings.notifyWatchUp else { return }
            post(
                title: "\(name) is back online after \(WatchFormat.duration(at.timeIntervalSince(since)))",
                body: "Offline since \(since.formatted(date: .omitted, time: .shortened)) · \(place)",
                ip: ip, historyKey: device.historyKey, networkID: network?.id, interfaceID: interfaceID,
                thread: "watch")
        case .firstUp:
            break
        }
    }
}
