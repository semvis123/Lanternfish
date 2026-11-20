import AppKit
import LanternfishKit
import SwiftUI

/// Map colours. Label plates use the background so connectors passing behind text don't cut it.
enum MapStyle {
    static let background = Color(nsColor: .controlBackgroundColor)
    static let pingOK = Color.green
    static let pingLost = Color.red
    static let uplink = Color(red: 0.2, green: 0.62, blue: 1)

    static func shadow(_ scheme: ColorScheme) -> Color {
        .black.opacity(scheme == .dark ? 0.5 : 0.16)
    }
}

func smoothstep(_ a: CGFloat, _ b: CGFloat, _ x: CGFloat) -> CGFloat {
    let t = min(max((x - a) / (b - a), 0), 1)
    return t * t * (3 - 2 * t)
}

/// Sizes of a node at a zoom level. Nodes are laid out at their real on-screen size (never
/// `scaleEffect`), so icons and text are always rasterised natively and stay sharp.
struct MapNodeMetrics: Equatable {
    var zoom: CGFloat
    var icon: CGFloat
    var font: CGFloat
    var labelWidth: CGFloat
    /// Names fade out when zoomed far out (they'd only collide); hovered/selected nodes keep theirs.
    var labelOpacity: CGFloat
    /// The IP line fades out a little earlier.
    var detailOpacity: CGFloat

    init(zoom: CGFloat, baseIcon: CGFloat = 40) {
        self.zoom = zoom
        icon = min(max(baseIcon * zoom, baseIcon * 0.45), baseIcon * 1.9)
        font = 11 * Self.fontScale(zoom: zoom)
        labelWidth = min(max(MapModel.nodeSize * 0.95 * zoom, 76), 156)
        labelOpacity = smoothstep(0.4, 0.52, zoom)
        detailOpacity = smoothstep(0.6, 0.72, zoom)
    }

    /// Text grows and shrinks with the zoom, but much less, so it stays readable.
    static func fontScale(zoom: CGFloat) -> CGFloat { min(max(zoom, 0.88), 1.3) }

    static func router(zoom: CGFloat) -> MapNodeMetrics {
        var m = MapNodeMetrics(zoom: zoom, baseIcon: 54)
        m.icon = min(max(54 * zoom, 26), 96)
        m.labelOpacity = 1
        m.detailOpacity = smoothstep(0.45, 0.6, zoom)
        return m
    }
}

/// A device on the map: tinted kind icon with name and IP below.
/// The view's frame is the icon, so callers can `.position` it on the node's point; the
/// labels hang below as an overlay.
struct MapDeviceNode: View {
    let device: Device
    let metrics: MapNodeMetrics
    var isSelected = false
    var isHovered = false
    /// Another node is hovered: recede slightly.
    var isReceded = false
    var isPinging = false
    var pingOK = true
    var isPinned = false
    var isDragging = false
    var dimmed = false
    /// Set on the centre node: labels it "Gateway · <ip>" plus brand/model, never fading.
    var isGateway = false
    /// Where the name hangs (chosen by `MapLabelPlacer` so it doesn't cover other nodes).
    var labelSide: MapLabelSide = .below
    /// False: no free spot for the name at this zoom, so it fades out.
    var labelVisible = true

    @Environment(\.colorScheme) private var scheme

    private var lifted: Bool { isHovered || isDragging }

    var body: some View {
        let size = metrics.icon
        icon(size: lifted ? size * 1.08 : size)
            .frame(width: size, height: size)
            .overlay(alignment: labelSide.overlayAlignment) {
                let show = (isSelected || lifted || device.isSelf ? 1 : metrics.labelOpacity) * (labelVisible ? 1 : 0)
                if show > 0.01 {
                    let d = size + (lifted ? size * 0.04 : 0) + MapLabelPlacer.gap
                    labels
                        .frame(width: metrics.labelWidth, alignment: labelSide.frameAlignment)
                        .fixedSize(horizontal: false, vertical: true)
                        // The overlay is aligned to the icon's near edge; push it past the icon.
                        .offset(labelSide.offset(d))
                        .opacity(show)
                }
            }
            .opacity(dimmed || !device.isOnline ? 0.5 : isReceded ? 0.82 : 1)
            .animation(.snappy(duration: 0.2), value: lifted)
            .animation(.easeOut(duration: 0.2), value: isReceded)
            .animation(.snappy(duration: 0.25), value: labelSide)
            .animation(.easeOut(duration: 0.2), value: labelVisible)
    }

    private func icon(size: CGFloat) -> some View {
        DeviceIconView(device: device, size: size)
            .saturation(device.isOnline ? 1 : 0.2)
            .shadow(
                color: MapStyle.shadow(scheme).opacity(lifted ? 1 : 0.8),
                radius: lifted ? size * 0.22 : size * 0.08, y: lifted ? size * 0.12 : size * 0.035
            )
            .background {
                if device.isSelf {
                    // "This Mac" halo.
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [Color.accentColor.opacity(0.32), Color.accentColor.opacity(0)],
                                center: .center, startRadius: size * 0.3, endRadius: size * 0.95)
                        )
                        .frame(width: size * 1.9, height: size * 1.9)
                    Circle()
                        .strokeBorder(Color.accentColor.opacity(0.5), lineWidth: 1)
                        .frame(width: size * 1.42, height: size * 1.42)
                }
            }
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: size * 0.27 + 4, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: 2.5)
                        .padding(-4)
                        .shadow(color: Color.accentColor.opacity(0.55), radius: 6)
                }
            }
            .overlay(alignment: .topTrailing) {
                if device.isNew {
                    badge(size: max(8, size * 0.24)) { Circle().fill(Color.accentColor) }
                        .offset(x: size * 0.1, y: -size * 0.1)
                        .help("New device")
                }
            }
            .overlay(alignment: .topLeading) {
                if isPinned {
                    let b = max(12, size * 0.34)
                    badge(size: b) {
                        Circle().fill(MapStyle.background)
                            .overlay(
                                Image(systemName: "pin.fill").font(.system(size: b * 0.5, weight: .semibold))
                                    .foregroundStyle(.secondary).rotationEffect(.degrees(30)))
                    }
                    .offset(x: -b * 0.35, y: -b * 0.35)
                    .help("Pinned")
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if isPinging {
                    let b = max(12, size * 0.38)
                    badge(size: b) {
                        Circle().fill((pingOK ? MapStyle.pingOK : MapStyle.pingLost).gradient)
                            .overlay(
                                Image(systemName: "waveform.path.ecg")
                                    .font(.system(size: b * 0.52, weight: .bold)).foregroundStyle(.white))
                    }
                    .offset(x: b * 0.33, y: b * 0.33)
                }
            }
            .contentShape(.rect(cornerRadius: size * 0.27))
    }

    private func badge(size: CGFloat, @ViewBuilder content: () -> some View) -> some View {
        content()
            .frame(width: size, height: size)
            .overlay(Circle().strokeBorder(MapStyle.background, lineWidth: 1.5))
    }

    private var labels: some View {
        let f = metrics.font
        return VStack(alignment: labelSide.stackAlignment, spacing: 1) {
            Text(device.mapName)
                .font(.system(size: f, weight: device.isSelf || isSelected || lifted ? .semibold : .medium))
                .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .lineLimit(2)
                .truncationMode(.tail)
                .multilineTextAlignment(labelSide.textAlignment)
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .background {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(
                            isSelected
                                ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(MapStyle.background.opacity(0.86)))
                }
            if isGateway {
                MapGatewayCaption(ip: device.ip, model: device.gatewayModelLine, metrics: metrics)
            } else if metrics.detailOpacity > 0.01 || isSelected || lifted {
                Text(device.isSelf ? "This Mac · \(device.ip)" : device.ip.description)
                    .font(.system(size: f * 0.86).monospacedDigit())
                    .foregroundStyle(device.isSelf ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 4)
                    .background(MapStyle.background.opacity(0.86), in: .rect(cornerRadius: 3))
                    .opacity(isSelected || lifted ? 1 : metrics.detailOpacity)
            }
        }
        .contentShape(.rect)
    }
}

extension MapLabelSide {
    /// The icon edge the label overlay is aligned to.
    var overlayAlignment: Alignment {
        switch self {
        case .below: .top
        case .above: .bottom
        case .right: .leading
        case .left: .trailing
        }
    }

    /// Text hugs the icon: leading on the right, trailing on the left.
    var frameAlignment: Alignment {
        switch self {
        case .right: .leading
        case .left: .trailing
        case .below, .above: .center
        }
    }

    var stackAlignment: HorizontalAlignment {
        switch self {
        case .right: .leading
        case .left: .trailing
        case .below, .above: .center
        }
    }

    var textAlignment: TextAlignment {
        switch self {
        case .right: .leading
        case .left: .trailing
        case .below, .above: .center
        }
    }

    /// Offset from the aligned icon edge to the label's spot, `d` = icon size + gap.
    func offset(_ d: CGFloat) -> CGSize {
        switch self {
        case .below: CGSize(width: 0, height: d)
        case .above: CGSize(width: 0, height: -d)
        case .right: CGSize(width: d, height: 0)
        case .left: CGSize(width: -d, height: 0)
        }
    }
}

/// Estimated on-screen sizes of map captions, for label placement. Text widths are measured
/// once per string at 11 pt and scaled, so placement stays cheap while zooming.
@MainActor
enum MapLabelSizing {
    private static var widths: [String: CGFloat] = [:]

    static func width(
        _ text: String, size: CGFloat, weight: NSFont.Weight = .regular, mono: Bool = false,
        tracking: CGFloat = 0
    ) -> CGFloat {
        let key = "\(weight.rawValue)|\(mono)|\(text)"
        let base: CGFloat
        if let w = widths[key] {
            base = w
        } else {
            let font =
                mono
                ? NSFont.monospacedDigitSystemFont(ofSize: 11, weight: weight)
                : NSFont.systemFont(ofSize: 11, weight: weight)
            base = ceil((text as NSString).size(withAttributes: [.font: font]).width)
            if widths.count > 4000 { widths.removeAll() }
            widths[key] = base
        }
        return base * size / 11 + tracking * CGFloat(text.count)
    }

    static func lineHeight(_ size: CGFloat) -> CGFloat { ceil(size * 1.21) }

    /// Name plate (plus the IP line when shown) under a device node.
    static func deviceLabel(_ d: Device, metrics m: MapNodeMetrics, emphasized: Bool, detail: Bool) -> CGSize {
        let f = m.font
        let available = m.labelWidth - 10
        let name = width(d.mapName, size: f, weight: emphasized ? .semibold : .medium)
        let lines: CGFloat = name <= available ? 1 : 2
        var w = min(name, available) + 10
        var h = lines * lineHeight(f) + 3
        if detail {
            let text = d.isSelf ? "This Mac · \(d.ip)" : d.ip.description
            w = max(w, width(text, size: f * 0.86, mono: true) + 8)
            h += 1 + lineHeight(f * 0.86)
        }
        return CGSize(width: min(w, m.labelWidth), height: h)
    }

    /// Name, gateway badge and model line under the router.
    static func routerLabel(name: String, ip: IPv4Address?, model: String?, metrics m: MapNodeMetrics) -> CGSize {
        let f = m.font
        let nameW = width(name, size: f, weight: .medium)
        let available = m.labelWidth - 10
        var w = min(nameW, available) + 10
        var h = (nameW <= available ? 1 : 2) * lineHeight(f) + 3
        let badge =
            width("GATEWAY", size: f * 0.74, weight: .bold, tracking: 0.4) + f * 0.7 + 6 + 12
            + (ip.map { width("· \($0)", size: f * 0.84, weight: .medium, mono: true) + 3 } ?? 0)
        w = max(w, badge)
        h += 1 + lineHeight(f * 0.84) + 3
        if let model {
            w = max(w, min(width(model, size: f * 0.86), max(m.labelWidth * 1.4, 150)) + 8)
            h += 2 + lineHeight(f * 0.86)
        }
        return CGSize(width: w, height: h)
    }
}

/// "GATEWAY · 192.168.1.1" badge and the brand/model line under the centre node's name.
/// Always fully visible, at every zoom level.
private struct MapGatewayCaption: View {
    let ip: IPv4Address?
    let model: String?
    let metrics: MapNodeMetrics

    var body: some View {
        let f = metrics.font
        VStack(spacing: 2) {
            HStack(spacing: 3) {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: f * 0.7, weight: .bold))
                Text("GATEWAY")
                    .font(.system(size: f * 0.74, weight: .bold))
                    .tracking(0.4)
                if let ip {
                    Text("· \(ip.description)")
                        .font(.system(size: f * 0.84, weight: .medium).monospacedDigit())
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(MapStyle.uplink.gradient, in: Capsule())
            .lineLimit(1)
            .fixedSize()
            if let model {
                Text(model)
                    .font(.system(size: f * 0.86))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: max(metrics.labelWidth * 1.4, 150))
                    .fixedSize(horizontal: false, vertical: true)
                    .help(model)
                    .padding(.horizontal, 4)
                    .background(MapStyle.background.opacity(0.86), in: .rect(cornerRadius: 3))
            }
        }
    }
}

/// The gateway when no device for it is known yet: a generic router glyph, still labelled
/// "Gateway" with the interface's gateway address.
struct MapHubNode: View {
    let gateway: IPv4Address?
    let metrics: MapNodeMetrics

    var body: some View {
        DeviceIconView(kind: .router, size: metrics.icon)
            .saturation(0.3)
            .opacity(0.7)
            .overlay(alignment: .top) {
                VStack(spacing: 2) {
                    Text(gateway == nil ? "No Gateway" : "Router")
                        .font(.system(size: metrics.font, weight: .medium))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(MapStyle.background.opacity(0.86), in: .rect(cornerRadius: 5))
                    if gateway != nil {
                        MapGatewayCaption(ip: gateway, model: nil, metrics: metrics)
                    }
                }
                .fixedSize()
                .offset(y: metrics.icon + 4)
            }
            .help(gateway.map { "Gateway \($0.description) — not identified yet" } ?? "This network has no gateway")
    }
}

/// The internet, above the router.
struct MapInternetNode: View {
    let zoom: CGFloat
    var tooltip = "Internet"
    @Environment(\.colorScheme) private var scheme

    static func iconSize(zoom: CGFloat) -> CGFloat { min(max(34 * zoom, 20), 60) }
    static func captionFontSize(zoom: CGFloat) -> CGFloat { 10.5 * MapNodeMetrics.fontScale(zoom: zoom) }

    var body: some View {
        let size = Self.iconSize(zoom: zoom)
        Circle()
            .fill(LinearGradient(colors: [.cyan, .blue], startPoint: .top, endPoint: .bottom))
            .overlay(Circle().strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
            .overlay {
                Image(systemName: "globe.americas.fill")
                    .font(.system(size: size * 0.56, weight: .medium))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.15), radius: 0.5, y: 0.5)
            }
            .frame(width: size, height: size)
            .shadow(color: MapStyle.uplink.opacity(scheme == .dark ? 0.45 : 0.3), radius: size * 0.25)
            .overlay(alignment: .top) {
                Text("Internet")
                    .font(.system(size: Self.captionFontSize(zoom: zoom), weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .background(MapStyle.background.opacity(0.86), in: .rect(cornerRadius: 3))
                    .fixedSize()
                    .offset(y: size + 4)
            }
            .help(tooltip)
    }
}

/// Sector caption, e.g. "SMART HOME · 4", drawn at real size.
struct MapGroupLabel: View {
    let group: MapGroup
    let count: Int
    let zoom: CGFloat

    /// Like `MapNodeMetrics.fontScale`, a little tighter.
    static func fontScale(zoom: CGFloat) -> CGFloat { min(max(zoom, 0.9), 1.25) }

    var body: some View {
        let fs = Self.fontScale(zoom: zoom)
        HStack(spacing: 4) {
            Image(systemName: group.symbolName)
                .font(.system(size: 9.5 * fs, weight: .semibold))
                .foregroundStyle(group.tint)
            Text(group.label.uppercased())
                .foregroundStyle(.secondary)
            Text("\(count)")
                .foregroundStyle(.tertiary)
        }
        .font(.system(size: 10 * fs, weight: .semibold))
        .tracking(0.5)
        .lineLimit(1)
        .fixedSize()
        .allowsHitTesting(false)
    }
}
