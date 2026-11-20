import Foundation

/// What a service banner (web page, SSH greeting) reveals about a device.
public struct BannerHints: Sendable, Equatable {
    public var webTitle: String?
    public var osHint: String?
    public var manufacturer: String?
    public var model: String?
    public var kind: DeviceKind?
    /// Software or product recognised on the page (e.g. "TrueNAS", "Coolify"). Used as a
    /// fallback web title when the page's own title is useless.
    public var product: String?

    public init(
        webTitle: String? = nil, osHint: String? = nil, manufacturer: String? = nil,
        model: String? = nil, kind: DeviceKind? = nil, product: String? = nil
    ) {
        self.webTitle = webTitle
        self.osHint = osHint
        self.manufacturer = manufacturer
        self.model = model
        self.kind = kind
        self.product = product
    }

    public var isEmpty: Bool { self == BannerHints() }

    /// A rough measure of how much this banner tells us; used to rank results across ports.
    var score: Int {
        (manufacturer != nil ? 4 : 0) + (model != nil ? 4 : 0) + (osHint != nil ? 2 : 0)
            + (product != nil ? 2 : 0) + (kind != nil ? 1 : 0) + (webTitle != nil ? 1 : 0)
    }

    /// Fills nil fields of `self` from `other`.
    mutating func fill(from other: BannerHints) {
        webTitle = webTitle ?? other.webTitle
        osHint = osHint ?? other.osHint
        manufacturer = manufacturer ?? other.manufacturer
        model = model ?? other.model
        kind = kind ?? other.kind
        product = product ?? other.product
    }
}

/// Pure parsing of HTTP and SSH banners. No I/O, fully unit-tested.
public enum BannerParser {
    // MARK: HTML title

    /// The contents of the first `<title>` element, entity-decoded and whitespace-collapsed.
    public static func extractTitle(_ html: String) -> String? {
        guard let open = html.range(of: "<title", options: .caseInsensitive),
            let gt = html[open.upperBound...].firstIndex(of: ">")
        else { return nil }
        let rest = html[html.index(after: gt)...]
        let end = rest.range(of: "</title", options: .caseInsensitive)?.lowerBound ?? rest.endIndex
        let raw = String(rest[..<end].prefix(400))
        let t = cleanTitle(decodeEntities(raw))
        return t.isEmpty ? nil : t
    }

    /// Collapses whitespace and strips decorative punctuation such as ".::Title::.".
    static func cleanTitle(_ s: String) -> String {
        let collapsed = s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let decoration = CharacterSet(charactersIn: ".:-|•*_~=#·»« ")
        var t = collapsed.trimmingCharacters(in: decoration)
        if t.count > 80 { t = String(t.prefix(80)).trimmingCharacters(in: .whitespaces) + "…" }
        return t
    }

    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
        "ndash": "–", "mdash": "—", "copy": "©", "reg": "®", "trade": "™", "middot": "·",
        "raquo": "»", "laquo": "«", "hellip": "…", "uuml": "ü", "ouml": "ö", "auml": "ä",
        "eacute": "é", "egrave": "è", "szlig": "ß",
    ]

    /// Decodes named (`&amp;`) and numeric (`&#39;`, `&#x27;`) HTML entities.
    public static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            guard c == "&", let semi = s[i...].prefix(12).firstIndex(of: ";") else {
                out.append(c)
                i = s.index(after: i)
                continue
            }
            let entity = s[s.index(after: i)..<semi]
            var replacement: String?
            if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
                replacement = UInt32(entity.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String($0) }
            } else if entity.hasPrefix("#") {
                replacement = UInt32(entity.dropFirst()).flatMap(Unicode.Scalar.init).map { String($0) }
            } else {
                replacement = namedEntities[entity.lowercased()]
            }
            if let replacement {
                out += replacement
                i = s.index(after: semi)
            } else {
                out.append(c)
                i = s.index(after: i)
            }
        }
        return out
    }

    private static let uselessTitles: Set<String> = [
        "404", "404 not found", "not found", "403", "403 forbidden", "forbidden", "401", "401 unauthorized",
        "unauthorized", "error", "page not found", "login", "log in", "sign in", "signin", "logon", "redirecting",
        "redirect", "redirecting...", "loading", "loading...", "please wait", "please wait...", "document",
        "untitled", "home", "index", "main", "welcome", "default site", "default page", "welcome to nginx!",
        "it works!", "it works", "web-based configurator", "welcome to the web-based configurator",
        "web configurator", "302 found", "301 moved permanently", "moved", "object moved", "web server", "title",
        "app", "react app", "vite app", "vite + react", "vite + react + ts", "iis windows server",
        "apache2 ubuntu default page: it works", "apache2 debian default page: it works",
        "test page for the nginx http server", "test page for the apache http server",
        "502 bad gateway", "503 service unavailable", "bad request", "400 bad request", "web ui", "webui",
    ]

    /// Whether a page title says something about the device.
    public static func isUsefulTitle(_ title: String?) -> Bool {
        guard let t = title?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return false }
        let l = t.lowercased()
        if uselessTitles.contains(l) { return false }
        if l.hasPrefix("index of") || l.hasPrefix("error") || l.hasPrefix("403 ") || l.hasPrefix("404 ") {
            return false
        }
        if l.allSatisfy({ $0.isNumber || $0.isWhitespace || $0.isPunctuation }) { return false }
        return true
    }

    // MARK: HTTP

    /// Interprets a web page. `title` may be passed pre-extracted; otherwise it is read from `body`.
    public static func parseHTML(title: String?, server: String?, body: String) -> BannerHints {
        let title = title.map { cleanTitle(decodeEntities($0)) } ?? extractTitle(body)
        var h = BannerHints()
        if isUsefulTitle(title) { h.webTitle = title }

        let t = title ?? ""
        let srv = server ?? ""
        // Search only the start of the page for markers; product names show up in the head.
        let page = String(body.prefix(64 * 1024))
        let all = t + "\n" + srv + "\n" + page
        func has(_ s: String) -> Bool { all.range(of: s, options: .caseInsensitive) != nil }
        func inTitle(_ s: String) -> Bool { t.range(of: s, options: .caseInsensitive) != nil }

        identifyProduct(&h, title: t, all: all, has: has, inTitle: inTitle)

        // Server header OS hints.
        if h.osHint == nil {
            h.osHint = osHint(fromServer: srv)
        }
        if h.osHint == nil, let tl = title?.lowercased() {
            if tl.contains("ubuntu default page") {
                h.osHint = "Ubuntu"
            } else if tl.contains("debian default page") {
                h.osHint = "Debian"
            } else if tl == "iis windows server" {
                h.osHint = "Windows"
            }
        }
        if srv.lowercased().hasPrefix("airtunes") {
            h.manufacturer = h.manufacturer ?? "Apple"
        }
        if h.webTitle == nil, let p = h.product { h.webTitle = p }
        return h
    }

    private static func identifyProduct(
        _ h: inout BannerHints, title t: String, all: String,
        has: (String) -> Bool, inTitle: (String) -> Bool
    ) {
        // NAS
        // TrueNAS SCALE's Angular shell has an empty title; its iX theme classes give it away.
        if has("TrueNAS") || has("<ix-root") || all.contains(".ix-dark{") {
            h.osHint = "TrueNAS"
            h.product = "TrueNAS"
            h.kind = .nas
            return
        }
        if has("FreeNAS") {
            h.osHint = "FreeNAS"
            h.product = "FreeNAS"
            h.kind = .nas
            return
        }
        if has("Synology") || inTitle("DiskStation") || has("SYNO.SDS") {
            h.manufacturer = "Synology"
            h.osHint = "DSM"
            h.kind = .nas
            h.product = "Synology DSM"
            h.model =
                firstMatch(#"\b(?:DS|RS|DVA|FS|SA)\d{3,4}(?:xs\+|\+|xs|j|play)?(?![A-Za-z0-9])"#, in: all)
                ?? "DiskStation"
            return
        }
        if has("QNAP") {
            h.manufacturer = "QNAP"
            h.osHint = "QTS"
            h.kind = .nas
            h.product = "QNAP QTS"
            h.model = firstMatch(#"\bT[SVBRH]-[A-Z0-9]{3,8}\b"#, in: all)
            return
        }
        if has("unRAID") {
            h.osHint = "Unraid"
            h.product = "Unraid"
            h.kind = .nas
            return
        }
        if has("OpenMediaVault") {
            h.osHint = "OpenMediaVault"
            h.product = "OpenMediaVault"
            h.kind = .nas
            return
        }

        // Routers / firewalls
        if has("FRITZ!Box") || has("FRITZ!OS") {
            h.manufacturer = "AVM"
            h.osHint = "FRITZ!OS"
            h.kind = .router
            h.product = "FRITZ!Box"
            h.model = firstMatch(#"FRITZ!Box\s*\d{4}(?:\s?(?:AX|Cable|LTE|5G|Fiber))?"#, in: all) ?? "FRITZ!Box"
            return
        }
        if has("OPNsense") {
            h.osHint = "OPNsense"
            h.product = "OPNsense"
            h.kind = .router
            return
        }
        if has("pfSense") {
            h.osHint = "pfSense"
            h.product = "pfSense"
            h.kind = .router
            return
        }
        if has("OpenWrt") || all.contains("LuCI") {
            h.osHint = "OpenWrt"
            h.product = "OpenWrt"
            h.kind = .router
            return
        }
        if has("RouterOS") || has("mikrotik") {
            h.manufacturer = "MikroTik"
            h.osHint = "RouterOS"
            h.kind = .router
            h.product = "RouterOS"
            return
        }
        if has("zyxel") {
            h.manufacturer = "Zyxel"
            h.kind = .router
            h.product = "Zyxel"
            h.model = firstMatch(
                #"\b(?:VMG|EMG|XMG|PMG|AX|DX|EX|NR|LTE|WX|NBG|USG|ATP|WSQ|FMG)\d{3,5}[A-Z]?(?:-[A-Z0-9]{2,6})?\b"#,
                in: all)
            return
        }
        if all.contains("UniFi OS") {
            h.manufacturer = "Ubiquiti"
            h.osHint = "UniFi OS"
            h.kind = .router
            h.product = "UniFi OS"
            return
        }
        if all.contains("UniFi") || has("Ubiquiti") {
            h.product = "UniFi Network"
            return
        }
        if has("NETGEAR") || inTitle("Orbi") {
            h.manufacturer = "NETGEAR"
            h.product = "NETGEAR"
            let model = firstMatch(
                #"\b(?:RBR|RBS|RBK|RBE|RAX|RAXE|CAX|LAX|MR|MK|XR|R|C|AC|WNR|WNDR|EX|GS|MS|WAX)\d{2,4}[A-Z]{0,3}\b"#,
                in: all)
            if let model { h.model = model } else if has("Orbi") { h.model = "Orbi" }
            h.kind = (model?.hasPrefix("GS") == true || model?.hasPrefix("MS") == true) ? nil : .router
            return
        }
        if has("TP-Link") || has("tplink") || has("TP-LINK") {
            h.manufacturer = "TP-Link"
            h.product = "TP-Link"
            h.model = firstMatch(
                #"\b(?:Archer\s?[A-Z]{1,3}\d{1,4}[A-Za-z]*|Deco\s?[A-Z]{1,2}\d{1,3}[A-Za-z]*|TL-[A-Z0-9]+(?:-[A-Z0-9]+)?|RE\d{3}[A-Z]?)\b"#,
                in: all)
            if h.model?.hasPrefix("RE") != true { h.kind = .router }
            return
        }
        if has("ASUSWRT")
            || all.contains("ASUS") && (has("router") || all.contains("RT-") || has("ZenWiFi") || all.contains("GT-"))
        {
            h.manufacturer = "ASUS"
            h.kind = .router
            h.product = "ASUS router"
            h.model = firstMatch(#"\b(?:RT|GT|TUF|DSL|4G|BRT)-[A-Z0-9_]{3,12}\b|ZenWiFi\s?[A-Z0-9 ]{2,12}"#, in: all)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            return
        }

        // Servers / apps
        if has("Proxmox") {
            h.osHint = "Proxmox VE"
            h.product = "Proxmox VE"
            h.kind = .computer
            return
        }
        if has("Home Assistant") || has("<home-assistant") {
            h.osHint = "Home Assistant"
            h.product = "Home Assistant"
            h.kind = .iot
            return
        }
        if has("Pi-hole") {
            h.product = "Pi-hole"
            return
        }
        if has("Coolify") {
            h.product = "Coolify"
            return
        }
        if has("Portainer") {
            h.product = "Portainer"
            return
        }
        if has("Jellyfin") {
            h.product = "Jellyfin"
            return
        }
        if inTitle("Plex") || has("plex.tv") || has("X-Plex") {
            h.product = "Plex Media Server"
            return
        }
        if has("OctoPrint") {
            h.product = "OctoPrint"
            return
        }
        if has("Nginx Proxy Manager") {
            h.product = "Nginx Proxy Manager"
            return
        }

        // Smart home / firmware
        if has("ESPHome") {
            h.osHint = "ESPHome"
            h.product = "ESPHome"
            h.kind = .iot
            return
        }
        if has("Tasmota") {
            h.osHint = "Tasmota"
            h.product = "Tasmota"
            h.kind = .iot
            return
        }
        if inTitle("WLED") || all.contains("WLED") && all.contains("wled") {
            h.osHint = "WLED"
            h.product = "WLED"
            h.kind = .iot
            return
        }
        if has("Shelly") {
            h.manufacturer = "Shelly"
            h.kind = .iot
            h.product = "Shelly"
            h.model = firstMatch(#"\bShelly\s?(?:Plus|Pro|Pro\s?\d|Mini|Gen\d)?\s?[A-Z0-9][A-Za-z0-9 ]{0,12}"#, in: t)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            return
        }
        if has("hue personal wireless lighting") || has("Philips hue") || inTitle("hue bridge") {
            h.manufacturer = "Philips Hue"
            h.model = "Hue Bridge"
            h.kind = .iot
            h.product = "Hue Bridge"
            return
        }
        if has("DIRIGERA") {
            h.manufacturer = "IKEA"
            h.model = "DIRIGERA Hub"
            h.kind = .iot
            h.product = "DIRIGERA"
            return
        }

        // Printers
        let printerPatterns: [(String, String)] = [
            (
                "HP",
                #"\bHP\s+(?:Color\s+)?(?:LaserJet|OfficeJet|DeskJet|ENVY|PageWide|Smart Tank|Tango|Photosmart|Neverstop)[A-Za-z0-9 +-]{0,30}"#
            ),
            ("Epson", #"\b(?:EPSON|Epson)\s+(?:(?:ET|WF|XP|L|EW|EC)-?[A-Z0-9]{2,8}[A-Za-z0-9 ]{0,12})"#),
            ("Brother", #"\bBrother\s+(?:MFC|HL|DCP|ADS)-[A-Z0-9]{3,10}"#),
            (
                "Canon",
                #"\bCanon\s+(?:PIXMA|imageCLASS|MAXIFY|i-SENSYS|imageRUNNER|MF|LBP|TS|G)\s?[A-Z0-9]{2,10}[A-Za-z0-9 ]{0,8}"#
            ),
            ("Kyocera", #"\b(?:ECOSYS|TASKalfa)\s+[A-Z0-9][A-Za-z0-9]{2,12}"#),
        ]
        for (brand, pattern) in printerPatterns {
            guard let m = firstMatch(pattern, in: t) ?? firstMatch(pattern, in: all) else { continue }
            var model = m.trimmingCharacters(in: .whitespaces)
            for prefix in ["\(brand) ", brand.uppercased() + " "] where model.hasPrefix(prefix) {
                model.removeFirst(prefix.count)
            }
            for suffix in [" series", " Series"] where model.hasSuffix(suffix) { model.removeLast(suffix.count) }
            h.manufacturer = brand
            h.model = model
            h.kind = .printer
            h.product = "\(brand) \(model)"
            return
        }
    }

    /// OS hints from an HTTP `Server` header, e.g. "Apache/2.4.58 (Ubuntu)" → "Ubuntu".
    public static func osHint(fromServer server: String) -> String? {
        let s = server.lowercased()
        guard !s.isEmpty else { return nil }
        if s.contains("microsoft-iis") || s.contains("microsoft-httpapi") { return "Windows" }
        for (needle, os) in [
            ("(ubuntu)", "Ubuntu"), ("(debian)", "Debian"), ("(raspbian)", "Raspberry Pi OS"),
            ("(centos)", "CentOS"), ("(red hat)", "Red Hat"), ("(fedora)", "Fedora"),
            ("(freebsd)", "FreeBSD"), ("(win64)", "Windows"), ("(win32)", "Windows"),
        ]
        where s.contains(needle) { return os }
        return nil
    }

    // MARK: Vendor follow-ups

    /// Zyxel routers expose `/getBasicInformation` without login:
    /// `{"result":"ZCFG_SUCCESS","ModelName":"NR7101",...}`.
    public static func parseZyxelBasicInfo(_ data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let model = obj["ModelName"] as? String
        else { return nil }
        let m = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return m.isEmpty ? nil : m
    }

    /// `<meta http-equiv="refresh" content="0; url=/ui/">` target, if any.
    public static func metaRefreshTarget(_ html: String) -> String? {
        guard
            let r = firstMatch(
                #"<meta[^>]+http-equiv\s*=\s*["']?refresh["']?[^>]*>"#, in: html, options: [.caseInsensitive]),
            let url = firstCapture(#"url\s*=\s*['"]?([^'">\s]+)"#, in: r)
        else { return nil }
        return url
    }

    // MARK: SSH

    /// Interprets an SSH identification line such as "SSH-2.0-OpenSSH_9.6p1 Ubuntu-3ubuntu13".
    public static func parseSSH(_ banner: String) -> BannerHints {
        let line =
            banner.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        guard line.hasPrefix("SSH-") else { return BannerHints() }
        let l = line.lowercased()
        var h = BannerHints()
        if l.contains("ubuntu") {
            h.osHint = ubuntuRelease(forOpenSSH: line).map { "Ubuntu \($0)" } ?? "Ubuntu"
            h.kind = .computer
        } else if l.contains("raspbian") {
            h.osHint = "Raspberry Pi OS"
            h.kind = .computer
        } else if l.contains("debian") {
            h.osHint = firstCapture(#"deb(\d{1,2})u"#, in: l).map { "Debian \($0)" } ?? "Debian"
            h.kind = .computer
        } else if l.contains("freebsd") {
            h.osHint = "FreeBSD"
        } else if l.contains("openssh_for_windows") {
            h.osHint = "Windows"
            h.kind = .computer
        } else if l.contains("rosssh") {
            h.osHint = "RouterOS"
            h.manufacturer = "MikroTik"
            h.kind = .router
        } else if l.contains("dropbear") {
            h.osHint = "Embedded Linux"
        } else if l.contains("cisco") {
            h.manufacturer = "Cisco"
        } else if l.contains("synology") {
            h.manufacturer = "Synology"
            h.osHint = "DSM"
            h.kind = .nas
        }
        return h
    }

    /// Default OpenSSH version shipped by each Ubuntu release.
    private static let ubuntuOpenSSH: [String: String] = [
        "7.6p1": "18.04", "8.2p1": "20.04", "8.9p1": "22.04", "9.3p1": "23.10",
        "9.6p1": "24.04", "9.7p1": "24.10", "9.9p1": "25.04", "10.0p1": "25.10",
    ]

    private static func ubuntuRelease(forOpenSSH line: String) -> String? {
        guard let v = firstCapture(#"OpenSSH_([0-9.]+p\d)"#, in: line) else { return nil }
        return ubuntuOpenSSH[v]
    }

    // MARK: Regex helpers

    static func firstMatch(
        _ pattern: String, in s: String,
        options: NSRegularExpression.Options = []
    ) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: options),
            let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
            let r = Range(m.range, in: s)
        else { return nil }
        return String(s[r])
    }

    static func firstCapture(_ pattern: String, in s: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
            let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), m.numberOfRanges > 1,
            let r = Range(m.range(at: 1), in: s)
        else { return nil }
        return String(s[r])
    }
}
