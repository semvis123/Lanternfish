import Foundation

public struct NetworkInterfaceInfo: Sendable, Hashable, Identifiable {
    public var id: String { name }
    public let name: String  // BSD name, e.g. "en0"
    public let displayName: String  // e.g. "Wi-Fi"
    public let address: IPv4Address
    public let subnet: Subnet
    public let mac: MACAddress?
    public let gateway: IPv4Address?
    public let isPrimary: Bool

    public init(
        name: String, displayName: String, address: IPv4Address, subnet: Subnet,
        mac: MACAddress?, gateway: IPv4Address?, isPrimary: Bool
    ) {
        self.name = name
        self.displayName = displayName
        self.address = address
        self.subnet = subnet
        self.mac = mac
        self.gateway = gateway
        self.isPrimary = isPrimary
    }
}
