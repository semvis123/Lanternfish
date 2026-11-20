import CoreGraphics
import Foundation

/// Remembers where the user dropped map nodes, per network, in `UserDefaults`.
/// Devices are keyed by a stable key (their history key, else their IP); positions are in
/// layout coordinates (router at the origin).
public struct MapPinStore {
    public let defaults: UserDefaults
    public let key: String

    public init(defaults: UserDefaults = .standard, key: String = "MapPins.v1") {
        self.defaults = defaults
        self.key = key
    }

    private var all: [String: [String: [Double]]] {
        defaults.dictionary(forKey: key) as? [String: [String: [Double]]] ?? [:]
    }

    /// Pinned positions for one network, by device key.
    public func pins(network: String) -> [String: CGPoint] {
        (all[network] ?? [:]).compactMapValues { v in
            v.count == 2 && v.allSatisfy(\.isFinite) ? CGPoint(x: v[0], y: v[1]) : nil
        }
    }

    /// Pins (or with nil, unpins) one device.
    public func setPin(_ p: CGPoint?, device: String, network: String) {
        var a = all
        var net = a[network] ?? [:]
        net[device] = p.map { [Double($0.x), Double($0.y)] }
        a[network] = net.isEmpty ? nil : net
        defaults.set(a, forKey: key)
    }

    /// Forgets every pin of a network.
    public func clear(network: String) {
        var a = all
        a[network] = nil
        defaults.set(a, forKey: key)
    }
}
