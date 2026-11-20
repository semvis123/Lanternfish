import CryptoKit
import Foundation

// Pure parsing helpers for `ServiceProbe`. No I/O; unit-tested.
extension ServiceProbe {
    // MARK: Banner display

    /// Printable ASCII kept, CRLF/LF become newlines, tabs kept, everything else `\xNN`.
    public static func escapePrintable(_ data: Data) -> String {
        var out = ""
        out.reserveCapacity(data.count)
        let bytes = [UInt8](data)
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            switch b {
            case 0x0D where i + 1 < bytes.count && bytes[i + 1] == 0x0A:
                out += "\n"
                i += 1
            case 0x0A: out += "\n"
            case 0x09: out += "\t"
            case 0x0D: out += "\\r"
            case 0x20...0x7E: out.unicodeScalars.append(Unicode.Scalar(b))
            default: out += String(format: "\\x%02X", b)
            }
            i += 1
        }
        return out
    }

    /// `hexdump -C` style lines: "00000000  53 53 48 2d …  |SSH-…|".
    public static func hexDump(_ data: Data, limit: Int = 512) -> String {
        let bytes = [UInt8](data.prefix(limit))
        var lines: [String] = []
        for offset in stride(from: 0, to: bytes.count, by: 16) {
            let row = bytes[offset..<min(offset + 16, bytes.count)]
            var hex = ""
            for (j, b) in row.enumerated() {
                hex += String(format: "%02x ", b)
                if j == 7 { hex += " " }
            }
            let pad = String(repeating: " ", count: max(0, 49 - hex.count))
            let ascii = String(row.map { (0x20...0x7E).contains($0) ? Character(Unicode.Scalar($0)) : "." })
            lines.append(String(format: "%08x  ", offset) + hex + pad + " |" + ascii + "|")
        }
        if data.count > limit { lines.append("… \(data.count - limit) more bytes") }
        return lines.joined(separator: "\n")
    }

    // MARK: Protocol detection

    /// Guesses the protocol from what the server sent unprompted.
    public static func detectProtocol(banner: Data?, port: UInt16) -> ServiceProtocol {
        guard let banner, !banner.isEmpty else { return .unknown }
        let bytes = [UInt8](banner.prefix(256))
        let text = String(decoding: bytes, as: UTF8.self)
        let lower = text.lowercased()
        if text.hasPrefix("SSH-") { return .ssh }
        if text.hasPrefix("RFB ") { return .vnc }
        if text.hasPrefix("+OK") { return .pop3 }
        if text.hasPrefix("* OK") || text.hasPrefix("* PREAUTH") { return .imap }
        if text.hasPrefix("RTSP/") { return .rtsp }
        if text.hasPrefix("HTTP/") { return .http }
        if text.hasPrefix("220") || text.hasPrefix("421") {
            if lower.contains("ftp") { return .ftp }
            if lower.contains("smtp") || lower.contains("mail") || lower.contains("postfix") || lower.contains("exim") {
                return .smtp
            }
            switch port {
            case 21, 990, 2121: return .ftp
            case 25, 465, 587, 2525: return .smtp
            default: return .unknown
            }
        }
        if bytes.first == 0xFF, bytes.count >= 2, (0xFB...0xFE).contains(bytes[1]) { return .telnet }
        // MySQL/MariaDB handshake: 3-byte length, seq 0, protocol 10.
        if bytes.count > 5, bytes[3] == 0, bytes[4] == 0x0A,
            port == 3306 || lower.contains("mysql") || lower.contains("mariadb")
        {
            return .mysql
        }
        if text.hasPrefix("-NOAUTH") || text.hasPrefix("-DENIED") { return .redis }
        return .unknown
    }

    // MARK: HTTP

    struct ParsedHTTPResponse: Equatable {
        var statusLine: String
        var httpVersion: String
        var statusCode: Int
        var reason: String
        var headers: [HTTPHeader]
        var body: Data
        /// Whether the whole body has arrived (by Content-Length or final chunk).
        var isComplete: Bool

        func header(_ name: String) -> String? {
            headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
        }
    }

    /// Parses a raw HTTP/1.x response (status line, ordered headers, de-chunked body).
    /// Returns nil until the header block is complete or if it isn't HTTP.
    static func parseHTTPResponse(_ data: Data) -> ParsedHTTPResponse? {
        var bytes = [UInt8](data)[...]
        while true {
            guard bytes.starts(with: Array("HTTP/".utf8)) else { return nil }
            guard let (headEnd, bodyStart) = headerBoundary(bytes) else { return nil }
            let head = String(decoding: bytes[bytes.startIndex..<headEnd], as: UTF8.self)
            // "\r\n" is a single Character, so split on any newline grapheme.
            var lines = head.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
            let statusLine = lines.removeFirst()
            let parts = statusLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count >= 2, let code = Int(parts[1]) else { return nil }
            var headers: [HTTPHeader] = []
            for line in lines where !line.isEmpty {
                if line.first == " " || line.first == "\t", !headers.isEmpty {
                    // Obsolete line folding: continuation of the previous header.
                    headers[headers.count - 1].value += " " + line.trimmingCharacters(in: .whitespaces)
                    continue
                }
                guard let colon = line.firstIndex(of: ":") else { continue }
                headers.append(
                    HTTPHeader(
                        name: String(line[..<colon]).trimmingCharacters(in: .whitespaces),
                        value: String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)))
            }
            let rawBody = bytes[bodyStart...]
            // Skip interim 1xx responses (100 Continue, 103 Early Hints).
            if (100..<200).contains(code), code != 101 {
                bytes = rawBody
                if bytes.isEmpty { return nil }
                continue
            }
            var response = ParsedHTTPResponse(
                statusLine: statusLine, httpVersion: String(parts[0]), statusCode: code,
                reason: parts.count > 2 ? String(parts[2]) : "", headers: headers, body: Data(), isComplete: false)
            let te = response.header("Transfer-Encoding")?.lowercased() ?? ""
            if code == 204 || code == 304 {
                response.isComplete = true
            } else if te.contains("chunked") {
                let (body, done) = dechunk(rawBody)
                response.body = body
                response.isComplete = done
            } else if let lenStr = response.header("Content-Length"), let len = Int(lenStr), len >= 0 {
                response.body = Data(rawBody.prefix(len))
                response.isComplete = rawBody.count >= len
            } else {
                response.body = Data(rawBody)
            }
            return response
        }
    }

    /// End of the header block and start of the body (handles CRLFCRLF and bare LFLF).
    private static func headerBoundary(_ b: ArraySlice<UInt8>) -> (Int, Int)? {
        var i = b.startIndex
        while i < b.endIndex {
            if b[i] == 0x0A {
                if i + 1 < b.endIndex, b[i + 1] == 0x0A { return (i, i + 2) }
                if i + 2 < b.endIndex, b[i + 1] == 0x0D, b[i + 2] == 0x0A { return (i, i + 3) }
            }
            i += 1
        }
        return nil
    }

    /// Decodes a chunked body; `complete` once the zero-length chunk arrived.
    private static func dechunk(_ b: ArraySlice<UInt8>) -> (Data, complete: Bool) {
        var out = Data()
        var i = b.startIndex
        while i < b.endIndex {
            guard let lf = b[i...].firstIndex(of: 0x0A) else { break }
            var sizeLine = String(decoding: b[i..<lf], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if let semi = sizeLine.firstIndex(of: ";") { sizeLine = String(sizeLine[..<semi]) }
            guard let size = Int(sizeLine, radix: 16), size >= 0 else { break }
            if size == 0 { return (out, true) }
            let start = lf + 1
            let available = min(size, b.endIndex - start)
            out.append(contentsOf: b[start..<start + available])
            if available < size { break }
            i = start + size
            // Chunk data is followed by CRLF.
            if i < b.endIndex, b[i] == 0x0D { i += 1 }
            if i < b.endIndex, b[i] == 0x0A { i += 1 }
        }
        return (out, false)
    }

    /// Resolves a Location header against the URL it came from.
    static func redirectTarget(_ location: String, from url: URL) -> URL? {
        URL(string: location.trimmingCharacters(in: .whitespaces), relativeTo: url)?.absoluteURL
    }

    // MARK: SSH

    /// Parses `ssh-keyscan` output ("host type base64" lines; comments ignored) into host keys.
    public static func parseKeyscan(_ output: String) -> [SSHHostKey] {
        var seen = Set<String>()
        var keys: [SSHHostKey] = []
        for line in output.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            let fields = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
            guard fields.count >= 3 else { continue }
            let (type, b64) = (fields[1], fields[2])
            guard let key = hostKey(algorithm: type, base64: b64), seen.insert(b64).inserted else { continue }
            keys.append(key)
        }
        return keys.sorted { order($0.algorithm) < order($1.algorithm) }
    }

    private static func order(_ algorithm: String) -> Int {
        switch algorithm {
        case "ssh-ed25519": 0
        case let a where a.hasPrefix("ecdsa"): 1
        case "ssh-rsa": 2
        default: 3
        }
    }

    /// Builds a host key from its known_hosts representation; nil if the blob doesn't decode.
    public static func hostKey(algorithm: String, base64: String) -> SSHHostKey? {
        guard let blob = Data(base64Encoded: base64), !blob.isEmpty else { return nil }
        return SSHHostKey(
            algorithm: algorithm, publicKey: base64,
            fingerprint: sshFingerprint(blob), bits: sshKeyBits(blob, algorithm: algorithm))
    }

    /// "SHA256:" + unpadded base64 of the SHA-256 of the key blob, as `ssh-keygen -l` prints.
    public static func sshFingerprint(_ blob: Data) -> String {
        var b64 = Data(SHA256.hash(data: blob)).base64EncodedString()
        while b64.hasSuffix("=") { b64.removeLast() }
        return "SHA256:" + b64
    }

    /// Key size the way `ssh-keygen -l` reports it.
    private static func sshKeyBits(_ blob: Data, algorithm: String) -> Int? {
        var fields: [ArraySlice<UInt8>] = []
        let bytes = [UInt8](blob)
        var i = 0
        while i + 4 <= bytes.count, fields.count < 6 {
            let len = Int(bytes[i]) << 24 | Int(bytes[i + 1]) << 16 | Int(bytes[i + 2]) << 8 | Int(bytes[i + 3])
            i += 4
            guard len >= 0, i + len <= bytes.count else { break }
            fields.append(bytes[i..<i + len])
            i += len
        }
        let type = fields.first.map { String(decoding: $0, as: UTF8.self) } ?? algorithm
        switch type {
        case "ssh-rsa": return fields.count >= 3 ? X509.bitLength(fields[2]) : nil
        case "ssh-dss": return fields.count >= 2 ? X509.bitLength(fields[1]) : nil
        case "ssh-ed25519", "sk-ssh-ed25519@openssh.com": return 256
        case "ssh-ed448": return 448
        default:
            for size in [256, 384, 521] where type.contains("nistp\(size)") { return size }
            return nil
        }
    }

    /// The identification line from an SSH greeting ("SSH-2.0-…"), without CR/LF.
    static func sshVersionLine(_ banner: Data) -> String? {
        let text = String(decoding: banner.prefix(512), as: UTF8.self)
        for line in text.split(whereSeparator: \.isNewline) where line.hasPrefix("SSH-") {
            return String(line).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    // MARK: TLS names

    static func tlsVersionName(_ raw: UInt16) -> String {
        switch raw {
        case 0x0300: "SSL 3.0"
        case 0x0301: "TLS 1.0"
        case 0x0302: "TLS 1.1"
        case 0x0303: "TLS 1.2"
        case 0x0304: "TLS 1.3"
        case 0xFEFF: "DTLS 1.0"
        case 0xFEFD: "DTLS 1.2"
        default: String(format: "0x%04X", raw)
        }
    }

    static func cipherSuiteName(_ raw: UInt16) -> String {
        cipherSuites[raw] ?? String(format: "0x%04X", raw)
    }

    private static let cipherSuites: [UInt16: String] = [
        0x1301: "TLS_AES_128_GCM_SHA256",
        0x1302: "TLS_AES_256_GCM_SHA384",
        0x1303: "TLS_CHACHA20_POLY1305_SHA256",
        0xC02B: "TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256",
        0xC02C: "TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384",
        0xC02F: "TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256",
        0xC030: "TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384",
        0xCCA8: "TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256",
        0xCCA9: "TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256",
        0xC009: "TLS_ECDHE_ECDSA_WITH_AES_128_CBC_SHA",
        0xC00A: "TLS_ECDHE_ECDSA_WITH_AES_256_CBC_SHA",
        0xC013: "TLS_ECDHE_RSA_WITH_AES_128_CBC_SHA",
        0xC014: "TLS_ECDHE_RSA_WITH_AES_256_CBC_SHA",
        0xC023: "TLS_ECDHE_ECDSA_WITH_AES_128_CBC_SHA256",
        0xC024: "TLS_ECDHE_ECDSA_WITH_AES_256_CBC_SHA384",
        0xC027: "TLS_ECDHE_RSA_WITH_AES_128_CBC_SHA256",
        0xC028: "TLS_ECDHE_RSA_WITH_AES_256_CBC_SHA384",
        0x009C: "TLS_RSA_WITH_AES_128_GCM_SHA256",
        0x009D: "TLS_RSA_WITH_AES_256_GCM_SHA384",
        0x009E: "TLS_DHE_RSA_WITH_AES_128_GCM_SHA256",
        0x009F: "TLS_DHE_RSA_WITH_AES_256_GCM_SHA384",
        0x002F: "TLS_RSA_WITH_AES_128_CBC_SHA",
        0x0035: "TLS_RSA_WITH_AES_256_CBC_SHA",
        0x003C: "TLS_RSA_WITH_AES_128_CBC_SHA256",
        0x003D: "TLS_RSA_WITH_AES_256_CBC_SHA256",
        0x000A: "TLS_RSA_WITH_3DES_EDE_CBC_SHA",
    ]
}

// MARK: - Plain-text export

extension ServiceReport {
    /// The whole report as plain text (for "Copy All").
    public var plainText: String {
        var out: [String] = []
        func line(_ k: String, _ v: String?) { if let v, !v.isEmpty { out.append("\(k): \(v)") } }
        out.append("Service \(ip):\(port)")
        line("Protocol", detectedProtocol.label)
        line("Connect time", connectTime.map(ServiceProbe.format))
        line("Connect error", connectError)

        if let http {
            out.append("")
            out.append("[HTTP]")
            for (i, r) in http.responses.enumerated() {
                if i > 0 { out.append("") }
                out.append("GET \(r.url.absoluteString)")
                out.append(r.statusLine)
                for h in r.headers { out.append("\(h.name): \(h.value)") }
            }
            out.append("")
            line("Final URL", http.finalURL?.absoluteString)
            line("Title", http.title)
            line("Content-Type", http.contentType)
            line("Body size", http.bodySize.map { "\($0) bytes" + (http.final?.bodyTruncated == true ? "+" : "") })
        }
        line("HTTP error", httpError)

        if let tls {
            out.append("")
            out.append("[TLS]")
            line("Version", tls.protocolVersion)
            line("Cipher suite", tls.cipherSuite)
            line("Trusted", tls.trusted ? "yes" : "no" + (tls.trustError.map { " (\($0))" } ?? ""))
            for (i, c) in tls.certificates.enumerated() {
                out.append("")
                out.append("Certificate \(i + 1): \(c.displayName)")
                line("  Subject", c.subject.description)
                line("  Issuer", c.issuer.description)
                if !c.subjectAltNames.isEmpty { line("  SANs", c.subjectAltNames.joined(separator: ", ")) }
                line("  Not before", c.notBefore.map(ServiceProbe.formatDate))
                line(
                    "  Not after",
                    c.notAfter.map(ServiceProbe.formatDate).map { d in
                        c.isExpired ? "\(d) (EXPIRED)" : c.daysUntilExpiry.map { "\(d) (\($0) days left)" } ?? d
                    })
                line("  Self-signed", c.isSelfSigned ? "yes" : nil)
                line("  Key", c.keyDescription)
                line("  Signature", c.signatureAlgorithm)
                line("  Serial", c.serialNumber)
                line("  SHA-256", c.sha256Fingerprint)
            }
        }
        line("TLS error", tlsError)

        if let ssh {
            out.append("")
            out.append("[SSH]")
            line("Version", ssh.versionLine)
            for k in ssh.hostKeys { out.append("\(k.algorithm) \(k.keygenLine)") }
        }
        line("SSH error", sshError)

        if let bannerText {
            out.append("")
            out.append("[Banner]")
            out.append(bannerText)
        }
        return out.joined(separator: "\n")
    }
}

extension ServiceProbe {
    /// "3 ms", "0.4 ms", "1.20 s".
    public static func format(_ d: Duration) -> String {
        let c = d.components
        let ms = Double(c.seconds) * 1000 + Double(c.attoseconds) / 1e15
        if ms < 1 { return String(format: "%.2f ms", ms) }
        if ms < 100 { return String(format: "%.1f ms", ms) }
        if ms < 1000 { return String(format: "%.0f ms", ms) }
        return String(format: "%.2f s", ms / 1000)
    }

    /// "2026-11-07 15:28:35 UTC".
    public static func formatDate(_ d: Date) -> String {
        let c = X509.utcCalendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: d)
        return String(
            format: "%04d-%02d-%02d %02d:%02d:%02d UTC", c.year ?? 0, c.month ?? 0, c.day ?? 0,
            c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }
}
