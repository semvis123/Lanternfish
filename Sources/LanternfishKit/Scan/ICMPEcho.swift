import Darwin

/// Shared helpers for unprivileged ICMP echo (`SOCK_DGRAM`/`IPPROTO_ICMP`), used by
/// `HostDiscovery` (sweep) and `Pinger` (continuous sessions).
enum ICMPPacket {
    /// Payload for requests that don't carry a session token.
    static let defaultPayload = Array("LanternfishKit-ping!".utf8)

    static func echoRequest(
        identifier: UInt16, sequence: UInt16,
        payload: [UInt8] = defaultPayload
    ) -> [UInt8] {
        var p: [UInt8] = [
            8, 0, 0, 0,
            UInt8(identifier >> 8), UInt8(identifier & 0xFF),
            UInt8(sequence >> 8), UInt8(sequence & 0xFF),
        ]
        p += payload
        let sum = checksum(p)
        p[2] = UInt8(sum >> 8)
        p[3] = UInt8(sum & 0xFF)
        return p
    }

    static func checksum(_ bytes: [UInt8]) -> UInt16 {
        var sum: UInt32 = 0
        var i = 0
        while i + 1 < bytes.count {
            sum += UInt32(bytes[i]) << 8 | UInt32(bytes[i + 1])
            i += 2
        }
        if i < bytes.count { sum += UInt32(bytes[i]) << 8 }
        while sum >> 16 != 0 { sum = (sum & 0xFFFF) + (sum >> 16) }
        return ~UInt16(sum)
    }

    struct EchoReply: Equatable {
        var identifier: UInt16
        var sequence: UInt16
        var payload: [UInt8]
    }

    /// Index of the ICMP message in `data`, skipping a leading IPv4 header if present (macOS
    /// includes it on received `SOCK_DGRAM` ICMP datagrams).
    static func messageStart(in data: ArraySlice<UInt8>) -> Int {
        guard let first = data.first, first >> 4 == 4 else { return data.startIndex }
        return data.startIndex + Int(first & 0x0F) * 4
    }

    /// Parses an echo reply (type 0, code 0), with or without a leading IPv4 header.
    static func parseEchoReply(_ data: ArraySlice<UInt8>) -> EchoReply? {
        let start = messageStart(in: data)
        guard data.endIndex - start >= 8, data[start] == 0, data[start + 1] == 0 else { return nil }
        return EchoReply(
            identifier: UInt16(data[start + 4]) << 8 | UInt16(data[start + 5]),
            sequence: UInt16(data[start + 6]) << 8 | UInt16(data[start + 7]),
            payload: Array(data[(start + 8)...]))
    }
}

extension ICMPPacket {
    /// Whether `reply` answers one of our requests: our `token` must be echoed back; only if the
    /// payload was cut short do we fall back to the identifier (which some `SOCK_DGRAM` ICMP
    /// implementations rewrite).
    static func matches(_ reply: EchoReply, token: [UInt8], identifier: UInt16) -> Bool {
        if reply.payload.count >= token.count {
            return reply.payload.starts(with: token)
        }
        return reply.identifier == identifier
    }

    /// A random 16-byte payload starting with `prefix`, identifying one socket's requests.
    static func makeToken(prefix: String) -> [UInt8] {
        let head = Array(prefix.utf8.prefix(15))
        return head + (head.count..<16).map { _ in UInt8.random(in: 0 ... .max) }
    }
}

/// Per-send bookkeeping for a sweep: which host each sequence number went to and when, so a
/// reply's round-trip time is measured from the request it answers (not the first try).
struct EchoLedger {
    private var sent: [UInt16: (ip: IPv4Address, at: ContinuousClock.Instant)] = [:]
    private var lastSent: [IPv4Address: ContinuousClock.Instant] = [:]
    private var sequence: UInt16

    init(firstSequence: UInt16 = .random(in: 0 ... .max)) { sequence = firstSequence }

    /// Records a send to `ip` and returns the sequence number to put in the request.
    mutating func recordSend(to ip: IPv4Address, at now: ContinuousClock.Instant) -> UInt16 {
        sequence &+= 1
        sent[sequence] = (ip, now)
        lastSent[ip] = now
        return sequence
    }

    /// The RTT for a (token-matched) reply from `ip` with `sequence`, or nil if we never pinged
    /// `ip`. When the sequence is unknown or belongs to another host (wrapped on huge sweeps), the
    /// latest send to `ip` is used.
    mutating func rtt(from ip: IPv4Address, sequence: UInt16, at now: ContinuousClock.Instant) -> Duration? {
        if let entry = sent[sequence], entry.ip == ip {
            sent[sequence] = nil
            return now - entry.at
        }
        return lastSent[ip].map { now - $0 }
    }
}

enum ICMPSocket {
    /// Opens a non-blocking unprivileged ICMP socket, or nil if the OS refuses.
    static func open(bufferSize: Int32 = 256 * 1024) -> Int32? {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
        guard fd >= 0 else { return nil }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var buf = bufferSize
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &buf, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &buf, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)
        return fd
    }

    /// Sends `packet` to `ip`, retrying briefly on `ENOBUFS`. Returns false on failure.
    /// May sleep for a few milliseconds: call it on a private dispatch queue (the socket's own
    /// read queue, which also serializes it with the close), never on the cooperative pool.
    @discardableResult
    static func send(_ fd: Int32, _ packet: [UInt8], to ip: IPv4Address) -> Bool {
        var packet = packet
        var addr = sockaddr_in.make(ip, port: 0)
        for _ in 0..<3 {
            let n = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, &packet, packet.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if n >= 0 { return true }
            if errno != ENOBUFS { return false }
            usleep(1000)
        }
        return false
    }

    /// Reads every pending datagram, calling `handle` with the bytes and the source address.
    static func drain(_ fd: Int32, _ handle: (ArraySlice<UInt8>, IPv4Address) -> Void) {
        var buffer = [UInt8](repeating: 0, count: 1500)
        while true {
            var from = sockaddr_in()
            var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(fd, &buffer, buffer.count, 0, $0, &fromLen)
                }
            }
            if n <= 0 { return }
            handle(buffer[0..<n], IPv4Address(UInt32(bigEndian: from.sin_addr.s_addr)))
        }
    }
}
