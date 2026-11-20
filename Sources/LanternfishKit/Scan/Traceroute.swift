import Darwin
import Dispatch
import Foundation
import Synchronization

/// One TTL of a traceroute.
public struct TracerouteHop: Sendable, Hashable {
    /// 1-based hop number (the probe's IP TTL).
    public let ttl: Int
    /// The first address that answered for this TTL, or nil while nothing answered.
    public var address: IPv4Address?
    /// Reverse DNS name of `address`, filled in later when the lookup succeeds.
    public var hostname: String?
    /// One entry per *completed* probe, in completion order: a round-trip time, or nil for a
    /// probe that timed out ("*"). Fewer than `probesPerHop` entries means probes are pending.
    public var rtts: [Duration?]

    public init(ttl: Int, address: IPv4Address? = nil, hostname: String? = nil, rtts: [Duration?] = []) {
        self.ttl = ttl
        self.address = address
        self.hostname = hostname
        self.rtts = rtts
    }

    /// Mean of the probes that got an answer.
    public var averageRTT: Duration? {
        let ok = rtts.compactMap { $0 }
        guard !ok.isEmpty else { return nil }
        return ok.reduce(.zero, +) / ok.count
    }
}

public enum TracerouteEvent: Sendable {
    /// The target resolved to this address; always the first event of a successful trace.
    case resolved(IPv4Address)
    /// A new or updated hop. The same `ttl` is emitted repeatedly as probes complete and the
    /// hostname resolves; consumers should replace earlier hops with the same ttl.
    case hop(TracerouteHop)
    /// The trace is over. Hops with a ttl above the destination's are never emitted once the
    /// destination is known, but a hop just above it may have been emitted early; consumers
    /// should drop hops past the first one whose address is the destination.
    case finished(reachedDestination: Bool)
    case failed(String)
}

/// Unprivileged ICMP traceroute.
///
/// Sends ICMP echo requests with increasing `IP_TTL` on a `SOCK_DGRAM`/`IPPROTO_ICMP` socket.
/// macOS delivers ICMP Time Exceeded / Destination Unreachable errors to that socket (with the IP
/// header), embedding our original echo header, so hops are matched by the embedded identifier
/// and sequence. Like `mtr`, every TTL is probed at once per round, so a full trace takes about
/// one timeout rather than `maxHops` × timeout.
public struct Traceroute: Sendable {
    public let maxHops: Int
    public let probesPerHop: Int
    public let timeout: Duration

    public init(maxHops: Int = 30, probesPerHop: Int = 3, timeout: Duration = .seconds(1)) {
        self.maxHops = max(1, min(255, maxHops))
        self.probesPerHop = max(1, min(10, probesPerHop))
        self.timeout = timeout
    }

    public func trace(_ host: String) -> AsyncStream<TracerouteEvent> {
        let (stream, continuation) = AsyncStream<TracerouteEvent>.makeStream()
        let config = self
        let task = Task {
            defer { continuation.finish() }
            let name = host.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else {
                continuation.yield(.failed("No host given"))
                return
            }
            guard let ip = await Self.resolve(name) else {
                if !Task.isCancelled { continuation.yield(.failed("Couldn’t resolve “\(name)”")) }
                return
            }
            if Task.isCancelled { return }
            continuation.yield(.resolved(ip))
            guard let session = TraceSession(target: ip, config: config, emit: { continuation.yield($0) }) else {
                continuation.yield(.failed("Couldn’t open an ICMP socket"))
                return
            }
            let reached = await withTaskCancellationHandler {
                await session.run()
            } onCancel: {
                session.cancel()
            }
            if !Task.isCancelled { continuation.yield(.finished(reachedDestination: reached)) }
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    /// Dotted IPv4 literal, else the first IPv4 address from getaddrinfo.
    static func resolve(_ host: String) async -> IPv4Address? {
        if let ip = IPv4Address(host) { return ip }
        return await withCheckedContinuation { c in
            DispatchQueue.global(qos: .userInitiated).async {
                var hints = addrinfo()
                hints.ai_family = AF_INET
                hints.ai_socktype = SOCK_DGRAM
                var res: UnsafeMutablePointer<addrinfo>?
                guard getaddrinfo(host, nil, &hints, &res) == 0, let first = res else {
                    c.resume(returning: nil)
                    return
                }
                defer { freeaddrinfo(first) }
                var p: UnsafeMutablePointer<addrinfo>? = first
                while let ai = p {
                    if ai.pointee.ai_family == AF_INET, let sa = ai.pointee.ai_addr {
                        let ip = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                            IPv4Address(UInt32(bigEndian: $0.pointee.sin_addr.s_addr))
                        }
                        c.resume(returning: ip)
                        return
                    }
                    p = ai.pointee.ai_next
                }
                c.resume(returning: nil)
            }
        }
    }
}

// MARK: - Packet parsing

/// An ICMP message relevant to traceroute, parsed from a datagram with or without IPv4 header.
enum TracerouteResponse: Equatable {
    case echoReply(identifier: UInt16, sequence: UInt16, payload: [UInt8])
    /// Type 11 (Time Exceeded) or 3 (Destination Unreachable) quoting one of our echo requests.
    case error(type: UInt8, code: UInt8, originalDestination: IPv4Address, identifier: UInt16, sequence: UInt16)

    static let timeExceeded: UInt8 = 11
    static let unreachable: UInt8 = 3

    static func parse(_ data: ArraySlice<UInt8>) -> TracerouteResponse? {
        let start = ICMPPacket.messageStart(in: data)
        guard data.endIndex - start >= 8 else { return nil }
        let type = data[start]
        let code = data[start + 1]
        if type == 0 {
            guard let r = ICMPPacket.parseEchoReply(data[start...]) else { return nil }
            return .echoReply(identifier: r.identifier, sequence: r.sequence, payload: r.payload)
        }
        guard type == timeExceeded || type == unreachable else { return nil }
        // Quoted original datagram: IPv4 header + at least the first 8 bytes of our ICMP echo.
        let inner = start + 8
        guard data.endIndex - inner >= 20, data[inner] >> 4 == 4 else { return nil }
        let ihl = Int(data[inner] & 0x0F) * 4
        guard ihl >= 20, data[inner + 9] == UInt8(IPPROTO_ICMP) else { return nil }
        let echo = inner + ihl
        guard data.endIndex - echo >= 8, data[echo] == 8 else { return nil }
        let dst = (16..<20).reduce(UInt32(0)) { $0 << 8 | UInt32(data[inner + $1]) }
        return .error(
            type: type, code: code, originalDestination: IPv4Address(dst),
            identifier: UInt16(data[echo + 4]) << 8 | UInt16(data[echo + 5]),
            sequence: UInt16(data[echo + 6]) << 8 | UInt16(data[echo + 7]))
    }
}

// MARK: - Session

/// One trace: a socket, outstanding probes and the hop table. All mutable state lives on `queue`.
private final class TraceSession: @unchecked Sendable {
    private static let roundSpacing: DispatchTimeInterval = .milliseconds(200)
    private static let nextIdentifier = Atomic<UInt16>(UInt16.random(in: 1 ... .max))

    private let target: IPv4Address
    private let config: Traceroute
    private let emit: @Sendable (TracerouteEvent) -> Void
    private let fd: Int32
    private let identifier: UInt16
    private let token: [UInt8]
    private let queue = DispatchQueue(label: "LanternfishKit.Traceroute", qos: .userInitiated)
    private var source: DispatchSourceRead?

    private struct Probe {
        var ttl: Int
        var sentAt: ContinuousClock.Instant
    }
    private var pending: [UInt16: Probe] = [:]
    private var nextSequence: UInt16 = UInt16.random(in: 0 ... .max)
    private var hops: [Int: TracerouteHop] = [:]
    /// Smallest TTL that got an echo reply from the target.
    private var destinationTTL: Int?
    /// Smallest TTL that got a Destination Unreachable (trace can't go past it).
    private var unreachableTTL: Int?
    private var roundsSent = 0
    private var lookups = 0
    private var lookupTasks: [Int: Task<Void, Never>] = [:]
    private var done = false
    private var completion: CheckedContinuation<Bool, Never>?

    init?(target: IPv4Address, config: Traceroute, emit: @escaping @Sendable (TracerouteEvent) -> Void) {
        guard let fd = ICMPSocket.open(bufferSize: 128 * 1024) else { return nil }
        self.fd = fd
        self.target = target
        self.config = config
        self.emit = emit
        self.identifier = Self.nextIdentifier.wrappingAdd(1, ordering: .relaxed).newValue
        self.token = ICMPPacket.makeToken(prefix: "SKtrace")
    }

    /// True until the read source takes over closing the descriptor.
    private var ownsDescriptor = true

    deinit { if ownsDescriptor { close(fd) } }

    /// Runs the trace; returns whether the destination answered.
    func run() async -> Bool {
        await withCheckedContinuation { c in
            queue.async { [self] in
                completion = c
                guard !done else {
                    finish()
                    return
                }
                let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
                src.setEventHandler { [weak self] in self?.receive() }
                src.setCancelHandler { [fd] in close(fd) }
                source = src
                ownsDescriptor = false
                src.activate()
                sendRound()
            }
        }
    }

    func cancel() {
        queue.async { [self] in
            done = true
            finish()
        }
    }

    // MARK: Sending

    /// The highest TTL still worth probing.
    private var ceiling: Int {
        min(config.maxHops, destinationTTL ?? .max, unreachableTTL ?? .max)
    }

    private func sendRound() {
        guard !done else { return }
        roundsSent += 1
        let top = ceiling
        for ttl in 1...top {
            var t = Int32(ttl)
            setsockopt(fd, IPPROTO_IP, IP_TTL, &t, socklen_t(MemoryLayout<Int32>.size))
            let seq = nextSequence
            nextSequence &+= 1
            let packet = ICMPPacket.echoRequest(identifier: identifier, sequence: seq, payload: token)
            pending[seq] = Probe(ttl: ttl, sentAt: .now)
            if !ICMPSocket.send(fd, packet, to: target) {
                complete(seq, from: nil, rtt: nil)
                continue
            }
            queue.asyncAfter(deadline: .now() + config.timeout.dispatchInterval) { [weak self] in
                self?.complete(seq, from: nil, rtt: nil)
            }
        }
        if roundsSent < config.probesPerHop {
            queue.asyncAfter(deadline: .now() + Self.roundSpacing) { [weak self] in self?.sendRound() }
        }
        checkDone()
    }

    // MARK: Receiving

    private func receive() {
        ICMPSocket.drain(fd) { data, from in
            let now = ContinuousClock.now
            switch TracerouteResponse.parse(data) {
            case .echoReply(let id, let seq, let payload)?:
                let reply = ICMPPacket.EchoReply(identifier: id, sequence: seq, payload: payload)
                guard from == target, ICMPPacket.matches(reply, token: token, identifier: identifier),
                    let probe = pending[seq]
                else { return }
                if probe.ttl < destinationTTL ?? .max { destinationTTL = probe.ttl }
                complete(seq, from: from, rtt: now - probe.sentAt)
            case .error(let type, _, let dst, let id, let seq)?:
                guard dst == target, id == identifier, let probe = pending[seq] else { return }
                if type == TracerouteResponse.unreachable, probe.ttl < unreachableTTL ?? .max {
                    unreachableTTL = probe.ttl
                }
                complete(seq, from: from, rtt: now - probe.sentAt)
            case nil:
                return
            }
        }
    }

    private func complete(_ seq: UInt16, from: IPv4Address?, rtt: Duration?) {
        guard let probe = pending.removeValue(forKey: seq) else { return }
        var hop = hops[probe.ttl] ?? TracerouteHop(ttl: probe.ttl)
        hop.rtts.append(rtt)
        let newAddress = hop.address == nil && from != nil
        if newAddress { hop.address = from }
        hops[probe.ttl] = hop
        if !done, probe.ttl <= ceiling { emit(.hop(hop)) }
        if newAddress, let from, !done, probe.ttl <= ceiling { lookUp(from, ttl: probe.ttl) }
        checkDone()
    }

    private func lookUp(_ ip: IPv4Address, ttl: Int) {
        lookups += 1
        // Tracked so a finished/cancelled trace cancels its outstanding lookups.
        lookupTasks[ttl]?.cancel()
        lookupTasks[ttl] = Task { [weak self] in
            let name = await ReverseDNS.lookup(ip, timeout: .milliseconds(1500))
            self?.queue.async { [weak self] in self?.named(ttl, ip: ip, name: name) }
        }
    }

    private func named(_ ttl: Int, ip: IPv4Address, name: String?) {
        lookups -= 1
        if !done { lookupTasks[ttl] = nil }
        if let name, !done, var hop = hops[ttl], hop.address == ip, ttl <= ceiling {
            hop.hostname = name
            hops[ttl] = hop
            emit(.hop(hop))
        }
        checkDone()
    }

    private func checkDone() {
        guard !done, roundsSent >= config.probesPerHop, lookups == 0 else { return }
        let top = ceiling
        guard !pending.values.contains(where: { $0.ttl <= top }) else { return }
        done = true
        finish()
    }

    private func finish() {
        for task in lookupTasks.values { task.cancel() }
        lookupTasks = [:]
        source?.cancel()  // closes fd
        source = nil
        pending = [:]
        completion?.resume(returning: destinationTTL != nil)
        completion = nil
    }
}
