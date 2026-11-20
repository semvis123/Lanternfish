import Foundation

/// Best guess of what a device is, with how sure we are and why.
public struct Identification: Sendable, Equatable {
    public var manufacturer: String?
    public var model: String?
    public var kind: DeviceKind?
    /// 0...1 (noisy-OR of the matched clues' weights).
    public var confidence: Double
    /// Matched evidence, strongest first.
    public var reasons: [String]
    /// The signature that matched, e.g. "Sony BRAVIA TV" (nil for the generic fallback).
    public var signature: String?

    public init(
        manufacturer: String? = nil, model: String? = nil, kind: DeviceKind? = nil, confidence: Double,
        reasons: [String], signature: String? = nil
    ) {
        self.manufacturer = manufacturer
        self.model = model
        self.kind = kind
        self.confidence = confidence
        self.reasons = reasons
        self.signature = signature
    }
}

/// Signature-based device fingerprinting. Combines every kind of evidence a scan collects (OUI
/// vendor, private MAC, names/hostnames, Bonjour services, open ports, HTTP title/server,
/// UPnP manufacturer/model, NetBIOS/LLMNR/DNS names, OS hints) and scores a table of known
/// device signatures. Each matched clue contributes its weight; clues combine as a noisy-OR,
/// so independent evidence adds up but never exceeds 1. Pure and table-driven.
public enum Fingerprint {
    // MARK: Clues

    struct Clue: Sendable {
        enum Test: Sendable {
            /// OUI vendor or reported manufacturer matches.
            case brand(NSRegularExpression)
            /// Name or hostname (LAN domain stripped) matches.
            case name(NSRegularExpression)
            /// Any identifying text: name, hostname, model, web title, OS hint.
            case text(NSRegularExpression)
            /// A Bonjour/UPnP service label (case-insensitive, exact).
            case service(Set<String>)
            /// Any of these ports open.
            case anyPort(Set<UInt16>)
            /// All of these ports open.
            case allPorts(Set<UInt16>)
            case gateway
            case privateMAC
        }

        var test: Test
        var weight: Double
        /// Optional explanation appended to the generated reason.
        var why: String?
    }

    struct Signature: Sendable {
        var label: String
        var manufacturer: String?
        var model: String?
        var kind: DeviceKind?
        var clues: [Clue]
        /// Regex (first capture group, else whole match) that pulls a model out of the device's text.
        var modelPattern: NSRegularExpression?
        /// Replace "-"/"_" with spaces in an extracted model (hostnames such as "Galaxy-XCover-5").
        var spaceSeparators = false
    }

    // MARK: Identify

    /// Minimum confidence for a signature to be reported.
    public static let threshold = 0.3

    /// Generic models heuristics fill in ("iPhone or iPad"); not evidence, and a confident
    /// fingerprint may replace them.
    public static let placeholderModels: Set<String> = ["iPhone or iPad", "Android device", "Smart device"]

    /// Identifies `d`. `gateway` marks the network's router; `notes` are extra source-specific
    /// facts (e.g. "Name from router DNS") appended to the reasons.
    public static func identify(_ d: Device, gateway: IPv4Address? = nil, notes: [String] = []) -> Identification {
        let ev = Evidence(d, isGateway: gateway == d.ip)
        var best: (sig: Signature, conf: Double, reasons: [(Double, String)])?
        for sig in signatures {
            var miss = 1.0
            var reasons: [(Double, String)] = []
            for clue in sig.clues {
                guard let reason = ev.match(clue) else { continue }
                miss *= 1 - clue.weight
                reasons.append((clue.weight, reason))
            }
            let conf = 1 - miss
            guard conf >= threshold else { continue }
            // Strictly greater (with float slack), so ties keep the earlier, more specific signature.
            if conf > (best?.conf ?? 0) + 1e-9 { best = (sig, conf, reasons) }
        }
        guard let best else { return generic(d, ev: ev, notes: notes) }
        var reasons = dedupe(best.reasons.sorted { $0.0 > $1.0 }.map(\.1))
        reasons += notes.filter { !reasons.contains($0) }
        let model =
            best.sig.modelPattern.flatMap { ev.extractModel($0, spaces: best.sig.spaceSeparators) } ?? best.sig.model
        return Identification(
            manufacturer: best.sig.manufacturer, model: model, kind: best.sig.kind,
            confidence: (best.conf * 100).rounded() / 100, reasons: reasons,
            signature: best.sig.label)
    }

    /// No signature matched: describe what is known.
    static func generic(_ d: Device, ev: Evidence, notes: [String]) -> Identification {
        var miss = 1.0
        var reasons: [String] = []
        func add(_ w: Double, _ r: String) {
            miss *= 1 - w
            reasons.append(r)
        }
        if let m = d.manufacturer, !m.isEmpty, m != d.vendor { add(0.35, "Manufacturer: \(m)") }
        if let m = d.model, !m.isEmpty, !placeholderModels.contains(m) { add(0.3, "Model: \(m)") }
        if let v = d.vendor, !v.isEmpty { add(0.2, "MAC vendor: \(v)") }
        if let n = ev.names.first { add(0.1, "Name “\(n)”") }
        if d.kind != .unknown { add(0.1, "Classified from services and ports as \(d.kind.label)") }
        if reasons.isEmpty {
            reasons.append(
                d.isPrivateMAC
                    ? "Private MAC address and no names, services or open ports"
                    : "No names, services or open ports to go on")
        }
        reasons += notes.filter { !reasons.contains($0) }
        return Identification(confidence: ((1 - miss) * 100).rounded() / 100, reasons: reasons)
    }

    private static func dedupe(_ a: [String]) -> [String] {
        var seen = Set<String>()
        return a.filter { seen.insert($0).inserted }
    }

    // MARK: Evidence

    struct Evidence {
        let vendor: String?
        let manufacturer: String?
        /// (label, value) pairs searched by `.text`.
        let texts: [(String, String)]
        /// Names/hostnames with LAN domains stripped.
        let names: [String]
        let services: Set<String>
        let ports: Set<UInt16>
        let isGateway: Bool
        let isPrivateMAC: Bool

        init(_ d: Device, isGateway: Bool) {
            vendor = d.vendor
            manufacturer = d.manufacturer == d.vendor ? nil : d.manufacturer
            var names: [String] = []
            for n in [d.name, d.hostname].compactMap({ $0 }) {
                let s = NameHints.stripDomain(n)
                if !s.isEmpty, !names.contains(s) { names.append(s) }
            }
            self.names = names
            var texts: [(String, String)] = names.map { ("Name", $0) }
            if let m = d.model, !m.isEmpty, !Fingerprint.placeholderModels.contains(m) { texts.append(("Model", m)) }
            if let t = d.webTitle, !t.isEmpty { texts.append(("Web page", t)) }
            if let o = d.osHint, !o.isEmpty { texts.append(("OS", o)) }
            self.texts = texts
            services = Set(d.services.map { $0.lowercased() })
            ports = Set(d.openPorts.map(\.port))
            self.isGateway = isGateway
            isPrivateMAC = d.isPrivateMAC
        }

        static func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
            re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
        }

        func suffix(_ why: String?) -> String { why.map { " (\($0))" } ?? "" }

        /// The reason text if the clue matches.
        func match(_ c: Clue) -> String? {
            switch c.test {
            case .brand(let re):
                if let m = manufacturer, Self.matches(re, m) { return "Manufacturer: \(m)" + suffix(c.why) }
                if let v = vendor, Self.matches(re, v) { return "MAC vendor: \(v)" + suffix(c.why) }
            case .name(let re):
                if let n = names.first(where: { Self.matches(re, $0) }) { return "Name “\(n)”" + suffix(c.why) }
            case .text(let re):
                if let (label, v) = texts.first(where: { Self.matches(re, $0.1) }) {
                    return "\(label) “\(v)”" + suffix(c.why)
                }
            case .service(let names):
                if let s = services.first(where: { names.contains($0) }) {
                    return "Advertises \(s.capitalizedService)" + suffix(c.why)
                }
            case .anyPort(let ps):
                if let p = ps.filter({ ports.contains($0) }).min() {
                    let label = CommonPorts.all[p].map { " (\($0))" } ?? ""
                    return "Port \(p) open" + (c.why.map { " (\($0))" } ?? label)
                }
            case .allPorts(let ps):
                if !ps.isEmpty, ps.isSubset(of: ports) {
                    return "Ports " + ps.sorted().map(String.init).joined(separator: "+") + " open" + suffix(c.why)
                }
            case .gateway:
                if isGateway { return "Default gateway of this network" }
            case .privateMAC:
                if isPrivateMAC { return "Private (randomized) MAC address" + suffix(c.why) }
            }
            return nil
        }

        func extractModel(_ re: NSRegularExpression, spaces: Bool) -> String? {
            for (_, s) in texts {
                guard let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { continue }
                let r = m.numberOfRanges > 1 && m.range(at: 1).location != NSNotFound ? m.range(at: 1) : m.range
                guard let range = Range(r, in: s) else { continue }
                var out = String(s[range])
                if spaces {
                    out = out.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
                }
                out = out.trimmingCharacters(in: .whitespaces)
                if !out.isEmpty { return out }
            }
            return nil
        }
    }
}

extension String {
    /// "android tv" → "Android TV" for reasons (labels are stored lowercased).
    fileprivate var capitalizedService: String {
        split(separator: " ").map { w in
            let s = String(w)
            return ["tv", "smb", "afp", "ssh", "ipp", "upnp", "mqtt", "esphome", "wled"].contains(s)
                ? (s == "esphome" ? "ESPHome" : s.uppercased()) : s.prefix(1).uppercased() + s.dropFirst()
        }.joined(separator: " ")
    }
}
