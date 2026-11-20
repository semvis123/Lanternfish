import Foundation
import Testing

@testable import LanternfishKit

@Suite struct LocalDNSTests {
    @Test func reverseNames() {
        let ip = IPv4Address("10.0.0.3")!
        #expect(LocalDNS.reverseName(ip) == "3.0.0.10.in-addr.arpa")
        #expect(LocalDNS.ip(fromReverseName: "3.0.0.10.in-addr.arpa.") == ip)
        #expect(LocalDNS.ip(fromReverseName: "3.0.0.10.IN-ADDR.ARPA") == ip)
        #expect(LocalDNS.ip(fromReverseName: "example.com") == nil)
        #expect(LocalDNS.ip(fromReverseName: "0.10.in-addr.arpa") == nil)
    }

    @Test func queryEncoding() {
        let q = [UInt8](LocalDNS.ptrQuery(IPv4Address("1.2.3.4")!, id: 0xBEEF, unicastResponse: true))
        #expect(q[0] == 0xBE && q[1] == 0xEF)
        #expect(q[2] == 0 && q[5] == 1)  // no RD, one question
        // "4.3.2.1.in-addr.arpa" = 1+1 +1+1 +1+1 +1+1 +1+7 +1+4 +1 = 22 bytes
        let qname = Array(q[12..<34])
        #expect(
            qname == [1, 0x34, 1, 0x33, 1, 0x32, 1, 0x31, 7] + Array("in-addr".utf8) + [4] + Array("arpa".utf8) + [0])
        #expect(Array(q[34...]) == [0x00, 0x0C, 0x80, 0x01])  // PTR, QU|IN
        let multi = [UInt8](LocalDNS.query(names: ["a.local", "b.local"], id: 0))
        #expect(multi[5] == 2)
    }

    /// A captured-style response: question + compressed PTR answer pointing back at the question.
    static func response(id: UInt16, ip: String, target: String) -> Data {
        let q = [UInt8](LocalDNS.ptrQuery(IPv4Address(ip)!, id: id))
        var b = q
        b[2] = 0x81
        b[3] = 0x80  // response, RD, RA
        b[7] = 1  // one answer
        b += [0xC0, 0x0C, 0x00, 0x0C, 0x00, 0x01, 0, 0, 0x0E, 0x10]
        let rdata = LocalDNS.encodeName(target)
        b += [UInt8(rdata.count >> 8), UInt8(rdata.count & 0xFF)] + rdata
        return Data(b)
    }

    @Test func parsesCompressedPTRAnswer() throws {
        let data = Self.response(id: 7, ip: "10.0.0.2", target: "Archer_AX10")
        let parsed = try #require(LocalDNS.parseResponse(data))
        #expect(parsed.id == 7)
        #expect(parsed.records == [LocalDNS.Record(name: "2.0.0.10.in-addr.arpa", type: 12, target: "Archer_AX10")])
        let answers = LocalDNS.ptrAnswers(data)
        #expect(answers.count == 1)
        #expect(answers.first?.0 == IPv4Address("10.0.0.2"))
        #expect(answers.first?.1 == "Archer_AX10")
    }

    @Test func rejectsGarbageAndQueries() {
        #expect(LocalDNS.parseResponse(Data()) == nil)
        #expect(LocalDNS.parseResponse(Data([0, 1, 2])) == nil)
        // A query (QR bit clear) is not a response.
        #expect(LocalDNS.parseResponse(LocalDNS.ptrQuery(IPv4Address("10.0.0.1")!, id: 1)) == nil)
        // Truncated answer: no crash, no records.
        let full = [UInt8](Self.response(id: 1, ip: "10.0.0.9", target: "Galaxy-XCover-5"))
        #expect(LocalDNS.ptrAnswers(Data(full.prefix(full.count - 5))).isEmpty)
        // Compression loop.
        var loop = [UInt8](repeating: 0, count: 12)
        loop[2] = 0x80
        loop[7] = 1
        loop += [0xC0, 12]
        #expect(LocalDNS.ptrAnswers(Data(loop)).isEmpty)
    }

    @Test(arguments: [
        ("Archer_AX10.", "Archer_AX10"),
        ("RAX40.home.", "RAX40.home"),
        ("iPad-van-Alex.local.", "iPad-van-Alex.local"),
        ("Galaxy-XCover-5", "Galaxy-XCover-5"),
        ("qb-102030405060-1234A56XYZ.", "qb-102030405060-1234A56XYZ"),
        ("esp32-A1B2C3.home.", "esp32-A1B2C3.home"),
    ])
    func keepsUsefulNames(_ raw: String, _ expected: String) {
        #expect(LocalDNS.cleanHostname(raw, ip: IPv4Address("10.0.0.5")!) == expected)
    }

    @Test(arguments: [
        "www.routerlogin.com.", "home.", "(none).local.", "wlan0.home.", "localhost", "Android.local.",
        "10-0-0-5.home", "dhcp-10-0-0-5", "e848b843df65", "5.0.0.10.in-addr.arpa", "", "host.isp.example.net",
    ])
    func dropsJunk(_ raw: String) {
        #expect(LocalDNS.cleanHostname(raw, ip: IPv4Address("10.0.0.5")!) == nil)
    }

    @Test func bestPrefersMDNS() {
        #expect(LocalDNS.best([.routerDNS: "iPad", .mdns: "iPad-van-Alex.local"])?.name == "iPad-van-Alex.local")
        #expect(LocalDNS.best([.routerDNS: "iPad", .llmnr: "IPAD"])?.source == .routerDNS)
        #expect(LocalDNS.best([:]) == nil)
    }

    @Test func trustsAnswersOnlyFromTheRightSender() {
        let host = IPv4Address("10.0.0.20")!
        let other = IPv4Address("10.0.0.66")!
        let router = IPv4Address("10.0.0.1")!
        func reply(_ from: IPv4Address, _ port: UInt16, _ target: String) -> UDPBatch.Reply {
            UDPBatch.Reply(from: from, port: port, data: Self.response(id: 1, ip: "10.0.0.20", target: target))
        }
        // LLMNR answered by a different host is ignored; mDNS from the host itself beats a third party.
        let names = LocalDNS.names(
            from: [
                reply(other, 5355, "Spoofed"), reply(host, 5355, "DESKTOP-1"),
                reply(other, 5353, "Imposter"), reply(host, 5353, "Real-Mac"),
                reply(router, 53, "laptop"), reply(other, 53, "NotTheRouter"),
            ], wanted: [host], dnsServers: [router])
        #expect(names[host] == [.llmnr: "DESKTOP-1", .mdns: "Real-Mac", .routerDNS: "laptop"])
        // Only a third party (e.g. a sleep proxy) answered over mDNS: still used. LLMNR isn't.
        let proxied = LocalDNS.names(
            from: [reply(other, 5353, "Sleepy-Mac"), reply(other, 5355, "Spoofed")],
            wanted: [host], dnsServers: [router])
        #expect(proxied[host] == [.mdns: "Sleepy-Mac"])
    }

    @Test func ignoresRepliesToQueriesWeDidNotSend() {
        let host = IPv4Address("10.0.0.20")!
        let router = IPv4Address("10.0.0.1")!
        let forged = UDPBatch.Reply(
            from: router, port: 53, data: Self.response(id: 999, ip: "10.0.0.20", target: "forged"))
        let real = UDPBatch.Reply(from: router, port: 53, data: Self.response(id: 7, ip: "10.0.0.20", target: "laptop"))
        let names = LocalDNS.names(from: [forged, real], wanted: [host], dnsServers: [router], sentIDs: [7])
        #expect(names[host] == [.routerDNS: "laptop"])
    }

    @Test(.timeLimit(.minutes(1))) func batchExchangeStopsWhenCancelled() async {
        // Nothing answers on this port: without cancellation support it would wait the full 20 s.
        let clock = ContinuousClock()
        let start = clock.now
        let task = Task {
            await UDPBatch.exchange(
                [(IPv4Address("127.0.0.1")!, 9, Data([0]))], interfaceAddress: nil,
                timeout: .seconds(20))
        }
        try? await Task.sleep(for: .milliseconds(200))
        task.cancel()
        _ = await task.value
        #expect(clock.now - start < .seconds(5))
    }

    /// Talks to a throwaway UDP "DNS server" on loopback, end to end through the batch socket.
    @Test(.timeLimit(.minutes(1))) func batchLookupAgainstLoopbackServer() async throws {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        try #require(fd >= 0)
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        try #require(bound == 0)
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        let port = UInt16(bigEndian: addr.sin_port)
        // Echo server: answer every query with a PTR built from the question.
        let server = Thread {
            var buf = [UInt8](repeating: 0, count: 2048)
            var tv = timeval(tv_sec: 3, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            for _ in 0..<4 {
                var from = sockaddr_in()
                var flen = socklen_t(MemoryLayout<sockaddr_in>.size)
                let n = withUnsafeMutablePointer(to: &from) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buf, buf.count, 0, $0, &flen) }
                }
                guard n > 0 else { return }
                var r = Array(buf[0..<n])
                r[2] = 0x81
                r[3] = 0x80
                r[7] = 1
                let target = LocalDNS.encodeName("host\(r[12 + 1] - 0x30)")
                r += [0xC0, 0x0C, 0x00, 0x0C, 0x00, 0x01, 0, 0, 0, 60, 0, UInt8(target.count)] + target
                _ = withUnsafePointer(to: &from) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(fd, r, r.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
        }
        server.start()
        let ips = [IPv4Address("127.0.0.1")!, IPv4Address("127.0.0.2")!]
        let replies = await UDPBatch.exchange(
            ips.map { (IPv4Address("127.0.0.1")!, port, LocalDNS.ptrQuery($0, id: 1)) },
            interfaceAddress: nil, timeout: .milliseconds(500))
        let names = Dictionary(replies.flatMap { LocalDNS.ptrAnswers($0.data) }, uniquingKeysWith: { a, _ in a })
        #expect(names[IPv4Address("127.0.0.1")!] == "host1")
        #expect(names[IPv4Address("127.0.0.2")!] == "host2")
        #expect(replies.allSatisfy { $0.port == port })
    }
}
