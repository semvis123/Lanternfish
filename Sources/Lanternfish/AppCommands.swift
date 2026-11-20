import AppKit
import SwiftUI

/// What ⌘R refreshes in the frontmost window (or sheet / popover): published by each scene.
struct SceneRefresh {
    let title: String
    var isDisabled = false
    let perform: @MainActor () -> Void
}

/// The main window's state the menu bar commands act on.
struct MainWindowActions {
    var showInspector: Binding<Bool>
    /// The map's controller while the map is the displayed view (zoom commands), else nil.
    var map: MapController?
}

extension FocusedValues {
    @Entry var sceneRefresh: SceneRefresh?
    @Entry var mainWindow: MainWindowActions?
}

extension NetworkHub {
    /// The main window's ⌘R: rescan every connected network (disabled while one is scanning).
    @MainActor
    var rescanRefresh: SceneRefresh {
        SceneRefresh(title: stores.count > 1 ? "Rescan All Networks" : "Rescan", isDisabled: isAnyScanning) {
            [weak self] in self?.rescanAll()
        }
    }
}

/// The app's menu bar commands: File (Rescan, Quick Search) and View (inspector, table / map, zoom).
struct AppCommands: Commands {
    let hub: NetworkHub

    var body: some Commands {
        CommandGroup(after: .newItem) {
            FileMenuItems(hub: hub)
        }
        CommandGroup(before: .toolbar) {
            ViewMenuItems(hub: hub)
        }
    }
}

private struct FileMenuItems: View {
    let hub: NetworkHub
    @FocusedValue(\.sceneRefresh) private var refresh
    @FocusedValue(\.mainWindow) private var mainWindow
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // No focused scene (settings, menu bar window): the main window's rescan.
        let r = refresh ?? Router.shared.refreshOverride ?? hub.rescanRefresh
        Button(r.title) { r.perform() }
            .keyboardShortcut("r")
            .disabled(r.isDisabled)
        Button("Quick Search…") { quickSearch() }
            .keyboardShortcut("k")
    }

    /// ⌘K: toggles the palette in the main window; from any other window, brings the main
    /// window forward first (so the palette never opens out of sight).
    private func quickSearch() {
        let router = Router.shared
        if mainWindow != nil, MainWindow.isKey {
            router.showCommandPalette.toggle()
            return
        }
        openWindow(id: MainWindow.id)
        NSApp.activate()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            // Only if the window really is up; otherwise the request would pop up later, unasked.
            guard MainWindow.isVisible else { return }
            router.showCommandPalette = true
        }
    }
}

private struct ViewMenuItems: View {
    let hub: NetworkHub
    @FocusedValue(\.mainWindow) private var mainWindow
    @Bindable private var router = Router.shared

    var body: some View {
        Toggle(
            "Show Offline Devices",
            isOn: Binding(
                get: { hub.displayedStore.showOfflineDevices },
                set: { hub.setShowOfflineDevices($0) })
        )
        .keyboardShortcut("o", modifiers: [.command, .shift])
        Divider()
        let inspector = mainWindow?.showInspector
        Button(inspector?.wrappedValue == true ? "Hide Inspector" : "Show Inspector") {
            inspector?.wrappedValue.toggle()
        }
        .keyboardShortcut("i", modifiers: [.command, .option])
        .disabled(inspector == nil)
        Button("Network Health…") { router.showHealth = true }
            .keyboardShortcut(HealthCommand.shortcut)
            .disabled(mainWindow == nil || router.showHealth)
        Divider()
        Toggle("as Table", isOn: viewMode(.table))
            .keyboardShortcut("1")
            .disabled(mainWindow == nil)
        Toggle("as Map", isOn: viewMode(.map))
            .keyboardShortcut("2")
            .disabled(mainWindow == nil)
        Divider()
        let map = mainWindow?.map
        Button("Zoom In") { map?.zoom(by: MapController.zoomStep) }
            .keyboardShortcut("+")
            .disabled(!(map?.canZoomIn ?? false))
        Button("Zoom Out") { map?.zoom(by: 1 / MapController.zoomStep) }
            .keyboardShortcut("-")
            .disabled(!(map?.canZoomOut ?? false))
        Button("Fit Map") { map?.fit() }
            .keyboardShortcut("0")
            .disabled(map == nil || map?.isFit == true)
        Divider()
    }

    private func viewMode(_ mode: Router.ViewMode) -> Binding<Bool> {
        Binding(get: { router.viewMode == mode }, set: { if $0 { router.viewMode = mode } })
    }
}

/// ⇧⌘H: Network Health (View menu). Not taken by the app or the system menus.
enum HealthCommand {
    static let shortcut = KeyboardShortcut("h", modifiers: [.command, .shift])
    static let shortcutLabel = "⇧⌘H"
}

extension MainWindow {
    private static func isMain(_ w: NSWindow) -> Bool { w.identifier?.rawValue.hasPrefix(id) == true }

    /// The main window is open (on screen, possibly behind others).
    static var isVisible: Bool { NSApp.windows.contains { isMain($0) && $0.isVisible } }

    /// The main window (or a sheet on it) has keyboard focus.
    static var isKey: Bool {
        guard let key = NSApp.keyWindow else { return false }
        return isMain(key) || key.sheetParent.map(isMain) == true
    }
}
