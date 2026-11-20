import CryptoKit
import Foundation
import Security

/// Minimal, defensive DER reader: just enough X.509 to show a certificate's fields.
/// Every accessor returns nil on malformed input instead of trapping.
struct DER {
    let tag: UInt8
    /// Value bytes (indices into the original buffer).
    let content: ArraySlice<UInt8>
    /// Header + value (the full TLV), e.g. to compare raw names.
    let raw: ArraySlice<UInt8>

    /// Reads one TLV at the start of `bytes`.
    static func read(_ bytes: ArraySlice<UInt8>) -> DER? {
        var i = bytes.startIndex
        guard i < bytes.endIndex else { return nil }
        let tag = bytes[i]
        i += 1
        guard tag & 0x1F != 0x1F, i < bytes.endIndex else { return nil }  // no multi-byte tags in X.509
        var length = Int(bytes[i])
        i += 1
        if length & 0x80 != 0 {
            let n = length & 0x7F
            guard n >= 1, n <= 4, bytes.endIndex - i >= n else { return nil }
            length = 0
            for _ in 0..<n {
                length = length << 8 | Int(bytes[i])
                i += 1
            }
        }
        guard length >= 0, bytes.endIndex - i >= length else { return nil }
        return DER(tag: tag, content: bytes[i..<i + length], raw: bytes[bytes.startIndex..<i + length])
    }

    /// The TLVs inside a constructed value.
    var children: [DER] {
        var out: [DER] = []
        var rest = content
        while !rest.isEmpty, let node = DER.read(rest) {
            out.append(node)
            rest = rest[node.raw.endIndex...]
        }
        return out
    }

    var oid: String? {
        guard tag == 0x06, !content.isEmpty else { return nil }
        var parts: [UInt64] = []
        var value: UInt64 = 0
        for b in content {
            guard value < (1 << 56) else { return nil }
            value = value << 7 | UInt64(b & 0x7F)
            if b & 0x80 == 0 {
                parts.append(value)
                value = 0
            }
        }
        guard let first = parts.first else { return nil }
        let head: [UInt64] = first < 80 ? [first / 40, first % 40] : [2, first - 80]
        return (head + parts.dropFirst()).map(String.init).joined(separator: ".")
    }

    /// Decodes the ASN.1 string types used in names.
    var string: String? {
        switch tag {
        case 0x0C, 0x13, 0x16, 0x14, 0x1A, 0x12:  // UTF8, Printable, IA5, T61, Visible, Numeric
            return String(decoding: content, as: UTF8.self)
        case 0x1E:  // BMPString, UTF-16BE
            let units = stride(from: content.startIndex, to: content.endIndex - 1, by: 2).map {
                UInt16(content[$0]) << 8 | UInt16(content[$0 + 1])
            }
            return String(decoding: units, as: UTF16.self)
        case 0x1C:  // UniversalString, UTF-32BE
            let scalars = stride(from: content.startIndex, to: content.endIndex - 3, by: 4).compactMap {
                i -> Unicode.Scalar? in
                Unicode.Scalar(
                    UInt32(content[i]) << 24 | UInt32(content[i + 1]) << 16
                        | UInt32(content[i + 2]) << 8 | UInt32(content[i + 3]))
            }
            return String(String.UnicodeScalarView(scalars))
        default:
            return nil
        }
    }

    /// UTCTime / GeneralizedTime → Date (UTC; fractional seconds and offsets tolerated).
    var time: Date? {
        guard tag == 0x17 || tag == 0x18 else { return nil }
        return X509.parseTime(String(decoding: content, as: UTF8.self), generalized: tag == 0x18)
    }
}

/// Field extraction from DER certificates.
enum X509 {
    struct Parsed: Equatable {
        var version: Int?
        var serialNumber: String?
        var signatureAlgorithm: String?
        var issuer = DistinguishedName()
        var subject = DistinguishedName()
        var notBefore: Date?
        var notAfter: Date?
        var keyType: String?
        var keySize: Int?
        var subjectAltNames: [String] = []
        var isCA = false
        var subjectEqualsIssuer = false
    }

    static func parse(_ data: Data) -> Parsed? {
        let bytes = ArraySlice([UInt8](data))
        guard let cert = DER.read(bytes), cert.tag == 0x30 else { return nil }
        let top = cert.children
        guard top.count >= 2, top[0].tag == 0x30 else { return nil }
        var tbs = top[0].children[...]
        var p = Parsed()

        if let first = tbs.first, first.tag == 0xA0 {
            // Version ::= INTEGER { v1(0), v2(1), v3(2) }; anything else is bogus (and a crafted
            // 0x7FFF… must not overflow the +1).
            p.version = first.children.first.flatMap { $0.tag == 0x02 ? Int(integer: $0.content) : nil }
                .flatMap { (0...2).contains($0) ? $0 + 1 : nil }
            tbs = tbs.dropFirst()
        } else {
            p.version = 1
        }
        guard tbs.count >= 6 else { return nil }
        let fields = Array(tbs)
        if fields[0].tag == 0x02 { p.serialNumber = hex(fields[0].content.drop { $0 == 0 }, separator: ":") }
        // The outer signatureAlgorithm is authoritative; fall back to the TBS copy.
        if let oid = top[1].children.first?.oid ?? fields[1].children.first?.oid {
            p.signatureAlgorithm = signatureNames[oid] ?? oid
        }
        p.issuer = name(fields[2])
        let validity = fields[3].children
        if validity.count == 2 {
            p.notBefore = validity[0].time
            p.notAfter = validity[1].time
        }
        p.subject = name(fields[4])
        p.subjectEqualsIssuer = fields[2].raw.elementsEqual(fields[4].raw)
        (p.keyType, p.keySize) = publicKey(fields[5])

        for f in fields.dropFirst(6) where f.tag == 0xA3 {
            for ext in f.children.first?.children ?? [] {
                let parts = ext.children
                guard let oid = parts.first?.oid, let value = parts.last, value.tag == 0x04,
                    let inner = DER.read(value.content)
                else { continue }
                switch oid {
                case "2.5.29.17": p.subjectAltNames = generalNames(inner)
                case "2.5.29.19":
                    p.isCA =
                        inner.children.first.map { $0.tag == 0x01 && $0.content.first.map { $0 != 0 } == true } ?? false
                default: break
                }
            }
        }
        return p
    }

    static func name(_ node: DER) -> DistinguishedName {
        var attrs: [DistinguishedName.Attribute] = []
        for rdn in node.children where rdn.tag == 0x31 {
            for atv in rdn.children where atv.tag == 0x30 {
                let parts = atv.children
                guard parts.count == 2, let oid = parts[0].oid else { continue }
                attrs.append(.init(oid: oid, value: parts[1].string ?? hex(parts[1].content, separator: "")))
            }
        }
        return DistinguishedName(attributes: attrs)
    }

    static func publicKey(_ spki: DER) -> (String?, Int?) {
        let parts = spki.children
        guard parts.count == 2, let alg = parts[0].children.first?.oid else { return (nil, nil) }
        let params = parts[0].children.dropFirst().first
        let keyBits = parts[1].tag == 0x03 ? parts[1].content.dropFirst() : []
        switch alg {
        case "1.2.840.113549.1.1.1", "1.2.840.113549.1.1.10":
            // RSAPublicKey ::= SEQUENCE { modulus INTEGER, publicExponent INTEGER }
            guard let seq = DER.read(keyBits), let modulus = seq.children.first, modulus.tag == 0x02 else {
                return ("RSA", nil)
            }
            return ("RSA", bitLength(modulus.content))
        case "1.2.840.10045.2.1":
            let curve = params?.oid.flatMap { curveNames[$0] }
            let size = curve.flatMap { c in curveSizes[c] } ?? (keyBits.count > 1 ? (keyBits.count - 1) / 2 * 8 : nil)
            return (curve.map { "EC \($0)" } ?? "EC", size)
        case "1.3.101.112": return ("Ed25519", 256)
        case "1.3.101.113": return ("Ed448", 448)
        case "1.2.840.10040.4.1": return ("DSA", nil)
        default: return (alg, nil)
        }
    }

    static func generalNames(_ seq: DER) -> [String] {
        seq.children.compactMap { n -> String? in
            switch n.tag {
            case 0x82: return "DNS:" + String(decoding: n.content, as: UTF8.self)
            case 0x81: return "email:" + String(decoding: n.content, as: UTF8.self)
            case 0x86: return "URI:" + String(decoding: n.content, as: UTF8.self)
            case 0x87:
                if n.content.count == 4 { return "IP:" + n.content.map(String.init).joined(separator: ".") }
                if n.content.count == 16 {
                    let groups = stride(from: n.content.startIndex, to: n.content.endIndex, by: 2).map {
                        String(UInt16(n.content[$0]) << 8 | UInt16(n.content[$0 + 1]), radix: 16)
                    }
                    return "IP:" + groups.joined(separator: ":")
                }
                return nil
            default: return nil
            }
        }
    }

    static func bitLength(_ integer: ArraySlice<UInt8>) -> Int? {
        let trimmed = integer.drop { $0 == 0 }
        guard let first = trimmed.first else { return nil }
        return (trimmed.count - 1) * 8 + (8 - first.leadingZeroBitCount)
    }

    static func parseTime(_ s: String, generalized: Bool) -> Date? {
        let digits = Array(s.utf8)
        let yearLen = generalized ? 4 : 2
        guard digits.count >= yearLen + 8 else { return nil }
        func num(_ from: Int, _ len: Int) -> Int? {
            guard from + len <= digits.count else { return nil }
            var v = 0
            for c in digits[from..<from + len] {
                guard (0x30...0x39).contains(c) else { return nil }
                v = v * 10 + Int(c - 0x30)
            }
            return v
        }
        guard var year = num(0, yearLen), let month = num(yearLen, 2), let day = num(yearLen + 2, 2),
            let hour = num(yearLen + 4, 2), let minute = num(yearLen + 6, 2)
        else { return nil }
        if !generalized { year += year >= 50 ? 1900 : 2000 }
        let second = num(yearLen + 8, 2) ?? 0
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = day
        comps.hour = hour
        comps.minute = minute
        comps.second = second
        guard var date = utcCalendar.date(from: comps) else { return nil }
        // Optional "+hhmm"/"-hhmm" offset (rare, but legal in GeneralizedTime).
        if let sign = s.lastIndex(where: { $0 == "+" || $0 == "-" }) {
            let off = s[s.index(after: sign)...]
            if off.count == 4, let hh = Int(off.prefix(2)), let mm = Int(off.suffix(2)) {
                let secs = TimeInterval(hh * 3600 + mm * 60)
                date.addTimeInterval(s[sign] == "+" ? -secs : secs)
            }
        }
        return date
    }

    static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }()

    static func hex(_ bytes: some Sequence<UInt8>, separator: String) -> String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: separator)
    }

    // MARK: Building CertificateInfo

    /// Combines the DER parse with Security.framework (for fields the parse couldn't get).
    static func info(der: Data, certificate: SecCertificate?, now: Date) -> CertificateInfo {
        let parsed = parse(der)
        let fingerprint = hex(SHA256.hash(data: der), separator: ":")
        var summary: String?
        var keyType = parsed?.keyType
        var keySize = parsed?.keySize
        var subject = parsed?.subject ?? DistinguishedName()
        if let certificate {
            summary = SecCertificateCopySubjectSummary(certificate) as String?
            if subject.attributes.isEmpty {
                var cn: CFString?
                if SecCertificateCopyCommonName(certificate, &cn) == errSecSuccess, let cn {
                    subject = DistinguishedName(attributes: [.init(oid: "2.5.4.3", value: cn as String)])
                }
            }
            if keyType == nil || keySize == nil, let key = SecCertificateCopyKey(certificate),
                let attrs = SecKeyCopyAttributes(key) as? [CFString: Any]
            {
                keySize = keySize ?? (attrs[kSecAttrKeySizeInBits] as? Int)
                if keyType == nil, let t = attrs[kSecAttrKeyType] as? String {
                    keyType =
                        t == (kSecAttrKeyTypeRSA as String)
                        ? "RSA"
                        : t == (kSecAttrKeyTypeECSECPrimeRandom as String) ? "EC" : t
                }
            }
        }
        let notAfter = parsed?.notAfter
        let notBefore = parsed?.notBefore
        let days = notAfter.flatMap { Int(exactly: floor($0.timeIntervalSince(now) / 86400)) }
        return CertificateInfo(
            subject: subject,
            issuer: parsed?.issuer ?? DistinguishedName(),
            subjectAltNames: parsed?.subjectAltNames ?? [],
            notBefore: notBefore,
            notAfter: notAfter,
            daysUntilExpiry: days,
            isExpired: notAfter.map { $0 < now } ?? false,
            isNotYetValid: notBefore.map { $0 > now } ?? false,
            isSelfSigned: parsed?.subjectEqualsIssuer ?? false,
            isCA: parsed?.isCA ?? false,
            sha256Fingerprint: fingerprint,
            keyType: keyType,
            keySize: keySize,
            signatureAlgorithm: parsed?.signatureAlgorithm,
            serialNumber: parsed?.serialNumber,
            version: parsed?.version,
            summary: summary
        )
    }

    // MARK: Names

    static let attributeNames: [String: String] = [
        "2.5.4.3": "CN", "2.5.4.10": "O", "2.5.4.11": "OU", "2.5.4.6": "C", "2.5.4.7": "L", "2.5.4.8": "ST",
        "2.5.4.5": "serialNumber", "2.5.4.9": "street", "2.5.4.17": "postalCode", "2.5.4.12": "title",
        "2.5.4.42": "GN", "2.5.4.4": "SN", "1.2.840.113549.1.9.1": "emailAddress",
        "0.9.2342.19200300.100.1.25": "DC", "0.9.2342.19200300.100.1.1": "UID",
    ]

    private static let signatureNames: [String: String] = [
        "1.2.840.113549.1.1.4": "md5WithRSAEncryption",
        "1.2.840.113549.1.1.5": "sha1WithRSAEncryption",
        "1.2.840.113549.1.1.11": "sha256WithRSAEncryption",
        "1.2.840.113549.1.1.12": "sha384WithRSAEncryption",
        "1.2.840.113549.1.1.13": "sha512WithRSAEncryption",
        "1.2.840.113549.1.1.14": "sha224WithRSAEncryption",
        "1.2.840.113549.1.1.10": "RSASSA-PSS",
        "1.2.840.10045.4.1": "ecdsa-with-SHA1",
        "1.2.840.10045.4.3.1": "ecdsa-with-SHA224",
        "1.2.840.10045.4.3.2": "ecdsa-with-SHA256",
        "1.2.840.10045.4.3.3": "ecdsa-with-SHA384",
        "1.2.840.10045.4.3.4": "ecdsa-with-SHA512",
        "1.3.101.112": "Ed25519",
        "1.3.101.113": "Ed448",
        "1.2.840.10040.4.3": "dsa-with-SHA1",
        "2.16.840.1.101.3.4.3.2": "dsa-with-SHA256",
    ]

    private static let curveNames: [String: String] = [
        "1.2.840.10045.3.1.7": "P-256", "1.3.132.0.34": "P-384", "1.3.132.0.35": "P-521",
        "1.3.132.0.10": "secp256k1", "1.2.840.10045.3.1.1": "P-192", "1.3.132.0.33": "P-224",
    ]

    private static let curveSizes: [String: Int] = [
        "P-256": 256, "P-384": 384, "P-521": 521, "secp256k1": 256, "P-192": 192, "P-224": 224,
    ]
}

extension Int {
    /// A small non-negative DER INTEGER (at most 4 content bytes, sign bit clear), else nil.
    fileprivate init?(integer bytes: ArraySlice<UInt8>) {
        guard let first = bytes.first, first & 0x80 == 0, bytes.count <= 4 else { return nil }
        var v = 0
        for b in bytes { v = v << 8 | Int(b) }
        self = v
    }
}
