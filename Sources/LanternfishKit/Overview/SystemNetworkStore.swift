import Foundation

#if os(macOS)
    import SystemConfiguration
#endif

/// The platform seam for SystemConfiguration, whose dynamic store and interface list are
/// macOS-only. Elsewhere every query comes back empty and callers fall back to what BSD APIs
/// (getifaddrs) provide.
enum SystemNetworkStore {
    enum InterfaceType: Sendable { case wifi, ethernet, other }

    struct Interface: Sendable {
        var bsdName: String
        var displayName: String?
        var hardwareAddress: String?
        var type: InterfaceType
    }

    /// Dynamic-store keys for the system-wide (primary service) network state.
    enum GlobalKey {
        static let ipv4 = "State:/Network/Global/IPv4"
        static let ipv6 = "State:/Network/Global/IPv6"
        static let dns = "State:/Network/Global/DNS"
    }

    /// A dynamic-store dictionary such as `GlobalKey.ipv4`.
    static func value(forKey key: String) -> [String: Any]? {
        #if os(macOS)
            guard let store = SCDynamicStoreCreate(nil, "LanternfishKit" as CFString, nil, nil) else { return nil }
            return SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any]
        #else
            return nil
        #endif
    }

    /// Every network interface SystemConfiguration knows about.
    static func interfaces() -> [Interface] {
        #if os(macOS)
            guard let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return [] }
            return all.compactMap { iface in
                guard let bsd = SCNetworkInterfaceGetBSDName(iface) as String? else { return nil }
                let type = SCNetworkInterfaceGetInterfaceType(iface)
                return Interface(
                    bsdName: bsd,
                    displayName: SCNetworkInterfaceGetLocalizedDisplayName(iface) as String?,
                    hardwareAddress: SCNetworkInterfaceGetHardwareAddressString(iface) as String?,
                    type: type == kSCNetworkInterfaceTypeIEEE80211
                        ? .wifi
                        : type == kSCNetworkInterfaceTypeEthernet ? .ethernet : .other)
            }
        #else
            return []
        #endif
    }
}
