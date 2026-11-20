import Darwin
import Foundation
import Testing

@testable import LanternfishKit

/// A listening TCP socket on 127.0.0.1 with an ephemeral port.
private final class LocalListener {
    let fd: Int32
    let port: UInt16

    init(backlog: Int32 = 16) throws {
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { throw POSIXError(.EBADF) }
        var addr = sockaddr_in.make(IPv4Address("127.0.0.1")!, port: 0)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, backlog) == 0 else {
            close(fd)
            throw POSIXError(.EADDRINUSE)
        }
        var out = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &out) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        self.fd = fd
        self.port = UInt16(bigEndian: out.sin_port)
    }

    func stop() { close(fd) }
}

/// Accepts (and immediately closes) every connection queued on a listening socket, so its
/// listen queue never fills up. Takes ownership of the listener: `stop()` closes it once the
/// read source is cancelled (closing it earlier would race the source).
private final class AcceptDrain: @unchecked Sendable {
    private let source: DispatchSourceRead

    init(_ listener: LocalListener) {
        let fd = listener.fd
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global(qos: .userInitiated))
        source.setEventHandler {
            while true {
                let c = accept(fd, nil, nil)
                guard c >= 0 else { break }
                close(c)
            }
        }
        source.setCancelHandler { listener.stop() }
        source.activate()
    }

    func stop() { source.cancel() }
}

private let localhost = IPv4Address("127.0.0.1")!

@Suite struct ScanTests {
    @Test func probeOpenPort() async throws {
        let listener = try LocalListener()
        defer { listener.stop() }
        #expect(await TCPProbe.probe(localhost, port: listener.port, timeout: .seconds(1)) == .open)
    }

    @Test func probeClosedPortIsRefused() async throws {
        let listener = try LocalListener()
        let port = listener.port
        listener.stop()
        #expect(await TCPProbe.probe(localhost, port: port, timeout: .seconds(1)) == .refused)
    }

    @Test func probeUnroutableTimesOut() async {
        // TEST-NET-1, should never answer.
        let start = ContinuousClock.now
        let result = await TCPProbe.probe(IPv4Address("192.0.2.1")!, port: 80, timeout: .milliseconds(200))
        #expect(result == .timeout)
        #expect(ContinuousClock.now - start < .seconds(2))
    }

    @Test func probeCancellationReturnsPromptly() async {
        let task = Task {
            await TCPProbe.probe(IPv4Address("192.0.2.1")!, port: 80, timeout: .seconds(30))
        }
        try? await Task.sleep(for: .milliseconds(50))
        let start = ContinuousClock.now
        task.cancel()
        #expect(await task.value == .timeout)
        #expect(ContinuousClock.now - start < .seconds(1))
    }

    /// 300 probes in flight at once must all see the open port.
    ///
    /// The listeners never block the probes: a listen queue that fills up makes the kernel
    /// reset new connections (ECONNRESET → `.timeout`), which makes the test flaky on a busy
    /// machine. So the probes are spread over three listeners whose queues
    /// (capped at `somaxconn`, 128) can each hold all of their probes even if nothing is ever
    /// accepted, and accepted connections are drained anyway. The timeout is generous: this
    /// checks correctness, not speed.
    @Test func manyConcurrentProbes() async throws {
        FileDescriptorLimit.raiseOnce()
        #expect(FileDescriptorLimit.current >= 1024)
        let listeners = try (0..<3).map { _ in try LocalListener(backlog: SOMAXCONN) }
        let drains = listeners.map(AcceptDrain.init)
        defer { for drain in drains { drain.stop() } }
        let ports = listeners.map(\.port)
        let results = await withTaskGroup(of: TCPProbe.Outcome.self) { group in
            for i in 0..<300 {
                let port = ports[i % ports.count]
                group.addTask { await TCPProbe.probeDetailed(localhost, port: port, timeout: .seconds(15)) }
            }
            return await group.reduce(into: [TCPProbe.Outcome]()) { $0.append($1) }
        }
        #expect(results.count == 300)
        let failures = results.filter { $0.result != .open }
        #expect(failures.isEmpty, "\(failures.count) probes failed, errnos: \(Set(failures.map(\.errno)).sorted())")
    }

    @Test func portScannerReportsOnlyOpenPort() async throws {
        let open = try LocalListener()
        defer { open.stop() }
        let closed = try LocalListener()
        let closedPort = closed.port
        closed.stop()

        let progress = ProgressBox()
        var found: [OpenPort] = []
        for await p in PortScanner().scan(
            localhost, ports: [open.port, closedPort],
            progress: { progress.append($0) })
        {
            found.append(p)
        }
        #expect(found.map(\.port) == [open.port])
        #expect(progress.values.last == 1)
    }

    @Test func portScannerFillsServiceNames() async throws {
        #expect(OpenPort(port: 22, service: CommonPorts.all[22]).service == "SSH")
    }

    @Test func portScannerCancellationStops() async {
        let ports = Array(UInt16(1)...2000)
        let start = ContinuousClock.now
        let task = Task {
            var n = 0
            for await _ in PortScanner(concurrency: 16, timeout: .seconds(5)).scan(
                IPv4Address("192.0.2.1")!, ports: ports)
            {
                n += 1
            }
            return n
        }
        try? await Task.sleep(for: .milliseconds(100))
        task.cancel()
        _ = await task.value
        #expect(ContinuousClock.now - start < .seconds(2))
    }

    @Test func sweepLocalhostYieldsOnce() async {
        var patches: [DevicePatch] = []
        for await p in HostDiscovery().sweep([localhost, localhost]) { patches.append(p) }
        #expect(patches.count == 1)
        #expect(patches.first?.ip == localhost)
        #expect(patches.first?.responseTime != nil)
    }

    /// A host that ignores ping but RSTs a closed port is alive.
    @Test func sweepCountsRefusedAsAlive() async {
        var discovery = HostDiscovery()
        discovery.useICMP = false
        var patches: [DevicePatch] = []
        for await p in discovery.sweep([localhost]) { patches.append(p) }
        #expect(patches.count == 1)
        #expect(patches.first?.responseTime != nil)
    }

    @Test func sweepCancellationStops() async {
        // TEST-NET-2: never answers, so only cancellation can end this quickly.
        let hosts = (1...50).map { IPv4Address(0xC633_6400 | UInt32($0)) }
        let start = ContinuousClock.now
        let task = Task {
            for await _ in HostDiscovery(timeout: .seconds(10)).sweep(hosts) {}
        }
        try? await Task.sleep(for: .milliseconds(100))
        task.cancel()
        await task.value
        #expect(ContinuousClock.now - start < .seconds(2))
    }

    @Test func sweepEmptyFinishes() async {
        var n = 0
        for await _ in HostDiscovery().sweep([]) { n += 1 }
        #expect(n == 0)
    }

    @Test func icmpParsing() {
        let req = ICMPPacket.echoRequest(identifier: 0x1234, sequence: 1)
        #expect(ICMPPacket.checksum(req) == 0)
        var reply = req
        reply[0] = 0
        #expect(ICMPPacket.parseEchoReply(reply[...]) != nil)
        let ipHeader: [UInt8] = [0x45] + Array(repeating: 0, count: 19)
        #expect(ICMPPacket.parseEchoReply((ipHeader + reply)[...]) != nil)
        #expect(ICMPPacket.parseEchoReply((ipHeader + req)[...]) == nil)
    }

    @Test func commonPorts() {
        #expect(CommonPorts.all.count >= 90)
        #expect(CommonPorts.all[443] == "HTTPS")
        #expect(CommonPorts.all[9100] == "Raw Print")
        #expect(CommonPorts.sortedPorts == CommonPorts.all.keys.sorted())
    }

    /// Manual smoke test of the real LAN: `LANTERNFISHKIT_LAN=192.168.1.0 swift test --filter lanSmoke`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LANTERNFISHKIT_LAN"] != nil))
    func lanSmoke() async {
        let base = IPv4Address(ProcessInfo.processInfo.environment["LANTERNFISHKIT_LAN"]!)!
        let hosts = Subnet(address: base, prefixLength: 24).scanHosts()
        func openFDs() -> Int { (0..<4096).filter { fcntl(Int32($0), F_GETFD) != -1 }.count }
        let fdsBefore = openFDs()
        let start = ContinuousClock.now
        var first: Duration?
        var found: [(IPv4Address, Duration)] = []
        for await p in HostDiscovery().sweep(hosts) {
            if first == nil { first = ContinuousClock.now - start }
            found.append((p.ip, p.responseTime!))
        }
        let total = ContinuousClock.now - start
        try? await Task.sleep(for: .milliseconds(100))
        print("open fds before \(fdsBefore), after \(openFDs())")
        print("LAN sweep: \(found.count) hosts, first after \(first.map { "\($0)" } ?? "-"), done in \(total)")
        for (ip, rtt) in found.sorted(by: { $0.0 < $1.0 }) { print("  \(ip)  \(rtt)") }
    }

    /// Manual full port scan: `LANTERNFISHKIT_PORTSCAN=192.168.1.1 swift test --filter fullPortScanSmoke`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LANTERNFISHKIT_PORTSCAN"] != nil))
    func fullPortScanSmoke() async {
        let ip = IPv4Address(ProcessInfo.processInfo.environment["LANTERNFISHKIT_PORTSCAN"]!)!
        let concurrency = Int(ProcessInfo.processInfo.environment["LANTERNFISHKIT_CONCURRENCY"] ?? "") ?? 64
        let start = ContinuousClock.now
        var open: [OpenPort] = []
        for await p in PortScanner(concurrency: concurrency).scan(ip, ports: Array(1...65535)) {
            open.append(p)
        }
        print(
            "Full scan of \(ip) @\(concurrency): \(open.sorted().map { "\($0.port)" }) in \(ContinuousClock.now - start)"
        )
    }
}

private final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [Double] = []
    func append(_ v: Double) { lock.withLock { _values.append(v) } }
    var values: [Double] { lock.withLock { _values } }
}
