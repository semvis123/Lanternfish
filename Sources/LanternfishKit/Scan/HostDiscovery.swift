import Darwin
import Dispatch
import Synchronization

/// Finds live hosts with an unprivileged ICMP echo sweep and, in parallel, TCP connect
/// probes to a few common ports. A RST (`ECONNREFUSED`) counts as alive.
public struct HostDiscovery: Sendable {
    /// Ports that most device types answer on: web, SSH, SMB, DNS, plus 62078 (iOS lockdown,
    /// so iPhones that ignore ping still show up) and 7000 (AirPlay).
    public static let probePorts: [UInt16] = [80, 443, 22, 445, 62078, 7000, 8080, 53]

    public let concurrency: Int
    public let timeout: Duration
    /// Testing hook: disable the ICMP sweep so only TCP decides liveness.
    var useICMP = true

    public init(concurrency: Int = 256, timeout: Duration = .milliseconds(800)) {
        self.concurrency = max(1, concurrency)
        self.timeout = timeout
    }

    /// Yields one `DevicePatch` (with `responseTime`) per live host, as soon as it answers.
    /// Finishes when every probe has answered or timed out. Stopping iteration cancels all work.
    public func sweep(_ hosts: [IPv4Address]) -> AsyncStream<DevicePatch> {
        let (stream, continuation) = AsyncStream<DevicePatch>.makeStream()
        let unique = Array(uniqued(hosts))
        let task = Task { [concurrency, timeout, useICMP] in
            await Self.run(
                unique, concurrency: concurrency, timeout: timeout, useICMP: useICMP,
                continuation: continuation)
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    // MARK: - Implementation

    private enum Job: Sendable { case probing, watcher }

    private static func run(
        _ hosts: [IPv4Address], concurrency: Int, timeout: Duration,
        useICMP: Bool, continuation: AsyncStream<DevicePatch>.Continuation
    ) async {
        guard !hosts.isEmpty else { return }
        let tracker = AliveTracker(continuation: continuation, total: hosts.count)

        let pinger = !useICMP ? nil : ICMPPinger(targets: Set(hosts)) { ip, rtt in tracker.report(ip, rtt: rtt) }
        pinger?.start()
        defer { pinger?.stop() }

        // `concurrency` bounds hosts in flight; each host's ports are probed at once, so a
        // silent address costs one timeout instead of `probePorts.count` sequential ones.
        // Keep the socket count within the descriptor limit.
        FileDescriptorLimit.raiseOnce()
        let socketBudget = max(probePorts.count, FileDescriptorLimit.current - 256)
        let hostConcurrency = min(concurrency, socketBudget / probePorts.count)

        await withTaskGroup(of: Job.self) { group in
            // ICMP: send to everyone now, then retry the silent ones (the first packet to a
            // host can be lost while ARP resolves), then keep listening until `timeout`.
            if let pinger {
                group.addTask {
                    await pinger.send(to: hosts)
                    for delay in [Duration.milliseconds(250), .milliseconds(250)] {
                        try? await Task.sleep(for: delay)
                        if Task.isCancelled || tracker.allFound { return .probing }
                        await pinger.send(to: hosts.filter { !tracker.isAlive($0) })
                    }
                    try? await Task.sleep(for: timeout)
                    return .probing
                }
            }

            // TCP: all ports of a host in parallel; stop as soon as the host is known alive.
            group.addTask {
                await forEachConcurrently(hosts, concurrency: hostConcurrency) { ip in
                    await probeHost(ip, timeout: timeout, tracker: tracker)
                }
                return .probing
            }

            // Return early once every host has answered.
            group.addTask {
                await tracker.waitUntilAllFound()
                return .watcher
            }

            // Done when all probing finished, every host answered, or we were cancelled.
            var probingLeft = pinger == nil ? 1 : 2
            while let job = await group.next() {
                if job == .probing { probingLeft -= 1 }
                if probingLeft == 0 || tracker.allFound || Task.isCancelled {
                    group.cancelAll()
                }
            }
        }
    }

    private enum HostEvent: Sendable { case alive, stop, timedOut }

    private static func probeHost(_ ip: IPv4Address, timeout: Duration, tracker: AliveTracker) async {
        if tracker.isAlive(ip) || Task.isCancelled { return }
        await withTaskGroup(of: HostEvent.self) { group in
            // Alive via ICMP (or any other path) cancels this host's outstanding probes.
            group.addTask {
                await tracker.waitUntilAlive(ip)
                return .alive
            }
            for port in probePorts {
                group.addTask {
                    let start = ContinuousClock.now
                    let outcome = await TCPProbe.probeDetailed(ip, port: port, timeout: timeout)
                    switch outcome.result {
                    case .open, .refused:
                        tracker.report(ip, rtt: ContinuousClock.now - start)
                        return .alive
                    case .timeout:
                        // ARP already failed: the host isn't on the link.
                        return outcome.errno == EHOSTDOWN ? .stop : .timedOut
                    }
                }
            }
            var pending = probePorts.count
            while let event = await group.next() {
                if event == .timedOut { pending -= 1 }
                if event != .timedOut || pending == 0 {
                    group.cancelAll()
                    return
                }
            }
        }
    }
}

/// Order-preserving dedupe.
private func uniqued(_ hosts: [IPv4Address]) -> [IPv4Address] {
    var seen = Set<IPv4Address>()
    return hosts.filter { seen.insert($0).inserted }
}

/// Yields each host once: first answer wins. Lets tasks wait for a host (or all hosts).
private final class AliveTracker: Sendable {
    private struct State: Sendable {
        var alive = Set<IPv4Address>()
        var hostWaiters: [IPv4Address: CheckedContinuation<Void, Never>] = [:]
        var allWaiter: CheckedContinuation<Void, Never>?
    }

    private let continuation: AsyncStream<DevicePatch>.Continuation
    private let total: Int
    private let state = Mutex(State())

    init(continuation: AsyncStream<DevicePatch>.Continuation, total: Int) {
        self.continuation = continuation
        self.total = total
    }

    func isAlive(_ ip: IPv4Address) -> Bool { state.withLock { $0.alive.contains(ip) } }
    var allFound: Bool { state.withLock { $0.alive.count >= total } }

    func report(_ ip: IPv4Address, rtt: Duration) {
        let waiters = state.withLock { s -> [CheckedContinuation<Void, Never>]? in
            guard s.alive.insert(ip).inserted else { return nil }
            var out: [CheckedContinuation<Void, Never>] = []
            if let w = s.hostWaiters.removeValue(forKey: ip) { out.append(w) }
            if s.alive.count >= total, let w = s.allWaiter {
                s.allWaiter = nil
                out.append(w)
            }
            return out
        }
        guard let waiters else { return }
        var patch = DevicePatch(ip: ip)
        patch.responseTime = rtt
        continuation.yield(patch)
        for waiter in waiters { waiter.resume() }
    }

    /// Returns once `ip` is alive or the calling task is cancelled. One waiter per host.
    func waitUntilAlive(_ ip: IPv4Address) async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                let now = state.withLock { s -> Bool in
                    if s.alive.contains(ip) || Task.isCancelled { return true }
                    s.hostWaiters[ip] = c
                    return false
                }
                if now { c.resume() }
            }
        } onCancel: {
            state.withLock { $0.hostWaiters.removeValue(forKey: ip) }?.resume()
        }
    }

    /// Returns once every host is alive or the calling task is cancelled.
    func waitUntilAllFound() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                let now = state.withLock { s -> Bool in
                    if s.alive.count >= total || Task.isCancelled { return true }
                    s.allWaiter = c
                    return false
                }
                if now { c.resume() }
            }
        } onCancel: {
            state.withLock { s -> CheckedContinuation<Void, Never>? in
                defer { s.allWaiter = nil }
                return s.allWaiter
            }?.resume()
        }
    }
}

// MARK: - ICMP

/// Unprivileged ICMP echo over one `SOCK_DGRAM`/`IPPROTO_ICMP` socket with a
/// `DispatchSource` receive loop. On macOS the received datagrams include the IP header, and every
/// ICMP socket sees every echo reply, so replies are matched like `EchoSession` does: source
/// address, our random payload token (identifier as fallback) and the sequence number, with the
/// RTT measured from the send that sequence belongs to.
private final class ICMPPinger: Sendable {
    private let fd: Int32
    private let identifier: UInt16
    private let token = ICMPPacket.makeToken(prefix: "SKsweep")
    private let targets: Set<IPv4Address>
    private let onReply: @Sendable (IPv4Address, Duration) -> Void
    /// Serial: reads, sends and the descriptor's close all happen here.
    private let queue = DispatchQueue(label: "LanternfishKit.ICMP", qos: .userInitiated)
    private struct State: @unchecked Sendable {
        var ledger = EchoLedger()
        var source: DispatchSourceRead?
        var stopped = false
    }
    private let state = Mutex(State())

    init?(targets: Set<IPv4Address>, onReply: @escaping @Sendable (IPv4Address, Duration) -> Void) {
        guard let fd = ICMPSocket.open() else { return nil }
        self.fd = fd
        self.identifier = UInt16.random(in: 1 ... .max)
        self.targets = targets
        self.onReply = onReply
    }

    func start() {
        let fd = self.fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { self.drain() }
        source.setCancelHandler { close(fd) }
        state.withLock { $0.source = source }
        source.activate()
    }

    func stop() {
        let source = state.withLock { s -> DispatchSourceRead? in
            guard !s.stopped else { return nil }
            s.stopped = true
            defer { s.source = nil }
            return s.source
        }
        if let source { source.cancel() }  // closes fd (on `queue`, after any in-progress send)
    }

    private static let burstSize = 32
    private static let burstGap = Duration.milliseconds(2)

    /// Sends one echo request per host, in small bursts to avoid `ENOBUFS`.
    func send(to hosts: [IPv4Address]) async {
        var index = 0
        while index < hosts.count {
            if Task.isCancelled { return }
            let end = min(index + Self.burstSize, hosts.count)
            let burst = Array(hosts[index..<end])
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                queue.async {
                    for ip in burst { self.sendOne(ip) }
                    c.resume()
                }
            }
            index = end
            if index < hosts.count { try? await Task.sleep(for: Self.burstGap) }
        }
    }

    /// On `queue`.
    private func sendOne(_ ip: IPv4Address) {
        let seq: UInt16? = state.withLock { s in
            guard !s.stopped else { return nil }
            return s.ledger.recordSend(to: ip, at: .now)
        }
        guard let seq else { return }
        ICMPSocket.send(fd, ICMPPacket.echoRequest(identifier: identifier, sequence: seq, payload: token), to: ip)
    }

    private func drain() {
        ICMPSocket.drain(fd) { data, ip in
            let now = ContinuousClock.now
            guard targets.contains(ip), let reply = ICMPPacket.parseEchoReply(data),
                ICMPPacket.matches(reply, token: token, identifier: identifier),
                let rtt = state.withLock({ $0.ledger.rtt(from: ip, sequence: reply.sequence, at: now) })
            else { return }
            onReply(ip, rtt)
        }
    }
}
