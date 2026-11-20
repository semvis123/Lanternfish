import Foundation

// MARK: - Report

/// How much a finding matters. `passed` items are the good news ("No risky ports open").
public enum HealthSeverity: Int, Sendable, Hashable, Comparable, CaseIterable {
    case critical, warning, info, passed

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    public var label: String {
        switch self {
        case .critical: "Critical"
        case .warning: "Warnings"
        case .info: "Good to Know"
        case .passed: "Looking Good"
        }
    }
}

/// The check behind a finding (stable; the UI picks icons by it).
public enum HealthRule: String, Sendable, Hashable, CaseIterable {
    case wifiSecurity
    case telnet
    case ftp
    case fileSharing
    case remoteDesktop
    case developerServices
    case routerAdminHTTP
    case webWithoutHTTPS
    case mqttPlaintext
    case routerUPnP
    case newDevices
    case unidentified
    case privateMACs
}

public struct HealthFinding: Sendable, Hashable, Identifiable {
    /// The rule, plus ".ok" for the passed variant.
    public let id: String
    public let rule: HealthRule
    public let severity: HealthSeverity
    public let title: String
    /// Why it matters and what to do, in a sentence or two.
    public let detail: String
    /// `Device.id` of each affected device (its IP, except for offline rows with a stand-in id).
    public let deviceIDs: [IPv4Address]

    public init(
        rule: HealthRule, severity: HealthSeverity, title: String, detail: String,
        deviceIDs: [IPv4Address] = []
    ) {
        self.id = severity == .passed ? "\(rule.rawValue).ok" : rule.rawValue
        self.rule = rule
        self.severity = severity
        self.title = title
        self.detail = detail
        self.deviceIDs = deviceIDs
    }
}

public enum HealthGrade: String, Sendable, Hashable {
    case excellent, good, fair, atRisk

    public init(score: Int) {
        switch score {
        case 90...: self = .excellent
        case 70..<90: self = .good
        case 45..<70: self = .fair
        default: self = .atRisk
        }
    }

    public var label: String {
        switch self {
        case .excellent: "Excellent"
        case .good: "Good"
        case .fair: "Fair"
        case .atRisk: "At Risk"
        }
    }
}

public struct HealthReport: Sendable, Hashable {
    /// 0...100.
    public let score: Int
    public let grade: HealthGrade
    /// One sentence, e.g. "2 things worth a look on 15 devices."
    public let summary: String
    /// Problems and notes, most severe first.
    public let findings: [HealthFinding]
    /// What's fine.
    public let passed: [HealthFinding]
    public let deviceCount: Int

    public var criticalCount: Int { findings.count { $0.severity == .critical } }
    public var warningCount: Int { findings.count { $0.severity == .warning } }
    public var isEmpty: Bool { deviceCount == 0 }

    public func findings(_ severity: HealthSeverity) -> [HealthFinding] {
        severity == .passed ? passed : findings.filter { $0.severity == severity }
    }
}

// MARK: - Check

/// Network health from what a scan already found: open ports, Bonjour / UPnP services, names and
/// MAC addresses. Pure and passive: it never contacts a device, and never tries a login.
///
/// Rules and thresholds (tuned to stay quiet on ordinary home networks):
/// - Wi-Fi with no encryption or WEP: critical; WPA (version 1) only: warning.
/// - Telnet (23) open anywhere: critical. FTP (21): warning.
/// - SMB (445 / Bonjour "File Sharing (SMB)") on something other than a computer, NAS or
///   unidentified device: warning.
/// - RDP (3389) / VNC (5900, 5901, Bonjour "Screen Sharing") on something other than a computer
///   or unidentified device: warning.
/// - Docker API without TLS (2375) or Android Debug Bridge (5555): warning.
/// - Router (the gateway or any device classified as one) with a web page on HTTP and no HTTPS port: warning.
/// - Camera, NAS or printer with a web page on HTTP and no HTTPS port: warning.
/// - MQTT on 1883 with no TLS listener on 8883 on the same device: warning.
/// - Gateway answers UPnP (SSDP): info (we can't see whether port mapping is enabled).
/// - New devices not yet looked at, unknown unnamed devices, 3+ private-MAC devices: info.
///
/// Score: 100 minus 25 per critical finding (+5 per extra device, at most 40 per finding) and 12 per
/// warning (+2 per extra device, at most 18); info costs nothing. Any critical finding caps the
/// score at 60. Grades: Excellent ≥ 90, Good ≥ 70, Fair ≥ 45, else At Risk.
public enum HealthCheck {
    public static let privateMACThreshold = 3

    fileprivate static let httpPorts: Set<UInt16> = [80, 81, 8000, 8080, 8081, 8888]
    fileprivate static let httpsPorts: Set<UInt16> = [443, 8443, 9443, 5001]
    private static let nasHTTPPorts: Set<UInt16> = [5000]  // Synology DSM (5000 is AirPlay on Macs)
    private static let vncPorts: Set<UInt16> = [5900, 5901]
    private static let smbService = "File Sharing (SMB)"
    private static let vncService = "Screen Sharing"
    /// Bonjour services only general-purpose computers advertise.
    fileprivate static let computerServices: Set<String> = [
        "Workstation", "Screen Sharing", "Time Machine", "File Sharing (AFP)",
    ]

    /// - Parameters:
    ///   - devices: the devices to judge (callers pass the online ones for a live network, or a saved
    ///     network's remembered snapshot).
    ///   - gateway: the router's IP, if known.
    ///   - wifiSecurity: the Wi-Fi security label (`WiFiInfo.security`) when the Mac is on that network's Wi-Fi.
    private enum Port {
        static let ftp: UInt16 = 21
        static let telnet: UInt16 = 23
        static let smb: UInt16 = 445
        static let mqtt: UInt16 = 1883
        static let dockerAPI: UInt16 = 2375
        static let rdp: UInt16 = 3389
        static let adb: UInt16 = 5555
        static let mqttTLS: UInt16 = 8883
    }

    public static func evaluate(
        devices: [Device], gateway: IPv4Address? = nil,
        wifiSecurity: String? = nil
    ) -> HealthReport {
        var findings: [HealthFinding] = []
        var passed: [HealthFinding] = []
        let devices = devices.sorted { $0.ip < $1.ip }

        func ids(_ match: (Device) -> Bool) -> [IPv4Address] { devices.filter(match).map(\.id) }
        func isRouter(_ d: Device) -> Bool { d.ip == gateway || d.effectiveKind == .router }

        // Wi-Fi
        if let wifi = wifiSecurity?.trimmingCharacters(in: .whitespaces), !wifi.isEmpty {
            switch wifiLevel(wifi) {
            case .open:
                findings.append(
                    .init(
                        rule: .wifiSecurity, severity: .critical, title: "Wi-Fi has no password",
                        detail:
                            "Anyone nearby can join and see unencrypted traffic. Turn on WPA2 or WPA3 in your router's Wi-Fi settings."
                    ))
            case .wep:
                findings.append(
                    .init(
                        rule: .wifiSecurity, severity: .critical, title: "Wi-Fi uses outdated WEP security",
                        detail:
                            "WEP can be cracked in minutes. Switch your router to WPA2 or WPA3 and set a new password.")
                )
            case .wpa1:
                findings.append(
                    .init(
                        rule: .wifiSecurity, severity: .warning, title: "Wi-Fi uses old WPA security",
                        detail:
                            "The first version of WPA has known weaknesses. Switch your router to WPA2 or WPA3 if your devices support it."
                    ))
            case .modern:
                passed.append(
                    .init(
                        rule: .wifiSecurity, severity: .passed, title: "Wi-Fi is encrypted",
                        detail: "This network uses \(wifi)."))
            case .unknown:
                break
            }
        }

        // Unencrypted remote access
        let telnet = ids { $0.has(port: Port.telnet) }
        if !telnet.isEmpty {
            findings.append(
                .init(
                    rule: .telnet, severity: .critical,
                    title: plural(telnet.count, "device has", "devices have") + " Telnet open",
                    detail:
                        "Telnet sends passwords in plain text and is a favourite target of malware. Turn it off in the device's settings, or update its firmware.",
                    deviceIDs: telnet))
        }
        let ftp = ids { $0.has(port: Port.ftp) }
        if !ftp.isEmpty {
            findings.append(
                .init(
                    rule: .ftp, severity: .warning,
                    title: plural(ftp.count, "device runs", "devices run") + " an FTP server",
                    detail:
                        "FTP sends passwords and files unencrypted. If you don't use it (e.g. scan-to-FTP on a printer), turn it off.",
                    deviceIDs: ftp))
        }
        var portPasses: [HealthFinding] = []
        if telnet.isEmpty, ftp.isEmpty, !devices.isEmpty {
            portPasses.append(
                .init(
                    rule: .telnet, severity: .passed, title: "No unencrypted remote access",
                    detail: "No device has Telnet or FTP open."))
        }

        // File sharing / remote desktop on things that aren't computers
        let smb = ids { d in
            guard d.has(port: Port.smb) || d.services.contains(smbService) else { return false }
            if isRouter(d) { return true }
            return ![.computer, .nas, .unknown].contains(d.effectiveKind) && !d.looksLikeComputer
        }
        if !smb.isEmpty {
            let onlyRouters = devices.filter { smb.contains($0.id) }.allSatisfy(isRouter)
            findings.append(
                .init(
                    rule: .fileSharing, severity: .warning,
                    title: onlyRouters && smb.count == 1
                        ? "Your router shares files over SMB"
                        : "File sharing on "
                            + plural(smb.count, "device that isn't a computer", "devices that aren't computers"),
                    detail:
                        "Routers and smart devices that share files over SMB (often a USB-drive feature) are a common way in for ransomware. Turn sharing off if you don't use it, or keep the firmware up to date.",
                    deviceIDs: smb))
        }
        let remote = ids { d in
            guard
                d.has(port: Port.rdp) || !d.openPortNumbers.isDisjoint(with: vncPorts)
                    || d.services.contains(vncService)
            else { return false }
            if isRouter(d) { return true }
            return ![.computer, .unknown].contains(d.effectiveKind) && !d.looksLikeComputer
        }
        if !remote.isEmpty {
            findings.append(
                .init(
                    rule: .remoteDesktop, severity: .warning,
                    title: "Remote desktop on "
                        + plural(remote.count, "device that isn't a computer", "devices that aren't computers"),
                    detail:
                        "RDP or VNC lets someone control the device's screen. Make sure it needs a strong password, or turn it off.",
                    deviceIDs: remote))
        }
        if smb.isEmpty, remote.isEmpty, !devices.isEmpty {
            portPasses.append(
                .init(
                    rule: .fileSharing, severity: .passed, title: "No risky sharing on smart devices",
                    detail: "File sharing and remote desktop are only on computers and storage."))
        }

        let dev = ids { $0.has(port: Port.dockerAPI) || $0.has(port: Port.adb) }
        if !dev.isEmpty {
            findings.append(
                .init(
                    rule: .developerServices, severity: .warning,
                    title: "Developer access open on " + plural(dev.count, "device", "devices"),
                    detail:
                        "An open Docker API (2375) or Android Debug Bridge (5555) gives full control without a password. Turn it off when you're not developing.",
                    deviceIDs: dev))
        }

        // Router admin page
        let routers = devices.filter(isRouter)
        let routerHTTPOnly = routers.filter { $0.servesHTTPOnly(extraHTTP: []) }.map(\.id)
        if !routerHTTPOnly.isEmpty {
            findings.append(
                .init(
                    rule: .routerAdminHTTP, severity: .warning,
                    title: "Router admin page isn't encrypted",
                    detail:
                        "Its settings page is only on plain HTTP, so the admin password crosses the network readable. Turn on HTTPS for the admin page if the router offers it, and use a strong password.",
                    deviceIDs: routerHTTPOnly))
        } else if let gw = routers.first(where: { $0.ip == gateway }),
            !gw.openPortNumbers.isDisjoint(with: httpsPorts)
        {
            passed.append(
                .init(
                    rule: .routerAdminHTTP, severity: .passed, title: "Router admin page uses HTTPS",
                    detail: "Your router's settings page is available over an encrypted connection."))
        }

        // Web interfaces on cameras / NAS / printers
        let web = ids { d in
            guard !isRouter(d) else { return false }
            switch d.effectiveKind {
            case .camera, .printer: return d.servesHTTPOnly(extraHTTP: [])
            case .nas: return d.servesHTTPOnly(extraHTTP: nasHTTPPorts)
            default: return false
            }
        }
        if !web.isEmpty {
            findings.append(
                .init(
                    rule: .webWithoutHTTPS, severity: .warning,
                    title: plural(web.count, "web interface has", "web interfaces have") + " no HTTPS",
                    detail:
                        "These cameras, storage or printers only offer an unencrypted web page, so logins can be read on the network. Turn on HTTPS in their settings, or avoid logging in over Wi-Fi you don't trust.",
                    deviceIDs: web))
        }

        let mqtt = ids { $0.has(port: Port.mqtt) && !$0.has(port: Port.mqttTLS) }
        if !mqtt.isEmpty {
            findings.append(
                .init(
                    rule: .mqttPlaintext, severity: .warning,
                    title: "MQTT without encryption on " + plural(mqtt.count, "device", "devices"),
                    detail:
                        "Smart-home messages on port 1883 are unencrypted and often need no password. Require a login on the broker, and enable TLS (port 8883) if your devices support it.",
                    deviceIDs: mqtt))
        }

        // One "all clear" instead of several when no device has a risky port.
        let riskyPorts = findings.contains { $0.rule != .wifiSecurity && $0.severity <= .warning }
        if !riskyPorts, !devices.isEmpty {
            passed.insert(
                .init(
                    rule: .telnet, severity: .passed, title: "No risky ports open",
                    detail:
                        "No Telnet, FTP, exposed file sharing, remote desktop, developer access, unencrypted admin pages or open MQTT."
                ),
                at: 0)
        } else {
            passed.insert(contentsOf: portPasses, at: 0)
        }

        // Router UPnP
        if let gw = gateway, let router = devices.first(where: { $0.ip == gw }), router.services.contains("UPnP") {
            findings.append(
                .init(
                    rule: .routerUPnP, severity: .info, title: "Your router has UPnP turned on",
                    detail:
                        "UPnP lets apps and devices open ports to the internet on their own. Game consoles and video calls like it, but a compromised device can use it too. Turn it off in the router if nothing needs it.",
                    deviceIDs: [router.id]))
        }

        // Bookkeeping
        let new = ids { $0.isNew }
        if !new.isEmpty {
            findings.append(
                .init(
                    rule: .newDevices, severity: .info,
                    title: plural(new.count, "new device", "new devices") + " to review",
                    detail:
                        "These joined since the network was first scanned and you haven't looked at them yet. Select each one to check it's yours; selecting it marks it as seen.",
                    deviceIDs: new))
        } else if !devices.isEmpty {
            passed.append(
                .init(
                    rule: .newDevices, severity: .passed, title: "No new devices to review",
                    detail: "You've looked at every device that joined."))
        }

        let unknown = ids { !$0.isSelf && !$0.hasAnyName && $0.effectiveKind == .unknown }
        if !unknown.isEmpty {
            findings.append(
                .init(
                    rule: .unidentified, severity: .info,
                    title: plural(
                        unknown.count, "device you haven't identified or named",
                        "devices you haven't identified or named"),
                    detail:
                        "They didn't announce a name or type. If you recognise one, rename it or set its type so you'll spot strangers later.",
                    deviceIDs: unknown))
        } else if !devices.isEmpty {
            passed.append(
                .init(
                    rule: .unidentified, severity: .passed, title: "Every device is identified",
                    detail: "Each device has a name or a known type."))
        }

        let privateMAC = ids { !$0.isSelf && $0.isPrivateMAC }
        if privateMAC.count >= privateMACThreshold {
            findings.append(
                .init(
                    rule: .privateMACs, severity: .info,
                    title: "\(privateMAC.count) devices use a private Wi-Fi address",
                    detail:
                        "Phones, tablets and computers use a random hardware address per network for privacy, so their maker can't be looked up and they may show up as unknown or as new after a reset. That's normal; name the ones you know.",
                    deviceIDs: privateMAC))
        }

        findings.sort { $0.severity < $1.severity }
        let score = score(for: findings)
        return HealthReport(
            score: score, grade: HealthGrade(score: score),
            summary: summary(findings, deviceCount: devices.count),
            findings: findings, passed: passed, deviceCount: devices.count)
    }

    // MARK: Score

    static func score(for findings: [HealthFinding]) -> Int {
        var penalty = 0
        var critical = false
        for f in findings {
            let extra = max(0, f.deviceIDs.count - 1)
            switch f.severity {
            case .critical:
                critical = true
                penalty += min(40, 25 + 5 * extra)
            case .warning:
                penalty += min(18, 12 + 2 * extra)
            case .info, .passed:
                break
            }
        }
        var s = max(0, 100 - penalty)
        if critical { s = min(s, 60) }
        return s
    }

    private static func summary(_ findings: [HealthFinding], deviceCount: Int) -> String {
        guard deviceCount > 0 else { return "No devices found yet." }
        let c = findings.count { $0.severity == .critical }
        let w = findings.count { $0.severity == .warning }
        let devices = plural(deviceCount, "device", "devices")
        switch (c, w) {
        case (0, 0): return "No problems found on \(devices)."
        case (0, _): return "\(plural(w, "thing", "things")) worth a look on \(devices)."
        case (_, 0): return "\(plural(c, "critical issue needs", "critical issues need")) your attention."
        default:
            return
                "\(plural(c, "critical issue", "critical issues")) and \(plural(w, "warning", "warnings")) need your attention."
        }
    }

    // MARK: Wi-Fi

    private enum WiFiLevel { case open, wep, wpa1, modern, unknown }

    /// Classifies `WiFiInfo.securityLabel` strings.
    private static func wifiLevel(_ label: String) -> WiFiLevel {
        let l = label.lowercased()
        if l == "none" || l == "open" { return .open }
        if l.contains("wep") { return .wep }
        if l.contains("owe") || l.contains("enhanced open") || l.contains("wpa2") || l.contains("wpa3") {
            return .modern
        }
        if l == "wpa personal" || l == "wpa enterprise" { return .wpa1 }
        if l == "personal" || l == "enterprise" { return .modern }
        return .unknown
    }

    private static func plural(_ n: Int, _ one: String, _ many: String) -> String {
        n == 1 ? "1 \(one)" : "\(n) \(many)"
    }
}

// MARK: - Device helpers

extension Device {
    fileprivate var openPortNumbers: Set<UInt16> { Set(openPorts.map(\.port)) }

    fileprivate func has(port: UInt16) -> Bool { openPorts.contains { $0.port == port } }

    /// A user, Bonjour/UPnP or DNS name (not a brand or IP fallback).
    fileprivate var hasAnyName: Bool {
        (customName?.isEmpty == false) || (name?.isEmpty == false) || (hostname?.isEmpty == false)
    }

    /// Announces services only general-purpose computers do, or runs a desktop OS.
    fileprivate var looksLikeComputer: Bool {
        if effectiveKind == .computer { return true }
        if !services.isDisjoint(with: HealthCheck.computerServices) { return true }
        let os = osHint?.lowercased() ?? ""
        return os.contains("windows") || os.contains("macos") || os.contains("mac os")
    }

    /// A web page on a plain-HTTP port and no HTTPS port at all.
    fileprivate func servesHTTPOnly(extraHTTP: Set<UInt16>) -> Bool {
        let ports = openPortNumbers
        return !ports.isDisjoint(with: HealthCheck.httpPorts.union(extraHTTP))
            && ports.isDisjoint(with: HealthCheck.httpsPorts)
    }
}
