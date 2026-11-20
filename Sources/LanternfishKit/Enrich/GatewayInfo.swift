import CryptoKit
import Foundation

/// Unauthenticated, read-only endpoints on routers that reveal their model (never logs in).
public enum GatewayInfo {
    /// Netgear routers serve `/currentsetting.htm` without login:
    /// "Firmware=V1.0.6.106_1.0.1\nRegionTag=RAX40_WW\nModel=RAX40\n…".
    public static func parseNetgearCurrentSetting(_ body: String) -> (model: String, firmware: String?)? {
        var fields: [String: String] = [:]
        for line in body.split(whereSeparator: \.isNewline) {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if fields[key] == nil { fields[key] = value }
        }
        guard let model = fields["model"], !model.isEmpty, model.count <= 32,
            model.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        else { return nil }
        let fw = fields["firmware"].flatMap { $0.isEmpty ? nil : $0 }
        return (model, fw)
    }

    /// What the gateway reveals about itself, plus human-readable evidence. Nil when nothing.
    public static func probe(_ gateway: IPv4Address, timeout: Duration = .seconds(2)) async
        -> (patch: DevicePatch, evidence: [String])?
    {
        guard let url = URL(string: "http://\(gateway)/currentsetting.htm"),
            let page = await ServiceBanners.fetch(url, timeout: timeout), page.status == 200,
            let info = parseNetgearCurrentSetting(page.body)
        else { return nil }
        var p = DevicePatch(ip: gateway)
        p.manufacturer = "Netgear"
        p.model = info.model
        p.kind = .router
        var evidence = ["Router reports model \(info.model) (Netgear currentsetting.htm)"]
        if let fw = info.firmware { evidence.append("Firmware \(fw)") }
        return (p, evidence)
    }
}

/// Favicon hashes (MD5 of /favicon.ico) of well-known web UIs.
public enum FaviconFingerprint {
    public struct Product: Sendable, Equatable {
        public var name: String
        public var manufacturer: String?
        public var kind: DeviceKind?
    }

    /// Sources: OWASP favicon database (www-community `_data/favicons-database.yml`) and icons
    /// captured from real devices.
    static let table: [String: Product] = [
        // OWASP
        "531e652a15bc0ad59b6af05019b1834a": Product(name: "Synology DSM", manufacturer: "Synology", kind: .nas),
        "f682dbd4d0a18dd7699339b8adb28c0f": Product(name: "QNAP QTS", manufacturer: "QNAP", kind: .nas),
        "7ff45523a7ee9686d3d391a0a27a0b4f": Product(name: "QNAP QTS", manufacturer: "QNAP", kind: .nas),
        "7b0d4bc0ca1659d54469e5013a08d240": Product(name: "ReadyNAS", manufacturer: "Netgear", kind: .nas),
        "6dcab71e60f0242907940f0fcda69ea5": Product(name: "Ubiquiti airOS", manufacturer: "Ubiquiti", kind: .router),
        "09a1e50dc3369e031b97f38abddd10c8": Product(name: "Ubiquiti airOS", manufacturer: "Ubiquiti", kind: .router),
        "45210ace96ce9c893f8c27c5decab10d": Product(name: "FRITZ!Box", manufacturer: "AVM", kind: .router),
        "107579220745d3b21461c23024d6c4a3": Product(name: "D-Link", manufacturer: "D-Link", kind: .router),
        // Captured from devices
        "457d76be8460d899c09becbc09b4a9e8": Product(
            name: "Kyocera Command Center", manufacturer: "Kyocera", kind: .printer),
        "53c0844f0f126e085a7aa3d346f9e58d": Product(name: "Netgear router", manufacturer: "Netgear", kind: .router),
    ]

    public static func md5(_ data: Data) -> String {
        Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// True for ICO, PNG, GIF, JPEG and SVG payloads (error pages are often served with 200).
    static func looksLikeImage(_ d: Data) -> Bool {
        let b = [UInt8](d.prefix(8))
        guard b.count >= 4 else { return false }
        if b[0] == 0, b[1] == 0, b[2] == 1 || b[2] == 2, b[3] == 0 { return true }  // ICO/CUR
        if b[0] == 0x89, b[1] == 0x50 { return true }  // PNG
        if b[0] == 0x47, b[1] == 0x49 { return true }  // GIF
        if b[0] == 0xFF, b[1] == 0xD8 { return true }  // JPEG
        return String(decoding: d.prefix(256), as: UTF8.self).contains("<svg")
    }

    public static func identify(_ data: Data) -> Product? {
        guard looksLikeImage(data) else { return nil }
        return table[md5(data)]
    }
}
