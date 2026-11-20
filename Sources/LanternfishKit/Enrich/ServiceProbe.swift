import Foundation
import Network
import Security
import Synchronization

/// Deep inspection of a single open TCP port, for the Service Details sheet: connect time, the
/// unprompted banner, HTTP(S) response headers with redirects, the TLS certificate chain, and SSH
/// host keys. Read-only: one GET per HTTP hop, an `ssh-keyscan` for SSH, nothing else.
public enum ServiceProbe {
    private static let bannerWindow: Duration = .milliseconds(800)
    static let bannerCap = 4096
    private static let httpBodyCap = 256 * 1024
    static let connectTimeout: Duration = .seconds(3)
    private static let httpTimeout: Duration = .seconds(5)
    private static let firstByteTimeout: Duration = .seconds(3)
    private static let maxRedirects = 5

    /// Ports where TLS is tried before plain HTTP.
    static let tlsFirstPorts: Set<UInt16> = [
        443, 8443, 9443, 4443, 10443, 5001, 8920, 8843, 7443, 2083, 2087,
        8006, 465, 636, 853, 990, 992, 993, 995, 5986, 6697, 8531, 9090,
    ]

    public static func inspect(_ ip: IPv4Address, port: UInt16) async -> ServiceReport {
        let started = ContinuousClock.now
        var report = ServiceReport(ip: ip, port: port)
        await run(&report)
        report.duration = ContinuousClock.now - started
        return report
    }

    private static func run(_ report: inout ServiceReport) async {
        let ip = report.ip
        let port = report.port

        // 1. Plain TCP: connect time + unprompted banner.
        let plain = ProbeConnection(ip: ip, port: port, tls: nil)
        switch await plain.open(timeout: connectTimeout) {
        case .failure(let message):
            plain.cancel()
            report.connectError = message
            return
        case .success(let elapsed):
            report.connectTime = elapsed
        }
        let (banner, truncated) = await plain.readAvailable(window: bannerWindow, cap: bannerCap)
        plain.cancel()
        if !banner.isEmpty {
            report.banner = banner
            report.bannerTruncated = truncated
        }
        report.detectedProtocol = detectProtocol(banner: report.banner, port: port)
        if Task.isCancelled { return }

        // 2. Talkative services: SSH gets host keys; others just the banner.
        if report.detectedProtocol == .ssh {
            await inspectSSH(&report, banner: banner)
            return
        }
        if report.banner != nil { return }

        // 3. Silent services: HTTP and/or TLS.
        guard let httpURL = URL(string: "http://\(ip)\(port == 80 ? "" : ":\(port)")/"),
            let httpsURL = URL(string: "https://\(ip)\(port == 443 ? "" : ":\(port)")/")
        else { return }
        var http: HTTPInfo?
        var tlsResult: TLSAttempt?

        if tlsFirstPorts.contains(port) {
            tlsResult = await tryTLS(ip: ip, port: port, url: httpsURL, now: report.date)
            if tlsResult?.tls == nil {
                http = await fetchChain(start: httpURL, ip: ip)
            }
        } else {
            http = await fetchChain(start: httpURL, ip: ip)
            let first = http?.responses.first
            let hintsTLS = first.map { $0.statusCode == 400 || $0.statusCode == 497 } ?? false
            // 400/497 on a silent port is often "plain HTTP sent to an HTTPS port".
            if http == nil || hintsTLS {
                let attempt = await tryTLS(ip: ip, port: port, url: httpsURL, now: report.date)
                if attempt.tls != nil {
                    tlsResult = attempt
                    if attempt.http != nil { http = nil }  // the TLS side is the real service
                } else if http == nil {
                    tlsResult = attempt
                }
            }
        }

        if let t = tlsResult {
            report.tls = t.tls
            report.tlsError = t.tls == nil ? t.error : nil
            if let h = t.http {
                http = await followRedirects(from: h, ip: ip)
            } else if t.tls != nil, !t.otherData.isEmpty {
                // TLS-wrapped greeting (IMAPS, POP3S, …).
                report.banner = t.otherData.prefix(bannerCap)
                report.bannerTruncated = t.otherData.count > bannerCap
            }
        }
        if let http {
            report.http = http
        } else {
            report.httpError = "No HTTP response"
        }

        switch (report.tls != nil, report.http != nil) {
        case (true, true): report.detectedProtocol = .https
        case (false, true):
            report.detectedProtocol = .http
            // "400 The plain HTTP request was sent to HTTPS port" (nginx) and similar.
            let first = report.http?.responses.first
            let text = ((first?.title ?? "") + " " + (first?.statusLine ?? "")).lowercased()
            if let first, [400, 497].contains(first.statusCode),
                text.contains("https") || text.contains("ssl") || text.contains("tls")
            {
                report.detectedProtocol = .https
                if let e = report.tlsError {
                    report.tlsError =
                        e + ". The server answers plain HTTP with an HTTPS error, so it most likely "
                        + "needs a host name (SNI) to complete the handshake."
                }
            }
        case (true, false):
            let inner = detectProtocol(banner: report.banner, port: port)
            report.detectedProtocol = inner == .unknown ? .tls : inner
        case (false, false): report.detectedProtocol = .unknown
        }
        // Errors only matter when they explain a missing section.
        if report.http != nil, report.detectedProtocol == .http, !tlsFirstPorts.contains(port) { report.tlsError = nil }
        if report.tls != nil, report.http == nil { report.httpError = nil }
    }

    // MARK: SSH

    private static func inspectSSH(_ report: inout ServiceReport, banner: Data) async {
        let line = sshVersionLine(banner) ?? escapePrintable(banner.prefix(255))
        var ssh = SSHInfo(versionLine: line)
        let (out, err) = await Keyscan.run(ip: report.ip, port: report.port)
        ssh.hostKeys = parseKeyscan(out)
        if ssh.hostKeys.isEmpty {
            report.sshError = err ?? "ssh-keyscan returned no host keys"
        }
        report.ssh = ssh
    }

    // MARK: TLS

    struct TLSAttempt: Sendable {
        var tls: TLSInfo?
        var error: String?
        var http: HTTPResponseInfo?
        /// Non-HTTP bytes received after the handshake.
        var otherData = Data()
    }

    /// TLS handshake (capturing the chain) and one GET over the same connection.
    private static func tryTLS(ip: IPv4Address, port: UInt16, url: URL, now: Date) async -> TLSAttempt {
        let capture = TLSCapture(now: now)
        let conn = ProbeConnection(ip: ip, port: port, tls: capture)
        defer { conn.cancel() }
        let handshake: Duration
        switch await conn.open(timeout: connectTimeout + .seconds(1)) {
        case .failure(let message):
            return TLSAttempt(error: message)
        case .success(let elapsed):
            handshake = elapsed
        }
        await capture.evaluateTrust()
        var info = capture.result
        info.handshakeTime = handshake
        if let (version, suite) = conn.tlsParameters() {
            info.protocolVersion = tlsVersionName(version)
            info.cipherSuite = cipherSuiteName(suite)
        }
        var attempt = TLSAttempt(tls: info)
        let (response, raw) = await get(conn, url: url)
        attempt.http = response
        if response == nil { attempt.otherData = raw }
        return attempt
    }

    // MARK: HTTP

    /// Fetches `start` and follows redirects.
    private static func fetchChain(start: URL, ip: IPv4Address) async -> HTTPInfo? {
        guard let first = await fetchOnce(start, ip: ip) else { return nil }
        return await followRedirects(from: first, ip: ip)
    }

    private static func followRedirects(from first: HTTPResponseInfo, ip: IPv4Address) async -> HTTPInfo {
        var info = HTTPInfo(responses: [first])
        var visited: Set<String> = [first.url.absoluteString]
        while let last = info.responses.last, last.isRedirect, let location = last.header("Location") {
            guard let next = redirectTarget(location, from: last.url) else {
                info.unfollowedRedirect = location
                break
            }
            guard info.responses.count <= maxRedirects, !visited.contains(next.absoluteString),
                // Only the probed device itself: a redirect must not make us request other LAN hosts.
                next.host == ip.description,
                next.scheme == "http" || next.scheme == "https",
                let response = await fetchOnce(next, ip: ip)
            else {
                info.unfollowedRedirect = next.absoluteString
                break
            }
            visited.insert(next.absoluteString)
            info.responses.append(response)
        }
        return info
    }

    /// The URL's TCP port (default 80/443). A Location header can carry any number as the port, so
    /// anything outside 0...65535 is nil (unfollowable) rather than a trap.
    static func port(of url: URL) -> UInt16? {
        UInt16(exactly: url.port ?? (url.scheme == "https" ? 443 : 80))
    }

    /// One GET on a fresh connection to the URL's host (an IPv4 literal).
    private static func fetchOnce(_ url: URL, ip: IPv4Address) async -> HTTPResponseInfo? {
        guard let host = url.host.flatMap(IPv4Address.init) else { return nil }
        let https = url.scheme == "https"
        guard let port = port(of: url) else { return nil }
        let conn = ProbeConnection(ip: host, port: port, tls: https ? TLSCapture(now: Date()) : nil)
        defer { conn.cancel() }
        guard case .success = await conn.open(timeout: connectTimeout) else { return nil }
        return await get(conn, url: url).0
    }

    /// The raw GET request for `url`, or nil when the URL can't be sent verbatim. Uses the
    /// percent-encoded path/query (so `%0D%0A` stays escaped and a trailing slash is kept) and
    /// refuses anything with whitespace or control characters in the request line or Host.
    static func requestHead(for url: URL) -> String? {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: true),
            let host = comps.percentEncodedHost, !host.isEmpty
        else { return nil }
        var target = comps.percentEncodedPath.isEmpty ? "/" : comps.percentEncodedPath
        if let q = comps.percentEncodedQuery { target += "?" + q }
        let hostHeader = comps.port.map { "\(host):\($0)" } ?? host
        let unsafe = { (s: String) in s.unicodeScalars.contains { $0.value <= 0x20 || $0.value == 0x7F } }
        guard target.hasPrefix("/"), !unsafe(target), !unsafe(hostHeader) else { return nil }
        return "GET \(target) HTTP/1.1\r\nHost: \(hostHeader)\r\n"
            + "User-Agent: \(ServiceBanners.browserUserAgent)\r\n"
            + "Accept: \(ServiceBanners.acceptHeader)\r\nAccept-Encoding: identity\r\n"
            + "Connection: close\r\n\r\n"
    }

    /// Sends a GET and reads the response until it's complete, the cap, or the timeout.
    private static func get(_ conn: ProbeConnection, url: URL) async -> (HTTPResponseInfo?, Data) {
        guard let request = requestHead(for: url), await conn.send(Data(request.utf8)) else { return (nil, Data()) }

        var data = Data()
        let deadline = ContinuousClock.now + httpTimeout
        var parsed: ParsedHTTPResponse?
        while data.count < httpBodyCap + 16 * 1024 {
            var remaining = deadline - ContinuousClock.now
            // Silent non-HTTP services: don't wait the full timeout for a first byte.
            if data.isEmpty { remaining = min(remaining, firstByteTimeout) }
            guard remaining > .zero else { break }
            let r = await conn.receive(max: 64 * 1024, timeout: remaining)
            if let d = r.data { data.append(d) }
            if data.count >= 5, !data.starts(with: Array("HTTP/".utf8)) { break }
            parsed = parseHTTPResponse(data)
            if parsed?.isComplete == true || r.isComplete || r.error || r.timedOut { break }
        }
        guard let parsed = parsed ?? parseHTTPResponse(data) else { return (nil, data) }
        let body = parsed.body.prefix(httpBodyCap)
        let type = parsed.header("Content-Type")?.lowercased() ?? ""
        var title: String?
        if type.isEmpty || type.contains("html") || type.contains("xml") {
            title = BannerParser.extractTitle(String(decoding: body.prefix(64 * 1024), as: UTF8.self))
        }
        let info = HTTPResponseInfo(
            url: url, statusLine: parsed.statusLine, statusCode: parsed.statusCode, headers: parsed.headers,
            bodySize: body.count, bodyTruncated: !parsed.isComplete && parsed.body.count >= httpBodyCap,
            title: title)
        return (info, data)
    }
}

// MARK: - TLS capture

/// Accepts any certificate during the handshake (we're inspecting, not trusting) while recording
/// the chain. Whether the system would have trusted it is evaluated afterwards (`evaluateTrust`),
/// asynchronously, so revocation/AIA fetches never block the handshake's verify queue.
final class TLSCapture: Sendable {
    private struct State: @unchecked Sendable {  // SecTrust is a CF object; only touched under the lock / on evalQueue
        var certificates: [CertificateInfo] = []
        var trusted = false
        var trustError: String?
        var trust: SecTrust?
    }

    private let state = Mutex(State())
    private static let evalQueue = DispatchQueue(label: "LanternfishKit.ServiceProbe.trust")
    let now: Date

    init(now: Date) { self.now = now }

    var result: TLSInfo {
        state.withLock { TLSInfo(certificates: $0.certificates, trusted: $0.trusted, trustError: $0.trustError) }
    }

    /// Records the presented chain (cheap: DER parsing only).
    func record(_ trust: SecTrust) {
        let chain = (SecTrustCopyCertificateChain(trust) as? [SecCertificate]) ?? []
        let certs = chain.map { X509.info(der: SecCertificateCopyData($0) as Data, certificate: $0, now: now) }
        state.withLock {
            $0.certificates = certs
            $0.trust = trust
        }
    }

    /// Asks the system whether it would trust the recorded chain (bounded by `timeout`).
    func evaluateTrust(timeout: Duration = .seconds(5)) async {
        guard let trust = state.withLock({ $0.trust }) else { return }
        nonisolated(unsafe) let unsafeTrust = trust
        let shot = OneShot<Bool>()
        _ = await shot.wait(timeout: timeout, timeoutValue: false, cancelValue: false) {
            Self.evalQueue.async {
                // Must be called on the queue the callback is delivered on.
                SecTrustEvaluateAsyncWithError(unsafeTrust, Self.evalQueue) { _, ok, error in
                    let message = error.map { CFErrorCopyDescription($0) as String }
                    self.state.withLock {
                        $0.trusted = ok
                        $0.trustError = ok ? nil : message
                    }
                    shot.finish(ok)
                }
            }
        }
        state.withLock { if !$0.trusted, $0.trustError == nil { $0.trustError = "Trust evaluation timed out" } }
    }

    func apply(to options: NWProtocolTLS.Options, queue: DispatchQueue) {
        let sec = options.securityProtocolOptions
        // Accept legacy TLS 1.0 so old routers can still be inspected (raw value avoids the deprecation warning).
        sec_protocol_options_set_min_tls_protocol_version(sec, tls_protocol_version_t(rawValue: 0x0301)!)
        sec_protocol_options_set_verify_block(
            sec,
            { [self] _, trust, complete in
                record(sec_trust_copy_ref(trust).takeRetainedValue())
                complete(true)
            }, queue)
    }
}

// MARK: - Connection

/// An `NWConnection` with async open/send/receive, each bounded by a timeout.
final class ProbeConnection: @unchecked Sendable {
    enum OpenResult: Sendable {
        case success(Duration)
        case failure(String)
    }

    struct Received: Sendable {
        var data: Data?
        var isComplete = false
        var error = false
        var timedOut = false
    }

    private static let queue = DispatchQueue(label: "LanternfishKit.ServiceProbe", attributes: .concurrent)
    private let connection: NWConnection?
    private let invalid: String?

    init(ip: IPv4Address, port: UInt16, tls capture: TLSCapture?) {
        guard let nwPort = NWEndpoint.Port(rawValue: port), let host = ip.nwAddress else {
            connection = nil
            invalid = "Invalid address"
            return
        }
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = Int(ServiceProbe.connectTimeout.components.seconds)
        let params: NWParameters
        if let capture {
            let tls = NWProtocolTLS.Options()
            capture.apply(to: tls, queue: Self.queue)
            params = NWParameters(tls: tls, tcp: tcp)
        } else {
            params = NWParameters(tls: nil, tcp: tcp)
        }
        connection = NWConnection(host: .ipv4(host), port: nwPort, using: params)
        invalid = nil
    }

    func open(timeout: Duration) async -> OpenResult {
        guard let connection else { return .failure(invalid ?? "Invalid address") }
        let start = ContinuousClock.now
        let shot = OneShot<String?>()
        let error: String? = await shot.wait(timeout: timeout, timeoutValue: "Timed out", cancelValue: "Cancelled") {
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: shot.finish(nil)
                case .failed(let e): shot.finish(Self.describe(e))
                case .waiting(let e): shot.finish(Self.describe(e))
                case .cancelled: shot.finish("Cancelled")
                default: break
                }
            }
            connection.start(queue: Self.queue)
        }
        if let error { return .failure(error) }
        return .success(ContinuousClock.now - start)
    }

    func send(_ data: Data) async -> Bool {
        guard let connection else { return false }
        let shot = OneShot<Bool>()
        return await shot.wait(timeout: .seconds(3), timeoutValue: false, cancelValue: false) {
            connection.send(content: data, completion: .contentProcessed { shot.finish($0 == nil) })
        }
    }

    func receive(max: Int, timeout: Duration) async -> Received {
        guard let connection else { return Received(error: true) }
        let shot = OneShot<Received>()
        return await shot.wait(
            timeout: timeout, timeoutValue: Received(timedOut: true),
            cancelValue: Received(error: true)
        ) {
            connection.receive(minimumIncompleteLength: 1, maximumLength: max) { data, _, complete, error in
                shot.finish(Received(data: data, isComplete: complete, error: error != nil))
            }
        }
    }

    /// Everything the peer sends within `window`, up to `cap` bytes.
    func readAvailable(window: Duration, cap: Int) async -> (Data, truncated: Bool) {
        var data = Data()
        let deadline = ContinuousClock.now + window
        while data.count < cap {
            let remaining = deadline - ContinuousClock.now
            guard remaining > .zero else { break }
            let r = await receive(max: cap - data.count + 1, timeout: remaining)
            if let d = r.data { data.append(d) }
            if r.isComplete || r.error || r.timedOut { break }
        }
        let truncated = data.count > cap
        return (data.prefix(cap), truncated)
    }

    /// Negotiated (version, cipher suite) raw values once a TLS connection is ready.
    func tlsParameters() -> (UInt16, UInt16)? {
        guard let meta = connection?.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata
        else { return nil }
        let sec = meta.securityProtocolMetadata
        return (
            sec_protocol_metadata_get_negotiated_tls_protocol_version(sec).rawValue,
            sec_protocol_metadata_get_negotiated_tls_ciphersuite(sec).rawValue
        )
    }

    func cancel() {
        connection?.stateUpdateHandler = nil
        connection?.cancel()
    }

    static func describe(_ error: NWError) -> String {
        switch error {
        case .posix(let code):
            return String(cString: strerror(code.rawValue))
        case .tls(let status):
            let msg = SecCopyErrorMessageString(status, nil) as String?
            return "TLS: " + (msg ?? "error \(status)")
        case .dns(let code):
            return "DNS error \(code)"
        default:
            return error.localizedDescription
        }
    }
}

/// A continuation that is resumed exactly once: by the operation, a timeout, or cancellation.
final class OneShot<T: Sendable>: Sendable {
    private struct State: Sendable {
        var continuation: CheckedContinuation<T, Never>?
        var result: T?
    }

    private let state = Mutex(State())

    func finish(_ value: T) {
        let c = state.withLock { s -> CheckedContinuation<T, Never>? in
            guard s.result == nil else { return nil }
            s.result = value
            defer { s.continuation = nil }
            return s.continuation
        }
        c?.resume(returning: value)
    }

    func wait(timeout: Duration, timeoutValue: T, cancelValue: T, start: () -> Void) async -> T {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<T, Never>) in
                let early = state.withLock { s -> T? in
                    if let r = s.result { return r }
                    s.continuation = c
                    return nil
                }
                if let early {
                    c.resume(returning: early)
                    return
                }
                start()
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout.dispatchInterval) {
                    self.finish(timeoutValue)
                }
            }
        } onCancel: {
            finish(cancelValue)
        }
    }
}

// MARK: - ssh-keyscan

enum Keyscan {
    /// How a child process ended.
    enum Outcome: Sendable, Equatable {
        case exited(Int32)
        case timedOut
        case cancelled
        case launchFailed
    }

    /// Runs `/usr/bin/ssh-keyscan` and returns (stdout, error message if it failed).
    static func run(ip: IPv4Address, port: UInt16, timeout: Duration = .seconds(15)) async -> (String, String?) {
        #if os(macOS)
            let (outcome, out, err) = await capture(
                executable: URL(fileURLWithPath: "/usr/bin/ssh-keyscan"),
                arguments: ["-T", "3", "-p", String(port), ip.description], timeout: timeout)
            let stdout = String(decoding: out, as: UTF8.self)
            switch outcome {
            case .timedOut: return (stdout, "ssh-keyscan timed out")
            case .cancelled: return (stdout, "Cancelled")
            case .launchFailed: return (stdout, "Couldn't run ssh-keyscan")
            case .exited:
                let message = String(decoding: err, as: UTF8.self).split(whereSeparator: \.isNewline)
                    .map(String.init).filter { !$0.hasPrefix("#") }.last
                return (stdout, message)
            }
        #else
            return ("", "Reading SSH host keys isn't available on this platform")
        #endif
    }

    #if os(macOS)
        /// Runs a process with stdout/stderr drained concurrently on GCD threads (never the
        /// cooperative pool, and never stalling on a full 64 KB pipe), bounded by `timeout` and
        /// task cancellation (both terminate the child).
        static func capture(executable: URL, arguments: [String], timeout: Duration) async -> (Outcome, Data, Data) {
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            let out = Pipe()
            let err = Pipe()
            process.standardOutput = out
            process.standardError = err
            process.standardInput = FileHandle.nullDevice

            let shot = OneShot<Outcome>()
            process.terminationHandler = { shot.finish(.exited($0.terminationStatus)) }
            do { try process.run() } catch { return (.launchFailed, Data(), Data()) }

            async let stdout = drain(out.fileHandleForReading)
            async let stderr = drain(err.fileHandleForReading)
            let outcome = await shot.wait(timeout: timeout, timeoutValue: .timedOut, cancelValue: .cancelled) {}
            if case .exited = outcome {} else if process.isRunning { process.terminate() }
            // The pipes hit EOF once the child is gone.
            return (outcome, await stdout, await stderr)
        }

        private static func drain(_ handle: FileHandle) async -> Data {
            await withCheckedContinuation { c in
                DispatchQueue.global(qos: .utility).async {
                    c.resume(returning: (try? handle.readToEnd()) ?? Data())
                }
            }
        }
    #endif
}
