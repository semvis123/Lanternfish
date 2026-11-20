import Foundation

/// Infers a `DeviceKind` from everything known about a device.
public enum DeviceKindClassifier {
    public static func classify(_ d: Device, gateway: IPv4Address?) -> DeviceKind {
        if let gateway, d.ip == gateway { return .router }
        let e = Evidence(d)

        // Android TVs often call themselves "Android" (hostname "Android.local"): unambiguous
        // TV evidence wins over the phone words below.
        if e.service("androidtvremote2", "android tv") || e.has("bravia")
            || (e.has("sony") && e.service("googlecast", "chromecast"))
        {
            return .tv
        }
        // Phones
        if e.has("iphone", "pixel", "galaxy s", "galaxy z", "galaxy note", "oneplus", "android", "phone") {
            return .phone
        }
        // Tablets
        if e.has("ipad", "galaxy tab", "kindle", "tablet") { return .tablet }
        // Game consoles
        if e.has("playstation", "xbox", "nintendo", "ps5", "ps4", "ps3", "switch console", "steam deck") {
            return .gameConsole
        }
        // NAS
        if e.has(
            "synology", "qnap", "diskstation", "nas", "truenas", "freenas", "unraid", "readynas", "wd my cloud",
            "mycloud")
        {
            return .nas
        }
        // Printers
        if e.service("ipp", "ipps", "printer", "pdl-datastream", "pdl datastream", "jetdirect")
            || e.port(631, 9100, 515)
            || e.has(
                "printer", "officejet", "laserjet", "deskjet", "pixma", "ecotank", "workforce", "imageclass", "mfc")
        {
            return .printer
        }
        // Cameras
        let tvWords = [
            "tv", "bravia", "roku", "chromecast", "fire tv", "firetv", "apple tv", "appletv",
            "webos", "tizen", "vizio", "shield", "television", "smart tv", "smarttv",
        ]
        if e.has(
            "camera", "ipcam", "ip cam", "webcam", "hikvision", "dahua", "reolink", "ring", "arlo", "wyze", "eufy",
            "doorbell")
            || (e.port(554) && !e.has(tvWords))
        {
            return .camera
        }
        // Speakers
        if e.has(
            "sonos", "homepod", "speaker", "echo", "bose", "nest audio", "nest mini", "google home", "soundbar",
            "soundtouch", "amp")
            || e.service("sonos")
            || (e.service("raop", "airplay audio") && !e.services.contains("airplay") && !e.has(tvWords))
        {
            return .speaker
        }
        // TVs
        if e.has(tvWords) || e.service("googlecast", "amzn-wplay", "androidtvremote2", "android tv")
            || e.port(8001, 8002, 8060)
        {
            return .tv
        }
        // Routers / access points
        if e.has(
            "router", "gateway", "access point", "ubiquiti", "unifi", "fritz", "mesh", "eero", "orbi", "deco",
            "airport", "mikrotik", "netgear", "openwrt", "pfsense", "opnsense", "routeros", "zyxel")
            || e.service("airport", "airport base station")
        {
            return .router
        }
        // Computers
        if e.has(
            "macbook", "imac", "mac mini", "macmini", "mac studio", "mac pro", "macpro", "mac", "windows",
            "workstation", "desktop", "laptop", "thinkpad", "pc", "ubuntu", "debian", "fedora", "centos",
            "proxmox", "freebsd", "raspberry pi", "raspberrypi")
            || (e.service("ssh", "sftp") && e.service("smb", "afp"))
            || (e.port(22) && e.port(445))
            || e.port(3389)
            || e.service("rdp", "rfb", "workstation", "nvstream", "game streaming")
        {
            return .computer
        }
        // IoT / smart home
        if e.has(
            "espressif", "tuya", "shelly", "sonoff", "hue", "philips lighting", "signify", "nest", "tado", "ecobee",
            "esp", "esp32", "esp8266", "tasmota", "wled", "meross", "govee", "lifx", "nanoleaf", "smartthings", "homey",
            "thermostat",
            "esphome", "home assistant", "dirigera", "roborock", "ewelink", "zigbee")
            || e.service(
                "hap", "homekit", "esphome", "esphomelib", "shelly", "wled", "hue", "philips hue", "ewelink",
                "home assistant", "home-assistant")
            || e.port(6668, 6053)
        {
            return .iot
        }
        return d.kind
    }
}

/// Normalized, word-boundary-aware view of a device's identifying text, services, and ports.
private struct Evidence {
    /// Name, hostname, model, manufacturer, vendor and OS hint, in `DeviceText.padded` form.
    let text: String
    /// Service types and labels, lowercased, without leading "_" and "._tcp".
    let services: [String]
    let ports: Set<UInt16>

    init(_ d: Device) {
        let raw = [d.name, d.hostname, d.model, d.manufacturer, d.vendor, d.osHint]
            .compactMap { $0 }
            .joined(separator: " ")
        text = DeviceText.padded(raw)
        services = d.services.map(DeviceText.serviceStem)
        ports = Set(d.openPorts.map(\.port))
    }

    /// See `DeviceText.contains(_:anyOf:)` for the matching rules.
    func has(_ words: String...) -> Bool { has(words) }

    func has(_ words: [String]) -> Bool { DeviceText.contains(text, anyOf: words) }

    /// Matches service types or labels by whole word, e.g. "ipp" matches "_ipp._tcp" and "IPP" but not "ipps".
    func service(_ names: String...) -> Bool {
        names.contains { n in
            let phrase = DeviceText.padded(n)
            return services.contains { s in s == n || DeviceText.padded(s).contains(phrase) }
        }
    }

    func port(_ candidates: UInt16...) -> Bool {
        candidates.contains { ports.contains($0) }
    }
}
