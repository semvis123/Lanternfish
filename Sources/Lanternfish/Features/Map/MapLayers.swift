import LanternfishKit
import SwiftUI

// MARK: - Geometry

extension CGRect {
    /// The square around a circle.
    fileprivate init(around center: CGPoint, radius r: CGFloat) {
        self.init(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r)
    }
}

/// Connectors are quadratic curves from the router that bend towards the middle of the node's
/// group sector, so each group's links fan out of one shared direction.
private enum MapCurve {
    /// Connectors start this far from the router's centre, as a share of its icon size.
    static let routerClearance: CGFloat = 0.62

    static func control(_ a: CGPoint, _ b: CGPoint, bend: CGFloat) -> CGPoint {
        let len = hypot(b.x - a.x, b.y - a.y)
        let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        let ray = CGPoint(x: a.x + cos(bend) * len * 0.5, y: a.y + sin(bend) * len * 0.5)
        return CGPoint(x: mid.x + (ray.x - mid.x) * 0.55, y: mid.y + (ray.y - mid.y) * 0.55)
    }

    static func point(_ a: CGPoint, _ c: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
        let u = 1 - t
        return CGPoint(
            x: u * u * a.x + 2 * u * t * c.x + t * t * b.x,
            y: u * u * a.y + 2 * u * t * c.y + t * t * b.y)
    }

    /// The part of the curve between `t0` and `t1` (exact, via blossoming).
    static func path(_ a: CGPoint, _ c: CGPoint, _ b: CGPoint, from t0: CGFloat, to t1: CGFloat) -> Path {
        let p0 = point(a, c, b, t0)
        let p2 = point(a, c, b, t1)
        let k0 = (1 - t0) * (1 - t1)
        let k1 = t0 * (1 - t1) + t1 * (1 - t0)
        let k2 = t0 * t1
        let ctrl = CGPoint(x: k0 * a.x + k1 * c.x + k2 * b.x, y: k0 * a.y + k1 * c.y + k2 * b.y)
        var p = Path()
        p.move(to: p0)
        p.addQuadCurve(to: p2, control: ctrl)
        return p
    }

    /// An annular sector with rounded corners.
    static func sector(center o: CGPoint, r0: CGFloat, r1: CGFloat, a0: CGFloat, a1: CGFloat, corner: CGFloat) -> Path {
        let c = min(corner, (r1 - r0) / 2, r0 * (a1 - a0) / 2)
        func pt(_ r: CGFloat, _ a: CGFloat) -> CGPoint { CGPoint(x: o.x + r * cos(a), y: o.y + r * sin(a)) }
        let d1 = c / r1
        let d0 = c / r0
        var p = Path()
        p.move(to: pt(r0 + c, a0))
        p.addArc(tangent1End: pt(r1, a0), tangent2End: pt(r1, a0 + d1 * 2), radius: c)
        p.addArc(center: o, radius: r1, startAngle: .radians(a0 + d1), endAngle: .radians(a1 - d1), clockwise: false)
        p.addArc(tangent1End: pt(r1, a1), tangent2End: pt(r1 - c, a1), radius: c)
        p.addLine(to: pt(r0 + c, a1))
        p.addArc(tangent1End: pt(r0, a1), tangent2End: pt(r0, a1 - d0 * 2), radius: c)
        p.addArc(center: o, radius: r0, startAngle: .radians(a1 - d0), endAngle: .radians(a0 + d0), clockwise: true)
        p.addArc(tangent1End: pt(r0, a0), tangent2End: pt(r0 + c, a0), radius: c)
        p.closeSubpath()
        return p
    }

    /// Curve parameters that leave `r0` / `r1` points free at the ends (approximate).
    static func trim(_ a: CGPoint, _ b: CGPoint, r0: CGFloat, r1: CGFloat) -> (CGFloat, CGFloat) {
        let len = max(hypot(b.x - a.x, b.y - a.y), 1)
        return (min(r0 / len, 0.45), max(1 - r1 / len, 0.55))
    }
}

/// A node as the canvases see it: where it is on screen and how to draw its connector.
private struct MapConnector {
    var id: IPv4Address
    var ip: IPv4Address
    var point: CGPoint
    var bend: CGFloat
    var tint: Color
    var alpha: CGFloat
    var online: Bool
    var iconRadius: CGFloat
}

// MARK: - Backdrop

/// Background, a soft glow behind the router, tinted group sectors and faint ring guides.
struct MapBackdrop: View {
    let controller: MapController
    let model: MapModel
    let size: CGSize
    @Environment(\.colorScheme) private var scheme
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let vp = controller.viewport(in: size)
        let layout = model.layout
        let groups = model.groups
        let dark = scheme == .dark
        let hair = 1 / max(displayScale, 1)
        Canvas { ctx, canvasSize in
            ctx.fill(Path(CGRect(origin: .zero, size: canvasSize)), with: .color(MapStyle.background))
            guard !model.nodes.isEmpty || model.center.device != nil else { return }
            let o = vp.toView(.zero, in: canvasSize)
            let z = vp.zoom
            let outer = ((layout.ringRadii.last ?? 160) + MapModel.nodeSize * 0.6) * z

            // Glow behind the router.
            let glow = outer * 1.1
            ctx.fill(
                Path(ellipseIn: CGRect(around: o, radius: glow)),
                with: .radialGradient(
                    Gradient(colors: [
                        Color.accentColor.opacity(dark ? 0.10 : 0.07),
                        Color.accentColor.opacity(0),
                    ]),
                    center: o, startRadius: 0, endRadius: glow))

            // Ring guides.
            for r in layout.ringRadii {
                let rr = r * z
                ctx.stroke(
                    Path(ellipseIn: CGRect(around: o, radius: rr)),
                    with: .color(.primary.opacity(dark ? 0.07 : 0.08)),
                    style: StrokeStyle(lineWidth: hair, dash: [2, 4]))
            }

            // Group sectors: rounded annular wedges, tinted like their devices.
            for label in layout.groupLabels where label.index < groups.count {
                let tint = groups[label.index].tint
                // Hug the group's nodes: their angular / radial extent plus about half a node.
                let mid = label.angle
                let pts = model.nodes.lazy.filter {
                    groups.firstIndex(of: MapGroup(kind: $0.effectiveKind)) == label.index
                }
                .compactMap { layout.positions[$0.id] }
                var lo = CGFloat.infinity
                var hi = -CGFloat.infinity
                var rMin = CGFloat.infinity
                var rMax: CGFloat = 0
                for p in pts {
                    var d = atan2(p.y, p.x) - mid
                    while d > .pi { d -= 2 * .pi }
                    while d < -.pi { d += 2 * .pi }
                    lo = min(lo, d)
                    hi = max(hi, d)
                    let r = hypot(p.x, p.y)
                    rMin = min(rMin, r)
                    rMax = max(rMax, r)
                }
                guard lo.isFinite else { continue }
                let r0 = max((rMin - MapModel.nodeSize * 0.5) * z, 34 * z)
                let r1 = (rMax + MapModel.nodeSize * 0.5) * z
                let pad = asin(min(1, MapModel.nodeSize * 0.55 / max(rMin, 1)))
                let a0 = mid + lo - pad
                let a1 = mid + hi + pad
                guard r1 > r0 + 4, a1 > a0 else { continue }
                let wedge = MapCurve.sector(center: o, r0: r0, r1: r1, a0: a0, a1: a1, corner: min(12, 16 * z))
                ctx.fill(
                    wedge,
                    with: .radialGradient(
                        Gradient(colors: [tint.opacity(dark ? 0.03 : 0.025), tint.opacity(dark ? 0.10 : 0.08)]),
                        center: o, startRadius: r0, endRadius: r1))
                ctx.stroke(wedge, with: .color(tint.opacity(dark ? 0.16 : 0.18)), lineWidth: hair)
            }
        }
    }
}

/// Sector captions, real-size text placed just outside each sector.
struct MapCaptions: View {
    let controller: MapController
    let model: MapModel
    let size: CGSize

    var body: some View {
        let vp = controller.viewport(in: size)
        let o = vp.toView(.zero, in: size)
        let opacity = Self.opacity(zoom: vp.zoom)
        ZStack {
            if opacity > 0.01 {
                ForEach(model.layout.groupLabels, id: \.index) { label in
                    let group = model.groups[label.index]
                    let a = Self.anchor(label, zoom: vp.zoom)
                    MapGroupLabel(
                        group: group, count: model.nodes.count { MapGroup(kind: $0.effectiveKind) == group },
                        zoom: vp.zoom
                    )
                    .frame(width: 0, height: 0, alignment: a.alignment)
                    .position(x: o.x + a.point.x, y: o.y + a.point.y)
                }
            }
        }
        .opacity(opacity)
        .allowsHitTesting(false)
    }

    static func opacity(zoom: CGFloat) -> CGFloat { smoothstep(0.2, 0.28, zoom) }

    /// Where a caption goes relative to the router (screen units) and which of its edges is
    /// pinned there: captions extend away from the ring.
    static func anchor(_ label: MapLayout.GroupLabel, zoom: CGFloat) -> (point: CGPoint, alignment: Alignment) {
        let c = cos(label.angle)
        let s = sin(label.angle)
        // Bottom captions clear the name labels hanging below the nodes.
        let r =
            (label.outerRadius + MapModel.nodeSize * 0.5) * zoom + 8
            + (s > 0 ? 34 * s * MapNodeMetrics(zoom: zoom).labelOpacity : 0)
        let h: HorizontalAlignment = c > 0.3 ? .leading : c < -0.3 ? .trailing : .center
        let v: VerticalAlignment = s > 0.3 ? .top : s < -0.3 ? .bottom : .center
        return (CGPoint(x: c * r, y: s * r), Alignment(horizontal: h, vertical: v))
    }

    /// Estimated box of a caption relative to the router (screen units), for label placement.
    @MainActor
    static func box(_ label: MapLayout.GroupLabel, group: MapGroup, count: Int, zoom: CGFloat) -> CGRect {
        let fs = MapGroupLabel.fontScale(zoom: zoom)
        let w =
            9.5 * fs * 1.25 + 8
            + MapLabelSizing.width(group.label.uppercased(), size: 10 * fs, weight: .semibold, tracking: 0.5)
            + MapLabelSizing.width("\(count)", size: 10 * fs, weight: .semibold, tracking: 0.5)
        let h = MapLabelSizing.lineHeight(10 * fs)
        let a = anchor(label, zoom: zoom)
        let x =
            a.alignment.horizontal == .leading
            ? a.point.x : a.alignment.horizontal == .trailing ? a.point.x - w : a.point.x - w / 2
        let y =
            a.alignment.vertical == .top
            ? a.point.y : a.alignment.vertical == .bottom ? a.point.y - h : a.point.y - h / 2
        return CGRect(x: x, y: y, width: w, height: h)
    }
}

// MARK: - Connectors

/// The uplink and every router → device connector: crisp, constant-width strokes drawn in
/// screen space (so zooming never blurs or thickens them).
struct MapConnectorLayer: View {
    let controller: MapController
    let size: CGSize
    let internet: CGPoint
    let routerIcon: CGFloat
    let selection: IPv4Address?
    @Environment(\.colorScheme) private var scheme
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let _ = controller.frame
        let pings = controller.activity.pings
        let vp = controller.viewport(in: size)
        let o = vp.toView(.zero, in: size)
        let net = vp.toView(internet, in: size)
        let items = controller.connectors(in: size, viewport: vp)
        let hovered = controller.hovered ?? controller.dragging
        let dark = scheme == .dark
        let hair = 1 / max(displayScale, 1)
        let reduceMotion = controller.reduceMotion
        let netRadius = MapInternetNode.iconSize(zoom: vp.zoom) / 2
        Canvas { ctx, _ in
            // Uplink.
            let (u0, u1) = MapCurve.trim(o, net, r0: routerIcon * MapCurve.routerClearance, r1: netRadius + 3)
            let uc = CGPoint(x: (o.x + net.x) / 2, y: (o.y + net.y) / 2)
            ctx.stroke(
                MapCurve.path(o, uc, net, from: u0, to: u1),
                with: .linearGradient(
                    Gradient(colors: [MapStyle.uplink.opacity(0.35), MapStyle.uplink.opacity(0.85)]),
                    startPoint: o, endPoint: net),
                style: StrokeStyle(lineWidth: 1.5, lineCap: .round))

            let n = CGFloat(max(items.count, 1))
            let base: CGFloat = (dark ? 0.32 : 0.42) * (n <= 16 ? 1 : max(0.45, (16 / n).squareRoot()))
            // Emphasised connectors last, so they draw on top.
            let ordered = items.sorted { rank($0, hovered, pings) < rank($1, hovered, pings) }
            for item in ordered {
                let selected = item.id == selection
                let isHovered = item.id == hovered
                let ping = pings[item.ip]
                let c = MapCurve.control(o, item.point, bend: item.bend)
                let (t0, t1) = MapCurve.trim(
                    o, item.point, r0: routerIcon * MapCurve.routerClearance, r1: item.iconRadius + 3)
                let path = MapCurve.path(o, c, item.point, from: t0, to: t1)
                var alpha = item.alpha * (item.online ? 1 : 0.6)
                if hovered != nil, !isHovered, !selected { alpha *= 0.45 }
                let dash: [CGFloat] = item.online ? [] : [3, 4]

                if selected || isHovered {
                    let w: CGFloat = selected ? 2 : 1.5
                    ctx.stroke(
                        path, with: .color(Color.accentColor.opacity((selected ? 0.25 : 0.15) * alpha)),
                        style: StrokeStyle(lineWidth: w + 4, lineCap: .round, dash: dash))
                    ctx.stroke(
                        path,
                        with: .linearGradient(
                            Gradient(colors: [
                                Color.accentColor.opacity(0.7 * alpha),
                                Color.accentColor.opacity(alpha),
                            ]),
                            startPoint: o, endPoint: item.point),
                        style: StrokeStyle(lineWidth: w, lineCap: .round, dash: dash))
                } else if let ping {
                    let color = ping.ok ? MapStyle.pingOK : MapStyle.pingLost
                    ctx.stroke(
                        path, with: .color(color.opacity((reduceMotion ? 0.85 : 0.55) * alpha)),
                        style: StrokeStyle(lineWidth: 1.25, lineCap: .round, dash: dash))
                } else {
                    // Neutral at the router, the device's tint at the node: groups read at a glance.
                    ctx.stroke(
                        path,
                        with: .linearGradient(
                            Gradient(colors: [
                                Color.primary.opacity(base * 0.8 * alpha),
                                item.tint.opacity(min(1, base * 1.9) * alpha),
                            ]),
                            startPoint: o, endPoint: item.point),
                        style: StrokeStyle(lineWidth: hair, lineCap: .round, dash: dash))
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func rank(_ c: MapConnector, _ hovered: IPv4Address?, _ pings: [IPv4Address: MapPing]) -> Int {
        c.id == selection ? 3 : c.id == hovered ? 2 : pings[c.ip] != nil ? 1 : 0
    }
}

extension MapController {
    /// Screen-space connector data for every visible node.
    fileprivate func connectors(in size: CGSize, viewport vp: MapViewport) -> [MapConnector] {
        let icon = MapNodeMetrics(zoom: vp.zoom).icon
        return nodes.compactMap { s in
            guard s.appear > 0.01 else { return nil }
            return MapConnector(
                id: s.id, ip: s.device.ip, point: vp.toView(s.position, in: size), bend: s.bendAngle,
                tint: s.device.effectiveKind.tint, alpha: CGFloat(s.appear),
                online: s.device.isOnline, iconRadius: icon / 2)
        }
    }
}

// MARK: - Activity

/// Things that move: ping packets travelling along connectors, the scanning ripple, glow
/// pulses on newly found devices, presence rings on devices that come online or go offline,
/// and the occasional packet up the uplink. Hidden with Reduce Motion (connectors are tinted
/// instead).
struct MapActivityLayer: View {
    let controller: MapController
    let size: CGSize
    let internet: CGPoint
    let routerIcon: CGFloat
    let outerRadius: CGFloat

    var body: some View {
        let t = controller.now
        if controller.reduceMotion {
            Color.clear
        } else {
            let vp = controller.viewport(in: size)
            let o = vp.toView(.zero, in: size)
            let net = vp.toView(internet, in: size)
            let activity = controller.activity
            let uplink = controller.uplinkPulse
            let icon = MapNodeMetrics(zoom: vp.zoom).icon
            let pinging =
                activity.pings.isEmpty
                ? []
                : controller.connectors(in: size, viewport: vp)
                    .compactMap { c in activity.pings[c.ip].map { (c, $0) } }
            let born = controller.nodes.compactMap { s -> (CGPoint, Color, Double)? in
                guard let b = s.bornAt, t - b < MapController.glowDuration, t >= b else { return nil }
                return (vp.toView(s.position, in: size), s.device.effectiveKind.tint, t - b)
            }
            let presence = controller.presencePulses
            let pulses =
                presence.isEmpty
                ? []
                : controller.nodes.compactMap { s -> (CGPoint, Color, Bool, Double)? in
                    guard !s.isRemoving, let p = presence[DeviceArrivals.key(for: s.device)],
                        t >= p.at, t - p.at < MapController.presencePulseDuration
                    else { return nil }
                    // A node that just appeared already has its discovery glow.
                    if let b = s.bornAt, t - b < MapController.glowDuration { return nil }
                    return (vp.toView(s.position, in: size), s.device.effectiveKind.tint, p.online, t - p.at)
                }
            Canvas { ctx, _ in
                if activity.isScanning {
                    let r0 = routerIcon * 0.7
                    let r1 = outerRadius * vp.zoom
                    for k in 0..<3 {
                        let f = CGFloat((t / 3.0 + Double(k) / 3).truncatingRemainder(dividingBy: 1))
                        let r = r0 + (r1 - r0) * f
                        let a = pow(1 - f, 1.6)
                        let rect = CGRect(around: o, radius: r)
                        ctx.stroke(
                            Path(ellipseIn: rect), with: .color(Color.accentColor.opacity(0.07 * a)), lineWidth: 10)
                        ctx.stroke(
                            Path(ellipseIn: rect), with: .color(Color.accentColor.opacity(0.32 * a)), lineWidth: 1)
                    }
                }

                // Packets up the uplink: periodically, and continuously while scanning.
                let uplinkPhase: CGFloat? =
                    if activity.isScanning {
                        CGFloat((t / 1.6).truncatingRemainder(dividingBy: 1))
                    } else if let u = uplink, t - u < MapController.uplinkPulseDuration, t >= u {
                        CGFloat((t - u) / MapController.uplinkPulseDuration)
                    } else { nil }
                if let f = uplinkPhase {
                    let c = CGPoint(x: (o.x + net.x) / 2, y: (o.y + net.y) / 2)
                    packet(
                        &ctx, at: { MapCurve.point(o, c, net, $0) }, phase: smoothstep(0, 1, f),
                        color: MapStyle.uplink, tail: true)
                }

                // Ping packets: out from the router, faster for quicker replies.
                for (item, ping) in pinging {
                    let period = ping.ok ? min(max(0.55 + (ping.rtt ?? 0.02) * 10, 0.55), 2.2) : 1.8
                    let color = ping.ok ? MapStyle.pingOK : MapStyle.pingLost
                    let c = MapCurve.control(o, item.point, bend: item.bend)
                    let (t0, t1) = MapCurve.trim(
                        o, item.point, r0: routerIcon * MapCurve.routerClearance, r1: item.iconRadius + 2)
                    for k in 0..<3 {
                        let f = CGFloat((t / period + Double(k) / 3).truncatingRemainder(dividingBy: 1))
                        // Lost echoes fade out half way.
                        let fade = ping.ok ? sin(.pi * f) : max(0, 1 - f * 1.8)
                        guard fade > 0.02 else { continue }
                        let p = MapCurve.point(o, c, item.point, t0 + (t1 - t0) * f)
                        let r: CGFloat = 2.2
                        ctx.fill(
                            Path(ellipseIn: CGRect(x: p.x - 3 * r, y: p.y - 3 * r, width: 6 * r, height: 6 * r)),
                            with: .radialGradient(
                                Gradient(colors: [color.opacity(0.35 * fade * item.alpha), color.opacity(0)]),
                                center: p, startRadius: 0, endRadius: 3 * r))
                        ctx.fill(
                            Path(ellipseIn: CGRect(around: p, radius: r)),
                            with: .color(color.opacity(fade * item.alpha)))
                    }
                }

                // Came online: one ring swells out of the node. Went offline: a dashed ring
                // closes in on it and fades.
                for (p, tint, online, age) in pulses {
                    let f = CGFloat(age / MapController.presencePulseDuration)
                    let e = 1 - pow(1 - f, 2)
                    if online {
                        let r = icon * (0.55 + 0.6 * e)
                        let rect = CGRect(around: p, radius: r)
                        ctx.fill(
                            Path(ellipseIn: rect),
                            with: .radialGradient(
                                Gradient(colors: [
                                    MapStyle.pingOK.opacity(0),
                                    MapStyle.pingOK.opacity(0.16 * (1 - f)),
                                ]),
                                center: p, startRadius: r * 0.55, endRadius: r))
                        ctx.stroke(Path(ellipseIn: rect), with: .color(tint.opacity(0.65 * (1 - f))), lineWidth: 1.5)
                    } else {
                        let r = icon * (1.15 - 0.55 * e)
                        let rect = CGRect(around: p, radius: r)
                        ctx.stroke(
                            Path(ellipseIn: rect), with: .color(Color.secondary.opacity(0.55 * sin(CGFloat.pi * f))),
                            style: StrokeStyle(lineWidth: 1.25, dash: [3, 3]))
                    }
                }

                // Newly discovered: two soft rings.
                for (p, tint, age) in born {
                    for k in 0..<2 {
                        let f = CGFloat((age - Double(k) * 0.55) / 1.2)
                        guard f > 0, f < 1 else { continue }
                        let r = icon * (0.6 + 0.9 * f)
                        let rect = CGRect(around: p, radius: r)
                        ctx.fill(
                            Path(ellipseIn: rect),
                            with: .radialGradient(
                                Gradient(colors: [tint.opacity(0), tint.opacity(0.22 * (1 - f))]),
                                center: p, startRadius: r * 0.5, endRadius: r))
                        ctx.stroke(Path(ellipseIn: rect), with: .color(tint.opacity(0.6 * (1 - f))), lineWidth: 1.5)
                    }
                }
            }
            .allowsHitTesting(false)
        }
    }

    private func packet(
        _ ctx: inout GraphicsContext, at point: (CGFloat) -> CGPoint, phase f: CGFloat,
        color: Color, tail: Bool
    ) {
        let fade = sin(.pi * f)
        for i in stride(from: 4, through: 0, by: -1) where tail || i == 0 {
            let ff = max(0, f - CGFloat(i) * 0.025)
            let p = point(ff)
            let r: CGFloat = 2.4 - CGFloat(i) * 0.35
            let a = fade * (1 - CGFloat(i) * 0.2)
            if i == 0 {
                ctx.fill(
                    Path(ellipseIn: CGRect(x: p.x - 3 * r, y: p.y - 3 * r, width: 6 * r, height: 6 * r)),
                    with: .radialGradient(
                        Gradient(colors: [color.opacity(0.45 * a), color.opacity(0)]),
                        center: p, startRadius: 0, endRadius: 3 * r))
            }
            ctx.fill(
                Path(ellipseIn: CGRect(around: p, radius: r)),
                with: .color(color.opacity(a)))
        }
    }
}
