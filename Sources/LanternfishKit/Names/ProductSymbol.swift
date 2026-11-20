import Foundation

/// Product-specific SF Symbols for device icons ("homepod.mini" for a HomePod mini rather than the
/// generic speaker), derived from the strings discovery actually produces: Bonjour models (friendly
/// names such as "Mac mini", or raw identifiers such as "AudioAccessory5,1"), names, hostnames,
/// service labels, fingerprinted manufacturer/model and OUI vendors.
///
/// Every symbol name used here is pinned by `ProductSymbolTests.allSymbols`, and verified to exist
/// in the SDK.
public enum ProductSymbol {
    public struct Match: Sendable, Hashable {
        /// SF Symbol name.
        public let symbol: String
        /// Human-readable product, used as the icon's accessibility label (e.g. "Apple TV").
        public let label: String
        /// The kind this product implies.
        public let kind: DeviceKind
    }

    /// The product symbol for `device`, or nil when nothing makes the product clear.
    public static func symbol(for device: Device) -> String? { match(for: device)?.symbol }

    /// The first recognized product whose kind agrees with the device's effective kind. Devices of
    /// unknown kind (and no user type) accept any product. The user's `customKind` therefore always wins: a product
    /// that implies a different kind is ignored and the icon falls back to the kind symbol.
    public static func match(for device: Device) -> Match? {
        let e = Evidence(device)
        let kind = device.effectiveKind
        // Only the classifier's "don't know" is a wildcard; a user who picked Unknown meant it.
        let anyKind = device.customKind == nil && kind == .unknown
        for rule in rules where anyKind || rule.kind == kind {
            if let m = rule.match(e) { return m }
        }
        return nil
    }

    // MARK: - Rules

    private struct Rule: Sendable {
        let kind: DeviceKind
        let match: @Sendable (Evidence) -> Match?

        /// A fixed product.
        init(_ symbol: String, _ label: String, _ kind: DeviceKind, _ test: @escaping @Sendable (Evidence) -> Bool) {
            self.kind = kind
            let m = Match(symbol: symbol, label: label, kind: kind)
            match = { test($0) ? m : nil }
        }

        /// A product whose symbol or label depends on the evidence.
        init(kind: DeviceKind, _ match: @escaping @Sendable (Evidence) -> Match?) {
            self.kind = kind
            self.match = match
        }
    }

    /// Most specific first; the first rule that fits the device's kind and matches wins.
    private static let rules: [Rule] = [
        // Apple
        Rule("homepod.mini", "HomePod mini", .speaker) {
            $0.rawModel(hasPrefix: "AudioAccessory5,") || ($0.model == "homepod" && $0.has("homepod mini"))
                || $0.has("homepod mini", "homepodmini")
        },
        Rule("homepod", "HomePod", .speaker) { $0.model == "homepod" || $0.has("homepod") },
        Rule("appletv", "Apple TV", .tv) { $0.model == "apple tv" || $0.has("apple tv", "appletv") },
        Rule("macmini", "Mac mini", .computer) { $0.model == "mac mini" || $0.has("mac mini", "macmini") },
        Rule("macstudio", "Mac Studio", .computer) { $0.model == "mac studio" || $0.has("mac studio", "macstudio") },
        Rule(kind: .computer) { e in
            guard e.model == "mac pro" || e.has("mac pro", "macpro") else { return nil }
            // MacPro1–5 are the cheese grater, MacPro6 the cylinder, MacPro7 on the tower.
            let gen = e.rawModelNumber(prefix: "MacPro").map { $0 <= 5 ? "gen1" : $0 == 6 ? "gen2" : "gen3" } ?? "gen3"
            return Match(symbol: "macpro.\(gen)", label: "Mac Pro", kind: .computer)
        },
        Rule("desktopcomputer", "iMac", .computer) { $0.model?.hasPrefix("imac") == true || $0.has("imac") },
        Rule(kind: .computer) { e in
            guard e.model?.hasPrefix("macbook") == true || e.has("macbook") else { return nil }
            let label =
                e.model.flatMap { ["macbook pro": "MacBook Pro", "macbook air": "MacBook Air"][$0] }
                ?? (e.has("macbook pro", "macbookpro")
                    ? "MacBook Pro" : e.has("macbook air", "macbookair") ? "MacBook Air" : "MacBook")
            return Match(symbol: "laptopcomputer", label: label, kind: .computer)
        },
        Rule("visionpro", "Apple Vision Pro", .tablet) { $0.model == "apple vision pro" || $0.has("vision pro") },
        Rule("applewatch", "Apple Watch", .phone) { $0.model == "apple watch" || $0.has("apple watch") },
        Rule("iphone", "iPhone", .phone) { $0.model == "iphone" || $0.has("iphone") },
        Rule("ipad", "iPad", .tablet) { $0.model == "ipad" || $0.has("ipad") },
        Rule(kind: .router) { e in
            guard
                e.service("airport base station", "airport")
                    || e.has("airport extreme", "airport express", "time capsule")
            else { return nil }
            if e.has("airport express") {
                return Match(symbol: "airport.express", label: "AirPort Express", kind: .router)
            }
            if e.has("time capsule") {
                return Match(symbol: "airport.extreme.tower", label: "AirPort Time Capsule", kind: .router)
            }
            return Match(symbol: "airport.extreme", label: "AirPort Base Station", kind: .router)
        },

        // Game consoles
        Rule("playstation.logo", "PlayStation", .gameConsole) { $0.has("playstation", "ps5", "ps4", "ps3") },
        Rule("xbox.logo", "Xbox", .gameConsole) { $0.has("xbox") },

        // Streaming
        Rule("mediastick", "Chromecast", .tv) { $0.has("chromecast") },
        Rule("mediastick", "Fire TV Stick", .tv) { $0.has("fire tv stick", "firetv stick", "fire tv", "firetv") },
        Rule("tv.and.mediabox", "NVIDIA Shield", .tv) { $0.has("shield tv", "nvidia shield") },

        // Speakers
        Rule("hifispeaker.2", "Sonos", .speaker) { $0.has("sonos") || $0.brand("sonos") || $0.service("sonos") },

        // Smart home
        Rule("video.doorbell", "Video Doorbell", .camera) { $0.has("doorbell") },
        Rule("homekit", "Smart Home Hub", .iot) {
            $0.has(
                "dirigera", "tradfri", "trådfri", "home assistant", "homeassistant", "homey", "smartthings",
                "hubitat", "deconz", "smart home hub")
                || $0.service("home assistant")
        },
        Rule("lightbulb.led.fill", "Philips Hue", .iot) {
            $0.service("philips hue", "hue") || $0.has("philips hue", "hue bridge") || $0.brand("signify")
        },
        Rule("light.strip.2", "LED Strip", .iot) { $0.service("wled") || $0.has("wled", "led strip", "lightstrip") },
        Rule("thermometer.medium", "Thermostat", .iot) {
            $0.has("thermostat", "tado", "ecobee", "netatmo", "evohome")
        },
        Rule("robotic.vacuum", "Robot Vacuum", .iot) {
            $0.has("robot vacuum", "roborock", "roomba", "irobot", "dreame", "deebot", "ecovacs")
        },
        Rule("ev.charger", "EV Charger", .iot) {
            $0.has("ev charger", "easee", "zaptec", "wallbox", "alfen", "wall connector")
        },
        Rule("powerplug.fill", "Smart Plug", .iot) { $0.has("smart plug", "plug") },
        Rule("sensor.fill", "Sensor", .iot) {
            $0.has("sensor", "air quality", "co2", "temperature", "humidity", "weather station")
        },
        Rule("cpu", "Microcontroller", .iot) {
            $0.service("esphome") || $0.has("esphome", "esp32", "esp8266", "tasmota") || $0.brand("espressif")
        },
        Rule("homekit", "HomeKit Accessory", .iot) { $0.service("homekit") },

        // Printers
        Rule("cube.fill", "3D Printer", .printer) {
            $0.has("3d printer", "bambu", "prusa", "octoprint", "klipper", "creality", "mainsail", "fluidd")
                || $0.service("bambu lab") || $0.brand("bambu")
        },
        Rule("printer.fill", "Printer", .printer) {
            $0.service("printer", "ipp", "ipps", "pdl datastream")
                || $0.has("printer", "laserjet", "officejet", "deskjet", "pixma", "ecotank", "ecosys", "taskalfa")
                // These brands also make PCs and cameras: their OUI alone isn't enough.
                || ($0.kind == .printer
                    && $0.brand("hp", "hewlett", "epson", "brother", "canon", "kyocera", "xerox", "lexmark", "ricoh"))
        },

        // NAS and servers
        Rule("server.rack", "Server", .nas) {
            $0.has("truenas", "freenas", "unraid") || ($0.model?.hasPrefix("rs") == true && $0.brand("synology"))
        },
        Rule("externaldrive.fill", "NAS", .nas) {
            $0.brand("synology", "qnap") || $0.has("diskstation", "synology", "qnap")
        },
        Rule("server.rack", "Server", .computer) { $0.has("proxmox", "server") },

        // Computers
        Rule("cpu", "Raspberry Pi", .computer) { $0.has("raspberry pi", "raspberrypi") || $0.brand("raspberry") },
        Rule("pc", "Windows PC", .computer) { $0.has("windows") },

        // Phones and wearables
        Rule("watch.analog", "Smartwatch", .phone) {
            $0.has("garmin watch", "forerunner", "fenix", "fitbit", "smartwatch", "galaxy watch")
                || ($0.kind == .phone && $0.brand("garmin", "fitbit"))
        },
        Rule("smartphone", "Android Phone", .phone) {
            $0.has(
                "android", "galaxy", "pixel", "oneplus", "xiaomi", "redmi", "huawei", "oppo", "motorola", "fairphone")
                || ($0.kind == .phone
                    && $0.brand("samsung", "google", "xiaomi", "oneplus", "huawei", "oppo", "motorola", "fairphone"))
        },
    ]

    /// Every symbol `match(for:)` can return (pinned by the tests).
    public static let allSymbols: Set<String> = [
        "homepod.mini", "homepod", "appletv", "macmini", "macstudio", "macpro.gen1", "macpro.gen2", "macpro.gen3",
        "desktopcomputer", "laptopcomputer", "visionpro", "applewatch", "iphone", "ipad", "airport.express",
        "airport.extreme.tower", "airport.extreme", "playstation.logo", "xbox.logo", "mediastick", "tv.and.mediabox",
        "hifispeaker.2", "video.doorbell", "homekit", "lightbulb.led.fill", "light.strip.2", "thermometer.medium",
        "robotic.vacuum", "ev.charger", "powerplug.fill", "sensor.fill", "cpu", "cube.fill", "printer.fill",
        "server.rack", "externaldrive.fill", "pc", "watch.analog", "smartphone",
    ]
}

// MARK: - Evidence

/// Normalized, word-boundary-aware view of the strings that identify a device.
private struct Evidence {
    /// Name, hostname, model, manufacturer, web title and OS hint, in `DeviceText.padded` form.
    let text: String
    /// Manufacturer and OUI vendor, same format.
    let brandText: String
    /// Lowercased friendly model ("mac mini"), with raw Apple identifiers mapped to their family.
    let model: String?
    /// The model as discovered (may be a raw identifier such as "AudioAccessory5,1").
    let rawModel: String?
    /// Service types and labels, lowercased, without leading "_" and "._tcp".
    let services: [String]
    /// The classified kind (not the user's).
    let kind: DeviceKind

    init(_ d: Device) {
        var raw = d.model?.trimmingCharacters(in: .whitespaces)
        if raw?.isEmpty == true { raw = nil }
        // "iPhone or iPad" and similar guesses don't identify a product.
        let ambiguous = raw?.localizedCaseInsensitiveContains(" or ") == true
        rawModel = ambiguous ? nil : raw
        model = rawModel.map { (BonjourTXT.appleFriendlyName($0) ?? $0).lowercased() }
        let fields = [d.name, d.hostname, ambiguous ? nil : model, d.manufacturer, d.webTitle, d.osHint]
        text = Self.padded(fields)
        brandText = Self.padded([d.manufacturer, d.vendor])
        services = d.services.map { DeviceText.padded(DeviceText.serviceStem($0)) }
        kind = d.kind
    }

    private static func padded(_ fields: [String?]) -> String {
        DeviceText.padded(fields.compactMap { $0 }.joined(separator: " "))
    }

    /// See `DeviceText.contains(_:anyOf:)` for the matching rules.
    func has(_ words: String...) -> Bool { DeviceText.contains(text, anyOf: words) }
    func brand(_ words: String...) -> Bool { DeviceText.contains(brandText, anyOf: words) }

    /// Whole-phrase match against a service type or label ("hue" matches "Philips Hue", not "hued").
    func service(_ names: String...) -> Bool {
        names.contains { n in
            let phrase = DeviceText.padded(n)
            return services.contains { $0.contains(phrase) }
        }
    }

    func rawModel(hasPrefix prefix: String) -> Bool { rawModel?.hasPrefix(prefix) == true }

    /// "MacPro6,1" with prefix "MacPro" → 6.
    func rawModelNumber(prefix: String) -> Int? {
        guard let raw = rawModel, raw.hasPrefix(prefix) else { return nil }
        return Int(raw.dropFirst(prefix.count).prefix(while: \.isNumber))
    }
}

// MARK: - Brand monogram

/// 1–2 letter badges for devices known only by brand ("Sonos" → "S", "Hewlett Packard" → "HP").
public enum BrandMonogram {
    /// Corporate and descriptive words dropped from the end of a brand before taking initials.
    private static let fillerWords: Set<String> = [
        "communications", "electronics", "electronic", "technologies", "technology", "tech", "corporation", "corp",
        "co", "company", "inc", "incorporated", "ltd", "limited", "llc", "gmbh", "ag", "ab", "bv", "sa", "sas", "plc",
        "international", "systems", "system", "wireless", "solutions", "display", "networks", "network",
        "semiconductor", "semiconductors", "labs", "lab", "group", "holdings", "industries", "industrial",
        "devices", "digital", "manufacturing", "products", "the",
    ]

    /// The brand's significant words: "Zyxel Communications Corp." → ["Zyxel"], "IKEA of Sweden" → ["IKEA"].
    static func words(_ brand: String) -> [String] {
        var words = brand.split(whereSeparator: { $0 == " " || $0 == "," || $0 == "." || $0 == "(" || $0 == ")" })
            .map(String.init)
        if let of = words.firstIndex(where: { $0.lowercased() == "of" }), of > 0 { words.removeSubrange(of...) }
        while words.count > 1, fillerWords.contains(words[words.count - 1].lowercased()) { words.removeLast() }
        return words.filter { $0.contains(where: { $0.isLetter || $0.isNumber }) }
    }

    /// Up to two uppercase letters, or nil when the brand has none.
    public static func letters(for brand: String) -> String? {
        let ws = words(brand)
        guard let first = ws.first else { return nil }
        let alnum = { (s: Substring) in String(s.filter { $0.isLetter || $0.isNumber }) }
        // "LG", "HP", "TP-Link" → the two-letter acronym.
        let lead = alnum(first.split(whereSeparator: { $0 == "-" || $0 == "&" || $0 == "!" }).first ?? Substring(first))
        if lead.count == 2, lead == lead.uppercased(), lead.allSatisfy(\.isLetter) { return lead }
        guard let initial = alnum(Substring(first)).first else { return nil }
        // "Hewlett Packard" → "HP" (second word capitalized), else the first letter.
        if ws.count >= 2, let second = alnum(Substring(ws[1])).first, second.isUppercase {
            return (String(initial) + String(second)).uppercased()
        }
        return String(initial).uppercased()
    }

    /// Stable palette index for `brand` (FNV-1a over the normalized brand, so it survives relaunches,
    /// unlike `hashValue`). Spelling variants that differ only in corporate suffixes share a color.
    public static func paletteIndex(for brand: String, count: Int) -> Int {
        guard count > 0 else { return 0 }
        let key = words(brand).joined(separator: " ").lowercased()
        var hash: UInt32 = 2_166_136_261
        for byte in key.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return Int(hash % UInt32(count))
    }
}
