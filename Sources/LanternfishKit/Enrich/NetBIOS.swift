import Foundation

/// NetBIOS node status (NBSTAT) lookups over UDP 137, as answered by Windows and Samba.
public enum NetBIOS {
    private static let nameServicePort: UInt16 = 137

    public struct Name: Sendable, Equatable {
        public var name: String
        public var suffix: UInt8
        public var isGroup: Bool
    }

    public struct NodeStatus: Sendable, Equatable {
        public var names: [Name]
        /// The "unit ID" (adapter MAC). Samba always reports all zeros.
        public var unitID: [UInt8]

        /// The machine name: first unique name with suffix 0x00 (workstation) or 0x20 (server).
        public var computerName: String? {
            (names.first { !$0.isGroup && $0.suffix == 0x00 } ?? names.first { !$0.isGroup && $0.suffix == 0x20 })?.name
        }

        /// The workgroup / domain: first group name with suffix 0x00.
        public var workgroup: String? { names.first { $0.isGroup && $0.suffix == 0x00 }?.name }

        public var isSamba: Bool { !unitID.isEmpty && unitID.allSatisfy { $0 == 0 } }
    }

    /// `*` wildcard NBSTAT query (type 0x21, class IN).
    public static func query(transactionID: UInt16 = 0x4E53) -> Data {
        var d = Data([
            UInt8(transactionID >> 8), UInt8(transactionID & 0xFF),
            0x00, 0x00,  // flags: query
            0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        ])
        d.append(0x20)
        // "*" padded with NULs to 16 bytes, first-level encoded: each nibble + 'A'.
        var raw = [UInt8](repeating: 0, count: 16)
        raw[0] = UInt8(ascii: "*")
        for b in raw {
            d.append(0x41 + (b >> 4))
            d.append(0x41 + (b & 0x0F))
        }
        d.append(contentsOf: [0x00, 0x00, 0x21, 0x00, 0x01])
        return d
    }

    /// Parses an NBSTAT response. Returns nil for anything malformed.
    public static func parse(_ data: Data) -> NodeStatus? {
        let b = [UInt8](data)
        guard b.count >= 12, b[2] & 0x80 != 0 else { return nil }  // must be a response
        let answers = Int(b[6]) << 8 | Int(b[7])
        guard answers >= 1 else { return nil }
        var i = 12
        // Answer name: labels or a compression pointer.
        while i < b.count {
            let len = Int(b[i])
            if len == 0 {
                i += 1
                break
            }
            if len & 0xC0 == 0xC0 {
                i += 2
                break
            }
            i += 1 + len
        }
        // type(2) class(2) ttl(4) rdlength(2)
        guard i + 10 <= b.count, b[i] == 0x00, b[i + 1] == 0x21 else { return nil }
        let rdLength = Int(b[i + 8]) << 8 | Int(b[i + 9])
        i += 10
        guard i < b.count else { return nil }
        let end = min(b.count, i + rdLength)
        let count = Int(b[i])
        i += 1
        var names: [Name] = []
        for _ in 0..<count {
            guard i + 18 <= end else { return nil }
            let raw = b[i..<i + 15]
            let name = String(decoding: raw, as: UTF8.self)
                .trimmingCharacters(in: CharacterSet(charactersIn: " \0"))
            let suffix = b[i + 15]
            let flags = UInt16(b[i + 16]) << 8 | UInt16(b[i + 17])
            names.append(Name(name: name, suffix: suffix, isGroup: flags & 0x8000 != 0))
            i += 18
        }
        let unit = i + 6 <= end ? Array(b[i..<i + 6]) : []
        return NodeStatus(names: names, unitID: unit)
    }

    /// OS hint from a node status: Samba is recognisable by its zero unit ID; otherwise it's
    /// almost certainly Windows (macOS doesn't answer NBSTAT by default), unless the device is Apple.
    public static func osHint(_ status: NodeStatus, vendor: String?) -> String? {
        if status.isSamba { return "Samba" }
        if let v = vendor, v.localizedCaseInsensitiveContains("apple") { return nil }
        return status.computerName == nil ? nil : "Windows"
    }

    /// Queries one host. Returns nil on timeout or no NetBIOS.
    public static func nodeStatus(_ ip: IPv4Address, timeout: Duration = .milliseconds(600)) async -> NodeStatus? {
        let txid = UInt16.random(in: 1...0xFFFE)
        guard
            let data = await LANIO.udpQuery(
                ip, port: nameServicePort, payload: query(transactionID: txid), timeout: timeout),
            data.count >= 2, UInt16(data[data.startIndex]) << 8 | UInt16(data[data.startIndex + 1]) == txid
        else { return nil }
        return parse(data)
    }
}
