import AppKit
import LanternfishKit
import QuartzCore
import SwiftUI

/// A running ping as the map shows it.
struct MapPing: Equatable {
    /// The latest echo got a reply.
    var ok: Bool
    /// Latest round trip, seconds.
    var rtt: Double?
}

/// What the activity layer animates.
struct MapActivity: Equatable {
    var pings: [IPv4Address: MapPing] = [:]
    var isScanning = false
}

/// A ring on a node whose device just came online (expands) or went offline (contracts).
struct MapPresencePulse: Equatable {
    var online: Bool
    /// CACurrentMediaTime of the change.
    var at: Double
}

/// One device node's live state. Each node is its own observable object, so a frame in which
/// only a few nodes move only re-renders those nodes.
@MainActor
@Observable
final class MapNodeState: Identifiable {
    let id: IPv4Address
    var device: Device
    /// Layout coordinates (router at the origin).
    var position: CGPoint
    /// 0…1: fades in as the node enters, out as it leaves.
    var appear: Double = 1
    var isPinned = false
    var isRemoving = false
    /// Connectors bend towards this angle (the middle of the node's group sector).
    var bendAngle: CGFloat
    /// When the node was discovered while the map was open (drives a short glow pulse).
    var bornAt: Double?
    /// Where its name label goes (see `MapController.refreshLabels`).
    var label = MapLabelPlacement()
    @ObservationIgnored var removedAt: Double?

    init(id: IPv4Address, device: Device, position: CGPoint, bendAngle: CGFloat) {
        self.id = id
        self.device = device
        self.position = position
        self.bendAngle = bendAngle
    }
}

/// Drives the network map: owns the force simulation, node states, the viewport (with
/// animated transitions and momentum), hover / drag state and pinned positions.
///
/// Frames come from a display link that only runs while something moves — the simulation is
/// awake, the viewport animates, nodes fade, or activity (pings, scanning, pulses) is shown.
@MainActor
@Observable
final class MapController {
    static let glowDuration: Double = 2.2
    static let uplinkPulseDuration: Double = 1.5
    static let uplinkPulseInterval: TimeInterval = 12
    static let presencePulseDuration: Double = 1.4
    /// Fade-in of a new node and fade-out of a removed one, in seconds.
    static let appearDuration: Double = 0.3
    static let removeDuration: Double = 0.28
    /// One click of the zoom buttons and ⌘+ / ⌘−.
    static let zoomStep: CGFloat = 1.25

    private(set) var nodes: [MapNodeState] = []
    @ObservationIgnored private var byID: [IPv4Address: MapNodeState] = [:]
    @ObservationIgnored private(set) var sim = MapSimulation(nodeSize: MapModel.nodeSize)
    /// Bumped whenever node positions change (connector layer redraws).
    private(set) var frame = 0
    /// Animation clock (CACurrentMediaTime), advanced only while activity animates.
    private(set) var now: Double = CACurrentMediaTime()

    var hovered: IPv4Address? {
        didSet { if hovered != oldValue { refreshLabels() } }
    }
    /// The selected device: its label is always shown and placed before others.
    var selection: IPv4Address? {
        didSet { if selection != oldValue { refreshLabels() } }
    }
    private(set) var dragging: IPv4Address?
    @ObservationIgnored private var dragOffset: CGPoint = .zero
    /// Any pinned device on this network (shows "Reset Layout").
    private(set) var hasPins = false

    // Viewport. `manual == nil` means "fit the map".
    private(set) var manual: MapViewport?
    private(set) var displayed: MapViewport?
    @ObservationIgnored private var viewportAnimation: (from: MapViewport, start: Double, duration: Double)?
    @ObservationIgnored var size: CGSize = .zero {
        didSet { if size != oldValue { refreshLabels() } }
    }
    private(set) var fitBounds: CGRect?
    var isFit: Bool { manual == nil }

    var activity = MapActivity() {
        didSet { if activity != oldValue { wake() } }
    }
    private(set) var uplinkPulse: Double?
    /// Presence pulses by `DeviceArrivals.key(for:)`; pruned once they've played.
    private(set) var presencePulses: [String: MapPresencePulse] = [:]
    @ObservationIgnored private var presenceSeq = 0
    @ObservationIgnored var reduceMotion = false
    /// Offscreen rendering: no display link, everything placed at rest.
    @ObservationIgnored var isSnapshot = false

    @ObservationIgnored var pinStore = MapPinStore()
    @ObservationIgnored private(set) var networkKey = ""
    @ObservationIgnored private var pinKeys: [IPv4Address: String] = [:]
    @ObservationIgnored private var layoutBounds: CGRect?
    @ObservationIgnored private var didInitialSync = false
    @ObservationIgnored private var seen: Set<IPv4Address> = []
    @ObservationIgnored private var lastTick: Double?
    @ObservationIgnored private var wasActive = false
    @ObservationIgnored private var lastDebug: Double = 0
    /// LANTERNFISH_MAP_DEBUG=1 logs why frames are running.
    static let debug = DebugEnv.values["LANTERNFISH_MAP_DEBUG"] == "1"
    private static func log(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
    @ObservationIgnored private var uplinkTimer: Timer?
    /// What label placement avoids besides the nodes (router, internet, sector captions).
    @ObservationIgnored private var labelScene = MapLabelScene()
    @ObservationIgnored private var labelKey: MapLabelKey?
    /// Set by the display link host: unpauses it.
    @ObservationIgnored var wakeHandler: (() -> Void)?

    func node(_ id: IPv4Address) -> MapNodeState? { byID[id] }

    /// Last computed model and its inputs (layout is only recomputed when the devices change).
    @ObservationIgnored private var cachedModel: (key: MapModelKey, model: MapModel)?

    /// The map model for these devices, reused while they don't change.
    func model(devices: [Device], allDevices: [Device], gateway: IPv4Address?) -> MapModel {
        let key = MapModelKey(devices: devices, allDevices: allDevices, gateway: gateway)
        if let c = cachedModel, c.key == key { return c.model }
        let m = MapModel(devices: devices, allDevices: allDevices, gateway: gateway)
        cachedModel = (key, m)
        return m
    }

    var canZoomIn: Bool { viewport(in: size).zoom < MapViewport.zoomRange.upperBound - 0.001 }
    var canZoomOut: Bool { viewport(in: size).zoom > MapViewport.zoomRange.lowerBound + 0.001 }

    /// Only ambient animation is running (pings, scan ripple, pulses; nothing moves): the display
    /// link drops to ~30 fps.
    @ObservationIgnored private(set) var prefersLowFrameRate = false

    // MARK: Model sync

    /// Applies a new device list / layout. New nodes spring out of the router (unless Reduce
    /// Motion is on or this is a snapshot); removed ones fade out.
    func sync(_ model: MapModel, networkKey: String) {
        let networkChanged = networkKey != self.networkKey
        self.networkKey = networkKey
        let stored = pinStore.pins(network: networkKey)
        let layout = model.layout
        labelScene = MapLabelScene(model: model, revision: labelScene.revision &+ 1)
        let sectorAngle = Dictionary(layout.groupLabels.map { ($0.index, $0.angle) }, uniquingKeysWith: { a, _ in a })

        var targets: [(IPv4Address, CGPoint)] = []
        var pins: [IPv4Address: CGPoint] = [:]
        var bends: [IPv4Address: CGFloat] = [:]
        pinKeys = [:]
        for d in model.nodes {
            guard let p = layout.positions[d.id] else { continue }
            targets.append((d.id, p))
            pinKeys[d.id] = d.mapPinKey
            if let pin = stored[d.mapPinKey] { pins[d.id] = pin }
            let g = model.groups.firstIndex(of: MapGroup(kind: d.effectiveKind))
            bends[d.id] = g.flatMap { sectorAngle[$0] } ?? atan2(p.y, p.x)
        }
        if let id = dragging, !pinKeys.keys.contains(id) { dragging = nil }

        let still = reduceMotion || isSnapshot
        let entrance: MapSimulation.Entrance =
            still || networkChanged && didInitialSync
            ? .place : .spawn(from: .zero, stagger: didInitialSync ? 0.05 : 0.014)
        let removed = sim.update(
            targets: targets, pins: pins, obstacles: [.zero, layout.internet],
            entrance: entrance)
        if still { sim.settle() }

        let t = CACurrentMediaTime()
        var list: [MapNodeState] = []
        list.reserveCapacity(targets.count)
        for d in model.nodes {
            guard let body = sim.body(d.id) else { continue }
            let state: MapNodeState
            if let s = byID[d.id] {
                state = s
                if s.device != d { s.device = d }
                if s.isRemoving {
                    s.isRemoving = false
                    s.removedAt = nil
                }
            } else {
                state = MapNodeState(id: d.id, device: d, position: body.position, bendAngle: bends[d.id] ?? 0)
                byID[d.id] = state
                if didInitialSync, !seen.contains(d.id), !still { state.bornAt = t }
                seen.insert(d.id)
            }
            if let b = bends[d.id], state.bendAngle != b { state.bendAngle = b }
            if state.isPinned != body.isPinned { state.isPinned = body.isPinned }
            state.appear = still ? 1 : min(1, max(0, body.age / Self.appearDuration))
            list.append(state)
        }
        for id in removed {
            guard let s = byID[id] else { continue }
            if still || isSnapshot {
                byID[id] = nil
            } else {
                s.isRemoving = true
                s.removedAt = t
            }
        }
        for s in nodes where s.isRemoving && byID[s.id] === s && !list.contains(where: { $0 === s }) {
            list.append(s)
        }
        if list.map(\.id) != nodes.map(\.id) || zip(list, nodes).contains(where: { $0 !== $1 }) {
            nodes = list
        }
        if hasPins != !stored.isEmpty { hasPins = !stored.isEmpty }

        layoutBounds = layout.bounds
        updateFitBounds(animated: didInitialSync && !networkChanged)
        didInitialSync = true
        copyPositions()
        wake()
    }

    /// Layout bounds grown to include pinned nodes.
    private func updateFitBounds(animated: Bool) {
        guard var b = layoutBounds else { return }
        let pad = MapModel.nodeSize / 2
        for body in sim.bodies {
            if let p = body.pin { b = b.union(CGRect(x: p.x - pad, y: p.y - pad, width: 2 * pad, height: 2 * pad)) }
        }
        guard b != fitBounds else { return }
        if animated, isFit, !reduceMotion, size.width > 0 {
            beginViewportAnimation(duration: 0.55)
        }
        fitBounds = b
    }

    private func copyPositions() {
        var moved = false
        for s in nodes where !s.isRemoving {
            if let p = sim.position(of: s.id), p != s.position {
                s.position = p
                moved = true
            }
        }
        if moved { frame &+= 1 }
        refreshLabels()
    }

    // MARK: Frames

    func start() {
        guard uplinkTimer == nil, !isSnapshot else { return }
        let timer = Timer(timeInterval: Self.uplinkPulseInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pulseUplink() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        uplinkTimer = timer
        // A first pulse shortly after the map appears.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            MainActor.assumeIsolated { self?.pulseUplink() }
        }
    }

    func stop() {
        uplinkTimer?.invalidate()
        uplinkTimer = nil
    }

    private func pulseUplink() {
        guard !reduceMotion, !isSnapshot, uplinkTimer != nil else { return }
        uplinkPulse = CACurrentMediaTime()
        wake()
    }

    /// Arrivals / departures from the store: each new one gets a pulse ring (waking the display
    /// link, which pauses again once the rings have played). Old events (from before the map was
    /// shown) are skipped.
    func notePresence(_ events: [DeviceArrivals.Event]) {
        let fresh = events.filter { $0.seq > presenceSeq }
        guard let last = fresh.last else { return }
        presenceSeq = last.seq
        guard !reduceMotion, !isSnapshot else { return }
        let t = CACurrentMediaTime()
        let wall = Date()
        var pulses = presencePulses
        for e in fresh {
            let age = wall.timeIntervalSince(e.at)
            guard age >= 0, age < Self.presencePulseDuration * 0.5 else { continue }
            pulses[e.key] = MapPresencePulse(online: e.online, at: t - age)
        }
        if Self.debug { Self.log("map presence: \(fresh.count) event(s), \(pulses.count) pulse(s)") }
        if pulses != presencePulses {
            presencePulses = pulses
            wake()
        }
    }

    func wake() {
        guard !isSnapshot else { return }
        wakeHandler?()
    }

    /// One display frame. Returns false when nothing needs further frames (the link pauses).
    func tick(_ t: Double) -> Bool {
        let dt = lastTick.map { min(max(t - $0, 0), 0.1) } ?? 1.0 / 60
        lastTick = t

        if !sim.isAsleep {
            sim.advance(by: dt)
            copyPositions()
        }

        var fading = false
        var finished: [IPv4Address] = []
        for s in nodes {
            let a: Double
            if s.isRemoving {
                a = max(0, 1 - (t - (s.removedAt ?? t)) / Self.removeDuration)
                if a == 0 { finished.append(s.id) }
            } else if let b = sim.body(s.id) {
                a = min(1, max(0, b.age / Self.appearDuration))
            } else {
                a = 1
            }
            if s.appear != a { s.appear = a }
            if a < 1 { fading = true }
        }
        if !finished.isEmpty {
            for id in finished where byID[id]?.isRemoving == true { byID[id] = nil }
            nodes.removeAll { finished.contains($0.id) && $0.isRemoving }
            frame &+= 1
        }

        if let anim = viewportAnimation {
            let f = min(1, (t - anim.start) / anim.duration)
            if f >= 1 {
                viewportAnimation = nil
                displayed = nil
            } else {
                // Ease out (cubic): quick start, soft landing — reads as momentum.
                let e = 1 - pow(1 - f, 3)
                displayed = MapViewport.interpolate(anim.from, targetViewport(in: size), CGFloat(e))
            }
        }

        if !presencePulses.isEmpty {
            let live = presencePulses.filter { t - $0.value.at < Self.presencePulseDuration }
            if live.count != presencePulses.count { presencePulses = live }
        }
        let active = activityNeedsFrames(t)
        // Ambient activity alone (nothing moving) is drawn at ~30 fps: it's slow and soft anyway.
        // One more clock tick after activity ends clears its last frame.
        let ambientOnly = sim.isAsleep && viewportAnimation == nil && !fading && dragging == nil
        prefersLowFrameRate = ambientOnly
        if active && !(ambientOnly && t - now < 1.0 / 32) || wasActive && !active { now = t }
        wasActive = active
        refreshLabels()
        let keepGoing = !sim.isAsleep || viewportAnimation != nil || fading || active || wasActive
        if !keepGoing { lastTick = nil }
        if Self.debug, t - lastDebug > 1 {
            lastDebug = t
            Self.log(
                "map tick: awake=\(!sim.isAsleep) viewport=\(viewportAnimation != nil) fading=\(fading)"
                    + " activity=\(active) scanning=\(activity.isScanning) pings=\(activity.pings.count)")
        }
        return keepGoing
    }

    /// Continuous animations that are currently visible.
    func activityNeedsFrames(_ t: Double) -> Bool {
        guard !reduceMotion else { return false }
        if activity.isScanning || !activity.pings.isEmpty { return true }
        if let u = uplinkPulse, t - u < Self.uplinkPulseDuration { return true }
        if presencePulses.values.contains(where: { t - $0.at < Self.presencePulseDuration }) { return true }
        return nodes.contains { $0.bornAt.map { t - $0 < Self.glowDuration } ?? false }
    }

    // MARK: Viewport

    func viewport(in size: CGSize) -> MapViewport {
        displayed ?? targetViewport(in: size)
    }

    private func targetViewport(in size: CGSize) -> MapViewport {
        manual ?? MapViewport.fit(fitBounds ?? CGRect(x: -200, y: -260, width: 400, height: 460), in: size)
    }

    /// Jumps (no animation), e.g. while a gesture tracks the pointer.
    func setViewport(_ v: MapViewport) {
        viewportAnimation = nil
        displayed = nil
        manual = clamped(v)
        refreshLabels()
    }

    /// Animates to `v` (nil = fit the map).
    func animateViewport(to v: MapViewport?, duration: Double = 0.45) {
        beginViewportAnimation(duration: duration)
        manual = v.map(clamped)
        if reduceMotion {
            viewportAnimation = nil
            displayed = nil
        }
        refreshLabels()
    }

    private func beginViewportAnimation(duration: Double) {
        guard size.width > 0, !isSnapshot else { return }
        let from = viewport(in: size)
        viewportAnimation = (from, CACurrentMediaTime(), duration)
        displayed = from
        wake()
    }

    private func clamped(_ v: MapViewport) -> MapViewport {
        var v = v
        v.zoom = min(max(v.zoom, MapViewport.zoomRange.lowerBound), MapViewport.zoomRange.upperBound)
        return v
    }

    func zoom(by factor: CGFloat, anchor: CGPoint? = nil, animated: Bool = true) {
        let current = viewport(in: size)
        let a = anchor ?? CGPoint(x: size.width / 2, y: size.height / 2)
        let base = viewportAnimation == nil ? current : (manual ?? current)
        let v = base.zoomed(to: base.zoom * factor, anchor: a, in: size)
        if animated { animateViewport(to: v, duration: 0.32) } else { setViewport(v) }
    }

    func fit() { animateViewport(to: nil, duration: 0.5) }

    /// Trackpad / wheel input over the map. Scrolling zooms around the pointer (like Maps and
    /// Figma): the point under the cursor stays put. Exponential in the delta, so it's smooth
    /// and continuous through the trackpad's momentum phase. ⇧ or ⌥ + scroll pans instead.
    func scroll(_ s: MapInputMonitor.Scroll, at location: CGPoint) {
        if s.shift || s.option {
            let k: CGFloat = s.precise ? 1 : 10
            setViewport(viewport(in: size).panned(by: CGSize(width: s.dx * k, height: s.dy * k)))
            return
        }
        guard s.dy != 0 else { return }
        // Trackpads report pixels; wheels report lines (≈1 per notch, accelerated).
        let k: CGFloat = s.precise ? 0.0065 : 0.13
        let factor = exp(max(min(s.dy * k, 0.7), -0.7))
        let base = viewport(in: size)
        setViewport(base.zoomed(to: base.zoom * factor, anchor: location, in: size))
    }

    // MARK: Direct manipulation

    /// Drags a node; `location` is in map view coordinates.
    func drag(_ id: IPv4Address, to location: CGPoint) {
        guard let state = byID[id], !state.isRemoving else { return }
        let vp = viewport(in: size)
        let w = vp.toWorld(location, in: size)
        if dragging != id {
            // Freeze the viewport so a fitted map doesn't re-fit under the pointer.
            if isFit { setViewport(vp) }
            dragging = id
            sim.beginDrag(id)
            let p = sim.position(of: id) ?? w
            dragOffset = CGPoint(x: p.x - w.x, y: p.y - w.y)
            state.bornAt = nil
        }
        sim.drag(id, to: CGPoint(x: w.x + dragOffset.x, y: w.y + dragOffset.y))
        copyPositions()
        wake()
    }

    /// Drops the dragged node; it stays pinned where it was dropped.
    func endDrag(_ id: IPv4Address) {
        guard dragging == id else { return }
        dragging = nil
        sim.endDrag(id, pin: true)
        if let p = sim.position(of: id), let key = pinKeys[id] {
            pinStore.setPin(p, device: key, network: networkKey)
            hasPins = true
        }
        byID[id]?.isPinned = true
        updateFitBounds(animated: false)
        refreshLabels()
        wake()
    }

    func unpin(_ id: IPv4Address) {
        sim.setPin(id, nil)
        if let key = pinKeys[id] { pinStore.setPin(nil, device: key, network: networkKey) }
        byID[id]?.isPinned = false
        hasPins = !pinStore.pins(network: networkKey).isEmpty
        updateFitBounds(animated: true)
        wake()
    }

    /// Unpins every device on this network; nodes spring back and the map re-fits.
    func resetLayout() {
        pinStore.clear(network: networkKey)
        for s in nodes where s.isPinned {
            sim.setPin(s.id, nil)
            s.isPinned = false
        }
        hasPins = false
        updateFitBounds(animated: false)
        fit()
        wake()
    }

    /// Snapshot support: settle synchronously.
    func settleNow() {
        sim.settle()
        copyPositions()
        for s in nodes { s.appear = 1 }
    }
}

// MARK: - Label placement

/// Inputs that change label placement; placement reruns only when this changes.
private struct MapLabelKey: Equatable {
    var zoom: CGFloat
    var frame: Int
    var hovered: IPv4Address?
    var dragging: IPv4Address?
    var selection: IPv4Address?
    var revision: Int
    var nodes: Int
}

/// The fixed things on the map that node labels keep clear of.
private struct MapLabelScene {
    var revision = 0
    var internet: CGPoint = .zero
    /// The centre node's caption: name, gateway address, model line.
    var router: (name: String, ip: IPv4Address?, model: String?)?
    var captions: [(label: MapLayout.GroupLabel, group: MapGroup, count: Int)] = []

    init() {}

    init(model: MapModel, revision: Int) {
        self.revision = revision
        internet = model.layout.internet
        switch model.center {
        case .device(let d, _):
            router = (
                d.mapName, d.ip == model.gatewayAddress ? d.ip : nil,
                d.ip == model.gatewayAddress ? d.gatewayModelLine : nil
            )
        case .hub(let gw):
            router = (gw == nil ? "No Gateway" : "Router", gw, nil)
        }
        captions = model.layout.groupLabels.compactMap { label in
            guard label.index < model.groups.count else { return nil }
            let g = model.groups[label.index]
            return (label, g, model.nodes.count { MapGroup(kind: $0.effectiveKind) == g })
        }
    }
}

extension MapController {
    /// Re-places node name labels for the current zoom so they don't cover other nodes' icons,
    /// the router / internet captions, sector captions or each other (see `MapLabelPlacer`).
    /// Labels that find no free spot fade, except hovered / selected / "This Mac". Cheap when
    /// nothing relevant changed, so it's called liberally.
    func refreshLabels() {
        let zoom = viewport(in: size).zoom
        let key = MapLabelKey(
            zoom: zoom, frame: frame, hovered: hovered, dragging: dragging, selection: selection,
            revision: labelScene.revision, nodes: nodes.count)
        guard key != labelKey else { return }
        labelKey = key

        let m = MapNodeMetrics(zoom: zoom)
        var items: [MapLabelPlacer.Item] = []
        items.reserveCapacity(nodes.count)
        for s in nodes where !s.isRemoving {
            let d = s.device
            let lifted = s.id == hovered || s.id == dragging
            let selected = s.id == selection
            let required = lifted || selected || d.isSelf
            let label =
                required || m.labelOpacity > 0.01
                ? MapLabelSizing.deviceLabel(
                    d, metrics: m, emphasized: required,
                    detail: m.detailOpacity > 0.01 || selected || lifted)
                : nil
            items.append(
                MapLabelPlacer.Item(
                    id: s.id, center: CGPoint(x: s.position.x * zoom, y: s.position.y * zoom),
                    iconSize: lifted ? m.icon * 1.08 : m.icon, labelSize: label,
                    priority: lifted ? 4 : selected ? 3 : d.isSelf ? 2 : 0, isRequired: required))
        }

        // Router and its caption.
        let rm = MapNodeMetrics.router(zoom: zoom)
        var obstacles = [MapLabelPlacer.iconRect(center: .zero, size: rm.icon)]
        if let r = labelScene.router {
            obstacles.append(
                MapLabelPlacer.labelRect(
                    center: .zero, iconSize: rm.icon,
                    labelSize: MapLabelSizing.routerLabel(name: r.name, ip: r.ip, model: r.model, metrics: rm),
                    side: .below))
        }
        // Internet and its caption (sizes as `MapInternetNode` draws them).
        let net = CGPoint(x: labelScene.internet.x * zoom, y: labelScene.internet.y * zoom)
        let netIcon = MapInternetNode.iconSize(zoom: zoom)
        let netFont = MapInternetNode.captionFontSize(zoom: zoom)
        obstacles.append(MapLabelPlacer.iconRect(center: net, size: netIcon))
        obstacles.append(
            MapLabelPlacer.labelRect(
                center: net, iconSize: netIcon,
                labelSize: CGSize(
                    width: MapLabelSizing.width("Internet", size: netFont, weight: .medium) + 8,
                    height: MapLabelSizing.lineHeight(netFont)), side: .below))
        // Sector captions.
        if MapCaptions.opacity(zoom: zoom) > 0.01 {
            for c in labelScene.captions {
                obstacles.append(MapCaptions.box(c.label, group: c.group, count: c.count, zoom: zoom))
            }
        }

        let placed = MapLabelPlacer.place(items, obstacles: obstacles)
        for s in nodes {
            let p = placed[s.id] ?? MapLabelPlacement()
            if s.label != p { s.label = p }
        }
    }
}

// MARK: - Display link

/// Hosts a `CADisplayLink` for the map. The link pauses itself whenever the controller has
/// nothing to animate, so an idle map costs no CPU.
struct MapFrameDriver: NSViewRepresentable {
    let controller: MapController
    /// Told the window the map lives in (the scroll monitor only handles that window's events).
    var onWindow: (NSWindow?) -> Void = { _ in }

    func makeNSView(context: Context) -> MapFrameDriverView {
        let v = MapFrameDriverView()
        v.controller = controller
        v.onWindow = onWindow
        return v
    }

    func updateNSView(_ nsView: MapFrameDriverView, context: Context) {
        if nsView.controller !== controller {
            nsView.controller = controller
            nsView.connect()
        }
    }

    static func dismantleNSView(_ nsView: MapFrameDriverView, coordinator: ()) {
        nsView.invalidate()
    }
}

final class MapFrameDriverView: NSView {
    weak var controller: MapController?
    var onWindow: (NSWindow?) -> Void = { _ in }
    private var link: CADisplayLink?
    private var lowRate = false
    /// False while the window is minimized or fully covered: no frames then.
    private var windowVisible = true
    private let visibility = WindowVisibilityObserver()

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindow(window)
        link?.invalidate()
        link = nil
        visibility.observe(window) { [weak self] in self?.visibilityChanged() }
        guard let window else { return }
        windowVisible = window.isVisibleOnScreen
        let l = displayLink(target: self, selector: #selector(step(_:)))
        l.add(to: .main, forMode: .common)
        link = l
        connect()
    }

    private func visibilityChanged() {
        guard let visible = window?.isVisibleOnScreen, visible != windowVisible else { return }
        windowVisible = visible
        // Hidden: pause. Visible again: catch up (the controller decides whether to keep going).
        link?.isPaused = !visible
    }

    func connect() {
        controller?.wakeHandler = { [weak self] in
            guard let self, self.windowVisible else { return }
            self.link?.isPaused = false
        }
        link?.isPaused = !windowVisible
    }

    func invalidate() {
        link?.invalidate()
        link = nil
        visibility.stop()
    }

    @objc private func step(_ l: CADisplayLink) {
        guard let controller, windowVisible else {
            l.isPaused = true
            return
        }
        if !controller.tick(l.targetTimestamp) { l.isPaused = true }
        // Ambient-only animation (soft and slow) doesn't need the display's full rate.
        if controller.prefersLowFrameRate != lowRate {
            lowRate = controller.prefersLowFrameRate
            l.preferredFrameRateRange = lowRate ? CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30) : .default
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Inputs of `MapModel`; the cached model is reused while these are equal.
private struct MapModelKey: Equatable {
    var devices: [Device]
    var allDevices: [Device]
    var gateway: IPv4Address?
}
