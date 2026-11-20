import Foundation

/// Pure logic for scanning several interfaces at once: which interfaces are distinct networks,
/// and how the set of per-interface scanners must change when the interface list changes.
public enum NetworkSet {
    /// Interfaces that reach distinct networks, primary first. Two interfaces are the same network
    /// when they share subnet and gateway IP, or when both gateways' MACs are known and equal.
    /// Of duplicates, the earliest one in primary-first order is kept.
    public static func dedupe(
        _ interfaces: [NetworkInterfaceInfo],
        gatewayMACs: [IPv4Address: MACAddress] = [:]
    ) -> [NetworkInterfaceInfo] {
        let ordered = interfaces.enumerated().sorted { a, b in
            a.element.isPrimary != b.element.isPrimary ? a.element.isPrimary : a.offset < b.offset
        }.map(\.element)
        var kept: [NetworkInterfaceInfo] = []
        for iface in ordered where !kept.contains(where: { isSameNetwork($0, iface, gatewayMACs: gatewayMACs) }) {
            kept.append(iface)
        }
        return kept
    }

    public static func isSameNetwork(
        _ a: NetworkInterfaceInfo, _ b: NetworkInterfaceInfo,
        gatewayMACs: [IPv4Address: MACAddress] = [:]
    ) -> Bool {
        if a.subnet.description == b.subnet.description, a.gateway == b.gateway { return true }
        if let ga = a.gateway, let gb = b.gateway, let ma = gatewayMACs[ga], let mb = gatewayMACs[gb] {
            return ma == mb
        }
        return false
    }

    /// How to go from the interfaces being scanned (`current`) to `desired`, matched by id.
    public struct Diff: Equatable, Sendable {
        /// New interfaces: create a scanner and scan.
        public var added: [NetworkInterfaceInfo] = []
        /// Ids of interfaces that went away (or became duplicates): drop their scanner.
        public var removed: [String] = []
        /// Same id, new address/subnet/gateway: update the scanner and rescan.
        public var changed: [NetworkInterfaceInfo] = []
        /// Same network, other details changed (name, MAC, primary flag): update without rescanning.
        public var updated: [NetworkInterfaceInfo] = []

        public var isEmpty: Bool { added.isEmpty && removed.isEmpty && changed.isEmpty && updated.isEmpty }
    }

    public static func diff(current: [NetworkInterfaceInfo], desired: [NetworkInterfaceInfo]) -> Diff {
        var d = Diff()
        let old = Dictionary(current.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let desiredIDs = Set(desired.map(\.id))
        d.removed = current.map(\.id).filter { !desiredIDs.contains($0) }
        for iface in desired {
            guard let prev = old[iface.id] else {
                d.added.append(iface)
                continue
            }
            if needsRescan(from: prev, to: iface) {
                d.changed.append(iface)
            } else if prev != iface {
                d.updated.append(iface)
            }
        }
        return d
    }

    /// Whether an interface now reaches a different network (or the same one at another address).
    public static func needsRescan(from old: NetworkInterfaceInfo, to new: NetworkInterfaceInfo) -> Bool {
        old.address != new.address || old.subnet != new.subnet || old.gateway != new.gateway
    }
}
