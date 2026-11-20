import AppKit
import SwiftUI

@main
struct LanternfishApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage(AppSettings.showInMenuBarKey) private var showInMenuBar = true

    private var hub: NetworkHub { AppServices.shared.hub }

    init() {
        // Allow launching the bare executable (swift run) as a regular foreground app.
        NSApplication.shared.setActivationPolicy(.regular)
    }

    private static var forcedColorScheme: ColorScheme? { DebugEnv.colorScheme }

    var body: some Scene {
        // A single main window, so the menu bar and notifications can bring "the" window back.
        Window("Lanternfish", id: MainWindow.id) {
            MainWindowView(hub: hub)
                .frame(minWidth: 860, minHeight: 440)
                .preferredColorScheme(Self.forcedColorScheme)
                .mainWindowOpener()
                .airwavesOpener()
                .onboardingOpener()
                .onAppear {
                    NSApplication.shared.activate()
                    AppServices.shared.scanIfStale()
                }
        }
        .defaultSize(width: 1360, height: 760)
        .windowToolbarStyle(.unified)
        .commands { AppCommands(hub: hub) }

        Window("Airwaves", id: AirwavesWindow.id) {
            AirwavesView()
                .frame(minWidth: 820, minHeight: 520)
                .preferredColorScheme(Self.forcedColorScheme)
        }
        .defaultSize(width: 1100, height: 720)
        .windowToolbarStyle(.unified)
        .commands {
            // Replaces the automatic Window-menu entries so the explorer's can carry ⇧⌘E.
            CommandGroup(replacing: .singleWindowList) { AirwavesMenuCommand() }
        }

        Window("Welcome to Lanternfish", id: OnboardingController.windowID) {
            OnboardingView()
                .preferredColorScheme(Self.forcedColorScheme)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.suppressed)
        .defaultWindowPlacement { _, _ in WindowPlacement(.center) }
        .commands {
            CommandGroup(after: .help) { OnboardingMenuCommand() }
        }

        MenuBarExtra(isInserted: $showInMenuBar) {
            MenuBarContentView(hub: hub)
                .preferredColorScheme(Self.forcedColorScheme)
                .airwavesOpener()
        } label: {
            MenuBarLabel(hub: hub)
                .onboardingOpener()
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .preferredColorScheme(Self.forcedColorScheme)
        }
    }
}
