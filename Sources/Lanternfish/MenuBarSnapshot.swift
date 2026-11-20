import AppKit
import SwiftUI

/// Debug aid: LANTERNFISH_MENUBAR_SNAPSHOT=/path.png renders the menu bar extra's content after
/// LANTERNFISH_MENUBAR_SNAPSHOT_DELAY seconds (default 8, enough for a scan to fill in).
@MainActor
enum MenuBarSnapshot {
    static func scheduleIfRequested(hub: NetworkHub) {
        let env = DebugEnv.values
        guard let path = env["LANTERNFISH_MENUBAR_SNAPSHOT"] else { return }
        let delay = DebugEnv.seconds("LANTERNFISH_MENUBAR_SNAPSHOT_DELAY", default: 8)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            OffscreenRenderer.render(MenuBarContentView(hub: hub), to: path)
            // Also the status item itself (our own layer tree, so no screen-recording permission).
            let itemPath = (path as NSString).deletingPathExtension + "-item.png"
            if let w = NSApp.windows.first(where: {
                String(describing: type(of: $0)).contains("StatusBar") && $0.isVisible
            }),
                let view = w.contentView
            {
                alertsLog("status item window %@ frame %@", String(describing: type(of: w)), NSStringFromRect(w.frame))
                UISnapshot.writePNG(of: view, scale: w.backingScaleFactor, to: itemPath)
            } else {
                alertsLog("no status item window found")
            }
        }
    }
}
