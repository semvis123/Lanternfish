import Synchronization

/// A thread-safe "was cancelled" bit that blocking work on GCD threads can poll; set it from a
/// task cancellation handler.
final class CancellationFlag: Sendable {
    private let flag = Atomic<Bool>(false)

    var isCancelled: Bool { flag.load(ordering: .acquiring) }

    func cancel() { flag.store(true, ordering: .releasing) }
}
