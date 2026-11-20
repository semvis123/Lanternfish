import CoreGraphics
import Testing

@testable import LanternfishKit

@Suite struct MapLayoutTests {
    /// `count` addresses split across `groupSizes` (remainder in the last group).
    private func groups(_ sizes: [Int]) -> [[IPv4Address]] {
        var next: UInt32 = 0xC0A8_0102  // 192.168.1.2
        return sizes.map { n in
            (0..<n).map { _ in
                defer { next += 1 }
                return IPv4Address(next)
            }
        }
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }

    private func assertNoOverlaps(
        _ layout: MapLayout, nodeSize: CGFloat,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let points = Array(layout.positions.values) + [.zero, layout.internet]
        var minDistance = CGFloat.infinity
        for i in points.indices {
            for j in points.indices where j > i {
                minDistance = min(minDistance, distance(points[i], points[j]))
            }
        }
        #expect(
            minDistance >= nodeSize - 0.01, "closest nodes \(minDistance) apart",
            sourceLocation: sourceLocation)
    }

    @Test func eightyNodesDoNotOverlap() {
        let g = groups([3, 22, 14, 9, 17, 2, 4, 9])
        let layout = MapLayout.compute(groups: g, ringSpacing: 130, nodeSize: 110)
        #expect(layout.positions.count == 80)
        #expect(layout.ringRadii.count > 1, "80 nodes should need more than one ring")
        assertNoOverlaps(layout, nodeSize: 110)
    }

    @Test(arguments: [1, 2, 3, 5, 7, 12, 20, 33, 50, 64, 80, 120])
    func noOverlapsAcrossSizes(count: Int) {
        // Uneven groups, including singletons and one big group.
        var sizes: [Int] = []
        var left = count
        for s in [1, count / 2, 2, 1, count / 5, 3, 1] where left > 0 {
            let n = min(max(s, 1), left)
            sizes.append(n)
            left -= n
        }
        if left > 0 { sizes.append(left) }
        let layout = MapLayout.compute(groups: groups(sizes), ringSpacing: 120, nodeSize: 100)
        #expect(layout.positions.count == count)
        assertNoOverlaps(layout, nodeSize: 100)
    }

    @Test func singleGroupOfEighty() {
        let layout = MapLayout.compute(groups: groups([80]), nodeSize: 110)
        #expect(layout.positions.count == 80)
        assertNoOverlaps(layout, nodeSize: 110)
    }

    @Test func deterministic() {
        let g = groups([4, 10, 3, 0, 7, 1])
        let a = MapLayout.compute(groups: g)
        let b = MapLayout.compute(groups: g)
        #expect(a == b)
        #expect(MapLayout.positions(for: g) == a.positions)
    }

    @Test func routerAtCentreAndInternetAbove() {
        let layout = MapLayout.compute(groups: groups([2, 3, 1]), nodeSize: 110)
        // The router is the origin: every node sits on a ring around it.
        for p in layout.positions.values {
            let r = distance(p, .zero)
            #expect(layout.ringRadii.contains { abs($0 - r) < 0.01 })
            #expect(r >= 110)
        }
        #expect(layout.internet.x == 0)
        #expect(layout.internet.y < 0)
        #expect(layout.bounds.contains(CGPoint.zero))
        #expect(layout.bounds.contains(layout.internet))
        for p in layout.positions.values { #expect(layout.bounds.contains(p)) }
    }

    @Test func smallNetworksHangBelowRouter() {
        let layout = MapLayout.compute(groups: groups([3]))
        // A few devices hang below the router, symmetric about the vertical axis.
        for p in layout.positions.values { #expect(p.y > 0) }
        #expect(abs(layout.positions.values.map(\.x).reduce(0, +)) < 0.01)
        #expect(layout.ringRadii.count == 1)
        // The internet's slot at the top stays free even when the circle is full.
        let big = MapLayout.compute(groups: groups([20, 20, 20]))
        for p in big.positions.values { #expect(hypot(p.x - big.internet.x, p.y - big.internet.y) >= 110) }
    }

    @Test func groupsOccupyContiguousSectors() {
        let g = groups([5, 5, 5])
        let layout = MapLayout.compute(groups: g)
        #expect(layout.groupLabels.map(\.index) == [0, 1, 2])
        // Sector angles increase clockwise (y-down) in group order.
        let angles = layout.groupLabels.map(\.angle)
        #expect(angles == angles.sorted())
    }

    @Test func sectorsContainTheirNodesAndDoNotOverlap() {
        let g = groups([5, 12, 3])
        let layout = MapLayout.compute(groups: g)
        for label in layout.groupLabels {
            #expect(label.startAngle < label.angle && label.angle < label.endAngle)
            #expect(label.innerRadius == layout.ringRadii[0])
            for ip in g[label.index] {
                let p = layout.positions[ip]!
                let r = hypot(p.x, p.y)
                #expect(r >= label.innerRadius - 0.01 && r <= label.outerRadius + 0.01)
                var a = atan2(p.y, p.x)
                while a < label.startAngle { a += 2 * .pi }
                #expect(a <= label.endAngle + 0.001)
            }
        }
        for (a, b) in zip(layout.groupLabels, layout.groupLabels.dropFirst()) {
            #expect(a.endAngle <= b.startAngle)
        }
    }

    @Test func emptyGroupsAreSkipped() {
        let layout = MapLayout.compute(groups: [[], groups([3])[0], []])
        #expect(layout.groupLabels.map(\.index) == [1])
        #expect(MapLayout.compute(groups: []).positions.isEmpty)
    }

    @Test func kindsMapToGroups() {
        #expect(MapGroup(kind: .phone) == .mobile)
        #expect(MapGroup(kind: .tablet) == .mobile)
        #expect(MapGroup(kind: .speaker) == .media)
        #expect(MapGroup(kind: .camera) == .peripherals)
        #expect(MapGroup(kind: .nas) == .servers)
        #expect(Set(DeviceKind.allCases.map(MapGroup.init(kind:))).count == MapGroup.allCases.count)
    }
}

@Suite struct MapLabelPlacerTests {
    private let a = IPv4Address("10.0.0.2")!
    private let b = IPv4Address("10.0.0.3")!
    private let c = IPv4Address("10.0.0.4")!

    private func labelRect(_ item: MapLabelPlacer.Item, _ p: MapLabelPlacement) -> CGRect {
        MapLabelPlacer.labelRect(center: item.center, iconSize: item.iconSize, labelSize: item.labelSize!, side: p.side)
    }

    @Test func labelStaysBelowWhenFree() {
        let items = [
            MapLabelPlacer.Item(
                id: a, center: CGPoint(x: 50, y: 0), iconSize: 40, labelSize: CGSize(width: 80, height: 30)),
            MapLabelPlacer.Item(
                id: b, center: CGPoint(x: 250, y: 0), iconSize: 40, labelSize: CGSize(width: 80, height: 30)),
        ]
        let p = MapLabelPlacer.place(items)
        #expect(p[a] == MapLabelPlacement(side: .below, isVisible: true))
        #expect(p[b] == MapLabelPlacement(side: .below, isVisible: true))
    }

    @Test func labelMovesOutwardWhenANodeSitsBelow() {
        let label = CGSize(width: 76, height: 29)
        // Right of the router: flips to the right; left of it: to the left.
        for (x, side) in [(CGFloat(100), MapLabelSide.right), (-100, .left)] {
            let items = [
                MapLabelPlacer.Item(
                    id: a, center: CGPoint(x: x, y: 0), iconSize: 18, labelSize: label,
                    priority: 2, isRequired: true),
                MapLabelPlacer.Item(id: b, center: CGPoint(x: x + 12, y: 34), iconSize: 18, labelSize: nil),
            ]
            let p = MapLabelPlacer.place(items)
            #expect(p[a] == MapLabelPlacement(side: side, isVisible: true))
            let r = labelRect(items[0], p[a]!)
            #expect(!r.intersects(MapLabelPlacer.iconRect(center: items[1].center, size: 18)))
        }
    }

    @Test func boxedInLabelsFadeUnlessRequired() {
        // b sits in a tight cluster: every side of its label is covered by a neighbour icon.
        let size = CGSize(width: 60, height: 20)
        let around = [CGPoint(x: 0, y: 28), CGPoint(x: 40, y: 0), CGPoint(x: -40, y: 0), CGPoint(x: 0, y: -28)]
        var items = around.enumerated().map { i, p in
            MapLabelPlacer.Item(id: IPv4Address(0x0A00_0100 + UInt32(i)), center: p, iconSize: 20, labelSize: nil)
        }
        items.append(MapLabelPlacer.Item(id: b, center: .zero, iconSize: 20, labelSize: size))
        #expect(MapLabelPlacer.place(items)[b] == MapLabelPlacement(side: .below, isVisible: false))
        items[items.count - 1].isRequired = true
        #expect(MapLabelPlacer.place(items)[b]?.isVisible == true)
    }

    @Test func higherPriorityLabelWinsTheSpot() {
        // Two labels that would overlap below their icons: the important one keeps its place.
        let size = CGSize(width: 100, height: 30)
        let items = [
            MapLabelPlacer.Item(id: a, center: CGPoint(x: 0, y: 0), iconSize: 20, labelSize: size),
            MapLabelPlacer.Item(id: b, center: CGPoint(x: 40, y: 0), iconSize: 20, labelSize: size, priority: 3),
        ]
        let p = MapLabelPlacer.place(items)
        #expect(p[b] == MapLabelPlacement(side: .below, isVisible: true))
        if let pa = p[a], pa.isVisible {
            #expect(!labelRect(items[0], pa).intersects(labelRect(items[1], p[b]!)))
        }
    }

    @Test func placementIsDeterministic() {
        var next: UInt32 = 0x0A00_0002
        let groups = [5, 12, 9].map { n in
            (0..<n).map { _ in
                defer { next += 1 }
                return IPv4Address(next)
            }
        }
        let layout = MapLayout.compute(groups: groups, ringSpacing: 128, nodeSize: 112)
        let items = groups.flatMap { $0 }.map { id in
            MapLabelPlacer.Item(
                id: id, center: CGPoint(x: layout.positions[id]!.x * 0.5, y: layout.positions[id]!.y * 0.5),
                iconSize: 20, labelSize: CGSize(width: 76, height: 29))
        }
        #expect(MapLabelPlacer.place(items) == MapLabelPlacer.place(items))
    }

    /// "This Mac" and another computer in the same sector. The Mac's label is always shown (even
    /// zoomed out, where other names fade), so it must not hang over the other computer's icon.
    /// At every zoom the app uses, no shown label may cover another node's icon, the router /
    /// internet captions, or another shown label.
    @Test(arguments: [0.4, 0.5, 0.62, 0.75, 1.0, 1.5])
    func twoComputersLabelsAvoidIcons(zoom: Double) {
        let z = CGFloat(zoom)
        var next: UInt32 = 0x0A00_0002
        // Computers, Phones, Printers, Other.
        let groups = [2, 1, 1, 8].map { n in
            (0..<n).map { _ in
                defer { next += 1 }
                return IPv4Address(next)
            }
        }
        let layout = MapLayout.compute(groups: groups, ringSpacing: 128, nodeSize: 112)
        var sim = MapSimulation(nodeSize: 112)
        sim.update(
            targets: groups.flatMap { $0 }.map { ($0, layout.positions[$0]!) }, pins: [:],
            obstacles: [.zero, layout.internet], entrance: .place)
        sim.settle()
        let me = groups[0][0]
        let other = groups[0][1]

        // Screen-size metrics as the app draws them (MapNodeMetrics).
        let icon = min(max(40 * z, 18), 76)
        let namesShown = z >= 0.42
        let detail = z >= 0.6
        func label(lines: CGFloat, width: CGFloat) -> CGSize {
            CGSize(width: width, height: lines * 14 + 3 + (detail ? 13 : 0))
        }
        let items = sim.bodies.map { body in
            let isMe = body.id == me
            return MapLabelPlacer.Item(
                id: body.id, center: CGPoint(x: body.position.x * z, y: body.position.y * z), iconSize: icon,
                labelSize: isMe ? label(lines: 2, width: 76) : namesShown ? label(lines: 1, width: 70) : nil,
                priority: isMe ? 2 : 0, isRequired: isMe)
        }
        let routerIcon = min(max(54 * z, 26), 96)
        let net = CGPoint(x: layout.internet.x * z, y: layout.internet.y * z)
        let netIcon = min(max(34 * z, 20), 60)
        let obstacles = [
            MapLabelPlacer.iconRect(center: .zero, size: routerIcon),
            MapLabelPlacer.labelRect(
                center: .zero, iconSize: routerIcon, labelSize: CGSize(width: 150, height: 62), side: .below),
            MapLabelPlacer.iconRect(center: net, size: netIcon),
            MapLabelPlacer.labelRect(
                center: net, iconSize: netIcon, labelSize: CGSize(width: 50, height: 14), side: .below),
        ]
        let placements = MapLabelPlacer.place(items, obstacles: obstacles)

        #expect(placements[me]?.isVisible == true)
        let meItem = items.first { $0.id == me }!
        let otherItem = items.first { $0.id == other }!
        let meLabel = labelRect(meItem, placements[me]!)
        #expect(
            !meLabel.intersects(MapLabelPlacer.iconRect(center: otherItem.center, size: icon)),
            "This Mac's label covers the other computer at \(zoom)")

        var shown: [(IPv4Address, CGRect)] = []
        for item in items {
            guard let p = placements[item.id], p.isVisible else { continue }
            shown.append((item.id, labelRect(item, p).insetBy(dx: 0.5, dy: 0.5)))
        }
        for (id, r) in shown {
            for item in items where item.id != id {
                #expect(
                    !r.intersects(MapLabelPlacer.iconRect(center: item.center, size: item.iconSize)),
                    "label of \(id) covers \(item.id) at zoom \(zoom)")
            }
            for o in obstacles { #expect(!r.intersects(o), "label of \(id) covers the router / internet at \(zoom)") }
            for (id2, r2) in shown where id2 > id {
                #expect(!r.intersects(r2), "labels \(id) / \(id2) overlap at \(zoom)")
            }
        }
    }
}
