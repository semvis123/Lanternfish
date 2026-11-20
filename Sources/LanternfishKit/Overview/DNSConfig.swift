import Foundation

/// The system's primary DNS configuration (`State:/Network/Global/DNS`).
public struct DNSConfiguration: Sendable, Hashable {
    public var servers: [String]
    public var searchDomains: [String]
    public var domainName: String?

    public init(servers: [String] = [], searchDomains: [String] = [], domainName: String? = nil) {
        self.servers = servers
        self.searchDomains = searchDomains
        self.domainName = domainName
    }

    /// True when one of the servers is the gateway (the router forwards DNS).
    public func usesRouter(_ gateway: IPv4Address?) -> Bool {
        guard let gateway else { return false }
        return servers.contains { IPv4Address($0) == gateway }
    }

    /// Recognizes well-known public resolvers, e.g. "1.1.1.1" → "Cloudflare".
    public static func publicResolverName(_ server: String) -> String? {
        let s = server.lowercased()
        switch s {
        case "1.1.1.1", "1.0.0.1", "1.1.1.2", "1.0.0.2", "1.1.1.3", "1.0.0.3":
            return "Cloudflare"
        case "8.8.8.8", "8.8.4.4": return "Google"
        case "9.9.9.9", "149.112.112.112", "9.9.9.10", "9.9.9.11": return "Quad9"
        case "208.67.222.222", "208.67.220.220": return "OpenDNS"
        case "94.140.14.14", "94.140.15.15": return "AdGuard"
        default: break
        }
        if s.hasPrefix("2606:4700:4700::") { return "Cloudflare" }
        if s.hasPrefix("2001:4860:4860::") { return "Google" }
        if s.hasPrefix("2620:fe::") { return "Quad9" }
        return nil
    }
}

public enum DNSConfig {
    public static func current() -> DNSConfiguration {
        guard let dict = SystemNetworkStore.value(forKey: SystemNetworkStore.GlobalKey.dns) else {
            return DNSConfiguration()
        }
        return parse(dict)
    }

    /// Pure parsing of the dynamic-store dictionary.
    public static func parse(_ dict: [String: Any]) -> DNSConfiguration {
        let servers = (dict["ServerAddresses"] as? [String] ?? []).map { $0.trimmingCharacters(in: .whitespaces) }
        let search = dict["SearchDomains"] as? [String] ?? []
        var seen = Set<String>()
        return DNSConfiguration(
            servers: servers.filter { !$0.isEmpty && seen.insert($0).inserted },
            searchDomains: search.filter { !$0.isEmpty },
            domainName: (dict["DomainName"] as? String).trimmedNonEmpty)
    }
}
