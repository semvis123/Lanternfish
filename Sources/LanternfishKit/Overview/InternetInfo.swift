import Foundation

/// What Cloudflare sees of this connection: public addresses, ISP and approximate location.
public struct InternetInfo: Sendable, Hashable {
    public var ipv4: String?
    public var ipv6: String?
    public var asn: Int?
    /// ISP / organization owning the ASN. Only `/meta` provides it.
    public var organization: String?
    public var city: String?
    public var region: String?
    /// ISO 3166 alpha-2 country code, e.g. "NL".
    public var country: String?
    /// Cloudflare data center (IATA code), e.g. "AMS".
    public var colo: String?
    public var timezone: String?

    public init(
        ipv4: String? = nil, ipv6: String? = nil, asn: Int? = nil, organization: String? = nil,
        city: String? = nil, region: String? = nil, country: String? = nil, colo: String? = nil,
        timezone: String? = nil
    ) {
        self.ipv4 = ipv4
        self.ipv6 = ipv6
        self.asn = asn
        self.organization = organization
        self.city = city
        self.region = region
        self.country = country
        self.colo = colo
        self.timezone = timezone
    }

    /// Assigns the client IP to the v4 or v6 slot, depending on its form.
    fileprivate mutating func setClientIP(_ ip: String?) {
        guard let ip = ip?.trimmingCharacters(in: .whitespaces), !ip.isEmpty else { return }
        if ip.contains(":") { ipv6 = ipv6 ?? ip } else { ipv4 = ipv4 ?? ip }
    }

    /// Fills fields that are nil here from `other`.
    fileprivate mutating func fillMissing(from other: InternetInfo) {
        ipv4 = ipv4 ?? other.ipv4
        ipv6 = ipv6 ?? other.ipv6
        asn = asn ?? other.asn
        organization = organization ?? other.organization
        city = city ?? other.city
        region = region ?? other.region
        country = country ?? other.country
        colo = colo ?? other.colo
        timezone = timezone ?? other.timezone
    }
}

/// Fetches `InternetInfo` from Cloudflare only (speed.cloudflare.com and 1.1.1.1).
///
/// `/meta` is tried first (it carries the AS organization); it currently answers 403 to
/// non-browser clients, so the metadata headers Cloudflare attaches to `__down?bytes=0`
/// (ip, asn, city, country, colo…) are the fallback. Public IPv4 / IPv6 are read from
/// `/cdn-cgi/trace` on the 1.1.1.1 and 2606:4700:4700::1111 literals so each family is forced.
public enum InternetInfoService {
    public static let userAgent = "Lanternfish"

    private static let metaURL = URL(string: "https://speed.cloudflare.com/meta")!
    private static let headersURL = URL(string: "https://speed.cloudflare.com/__down?bytes=0")!
    private static let traceV4URL = URL(string: "https://1.1.1.1/cdn-cgi/trace")!
    private static let traceV6URL = URL(string: "https://[2606:4700:4700::1111]/cdn-cgi/trace")!

    /// Ephemeral session: no cookies, no cache, generic User-Agent.
    public static func makeSession(timeout: TimeInterval = 6) -> URLSession {
        let config = privateConfiguration()
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout * 2
        return URLSession(configuration: config)
    }

    /// An ephemeral configuration that keeps nothing between requests (no cache, no cookies) and
    /// identifies only as `userAgent`.
    static func privateConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.httpAdditionalHeaders = ["User-Agent": userAgent, "Accept": "*/*"]
        return config
    }

    /// Throws only when nothing at all could be learned (i.e. likely offline).
    public static func fetch() async throws -> InternetInfo {
        let session = makeSession()
        defer { session.finishTasksAndInvalidate() }

        async let meta = try? fetchMeta(session)
        async let headers = try? fetchHeaderMeta(session)
        async let v4 = try? fetchTrace(session, url: traceV4URL)
        async let v6 = try? fetchTrace(session, url: traceV6URL)

        var info = InternetInfo()
        let (m, h, t4, t6) = await (meta, headers, v4, v6)
        if let ip = t4?["ip"], !ip.contains(":") { info.ipv4 = ip }
        if let ip = t6?["ip"], ip.contains(":") { info.ipv6 = ip }
        if let m { info.fillMissing(from: m) }
        if let h { info.fillMissing(from: h) }
        if info.colo == nil { info.colo = t4?["colo"] ?? t6?["colo"] }
        if info.country == nil { info.country = t4?["loc"] ?? t6?["loc"] }
        if m == nil, h == nil, t4 == nil, t6 == nil { throw URLError(.notConnectedToInternet) }
        return info
    }

    private static func fetchMeta(_ session: URLSession) async throws -> InternetInfo {
        let (data, response) = try await session.data(from: metaURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try parseMeta(data)
    }

    private static func fetchHeaderMeta(_ session: URLSession) async throws -> InternetInfo {
        let (_, response) = try await session.data(from: headersURL)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        var headers: [String: String] = [:]
        for (k, v) in http.allHeaderFields {
            if let k = k as? String, let v = v as? String { headers[k] = v }
        }
        let info = parseHeaders(headers)
        guard info.ipv4 != nil || info.ipv6 != nil || info.asn != nil else { throw URLError(.cannotParseResponse) }
        return info
    }

    private static func fetchTrace(_ session: URLSession, url: URL) async throws -> [String: String] {
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return parseTrace(String(decoding: data, as: UTF8.self))
    }

    // MARK: - Parsing (pure)

    private struct Meta: Decodable {
        var clientIp: String?
        var asn: FlexibleInt?
        var asOrganization: String?
        var city: String?
        var region: String?
        var country: String?
        var colo: String?
        var timezone: String?
    }

    /// Accepts a number or a numeric string.
    private struct FlexibleInt: Decodable {
        let value: Int?
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let i = try? c.decode(Int.self) {
                value = i
            } else if let s = try? c.decode(String.self) {
                value = Int(s.trimmingCharacters(in: .whitespaces))
            } else {
                value = nil
            }
        }
    }

    /// Decodes the `speed.cloudflare.com/meta` JSON. Throws if it's not JSON or carries no IP.
    public static func parseMeta(_ data: Data) throws -> InternetInfo {
        let m = try JSONDecoder().decode(Meta.self, from: data)
        guard m.clientIp?.isEmpty == false else { throw URLError(.cannotParseResponse) }
        var info = InternetInfo(
            asn: m.asn?.value, organization: m.asOrganization.trimmedNonEmpty,
            city: m.city.trimmedNonEmpty, region: m.region.trimmedNonEmpty, country: m.country.trimmedNonEmpty,
            colo: m.colo.trimmedNonEmpty, timezone: m.timezone.trimmedNonEmpty)
        info.setClientIP(m.clientIp)
        return info
    }

    /// Reads the metadata headers of a `__down` response. Header names are case-insensitive.
    public static func parseHeaders(_ headers: [String: String]) -> InternetInfo {
        var lower: [String: String] = [:]
        for (k, v) in headers { lower[k.lowercased()] = v.trimmingCharacters(in: .whitespaces) }
        func get(_ names: String...) -> String? {
            for n in names { if let v = lower[n], !v.isEmpty { return v } }
            return nil
        }
        var info = InternetInfo(
            asn: get("cf-meta-asn", "asn").flatMap { Int($0) },
            city: get("cf-meta-city", "city"),
            region: get("cf-meta-region", "region"),
            country: get("cf-meta-country", "country"),
            colo: get("cf-meta-colo", "colo"),
            timezone: get("cf-meta-timezone", "timezone"))
        info.setClientIP(get("cf-meta-ip"))
        return info
    }

    /// Parses `key=value` lines of `/cdn-cgi/trace`.
    public static func parseTrace(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { out[key] = value }
        }
        return out
    }
}

// MARK: - Latency to 1.1.1.1

public enum InternetLatency {
    public static let target = IPv4Address("1.1.1.1")!

    /// Sends `count` ICMP echoes to 1.1.1.1. Returns one entry per echo (nil = timeout).
    public static func measure(
        count: Int = 4, interval: Duration = .milliseconds(250),
        timeout: Duration = .seconds(1)
    ) async -> [Duration?] {
        var out: [Duration?] = []
        for await r in Pinger(interval: interval, timeout: timeout).ping(target) {
            out.append(r.rtt)
            if out.count >= count { break }
        }
        return out
    }
}

extension Optional where Wrapped == String {
    /// The string trimmed of spaces and tabs, or nil when that leaves nothing.
    var trimmedNonEmpty: String? {
        guard let s = self?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        return s
    }
}
