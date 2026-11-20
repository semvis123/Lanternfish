import Foundation

/// Everything `ServiceProbe.inspect` learned about one TCP port.
public struct ServiceReport: Sendable, Equatable {
    public var ip: IPv4Address
    public var port: UInt16
    /// When the inspection started; expiry countdowns are relative to this.
    public var date: Date
    /// Wall time of the whole inspection.
    public var duration: Duration = .zero

    /// TCP handshake time, nil when the connection failed.
    public var connectTime: Duration?
    /// Why the TCP connection failed, if it did.
    public var connectError: String?

    public var detectedProtocol: ServiceProtocol = .unknown

    /// The first bytes the server sent unprompted (capped), nil if it stayed silent.
    public var banner: Data?
    public var bannerTruncated = false

    public var http: HTTPInfo?
    public var httpError: String?
    public var tls: TLSInfo?
    public var tlsError: String?
    public var ssh: SSHInfo?
    public var sshError: String?

    public init(ip: IPv4Address, port: UInt16, date: Date = Date()) {
        self.ip = ip
        self.port = port
        self.date = date
    }

    /// The banner with control bytes escaped, for display.
    public var bannerText: String? { banner.map { ServiceProbe.escapePrintable($0) } }
    /// `hexdump -C` style preview of the banner.
    public var bannerHex: String? { banner.map { ServiceProbe.hexDump($0, limit: 512) } }

    /// The URL a browser should open for this service, if it speaks HTTP.
    public var webURL: URL? {
        guard let http else { return nil }
        return http.responses.first?.url ?? http.finalURL
    }
}

/// What a port turned out to speak.
public enum ServiceProtocol: String, Sendable, Equatable, CaseIterable {
    case http, https, tls, ssh, ftp, smtp, pop3, imap, telnet, vnc, mysql, redis, rtsp, unknown

    public var label: String {
        switch self {
        case .http: "HTTP"
        case .https: "HTTPS"
        case .tls: "TLS"
        case .ssh: "SSH"
        case .ftp: "FTP"
        case .smtp: "SMTP"
        case .pop3: "POP3"
        case .imap: "IMAP"
        case .telnet: "Telnet"
        case .vnc: "VNC (RFB)"
        case .mysql: "MySQL"
        case .redis: "Redis"
        case .rtsp: "RTSP"
        case .unknown: "Unknown"
        }
    }
}

// MARK: - HTTP

public struct HTTPHeader: Sendable, Equatable, Hashable {
    public var name: String
    public var value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

/// One HTTP response, as received.
public struct HTTPResponseInfo: Sendable, Equatable {
    /// The URL that was requested.
    public var url: URL
    /// e.g. "HTTP/1.1 200 OK".
    public var statusLine: String
    public var statusCode: Int
    /// Headers in wire order, duplicates kept.
    public var headers: [HTTPHeader]
    /// Decoded body size in bytes (capped by the probe).
    public var bodySize: Int
    public var bodyTruncated: Bool
    public var title: String?

    public init(
        url: URL, statusLine: String, statusCode: Int, headers: [HTTPHeader], bodySize: Int,
        bodyTruncated: Bool = false, title: String? = nil
    ) {
        self.url = url
        self.statusLine = statusLine
        self.statusCode = statusCode
        self.headers = headers
        self.bodySize = bodySize
        self.bodyTruncated = bodyTruncated
        self.title = title
    }

    /// First header with this name (case-insensitive).
    public func header(_ name: String) -> String? {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    public var contentType: String? { header("Content-Type") }
    public var server: String? { header("Server") }
    public var isRedirect: Bool { (300..<400).contains(statusCode) && header("Location") != nil }
}

public struct HTTPInfo: Sendable, Equatable {
    /// The original response first, then one per followed redirect.
    public var responses: [HTTPResponseInfo]
    /// A redirect the probe refused to follow (it leaves the LAN, or too many hops).
    public var unfollowedRedirect: String?

    public init(responses: [HTTPResponseInfo], unfollowedRedirect: String? = nil) {
        self.responses = responses
        self.unfollowedRedirect = unfollowedRedirect
    }

    public var final: HTTPResponseInfo? { responses.last }
    public var finalURL: URL? { final?.url }
    public var title: String? { final?.title }
    public var contentType: String? { final?.contentType }
    public var bodySize: Int? { final?.bodySize }
    public var redirected: Bool { responses.count > 1 }
}

// MARK: - TLS

public struct TLSInfo: Sendable, Equatable {
    /// e.g. "TLS 1.3".
    public var protocolVersion: String?
    /// IANA name, e.g. "TLS_AES_128_GCM_SHA256".
    public var cipherSuite: String?
    /// Leaf first.
    public var certificates: [CertificateInfo]
    /// Whether the system trusts the chain for this host (LAN devices usually don't).
    public var trusted: Bool
    public var trustError: String?
    public var handshakeTime: Duration?

    public init(
        protocolVersion: String? = nil, cipherSuite: String? = nil, certificates: [CertificateInfo] = [],
        trusted: Bool = false, trustError: String? = nil, handshakeTime: Duration? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.cipherSuite = cipherSuite
        self.certificates = certificates
        self.trusted = trusted
        self.trustError = trustError
        self.handshakeTime = handshakeTime
    }
}

public struct DistinguishedName: Sendable, Equatable {
    public struct Attribute: Sendable, Equatable {
        public var oid: String
        public var value: String
        /// Short name such as "CN" or the dotted OID when unknown.
        public var key: String { X509.attributeNames[oid] ?? oid }
    }

    public var attributes: [Attribute]

    public init(attributes: [Attribute] = []) { self.attributes = attributes }

    public func first(_ oid: String) -> String? { attributes.first { $0.oid == oid }?.value }

    public var commonName: String? { first("2.5.4.3") }
    public var organization: String? { first("2.5.4.10") }
    public var organizationalUnit: String? { first("2.5.4.11") }

    /// "CN=router.lan, O=Example, C=NL" (most specific first, like `openssl -nameopt RFC2253`).
    public var description: String {
        attributes.reversed().map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
    }
}

public struct CertificateInfo: Sendable, Equatable {
    public var subject: DistinguishedName
    public var issuer: DistinguishedName
    public var subjectAltNames: [String]
    public var notBefore: Date?
    public var notAfter: Date?
    /// Whole days from the report date to `notAfter` (negative when expired).
    public var daysUntilExpiry: Int?
    public var isExpired: Bool
    public var isNotYetValid: Bool
    public var isSelfSigned: Bool
    public var isCA: Bool
    /// "AB:CD:…" uppercase hex.
    public var sha256Fingerprint: String
    /// "RSA", "EC P-256", "Ed25519".
    public var keyType: String?
    public var keySize: Int?
    /// e.g. "sha256WithRSAEncryption".
    public var signatureAlgorithm: String?
    public var serialNumber: String?
    public var version: Int?
    /// Security.framework's one-line summary (usually the CN).
    public var summary: String?

    public var subjectCN: String? { subject.commonName }
    public var subjectO: String? { subject.organization }
    public var issuerCN: String? { issuer.commonName }
    public var issuerO: String? { issuer.organization }

    /// True when the certificate expires within 30 days (and hasn't yet).
    public var expiresSoon: Bool { !isExpired && (daysUntilExpiry ?? .max) < 30 }

    /// "RSA 2048-bit", "EC P-256".
    public var keyDescription: String? {
        guard let keyType else { return nil }
        if let keySize, !keyType.contains(String(keySize)) { return "\(keyType) \(keySize)-bit" }
        return keyType
    }

    /// Best display name: CN, else first SAN, else summary.
    public var displayName: String {
        subjectCN ?? subjectAltNames.first ?? summary ?? "Certificate"
    }
}

// MARK: - SSH

public struct SSHHostKey: Sendable, Equatable, Hashable {
    /// e.g. "ssh-ed25519".
    public var algorithm: String
    /// Base64 public key blob, as in known_hosts.
    public var publicKey: String
    /// "SHA256:…" without padding, like `ssh-keygen -l`.
    public var fingerprint: String
    public var bits: Int?

    public init(algorithm: String, publicKey: String, fingerprint: String, bits: Int?) {
        self.algorithm = algorithm
        self.publicKey = publicKey
        self.fingerprint = fingerprint
        self.bits = bits
    }

    /// "ED25519", "RSA", "ECDSA" — the label `ssh-keygen -l` prints.
    public var typeLabel: String {
        switch algorithm {
        case "ssh-ed25519": "ED25519"
        case "ssh-rsa": "RSA"
        case "ssh-dss": "DSA"
        case "ssh-ed448": "ED448"
        case let a where a.hasPrefix("ecdsa-sha2-"): "ECDSA"
        case let a where a.hasPrefix("sk-ecdsa"): "ECDSA-SK"
        case let a where a.hasPrefix("sk-ssh-ed25519"): "ED25519-SK"
        default: algorithm
        }
    }

    /// `ssh-keygen -l` style: "256 SHA256:… (ED25519)".
    public var keygenLine: String {
        "\(bits.map(String.init) ?? "?") \(fingerprint) (\(typeLabel))"
    }
}

public struct SSHInfo: Sendable, Equatable {
    /// e.g. "SSH-2.0-OpenSSH_9.6p1 Ubuntu-3ubuntu13.5".
    public var versionLine: String
    public var hostKeys: [SSHHostKey]

    public init(versionLine: String, hostKeys: [SSHHostKey] = []) {
        self.versionLine = versionLine
        self.hostKeys = hostKeys
    }

    /// "2.0".
    public var protocolVersion: String? {
        let parts = versionLine.split(separator: "-", maxSplits: 2)
        return parts.count >= 2 ? String(parts[1]) : nil
    }

    /// "OpenSSH_9.6p1 Ubuntu-3ubuntu13.5".
    public var software: String? {
        let parts = versionLine.split(separator: "-", maxSplits: 2)
        return parts.count == 3 ? String(parts[2]) : nil
    }
}
