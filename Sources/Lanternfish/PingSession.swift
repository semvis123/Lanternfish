import LanternfishKit

/// A ping session's recent results plus running totals.
struct PingSession: Equatable {
    /// The most recent results, oldest first (at most `PingSession.capacity`).
    private(set) var results: [PingResult] = []
    var isRunning: Bool

    static let capacity = 120

    private(set) var sent = 0
    private(set) var received = 0
    private(set) var min: Duration?
    private(set) var max: Duration?
    private var total: Duration = .zero

    init(isRunning: Bool) {
        self.isRunning = isRunning
    }

    mutating func append(_ result: PingResult) {
        results.append(result)
        if results.count > Self.capacity { results.removeFirst(results.count - Self.capacity) }
        sent += 1
        guard let rtt = result.rtt else { return }
        received += 1
        total += rtt
        min = Swift.min(min ?? rtt, rtt)
        max = Swift.max(max ?? rtt, rtt)
    }

    var avg: Duration? { received > 0 ? total / received : nil }
    var last: PingResult? { results.last }
    /// Packet loss over the whole session, 0...100.
    var lossPercent: Double { sent > 0 ? Double(sent - received) / Double(sent) * 100 : 0 }
}
