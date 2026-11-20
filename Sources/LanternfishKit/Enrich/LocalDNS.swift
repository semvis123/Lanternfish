import Darwin
import Dispatch
import Foundation

/// Where a local host name came from.
public enum LocalNameSource: String, Sendable, CaseIterable {
    /// PTR answered by the router's (or another in-subnet) DNS server, usually its DHCP lease names.
    case routerDNS = "router DNS"
    /// PTR answered over multicast DNS (the device itself, or a Bonjour sleep proxy).
    case mdns = "mDNS"
    /// PTR answered over LLMNR (Windows).
    case llmnr = "LLMNR"
}

/// A tiny DNS client for LAN host names. The system resolver often forwards PTR queries for
/// private addresses to a public resolver that knows nothing about the LAN, so this asks the
/// sources that do, directly and in one batch:
/// - the gateway (and any DNS server inside the subnet) on UDP 53 — most home routers answer
///   reverse lookups for their DHCP clients without any login;
/// - multicast DNS (224.0.0.251:5353, QU bit) plus unicast mDNS to each host;
/// - LLMNR (unicast to each host on UDP 5355), which Windows answers.
public enum LocalDNS {
    // MARK: Constants

    static let ptrType: UInt16 = 12
    static let cnameType: UInt16 = 5
    static let dnsPort: UInt16 = 53
    static let mdnsPort: UInt16 = 5353
    static let llmnrPort: UInt16 = 5355
    /// 224.0.0.251, the mDNS multicast group.
    static let mdnsGroup = IPv4Address(0xE000_00FB)
    /// Questions per multicast mDNS packet; keeps each query well under a typical MTU.
    static let mdnsQuestionsPerPacket = 16
    private static let reverseSuffix = ".in-addr.arpa"

    // MARK: Messages

    /// "4.3.2.1.in-addr.arpa" for 1.2.3.4.
    public static func reverseName(_ ip: IPv4Address) -> String {
        let v = ip.value
        return "\(v & 0xFF).\(v >> 8 & 0xFF).\(v >> 16 & 0xFF).\(v >> 24 & 0xFF)\(reverseSuffix)"
    }

    /// Inverse of `reverseName` (case-insensitive, trailing dot allowed).
    public static func ip(fromReverseName name: String) -> IPv4Address? {
        var n = name.lowercased()
        while n.hasSuffix(".") { n.removeLast() }
        guard n.hasSuffix(reverseSuffix) else { return nil }
        let octets = n.dropLast(reverseSuffix.count).split(separator: ".")
        guard octets.count == 4 else { return nil }
        return IPv4Address(octets.reversed().joined(separator: "."))
    }

    static func encodeName(_ name: String) -> [UInt8] {
        var out: [UInt8] = []
        for label in name.split(separator: ".") {
            let bytes = Array(label.utf8.prefix(63))
            out.append(UInt8(bytes.count))
            out += bytes
        }
        out.append(0)
        return out
    }

    /// A query with one question per name (mDNS packs several; DNS/LLMNR servers expect one).
    /// `type` defaults to PTR (12).
    /// `unicastResponse` sets the mDNS QU bit; `recursionDesired` is for ordinary DNS servers.
    public static func query(
        names: [String], type: UInt16 = 12, id: UInt16,
        unicastResponse: Bool = false, recursionDesired: Bool = false
    ) -> Data {
        var b: [UInt8] = [
            UInt8(id >> 8), UInt8(id & 0xFF), recursionDesired ? 0x01 : 0x00, 0x00,
            UInt8(names.count >> 8), UInt8(names.count & 0xFF), 0, 0, 0, 0, 0, 0,
        ]
        let qclass: UInt16 = (unicastResponse ? 0x8000 : 0) | 1
        for n in names {
            b += encodeName(n)
            b += [UInt8(type >> 8), UInt8(type & 0xFF), UInt8(qclass >> 8), UInt8(qclass & 0xFF)]
        }
        return Data(b)
    }

    /// PTR query for one address.
    public static func ptrQuery(
        _ ip: IPv4Address, id: UInt16, unicastResponse: Bool = false,
        recursionDesired: Bool = false
    ) -> Data {
        query(names: [reverseName(ip)], id: id, unicastResponse: unicastResponse, recursionDesired: recursionDesired)
    }

    public struct Record: Sendable, Equatable {
        public var name: String
        public var type: UInt16
        /// Target name for PTR/CNAME records.
        public var target: String?
    }

    /// Parses a response's answer and additional records. Nil for anything that isn't a well-formed response.
    public static func parseResponse(_ data: Data) -> (id: UInt16, records: [Record])? {
        let b = [UInt8](data)
        guard b.count >= 12, b[2] & 0x80 != 0 else { return nil }
        let id = UInt16(b[0]) << 8 | UInt16(b[1])
        let qd = Int(b[4]) << 8 | Int(b[5])
        let an = Int(b[6]) << 8 | Int(b[7])
        let ns = Int(b[8]) << 8 | Int(b[9])
        let ar = Int(b[10]) << 8 | Int(b[11])
        var i = 12
        for _ in 0..<qd {
            guard let (_, next) = readName(b, at: i), next + 4 <= b.count else { return nil }
            i = next + 4
        }
        var records: [Record] = []
        for n in 0..<(an + ns + ar) {
            guard let (name, next) = readName(b, at: i), next + 10 <= b.count else { break }
            let type = UInt16(b[next]) << 8 | UInt16(b[next + 1])
            let rdLength = Int(b[next + 8]) << 8 | Int(b[next + 9])
            let rdStart = next + 10
            guard rdStart + rdLength <= b.count else { break }
            // Authority records (SOA etc.) are skipped, answers and additionals kept.
            if n < an || n >= an + ns {
                var target: String?
                if type == ptrType || type == cnameType { target = readName(b, at: rdStart)?.0 }
                records.append(Record(name: name, type: type, target: target))
            }
            i = rdStart + rdLength
        }
        return (id, records)
    }

    /// Reads a (possibly compressed) name. Returns it without trailing dot and the offset after it.
    static func readName(_ b: [UInt8], at start: Int) -> (String, Int)? {
        var labels: [String] = []
        var i = start
        var end: Int?
        var jumps = 0
        while true {
            guard i < b.count else { return nil }
            let len = Int(b[i])
            if len == 0 {
                i += 1
                break
            }
            if len & 0xC0 == 0xC0 {
                guard i + 1 < b.count, jumps < 16 else { return nil }
                if end == nil { end = i + 2 }
                i = (len & 0x3F) << 8 | Int(b[i + 1])
                jumps += 1
                continue
            }
            guard len < 64, i + 1 + len <= b.count else { return nil }
            labels.append(String(decoding: b[(i + 1)...(i + len)], as: UTF8.self))
            i += 1 + len
        }
        return (labels.joined(separator: "."), end ?? i)
    }

    /// (address, host name) for every PTR record about an in-addr.arpa name.
    public static func ptrAnswers(_ data: Data) -> [(IPv4Address, String)] {
        guard let (_, records) = parseResponse(data) else { return [] }
        return records.compactMap { r in
            guard r.type == ptrType, let target = r.target, let ip = ip(fromReverseName: r.name) else { return nil }
            return (ip, target)
        }
    }

    // MARK: Name hygiene

    /// LAN-only domain suffixes routers append to DHCP names.
    static let lanSuffixes = [
        ".local", ".lan", ".home", ".home.arpa", ".localdomain", ".fritz.box", ".internal",
        ".router", ".gateway", ".domain", ".intranet", ".box", ".localnet", ".private",
        ".workgroup", ".speedport.ip", ".station", ".ziggo", ".kpn",
    ]
    /// Names that say nothing about the device.
    static let junkNames: Set<String> = [
        "localhost", "home", "lan", "local", "router", "gateway", "wlan0", "wlan1", "eth0", "eth1", "br0",
        "unknown", "none", "(none)", "android", "device", "client", "host", "dhcp", "espressif", "wifi", "default",
        "mylocalhost", "localhost.localdomain", "*",
    ]

    /// Returns a usable host name (trailing dot removed), or nil for junk: the router's own domain,
    /// public names like "www.routerlogin.com", "(none)", interface names, names made of the IP or MAC.
    public static func cleanHostname(_ raw: String, ip: IPv4Address) -> String? {
        var h = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while h.hasSuffix(".") { h.removeLast() }
        guard !h.isEmpty, h.count <= 80, !h.contains(" "), !h.lowercased().hasSuffix("in-addr.arpa") else { return nil }
        var bare = h.lowercased()
        for s in lanSuffixes where bare.hasSuffix(s) && bare.count > s.count {
            bare.removeLast(s.count)
            break
        }
        let first = bare.split(separator: ".").first.map(String.init) ?? bare
        if junkNames.contains(bare) || junkNames.contains(first) || first.hasPrefix("(none)") { return nil }
        // Still dotted after stripping a LAN suffix: a public name (vendor setup domains, ISP PTRs).
        if bare.contains(".") { return nil }
        // Made from the address: "10-0-0-5", "dhcp-10-0-0-5", "ip-10-0-0-5".
        let dashed = ip.description.replacingOccurrences(of: ".", with: "-")
        if bare.contains(dashed) || bare.contains(ip.description) { return nil }
        // MAC-only names.
        let hex = bare.filter { $0 != "-" && $0 != ":" }
        if hex.count == 12, hex.allSatisfy(\.isHexDigit) { return nil }
        return h
    }

    /// Picks the best name: mDNS ("Sams-iPad.local") over the router's DHCP name ("iPad") over LLMNR.
    public static func best(_ names: [LocalNameSource: String]) -> (name: String, source: LocalNameSource)? {
        for s in [LocalNameSource.mdns, .routerDNS, .llmnr] {
            if let n = names[s] { return (n, s) }
        }
        return nil
    }

    // MARK: Lookup

    /// Reverse-resolves `ips` through every local source at once. `dnsServers` should be the
    /// gateway plus any DNS servers inside the subnet; `interfaceAddress` pins the multicast
    /// interface (needed for secondary interfaces). Never throws; unanswered hosts are absent.
    public static func lookup(
        _ ips: [IPv4Address], dnsServers: [IPv4Address], interfaceAddress: IPv4Address?,
        timeout: Duration = .milliseconds(1500)
    ) async -> [IPv4Address: [LocalNameSource: String]] {
        guard !ips.isEmpty else { return [:] }
        var packets: [(dest: IPv4Address, port: UInt16, data: Data)] = []
        var id: UInt16 = UInt16.random(in: 1...0x7FFF)
        func nextID() -> UInt16 {
            id &+= 1
            return id
        }
        for server in dnsServers {
            for ip in ips { packets.append((server, dnsPort, ptrQuery(ip, id: nextID(), recursionDesired: true))) }
        }
        // Multicast mDNS, several questions per packet, QU so answers come straight back to us.
        let chunkSize = mdnsQuestionsPerPacket
        for start in stride(from: 0, to: ips.count, by: chunkSize) {
            let chunk = ips[start..<min(start + chunkSize, ips.count)]
            packets.append((mdnsGroup, mdnsPort, query(names: chunk.map(reverseName), id: 0, unicastResponse: true)))
        }
        for ip in ips {
            packets.append((ip, mdnsPort, ptrQuery(ip, id: 0, unicastResponse: true)))
            packets.append((ip, llmnrPort, ptrQuery(ip, id: nextID())))
        }
        let replies = await UDPBatch.exchange(packets, interfaceAddress: interfaceAddress, timeout: timeout)
        let sentIDs = Set(packets.compactMap { transactionID($0.data) })
        return names(from: replies, wanted: Set(ips), dnsServers: Set(dnsServers), sentIDs: sentIDs)
    }

    /// Sorts replies into per-host names. Router DNS answers are trusted for any host (that's
    /// their job). LLMNR is unicast to each host, so only the host's own answer counts. mDNS
    /// answers from the host itself win; answers about it from other senders (e.g. a Bonjour
    /// sleep proxy) are used only when the host didn't answer for itself.
    /// Replies whose transaction ID isn't one we sent are ignored, when `sentIDs` is given.
    static func names(
        from replies: [UDPBatch.Reply], wanted: Set<IPv4Address>,
        dnsServers: Set<IPv4Address>, sentIDs: Set<UInt16>? = nil
    ) -> [IPv4Address: [LocalNameSource: String]] {
        var out: [IPv4Address: [LocalNameSource: String]] = [:]
        var proxied: [IPv4Address: String] = [:]
        for reply in replies {
            if let sentIDs, let id = transactionID(reply.data), !sentIDs.contains(id) { continue }
            let source: LocalNameSource
            switch reply.port {
            case dnsPort where dnsServers.contains(reply.from): source = .routerDNS
            case mdnsPort: source = .mdns
            case llmnrPort: source = .llmnr
            default: continue
            }
            for (ip, raw) in ptrAnswers(reply.data) where wanted.contains(ip) {
                let own = reply.from == ip
                if source == .llmnr, !own { continue }
                guard let name = cleanHostname(raw, ip: ip) else { continue }
                if source == .mdns, !own {
                    if proxied[ip] == nil { proxied[ip] = name }
                    continue
                }
                if out[ip]?[source] == nil { out[ip, default: [:]][source] = name }
            }
        }
        for (ip, name) in proxied where out[ip]?[.mdns] == nil {
            out[ip, default: [:]][.mdns] = name
        }
        return out
    }
}

extension LocalDNS {
    /// The 16-bit ID at the start of a DNS, mDNS or LLMNR message.
    static func transactionID(_ message: Data) -> UInt16? {
        guard message.count >= 2 else { return nil }
        let start = message.startIndex
        return UInt16(message[start]) << 8 | UInt16(message[start + 1])
    }
}

// MARK: - UDP batch I/O

/// Sends a batch of datagrams from one socket and collects every reply until the timeout.
enum UDPBatch {
    struct Reply: Sendable {
        var from: IPv4Address
        var port: UInt16
        var data: Data
    }

    private static let queue = DispatchQueue(label: "LanternfishKit.UDPBatch", attributes: .concurrent)

    static func exchange(
        _ packets: [(dest: IPv4Address, port: UInt16, data: Data)], interfaceAddress: IPv4Address?,
        timeout: Duration
    ) async -> [Reply] {
        if Task.isCancelled { return [] }
        let cancelled = CancellationFlag()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { cont in
                queue.async {
                    cont.resume(
                        returning: run(
                            packets, interfaceAddress: interfaceAddress, timeout: timeout,
                            isCancelled: { cancelled.isCancelled }))
                }
            }
        } onCancel: {
            cancelled.cancel()
        }
    }

    /// Blocking; runs on `queue`. Stops early (returning what it has) once `isCancelled()`.
    private static func run(
        _ packets: [(dest: IPv4Address, port: UInt16, data: Data)], interfaceAddress: IPv4Address?,
        timeout: Duration, isCancelled: () -> Bool
    ) -> [Reply] {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return [] }
        defer { close(fd) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        if let interfaceAddress {
            // Bind to the interface's address so replies (and multicast) use the right network.
            var addr = sockaddr_in.make(interfaceAddress, port: 0)
            _ = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            var ifAddr = in_addr(s_addr: interfaceAddress.value.bigEndian)
            setsockopt(fd, IPPROTO_IP, IP_MULTICAST_IF, &ifAddr, socklen_t(MemoryLayout<in_addr>.size))
        }
        var ttl: UInt8 = 255
        setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout<UInt8>.size))
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        var replies: [Reply] = []
        // Replies kept per batch: a few per query is plenty; anything beyond is noise or a flood.
        let maxReplies = max(64, packets.count * 4)
        var buffer = [UInt8](repeating: 0, count: 9000)
        func drain() {
            while replies.count < maxReplies {
                var from = sockaddr_in()
                var len = socklen_t(MemoryLayout<sockaddr_in>.size)
                let n = buffer.withUnsafeMutableBytes { buf in
                    withUnsafeMutablePointer(to: &from) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            recvfrom(fd, buf.baseAddress, buf.count, 0, $0, &len)
                        }
                    }
                }
                guard n > 0 else { return }
                replies.append(
                    Reply(
                        from: IPv4Address(UInt32(bigEndian: from.sin_addr.s_addr)),
                        port: UInt16(bigEndian: from.sin_port), data: Data(buffer[0..<n])))
            }
        }
        // Paced: 24 datagrams, then a short pause, so neither the router nor our buffer overflows.
        for (i, p) in packets.enumerated() {
            if isCancelled() { return replies }
            var dest = sockaddr_in.make(p.dest, port: p.port)
            _ = p.data.withUnsafeBytes { buf in
                withUnsafePointer(to: &dest) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(fd, buf.baseAddress, buf.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
            if i % 24 == 23 {
                usleep(15_000)
                drain()
            }
        }
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline, !isCancelled() {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ms = max(1, min(100, (deadline - ContinuousClock.now).clampedMilliseconds))
            if poll(&pfd, 1, Int32(ms)) > 0 { drain() }
        }
        return replies
    }
}
