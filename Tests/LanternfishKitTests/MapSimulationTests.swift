import CoreGraphics
import Foundation
import Testing

@testable import LanternfishKit

@Suite struct MapSimulationTests {
    private let nodeSize: CGFloat = 112

    private func layout(_ sizes: [Int]) -> (MapLayout, [(IPv4Address, CGPoint)]) {
        var next: UInt32 = 0xC0A8_0102
        let groups = sizes.map { n in
            (0..<n).map { _ in
                defer { next += 1 }
                return IPv4Address(next)
            }
        }
        let layout = MapLayout.compute(groups: groups, ringSpacing: 128, nodeSize: nodeSize)
        let targets = groups.flatMap { $0 }.map { ($0, layout.positions[$0]!) }
        return (layout, targets)
    }

    private func minDistance(_ sim: MapSimulation) -> CGFloat {
        let pts = sim.bodies.map(\.position) + sim.obstacles
        var m = CGFloat.infinity
        for i in pts.indices {
            for j in pts.indices where j > i { m = min(m, hypot(pts[i].x - pts[j].x, pts[i].y - pts[j].y)) }
        }
        return m
    }

    @Test(arguments: [1, 7, 30, 80])
    func spawnedNodesSettleOnTargetsWithoutOverlaps(count: Int) {
        let (layout, targets) = layout([count / 3, count - count / 3 - count / 4, count / 4].filter { $0 > 0 })
        var sim = MapSimulation(nodeSize: nodeSize)
        sim.update(
            targets: targets, pins: [:], obstacles: [.zero, layout.internet],
            entrance: .spawn(from: .zero, stagger: 0.01))
        #expect(!sim.isAsleep)
        // Settles within 10 simulated seconds.
        let settled1 = sim.settle(maxSteps: 1200)
        #expect(settled1)
        #expect(minDistance(sim) >= nodeSize * 0.9, "closest nodes \(minDistance(sim)) apart")
        for b in sim.bodies {
            #expect(hypot(b.position.x - b.target.x, b.position.y - b.target.y) < 2)
        }
        // Asleep means no work per frame.
        let before = sim
        let moved = sim.advance(by: 1.0 / 60)
        #expect(!moved)
        #expect(sim == before)
    }

    @Test func deterministic() {
        let (layout, targets) = layout([5, 12, 9])
        func run() -> MapSimulation {
            var sim = MapSimulation(nodeSize: nodeSize)
            sim.update(
                targets: targets, pins: [:], obstacles: [.zero, layout.internet],
                entrance: .spawn(from: .zero, stagger: 0.012))
            for _ in 0..<50 { sim.advance(by: 1.0 / 60) }
            sim.settle()
            return sim
        }
        #expect(run().bodies == run().bodies)
    }

    @Test func placedNodesStartAtRest() {
        let (layout, targets) = layout([4, 6])
        var sim = MapSimulation(nodeSize: nodeSize)
        sim.update(targets: targets, pins: [:], obstacles: [.zero, layout.internet], entrance: .place)
        sim.step()
        #expect(sim.isAsleep)
        for (id, t) in targets { #expect(sim.position(of: id) == t) }
        // Re-applying the same targets doesn't wake it…
        sim.update(targets: targets, pins: [:], obstacles: [.zero, layout.internet], entrance: .place)
        #expect(sim.isAsleep)
        // …moving one does, and only that node travels.
        var moved = targets
        moved[0].1.x += 40
        sim.update(targets: moved, pins: [:], obstacles: [.zero, layout.internet], entrance: .place)
        #expect(!sim.isAsleep)
        sim.settle()
        #expect(abs(sim.position(of: moved[0].0)!.x - moved[0].1.x) < 1)
        #expect(sim.position(of: targets[3].0) == targets[3].1)
    }

    @Test func pinnedNodeStaysAndNeighbourMakesRoom() {
        let (layout, targets) = layout([6])
        let a = targets[0].0
        let b = targets[1].0
        var sim = MapSimulation(nodeSize: nodeSize)
        // Pin `a` right on top of `b`'s slot.
        let pin = targets[1].1
        sim.update(targets: targets, pins: [a: pin], obstacles: [.zero, layout.internet], entrance: .place)
        let settled2 = sim.settle()
        #expect(settled2)
        #expect(sim.position(of: a) == pin)
        let pb = sim.position(of: b)!
        #expect(hypot(pb.x - pin.x, pb.y - pin.y) >= nodeSize * 0.85)
        // Unpinning sends both back home.
        sim.setPin(a, nil)
        let settled3 = sim.settle()
        #expect(settled3)
        #expect(minDistance(sim) >= nodeSize * 0.9)
        #expect(hypot(sim.position(of: a)!.x - targets[0].1.x, sim.position(of: a)!.y - targets[0].1.y) < 2)
    }

    @Test func draggingPushesNeighboursAndDropPins() {
        let (layout, targets) = layout([8])
        let a = targets[0].0
        let b = targets[1].0
        var sim = MapSimulation(nodeSize: nodeSize)
        sim.update(targets: targets, pins: [:], obstacles: [.zero, layout.internet], entrance: .place)
        sim.settle()
        sim.beginDrag(a)
        let drop = CGPoint(x: (targets[1].1.x + targets[2].1.x) / 2, y: (targets[1].1.y + targets[2].1.y) / 2)
        sim.drag(a, to: drop)
        for _ in 0..<60 { sim.advance(by: 1.0 / 60) }
        #expect(!sim.isAsleep, "never sleeps mid-drag")
        let pb = sim.position(of: b)!
        #expect(hypot(pb.x - drop.x, pb.y - drop.y) >= nodeSize * 0.95)
        sim.endDrag(a, pin: true)
        #expect(sim.body(a)?.pin == drop)
        let settled4 = sim.settle()
        #expect(settled4)
        #expect(sim.position(of: a) == drop)
    }

    @Test func removedNodesAreReported() {
        let (layout, targets) = layout([3])
        var sim = MapSimulation(nodeSize: nodeSize)
        sim.update(targets: targets, pins: [:], obstacles: [.zero, layout.internet], entrance: .place)
        let removed = sim.update(
            targets: Array(targets.prefix(2)), pins: [:],
            obstacles: [.zero, layout.internet], entrance: .place)
        #expect(removed == [targets[2].0])
        #expect(sim.bodies.count == 2)
    }
}

@Suite struct MapPinStoreTests {
    private func withStore(_ body: (MapPinStore) -> Void) {
        let suite = "MapPinStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        body(MapPinStore(defaults: defaults))
        defaults.removePersistentDomain(forName: suite)
    }

    @Test func roundTripsPerNetwork() {
        withStore { store in
            #expect(store.pins(network: "home").isEmpty)
            store.setPin(CGPoint(x: 12.5, y: -40), device: "mac:aa", network: "home")
            store.setPin(CGPoint(x: 1, y: 2), device: "192.168.1.9", network: "home")
            store.setPin(CGPoint(x: 99, y: 99), device: "mac:aa", network: "office")
            #expect(
                store.pins(network: "home") == [
                    "mac:aa": CGPoint(x: 12.5, y: -40),
                    "192.168.1.9": CGPoint(x: 1, y: 2),
                ])
            #expect(store.pins(network: "office") == ["mac:aa": CGPoint(x: 99, y: 99)])
            // A fresh store on the same defaults sees the same pins.
            #expect(MapPinStore(defaults: store.defaults).pins(network: "home").count == 2)
        }
    }

    @Test func unpinAndClear() {
        withStore { store in
            store.setPin(CGPoint(x: 1, y: 1), device: "a", network: "n")
            store.setPin(CGPoint(x: 2, y: 2), device: "b", network: "n")
            store.setPin(nil, device: "a", network: "n")
            #expect(store.pins(network: "n") == ["b": CGPoint(x: 2, y: 2)])
            store.setPin(CGPoint(x: 3, y: 3), device: "c", network: "m")
            store.clear(network: "n")
            #expect(store.pins(network: "n").isEmpty)
            #expect(store.pins(network: "m").count == 1)
        }
    }
}
