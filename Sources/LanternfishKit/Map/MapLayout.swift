import CoreGraphics
import Foundation

// MARK: - MapGroup

/// The sectors of the network map. Order is the clockwise order around the router.
public enum MapGroup: Int, CaseIterable, Sendable, Comparable {
    case network, computers, mobile, media, smartHome, servers, peripherals, unknown

    public init(kind: DeviceKind) {
        switch kind {
        case .router: self = .network
        case .computer: self = .computers
        case .phone, .tablet: self = .mobile
        case .tv, .speaker, .gameConsole: self = .media
        case .iot: self = .smartHome
        case .nas: self = .servers
        case .printer, .camera: self = .peripherals
        case .unknown: self = .unknown
        }
    }

    public var label: String {
        switch self {
        case .network: "Network"
        case .computers: "Computers"
        case .mobile: "Phones & Tablets"
        case .media: "TV & Media"
        case .smartHome: "Smart Home"
        case .servers: "NAS & Servers"
        case .peripherals: "Printers & Cameras"
        case .unknown: "Other"
        }
    }

    public var symbolName: String {
        switch self {
        case .network: "wifi.router"
        case .computers: "laptopcomputer"
        case .mobile: "iphone"
        case .media: "tv"
        case .smartHome: "lightbulb"
        case .servers: "externaldrive"
        case .peripherals: "printer"
        case .unknown: "questionmark.circle"
        }
    }

    public static func < (lhs: MapGroup, rhs: MapGroup) -> Bool { lhs.rawValue < rhs.rawValue }
}

// MARK: - MapLayout

/// Pure, deterministic radial layout for the network map.
///
/// The router sits at the origin; the internet node sits straight above it in a gap kept free
/// at the top of every ring. Groups get consecutive angular sectors, clockwise from the top.
/// Within a sector nodes fill a polar grid: angular columns × concentric rings. Columns are
/// spaced so neighbours on the innermost ring are at least `nodeSize` apart (and outer rings
/// only have more room); rings are `ringSpacing ≥ nodeSize` apart. Each ring is rotated by a
/// fraction of a column so connectors to outer nodes run between inner nodes.
///
/// Coordinates are y-down (screen convention); the origin is the router.
public struct MapLayout: Sendable, Equatable {
    public struct GroupLabel: Sendable, Equatable {
        /// Index into the `groups` passed to `compute`.
        public var index: Int
        public var position: CGPoint
        /// Angle of the sector's middle, radians, y-down (π/2 = straight down).
        public var angle: CGFloat
        /// Arc length available to the label at its radius (the sector's width).
        public var width: CGFloat
        /// Angular extent of the sector's columns, radians, y-down, `startAngle < endAngle`.
        public var startAngle: CGFloat = 0
        public var endAngle: CGFloat = 0
        /// Radial extent of the sector's nodes (innermost / outermost ring used by the group).
        public var innerRadius: CGFloat = 0
        public var outerRadius: CGFloat = 0
    }

    /// Angular offset (in columns) of each ring, so spokes to outer nodes pass between inner ones.
    private static let stagger: [CGFloat] = [0, 0.5, 0.25, 0.375, 0.125]

    /// Centre of each device node.
    public var positions: [IPv4Address: CGPoint]
    /// Ring radii, innermost first.
    public var ringRadii: [CGFloat]
    /// Where the internet node goes.
    public var internet: CGPoint
    /// One per non-empty group, placed just outside the outermost ring of its sector.
    public var groupLabels: [GroupLabel]
    /// Box containing every node centre, the internet node and the labels, padded by `nodeSize / 2`.
    public var bounds: CGRect

    /// Convenience: node centres only.
    public static func positions(
        for groups: [[IPv4Address]], ringSpacing: CGFloat = 130,
        nodeSize: CGFloat = 110
    ) -> [IPv4Address: CGPoint] {
        compute(groups: groups, ringSpacing: ringSpacing, nodeSize: nodeSize).positions
    }

    /// - Parameters:
    ///   - groups: devices per sector, in display order (callers sort each group, e.g. by IP).
    ///     Empty groups are skipped. The router itself must not be included.
    ///   - ringSpacing: radial distance between rings (clamped to at least `nodeSize`).
    ///   - nodeSize: minimum distance between any two node centres.
    ///   - maxSpread: largest angle (radians) between neighbouring columns, so small networks
    ///     stay together below the router instead of spreading around the whole circle.
    public static func compute(
        groups: [[IPv4Address]], ringSpacing: CGFloat = 130, nodeSize: CGFloat = 110,
        maxSpread: CGFloat = .pi / 3.2
    ) -> MapLayout {
        let spacing = max(ringSpacing, nodeSize)
        let minRadius = max(spacing * 1.25, nodeSize * 1.5)
        let indexed = groups.enumerated().filter { !$0.element.isEmpty }
        let total = indexed.reduce(0) { $0 + $1.element.count }
        let pad = nodeSize / 2

        guard total > 0 else {
            let internet = CGPoint(x: 0, y: -minRadius)
            return MapLayout(
                positions: [:], ringRadii: [], internet: internet, groupLabels: [],
                bounds: CGRect(
                    x: -pad, y: internet.y - pad, width: nodeSize,
                    height: minRadius + nodeSize))
        }

        // Gap between sectors, in columns.
        let groupGap: CGFloat = indexed.count > 1 ? 0.6 : 0
        // Free columns kept at the top for the internet node (one column each side of it).
        let topGapColumns: CGFloat = 2

        /// Smallest inner radius at which `columns` columns plus gaps fit around the circle.
        func innerRadius(rings: Int) -> (radius: CGFloat, columns: [Int]) {
            let cols = indexed.map { Int((Double($0.element.count) / Double(rings)).rounded(.up)) }
            let units = CGFloat(cols.reduce(0, +)) + groupGap * CGFloat(indexed.count) + topGapColumns
            // units × δ ≤ 2π with δ = 2·asin(nodeSize / 2r)  ⇒  r ≥ nodeSize / (2·sin(π / units)).
            let r = units <= 2 ? minRadius : nodeSize / (2 * sin(.pi / units))
            return (max(minRadius, r) * 1.0001, cols)
        }

        // Pick the ring count with the smallest outer radius (fewest rings on ties).
        var best: (rings: Int, radius: CGFloat, columns: [Int])?
        for rings in 1...max(1, min(total, 12)) {
            let (r, cols) = innerRadius(rings: rings)
            let outer = r + CGFloat(rings - 1) * spacing
            if let b = best, b.radius + CGFloat(b.rings - 1) * spacing <= outer + 0.5 { continue }
            best = (rings, r, cols)
        }
        let (rings, r1, columns) = best!  // the loop above runs at least once
        let radii = (0..<rings).map { r1 + CGFloat($0) * spacing }

        // Column angle at the inner radius, then widened (up to maxSpread) to use the circle.
        let delta = 2 * asin(min(1, nodeSize / (2 * r1)))
        let units = CGFloat(columns.reduce(0, +)) + groupGap * CGFloat(indexed.count)
        let available = 2 * .pi - topGapColumns * delta
        let step = min(max(delta, available / units), max(delta, maxSpread))
        let used = units * step
        // Centre the used arc on straight-down (π/2) so small networks hang below the router.
        var cursor = CGFloat.pi / 2 - used / 2 + groupGap * step / 2

        var positions: [IPv4Address: CGPoint] = [:]
        var labels: [GroupLabel] = []
        var minX: CGFloat = 0
        var maxX: CGFloat = 0
        var minY: CGFloat = 0
        var maxY: CGFloat = 0
        func include(_ p: CGPoint, _ dx: CGFloat = 0, _ dy: CGFloat = 0) {
            minX = min(minX, p.x - dx)
            maxX = max(maxX, p.x + dx)
            minY = min(minY, p.y - dy)
            maxY = max(maxY, p.y + dy)
        }
        // Labels sit on one circle just outside the outermost ring.
        let labelRadius = radii[rings - 1] + nodeSize * 0.72

        for ((index, ips), cols) in zip(indexed, columns) {
            for (i, ip) in ips.enumerated() {
                let ring = i / cols
                let col = i % cols
                let inRing = min(cols, ips.count - ring * cols)
                // Full rings are staggered by ≤ ½ column (so they never reach the next sector,
                // which starts ≥ 1 + groupGap columns after this one's last column);
                // a partial last ring is centred in the sector instead.
                let shift = inRing < cols ? CGFloat(cols - inRing) / 2 : Self.stagger[ring % Self.stagger.count]
                let a = cursor + (CGFloat(col) + 0.5 + shift) * step
                let p = CGPoint(x: radii[ring] * cos(a), y: radii[ring] * sin(a))
                positions[ip] = p
                include(p)
            }
            let mid = cursor + CGFloat(cols) * step / 2
            let lp = CGPoint(x: labelRadius * cos(mid), y: labelRadius * sin(mid))
            let width = max(nodeSize, labelRadius * step * (CGFloat(cols) + groupGap) * 0.95)
            let usedRings = (ips.count + cols - 1) / cols
            labels.append(
                GroupLabel(
                    index: index, position: lp, angle: mid, width: width,
                    startAngle: cursor, endAngle: cursor + CGFloat(cols) * step,
                    innerRadius: radii[0], outerRadius: radii[usedRings - 1]))
            // Side captions extend outward (the view aligns them away from the ring).
            include(lp, abs(cos(mid)) > 0.3 ? nodeSize * 1.5 : min(width, nodeSize * 1.6) / 2, nodeSize * 0.2)
            cursor += (CGFloat(cols) + groupGap) * step
        }

        let internet = CGPoint(x: 0, y: -r1)
        include(internet)
        let bounds = CGRect(
            x: minX - pad, y: minY - pad, width: maxX - minX + 2 * pad,
            height: maxY - minY + 2 * pad)
        return MapLayout(
            positions: positions, ringRadii: radii, internet: internet,
            groupLabels: labels, bounds: bounds)
    }
}

// MARK: - Label placement

/// Where a node's name label sits relative to its icon.
public enum MapLabelSide: Int, CaseIterable, Sendable {
    case below, right, left, above
}

/// The outcome of label placement for one node.
public struct MapLabelPlacement: Sendable, Equatable {
    public var side: MapLabelSide
    /// False when no side is free and the label isn't important enough to cover others: it fades.
    public var isVisible: Bool

    public init(side: MapLabelSide = .below, isVisible: Bool = true) {
        self.side = side
        self.isVisible = isVisible
    }
}

/// Places node name labels so they don't cover other nodes' icons or each other.
///
/// Labels are drawn at real (screen) size while nodes are laid out in map units, so whether
/// two labels collide depends on the zoom. Placement therefore runs in screen units (map
/// coordinates × zoom, router at the origin): every label tries below its icon first, then
/// the outward side, the inward side and above; the first spot that intersects no icon, no
/// fixed obstacle (router / internet captions, sector captions) and no already-placed label
/// wins. Labels are placed in priority order (hovered / selected / "This Mac" first); a
/// low-priority label with no free spot is hidden, a required one takes the spot with the
/// least overlap. Pure and deterministic: equal inputs always give equal placements.
public enum MapLabelPlacer {
    public struct Item: Sendable, Equatable {
        public var id: IPv4Address
        /// Icon centre, screen units.
        public var center: CGPoint
        public var iconSize: CGFloat
        /// Label size, screen units; nil when the node shows no label (its icon still blocks).
        public var labelSize: CGSize?
        /// Higher is placed first.
        public var priority: Int
        /// Always shown, even when it can't avoid everything.
        public var isRequired: Bool

        public init(
            id: IPv4Address, center: CGPoint, iconSize: CGFloat, labelSize: CGSize?,
            priority: Int = 0, isRequired: Bool = false
        ) {
            self.id = id
            self.center = center
            self.iconSize = iconSize
            self.labelSize = labelSize
            self.priority = priority
            self.isRequired = isRequired
        }
    }

    /// Gap between an icon and its label.
    public static let gap: CGFloat = 4

    public static func iconRect(center c: CGPoint, size s: CGFloat) -> CGRect {
        CGRect(x: c.x - s / 2, y: c.y - s / 2, width: s, height: s)
    }

    /// The label's box for a side: centred under / over the icon, or vertically centred beside it.
    public static func labelRect(
        center c: CGPoint, iconSize s: CGFloat, labelSize l: CGSize,
        side: MapLabelSide, gap: CGFloat = gap
    ) -> CGRect {
        switch side {
        case .below: CGRect(x: c.x - l.width / 2, y: c.y + s / 2 + gap, width: l.width, height: l.height)
        case .above: CGRect(x: c.x - l.width / 2, y: c.y - s / 2 - gap - l.height, width: l.width, height: l.height)
        case .right: CGRect(x: c.x + s / 2 + gap, y: c.y - l.height / 2, width: l.width, height: l.height)
        case .left: CGRect(x: c.x - s / 2 - gap - l.width, y: c.y - l.height / 2, width: l.width, height: l.height)
        }
    }

    /// Candidate sides in order of preference: below, then away from the router, towards it, above.
    private static func candidates(for c: CGPoint) -> [MapLabelSide] {
        c.x >= 0 ? [.below, .right, .left, .above] : [.below, .left, .right, .above]
    }

    /// - Parameter obstacles: fixed boxes labels must avoid (screen units).
    /// - Returns: a placement for every item that has a label.
    public static func place(_ items: [Item], obstacles: [CGRect] = []) -> [IPv4Address: MapLabelPlacement] {
        var icons = RectGrid()
        for (i, item) in items.enumerated() {
            icons.insert(iconRect(center: item.center, size: item.iconSize), tag: i)
        }
        var fixed = RectGrid()
        for o in obstacles where !o.isNull && !o.isEmpty { fixed.insert(o, tag: -1) }
        var placed = RectGrid()

        // Shrink a hair so labels that merely touch don't count as overlapping.
        func box(_ item: Item, _ size: CGSize, _ side: MapLabelSide) -> CGRect {
            labelRect(center: item.center, iconSize: item.iconSize, labelSize: size, side: side).insetBy(
                dx: 0.5, dy: 0.5)
        }

        let order = items.indices.compactMap { i in items[i].labelSize.map { (index: i, size: $0) } }
            .sorted { (items[$0.index].priority, -$0.index) > (items[$1.index].priority, -$1.index) }
        var out: [IPv4Address: MapLabelPlacement] = [:]
        out.reserveCapacity(order.count)
        for (i, size) in order {
            let item = items[i]
            let sides = candidates(for: item.center)
            if let side = sides.first(where: { side in
                let r = box(item, size, side)
                return !icons.intersects(r, except: i) && !fixed.intersects(r) && !placed.intersects(r)
            }) {
                out[item.id] = MapLabelPlacement(side: side, isVisible: true)
                placed.insert(box(item, size, side), tag: i)
            } else if item.isRequired {
                // Least-bad spot; covering an icon counts more than covering text.
                var best = sides[0]
                var bestCost = CGFloat.infinity
                for side in sides {
                    let r = box(item, size, side)
                    let cost = 4 * icons.overlap(r, except: i) + 2 * fixed.overlap(r) + placed.overlap(r)
                    if cost < bestCost - 0.001 {
                        best = side
                        bestCost = cost
                    }
                }
                out[item.id] = MapLabelPlacement(side: best, isVisible: true)
                placed.insert(box(item, size, best), tag: i)
            } else {
                out[item.id] = MapLabelPlacement(side: .below, isVisible: false)
            }
        }
        return out
    }
}

/// Boxes bucketed in a uniform grid, for quick overlap queries.
private struct RectGrid {
    private let cell: CGFloat = 48
    private var rects: [(CGRect, Int)] = []
    private var buckets: [Int64: [Int]] = [:]

    private func cells(_ r: CGRect) -> (ClosedRange<Int>, ClosedRange<Int>) {
        let x0 = Int((r.minX / cell).rounded(.down))
        let x1 = Int((r.maxX / cell).rounded(.down))
        let y0 = Int((r.minY / cell).rounded(.down))
        let y1 = Int((r.maxY / cell).rounded(.down))
        return (x0...max(x0, x1), y0...max(y0, y1))
    }

    private static func key(_ x: Int, _ y: Int) -> Int64 {
        Int64(x) << 32 ^ Int64(UInt32(bitPattern: Int32(truncatingIfNeeded: y)))
    }

    mutating func insert(_ r: CGRect, tag: Int) {
        guard r.width.isFinite, r.height.isFinite else { return }
        let n = rects.count
        rects.append((r, tag))
        let (xs, ys) = cells(r)
        for x in xs { for y in ys { buckets[Self.key(x, y), default: []].append(n) } }
    }

    /// Indices of stored boxes that intersect `r` (each once, ascending).
    private func hits(_ r: CGRect, except tag: Int?) -> [Int] {
        guard !rects.isEmpty else { return [] }
        var seen = Set<Int>()
        let (xs, ys) = cells(r)
        for x in xs {
            for y in ys {
                for n in buckets[Self.key(x, y)] ?? [] where rects[n].1 != tag {
                    if rects[n].0.intersects(r) { seen.insert(n) }
                }
            }
        }
        return seen.sorted()
    }

    func intersects(_ r: CGRect, except tag: Int? = nil) -> Bool { !hits(r, except: tag).isEmpty }

    /// Total area of `r` covered by stored boxes (overlaps between them counted twice).
    func overlap(_ r: CGRect, except tag: Int? = nil) -> CGFloat {
        hits(r, except: tag).reduce(0) { a, n in
            let i = rects[n].0.intersection(r)
            return a + i.width * i.height
        }
    }
}
