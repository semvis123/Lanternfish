import CoreGraphics
import LanternfishKit
import SwiftUI

/// Everything the network map draws, derived from the (filtered) device list.
/// Pure and deterministic: devices are grouped by kind and sorted by IP, so the same set of
/// devices always lands in the same place.
struct MapModel {
    /// Node metrics in map units (points at 100 % zoom).
    static let nodeSize: CGFloat = 112
    static let ringSpacing: CGFloat = 128

    enum Center {
        /// The gateway device (dimmed when the search filter hides it).
        case device(Device, dimmed: Bool)
        /// No gateway device known: a generic hub, labelled with the gateway address if any.
        case hub(IPv4Address?)
    }

    let center: Center
    /// The displayed network's gateway (from its interface), if it has one.
    let gateway: IPv4Address?
    let nodes: [Device]
    let groups: [MapGroup]
    let layout: MapLayout

    init(devices: [Device], allDevices: [Device], gateway: IPv4Address?) {
        func isGateway(_ d: Device) -> Bool { d.ip == gateway && d.isOnline }
        self.gateway = gateway
        let center: Center
        // With a known gateway address only that device may sit in the middle (until it's found,
        // a placeholder labelled with its address does); without one, any router stands in.
        let standIn = gateway == nil ? devices.first(where: { $0.effectiveKind == .router && $0.isOnline }) : nil
        if let d = devices.first(where: isGateway) ?? standIn {
            center = .device(d, dimmed: false)
        } else if let d = allDevices.first(where: isGateway) {
            center = .device(d, dimmed: true)
        } else {
            center = .hub(gateway)
        }
        self.center = center

        let centerID = center.device?.id
        var buckets: [MapGroup: [Device]] = [:]
        for d in devices where d.id != centerID {
            buckets[MapGroup(kind: d.effectiveKind), default: []].append(d)
        }
        let groups = MapGroup.allCases.filter { buckets[$0] != nil }
        let sorted = groups.map { g in
            buckets[g]!.sorted { ($0.ip, $0.id) < ($1.ip, $1.id) }
        }
        self.groups = groups
        nodes = sorted.flatMap { $0 }
        layout = MapLayout.compute(
            groups: sorted.map { $0.map(\.id) },
            ringSpacing: Self.ringSpacing, nodeSize: Self.nodeSize)
    }
}

extension MapModel.Center {
    var device: Device? {
        if case .device(let d, _) = self { d } else { nil }
    }
}

extension MapModel {
    /// The gateway's address as shown on the map: the interface's gateway, else the centre device's.
    var gatewayAddress: IPv4Address? { gateway ?? center.device?.ip }

    /// Brand and model of the gateway, e.g. "Zyxel NR7101" (nil until known).
    var gatewayModel: String? { center.device?.gatewayModelLine }

    /// Tooltip of the internet uplink, e.g. "Internet via gateway 192.168.1.1 (Zyxel NR7101)".
    var uplinkTooltip: String {
        guard let ip = gatewayAddress else { return "Internet" }
        return "Internet via gateway \(ip)" + (gatewayModel.map { " (\($0))" } ?? "")
    }
}

extension Device {
    /// "Zyxel NR7101": brand and model on one line (falls back to either, or the OS hint).
    var gatewayModelLine: String? {
        let d = brandDetail
        let line = [d.primary.map(Device.shortBrand), d.secondary].compactMap { $0 }.joined(separator: " ")
        return line.isEmpty ? nil : line
    }
}

// MARK: - Viewport

/// Maps layout coordinates (router at the origin) to view coordinates:
/// `view = viewCenter + zoom × (p − focus)`.
struct MapViewport: Equatable {
    var zoom: CGFloat
    var focus: CGPoint

    static let zoomRange: ClosedRange<CGFloat> = 0.3...3

    /// Fits `bounds` into `size` with a margin; never zooms in past 110 %.
    static func fit(_ bounds: CGRect, in size: CGSize, margin: CGFloat = 28) -> MapViewport {
        let w = max(size.width - 2 * margin, 50)
        let h = max(size.height - 2 * margin, 50)
        let z = min(w / max(bounds.width, 1), h / max(bounds.height, 1), 1.1)
        return MapViewport(zoom: max(zoomRange.lowerBound, z), focus: CGPoint(x: bounds.midX, y: bounds.midY))
    }

    func toView(_ p: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(x: size.width / 2 + zoom * (p.x - focus.x), y: size.height / 2 + zoom * (p.y - focus.y))
    }

    func toWorld(_ p: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(x: focus.x + (p.x - size.width / 2) / zoom, y: focus.y + (p.y - size.height / 2) / zoom)
    }

    /// Zoom interpolates geometrically (so it feels uniform), the focus linearly.
    static func interpolate(_ a: MapViewport, _ b: MapViewport, _ t: CGFloat) -> MapViewport {
        MapViewport(
            zoom: a.zoom * pow(b.zoom / a.zoom, t),
            focus: CGPoint(
                x: a.focus.x + (b.focus.x - a.focus.x) * t,
                y: a.focus.y + (b.focus.y - a.focus.y) * t))
    }

    func panned(by d: CGSize) -> MapViewport {
        var v = self
        v.pan(by: d)
        return v
    }

    func zoomed(to z: CGFloat, anchor: CGPoint, in size: CGSize) -> MapViewport {
        var v = self
        v.zoom(to: z, anchor: anchor, in: size)
        return v
    }

    mutating func pan(by d: CGSize) {
        focus.x -= d.width / zoom
        focus.y -= d.height / zoom
    }

    /// Zooms keeping the layout point under `anchor` (view coordinates) fixed.
    mutating func zoom(to newZoom: CGFloat, anchor: CGPoint, in size: CGSize) {
        let z = min(max(newZoom, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
        let ax = anchor.x - size.width / 2
        let ay = anchor.y - size.height / 2
        let px = focus.x + ax / zoom
        let py = focus.y + ay / zoom
        focus = CGPoint(x: px - ax / z, y: py - ay / z)
        zoom = z
    }
}

// MARK: - Device display

extension MapGroup {
    /// Sector tint, matching the kind icons in the group.
    var tint: Color {
        switch self {
        case .network: DeviceKind.router.tint
        case .computers: DeviceKind.computer.tint
        case .mobile: DeviceKind.phone.tint
        case .media: DeviceKind.tv.tint
        case .smartHome: DeviceKind.iot.tint
        case .servers: DeviceKind.nas.tint
        case .peripherals: DeviceKind.printer.tint
        case .unknown: DeviceKind.unknown.tint
        }
    }
}

extension Device {
    /// Stable key for remembering where the user pinned this device on the map.
    var mapPinKey: String { historyKey ?? "ip:\(ip)" }

    /// Name shown under a map node.
    var mapName: String {
        if let c = customName, !c.isEmpty { return c }
        return listName
    }

    /// VoiceOver: "Living Room TV, TV, 192.168.1.20, offline".
    var mapAccessibilityLabel: String {
        var parts = [mapName]
        if effectiveKind != .unknown { parts.append(effectiveKind.label) }
        if isSelf { parts.append("This Mac") }
        parts.append(ip.description)
        if !isOnline { parts.append("offline") }
        if isNew { parts.append("new") }
        return parts.joined(separator: ", ")
    }

    /// Tooltip: brand / model, OS, open ports.
    var mapTooltip: String {
        var lines = [mapName]
        let detail = brandDetail
        if let p = detail.primary {
            lines.append([p, detail.secondary].compactMap { $0 }.joined(separator: " "))
        } else if let s = detail.secondary {
            lines.append(s)
        }
        lines.append(ip.description + (mac.map { " · \($0)" } ?? ""))
        let n = openPorts.count
        lines.append(n == 0 ? "No open ports" : n == 1 ? "1 open port" : "\(n) open ports")
        if !isOnline {
            lines.append(
                lastSeen.map { "Offline · last seen \($0.formatted(.relative(presentation: .named)))" }
                    ?? "Offline")
        }
        return lines.joined(separator: "\n")
    }
}
