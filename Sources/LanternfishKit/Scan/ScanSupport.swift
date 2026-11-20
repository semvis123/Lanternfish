import Darwin
import Dispatch

extension sockaddr_in {
    static func make(_ ip: IPv4Address, port: UInt16) -> sockaddr_in {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = ip.value.bigEndian
        return addr
    }
}

extension Duration {
    /// Whole nanoseconds clamped to `0 ... Int64.max`; never traps (e.g. `.seconds(Int64.max)`).
    var clampedNanoseconds: Int64 {
        let (seconds, attoseconds) = components
        guard seconds >= 0 else { return 0 }
        let (ns, overflow) = seconds.multipliedReportingOverflow(by: 1_000_000_000)
        guard !overflow else { return .max }
        let (sum, overflow2) = ns.addingReportingOverflow(attoseconds / 1_000_000_000)
        return overflow2 ? .max : max(0, sum)
    }

    /// Whole milliseconds, clamped like `clampedNanoseconds`.
    var clampedMilliseconds: Int { Int(clamping: clampedNanoseconds / 1_000_000) }

    /// For `DispatchTime` arithmetic: negative durations become zero, huge ones saturate.
    var dispatchInterval: DispatchTimeInterval { .nanoseconds(Int(clamping: clampedNanoseconds)) }

    var seconds: Double {
        let (s, a) = components
        return Double(s) + Double(a) / 1e18
    }
}

/// GUI apps start with a soft limit of 256 descriptors, which hundreds of concurrent probes
/// would exhaust. Raise the soft limit (process-wide, once) towards the hard limit.
enum FileDescriptorLimit {
    private static let raised: Bool = {
        var lim = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &lim) == 0 else { return false }
        let target: rlim_t = min(lim.rlim_max, 8192)
        guard lim.rlim_cur < target else { return true }
        lim.rlim_cur = target
        return setrlimit(RLIMIT_NOFILE, &lim) == 0
    }()

    static func raiseOnce() { _ = raised }

    /// The current soft limit.
    static var current: Int {
        var lim = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &lim) == 0 else { return 256 }
        return Int(clamping: lim.rlim_cur)
    }
}

/// Runs `body` for every item with at most `concurrency` invocations in flight.
/// Stops scheduling new items once the calling task is cancelled.
public func forEachConcurrently<T: Sendable>(
    _ items: [T], concurrency: Int, _ body: @escaping @Sendable (T) async -> Void
) async {
    let limit = max(1, concurrency)
    await withTaskGroup(of: Void.self) { group in
        var iterator = items.makeIterator()
        var inFlight = 0
        while inFlight < limit, let item = iterator.next() {
            group.addTask { await body(item) }
            inFlight += 1
        }
        while await group.next() != nil {
            if Task.isCancelled {
                group.cancelAll()
                continue
            }
            if let item = iterator.next() {
                group.addTask { await body(item) }
            }
        }
    }
}
