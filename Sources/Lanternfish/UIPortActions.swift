import AppKit
import LanternfishKit
import SwiftUI

// MARK: - Model

/// One thing you can do with an open port: open a URL in its handler app, or copy text.
struct PortAction: Identifiable {
    enum Effect {
        case open(URL)
        case copy(String)
        case run(@MainActor () -> Void)
    }

    let title: String
    let symbol: String
    let effect: Effect

    var id: String { title }

    @MainActor
    func perform() {
        switch effect {
        case .open(let url): DeviceActions.open(url)
        case .copy(let s):
            DeviceActions.copy(s, what: title.hasPrefix("Copy ") ? String(title.dropFirst(5)) : nil)
        case .run(let action): action()
        }
    }
}

/// All actions for a port, grouped for menus, plus the default (click) action.
struct PortActionSet {
    var primary: PortAction?
    var groups: [[PortAction]]

    /// `reachable`: the device is on a network being scanned now. Otherwise only the copy
    /// actions are offered (opening, connecting and inspecting need the device to be reachable).
    @MainActor
    init(port: OpenPort, host: IPv4Address, reachable: Bool = true) {
        let ip = host.description
        let p = Int(port.port)
        var open: [PortAction] = []
        var browser: [PortAction] = []
        var primaryURL: URL?

        func add(_ list: inout [PortAction], _ title: String, _ symbol: String, _ string: String) -> URL? {
            guard let url = URL(string: string), Self.canOpen(url) else { return nil }
            list.append(PortAction(title: title, symbol: symbol, effect: .open(url)))
            return url
        }

        let httpURL = "http://\(ip):\(p)"
        let httpsURL = "https://\(ip):\(p)"

        if let webURL = port.url(host: host) {
            if Self.canOpen(webURL) {
                open.append(PortAction(title: "Open in Browser", symbol: "safari", effect: .open(webURL)))
                primaryURL = webURL
            }
            _ = add(&browser, "Open with http://", "globe", httpURL)
            _ = add(&browser, "Open with https://", "lock", httpsURL)
        } else {
            switch port.port {
            case 22: primaryURL = add(&open, "Connect via SSH", "terminal", "ssh://\(ip)")
            case 21: primaryURL = add(&open, "Open FTP", "folder", "ftp://\(ip)")
            case 23: primaryURL = add(&open, "Telnet", "terminal", "telnet://\(ip)")
            case 139, 445:
                primaryURL = add(
                    &open, "Connect to Server (SMB)", "externaldrive.connected.to.line.below", "smb://\(ip)")
            case 548: primaryURL = add(&open, "Connect (AFP)", "externaldrive.connected.to.line.below", "afp://\(ip)")
            case 5900...5909: primaryURL = add(&open, "Screen Sharing", "rectangle.on.rectangle", "vnc://\(ip):\(p)")
            case 3389:
                primaryURL = add(
                    &open, "Remote Desktop", "desktopcomputer",
                    "rdp://full%20address=s:\(ip):\(p)")
            case 554, 8554: primaryURL = add(&open, "Open Stream", "play.rectangle", "rtsp://\(ip):\(p)")
            case 631: primaryURL = add(&open, "Open Printer Web Page", "printer", httpURL)
            default: break
            }
            _ = add(&browser, "Try in Browser (http)", "globe", httpURL)
            _ = add(&browser, "Try in Browser (https)", "lock", httpsURL)
        }

        var copy = [
            PortAction(title: "Copy IP:Port", symbol: "doc.on.doc", effect: .copy("\(ip):\(p)")),
            PortAction(title: "Copy Port", symbol: "number", effect: .copy(String(p))),
        ]
        if let primaryURL {
            copy.append(PortAction(title: "Copy URL", symbol: "link", effect: .copy(primaryURL.absoluteString)))
        }

        let details = [
            PortAction(
                title: "Show Details…", symbol: "info.circle",
                effect: .run {
                    Router.shared.serviceDetails = ServiceDetailsTarget(ip: host, port: port)
                })
        ]

        if reachable {
            primary = open.first
            groups = [open, browser, details, copy].filter { !$0.isEmpty }
        } else {
            primary = nil
            groups = [copy]
        }
    }

    /// True when some app on this Mac handles the URL's scheme.
    @MainActor
    private static func canOpen(_ url: URL) -> Bool {
        if let cached = schemeCache[url.scheme ?? ""] { return cached }
        let ok = NSWorkspace.shared.urlForApplication(toOpen: url) != nil
        schemeCache[url.scheme ?? ""] = ok
        return ok
    }

    @MainActor private static var schemeCache: [String: Bool] = [:]

    /// Pops the actions up as a native menu at the mouse location.
    @MainActor
    fileprivate func popUpMenu() {
        let menu = NSMenu()
        for (i, group) in groups.enumerated() {
            if i > 0 { menu.addItem(.separator()) }
            for action in group {
                let item = ClosureMenuItem(title: action.title) { action.perform() }
                item.image = NSImage(systemSymbolName: action.symbol, accessibilityDescription: nil)
                menu.addItem(item)
            }
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
}

@MainActor
private final class ClosureMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(title: String, handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() { handler() }
}

// MARK: - Views

/// SwiftUI menu items for a port (context menus, ellipsis menus).
struct PortMenuItems: View {
    let actions: PortActionSet

    var body: some View {
        ForEach(Array(actions.groups.enumerated()), id: \.offset) { i, group in
            if i > 0 { Divider() }
            ForEach(group) { a in
                Button(a.title, systemImage: a.symbol) { a.perform() }
            }
        }
    }
}

extension OpenPort {
    /// VoiceOver name, e.g. "Port 443, HTTPS, web page".
    var accessibilityName: String {
        (["Port \(port)", service] + [isWeb ? "web page" : nil]).compactMap { $0 }.joined(separator: ", ")
    }

    /// Tooltip: service name plus what a click does.
    @MainActor
    func tooltip(_ actions: PortActionSet) -> String {
        let name = service.map { "\($0) (port \(port))" } ?? "Port \(port)"
        if let p = actions.primary { return "\(name) — click to \(p.title.lowercasedFirst)" }
        return "\(name) — click for actions"
    }
}

extension String {
    /// Lowercases a leading capitalized word, keeping acronyms ("SSH", "FTP") intact.
    fileprivate var lowercasedFirst: String {
        guard let first, first.isUppercase, dropFirst().first?.isLowercase == true else { return self }
        return first.lowercased() + dropFirst()
    }
}

/// A compact port chip for the table. Web ports get a green dot. Click = default action
/// (or the action menu when there is none); right-click = action menu.
private struct PortChip: View {
    let port: OpenPort
    let host: IPv4Address
    var reachable = true

    @State private var hovering = false

    var body: some View {
        let actions = PortActionSet(port: port, host: host, reachable: reachable)
        Button {
            if let p = actions.primary { p.perform() } else { actions.popUpMenu() }
        } label: {
            HStack(spacing: 3) {
                if port.isWeb {
                    Circle().fill(.green).frame(width: 5, height: 5)
                }
                Text(String(port.port))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(hovering ? .primary : .secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                hovering ? AnyShapeStyle(.fill.secondary) : AnyShapeStyle(.fill.tertiary),
                in: RoundedRectangle(cornerRadius: 4, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .pointerStyle(.link)
        .help(port.tooltip(actions))
        .accessibilityLabel(port.accessibilityName)
        .accessibilityHint(actions.primary.map { $0.title } ?? "Shows actions")
        .contextMenu { PortMenuItems(actions: actions) }
    }
}

/// As many chips as fit (at most `limit`), then "+N" whose tooltip lists the rest.
struct PortChips: View {
    let ports: [OpenPort]
    let host: IPv4Address
    var reachable = true
    var limit = 5

    var body: some View {
        if ports.isEmpty {
            NoValue()
        } else {
            ViewThatFits(in: .horizontal) {
                ForEach(Array(stride(from: min(limit, ports.count), through: 1, by: -1)), id: \.self) { n in
                    row(showing: n)
                }
            }
        }
    }

    private func row(showing n: Int) -> some View {
        HStack(spacing: 3) {
            ForEach(ports.prefix(n), id: \.port) { p in
                PortChip(port: p, host: host, reachable: reachable)
            }
            if ports.count > n {
                Text("+\(ports.count - n)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 2)
                    .help(
                        ports.dropFirst(n)
                            .map { p in p.service.map { "\(p.port) \($0)" } ?? String(p.port) }
                            .joined(separator: "\n"))
            }
        }
        .fixedSize()
    }
}
