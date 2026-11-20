import Foundation

/// Tidies raw names from UPnP descriptions and other machine sources: firmware/board ids such as
/// "GRX350_1600_MR_AXEPOINT_6X_WAV60" are not names, "NETGEAR, Inc." is "Netgear". Pure.
public enum NameCleanup {
    // MARK: Manufacturer

    /// Canonical spellings for brands that report themselves in odd casing or with legal suffixes.
    /// Keys are lowercase prefixes of the cleaned manufacturer string.
    private static let brands: [(prefix: String, name: String)] = [
        ("netgear", "Netgear"), ("sony", "Sony"), ("tp-link", "TP-Link"), ("tplink", "TP-Link"),
        ("samsung", "Samsung"), ("lg electronics", "LG"), ("lge", "LG"), ("philips hue", "Philips Hue"),
        ("philips", "Philips"),
        ("signify", "Philips Hue"), ("synology", "Synology"), ("sonos", "Sonos"), ("microsoft", "Microsoft"),
        ("google", "Google"), ("amazon", "Amazon"), ("roku", "Roku"), ("yamaha", "Yamaha"), ("denon", "Denon"),
        ("bose", "Bose"), ("hewlett-packard", "HP"), ("hewlett packard", "HP"), ("hp inc", "HP"),
        ("seiko epson", "Epson"), ("epson", "Epson"), ("brother", "Brother"), ("canon", "Canon"),
        ("kyocera", "Kyocera"), ("ubiquiti", "Ubiquiti"), ("asustek", "ASUS"), ("asus", "ASUS"),
        ("avm", "AVM"), ("xiaomi", "Xiaomi"), ("huawei", "Huawei"), ("zyxel", "Zyxel"), ("linksys", "Linksys"),
        ("d-link", "D-Link"), ("panasonic", "Panasonic"), ("hisense", "Hisense"), ("tcl", "TCL"),
        ("vizio", "Vizio"), ("nvidia", "NVIDIA"), ("apple", "Apple"), ("qnap", "QNAP"), ("ikea", "IKEA"),
        ("bambu", "Bambu Lab"), ("shenzhen bambu", "Bambu Lab"), ("arcadyan", "Arcadyan"),
        ("sagemcom", "Sagemcom"), ("technicolor", "Technicolor"), ("plex", "Plex"),
    ]

    private static let legalSuffixes = [
        ", inc.", ", inc", " inc.", " inc", ", ltd.", " ltd.", " ltd", " co., ltd.", " co.,ltd.", " co. ltd",
        " corporation", " corp.", " corp", " co.", " co", " gmbh", " ag", " b.v.", " bv", " s.a.", " llc", " limited",
        " electronics", " technologies", " technology",
    ]

    /// "NETGEAR, Inc." → "Netgear", "Sony Corporation" → "Sony". Unknown brands only lose legal suffixes.
    public static func manufacturer(_ raw: String?) -> String? {
        guard var m = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !m.isEmpty else { return nil }
        let lower = m.lowercased()
        if let b = brands.first(where: { lower.hasPrefix($0.prefix) }) { return b.name }
        var changed = true
        while changed {
            changed = false
            for s in legalSuffixes where m.lowercased().hasSuffix(s) && m.count > s.count + 1 {
                m.removeLast(s.count)
                m = m.trimmingCharacters(in: CharacterSet(charactersIn: " ,"))
                changed = true
            }
        }
        return m.isEmpty ? nil : m
    }

    // MARK: Firmware-ish identifiers

    /// True for strings that are board / firmware / serial identifiers rather than names, e.g.
    /// "GRX350_1600_MR_AXEPOINT_6X_WAV60", "SOC_7621_V2_REV3", "5U9193WKA1115", "a1b2c3d4e5f6".
    public static func isFirmwareish(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        if t.contains(" ") {
            // Only if every word is firmware-ish.
            let words = t.split(separator: " ").map(String.init)
            return words.count > 1 && words.allSatisfy(isFirmwareish)
        }
        let parts = t.split(whereSeparator: { $0 == "_" }).map(String.init)
        if parts.count >= 3 {
            let shouty = parts.filter { p in p.allSatisfy { $0.isUppercase || $0.isNumber } }
            if shouty.count * 2 >= parts.count { return true }
        }
        let alnum = t.filter { $0 != "-" && $0 != ":" && $0 != "_" }
        // Long hex strings (MACs, ids).
        if alnum.count >= 10, alnum.allSatisfy(\.isHexDigit), alnum.contains(where: \.isNumber),
            alnum.contains(where: \.isLetter) || alnum.count >= 12
        {
            return true
        }
        // Serial-like: long run of caps+digits with many digits, e.g. "5U9193WKA1115".
        if alnum.count >= 11, alnum.allSatisfy({ $0.isNumber || $0.isUppercase }),
            alnum.filter(\.isNumber).count >= 4
        {
            return true
        }
        return false
    }

    /// Drops firmware-ish words from a model string: "GRX350_1600_MR_AXEPOINT_6X_WAV60 RAX40" → "RAX40".
    public static func model(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        let words = raw.split(separator: " ").map(String.init)
        let kept = words.filter { !isFirmwareish($0) }
        let out = kept.joined(separator: " ")
        return out.isEmpty ? nil : out
    }

    /// A UPnP friendlyName unless it is a firmware/board id; then "Brand Model" (or nil).
    public static func friendlyName(_ raw: String?, manufacturer: String?, model: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        guard isFirmwareish(raw) || isFirmwareish(raw.split(separator: " ").first.map(String.init) ?? "") else {
            return raw
        }
        let brand = self.manufacturer(manufacturer)
        let m = self.model(model)
        switch (brand, m) {
        case (let b?, let m?): return m.localizedCaseInsensitiveContains(b) ? m : "\(b) \(m)"
        case (nil, let m?): return m
        case (let b?, nil): return b
        default: return nil
        }
    }

    /// Cleans a device in place. Also applied to history snapshots, which may hold names saved
    /// before these rules existed.
    public static func sanitize(_ d: inout Device) {
        if let m = d.manufacturer { d.manufacturer = manufacturer(m) ?? m }
        if let m = d.model, model(m) != m { d.model = model(m) }
        if let n = d.name, !n.isEmpty {
            d.name = friendlyName(n, manufacturer: d.manufacturer ?? d.vendor, model: d.model)
        }
    }
}
