import AppKit
import SwiftUI

/// Opening the Airwaves window from anywhere (toolbar, ⌘K, menu bar).
@MainActor
enum AirwavesWindow {
    static let id = "airwaves"
    /// ⇧⌘E (⇧⌘W is "Close Window" in many apps).
    static let shortcut = KeyboardShortcut("e", modifiers: [.command, .shift])
    static let shortcutLabel = "⇧⌘E"

    /// Asks a live view with `openWindow` (see `airwavesOpener()`) to open/focus the window.
    static func show() {
        NSApp.activate()
        Router.shared.airwavesRequest &+= 1
    }

    /// Debug aid: LANTERNFISH_AIRWAVES=1 opens the Airwaves window on launch.
    static var openOnLaunch: Bool { DebugEnv.values["LANTERNFISH_AIRWAVES"] == "1" }
}

/// Opens the Airwaves window when `Router.airwavesRequest` changes (and once on launch when asked to).
private struct AirwavesOpener: ViewModifier {
    @Environment(\.openWindow) private var openWindow
    private let router = Router.shared
    @MainActor private static var didLaunchHook = false

    func body(content: Content) -> some View {
        content
            .onChange(of: router.airwavesRequest) {
                openWindow(id: AirwavesWindow.id)
                NSApp.activate()
            }
            .onAppear {
                guard AirwavesWindow.openOnLaunch, !Self.didLaunchHook else { return }
                Self.didLaunchHook = true
                openWindow(id: AirwavesWindow.id)
            }
    }
}

extension View {
    func airwavesOpener() -> some View { modifier(AirwavesOpener()) }
}

/// Window menu items for the app's single-instance windows (replacing SwiftUI's automatic
/// ones, which can't carry a shortcut).
struct AirwavesMenuCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Lanternfish") { openWindow(id: MainWindow.id) }
        Button("Airwaves") { openWindow(id: AirwavesWindow.id) }
            .keyboardShortcut(AirwavesWindow.shortcut)
    }
}

/// Main-window toolbar button.
struct AirwavesToolbarButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button {
            openWindow(id: AirwavesWindow.id)
        } label: {
            Label("Airwaves", systemImage: "wifi")
        }
        .help("Airwaves: nearby networks, channels and signal (\(AirwavesWindow.shortcutLabel))")
    }
}
