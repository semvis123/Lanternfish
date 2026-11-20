import Darwin
import Dispatch
import Foundation
import Synchronization

/// One echo exchange of a ping session.
public struct PingResult: Sendable, Hashable {
    /// 0-based, increasing by one per echo request sent.
    public let sequence: Int
    /// Round-trip time, or nil when no reply arrived within the timeout.
    public let rtt: Duration?
    /// When the request was sent.
    public let date: Date

    public init(sequence: Int, rtt: Duration?, date: Date) {
        self.sequence = sequence
        self.rtt = rtt
        self.date = date
    }

    public var isTimeout: Bool { rtt == nil }
}

/// Continuous unprivileged ICMP echo ("ping") to a single host.
public struct Pinger: Sendable {
    public let interval: Duration
    public let timeout: Duration

    public init(interval: Duration = .seconds(1), timeout: Duration = .seconds(1)) {
        self.interval = interval
        self.timeout = timeout
    }

    /// Pings `ip` once per `interval` and yields one result per request (a reply or a timeout).
    /// Runs until the consumer stops iterating or the consuming task is cancelled. Finishes
    /// immediately if an ICMP socket can't be opened.
    public func ping(_ ip: IPv4Address) -> AsyncStream<PingResult> {
        let (stream, continuation) = AsyncStream<PingResult>.makeStream(bufferingPolicy: .bufferingNewest(256))
        let task = Task { [interval, timeout] in
            defer { continuation.finish() }
            guard let session = EchoSession(target: ip) else { return }
            defer { session.invalidate() }
            let clock = ContinuousClock()
            var next = clock.now
            var sequence = 0
            while !Task.isCancelled {
                let date = Date()
                let rtt = await session.exchange(sequence: UInt16(truncatingIfNeeded: sequence), timeout: timeout)
                if Task.isCancelled { break }
                continuation.yield(PingResult(sequence: sequence, rtt: rtt, date: date))
                sequence += 1
                next = max(next.advanced(by: interval), clock.now)
                try? await Task.sleep(until: next, clock: clock)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }
}

// MARK: - Session

/// One ICMP socket talking to one host. Replies are matched on source address, sequence and a
/// per-session token in the payload. The token survives the kernel rewriting the ICMP identifier
/// (as some `SOCK_DGRAM` ICMP implementations do), so concurrent sessions — even to the same
/// host — never take each other's replies. On macOS every ICMP socket sees every echo reply.
final class EchoSession: Sendable {
    private static let nextIdentifier = Atomic<UInt16>(UInt16.random(in: 1 ... .max))

    let target: IPv4Address
    let identifier: UInt16
    let token: [UInt8]
    private let fd: Int32
    private let queue = DispatchQueue(label: "LanternfishKit.Ping", qos: .userInitiated)

    private struct Pending {
        var sentAt: ContinuousClock.Instant
        var continuation: CheckedContinuation<Duration?, Never>
    }
    private struct State: @unchecked Sendable {
        var pending: [UInt16: Pending] = [:]
        var source: DispatchSourceRead?
        var closed = false
    }
    private let state = Mutex(State())

    init?(target: IPv4Address) {
        guard let fd = ICMPSocket.open(bufferSize: 64 * 1024) else { return nil }
        self.fd = fd
        self.target = target
        self.identifier = Self.nextIdentifier.wrappingAdd(1, ordering: .relaxed).newValue
        self.token = ICMPPacket.makeToken(prefix: "SKping")

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.drain() }
        source.setCancelHandler { close(fd) }
        state.withLock { $0.source = source }
        source.activate()
    }

    deinit { invalidate() }

    func invalidate() {
        let (source, waiters) = state.withLock { s -> (DispatchSourceRead?, [Pending]) in
            guard !s.closed else { return (nil, []) }
            s.closed = true
            defer {
                s.source = nil
                s.pending = [:]
            }
            return (s.source, Array(s.pending.values))
        }
        source?.cancel()  // closes fd
        for waiter in waiters { waiter.continuation.resume(returning: nil) }
    }

    /// Sends one echo request and waits for its reply. Returns nil on timeout, send failure,
    /// cancellation or after `invalidate()`.
    func exchange(sequence: UInt16, timeout: Duration) async -> Duration? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Duration?, Never>) in
                let registered = state.withLock { s -> Bool in
                    guard !s.closed, !Task.isCancelled else { return false }
                    s.pending[sequence]?.continuation.resume(returning: nil)  // wrapped sequence
                    s.pending[sequence] = Pending(sentAt: .now, continuation: c)
                    return true
                }
                guard registered else {
                    c.resume(returning: nil)
                    return
                }
                let packet = ICMPPacket.echoRequest(identifier: identifier, sequence: sequence, payload: token)
                // Send on the socket's queue: off the cooperative pool (ENOBUFS retries sleep) and
                // serialized with the read source's cancel handler that closes the descriptor.
                queue.async { [self] in
                    guard !state.withLock({ $0.closed }) else {
                        finish(sequence, rtt: nil)
                        return
                    }
                    if !ICMPSocket.send(fd, packet, to: target) {
                        finish(sequence, rtt: nil)
                        return
                    }
                    queue.asyncAfter(deadline: .now() + timeout.dispatchInterval) { [weak self] in
                        self?.finish(sequence, rtt: nil)
                    }
                }
            }
        } onCancel: {
            finish(sequence, rtt: nil)
        }
    }

    private func finish(_ sequence: UInt16, rtt: Duration?) {
        state.withLock { $0.pending.removeValue(forKey: sequence) }?.continuation.resume(returning: rtt)
    }

    private func drain() {
        ICMPSocket.drain(fd) { data, from in
            let now = ContinuousClock.now
            guard from == target, let reply = ICMPPacket.parseEchoReply(data), matches(reply) else { return }
            if let pending = state.withLock({ $0.pending.removeValue(forKey: reply.sequence) }) {
                pending.continuation.resume(returning: now - pending.sentAt)
            }
        }
    }

    /// Our token must be echoed back; fall back to the identifier only if the payload was cut.
    func matches(_ reply: ICMPPacket.EchoReply) -> Bool {
        ICMPPacket.matches(reply, token: token, identifier: identifier)
    }
}
