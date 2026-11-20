import Foundation
import Testing

@testable import LanternfishKit

@Suite(.timeLimit(.minutes(1)))
struct PingerTests {
    /// Collects up to `count` results or stops after `deadline`, whichever comes first.
    private func collect(_ stream: AsyncStream<PingResult>, count: Int, deadline: Duration) async -> [PingResult] {
        await withTaskGroup(of: [PingResult]?.self) { group in
            group.addTask {
                var out: [PingResult] = []
                for await r in stream {
                    out.append(r)
                    if out.count >= count { break }
                }
                return out
            }
            group.addTask {
                try? await Task.sleep(for: deadline)
                return nil
            }
            var result: [PingResult] = []
            while let next = await group.next() {
                if let next { result = next }
                group.cancelAll()
                if next != nil { break }
            }
            return result
        }
    }

    @Test func pingLoopback() async {
        let pinger = Pinger(interval: .milliseconds(500), timeout: .seconds(1))
        let results = await collect(pinger.ping(IPv4Address("127.0.0.1")!), count: 3, deadline: .seconds(4))
        #expect(results.count >= 3)
        #expect(results.allSatisfy { $0.rtt != nil })
        #expect(results.map(\.sequence) == Array(0..<results.count))
        for r in results {
            if let rtt = r.rtt { #expect(rtt < .seconds(1)) }
        }
    }

    @Test func concurrentSessionsDoNotStealReplies() async {
        let pinger = Pinger(interval: .milliseconds(200), timeout: .seconds(1))
        let ip = IPv4Address("127.0.0.1")!
        async let a = collect(pinger.ping(ip), count: 5, deadline: .seconds(4))
        async let b = collect(pinger.ping(ip), count: 5, deadline: .seconds(4))
        let (ra, rb) = await (a, b)
        #expect(ra.count == 5 && rb.count == 5)
        #expect(ra.allSatisfy { $0.rtt != nil })
        #expect(rb.allSatisfy { $0.rtt != nil })
    }

    @Test func blackholeTimesOut() async {
        // TEST-NET-1 (RFC 5737): never routed, so every request times out.
        let pinger = Pinger(interval: .milliseconds(250), timeout: .milliseconds(250))
        let results = await collect(pinger.ping(IPv4Address("192.0.2.1")!), count: 3, deadline: .seconds(4))
        #expect(results.count == 3)
        #expect(results.allSatisfy { $0.rtt == nil })
        #expect(results.map(\.sequence) == [0, 1, 2])
        #expect(zip(results, results.dropFirst()).allSatisfy { $0.date < $1.date })
    }

    @Test func cancellationStopsStream() async {
        let pinger = Pinger(interval: .milliseconds(100), timeout: .milliseconds(500))
        let counter = Counter()
        let task = Task {
            for await _ in pinger.ping(IPv4Address("127.0.0.1")!) { counter.increment() }
            return true
        }
        try? await Task.sleep(for: .milliseconds(450))
        task.cancel()
        let finished = await task.value
        #expect(finished)
        let atCancel = counter.value
        #expect(atCancel >= 1)
        try? await Task.sleep(for: .milliseconds(400))
        #expect(counter.value == atCancel)
    }

    @Test func replyMatching() {
        let session = EchoSession(target: IPv4Address("127.0.0.1")!)!
        defer { session.invalidate() }
        let ours = ICMPPacket.EchoReply(identifier: 1, sequence: 1, payload: session.token)
        #expect(session.matches(ours))
        // Identifier rewritten by the kernel: the token still matches.
        #expect(session.matches(.init(identifier: session.identifier &+ 7, sequence: 1, payload: session.token)))
        // Another session's reply (different token) is rejected even with our identifier.
        #expect(
            !session.matches(
                .init(
                    identifier: session.identifier, sequence: 1,
                    payload: Array("SKping".utf8) + Array(repeating: 0, count: 10))))
        // Parsing round-trips through an echo request turned into a reply.
        var packet = ICMPPacket.echoRequest(identifier: 0xBEEF, sequence: 42, payload: session.token)
        packet[0] = 0
        let parsed = ICMPPacket.parseEchoReply(([0x45] + Array(repeating: 0, count: 19) + packet)[...])
        #expect(parsed == .init(identifier: 0xBEEF, sequence: 42, payload: session.token))
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func increment() { lock.withLock { n += 1 } }
    var value: Int { lock.withLock { n } }
}
