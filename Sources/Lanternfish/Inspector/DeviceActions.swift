import AppKit
import LanternfishKit

/// Small AppKit-backed helpers shared by the table context menu and the inspector.
enum DeviceActions {
    /// Copies `s` to the pasteboard. With `what` ("IP Address"), confirms with a "Copied …" toast.
    @MainActor
    static func copy(_ s: String, what: String? = nil) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
        if let what {
            PaletteToastCenter.shared.show("Copied \(what)", detail: s, symbol: "doc.on.doc")
        }
    }

    @MainActor
    static func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}

/// The one way latencies are written everywhere (table, inspector, ping, map, overview, menu bar):
/// under 1 ms → "<1 ms", under 10 ms → one decimal ("4.2 ms"), else whole ms ("128 ms"); ≥ 1 s → "1.2 s".
enum Latency {
    static func ms(_ d: Duration) -> Double {
        let c = d.components
        return Double(c.seconds) * 1000 + Double(c.attoseconds) / 1e15
    }

    static func format(_ d: Duration) -> String { format(ms: ms(d)) }

    static func format(ms v: Double) -> String {
        if v < 1 { return "<1 ms" }
        if v < 9.95 { return String(format: "%.1f ms", v) }
        if v < 999.5 { return "\(Int(v.rounded())) ms" }
        return String(format: "%.1f s", v / 1000)
    }
}

extension Device {
    /// Web URLs for every open web port, in port order.
    var webURLs: [(port: OpenPort, url: URL)] {
        openPorts.compactMap { p in p.url(host: ip).map { (p, $0) } }
    }

    /// The web page "Open in Browser" goes to: HTTPS on 443, else HTTP on 80, else the first web port.
    var preferredWebURL: URL? {
        let urls = webURLs
        return (urls.first { $0.port.port == 443 } ?? urls.first { $0.port.port == 80 } ?? urls.first)?.url
    }

    /// Case-insensitive match across every visible column.
    func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return true }
        let fields: [String?] = [
            displayName, ip.description, brandModel, vendor, manufacturer, model,
            mac?.description, hostname, effectiveKind.label, kind.label, name,
            fallbackLabel, osHint, webTitle, notes, isPrivateMAC ? "Private" : nil,
            isOnline ? nil : "Offline", isNew ? "New" : nil,
        ]
        if fields.contains(where: { $0?.localizedCaseInsensitiveContains(q) == true }) { return true }
        if services.contains(where: { $0.localizedCaseInsensitiveContains(q) }) { return true }
        return openPorts.contains { p in
            String(p.port) == q || p.service?.localizedCaseInsensitiveContains(q) == true
        }
    }

    // Sort keys for table columns (devices without a value sort last).
    var brandSortKey: String { brandModel ?? "\u{10FFFF}" }
    var macSortKey: String { mac?.description ?? "\u{10FFFF}" }
    var portCount: Int { openPorts.count }
}

extension ScanStore {
    /// Live actions (ping, traceroute, port scans, browser, service details) only reach devices
    /// of the network this store is scanning right now.
    var canReachDevices: Bool { !isViewingOtherNetwork && interface != nil }

    /// Why live actions are unavailable (nil when they are available).
    var unreachableReason: String? {
        if canReachDevices { return nil }
        if isViewingOtherNetwork {
            return "Not connected to \(displayedNetwork?.displayName ?? "this network") — showing saved devices"
        }
        return "Not connected to a network"
    }
}
