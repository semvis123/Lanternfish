import Darwin
import Dispatch
import Synchronization

/// A single non-blocking TCP connect probe.
///
/// The connect is started on a non-blocking socket and completion is awaited with a
/// `DispatchSource` write-readiness source plus a timer, so no thread (cooperative or
/// otherwise) is blocked while hundreds of probes are in flight.
public enum TCPProbe {
    public enum Result: Sendable, Equatable {
        /// The connection was accepted.
        case open
        /// The host answered with a RST: the port is closed but the host is alive.
        case refused
        /// No answer, host unreachable/down, or the probe was cancelled.
        case timeout
    }

    public static func probe(_ ip: IPv4Address, port: UInt16, timeout: Duration) async -> Result {
        await probeDetailed(ip, port: port, timeout: timeout).result
    }

    // MARK: - Internal

    struct Outcome: Sendable {
        var result: Result
        /// errno of the failure, 0 for success or timeout.
        var errno: Int32
    }

    fileprivate static let queue = DispatchQueue(
        label: "LanternfishKit.TCPProbe", qos: .userInitiated,
        attributes: .concurrent)

    static func probeDetailed(_ ip: IPv4Address, port: UInt16, timeout: Duration) async -> Outcome {
        FileDescriptorLimit.raiseOnce()
        if Task.isCancelled { return Outcome(result: .timeout, errno: ECANCELED) }

        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { return Outcome(result: .timeout, errno: errno) }

        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        var addr = sockaddr_in.make(ip, port: port)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if rc == 0 {
            close(fd)
            return Outcome(result: .open, errno: 0)
        }
        let err = errno
        guard err == EINPROGRESS else {
            close(fd)
            return outcome(forError: err)
        }

        let waiter = ConnectWaiter(fd: fd)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiter.start(continuation, timeout: timeout)
            }
        } onCancel: {
            waiter.finish(Outcome(result: .timeout, errno: ECANCELED))
        }
    }

    fileprivate static func outcome(forError err: Int32) -> Outcome {
        switch err {
        case 0: Outcome(result: .open, errno: 0)
        case ECONNREFUSED: Outcome(result: .refused, errno: err)
        default: Outcome(result: .timeout, errno: err)
        }
    }
}

/// Owns the socket of one in-flight connect and resumes its continuation exactly once.
private final class ConnectWaiter: Sendable {
    private struct State: @unchecked Sendable {
        var continuation: CheckedContinuation<TCPProbe.Outcome, Never>?
        var done = false
        var source: DispatchSourceWrite?
        var timer: DispatchSourceTimer?
    }

    private let fd: Int32
    private let state = Mutex(State())

    init(fd: Int32) { self.fd = fd }

    func start(_ continuation: CheckedContinuation<TCPProbe.Outcome, Never>, timeout: Duration) {
        let fd = self.fd
        let cancelledEarly = state.withLock { s -> Bool in
            if s.done { return true }
            s.continuation = continuation

            let source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: TCPProbe.queue)
            // Strong captures: the cycle is broken in `finish`, which the timer guarantees.
            source.setEventHandler {
                var err: Int32 = 0
                var len = socklen_t(MemoryLayout<Int32>.size)
                if getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len) != 0 { err = errno }
                self.finish(TCPProbe.outcome(forError: err))
            }
            // The source owns the fd from here on; cancelling it closes the socket.
            source.setCancelHandler { close(fd) }

            let timer = DispatchSource.makeTimerSource(queue: TCPProbe.queue)
            timer.schedule(deadline: .now() + timeout.dispatchInterval, leeway: .milliseconds(5))
            timer.setEventHandler {
                self.finish(TCPProbe.Outcome(result: .timeout, errno: ETIMEDOUT))
            }

            s.source = source
            s.timer = timer
            source.activate()
            timer.activate()
            return false
        }
        if cancelledEarly {
            close(fd)
            continuation.resume(returning: TCPProbe.Outcome(result: .timeout, errno: ECANCELED))
        }
    }

    func finish(_ outcome: TCPProbe.Outcome) {
        let taken = state.withLock { s -> State? in
            guard !s.done else { return nil }
            s.done = true
            let copy = s
            s.continuation = nil
            s.source = nil
            s.timer = nil
            return copy
        }
        // If `start` hasn't run yet it will see `done` and close the fd itself.
        guard let taken else { return }
        taken.timer?.cancel()
        taken.source?.cancel()
        taken.continuation?.resume(returning: outcome)
    }
}
