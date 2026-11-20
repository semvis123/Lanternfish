import AppKit
import LanternfishKit
import SwiftUI

/// Debug hooks for the network map (call from ContentView.onAppear).
@MainActor
enum MapDebug {
    /// LANTERNFISH_VIEW=map starts in map mode.
    static func applyEnv() {
        if DebugEnv.values["LANTERNFISH_VIEW"] == "map" {
            Router.shared.viewMode = .map
        }
    }
}

/// Debug aid: renders the network map offscreen to a PNG with `ImageRenderer`.
///   LANTERNFISH_MAP_SNAPSHOT=/path.png
///   LANTERNFISH_MAP_SNAPSHOT_DELAY=seconds   (default 6; waits for devices to stream in)
///   LANTERNFISH_MAP_SNAPSHOT_SIZE=WxH        (default 1100x760)
///   LANTERNFISH_MAP_SNAPSHOT_SELECT=<ip>     (optional selected device)
///   LANTERNFISH_MAP_SNAPSHOT_ZOOM=0.5        (optional zoom around the fitted centre; default: fit)
///   LANTERNFISH_MAP_SNAPSHOT_FOCUS=<ip>      (optional: centre the zoomed snapshot on a device)
///   LANTERNFISH_MAP_SNAPSHOT_HOVER=<ip>      (optional hovered device)
///   LANTERNFISH_MAP_SNAPSHOT_FAKE=<n>        (optional: add n synthetic devices, for density checks)
///   LANTERNFISH_APPEARANCE=light|dark        (default: the app's appearance)
/// The force layout is run to rest synchronously, so the image shows the settled map.
/// The glass zoom control is drawn by AppKit and does not appear in the image.
@MainActor
enum MapSnapshot {
    static func renderIfRequested(store: ScanStore) {
        let env = DebugEnv.values
        guard let path = env["LANTERNFISH_MAP_SNAPSHOT"] else { return }
        let delay = DebugEnv.seconds("LANTERNFISH_MAP_SNAPSHOT_DELAY", default: 6)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            render(store: store, to: path)
        }
    }

    static func render(store: ScanStore, to path: String) {
        let env = DebugEnv.values
        let dims = (env["LANTERNFISH_MAP_SNAPSHOT_SIZE"] ?? "1100x760").split(separator: "x").compactMap { Double($0) }
        let size = dims.count == 2 ? CGSize(width: dims[0], height: dims[1]) : CGSize(width: 1100, height: 760)
        let selected = env["LANTERNFISH_MAP_SNAPSHOT_SELECT"].flatMap(IPv4Address.init)
        let scheme =
            DebugEnv.colorScheme
            ?? (NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light)

        var devices = store.devices
        if let n = env["LANTERNFISH_MAP_SNAPSHOT_FAKE"].flatMap(Int.init) { devices += fakeDevices(n) }

        let controller = MapController()
        controller.isSnapshot = true
        controller.size = size
        let model = MapModel(devices: devices, allDevices: store.devices, gateway: store.selectedInterface?.gateway)
        controller.sync(model, networkKey: store.mapNetworkKey)
        controller.settleNow()
        if let z = env["LANTERNFISH_MAP_SNAPSHOT_ZOOM"].flatMap(Double.init) {
            var v = controller.viewport(in: size)
            v.zoom = CGFloat(z)
            if let ip = env["LANTERNFISH_MAP_SNAPSHOT_FOCUS"].flatMap(IPv4Address.init), let n = controller.node(ip) {
                v.focus = n.position
            }
            controller.setViewport(v)
        }
        controller.hovered = env["LANTERNFISH_MAP_SNAPSHOT_HOVER"].flatMap(IPv4Address.init)
        controller.activity = MapActivity(pings: [:], isScanning: store.isScanning)

        let view = NetworkMapView(
            devices: devices, selection: .constant(selected), store: store, controller: controller
        )
        .frame(width: size.width, height: size.height)
        .environment(\.colorScheme, scheme)
        .environment(\.displayScale, 2)
        let renderer = ImageRenderer(content: view)
        renderer.proposedSize = ProposedViewSize(size)
        renderer.scale = 2
        // Resolve dynamic NSColors (the map background) for the requested appearance.
        var image: NSImage?
        NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
            image = renderer.nsImage
        }
        guard let cg = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let rep = NSBitmapImageRep(cgImage: cg)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    /// Synthetic devices of every kind on 10.99.x.x, deterministic.
    static func fakeDevices(_ n: Int) -> [Device] {
        let kinds: [DeviceKind] = [
            .computer, .phone, .iot, .iot, .tv, .speaker, .unknown, .printer, .nas,
            .tablet, .camera, .gameConsole, .iot, .unknown, .phone,
        ]
        let names = [
            "Hue Bridge", "Living Room", "Kitchen Plug", "Office Laptop", "Pixel 9", "Nest Mini",
            "Thermostat", "Garage Cam", "Plex", "Switch", "Desk Lamp", "Doorbell", "ESP-32A1",
            "LaserJet", "iPad Pro",
        ]
        return (0..<n).map { i in
            var d = Device(ip: IPv4Address(0x0A63_0000 + UInt32(i + 2)))
            d.kind = kinds[i % kinds.count]
            d.name = i % 4 == 3 ? nil : "\(names[i % names.count]) \(i)"
            d.isOnline = i % 11 != 5
            d.isNew = i % 17 == 3
            return d
        }
    }
}
