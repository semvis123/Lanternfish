import Foundation
import Network
import Synchronization
import Testing

@testable import LanternfishKit

@Suite struct ServiceProbeParsingTests {
    // MARK: Banner display

    @Test func escapesBanner() {
        let data = Data("SSH-2.0-OpenSSH_9.6\r\n".utf8) + Data([0x00, 0x14, 0xFF]) + Data("ok\tx\r".utf8)
        #expect(ServiceProbe.escapePrintable(data) == "SSH-2.0-OpenSSH_9.6\n\\x00\\x14\\xFFok\tx\\r")
    }

    @Test func hexDumpsLikeHexdumpC() {
        let dump = ServiceProbe.hexDump(Data("SSH-2.0-OpenSSH_9.6\r\n".utf8))
        let lines = dump.split(separator: "\n")
        #expect(lines.count == 2)
        #expect(lines[0] == "00000000  53 53 48 2d 32 2e 30 2d  4f 70 65 6e 53 53 48 5f  |SSH-2.0-OpenSSH_|")
        #expect(lines[1].hasPrefix("00000010  39 2e 36 0d 0a"))
        #expect(lines[1].hasSuffix("|9.6..|"))
        #expect(ServiceProbe.hexDump(Data(repeating: 0x41, count: 40), limit: 16).hasSuffix("… 24 more bytes"))
    }

    @Test(arguments: [
        ("SSH-2.0-OpenSSH_9.6p1 Ubuntu-3ubuntu13.5\r\n", UInt16(22), ServiceProtocol.ssh),
        ("220 (vsFTPd 3.0.5)\r\n", 21, .ftp),
        ("220 ProFTPD Server ready.\r\n", 2121, .ftp),
        ("220 mail.example.com ESMTP Postfix\r\n", 25, .smtp),
        ("220 hello\r\n", 587, .smtp),
        ("+OK Dovecot ready.\r\n", 110, .pop3),
        ("* OK [CAPABILITY IMAP4rev1] ready\r\n", 143, .imap),
        ("RFB 003.008\n", 5900, .vnc),
        ("hello there", 1234, .unknown),
    ])
    func detectsProtocol(_ banner: String, _ port: UInt16, _ expected: ServiceProtocol) {
        #expect(ServiceProbe.detectProtocol(banner: Data(banner.utf8), port: port) == expected)
    }

    @Test func detectsBinaryProtocols() {
        #expect(ServiceProbe.detectProtocol(banner: Data([0xFF, 0xFD, 0x18, 0xFF, 0xFD, 0x20]), port: 23) == .telnet)
        let mysql = Data([0x4A, 0, 0, 0, 0x0A]) + Data("8.0.36\0".utf8)
        #expect(ServiceProbe.detectProtocol(banner: mysql, port: 3306) == .mysql)
        #expect(ServiceProbe.detectProtocol(banner: nil, port: 22) == .unknown)
        #expect(ServiceProbe.detectProtocol(banner: Data(), port: 22) == .unknown)
    }

    // MARK: HTTP

    @Test func parsesHeadersInOrderWithDuplicatesAndFolding() throws {
        let raw =
            "HTTP/1.1 302 Found\r\nServer: lighttpd\r\nSet-Cookie: a=1\r\nSet-Cookie: b=2\r\n"
            + "X-Long: part one\r\n  part two\r\nLocation: /login.html\r\nContent-Length: 5\r\n\r\nhello EXTRA"
        let r = try #require(ServiceProbe.parseHTTPResponse(Data(raw.utf8)))
        #expect(r.statusLine == "HTTP/1.1 302 Found")
        #expect(r.statusCode == 302)
        #expect(r.reason == "Found")
        #expect(r.httpVersion == "HTTP/1.1")
        #expect(
            r.headers.map(\.name) == ["Server", "Set-Cookie", "Set-Cookie", "X-Long", "Location", "Content-Length"])
        #expect(r.header("x-long") == "part one part two")
        #expect(r.header("location") == "/login.html")
        #expect(r.body == Data("hello".utf8))
        #expect(r.isComplete)
    }

    @Test func incompleteHeadersAndNonHTTP() {
        #expect(ServiceProbe.parseHTTPResponse(Data("HTTP/1.1 200 OK\r\nServer: x\r\n".utf8)) == nil)
        #expect(ServiceProbe.parseHTTPResponse(Data("SSH-2.0-x\r\n\r\n".utf8)) == nil)
        let partial = ServiceProbe.parseHTTPResponse(Data("HTTP/1.0 200 OK\r\nContent-Length: 10\r\n\r\nabc".utf8))
        #expect(partial?.isComplete == false)
        #expect(partial?.body.count == 3)
        // No length: complete only when the connection closes.
        let open = ServiceProbe.parseHTTPResponse(Data("HTTP/1.0 200 OK\n\nbody".utf8))
        #expect(open?.isComplete == false)
        #expect(open?.body == Data("body".utf8))
    }

    @Test func decodesChunkedBodies() throws {
        let raw =
            "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n7;ext=1\r\n<title>\r\n5\r\nHello\r\n8\r\n</title>\r\n0\r\n\r\n"
        let r = try #require(ServiceProbe.parseHTTPResponse(Data(raw.utf8)))
        #expect(String(decoding: r.body, as: UTF8.self) == "<title>Hello</title>")
        #expect(r.isComplete)
        let cut = try #require(ServiceProbe.parseHTTPResponse(Data(raw.prefix(60).utf8)))
        #expect(!cut.isComplete)
    }

    @Test func skipsInterimResponses() throws {
        let raw = "HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 204 No Content\r\nServer: x\r\n\r\n"
        let r = try #require(ServiceProbe.parseHTTPResponse(Data(raw.utf8)))
        #expect(r.statusCode == 204)
        #expect(r.isComplete)
    }

    @Test func resolvesRedirects() {
        let base = URL(string: "http://192.168.1.1:8080/a/b")!
        #expect(ServiceProbe.redirectTarget("/login", from: base)?.absoluteString == "http://192.168.1.1:8080/login")
        #expect(ServiceProbe.redirectTarget("c?x=1", from: base)?.absoluteString == "http://192.168.1.1:8080/a/c?x=1")
        #expect(
            ServiceProbe.redirectTarget("https://192.168.1.1/", from: base)?.absoluteString == "https://192.168.1.1/")
    }

    @Test func buildsRequestFromEncodedPath() throws {
        let head = { (s: String) in ServiceProbe.requestHead(for: URL(string: s)!) }
        #expect(try #require(head("http://192.168.1.1/ui/")).hasPrefix("GET /ui/ HTTP/1.1\r\nHost: 192.168.1.1\r\n"))
        #expect(try #require(head("http://192.168.1.1:8080")).hasPrefix("GET / HTTP/1.1\r\nHost: 192.168.1.1:8080\r\n"))
        #expect(try #require(head("http://192.168.1.1/a%20b?q=%0D%0A")).hasPrefix("GET /a%20b?q=%0D%0A HTTP/1.1\r\n"))
        let injected = try #require(head("http://192.168.1.1/x%0D%0AEvil:%201"))
        #expect(!injected.contains("\r\nEvil:"))
        #expect(head("mailto:someone") == nil)
    }

    // MARK: SSH

    static let ed25519 = "AAAAC3NzaC1lZDI1NTE5AAAAIDUIv0mbsMQ84rlmWjl7/2YImXdmpfyC+gBgEgEi9opu"
    static let rsa3072 =
        "AAAAB3NzaC1yc2EAAAADAQABAAABgQCfAzA6QNEGxr9m+GcJYsqJnKXSxcM0a9iXN3N2v1qTm1lMJQf27IoH7IN/hSVBOgNHMEvA/GmJCi2h6ZZAOf4Pyjx+apC+Nz2CPoQyTmgDlFhz9Z9YPX0O7mRicnulIviWNXM4jbTJDhiyimfu0KhxLxSq2AST+zMvv8gbfageThmKnbT++gtVF+Wkr1uc3hDaMKRehJaZMuCs7q03fEHce5KRzJSPaQURdbefoAu6D1DiqeqBdbDsNEgxyznob/2lphC8sjgU88ehMazFEMtSe1uwDRMXeHKDDKC6LLdMA0v84ojAfrhaE2RXB1Zp1I4h2pyQyCmeaPZAHasnC1lCdNthaYykG0JTpqK+hNelj0jUa02ToIUJHWhV2TZ1uKM9+0huO6cNJDf+GzmvI4k1gf5Ssv4w69qYBJcOmlTVXDzFCsKgPb1Wlo5A/nt6+l+seMzdReqMApC0mlJ5k0fjewiAqLTfhH4rj7Unxdbg7PLppYKAUs8WGL0/Dj78CKc="
    static let ecdsa384 =
        "AAAAE2VjZHNhLXNoYTItbmlzdHAzODQAAAAIbmlzdHAzODQAAABhBKAeoiJe8bTIiDVDZ/4XHRFVpSL2Hi59LebntM9iqGhzGM1mJH3os6QYseXIh8bD5LP91Vv1ZoaQqvDYzDjfmr3jHbSZwo6pCDekC797qTNaUPpzUHGkJ6yRNyn1ENR7MQ=="

    /// Expected values from `ssh-keygen -lf`.
    @Test func fingerprintsMatchSSHKeygen() throws {
        let ed = try #require(ServiceProbe.hostKey(algorithm: "ssh-ed25519", base64: Self.ed25519))
        #expect(ed.fingerprint == "SHA256:FOx2QF8MV6hCUiHvjPr03ndjqGK4hbefhNaCYbIHBdc")
        #expect(ed.keygenLine == "256 SHA256:FOx2QF8MV6hCUiHvjPr03ndjqGK4hbefhNaCYbIHBdc (ED25519)")
        let rsa = try #require(ServiceProbe.hostKey(algorithm: "ssh-rsa", base64: Self.rsa3072))
        #expect(rsa.keygenLine == "3072 SHA256:TH2pavkyQe5Ax06ty7+qSW9P2mmBPIia83hvFhm9Kt4 (RSA)")
        let ec = try #require(ServiceProbe.hostKey(algorithm: "ecdsa-sha2-nistp384", base64: Self.ecdsa384))
        #expect(ec.keygenLine == "384 SHA256:palCdc7Jnp5qtYRfWdwIznIWJb6K6fXLmSRS3qi71aA (ECDSA)")
        #expect(ServiceProbe.hostKey(algorithm: "ssh-rsa", base64: "not base64!") == nil)
    }

    @Test func parsesKeyscanOutput() {
        let out = """
            # 192.168.1.99:22 SSH-2.0-OpenSSH_9.6p1 Ubuntu-3ubuntu13.5
            192.168.1.99 ssh-rsa \(Self.rsa3072)
            # 192.168.1.99:22 SSH-2.0-OpenSSH_9.6p1 Ubuntu-3ubuntu13.5
            [192.168.1.99]:2222 ssh-ed25519 \(Self.ed25519)
            192.168.1.99 ecdsa-sha2-nistp384 \(Self.ecdsa384)
            192.168.1.99 ssh-ed25519 \(Self.ed25519)
            garbage
            """
        let keys = ServiceProbe.parseKeyscan(out)
        #expect(keys.map(\.algorithm) == ["ssh-ed25519", "ecdsa-sha2-nistp384", "ssh-rsa"])
        #expect(keys.map(\.bits) == [256, 384, 3072])
    }

    #if os(macOS)
        @Test func keyscanRunnerDrainsLargeOutputConcurrently() async {
            // Pipes must be drained while the child runs: >64 KB of unread output would stall it.
            let (outcome, out, err) = await Keyscan.capture(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "head -c 300000 /dev/zero; echo oops >&2"], timeout: .seconds(10))
            #expect(outcome == .exited(0))
            #expect(out.count == 300_000)
            #expect(String(decoding: err, as: UTF8.self) == "oops\n")
        }

        @Test func keyscanRunnerReportsTimeoutAndCancellation() async {
            let clock = ContinuousClock()
            let start = clock.now
            let (timedOut, _, _) = await Keyscan.capture(
                executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], timeout: .milliseconds(200))
            #expect(timedOut == .timedOut)
            let task = Task {
                await Keyscan.capture(
                    executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], timeout: .seconds(30)
                ).0
            }
            try? await Task.sleep(for: .milliseconds(200))
            task.cancel()
            #expect(await task.value == .cancelled)
            #expect(clock.now - start < .seconds(10))
            let (missing, _, _) = await Keyscan.capture(
                executable: URL(fileURLWithPath: "/nonexistent/tool"), arguments: [], timeout: .seconds(1))
            #expect(missing == .launchFailed)
        }
    #endif

    @Test func sshVersionLine() {
        let banner = Data("SSH-2.0-OpenSSH_9.6p1 Ubuntu-3ubuntu13.5\r\n".utf8) + Data([0, 0, 4, 0x14, 0x0A])
        let line = ServiceProbe.sshVersionLine(banner)
        #expect(line == "SSH-2.0-OpenSSH_9.6p1 Ubuntu-3ubuntu13.5")
        let info = SSHInfo(versionLine: line!)
        #expect(info.protocolVersion == "2.0")
        #expect(info.software == "OpenSSH_9.6p1 Ubuntu-3ubuntu13.5")
    }

    // MARK: TLS names

    @Test func tlsNames() {
        #expect(ServiceProbe.tlsVersionName(0x0304) == "TLS 1.3")
        #expect(ServiceProbe.tlsVersionName(0x0303) == "TLS 1.2")
        #expect(ServiceProbe.cipherSuiteName(0x1301) == "TLS_AES_128_GCM_SHA256")
        #expect(ServiceProbe.cipherSuiteName(0xC02F) == "TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256")
        #expect(ServiceProbe.cipherSuiteName(0xABCD) == "0xABCD")
    }
}

// MARK: - X.509

@Suite struct X509Tests {
    /// `openssl req -x509 -newkey rsa:2048 -subj "/C=NL/O=Test Org/OU=Lab/CN=router.lan"
    ///  -addext "subjectAltName=DNS:router.lan,DNS:*.router.lan,IP:192.168.1.1" -set_serial 0x1234ABCD -days 3650`
    static let rsaPEM = """
        MIIDgjCCAmqgAwIBAgIEEjSrzTANBgkqhkiG9w0BAQsFADBDMQswCQYDVQQGEwJO
        TDERMA8GA1UECgwIVGVzdCBPcmcxDDAKBgNVBAsMA0xhYjETMBEGA1UEAwwKcm91
        dGVyLmxhbjAeFw0yNjExMDcxNTI4MzVaFw0zNjExMDQxNTI4MzVaMEMxCzAJBgNV
        BAYTAk5MMREwDwYDVQQKDAhUZXN0IE9yZzEMMAoGA1UECwwDTGFiMRMwEQYDVQQD
        DApyb3V0ZXIubGFuMIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA5L8G
        IiaWt/LOEzvfIhNyZvnyOr12yKAHr9U5iKFKcUQRT3nyy5/II0v3GtmINRMpxb9W
        pHr6vM5Of9/gyfnQvMqW+k2hgqslWai5mxX20Gcy2RP5GvGHYRrcX7yug+x2K5vB
        eCFzdrInC7Zu38hMSC5F8dwNqaQUV9eZ7Jgb7uW7bXm5cU3BW8Bb70RRFd4k2xRF
        kc7zC8Gl0of9xKPBMoBCd0zHuHpe6ZCouX2rMGxspR/MF6gDmpnToq4EVv++kmK0
        PBbZG3YNNHYsdo9GfKOmUsGQ7/mw2qNAIYEPzbc8VBCGmqKcJHHahengBgelvIiA
        3r2eALXb9Kes5Y1rUwIDAQABo34wfDAdBgNVHQ4EFgQUaTUGwTwh2w2xoDnytV4t
        DZDYtYgwHwYDVR0jBBgwFoAUaTUGwTwh2w2xoDnytV4tDZDYtYgwDwYDVR0TAQH/
        BAUwAwEB/zApBgNVHREEIjAgggpyb3V0ZXIubGFuggwqLnJvdXRlci5sYW6HBMCo
        AQEwDQYJKoZIhvcNAQELBQADggEBAGPjtJ1PTmji3UYu9IQUMiBYYcqjNmHWta1m
        rivepQY0B7xze+ovZjTO76E26hHD0BauOZhUm/BypGuiRdljvsC7v2/c/3FK3ZOS
        7zBmJ/+PmXghaSZ59oyW2cVUzQB2CYUPH/r8K+unHo5WBKcI7o1xZC8f8OP/c6F0
        V+krt0FcrBqe/3EF+wkZOA8/l8Y0JbS06+yNSn+vbSTSOKgwG/fYsYkigNU08U+C
        O9jdF9jKI1xaNo3dGaa0pTiT7+w1cIo4GkscrPHo1qSP0rYucZykrK8p4lg/U89L
        Kgbs885MGwZcqR1ozFySYZpyr4DhWu654i82TQGfL/bdVUTKC3Y=
        """

    /// EC P-256, `-subj "/CN=nas.local/O=Ex" -days 30 -set_serial 7`.
    static let ecPEM = """
        MIIBmjCCAUCgAwIBAgIBBzAKBggqhkjOPQQDAjAhMRIwEAYDVQQDDAluYXMubG9j
        YWwxCzAJBgNVBAoMAkV4MB4XDTI2MTEwNzE1MjgzNVoXDTI2MTIwNzE1MjgzNVow
        ITESMBAGA1UEAwwJbmFzLmxvY2FsMQswCQYDVQQKDAJFeDBZMBMGByqGSM49AgEG
        CCqGSM49AwEHA0IABO0ciS/WHLKWcpr406ocVPwkzMlbAB2Fe9LHmUJ8B4YX2msv
        CyoaZF8TbVsBv9Se1Yn6BgGhvMGa/wCpW/wTDHWjaTBnMB0GA1UdDgQWBBR5Ah0q
        VuNMv7gxh1EHQihfSHuC6zAfBgNVHSMEGDAWgBR5Ah0qVuNMv7gxh1EHQihfSHuC
        6zAPBgNVHRMBAf8EBTADAQH/MBQGA1UdEQQNMAuCCW5hcy5sb2NhbDAKBggqhkjO
        PQQDAgNIADBFAiBCFLzZxW/LVUYyoyAKKzN8FSzJqKx0HZtKaIGyh4ohPQIhALMU
        vanc+jKBxTwX+cy/d2QTWS3EOslBCBmFybAZ0PLI
        """

    static func der(_ pem: String) -> Data {
        Data(base64Encoded: pem.filter { !$0.isWhitespace })!
    }

    static func utc(_ s: String) -> Date {
        try! Date(s, strategy: .iso8601)
    }

    @Test func parsesRSACertificate() throws {
        let p = try #require(X509.parse(Self.der(Self.rsaPEM)))
        #expect(p.version == 3)
        #expect(p.serialNumber == "12:34:AB:CD")
        #expect(p.signatureAlgorithm == "sha256WithRSAEncryption")
        #expect(p.subject.commonName == "router.lan")
        #expect(p.subject.organization == "Test Org")
        #expect(p.subject.organizationalUnit == "Lab")
        #expect(p.subject.description == "CN=router.lan, OU=Lab, O=Test Org, C=NL")
        #expect(p.issuer == p.subject)
        #expect(p.subjectEqualsIssuer)
        #expect(p.notBefore == Self.utc("2026-11-07T15:28:35Z"))
        #expect(p.notAfter == Self.utc("2036-11-04T15:28:35Z"))
        #expect(p.keyType == "RSA")
        #expect(p.keySize == 2048)
        #expect(p.subjectAltNames == ["DNS:router.lan", "DNS:*.router.lan", "IP:192.168.1.1"])
        #expect(p.isCA)
    }

    @Test func parsesECCertificate() throws {
        let p = try #require(X509.parse(Self.der(Self.ecPEM)))
        #expect(p.serialNumber == "07")
        #expect(p.signatureAlgorithm == "ecdsa-with-SHA256")
        #expect(p.subject.commonName == "nas.local")
        #expect(p.subject.organization == "Ex")
        #expect(p.keyType == "EC P-256")
        #expect(p.keySize == 256)
        #expect(p.notAfter == Self.utc("2026-12-07T15:28:35Z"))
        #expect(p.subjectAltNames == ["DNS:nas.local"])
    }

    @Test func evaluatesTrustAfterRecording() async throws {
        // Recording must not evaluate trust, which would block the TLS verify queue.
        let cert = try #require(SecCertificateCreateWithData(nil, Self.der(Self.ecPEM) as CFData))
        var trust: SecTrust?
        #expect(
            SecTrustCreateWithCertificates(cert, SecPolicyCreateSSL(true, "nas.local" as CFString), &trust)
                == errSecSuccess)
        let capture = TLSCapture(now: Self.utc("2026-11-20T00:00:00Z"))
        capture.record(try #require(trust))
        #expect(capture.result.certificates.count == 1)
        #expect(capture.result.trustError == nil)
        await capture.evaluateTrust()
        #expect(!capture.result.trusted)
        #expect(capture.result.trustError != nil)
    }

    @Test func buildsCertificateInfoWithExpiry() throws {
        let der = Self.der(Self.ecPEM)
        let cert = try #require(SecCertificateCreateWithData(nil, der as CFData))
        let now = Self.utc("2026-11-20T00:00:00Z")
        let info = X509.info(der: der, certificate: cert, now: now)
        #expect(
            info.sha256Fingerprint
                == "29:3D:6A:45:D0:72:38:1E:CB:84:76:2E:DF:D7:3E:A4:DA:1B:80:4D:76:3D:E2:E8:C5:47:86:E6:A9:46:E2:4C")
        #expect(info.daysUntilExpiry == 17)
        #expect(info.expiresSoon)
        #expect(!info.isExpired)
        #expect(info.isSelfSigned)
        #expect(info.keyDescription == "EC P-256")
        #expect(info.summary == "nas.local")

        let later = X509.info(der: der, certificate: cert, now: Self.utc("2027-01-01T00:00:00Z"))
        #expect(later.isExpired)
        #expect(!later.expiresSoon)
        #expect((later.daysUntilExpiry ?? 0) < 0)

        let rsa = X509.info(der: Self.der(Self.rsaPEM), certificate: nil, now: now)
        #expect(rsa.sha256Fingerprint.hasPrefix("CF:C6:B0:5B:4D:07"))
        #expect(rsa.keyDescription == "RSA 2048-bit")
        #expect(!rsa.expiresSoon)
    }

    @Test func toleratesGarbage() {
        #expect(X509.parse(Data()) == nil)
        #expect(X509.parse(Data([0x30, 0x82, 0xFF, 0xFF, 0x01])) == nil)
        #expect(X509.parse(Data(repeating: 0x30, count: 64)) == nil)
        var truncated = Self.der(Self.rsaPEM)
        truncated.removeLast(300)
        #expect(X509.parse(truncated) == nil)
        let info = X509.info(der: Data([1, 2, 3]), certificate: nil, now: Date())
        #expect(info.subjectCN == nil)
        #expect(info.sha256Fingerprint.count == 95)
    }

    /// Builds a TLV with a long-form length when needed.
    static func tlv(_ tag: UInt8, _ body: [UInt8]) -> [UInt8] {
        let n = body.count
        let len: [UInt8] =
            n < 0x80 ? [UInt8(n)] : n < 0x100 ? [0x81, UInt8(n)] : [0x82, UInt8(n >> 8), UInt8(n & 0xFF)]
        return [tag] + len + body
    }

    /// A structurally valid (but unsigned) certificate whose version INTEGER is `version`.
    static func cert(version: [UInt8]) -> Data {
        let empty = tlv(0x30, [])
        let tbs = tlv(0x30, tlv(0xA0, tlv(0x02, version)) + tlv(0x02, [1]) + empty + empty + empty + empty + empty)
        return Data(tlv(0x30, tbs + empty + tlv(0x03, [0])))
    }

    @Test func rejectsOutOfRangeVersionsWithoutTrapping() throws {
        // 0x7FFF_FFFF_FFFF_FFFF must not overflow the `+ 1`.
        let huge = try #require(X509.parse(Self.cert(version: [0x7F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])))
        #expect(huge.version == nil)
        #expect(try #require(X509.parse(Self.cert(version: [0xFF]))).version == nil)  // negative
        #expect(try #require(X509.parse(Self.cert(version: [3]))).version == nil)
        #expect(try #require(X509.parse(Self.cert(version: [2]))).version == 3)
        #expect(try #require(X509.parse(Self.cert(version: [0]))).version == 1)
        #expect(try #require(X509.parse(Self.cert(version: []))).version == nil)
    }

    @Test func toleratesHostileLengthsAndTimes() {
        // 4-byte length claiming 4 GiB, and a 5-byte length (unsupported).
        #expect(X509.parse(Data([0x30, 0x84, 0xFF, 0xFF, 0xFF, 0xFF, 0x00])) == nil)
        #expect(X509.parse(Data([0x30, 0x85, 0x01, 0x00, 0x00, 0x00, 0x00])) == nil)
        // OID components that would overflow a UInt64.
        #expect(DER.read(ArraySlice([0x06, 0x0B] + [UInt8](repeating: 0xFF, count: 10) + [0x01]))?.oid == nil)
        // Odd-length BMP / short UniversalString / empty strings decode without trapping.
        #expect(DER.read([0x1E, 0x01, 0x41])?.string == "")
        #expect(DER.read([0x1C, 0x02, 0x00, 0x41])?.string == "")
        #expect(DER.read([0x1E, 0x00])?.string == "")
        // Out-of-range calendar fields and offsets.
        _ = X509.parseTime("99999999999999+9999", generalized: true)
        _ = X509.parseTime("991399999999Z", generalized: false)
        let far = X509.info(der: Data(), certificate: nil, now: .distantPast)
        #expect(far.daysUntilExpiry == nil)
    }

    @Test func parsesTimes() {
        #expect(X509.parseTime("491231235959Z", generalized: false) == Self.utc("2049-12-31T23:59:59Z"))
        #expect(X509.parseTime("500101000000Z", generalized: false) == Self.utc("1950-01-01T00:00:00Z"))
        #expect(X509.parseTime("20500101000000Z", generalized: true) == Self.utc("2050-01-01T00:00:00Z"))
        #expect(X509.parseTime("20500101000000.123Z", generalized: true) == Self.utc("2050-01-01T00:00:00Z"))
        #expect(X509.parseTime("garbage", generalized: true) == nil)
    }
}

// MARK: - Local servers

/// A tiny TCP server on 127.0.0.1 for exercising the real probe.
final class LocalServer: Sendable {
    let listener: NWListener
    private static let queue = DispatchQueue(label: "ServiceProbeTests.server")

    /// `greeting` is sent on connect; `respond` maps a request line to a raw response.
    init(greeting: Data? = nil, respond: (@Sendable (String) -> Data?)? = nil) throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: params)
        listener.newConnectionHandler = { conn in
            conn.start(queue: Self.queue)
            if let greeting { conn.send(content: greeting, completion: .idempotent) }
            guard let respond else { return }
            Self.readRequest(conn, buffer: Data()) { request in
                let line = request.split(separator: "\r\n").first.map(String.init) ?? ""
                if let response = respond(line) {
                    conn.send(
                        content: response, contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { _ in conn.cancel() })
                } else {
                    conn.cancel()
                }
            }
        }
    }

    private static func readRequest(_ conn: NWConnection, buffer: Data, done: @escaping @Sendable (String) -> Void) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, complete, error in
            var buf = buffer
            if let data { buf.append(data) }
            let text = String(decoding: buf, as: UTF8.self)
            if text.contains("\r\n\r\n") { return done(text) }
            if complete || error != nil { return conn.cancel() }
            readRequest(conn, buffer: buf, done: done)
        }
    }

    func start() async throws -> UInt16 {
        let ready = OneShot<UInt16?>()
        listener.stateUpdateHandler = { [listener] state in
            switch state {
            case .ready: ready.finish(listener.port?.rawValue)
            case .failed, .cancelled: ready.finish(nil)
            default: break
            }
        }
        listener.start(queue: Self.queue)
        let port = await ready.wait(timeout: .seconds(3), timeoutValue: nil, cancelValue: nil) {}
        return try #require(port)
    }

    func stop() { listener.cancel() }
}

@Suite(.serialized) struct ServiceProbeLocalTests {
    static let localhost = LanternfishKit.IPv4Address("127.0.0.1")!

    @Test func readsUnpromptedBanner() async throws {
        let server = try LocalServer(greeting: Data("220 test FTP server ready\r\n".utf8))
        let port = try await server.start()
        defer { server.stop() }
        let report = await ServiceProbe.inspect(Self.localhost, port: port)
        #expect(report.connectError == nil)
        #expect(report.connectTime != nil)
        #expect(report.detectedProtocol == .ftp)
        #expect(report.bannerText == "220 test FTP server ready\n")
        #expect(report.bannerHex?.hasPrefix("00000000  32 32 30 20") == true)
        #expect(report.http == nil)
        #expect(report.tls == nil)
    }

    @Test func fetchesHTTPAndFollowsRedirects() async throws {
        let server = try LocalServer(respond: { line in
            if line.hasPrefix("GET / ") {
                return Data(
                    "HTTP/1.1 302 Found\r\nLocation: /home?x=1\r\nServer: TestServer/1.0\r\nContent-Length: 0\r\n\r\n"
                        .utf8)
            }
            if line.hasPrefix("GET /home?x=1 ") {
                let body = "<html><head><title>Test &amp; Home</title></head><body>hi</body></html>"
                let chunked = String(body.count, radix: 16) + "\r\n" + body + "\r\n0\r\n\r\n"
                return Data(
                    ("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n"
                        + "Transfer-Encoding: chunked\r\nX-Frame-Options: DENY\r\n\r\n" + chunked).utf8)
            }
            return Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n".utf8)
        })
        let port = try await server.start()
        defer { server.stop() }
        let report = await ServiceProbe.inspect(Self.localhost, port: port)
        #expect(report.banner == nil)
        #expect(report.detectedProtocol == .http)
        let http = try #require(report.http)
        #expect(http.responses.count == 2)
        #expect(http.responses[0].statusLine == "HTTP/1.1 302 Found")
        #expect(http.responses[0].server == "TestServer/1.0")
        #expect(http.finalURL?.absoluteString == "http://127.0.0.1:\(port)/home?x=1")
        #expect(http.final?.statusCode == 200)
        #expect(http.title == "Test & Home")
        #expect(http.contentType == "text/html; charset=utf-8")
        #expect(http.final?.header("X-Frame-Options") == "DENY")
        #expect(http.bodySize == 71)
        #expect(report.webURL?.absoluteString == "http://127.0.0.1:\(port)/")
        #expect(report.plainText.contains("Title: Test & Home"))
        #expect(report.plainText.contains("HTTP/1.1 302 Found"))
    }

    @Test func keepsTrailingSlashAndEscapesInRedirects() async throws {
        // The request target must keep the trailing slash (or "/ui" -> "/ui/" would loop and be
        // reported as an unfollowed redirect) and must not decode %0D%0A into the request line.
        let lines = Mutex<[String]>([])
        let server = try LocalServer(respond: { line in
            lines.withLock { $0.append(line) }
            if line.hasPrefix("GET / ") {
                return Data("HTTP/1.1 302 Found\r\nLocation: /ui\r\nContent-Length: 0\r\n\r\n".utf8)
            }
            if line.hasPrefix("GET /ui ") {
                return Data("HTTP/1.1 301 Moved\r\nLocation: /ui/\r\nContent-Length: 0\r\n\r\n".utf8)
            }
            if line.hasPrefix("GET /ui/ ") {
                return Data("HTTP/1.1 302 Found\r\nLocation: /x%0D%0AX-Injected:%201\r\nContent-Length: 0\r\n\r\n".utf8)
            }
            return Data("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n".utf8)
        })
        let port = try await server.start()
        defer { server.stop() }
        let report = await ServiceProbe.inspect(Self.localhost, port: port)
        let http = try #require(report.http)
        #expect(http.unfollowedRedirect == nil)
        #expect(http.responses.map(\.statusCode) == [302, 301, 302, 200])
        #expect(lines.withLock { $0 }.contains("GET /x%0D%0AX-Injected:%201 HTTP/1.1"))
    }

    @Test func reportsClosedPort() async throws {
        // Bind and immediately stop a server to get a port that is (almost certainly) closed.
        let server = try LocalServer()
        let port = try await server.start()
        server.stop()
        try await Task.sleep(for: .milliseconds(100))
        let report = await ServiceProbe.inspect(Self.localhost, port: port)
        #expect(report.connectTime == nil)
        #expect(report.connectError != nil)
        #expect(report.detectedProtocol == .unknown)
    }
}

// MARK: - Live LAN (manual)

/// `LANTERNFISHKIT_SVC=1 swift test --filter ServiceProbeLiveTests` — inspects real devices on the
/// owner's LAN and prints the reports. Override targets with `LANTERNFISHKIT_SVC=ip:port,ip:port`.
@Suite struct ServiceProbeLiveTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LANTERNFISHKIT_SVC"] != nil))
    func inspectLAN() async throws {
        let env = ProcessInfo.processInfo.environment["LANTERNFISHKIT_SVC"]!
        let targets =
            env == "1"
            ? ["192.168.1.1:443", "192.168.1.142:443", "192.168.1.142:22", "192.168.1.99:22", "192.168.1.1:80"]
            : env.split(separator: ",").map(String.init)
        for t in targets {
            let parts = t.split(separator: ":")
            guard parts.count == 2, let ip = LanternfishKit.IPv4Address(String(parts[0])), let port = UInt16(parts[1])
            else {
                continue
            }
            let report = await ServiceProbe.inspect(ip, port: port)
            print("===== \(t) (\(ServiceProbe.format(report.duration))) =====")
            print(report.plainText)
            print()
        }
    }
}
