import Foundation
import Testing

@testable import LanternfishKit

/// Edge cases of the scan engine: arithmetic that must not trap, ICMP reply matching, cancellation.
@Suite(.timeLimit(.minutes(1)))
struct EngineHardeningTests {
    // MARK: Duration clamping

    @Test func durationClampingNeverTraps() {
        #expect(Duration.seconds(Int64.max).clampedNanoseconds == .max)
        #expect(Duration.seconds(Int64.max).clampedMilliseconds == Int(Int64.max / 1_000_000))
        #expect(Duration.seconds(-5).clampedNanoseconds == 0)
        #expect(Duration.milliseconds(-1).clampedMilliseconds == 0)
        #expect(Duration.milliseconds(1500).clampedNanoseconds == 1_500_000_000)
        #expect(Duration.milliseconds(1500).clampedMilliseconds == 1500)
        // Just under the overflow edge for seconds * 1e9, plus attoseconds pushing it over.
        let edge = Duration(secondsComponent: Int64.max / 1_000_000_000, attosecondsComponent: 999_999_999_999_999_999)
        #expect(edge.clampedNanoseconds == .max)
        #expect(Duration.seconds(Int64.max).dispatchInterval == .nanoseconds(Int.max))
        #expect(Duration.seconds(-1).dispatchInterval == .nanoseconds(0))
    }

    // MARK: Sweep echo matching

    @Test func ledgerMeasuresRTTFromTheMatchingSend() {
        let ip = IPv4Address("192.168.1.10")!
        let other = IPv4Address("192.168.1.11")!
        let t0 = ContinuousClock.now
        var ledger = EchoLedger(firstSequence: 100)
        let first = ledger.recordSend(to: ip, at: t0)
        let retry = ledger.recordSend(to: ip, at: t0 + .milliseconds(250))
        let otherSeq = ledger.recordSend(to: other, at: t0 + .milliseconds(250))
        #expect(first == 101 && retry == 102 && otherSeq == 103)

        // The reply to the retry is timed from the retry, not from the first send.
        #expect(ledger.rtt(from: ip, sequence: retry, at: t0 + .milliseconds(260)) == .milliseconds(10))
        // A late reply to the first request is timed from the first request.
        #expect(ledger.rtt(from: ip, sequence: first, at: t0 + .milliseconds(300)) == .milliseconds(300))
        // A sequence that belongs to another host falls back to the latest send to the replier.
        #expect(ledger.rtt(from: ip, sequence: otherSeq, at: t0 + .milliseconds(270)) == .milliseconds(20))
        // Never pinged: no RTT.
        #expect(ledger.rtt(from: IPv4Address("10.0.0.1")!, sequence: 1, at: t0) == nil)
    }

    @Test func ledgerSequenceWrapsWithoutTrapping() {
        var ledger = EchoLedger(firstSequence: .max)
        #expect(ledger.recordSend(to: IPv4Address("10.0.0.1")!, at: .now) == 0)
    }

    @Test func echoMatchingRequiresOurToken() {
        let token = ICMPPacket.makeToken(prefix: "SKsweep")
        #expect(token.count == 16 && token.starts(with: Array("SKsweep".utf8)))
        var foreign = token
        foreign[15] ^= 0xFF
        #expect(ICMPPacket.matches(.init(identifier: 7, sequence: 1, payload: token), token: token, identifier: 9))
        // Another socket's sweep (same prefix, different random tail) is not ours even with our identifier.
        #expect(!ICMPPacket.matches(.init(identifier: 9, sequence: 1, payload: foreign), token: token, identifier: 9))
        // Truncated payload: fall back to the identifier.
        #expect(ICMPPacket.matches(.init(identifier: 9, sequence: 1, payload: [1, 2]), token: token, identifier: 9))
        #expect(!ICMPPacket.matches(.init(identifier: 8, sequence: 1, payload: [1, 2]), token: token, identifier: 9))
    }

    // MARK: Reverse DNS

    @Test func reverseDNSCleansTargets() {
        let ip = IPv4Address("192.168.1.5")!
        #expect(ReverseDNS.clean("nas.lan.", ip: ip) == "nas.lan")
        #expect(ReverseDNS.clean("...", ip: ip) == nil)
        #expect(ReverseDNS.clean("192.168.1.5.", ip: ip) == nil)
    }

    @Test func reverseDNSReturnsPromptlyWhenCancelled() async {
        let start = ContinuousClock.now
        let task = Task { await ReverseDNS.lookup(IPv4Address("192.0.2.1")!, timeout: .seconds(30)) }
        try? await Task.sleep(for: .milliseconds(20))
        task.cancel()
        let name = await task.value
        #expect(name == nil)
        #expect(ContinuousClock.now - start < .seconds(5))
    }

    @Test func reverseDNSAlreadyCancelledReturnsNil() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await ReverseDNS.lookup(IPv4Address("192.0.2.1")!, timeout: .seconds(30))
        }
        #expect(await task.value == nil)
    }

    @Test func manyConcurrentReverseLookupsDoNotPileUp() async {
        // 200 unresolvable lookups with a short timeout must all finish around the timeout,
        // not serialize behind blocked threads.
        let start = ContinuousClock.now
        await withTaskGroup(of: Void.self) { group in
            for i in 1...200 {
                group.addTask { _ = await ReverseDNS.lookup(IPv4Address("192.0.2.\(i)")!, timeout: .milliseconds(300)) }
            }
        }
        #expect(ContinuousClock.now - start < .seconds(5))
    }

    // MARK: LANIO

    @Test func lanioCancelledBeforeStartReturnsNil() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await LANIO.readGreeting(IPv4Address("192.0.2.1")!, port: 22, timeout: .seconds(30))
        }
        #expect(await task.value == nil)
    }

    @Test func lanioCancelledMidwayReturnsPromptly() async {
        let start = ContinuousClock.now
        let task = Task { await LANIO.readGreeting(IPv4Address("192.0.2.1")!, port: 22, timeout: .seconds(30)) }
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()
        #expect(await task.value == nil)
        #expect(ContinuousClock.now - start < .seconds(5))
    }

    // MARK: Wi-Fi async scan

    @Test func asyncWiFiScanOfUnknownInterfaceThrows() async {
        // The async overload hops to its own queue and must surface the sync API's errors.
        await #expect(throws: WiFiScanError.self) {
            try await WiFiScanner.scan(interfaceName: "definitely-not-an-interface0")
        }
    }
}
