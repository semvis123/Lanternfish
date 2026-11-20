import Synchronization

/// TCP connect scan of one host. Only open ports are reported.
///
/// Cost is roughly `ports / concurrency * timeout` for a host that silently drops SYNs
/// (measured on a LAN router, 1-65535: 417 s @64, 105 s @256, 26 s @1024 - all with the same
/// results). Use `concurrency` of 512-1024 for full-range scans; hosts that send RSTs are
/// far faster (~1.5 s for the full range @256).
public struct PortScanner: Sendable {
    public let concurrency: Int
    public let timeout: Duration

    public init(concurrency: Int = 64, timeout: Duration = .milliseconds(400)) {
        self.concurrency = max(1, concurrency)
        self.timeout = timeout
    }

    /// Yields each open port as it is found. `progress` is called with values in 0...1,
    /// at most once per percent, and with 1 when the scan completes.
    /// Stopping iteration (or cancelling the consuming task) stops the scan.
    public func scan(
        _ ip: IPv4Address, ports: [UInt16],
        progress: (@Sendable (Double) -> Void)? = nil
    ) -> AsyncStream<OpenPort> {
        let (stream, continuation) = AsyncStream<OpenPort>.makeStream()
        FileDescriptorLimit.raiseOnce()
        // Stay well inside the descriptor limit.
        let concurrency = min(self.concurrency, max(16, FileDescriptorLimit.current - 256))
        let task = Task { [timeout] in
            let total = ports.count
            let counter = Mutex((done: 0, lastPercent: -1))
            if total == 0 { progress?(1) }
            await forEachConcurrently(ports, concurrency: concurrency) { port in
                let result = await TCPProbe.probe(ip, port: port, timeout: timeout)
                if Task.isCancelled { return }
                if result == .open {
                    continuation.yield(OpenPort(port: port, service: CommonPorts.all[port]))
                }
                guard let progress else { return }
                let report: Double? = counter.withLock { c in
                    c.done += 1
                    let percent = c.done * 100 / total
                    guard percent > c.lastPercent else { return nil }
                    c.lastPercent = percent
                    return Double(c.done) / Double(total)
                }
                if let report { progress(report) }
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }
}
