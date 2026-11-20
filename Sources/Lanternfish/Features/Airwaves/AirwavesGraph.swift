import AppKit
import LanternfishKit
import SwiftUI

/// Geometry of the channel graph: plot rect, frequency ↔ x and dBm ↔ y.
private struct WiFiGraphLayout {
    static let insets = EdgeInsets(top: 26, leading: 44, bottom: 40, trailing: 12)
    static let dBm = AirwavesFormat.signalRange

    let size: CGSize
    let band: WiFiBand
    let axis: BandAxis

    init(size: CGSize, band: WiFiBand) {
        self.size = size
        self.band = band
        self.axis = BandAxis(band: band)
    }

    var plot: CGRect {
        let i = Self.insets
        return CGRect(
            x: i.leading, y: i.top, width: max(size.width - i.leading - i.trailing, 10),
            height: max(size.height - i.top - i.bottom, 10))
    }

    func x(_ f: Double) -> CGFloat { plot.minX + axis.position(of: f) * plot.width }

    func y(_ dBm: Double) -> CGFloat {
        let d = min(max(dBm, Self.dBm.lowerBound), Self.dBm.upperBound)
        return plot.maxY - (d - Self.dBm.lowerBound) / (Self.dBm.upperBound - Self.dBm.lowerBound) * plot.height
    }

    func frequency(atX x: CGFloat) -> Double? {
        guard plot.width > 0 else { return nil }
        return axis.frequency(at: (x - plot.minX) / plot.width)
    }

    /// Pixels per 5 MHz channel step.
    var channelStep: CGFloat {
        guard let s = axis.segments.first else { return 0 }
        return x(s.lowerBound + 5) - x(s.lowerBound)
    }

    struct Hill {
        var x0: CGFloat, x1: CGFloat, peak: CGFloat
        var mid: CGFloat { (x0 + x1) / 2 }
    }

    func hill(_ r: WiFiScanResult) -> Hill {
        let s = r.span
        return Hill(x0: x(s.lower), x1: x(s.upper), peak: y(Double(r.rssi)))
    }

    /// Hill height as a 0...1 share of its peak, at `t` = −1…1 across the occupied span.
    /// Rounded top, steep but finite flanks that meet the baseline smoothly.
    static func profile(_ t: Double) -> Double {
        let a = min(abs(t), 1)
        return pow(1 - pow(a, 2.2), 1.15)
    }
}

/// The channel graph: every network a hill over the frequencies it occupies, as tall as its signal.
struct WiFiChannelGraph: View {
    let band: WiFiBand
    let networks: [WiFiScanResult]
    let currentID: String?
    /// Your network's name: its BSSs on other bands share your colour.
    let currentSSID: String?
    @Binding var hover: WiFiHover?
    @Binding var selection: String?
    @State private var pointer: CGPoint?

    var body: some View {
        GeometryReader { geo in
            let layout = WiFiGraphLayout(size: geo.size, band: band)
            let hoveredID = hover?.id
            ZStack(alignment: .topLeading) {
                WiFiGraphBackground(layout: layout)
                hills(layout, hoveredID: hoveredID)
                    .animation(.smooth(duration: 0.9), value: networks)
                labels(layout, hoveredID: hoveredID)
                    .animation(.smooth(duration: 0.9), value: networks)
                decorations(layout, hoveredID: hoveredID)
            }
            .animation(.easeOut(duration: 0.15), value: hover)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let p):
                    pointer = p
                    let id = hitTest(p, layout: layout)
                    if id != hover?.id || (id != nil && hover?.fromGraph == false) {
                        hover = id.map { WiFiHover(id: $0, fromGraph: true) }
                    }
                case .ended:
                    pointer = nil
                    if hover?.fromGraph == true { hover = nil }
                }
            }
            .onTapGesture { p in
                if let id = hitTest(p, layout: layout) { selection = id }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Channel graph, \(band.label)")
    }

    // MARK: Hills

    /// Tallest first, so lower hills draw in front and stay reachable.
    private var drawOrder: [WiFiScanResult] {
        networks.sorted { ($0.rssi, $1.id) > ($1.rssi, $0.id) }
    }

    private func color(_ r: WiFiScanResult) -> Color {
        AirwavesFormat.color(for: r, currentID: currentID, currentSSID: currentSSID)
    }

    private func hills(_ layout: WiFiGraphLayout, hoveredID: String?) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(drawOrder) { r in
                let h = layout.hill(r)
                let c = color(r)
                let isCurrent = r.id == currentID
                let isHovered = r.id == hoveredID
                let dimmed = hoveredID != nil && !isHovered
                let emphasis = isHovered || r.id == selection
                ZStack {
                    HillShape(x0: h.x0, x1: h.x1, peak: h.peak, base: layout.plot.maxY, closed: true)
                        .fill(
                            LinearGradient(
                                colors: [
                                    c.opacity(emphasis ? 0.42 : isCurrent ? 0.30 : 0.20),
                                    c.opacity(emphasis ? 0.16 : 0.05),
                                ],
                                startPoint: .top, endPoint: .bottom))
                    HillShape(x0: h.x0, x1: h.x1, peak: h.peak, base: layout.plot.maxY, closed: false)
                        .stroke(
                            c,
                            style: StrokeStyle(
                                lineWidth: isCurrent ? 2.6 : emphasis ? 2 : 1.3,
                                lineCap: .round, lineJoin: .round))
                }
                .opacity(dimmed ? 0.35 : 1)
                .zIndex(isHovered ? 1 : 0)
                .transition(.opacity)
            }
        }
        .frame(width: layout.size.width, height: layout.size.height)
        .clipShape(Rectangle().path(in: layout.plot.insetBy(dx: 0, dy: -2)))
        .allowsHitTesting(false)
    }

    // MARK: Labels

    private struct Placement {
        let r: WiFiScanResult
        let point: CGPoint
        let visible: Bool
    }

    private static let labelFont = NSFont.systemFont(ofSize: 11, weight: .semibold)

    private func labelSize(_ r: WiFiScanResult) -> CGSize {
        let w = (r.displayName as NSString).size(withAttributes: [.font: Self.labelFont]).width
        return CGSize(width: w + (r.id == currentID ? 32 : 0) + 4, height: 15)
    }

    /// Greedy placement, strongest first: above the peak, nudged up to two rows higher, else hidden
    /// (hidden labels still show while hovered).
    private func placements(_ layout: WiFiGraphLayout, hoveredID: String?) -> [Placement] {
        var taken: [CGRect] = []
        var out: [Placement] = []
        let order = networks.sorted { a, b in
            let pa = a.id == currentID || a.id == hoveredID
            let pb = b.id == currentID || b.id == hoveredID
            return pa != pb ? pa : (a.rssi, b.id) > (b.rssi, a.id)
        }
        for r in order {
            let h = layout.hill(r)
            let size = labelSize(r)
            var placed: CGRect?
            for step in 0..<3 {
                var y = h.peak - 10 - CGFloat(step) * 16
                y = max(y, layout.plot.minY - 16)
                var x = h.mid
                x = min(max(x, layout.plot.minX + size.width / 2), layout.plot.maxX - size.width / 2)
                let rect = CGRect(x: x - size.width / 2, y: y - size.height / 2, width: size.width, height: size.height)
                if !taken.contains(where: { $0.insetBy(dx: -3, dy: 0).intersects(rect) }) {
                    placed = rect
                    break
                }
            }
            let forced = r.id == hoveredID || r.id == currentID
            if placed == nil, forced {
                let x = min(max(h.mid, layout.plot.minX + size.width / 2), layout.plot.maxX - size.width / 2)
                placed = CGRect(
                    x: x - size.width / 2, y: max(h.peak - 10, layout.plot.minY - 16) - size.height / 2,
                    width: size.width, height: size.height)
            }
            if let placed {
                taken.append(placed)
                out.append(Placement(r: r, point: CGPoint(x: placed.midX, y: placed.midY), visible: true))
            } else {
                out.append(Placement(r: r, point: CGPoint(x: h.mid, y: h.peak - 10), visible: false))
            }
        }
        return out
    }

    private func labels(_ layout: WiFiGraphLayout, hoveredID: String?) -> some View {
        let list = placements(layout, hoveredID: hoveredID)
        return ZStack(alignment: .topLeading) {
            ForEach(list, id: \.r.id) { p in
                let isHovered = p.r.id == hoveredID
                HillLabel(
                    name: p.r.displayName, isCurrent: p.r.id == currentID, isHidden: p.r.ssid == nil,
                    tint: color(p.r)
                )
                .opacity(p.visible ? (hoveredID == nil || isHovered ? 1 : 0.35) : 0)
                .position(p.point)
            }
        }
        .frame(width: layout.size.width, height: layout.size.height, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    // MARK: Hover decorations

    @ViewBuilder
    private func decorations(_ layout: WiFiGraphLayout, hoveredID: String?) -> some View {
        let hovered = hoveredID.flatMap { id in networks.first { $0.id == id } }
        ZStack(alignment: .topLeading) {
            if let r = hovered {
                let h = layout.hill(r)
                let c = color(r)
                // Occupied frequencies along the axis.
                Capsule()
                    .fill(c.opacity(0.85))
                    .frame(width: max(h.x1 - h.x0, 4), height: 3)
                    .position(x: h.mid, y: layout.plot.maxY + 1.5)
                Text(spanText(r))
                    .font(.caption2.monospacedDigit().weight(.medium))
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .position(
                        x: min(max(h.mid, layout.plot.minX + 60), layout.plot.maxX - 60),
                        y: layout.plot.maxY + 29)
                WiFiHillTooltip(r: r, isCurrent: r.id == currentID, tint: c)
                    .fixedSize()
                    .position(tooltipPoint(h, layout: layout))
                    .transition(.opacity)
            } else if let p = pointer, layout.plot.contains(p), let f = layout.frequency(atX: p.x) {
                Rectangle()
                    .fill(.secondary.opacity(0.5))
                    .frame(width: 1, height: layout.plot.height)
                    .position(x: p.x, y: layout.plot.midY)
                Text(pointerText(f))
                    .font(.caption2.monospacedDigit().weight(.medium))
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .position(x: min(max(p.x, layout.plot.minX + 50), layout.plot.maxX - 50), y: layout.plot.maxY + 29)
            }
        }
        .frame(width: layout.size.width, height: layout.size.height, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    private func tooltipPoint(_ h: WiFiGraphLayout.Hill, layout: WiFiGraphLayout) -> CGPoint {
        let w: CGFloat = 220
        let hgt: CGFloat = 92
        // Beside the peak, on the side with more room, a little below it.
        var x = h.mid + (h.mid + 24 + w < layout.plot.maxX ? 24 + w / 2 : -(24 + w / 2))
        x = min(max(x, layout.plot.minX + w / 2), layout.plot.maxX - w / 2)
        let y = min(max(h.peak + hgt / 2 + 6, layout.plot.minY + hgt / 2), layout.plot.maxY - hgt / 2 - 4)
        return CGPoint(x: x, y: y)
    }

    private func spanText(_ r: WiFiScanResult) -> String {
        let s = r.span
        return "\(Int(s.lower))–\(Int(s.upper)) MHz"
    }

    private func pointerText(_ f: Double) -> String {
        // Nearest 20 MHz channel to the pointer.
        let channels = WiFiChannels.channels(in: band)
        let nearest = channels.min { a, b in
            abs(Double(WiFiChannels.frequency(channel: a, band: band) ?? 0) - f)
                < abs(Double(WiFiChannels.frequency(channel: b, band: band) ?? 0) - f)
        }
        guard let ch = nearest, let cf = WiFiChannels.frequency(channel: ch, band: band) else {
            return "\(Int(f)) MHz"
        }
        var s = "Channel \(ch) · \(cf) MHz"
        if WiFiChannels.isDFS(channel: ch, band: band) { s += " · DFS" }
        if WiFiChannels.isPSC(channel: ch, band: band) { s += " · PSC" }
        return s
    }

    // MARK: Hit testing

    /// The front-most hill under `p` (lowest peak wins, as it draws on top).
    private func hitTest(_ p: CGPoint, layout: WiFiGraphLayout) -> String? {
        guard p.y <= layout.plot.maxY + 4, let f = layout.frequency(atX: p.x) else { return nil }
        var best: (id: String, height: CGFloat)?
        for r in networks {
            let s = r.span
            guard f > s.lower, f < s.upper else { continue }
            let t = (f - s.center) / (Double(s.width) / 2)
            let full = layout.plot.maxY - layout.hill(r).peak
            let top = layout.plot.maxY - full * WiFiGraphLayout.profile(t)
            guard p.y >= top - 5 else { continue }
            if best == nil || full < best!.height { best = (r.id, full) }
        }
        return best?.id
    }
}

/// A hill outline: rises from `x0`, peaks at `peak`, returns to the baseline at `x1`.
private struct HillShape: Shape {
    var x0: CGFloat
    var x1: CGFloat
    var peak: CGFloat
    var base: CGFloat
    var closed: Bool

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(AnimatablePair(x0, x1), AnimatablePair(peak, base)) }
        set {
            x0 = newValue.first.first
            x1 = newValue.first.second
            peak = newValue.second.first
            base = newValue.second.second
        }
    }

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let n = 64
        let height = base - peak
        p.move(to: CGPoint(x: x0, y: base))
        for i in 1..<n {
            let t = Double(i) / Double(n) * 2 - 1
            let x = x0 + (x1 - x0) * CGFloat(i) / CGFloat(n)
            p.addLine(to: CGPoint(x: x, y: base - height * WiFiGraphLayout.profile(t)))
        }
        p.addLine(to: CGPoint(x: x1, y: base))
        if closed { p.closeSubpath() }
        return p
    }
}

private struct HillLabel: View {
    let name: String
    let isCurrent: Bool
    let isHidden: Bool
    let tint: Color

    var body: some View {
        HStack(spacing: 4) {
            if isCurrent { WiFiYouBadge() }
            Text(name)
                .font(.system(size: 11, weight: .semibold))
                .italic(isHidden)
                .foregroundStyle(isCurrent ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary.opacity(0.85)))
                .lineLimit(1)
        }
        .fixedSize()
        .shadow(color: Color(nsColor: .textBackgroundColor), radius: 1.5)
        .shadow(color: Color(nsColor: .textBackgroundColor), radius: 1.5)
    }
}

/// Details of the hovered hill.
private struct WiFiHillTooltip: View {
    let r: WiFiScanResult
    let isCurrent: Bool
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Circle().fill(tint).frame(width: 8, height: 8)
                Text(r.displayName)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                if isCurrent { WiFiYouBadge() }
            }
            Text(channelLine).foregroundStyle(.secondary)
            HStack(spacing: 5) {
                SignalBars(bars: r.quality.bars, tint: OverviewFormat.color(r.quality))
                Text("\(r.rssi) dBm · \(r.quality.label)")
            }
            .foregroundStyle(.secondary)
            if let brand = AirwavesFormat.brand(r) {
                Text("\(brand) · \(r.security.label)").foregroundStyle(.tertiary)
            } else {
                Text(r.security.label).foregroundStyle(.tertiary)
            }
        }
        .font(.caption.monospacedDigit())
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(width: 220, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(.separator, lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
    }

    private var channelLine: String {
        var s = "Channel \(r.channelLabel) · \(r.width) MHz"
        if let f = r.frequency { s += " · \(f) MHz" }
        if r.isDFS { s += " · DFS" }
        return s
    }
}

/// Grid, axes, sub-band captions, DFS shading and the 5 GHz gap, drawn once per size/band.
private struct WiFiGraphBackground: View {
    let layout: WiFiGraphLayout

    var body: some View {
        Canvas { ctx, _ in
            let plot = layout.plot
            let band = layout.band
            let grid = Color.primary.opacity(0.07)
            let axisColor = Color.primary.opacity(0.22)

            // DFS shading and sub-band captions.
            for sub in WiFiChannels.subBands(band) {
                let x0 = layout.x(sub.range.lowerBound)
                let x1 = layout.x(sub.range.upperBound)
                let isDFS = band == .ghz5 && (sub.name == "UNII-2A" || sub.name == "UNII-2C")
                if isDFS {
                    ctx.fill(
                        Path(CGRect(x: x0, y: plot.minY, width: x1 - x0, height: plot.height)),
                        with: .color(.orange.opacity(0.04)))
                }
                let caption = isDFS ? "\(sub.name) · DFS" : sub.name
                if x1 - x0 > 54 {
                    ctx.draw(
                        Text(caption).font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(
                                isDFS ? AnyShapeStyle(Color.orange.opacity(0.85)) : AnyShapeStyle(.tertiary)),
                        at: CGPoint(x: (x0 + x1) / 2, y: plot.minY - 15), anchor: .center)
                }
                ctx.stroke(
                    Path { p in
                        p.move(to: CGPoint(x: x0, y: plot.minY - 6))
                        p.addLine(to: CGPoint(x: x0, y: plot.maxY))
                    }, with: .color(grid), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
            }

            // Horizontal grid + dBm labels.
            for d in stride(from: -30, through: -100, by: -10) {
                let y = layout.y(Double(d))
                ctx.stroke(
                    Path { p in
                        p.move(to: CGPoint(x: plot.minX, y: y))
                        p.addLine(to: CGPoint(x: plot.maxX, y: y))
                    }, with: .color(d == -100 ? axisColor : grid), lineWidth: 1)
                ctx.draw(
                    Text("\(d)").font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary),
                    at: CGPoint(x: plot.minX - 7, y: y), anchor: .trailing)
            }
            ctx.draw(
                Text("dBm").font(.system(size: 9.5, weight: .medium)).foregroundStyle(.tertiary),
                at: CGPoint(x: plot.minX - 7, y: plot.minY - 15), anchor: .trailing)

            // Gaps between segments (5 GHz 5350–5470 MHz is unused).
            for g in layout.axis.gaps {
                let x0 = plot.minX + g.lowerBound * plot.width
                let x1 = plot.minX + g.upperBound * plot.width
                ctx.fill(
                    Path(CGRect(x: x0, y: plot.minY - 6, width: x1 - x0, height: plot.height + 14)),
                    with: .color(Color(nsColor: .windowBackgroundColor)))
                for dx in [x0 + (x1 - x0) * 0.35, x0 + (x1 - x0) * 0.65] {
                    ctx.stroke(
                        Path { p in
                            p.move(to: CGPoint(x: dx - 3, y: plot.maxY + 5))
                            p.addLine(to: CGPoint(x: dx + 3, y: plot.maxY - 5))
                        }, with: .color(axisColor), lineWidth: 1)
                }
            }

            // Channel ticks and labels.
            let channels = WiFiChannels.channels(in: band)
            let perChannel = layout.channelStep * 4  // px between neighbouring 20 MHz channels
            let labelEvery: Int =
                switch band {
                case .ghz2: layout.channelStep < 15 ? 2 : 1
                case .ghz6: perChannel * 4 < 30 ? 8 : perChannel < 26 ? 4 : 1
                default: perChannel < 22 ? 2 : 1
                }
            for (i, ch) in channels.enumerated() {
                guard let f = WiFiChannels.frequency(channel: ch, band: band) else { continue }
                let x = layout.x(Double(f))
                let isPSC = WiFiChannels.isPSC(channel: ch, band: band)
                let labelled: Bool =
                    switch band {
                    case .ghz6: labelEvery == 1 || (labelEvery == 4 ? isPSC : (ch - 5) % 32 == 0)
                    default: i % labelEvery == 0 || ch == 149 || ch == 100
                    }
                ctx.stroke(
                    Path { p in
                        p.move(to: CGPoint(x: x, y: plot.maxY))
                        p.addLine(to: CGPoint(x: x, y: plot.maxY + (labelled ? 4 : 2.5)))
                    }, with: .color(axisColor), lineWidth: 1)
                if labelled {
                    let dfs = WiFiChannels.isDFS(channel: ch, band: band)
                    let style: AnyShapeStyle =
                        dfs
                        ? AnyShapeStyle(Color.orange.opacity(0.9))
                        : isPSC ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary)
                    ctx.draw(
                        Text("\(ch)").font(.system(size: 10, weight: isPSC ? .semibold : .regular).monospacedDigit())
                            .foregroundStyle(style),
                        at: CGPoint(x: x, y: plot.maxY + 12), anchor: .center)
                }
            }
        }
        .frame(width: layout.size.width, height: layout.size.height)
        .allowsHitTesting(false)
    }
}
