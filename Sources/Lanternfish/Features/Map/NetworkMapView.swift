import AppKit
import LanternfishKit
import SwiftUI

/// The network map: the internet above the router, every other device around it, grouped by
/// kind into tinted sectors.
///
/// Nodes live in a small force simulation (`MapSimulation`): they spring out of the router as
/// they're discovered, make room for each other and can be dragged; dropped nodes stay pinned.
/// Zooming moves *positions* and resizes nodes natively — content is never `scaleEffect`-ed,
/// so text, icons and hairline connectors stay sharp at every zoom.
///
/// Click selects (opens the inspector), double-click opens the device's web interface,
/// double-click empty space zooms in. Scroll / wheel / pinch zoom around the pointer,
/// drag on empty space (or ⇧/⌥-scroll) pans, ⌘+ ⌘− ⌘0 zoom and fit.
struct NetworkMapView: View {
    let devices: [Device]
    @Binding var selection: IPv4Address?
    let store: ScanStore
    /// Owned by the window (one per network), so the viewport survives switching views and networks.
    let controller: MapController

    @State private var input = MapInputMonitor()
    @State private var panStart: MapViewport?
    @State private var magnifyStart: MapViewport?
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(devices: [Device], selection: Binding<IPv4Address?>, store: ScanStore, controller: MapController) {
        self.devices = devices
        _selection = selection
        self.store = store
        self.controller = controller
    }

    var body: some View {
        // Cached by device list: a ping tick or hover doesn't recompute the layout.
        let model = controller.model(
            devices: devices, allDevices: store.devices,
            gateway: store.selectedInterface?.gateway)
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                MapBackdrop(controller: controller, model: model, size: size)
                    .contentShape(.rect)
                    .gesture(panGesture)
                    .gesture(
                        SpatialTapGesture(count: 2).onEnded { v in
                            controller.zoom(by: 1.8, anchor: v.location)
                        }
                    )
                    .simultaneousGesture(
                        TapGesture().onEnded {
                            selection = nil
                            focused = true
                        }
                    )
                    .accessibilityHidden(true)

                if !devices.isEmpty {
                    content(model, size: size)
                }
            }
            .coordinateSpace(.named(MapSpace.name))
            .clipped()
            .simultaneousGesture(magnifyGesture(size: size))
            .overlay(alignment: .bottomTrailing) {
                if !devices.isEmpty {
                    MapControls(controller: controller, size: size)
                        .padding(12)
                }
            }
            .background {
                if !controller.isSnapshot {
                    MapFrameDriver(controller: controller, onWindow: { input.window = $0 })
                        .frame(width: 0, height: 0)
                    // Reads the store's pings / scanning state, so their ticks don't re-render the map.
                    MapActivitySync(store: store, controller: controller)
                }
            }
            .onContinuousHover(coordinateSpace: .named(MapSpace.name)) { phase in
                if case .active(let p) = phase { input.hoverLocation = p } else { input.hoverLocation = nil }
            }
            .onChange(of: size, initial: true) { controller.size = size }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilitySummary(model))
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(keys: [.leftArrow, .upArrow, .rightArrow, .downArrow]) { press in
            let back = press.key == .leftArrow || press.key == .upArrow
            return selectNeighbor(back ? -1 : 1, in: model) ? .handled : .ignored
        }
        .onKeyPress(.escape) {
            guard selection != nil else { return .ignored }
            selection = nil
            return .handled
        }
        .onChange(of: reduceMotion, initial: true) { controller.reduceMotion = reduceMotion }
        .onChange(of: selection, initial: true) { controller.selection = selection }
        .onChange(of: MapSyncKey(model: model, network: networkKey), initial: true) {
            controller.sync(model, networkKey: networkKey)
        }
        .onAppear {
            input.onScroll = { [controller] s, location in controller.scroll(s, at: location) }
            input.install()
            controller.start()
        }
        .onDisappear {
            input.uninstall()
            controller.stop()
        }
    }

    /// "Network map, 12 devices".
    private func accessibilitySummary(_ model: MapModel) -> String {
        let n = model.nodes.count + (model.center.device == nil ? 0 : 1)
        return "Network map, \(n == 1 ? "1 device" : "\(n) devices")"
    }

    /// Devices in reading order: by name (VoiceOver order and arrow-key selection).
    private func byName(_ model: MapModel) -> [Device] {
        ((model.center.device.map { [$0] } ?? []) + model.nodes)
            .sorted { $0.mapName.localizedStandardCompare($1.mapName) == .orderedAscending }
    }

    /// Arrow keys: select the next / previous device by name. False when there is none.
    private func selectNeighbor(_ delta: Int, in model: MapModel) -> Bool {
        let list = byName(model)
        guard !list.isEmpty else { return false }
        let i = list.firstIndex { $0.id == selection }
        let next = i.map { ($0 + delta + list.count) % list.count } ?? (delta > 0 ? 0 : list.count - 1)
        selection = list[next].id
        return true
    }

    private var networkKey: String { store.mapNetworkKey }

    // MARK: Content

    @ViewBuilder
    private func content(_ model: MapModel, size: CGSize) -> some View {
        let layout = model.layout
        let outer = (layout.ringRadii.last ?? 160) + MapModel.nodeSize * 0.5
        let order = Dictionary(byName(model).enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        let reach = store.canReachDevices
        let routerIcon = MapNodeMetrics.router(zoom: controller.viewport(in: size).zoom).icon

        MapCaptions(controller: controller, model: model, size: size)
            .accessibilityHidden(true)

        MapConnectorLayer(
            controller: controller, size: size, internet: layout.internet,
            routerIcon: routerIcon, selection: selection
        )
        .accessibilityHidden(true)

        MapActivityLayer(
            controller: controller, size: size, internet: layout.internet,
            routerIcon: routerIcon, outerRadius: outer
        )
        .accessibilityHidden(true)

        // Hover target along the uplink (drawn in the connector canvas), for its tooltip.
        MapPositioned(
            controller: controller, size: size,
            point: CGPoint(x: layout.internet.x / 2, y: layout.internet.y / 2)
        ) { zoom in
            Color.clear
                .frame(width: 14, height: max(4, abs(layout.internet.y) * zoom * 0.45))
                .contentShape(.rect)
                .help(model.uplinkTooltip)
        }
        .accessibilityHidden(true)

        MapPositioned(controller: controller, size: size, point: layout.internet) { zoom in
            MapInternetNode(zoom: zoom, tooltip: model.uplinkTooltip)
        }
        .accessibilityHidden(true)

        // Router. Pings are read inside the positioned views, so a ping tick only re-renders those.
        MapPositioned(controller: controller, size: size, point: .zero) { zoom in
            let m = MapNodeMetrics.router(zoom: zoom)
            switch model.center {
            case .device(let d, let dimmed):
                let ping = controller.activity.pings[d.ip]
                interactive(d, pinnable: false, reachable: reach, order: order[d.id] ?? 0) {
                    MapDeviceNode(
                        device: d, metrics: m, isSelected: selection == d.id,
                        isHovered: controller.hovered == d.id,
                        isReceded: controller.hovered.map { $0 != d.id } ?? false,
                        isPinging: ping != nil, pingOK: ping?.ok ?? true, dimmed: dimmed,
                        isGateway: d.ip == model.gatewayAddress)
                }
            case .hub(let gw):
                MapHubNode(gateway: gw, metrics: m)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(gw.map { "Router, \($0.description)" } ?? "No gateway")
            }
        }

        // Devices, keyed by id: views persist and only move.
        ForEach(controller.nodes) { node in
            MapNodeHost(node: node, controller: controller, size: size) { metrics in
                let d = node.device
                let ping = controller.activity.pings[d.ip]
                interactive(d, pinnable: true, reachable: reach, order: order[d.id] ?? 0) {
                    MapDeviceNode(
                        device: d, metrics: metrics, isSelected: selection == d.id,
                        isHovered: controller.hovered == d.id,
                        isReceded: (controller.hovered ?? controller.dragging).map { $0 != d.id } ?? false,
                        isPinging: ping != nil, pingOK: ping?.ok ?? true,
                        isPinned: node.isPinned, isDragging: controller.dragging == d.id,
                        labelSide: node.label.side, labelVisible: node.label.isVisible)
                }
                .gesture(nodeDrag(node.id))
                .allowsHitTesting(!node.isRemoving)
                .accessibilityHidden(node.isRemoving)
            }
        }
    }

    private func interactive(
        _ d: Device, pinnable: Bool, reachable: Bool, order: Int,
        @ViewBuilder node: () -> some View
    ) -> some View {
        node()
            .onTapGesture {
                selection = d.id
                focused = true
            }
            .simultaneousGesture(
                TapGesture(count: 2).onEnded {
                    // Double-click opens the web page, only when the device is on a network being scanned.
                    if reachable, let url = d.preferredWebURL { DeviceActions.open(url) }
                }
            )
            .onHover { inside in
                if inside { controller.hovered = d.id } else if controller.hovered == d.id { controller.hovered = nil }
            }
            .help(d.mapTooltip)
            .contextMenu { contextMenu(d, pinnable: pinnable) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(d.mapAccessibilityLabel)
            .accessibilityAddTraits(selection == d.id ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { selection = d.id }
            // Higher priority is read first: name order.
            .accessibilitySortPriority(Double(10_000 - order))
    }

    @ViewBuilder
    private func contextMenu(_ d: Device, pinnable: Bool) -> some View {
        DeviceActionMenuItems(
            actions: DeviceActionSet(
                device: d, store: store,
                context: .init(show: { selection = d.id })))
        if pinnable, controller.node(d.id)?.isPinned == true {
            Divider()
            Button("Unpin", systemImage: "pin.slash") { controller.unpin(d.id) }
        }
    }

    // MARK: Gestures

    /// Drag on empty space pans; letting go glides on.
    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { g in
                let start = panStart ?? controller.viewport(in: controller.size)
                if panStart == nil { panStart = start }
                controller.setViewport(start.panned(by: g.translation))
            }
            .onEnded { g in
                guard let start = panStart else { return }
                panStart = nil
                let rest = CGSize(
                    width: g.predictedEndTranslation.width - g.translation.width,
                    height: g.predictedEndTranslation.height - g.translation.height)
                if hypot(rest.width, rest.height) > 20 {
                    let end = start.panned(
                        by: CGSize(
                            width: g.translation.width + rest.width * 0.6,
                            height: g.translation.height + rest.height * 0.6))
                    controller.animateViewport(to: end, duration: 0.6)
                }
            }
    }

    private func nodeDrag(_ id: IPv4Address) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named(MapSpace.name))
            .onChanged { g in controller.drag(id, to: g.location) }
            .onEnded { _ in controller.endDrag(id) }
    }

    private func magnifyGesture(size: CGSize) -> some Gesture {
        MagnifyGesture()
            .onChanged { g in
                let start = magnifyStart ?? controller.viewport(in: size)
                if magnifyStart == nil { magnifyStart = start }
                controller.setViewport(
                    start.zoomed(to: start.zoom * g.magnification, anchor: g.startLocation, in: size))
            }
            .onEnded { _ in magnifyStart = nil }
    }
}

private enum MapSpace {
    static let name = "NetworkMap"
}

extension ScanStore {
    /// Identifies the displayed network for the map; pins are remembered per network.
    var mapNetworkKey: String {
        displayedNetwork?.id ?? selectedInterface.map { "subnet:\($0.subnet)" } ?? "default"
    }
}

/// Re-syncs the simulation when the nodes, their details or the network change.
private struct MapSyncKey: Equatable {
    var nodes: [Device]
    var center: Device?
    var network: String

    init(model: MapModel, network: String) {
        nodes = model.nodes
        center = model.center.device
        self.network = network
    }
}

// MARK: - Positioning

/// A fixed map point (router, internet) placed on screen.
private struct MapPositioned<Content: View>: View {
    let controller: MapController
    let size: CGSize
    let point: CGPoint
    @ViewBuilder let content: (CGFloat) -> Content

    var body: some View {
        let vp = controller.viewport(in: size)
        content(vp.zoom).position(vp.toView(point, in: size))
    }
}

/// A simulated node placed at its live position. Only this view observes the node's
/// position, so a moving node doesn't re-render the others.
private struct MapNodeHost<Content: View>: View {
    let node: MapNodeState
    let controller: MapController
    let size: CGSize
    @ViewBuilder let content: (MapNodeMetrics) -> Content

    var body: some View {
        let vp = controller.viewport(in: size)
        let metrics = MapNodeMetrics(zoom: vp.zoom)
        // Entering nodes grow out of the router.
        let grow = 0.55 + 0.45 * CGFloat(node.appear)
        var m = metrics
        m.icon *= grow
        return content(m)
            .opacity(node.appear)
            .position(vp.toView(node.position, in: size))
    }
}

// MARK: - Controls

private struct MapControls: View {
    let controller: MapController
    let size: CGSize

    var body: some View {
        let zoom = controller.viewport(in: size).zoom
        HStack(spacing: 2) {
            if controller.hasPins {
                button("Reset Layout", "pin.slash", help: "Reset Layout (unpin all devices)") {
                    controller.resetLayout()
                }
                Divider().frame(height: 16).padding(.horizontal, 2)
            }
            // ⌘− ⌘+ ⌘0 live in the View menu (enabled while the map shows).
            button("Zoom Out", "minus.magnifyingglass", help: "Zoom Out (⌘−)") {
                controller.zoom(by: 1 / MapController.zoomStep)
            }
            .disabled(!controller.canZoomOut)
            Text("\(Int((zoom * 100).rounded())) %")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 42)
                .accessibilityLabel("Zoom \(Int((zoom * 100).rounded())) percent")
            button("Zoom In", "plus.magnifyingglass", help: "Zoom In (⌘+)") {
                controller.zoom(by: MapController.zoomStep)
            }
            .disabled(!controller.canZoomIn)
            Divider().frame(height: 16).padding(.horizontal, 2)
            button(
                "Fit Map", "arrow.up.left.and.down.right.and.arrow.up.right.and.down.left",
                help: "Fit Map (⌘0)"
            ) { controller.fit() }
            .disabled(controller.isFit)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background {
            // ⌘= also zooms in (the unshifted key of ⌘+ on most layouts).
            Button("") { controller.zoom(by: MapController.zoomStep) }
                .keyboardShortcut("=", modifiers: .command)
                .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
        }
        .glassEffect(.regular, in: .capsule)
        .animation(.snappy(duration: 0.2), value: controller.hasPins)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Map controls")
    }

    private func button(_ title: String, _ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .labelStyle(.iconOnly)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 26, height: 22)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Feeds the store's running pings, scanning state and arrivals to the map's activity layer. Its own view,
/// so the per-second ping updates only re-render this (and the nodes that read the pings).
private struct MapActivitySync: View {
    let store: ScanStore
    let controller: MapController

    var body: some View {
        let activity = MapActivity(pings: Self.pings(store), isScanning: store.isScanning)
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onChange(of: activity, initial: true) { _, a in controller.activity = a }
            .onChange(of: store.arrivals.events, initial: true) { _, e in controller.notePresence(e) }
    }

    static func pings(_ store: ScanStore) -> [IPv4Address: MapPing] {
        var out: [IPv4Address: MapPing] = [:]
        for (ip, s) in store.pingSessions where s.isRunning {
            let last = s.last
            out[ip] = MapPing(
                ok: last.map { $0.rtt != nil } ?? true,
                rtt: last?.rtt.map { Latency.ms($0) / 1000 })
        }
        return out
    }
}

// MARK: - Scroll input

/// Routes scroll-wheel events over the map to a handler. SwiftUI has no scroll-wheel
/// gesture outside ScrollView, so this uses a local event monitor that only consumes events
/// while the pointer is over the map, in the map's own window.
@MainActor
final class MapInputMonitor {
    var hoverLocation: CGPoint?
    weak var window: NSWindow?
    var onScroll: ((Scroll, CGPoint) -> Void)?
    private var monitor: Any?

    struct Scroll: Sendable {
        var dx: CGFloat, dy: CGFloat, precise: Bool, command: Bool, shift: Bool, option: Bool
    }

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            let flags = event.modifierFlags
            let scroll = Scroll(
                dx: event.scrollingDeltaX, dy: event.scrollingDeltaY,
                precise: event.hasPreciseScrollingDeltas, command: flags.contains(.command),
                shift: flags.contains(.shift), option: flags.contains(.option))
            let eventWindow = event.window
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard let self, let location = self.hoverLocation, let handler = self.onScroll,
                    let window = self.window, eventWindow === window, window.isVisible,
                    window.attachedSheet == nil
                else { return false }
                handler(scroll, location)
                return true
            }
            return consumed ? nil : event
        }
    }

    func uninstall() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
