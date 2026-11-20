import Foundation

/// Derives manufacturer / model / kind from names, hostnames, services and ports — the evidence
/// that's left when the MAC is randomized or its OUI is generic. Pure; table-driven.
public enum NameHints {
    struct Rule: Sendable {
        /// Regex matched case-insensitively against each of name/hostname (domain suffix stripped).
        var pattern: String
        var manufacturer: String?
        var model: String?
        var kind: DeviceKind?
        var osHint: String? = nil
    }

    static let rules: [Rule] = [
        // Apple
        Rule(pattern: #"iphone"#, manufacturer: "Apple", model: "iPhone", kind: .phone),
        Rule(pattern: #"ipad"#, manufacturer: "Apple", model: "iPad", kind: .tablet),
        Rule(pattern: #"macbook[- ]?air"#, manufacturer: "Apple", model: "MacBook Air", kind: .computer),
        Rule(
            pattern: #"macbook[- ]?pro|-mbp($|[-.])|^mbp[-.]"#, manufacturer: "Apple", model: "MacBook Pro",
            kind: .computer),
        Rule(pattern: #"macbook"#, manufacturer: "Apple", model: "MacBook", kind: .computer),
        Rule(pattern: #"^imac|[-_ ]imac"#, manufacturer: "Apple", model: "iMac", kind: .computer),
        Rule(pattern: #"mac[- ]?mini"#, manufacturer: "Apple", model: "Mac mini", kind: .computer),
        Rule(pattern: #"mac[- ]?studio"#, manufacturer: "Apple", model: "Mac Studio", kind: .computer),
        Rule(pattern: #"apple[- ]?tv"#, manufacturer: "Apple", model: "Apple TV", kind: .tv),
        Rule(pattern: #"homepod"#, manufacturer: "Apple", model: "HomePod", kind: .speaker),
        Rule(pattern: #"apple[- ]?watch"#, manufacturer: "Apple", model: "Apple Watch", kind: .phone),
        // Android / Samsung
        Rule(pattern: #"^galaxy[-_ ]|^sm-[a-z]\d"#, manufacturer: "Samsung", model: "Galaxy", kind: .phone),
        Rule(pattern: #"^android[-_]"#, manufacturer: nil, model: "Android device", kind: .phone, osHint: "Android"),
        Rule(pattern: #"^pixel[-_ ]"#, manufacturer: "Google", model: "Pixel", kind: .phone, osHint: "Android"),
        // Microcontrollers / smart home
        Rule(pattern: #"^esp_[0-9a-f]{6}$|^esp8266"#, manufacturer: "Espressif", model: "ESP8266", kind: .iot),
        Rule(pattern: #"^esp32"#, manufacturer: "Espressif", model: "ESP32", kind: .iot),
        Rule(pattern: #"^shelly"#, manufacturer: "Shelly", model: nil, kind: .iot),
        Rule(pattern: #"^tasmota[-_]"#, manufacturer: nil, model: nil, kind: .iot, osHint: "Tasmota"),
        Rule(pattern: #"^wled[-_]"#, manufacturer: nil, model: nil, kind: .iot, osHint: "WLED"),
        Rule(pattern: #"^lgwebostv|^lg-?webos"#, manufacturer: "LG", model: "webOS TV", kind: .tv, osHint: "webOS"),
        Rule(pattern: #"^chromecast"#, manufacturer: "Google", model: "Chromecast", kind: .tv),
        Rule(pattern: #"^google-?(home|nest)"#, manufacturer: "Google", model: "Nest speaker", kind: .speaker),
        Rule(pattern: #"^roborock|^rockrobo"#, manufacturer: "Roborock", model: "Robot vacuum", kind: .iot),
        Rule(pattern: #"^dirigera"#, manufacturer: "IKEA", model: "DIRIGERA Hub", kind: .iot),
        Rule(pattern: #"^philips-hue|^hue-?bridge"#, manufacturer: "Philips Hue", model: "Hue Bridge", kind: .iot),
        // NAS / servers
        Rule(pattern: #"^truenas|^freenas"#, manufacturer: nil, model: nil, kind: .nas, osHint: "TrueNAS"),
        Rule(
            pattern: #"^synology|^diskstation|^ds\d{3,4}"#, manufacturer: "Synology", model: "DiskStation", kind: .nas,
            osHint: "DSM"),
        Rule(pattern: #"^raspberrypi|^raspberry-?pi"#, manufacturer: "Raspberry Pi", model: nil, kind: .computer),
        Rule(
            pattern: #"^homeassistant$|^home-assistant"#, manufacturer: nil, model: nil, kind: .iot,
            osHint: "Home Assistant"),
        Rule(pattern: #"^proxmox|^pve\d*$"#, manufacturer: nil, model: nil, kind: .computer, osHint: "Proxmox VE"),
        // Windows
        Rule(
            pattern: #"^(desktop|laptop)-[a-z0-9]{5,}$"#, manufacturer: nil, model: "Windows PC", kind: .computer,
            osHint: "Windows"),
    ]

    private static let compiled: [(NSRegularExpression, Rule)] = rules.compactMap { r in
        (try? NSRegularExpression(pattern: r.pattern, options: [.caseInsensitive])).map { ($0, r) }
    }

    /// A patch with whatever the device's names/services/ports imply, or nil if nothing.
    /// Callers should only use it to fill fields that are still empty.
    public static func patch(for d: Device) -> DevicePatch? {
        var p = DevicePatch(ip: d.ip)
        let names = [d.name, d.hostname].compactMap { $0.map(stripDomain) }.filter { !$0.isEmpty }

        if let rule = names.lazy.compactMap(match).first {
            p.manufacturer = rule.manufacturer
            p.model = rule.model
            p.kind = rule.kind
            p.osHint = rule.osHint
        }

        let ports = Set(d.openPorts.map(\.port))
        let services = Set(d.services.map { $0.lowercased() })
        let brand = (d.manufacturer ?? d.vendor ?? "").lowercased()

        // lockdownd (iPhone/iPad sync) only runs on iOS devices.
        if p.manufacturer == nil, ports.contains(62078) {
            p.manufacturer = "Apple"
            if p.model == nil {
                p.model = "iPhone or iPad"
                p.kind = .phone
            }
        }
        // _companion-link / _apple-mobdev2 are Apple-only.
        if p.manufacturer == nil, services.contains("apple device") || services.contains("airplay") {
            p.manufacturer = "Apple"
        }
        // Tuya devices listen on 6668.
        if p.manufacturer == nil, ports.contains(6668),
            brand.contains("tuya") || d.isPrivateMAC || brand.isEmpty
        {
            p.manufacturer = "Tuya"
            p.model = "Smart device"
            p.kind = .iot
        }
        if p.manufacturer == nil, p.model == nil, brand.contains("tuya") {
            p.model = "Smart device"
            p.kind = .iot
        }
        // ESPHome devices expose their native API on 6053.
        if ports.contains(6053) || services.contains("esphome") {
            p.osHint = p.osHint ?? "ESPHome"
            p.kind = p.kind ?? .iot
        }
        if brand.contains("espressif") {
            p.kind = p.kind ?? .iot
        }

        let empty = p.manufacturer == nil && p.model == nil && p.kind == nil && p.osHint == nil
        return empty ? nil : p
    }

    static func match(_ name: String) -> Rule? {
        let range = NSRange(name.startIndex..., in: name)
        return compiled.first { $0.0.firstMatch(in: name, range: range) != nil }?.1
    }

    static func stripDomain(_ s: String) -> String {
        var h = s
        for suffix in [".local.", ".local", ".lan", ".home", ".fritz.box", "."] where h.lowercased().hasSuffix(suffix) {
            h.removeLast(suffix.count)
        }
        return h
    }
}

// MARK: - Weak merges

extension Device {
    /// osHints that a more specific hint may replace.
    static let weakOSHints: Set<String> = ["Samba", "Embedded Linux", "Linux", "Windows"]

    /// Merges a patch from a weaker source: only fills fields that are still empty (an existing
    /// weak osHint may be refined), unions services/ports, and only sets kind when unknown.
    public mutating func fillGaps(from p: DevicePatch) {
        precondition(p.ip == ip, "patch for a different device")
        if mac == nil { mac = p.mac }
        if vendor == nil { vendor = p.vendor }
        if hostname == nil { hostname = p.hostname }
        if name?.isEmpty ?? true, let v = p.name, !v.isEmpty { name = v }
        if manufacturer == nil { manufacturer = p.manufacturer }
        if model?.isEmpty ?? true, let v = p.model, !v.isEmpty { model = v }
        if kind == .unknown, let k = p.kind { kind = k }
        services.formUnion(p.services)
        if !p.openPorts.isEmpty { openPorts = Array(Set(openPorts).union(p.openPorts)).sorted() }
        if let v = p.osHint, !v.isEmpty,
            osHint.map({ Self.weakOSHints.contains($0) && !Self.weakOSHints.contains(v) }) ?? true
        {
            osHint = v
        }
        if webTitle == nil, let v = p.webTitle, !v.isEmpty { webTitle = v }
        if let v = p.responseTime, responseTime.map({ v < $0 }) ?? true { responseTime = v }
    }
}
