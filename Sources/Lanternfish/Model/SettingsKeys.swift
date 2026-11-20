import Foundation
import LanternfishKit

/// User defaults keys and defaults for the Settings window (`@AppStorage` uses the same keys).
enum AppSettings {
    static let showInMenuBarKey = "ShowInMenuBar"
    static let menuBarShowsCountKey = "MenuBarShowsOnlineCount"
    static let autoScanMinutesKey = "AutoScanMinutes"
    static let notifyNewDevicesKey = "NotifyNewDevices"
    static let newDeviceSoundKey = "PlayNewDeviceSound"

    static let autoScanChoices = [0, 5, 15, 30, 60]
    static let defaultAutoScanMinutes = 15

    private static var defaults: UserDefaults { .standard }

    static var showInMenuBar: Bool { defaults.object(forKey: showInMenuBarKey) as? Bool ?? true }
    static var notifyNewDevices: Bool { defaults.object(forKey: notifyNewDevicesKey) as? Bool ?? true }
    /// A quiet sound when a device that's new to the network joins during a scan. Off by default.
    static var newDeviceSound: Bool { defaults.object(forKey: newDeviceSoundKey) as? Bool ?? false }
    /// 0 = off.
    static var autoScanMinutes: Int { defaults.object(forKey: autoScanMinutesKey) as? Int ?? defaultAutoScanMinutes }

    // MARK: Monitoring (watch list) and presence

    static let watchIntervalKey = "WatchIntervalSeconds"
    static let watchFailuresKey = "WatchFailuresBeforeAlert"
    static let notifyWatchDownKey = "NotifyWatchDown"
    static let notifyWatchUpKey = "NotifyWatchUp"

    static let defaultWatchInterval = Int(WatchPolicy.defaultInterval)
    static let defaultWatchFailures = WatchPolicy.defaultFailureThreshold

    /// Seconds between checks of watched devices. Debug aid: LANTERNFISH_WATCH_SECONDS overrides.
    static var watchInterval: TimeInterval {
        if let s = DebugEnv.values["LANTERNFISH_WATCH_SECONDS"].flatMap(Double.init), s > 0 { return s }
        return TimeInterval(defaults.object(forKey: watchIntervalKey) as? Int ?? defaultWatchInterval)
    }
    /// Consecutive failed checks before a watched device counts as down (within the range Settings offers).
    static var watchFailures: Int {
        let range = WatchPolicy.failureThresholdRange
        return min(
            range.upperBound,
            max(range.lowerBound, defaults.object(forKey: watchFailuresKey) as? Int ?? defaultWatchFailures))
    }
    static var notifyWatchDown: Bool { defaults.object(forKey: notifyWatchDownKey) as? Bool ?? true }
    static var notifyWatchUp: Bool { defaults.object(forKey: notifyWatchUpKey) as? Bool ?? true }

    /// Sightings further apart than this start a new presence session: 2× the automatic-scan
    /// interval, at least 10 minutes.
    static var presenceGap: TimeInterval {
        let minutes = autoScanMinutes
        return PresencePolicy.gap(autoScanInterval: minutes > 0 ? TimeInterval(minutes * 60) : nil)
    }
}
