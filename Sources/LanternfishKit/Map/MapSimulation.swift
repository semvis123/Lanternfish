import CoreGraphics
import Foundation

/// A small, deterministic force simulation for the network map.
///
/// Every node is a unit mass pulled towards its *target* (its `MapLayout` position, which
/// already encodes the ring / group sector it belongs to) by a damped spring, and pushed out of
/// other nodes and fixed obstacles (router, internet) by a stiff collision spring. Pinned and
/// dragged nodes are immovable; the rest flow around them.
///
/// The simulation runs in fixed time steps (so results don't depend on the frame rate) and
/// goes to sleep once nothing moves, so a settled map costs nothing per frame. Coordinates are
/// the layout's (router at the origin, y-down).
public struct MapSimulation: Sendable, Equatable {
    public struct Body: Sendable, Equatable {
        public let id: IPv4Address
        public var position: CGPoint
        public var velocity: CGPoint = .zero
        /// Where the layout wants the node.
        public var target: CGPoint
        /// User-placed position; the node stays exactly here.
        public var pin: CGPoint?
        /// Being dragged: position is set from outside, it doesn't react to forces.
        public var isDragged = false
        /// Seconds since the node entered the map; negative while it waits for its entrance.
        public var age: Double

        public var isPinned: Bool { pin != nil }
        var isFixed: Bool { isDragged || pin != nil }
    }

    public struct Parameters: Sendable, Equatable {
        /// Spring towards the target, 1/s². ω = √k ≈ 8.4 rad/s.
        public var stiffness: Double = 70
        /// < 1 gives a slight, lively overshoot.
        public var dampingRatio: Double = 0.78
        /// Collision spring between overlapping nodes, 1/s².
        public var collisionStiffness: Double = 900
        /// Nodes closer than `nodeSize × collisionFraction` push each other apart.
        public var collisionFraction: CGFloat = 0.95
        /// A dragged node clears a wider path, so its neighbours visibly make room.
        public var dragClearance: CGFloat = 1.3
        /// New nodes pass through each other for this long, then collisions fade in.
        public var ghostTime: Double = 0.45
        public var maxSpeed: CGFloat = 6000
        /// Asleep when every free node moves slower than this (pt/s)…
        public var sleepSpeed: CGFloat = 1.5
        /// …and its net force is below `stiffness × sleepDistance`.
        public var sleepDistance: CGFloat = 0.35

        public init() {}
    }

    public enum Entrance: Sendable, Equatable {
        /// New nodes appear at their targets, at rest.
        case place
        /// New nodes start next to `origin` and spring out to their targets; when several enter
        /// at once each waits `stagger` seconds longer than the previous (capped at 0.6 s).
        case spawn(from: CGPoint, stagger: Double)
    }

    public private(set) var bodies: [Body] = []
    private var index: [IPv4Address: Int] = [:]
    /// Fixed nodes the others keep clear of (router, internet).
    public private(set) var obstacles: [CGPoint] = []
    public var nodeSize: CGFloat
    public var parameters: Parameters
    public private(set) var isAsleep = true
    /// Fixed integration step.
    public let timeStep: Double = 1.0 / 120
    private var accumulator: Double = 0

    public init(nodeSize: CGFloat, parameters: Parameters = Parameters()) {
        self.nodeSize = nodeSize
        self.parameters = parameters
    }

    public func body(_ id: IPv4Address) -> Body? { index[id].map { bodies[$0] } }
    public func position(of id: IPv4Address) -> CGPoint? { index[id].map { bodies[$0].position } }

    // MARK: Updates

    /// Sets the nodes and their targets (in display order, which also fixes the integration
    /// order, keeping runs reproducible). Nodes not listed are removed; their ids are returned.
    /// `pins` are applied to listed nodes (a node with no entry is unpinned).
    @discardableResult
    public mutating func update(
        targets: [(IPv4Address, CGPoint)], pins: [IPv4Address: CGPoint],
        obstacles: [CGPoint], entrance: Entrance
    ) -> [IPv4Address] {
        var changed = obstacles != self.obstacles
        self.obstacles = obstacles
        let keep = Set(targets.map(\.0))
        let removed = bodies.map(\.id).filter { !keep.contains($0) }
        changed = changed || !removed.isEmpty

        var next: [Body] = []
        next.reserveCapacity(targets.count)
        var entering = 0
        for (id, target) in targets {
            if var b = body(id) {
                if b.target != target {
                    b.target = target
                    changed = true
                }
                if !b.isDragged, b.pin != pins[id] {
                    b.pin = pins[id]
                    if let p = b.pin {
                        b.position = p
                        b.velocity = .zero
                    }
                    changed = true
                }
                next.append(b)
                continue
            }
            changed = true
            let pin = pins[id]
            switch entrance {
            case .place:
                next.append(
                    Body(
                        id: id, position: pin ?? target, target: target, pin: pin,
                        age: parameters.ghostTime))
            case .spawn(let origin, let stagger):
                if let pin {
                    next.append(Body(id: id, position: pin, target: target, pin: pin, age: 0))
                    continue
                }
                // Just outside the origin, in the direction of the target.
                let dx = target.x - origin.x
                let dy = target.y - origin.y
                let len = max(hypot(dx, dy), 0.001)
                let start = CGPoint(
                    x: origin.x + dx / len * nodeSize * 0.3,
                    y: origin.y + dy / len * nodeSize * 0.3)
                let delay = min(Double(entering) * stagger, 0.6)
                entering += 1
                next.append(
                    Body(
                        id: id, position: start,
                        velocity: CGPoint(x: dx / len * 60, y: dy / len * 60),
                        target: target, pin: nil, age: -delay))
            }
        }
        if next.map(\.id) != bodies.map(\.id) { changed = true }
        bodies = next
        index = Dictionary(uniqueKeysWithValues: bodies.enumerated().map { ($1.id, $0) })
        if changed { isAsleep = false }
        return removed
    }

    public mutating func wake() { isAsleep = false }

    // MARK: Direct manipulation

    public mutating func beginDrag(_ id: IPv4Address) {
        guard let i = index[id] else { return }
        bodies[i].isDragged = true
        bodies[i].velocity = .zero
        isAsleep = false
    }

    public mutating func drag(_ id: IPv4Address, to p: CGPoint) {
        guard let i = index[id] else { return }
        bodies[i].position = p
        bodies[i].age = max(bodies[i].age, parameters.ghostTime)
        isAsleep = false
    }

    /// Ends a drag; with `pin` the node stays where it was dropped.
    public mutating func endDrag(_ id: IPv4Address, pin: Bool) {
        guard let i = index[id] else { return }
        bodies[i].isDragged = false
        if pin { bodies[i].pin = bodies[i].position }
        isAsleep = false
    }

    /// Pins a node at `p`, or unpins it (it springs back to its target).
    public mutating func setPin(_ id: IPv4Address, _ p: CGPoint?) {
        guard let i = index[id] else { return }
        bodies[i].pin = p
        if let p { bodies[i].position = p }
        bodies[i].velocity = .zero
        isAsleep = false
    }

    // MARK: Integration

    /// Advances by wall-clock `elapsed` seconds in fixed steps. Returns true if anything moved.
    @discardableResult
    public mutating func advance(by elapsed: Double) -> Bool {
        guard !isAsleep else {
            accumulator = 0
            return false
        }
        accumulator += min(max(elapsed, 0), 0.1)
        var moved = false
        while accumulator >= timeStep {
            accumulator -= timeStep
            step()
            moved = true
            if isAsleep {
                accumulator = 0
                break
            }
        }
        return moved
    }

    /// Runs until the simulation sleeps (or `maxSteps`). Returns true if it settled.
    @discardableResult
    public mutating func settle(maxSteps: Int = 6000) -> Bool {
        var n = 0
        while !isAsleep, n < maxSteps {
            step()
            n += 1
        }
        return isAsleep
    }

    /// One fixed step: forces, semi-implicit Euler, damping, sleep check.
    public mutating func step() {
        let p = parameters
        let dt = timeStep
        let n = bodies.count
        let k = CGFloat(p.stiffness)
        let damping = CGFloat(exp(-2 * p.dampingRatio * p.stiffness.squareRoot() * dt))
        let kc = CGFloat(p.collisionStiffness)
        let minD = nodeSize * p.collisionFraction

        // Entrance: waiting nodes count down; collisions fade in after `ghostTime`.
        var weight = [CGFloat](repeating: 0, count: n)
        for i in 0..<n {
            bodies[i].age += dt
            let a = bodies[i].age
            weight[i] = bodies[i].isFixed ? 1 : CGFloat(min(max((a - p.ghostTime * 0.3) / (p.ghostTime * 0.7), 0), 1))
        }

        var force = [CGPoint](repeating: .zero, count: n)
        for i in 0..<n where !bodies[i].isFixed && bodies[i].age >= 0 {
            force[i].x = k * (bodies[i].target.x - bodies[i].position.x)
            force[i].y = k * (bodies[i].target.y - bodies[i].position.y)
        }

        // Pairwise collisions, O(n²) — fine for the few hundred nodes a LAN has.
        for i in 0..<n where bodies[i].age >= 0 {
            let pi = bodies[i].position
            for j in (i + 1)..<max(i + 1, n) where bodies[j].age >= 0 {
                let w = min(weight[i], weight[j])
                guard w > 0 else { continue }
                if bodies[i].isFixed && bodies[j].isFixed { continue }
                let reach = bodies[i].isDragged || bodies[j].isDragged ? minD * p.dragClearance : minD
                var dx = bodies[j].position.x - pi.x
                var dy = bodies[j].position.y - pi.y
                if abs(dx) > reach || abs(dy) > reach { continue }
                var d = hypot(dx, dy)
                guard d < reach else { continue }
                if d < 0.001 {
                    // Coincident: separate along a deterministic direction.
                    let a = CGFloat(i * 7 + j * 13)
                    dx = cos(a) * 0.001
                    dy = sin(a) * 0.001
                    d = 0.001
                }
                let f = kc * (reach - d) * w / d
                force[i].x -= dx * f
                force[i].y -= dy * f
                force[j].x += dx * f
                force[j].y += dy * f
            }
            for o in obstacles {
                let dx = pi.x - o.x
                let dy = pi.y - o.y
                if abs(dx) > minD || abs(dy) > minD { continue }
                let d = max(hypot(dx, dy), 0.001)
                guard d < minD else { continue }
                let f = kc * (minD - d) * weight[i] / d
                force[i].x += dx * f
                force[i].y += dy * f
            }
        }

        var awake = false
        let sleepForce = k * p.sleepDistance
        for i in 0..<n {
            if bodies[i].isDragged {
                awake = true
                continue
            }
            if let pin = bodies[i].pin {
                bodies[i].position = pin
                bodies[i].velocity = .zero
                continue
            }
            if bodies[i].age < 0 {
                awake = true
                continue
            }
            var v = bodies[i].velocity
            v.x = (v.x + force[i].x * dt) * damping
            v.y = (v.y + force[i].y * dt) * damping
            let speed = hypot(v.x, v.y)
            if speed > p.maxSpeed {
                v.x *= p.maxSpeed / speed
                v.y *= p.maxSpeed / speed
            }
            bodies[i].velocity = v
            bodies[i].position.x += v.x * dt
            bodies[i].position.y += v.y * dt
            if speed > p.sleepSpeed || hypot(force[i].x, force[i].y) > sleepForce || weight[i] < 1 {
                awake = true
            }
        }
        if !awake {
            for i in 0..<n { bodies[i].velocity = .zero }
        }
        isAsleep = !awake
    }
}
