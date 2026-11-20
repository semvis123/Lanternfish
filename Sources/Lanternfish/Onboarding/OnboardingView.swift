import AppKit
import SwiftUI

enum OnboardingPage: Int, CaseIterable {
    case welcome, permissions, background, done
}

/// The welcome window: Welcome → Permissions → Menu bar & background → Done.
/// Return continues, Esc skips (both via the bottom bar's default/cancel buttons).
struct OnboardingView: View {
    static let size = CGSize(width: 640, height: 560)

    @State private var page: OnboardingPage
    @State private var forward = true
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(initialPage: OnboardingPage = OnboardingPage(rawValue: OnboardingController.initialPage) ?? .welcome) {
        _page = State(initialValue: initialPage)
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                pageView(page)
                    .id(page)
                    .transition(transition)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()

            bottomBar
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(.windowBackground)
        .onDisappear { OnboardingController.shared.markCompleted() }
    }

    @ViewBuilder
    private func pageView(_ page: OnboardingPage) -> some View {
        switch page {
        case .welcome: OnboardingWelcomePage()
        case .permissions: OnboardingPermissionsPage()
        case .background: OnboardingBackgroundPage()
        case .done: OnboardingDonePage()
        }
    }

    private var transition: AnyTransition {
        if reduceMotion { return .opacity }
        return .asymmetric(
            insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
            removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity))
    }

    private var bottomBar: some View {
        HStack(spacing: 10) {
            PageDots(count: OnboardingPage.allCases.count, current: page.rawValue)
            Spacer()
            if page != .welcome {
                Button("Back") { go(by: -1) }
                    .controlSize(.large)
            }
            if page == .done {
                // Esc closes on the last page too: a real (zero-size, invisible) button, since a
                // `.hidden()` one doesn't receive its key equivalent.
                Button("Close", action: finish)
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.plain)
                    .frame(width: 0, height: 0)
                    .opacity(0)
                    .accessibilityHidden(true)
                Button("Start Using Lanternfish", action: finish)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            } else {
                Button("Skip", action: finish)
                    .keyboardShortcut(.cancelAction)
                    .controlSize(.large)
                Button("Continue") { go(by: 1) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private func go(by delta: Int) {
        guard let next = OnboardingPage(rawValue: page.rawValue + delta) else { return }
        forward = delta > 0
        withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(duration: 0.4, bounce: 0.1)) { page = next }
    }

    private func finish() {
        OnboardingController.shared.markCompleted()
        dismiss()
    }
}

private struct PageDots: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: 7) {
            ForEach(0..<count, id: \.self) { i in
                Capsule()
                    .fill(i == current ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                    .frame(width: i == current ? 18 : 7, height: 7)
            }
        }
        .animation(.snappy, value: current)
        .accessibilityElement()
        .accessibilityLabel("Page \(current + 1) of \(count)")
    }
}

/// Title + subtitle at the top of a page.
private struct PageHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 6) {
            Text(title).font(.largeTitle.weight(.bold))
            Text(subtitle)
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 48)
    }
}

/// A rounded, filled square with a white SF Symbol, like System Settings' sidebar icons.
private struct SettingsIcon: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 32

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            .fill(color.gradient)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
    }
}

// MARK: - Welcome

private struct OnboardingWelcomePage: View {
    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 20)
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 128, height: 128)
                .shadow(color: .black.opacity(0.18), radius: 12, y: 6)
                .accessibilityHidden(true)
            PageHeader(
                title: "Welcome to Lanternfish",
                subtitle: "Light up your network: see every device, what it is, and when it comes and goes."
            )
            .padding(.top, 14)
            Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 18) {
                GridRow {
                    Feature(
                        symbol: "dot.radiowaves.left.and.right", color: .blue, title: "Discover devices",
                        text: "Names, makers and open ports, from ARP, Bonjour and ping.")
                    Feature(
                        symbol: "point.3.connected.trianglepath.dotted", color: .purple, title: "Map your network",
                        text: "Every network you're connected to, scanned at once.")
                }
                GridRow {
                    Feature(
                        symbol: "bell.badge.fill", color: .red, title: "Get alerted",
                        text: "When a new device joins, or a watched one goes down.")
                    Feature(
                        symbol: "wifi", color: .teal, title: "Explore Wi-Fi",
                        text: "Nearby networks, channels and signal strength.")
                }
            }
            .padding(.horizontal, 56)
            .padding(.top, 30)
            Spacer(minLength: 20)
        }
    }

    private struct Feature: View {
        let symbol: String
        let color: Color
        let title: String
        let text: String

        var body: some View {
            HStack(alignment: .top, spacing: 12) {
                SettingsIcon(symbol: symbol, color: color, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(text)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        }
    }
}

// MARK: - Permissions

private struct OnboardingPermissionsPage: View {
    @State private var localNetwork = LocalNetworkProbe()
    @State private var location = OverviewLocationAuthorizer()
    @State private var notifications: PermissionStatus?

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(
                title: "Permissions",
                subtitle:
                    "Lanternfish asks for these when it first needs them. Grant them now, so prompts don't pop up later."
            )
            .padding(.top, 34)
            Form {
                Section {
                    PermissionRow(
                        symbol: "network", color: .blue, title: "Local Network",
                        why: "Find devices and read their addresses on your network.",
                        status: localNetwork.status, busy: localNetwork.isChecking,
                        request: localNetwork.request, openSettings: LocalNetworkProbe.openSettings)
                    PermissionRow(
                        symbol: "bell.badge.fill", color: .red, title: "Notifications",
                        why: "Alert you about new devices and watched devices going down.",
                        status: notifications ?? .notYet, busy: notifications == nil,
                        request: requestNotifications, openSettings: NotificationPermission.openSettings)
                    PermissionRow(
                        symbol: "location.fill", color: .indigo, title: "Location",
                        why: "macOS requires it to show Wi-Fi network names. Your location is never read.",
                        status: location.state.permission, busy: false,
                        request: location.request, openSettings: location.openSettings)
                } footer: {
                    Text(
                        "macOS doesn't let apps check Local Network access. If devices don't show up, make sure Lanternfish is turned on in System Settings › Privacy & Security › Local Network."
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .padding(.horizontal, 20)
        }
        .task {
            await refreshNotifications()
            // The launch scan already accesses the LAN (and so causes the system prompt), so a
            // short browse here adds no prompt of its own; it only reads the outcome.
            localNetwork.probe()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refreshNotifications() }
            localNetwork.probe()
        }
    }

    private func refreshNotifications() async {
        notifications = await NotificationPermission.status()
    }

    private func requestNotifications() {
        Task {
            await AppServices.shared.notifier.ensureAuthorized(userInitiated: true)
            await refreshNotifications()
        }
    }
}

private struct PermissionRow: View {
    let symbol: String
    let color: Color
    let title: String
    let why: String
    let status: PermissionStatus
    let busy: Bool
    let request: () -> Void
    let openSettings: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            SettingsIcon(symbol: symbol, color: color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(why)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 6) {
                StatusLabel(status: status, busy: busy)
                action
            }
            .frame(minWidth: 150, alignment: .trailing)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var action: some View {
        switch status {
        case .notYet:
            Button("Allow…", action: request)
        case .requested, .denied:
            Button("Open System Settings", action: openSettings)
        case .allowed, .unavailable:
            EmptyView()
        }
    }
}

private struct StatusLabel: View {
    let status: PermissionStatus
    let busy: Bool

    var body: some View {
        HStack(spacing: 5) {
            if busy {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: status.symbol)
                    .foregroundStyle(status.tint)
                    .contentTransition(.symbolEffect(.replace))
            }
            Text(busy ? "Checking…" : status.label)
                .foregroundStyle(status == .allowed ? .primary : .secondary)
        }
        .font(.callout.weight(.medium))
        .animation(.default, value: status)
    }
}

// MARK: - Menu bar & background

private struct OnboardingBackgroundPage: View {
    var body: some View {
        VStack(spacing: 0) {
            SettingsIcon(symbol: "menubar.rectangle", color: .gray, size: 52)
                .padding(.top, 30)
            PageHeader(
                title: "Menu Bar & Background",
                subtitle: "Keep an eye on your network with the window closed."
            )
            .padding(.top, 12)
            GeneralSettingsTab()
                .padding(.horizontal, 20)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Done

private struct OnboardingDonePage: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 20)
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 76))
                .foregroundStyle(.white, .green.gradient)
                .symbolEffect(.bounce, value: appeared && !reduceMotion)
                .accessibilityHidden(true)
            PageHeader(
                title: "You're All Set",
                subtitle: "Your networks are being scanned. A few shortcuts to get around:"
            )
            .padding(.top, 16)
            VStack(spacing: 10) {
                Shortcut(keys: "⌘R", text: "Rescan all networks")
                Shortcut(keys: "⌘K", text: "Quick search devices and actions")
                Shortcut(keys: AirwavesWindow.shortcutLabel, text: "Open the Airwaves")
                Shortcut(keys: "⌘,", text: "Settings")
            }
            .frame(width: 340)
            .padding(.top, 26)
            Text("You can show this again from Help › Show Welcome…")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .padding(.top, 26)
            Spacer(minLength: 20)
        }
        .onAppear { appeared = true }
    }

    private struct Shortcut: View {
        let keys: String
        let text: String

        var body: some View {
            HStack {
                Text(text)
                Spacer()
                Text(keys)
                    .font(.body.monospaced().weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .accessibilityElement(children: .combine)
        }
    }
}
