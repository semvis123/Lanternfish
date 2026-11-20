import Foundation
import SwiftUI

/// The `LANTERNFISH_*` debug hooks (snapshots, previews, data dir, forced appearance, …), used to
/// render the README screenshots from made-up data.
///
/// Active in debug builds, or in release builds compiled with `-DLANTERNFISH_DEBUG_HOOKS`
/// (`DEBUG_HOOKS=1 ./scripts/build-app.sh`). In a normal release build `values` is always empty,
/// so no environment variable can change the app's behavior.
enum DebugEnv {
    #if DEBUG || LANTERNFISH_DEBUG_HOOKS
        static let values: [String: String] =
            ProcessInfo.processInfo.environment.filter { $0.key.hasPrefix("LANTERNFISH_") }
    #else
        static let values: [String: String] = [:]
    #endif

    /// LANTERNFISH_PREVIEW=1: show the made-up network from `ScanStore.preview` instead of scanning.
    static var isPreview: Bool { values["LANTERNFISH_PREVIEW"] == "1" }

    /// LANTERNFISH_APPEARANCE=light|dark: forces that appearance in windows and snapshots.
    static var colorScheme: ColorScheme? {
        switch values["LANTERNFISH_APPEARANCE"] {
        case "light": .light
        case "dark": .dark
        default: nil
        }
    }

    /// A number of seconds from `key` (e.g. a snapshot delay), else `fallback`.
    static func seconds(_ key: String, default fallback: Double) -> Double {
        values[key].flatMap(Double.init) ?? fallback
    }
}
