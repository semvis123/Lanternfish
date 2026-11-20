import Foundation
import Testing

@testable import LanternfishKit

@Suite(.timeLimit(.minutes(1)))
struct TracerouteTests {
    private func bytes(_ hex: String) -> ArraySlice<UInt8> {
        var out: [UInt8] = []
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            out.append(UInt8(hex[i..<j], radix: 16)!)
            i = j
        }
        return out[...]
    }

    // MARK: Parsing (packets captured from a real SOCK_DGRAM ICMP socket on macOS)

    @Test func parsesTimeExceededWithFullQuote() {
        // From 192.168.1.1: Time Exceeded quoting echo id 0x1234 seq 1 to 1.1.1.1, with payload.
        let packet = bytes(
            "45c03400c2a800004001331cc0a80101c0a801df0b00f4ff0000000045002c00d9ca000001011b7ec0a801df"
                + "0101010108009a2b12340001534b74726163652d")
        #expect(
            TracerouteResponse.parse(packet)
                == .error(
                    type: 11, code: 0,
                    originalDestination: IPv4Address("1.1.1.1")!,
                    identifier: 0x1234, sequence: 1))
    }

    @Test func parsesTimeExceededWithMinimalQuote() {
        // Router that quotes only the IP header + 8 bytes (RFC 792 minimum).
        let packet = bytes(
            "4500240000000000f701b93754f1f314c0a801df0b00409f0000000045002c00f1de00000101036ac0a801df"
                + "0101010108009a221234000a")
        #expect(
            TracerouteResponse.parse(packet)
                == .error(
                    type: 11, code: 0,
                    originalDestination: IPv4Address("1.1.1.1")!,
                    identifier: 0x1234, sequence: 10))
    }

    @Test func parsesTimeExceededWithoutOuterIPHeader() {
        let packet = bytes("0b00409f0000000045002c00f1de00000101036ac0a801df0101010108009a221234000a")
        #expect(
            TracerouteResponse.parse(packet)
                == .error(
                    type: 11, code: 0,
                    originalDestination: IPv4Address("1.1.1.1")!,
                    identifier: 0x1234, sequence: 10))
    }

    @Test func parsesDestinationUnreachable() {
        // Host unreachable (3/1) quoting echo id 0xBEEF seq 7 to 10.0.0.9.
        let packet = bytes(
            "0301000000000000" + "45000024000000000101" + "0000" + "0a000001" + "0a000009"
                + "08000000beef0007")
        #expect(
            TracerouteResponse.parse(packet)
                == .error(
                    type: 3, code: 1,
                    originalDestination: IPv4Address("10.0.0.9")!,
                    identifier: 0xBEEF, sequence: 7))
    }

    @Test func parsesEchoReply() {
        let packet = ICMPPacket.echoRequest(identifier: 0x0102, sequence: 0x0304, payload: [9, 9])
        var reply = packet
        reply[0] = 0
        #expect(
            TracerouteResponse.parse(reply[...])
                == .echoReply(
                    identifier: 0x0102, sequence: 0x0304,
                    payload: [9, 9]))
    }

    @Test func rejectsOtherMessages() {
        // Echo request (type 8), a Time Exceeded quoting UDP, and truncated quotes.
        #expect(TracerouteResponse.parse(ICMPPacket.echoRequest(identifier: 1, sequence: 1)[...]) == nil)
        let udpQuote = bytes("0b000000000000004500001c000000000111000000000000a0a0a0a0" + "0000000000000000")
        #expect(TracerouteResponse.parse(udpQuote) == nil)
        #expect(TracerouteResponse.parse(bytes("0b00409f0000000045002c00f1de0000")) == nil)
        #expect(
            TracerouteResponse.parse(bytes("0b00409f0000000045002c00f1de00000101036ac0a801df01010101080000")) == nil)
        #expect(TracerouteResponse.parse([]) == nil)
    }

    @Test func averageIgnoresTimeouts() {
        let hop = TracerouteHop(ttl: 1, rtts: [.milliseconds(10), nil, .milliseconds(20)])
        #expect(hop.averageRTT == .milliseconds(15))
        #expect(TracerouteHop(ttl: 2, rtts: [nil, nil]).averageRTT == nil)
    }

    // MARK: Live

    private func run(_ host: String, _ tr: Traceroute = Traceroute()) async -> (
        IPv4Address?, [Int: TracerouteHop], Bool?, String?
    ) {
        var resolved: IPv4Address?
        var hops: [Int: TracerouteHop] = [:]
        var reached: Bool?
        var failure: String?
        for await e in tr.trace(host) {
            switch e {
            case .resolved(let ip): resolved = ip
            case .hop(let h): hops[h.ttl] = h
            case .finished(let r): reached = r
            case .failed(let m): failure = m
            }
        }
        return (resolved, hops, reached, failure)
    }

    @Test func tracesLoopbackInOneHop() async {
        let (ip, hops, reached, failure) = await run("127.0.0.1")
        #expect(failure == nil)
        #expect(ip == IPv4Address("127.0.0.1"))
        #expect(reached == true)
        #expect(hops.keys.sorted() == [1])
        #expect(hops[1]?.address == IPv4Address("127.0.0.1"))
        #expect(hops[1]?.rtts.count == 3)
        #expect(hops[1]?.rtts.allSatisfy { $0 != nil } == true)
    }

    @Test func resolvesLocalhostName() async {
        let (ip, _, reached, _) = await run("localhost", Traceroute(maxHops: 3, probesPerHop: 1))
        #expect(ip == IPv4Address("127.0.0.1"))
        #expect(reached == true)
    }

    @Test func failsOnUnresolvableHost() async {
        let (ip, _, reached, failure) = await run("no-such-host.invalid")
        #expect(ip == nil)
        #expect(reached == nil)
        #expect(failure != nil)
    }

    /// `LANTERNFISHKIT_TRACE=1 swift test --filter TracerouteTests` prints a real trace to 1.1.1.1
    /// (or `LANTERNFISHKIT_TRACE_HOST`; per-probe timeout in seconds via `LANTERNFISHKIT_TRACE_TIMEOUT`).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LANTERNFISHKIT_TRACE"] == "1"))
    func liveTrace() async {
        let env = ProcessInfo.processInfo.environment
        let host = env["LANTERNFISHKIT_TRACE_HOST"] ?? "1.1.1.1"
        let timeout = env["LANTERNFISHKIT_TRACE_TIMEOUT"].flatMap(Double.init) ?? 1
        let start = ContinuousClock.now
        let (ip, hops, reached, failure) = await run(host, Traceroute(timeout: .milliseconds(Int(timeout * 1000))))
        let elapsed = ContinuousClock.now - start
        print("traceroute to \(host) (\(ip.map(String.init(describing:)) ?? "?")) — \(elapsed)")
        let last = hops.values.first { $0.address == ip }?.ttl ?? hops.keys.max() ?? 0
        for ttl in hops.keys.sorted() where ttl <= last {
            let h = hops[ttl]!
            let rtts = h.rtts.map {
                $0.map {
                    String(
                        format: "%.2f ms",
                        Double($0.components.attoseconds) / 1e15 + Double($0.components.seconds) * 1000)
                } ?? "*"
            }
            print(
                String(format: "%2d  ", ttl)
                    + "\(h.address.map(String.init(describing:)) ?? "*")  \(h.hostname ?? "")  \(rtts.joined(separator: "  "))"
            )
        }
        print("reached: \(reached.map(String.init(describing:)) ?? "nil") failure: \(failure ?? "none")")
        #expect(reached == true)
    }
}
