import Foundation
import Synchronization

/// Grabs banners from a device's open ports (web page title/server/product markers, SSH greeting)
/// and turns them into a `DevicePatch`. Network I/O only; interpretation lives in `BannerParser`.
public enum ServiceBanners {
    static let httpPorts: [UInt16] = [
        80, 8000, 8080, 8081, 8123, 5000, 8096, 32400, 8888, 81, 3000, 8880, 10000, 7000,
        9000, 8090, 8889, 9080,
    ]
    static let httpsPorts: [UInt16] = [443, 8443, 9443, 5001, 8920, 8843]
    private static let sshPorts: [UInt16] = [22, 2222]
    private static let maxWebPorts = 6
    static let bodyCap = 64 * 1024

    /// Probes the given open ports and returns what they reveal, or nil if nothing useful.
    public static func probe(
        _ ip: IPv4Address, openPorts: [UInt16],
        timeout: Duration = .seconds(2)
    ) async -> DevicePatch? {
        let open = Set(openPorts)
        // Ordered by usefulness: the standard ports first.
        var web: [URL] = []
        for port in [80, 443] + (httpPorts + httpsPorts).filter({ $0 != 80 && $0 != 443 }) where open.contains(port) {
            let https = httpsPorts.contains(port)
            let defaultPort = (https && port == 443) || (!https && port == 80)
            let s = "\(https ? "https" : "http")://\(ip)\(defaultPort ? "" : ":\(port)")/"
            if let url = URL(string: s) { web.append(url) }
            if web.count >= maxWebPorts { break }
        }
        let ssh = sshPorts.first { open.contains($0) }
        let urls = web
        let sshIndex = urls.count
        guard !web.isEmpty || ssh != nil else { return nil }

        let results = await withTaskGroup(of: (Int, BannerHints).self) { group in
            for (i, url) in urls.enumerated() {
                group.addTask { (i, await webHints(url, timeout: timeout)) }
            }
            // One favicon (from the first web port) for the hash table.
            if let first = urls.first, let icon = URL(string: "/favicon.ico", relativeTo: first)?.absoluteURL {
                group.addTask {
                    guard let data = await fetchData(icon, timeout: timeout),
                        let product = FaviconFingerprint.identify(data)
                    else { return (sshIndex + 1, BannerHints()) }
                    return (
                        sshIndex + 1,
                        BannerHints(
                            manufacturer: product.manufacturer, kind: product.kind,
                            product: product.name)
                    )
                }
            }
            if let ssh {
                group.addTask {
                    let data = await LANIO.readGreeting(ip, port: ssh, timeout: timeout)
                    let line = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
                    return (sshIndex, BannerParser.parseSSH(line))
                }
            }
            var out: [(Int, BannerHints)] = []
            for await r in group { out.append(r) }
            return out
        }
        let combined = combine(results.sorted { $0.0 < $1.0 }.map(\.1))
        guard !combined.isEmpty else { return nil }
        var patch = DevicePatch(ip: ip)
        patch.webTitle = combined.webTitle
        patch.osHint = combined.osHint
        patch.manufacturer = combined.manufacturer
        patch.model = combined.model
        patch.kind = combined.kind
        return patch
    }

    /// Folds per-port hints into one, richest first; ties keep port order.
    static func combine(_ hints: [BannerHints]) -> BannerHints {
        let ranked = hints.enumerated().sorted {
            $0.element.score != $1.element.score ? $0.element.score > $1.element.score : $0.offset < $1.offset
        }
        var out = BannerHints()
        for (_, h) in ranked { out.fill(from: h) }
        return out
    }

    // MARK: HTTP

    private static func webHints(_ url: URL, timeout: Duration) async -> BannerHints {
        guard var page = await fetch(url, timeout: timeout) else { return BannerHints() }
        var hints = BannerParser.parseHTML(title: nil, server: page.server, body: page.body)
        // Single-page apps sometimes bounce via <meta http-equiv="refresh">; follow one hop on the same host.
        if hints.webTitle == nil, hints.product == nil, let target = BannerParser.metaRefreshTarget(page.body),
            let next = URL(string: target, relativeTo: page.url)?.absoluteURL, next.host == url.host,
            let p2 = await fetch(next, timeout: timeout)
        {
            page = p2
            hints = BannerParser.parseHTML(title: nil, server: p2.server ?? page.server, body: p2.body)
        }
        // Zyxel's web UI is an SPA, but it serves the model unauthenticated.
        if hints.manufacturer == "Zyxel", hints.model == nil,
            let infoURL = URL(string: "/getBasicInformation", relativeTo: url)?.absoluteURL,
            let info = await fetch(infoURL, timeout: timeout),
            let model = BannerParser.parseZyxelBasicInfo(Data(info.body.utf8))
        {
            hints.model = model
        }
        return hints
    }

    struct Page: Sendable {
        var url: URL
        var status: Int
        var server: String?
        var body: String
    }

    static let browserUserAgent = "Mozilla/5.0 (Macintosh) Lanternfish/0.1"
    static let acceptHeader = "text/html,application/xhtml+xml,*/*;q=0.8"

    /// Raw body of a 200 response (at most `cap` bytes) via `LANSession` (private-only redirects).
    static func fetchData(
        _ url: URL, timeout: Duration, cap: Int = bodyCap,
        userAgent: String = browserUserAgent
    ) async -> Data? {
        guard let (page, data) = await fetchRaw(url, timeout: timeout, cap: cap, userAgent: userAgent),
            page.status == 200
        else { return nil }
        return data
    }

    static func fetch(_ url: URL, timeout: Duration) async -> Page? {
        await fetchRaw(url, timeout: timeout)?.0
    }

    private static func fetchRaw(
        _ url: URL, timeout: Duration, cap: Int = bodyCap,
        userAgent: String = browserUserAgent
    ) async -> (Page, Data)? {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout.seconds)
        request.setValue(acceptHeader, forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        do {
            let (bytes, response) = try await LANSession.shared.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { return nil }
            var data = Data()
            data.reserveCapacity(8192)
            let deadline = ContinuousClock.now + timeout
            for try await b in bytes {
                data.append(b)
                if data.count >= cap || ContinuousClock.now > deadline { break }
            }
            bytes.task.cancel()
            return (
                Page(
                    url: http.url ?? url, status: http.statusCode,
                    server: http.value(forHTTPHeaderField: "Server"),
                    body: String(decoding: data, as: UTF8.self)), data
            )
        } catch {
            return nil
        }
    }
}

// MARK: - Session

enum LANSession {
    /// Ephemeral, cookie-less, cache-less session for LAN banner grabs.
    static let shared: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2
        config.timeoutIntervalForResource = 4
        config.httpMaximumConnectionsPerHost = 2
        config.waitsForConnectivity = false
        config.httpCookieStorage = nil
        config.urlCache = nil
        return URLSession(configuration: config, delegate: LANTrustDelegate(), delegateQueue: nil)
    }()
}

/// Trusts self-signed certificates for private-range IPv4 hosts only, never answers auth prompts,
/// and follows at most 3 redirects that stay on the host that was asked.
final class LANTrustDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    private static let maxRedirects = 3
    /// Redirects followed so far, per task.
    private let redirects = Mutex<[Int: Int]>([:])

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        let n = redirects.withLock { r -> Int in
            let count = r[task.taskIdentifier, default: 0] + 1
            r[task.taskIdentifier] = count
            return count
        }
        guard n <= Self.maxRedirects, let host = request.url?.host, Self.isPrivateIPv4(host),
            host == task.originalRequest?.url?.host
        else { return nil }
        return request
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        _ = redirects.withLock { $0.removeValue(forKey: task.taskIdentifier) }
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge
    ) async
        -> (URLSession.AuthChallengeDisposition, URLCredential?)
    {
        let space = challenge.protectionSpace
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust else {
            return (.rejectProtectionSpace, nil)
        }
        guard Self.isPrivateIPv4(space.host), let trust = space.serverTrust else {
            return (.performDefaultHandling, nil)
        }
        return (.useCredential, URLCredential(trust: trust))
    }

    /// 10/8, 172.16/12, 192.168/16, 169.254/16 IPv4 literals.
    static func isPrivateIPv4(_ host: String) -> Bool {
        guard let ip = IPv4Address(host) else { return false }
        let v = ip.value
        return v >> 24 == 10 || v >> 20 == 0xAC1 || v >> 16 == 0xC0A8 || v >> 16 == 0xA9FE
    }
}
