import Darwin
import Dispatch
import Foundation
import dnssd

// MARK: - TXT records

public enum BonjourTXT {
    /// Parses a DNS-SD TXT record (a sequence of length-prefixed "key=value" strings).
    /// Keys are lowercased; a key without "=" maps to "". The first occurrence of a key wins.
    public static func parse(_ txt: Data) -> [String: String] {
        let bytes = [UInt8](txt)
        var out: [String: String] = [:]
        var i = 0
        while i < bytes.count {
            let len = Int(bytes[i])
            i += 1
            guard len > 0 else { continue }
            let end = min(i + len, bytes.count)
            let entry = bytes[i..<end]
            i = end
            let key: String
            let value: String
            if let eq = entry.firstIndex(of: UInt8(ascii: "=")) {
                key = String(decoding: entry[entry.startIndex..<eq], as: UTF8.self)
                value = String(decoding: entry[(eq + 1)...], as: UTF8.self)
            } else {
                key = String(decoding: entry, as: UTF8.self)
                value = ""
            }
            let k = key.lowercased()
            guard !k.isEmpty, out[k] == nil else { continue }
            out[k] = value
        }
        return out
    }

    private static let modelKeys = ["model", "md", "am", "rpmd", "ty", "product", "usb_mdl"]

    /// Best model string from a TXT dictionary (keys matched case-insensitively).
    public static func model(from txt: [String: String]) -> String? {
        var lower: [String: String] = [:]
        for (k, v) in txt where lower[k.lowercased()] == nil { lower[k.lowercased()] = v }
        for key in modelKeys {
            guard var v = lower[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { continue }
            if key == "product" {
                v = v.trimmingCharacters(in: CharacterSet(charactersIn: "()"))
                    .trimmingCharacters(in: .whitespaces)
                guard !v.isEmpty else { continue }
            }
            // Samba/TrueNAS style "MacPro7,1@ECOLOR=226,226,224": drop the "@…" decoration.
            if let at = v.firstIndex(of: "@"), at != v.startIndex { v = String(v[..<at]) }
            return appleFriendlyName(v) ?? v
        }
        return nil
    }

    // Longest prefixes first so "MacBookPro" wins over "MacBook" and "Mac".
    private static let appleFamilies: [(prefix: String, name: String)] = [
        ("MacBookPro", "MacBook Pro"),
        ("MacBookAir", "MacBook Air"),
        ("MacBook", "MacBook"),
        ("Macmini", "Mac mini"),
        ("MacPro", "Mac Pro"),
        ("iMacPro", "iMac Pro"),
        ("iMac", "iMac"),
        ("Mac", "Mac"),
        ("iPhone", "iPhone"),
        ("iPad", "iPad"),
        ("iPod", "iPod touch"),
        ("AppleTV", "Apple TV"),
        ("AudioAccessory", "HomePod"),
        ("Watch", "Apple Watch"),
        ("RealityDevice", "Apple Vision Pro"),
    ]

    /// Apple Silicon Macs use generic "MacNN,N" identifiers; map the known ones to their family.
    private static let macIdentifiers: [String: String] = {
        var m: [String: String] = [:]
        func add(_ name: String, _ ids: String...) { for id in ids { m[id] = name } }
        add("MacBook Air", "Mac14,2", "Mac14,15", "Mac15,12", "Mac15,13", "Mac16,12", "Mac16,13")
        add(
            "MacBook Pro", "Mac14,5", "Mac14,6", "Mac14,7", "Mac14,9", "Mac14,10", "Mac15,3", "Mac15,6",
            "Mac15,7", "Mac15,8", "Mac15,9", "Mac15,10", "Mac15,11", "Mac16,1", "Mac16,5", "Mac16,6",
            "Mac16,7", "Mac16,8", "Mac17,2")
        add("Mac mini", "Mac14,3", "Mac14,12", "Mac16,10", "Mac16,11")
        add("Mac Studio", "Mac13,1", "Mac13,2", "Mac14,13", "Mac14,14", "Mac15,14", "Mac16,9")
        add("Mac Pro", "Mac14,8")
        add("iMac", "Mac15,4", "Mac15,5", "Mac16,2", "Mac16,3")
        return m
    }()

    /// Whether `name` is one of the friendly family names produced by `appleFriendlyName`.
    public static func isAppleFamilyName(_ name: String) -> Bool {
        appleFamilies.contains { $0.name == name } || macIdentifiers.values.contains(name)
    }

    /// Maps Apple hardware identifiers such as "MacBookPro18,3" to a family name ("MacBook Pro").
    /// Returns nil for anything that isn't `<Family><digits>,<digits>`.
    public static func appleFriendlyName(_ identifier: String) -> String? {
        if let exact = macIdentifiers[identifier] { return exact }
        for (prefix, name) in appleFamilies where identifier.hasPrefix(prefix) {
            let rest = identifier.dropFirst(prefix.count)
            guard let first = rest.first, first.isNumber,
                rest.allSatisfy({ $0.isNumber || $0 == "," })
            else { continue }
            return name
        }
        return nil
    }
}

// MARK: - Service labels

public enum BonjourServiceLabels {
    private static let labels: [String: String] = [
        "_airplay._tcp": "AirPlay",
        "_raop._tcp": "AirPlay Audio",
        "_googlecast._tcp": "Chromecast",
        "_ipp._tcp": "Printer",
        "_ipps._tcp": "Printer",
        "_printer._tcp": "Printer",
        "_pdl-datastream._tcp": "Printer",
        "_scanner._tcp": "Scanner",
        "_uscan._tcp": "Scanner",
        "_smb._tcp": "File Sharing (SMB)",
        "_afpovertcp._tcp": "File Sharing (AFP)",
        "_ssh._tcp": "SSH",
        "_sftp-ssh._tcp": "SSH",
        "_rfb._tcp": "Screen Sharing",
        "_http._tcp": "Web",
        "_hap._tcp": "HomeKit",
        "_homekit._tcp": "HomeKit",
        "_spotify-connect._tcp": "Spotify Connect",
        "_sonos._tcp": "Sonos",
        "_amzn-wplay._tcp": "Amazon Fire TV",
        "_touch-able._tcp": "Remote",
        "_companion-link._tcp": "Apple Device",
        "_apple-mobdev2._tcp": "Apple Device",
        "_device-info._tcp": "",
        "_workstation._tcp": "Workstation",
        "_rdlink._tcp": "Apple Device",
        "_airport._tcp": "AirPort Base Station",
        "_adisk._tcp": "Time Machine",
        "_esphomelib._tcp": "ESPHome",
        "_shelly._tcp": "Shelly",
        "_wled._tcp": "WLED",
        "_androidtvremote2._tcp": "Android TV",
        "_matter._tcp": "Matter",
        "_hue._tcp": "Philips Hue",
        "_ewelink._tcp": "eWeLink",
        "_mqtt._tcp": "MQTT",
        "_home-assistant._tcp": "Home Assistant",
        "_nvstream._tcp": "Game Streaming",
        "_daap._tcp": "iTunes Sharing",
        "_sleep-proxy._udp": "Sleep Proxy",
        "_meshcop._udp": "Thread Border Router",
        "_trel._udp": "Thread",
    ]

    /// Human-readable label for a service type. Accepts "_x._tcp" with or without a trailing ".".
    /// Unknown types return the type trimmed (e.g. "_foo._tcp" → "foo"). "" means "don't show".
    public static func label(for type: String) -> String {
        let t = normalize(type)
        if let l = labels[t] { return l }
        var s = Substring(t)
        if s.hasSuffix("._tcp") { s = s.dropLast(5) } else if s.hasSuffix("._udp") { s = s.dropLast(5) }
        while s.hasPrefix("_") { s = s.dropFirst() }
        return String(s)
    }

    static func normalize(_ type: String) -> String {
        var t = type.lowercased()
        while t.hasSuffix(".") { t.removeLast() }
        if t.hasSuffix(".local") { t.removeLast(6) }
        return t
    }
}

// MARK: - Name / kind heuristics

enum BonjourNaming {
    static let printerTypes: Set<String> = ["_ipp._tcp", "_ipps._tcp", "_printer._tcp", "_pdl-datastream._tcp"]
    /// Types whose instance names are opaque identifiers, not device names.
    static let opaqueNameTypes: Set<String> = [
        "_apple-mobdev2._tcp", "_touch-able._tcp", "_amzn-wplay._tcp", "_matter._tcp", "_trel._udp",
        "_sleep-proxy._udp", "_meshcop._udp", "_daap._tcp", "_mqtt._tcp", "_home-assistant._tcp",
    ]
    /// Services only Apple devices advertise. `_device-info` models are trusted only alongside one,
    /// because Samba (TrueNAS etc.) fakes e.g. "MacPro7,1" for its Finder icon.
    static let appleOnlyTypes: Set<String> = [
        "_airplay._tcp", "_raop._tcp", "_companion-link._tcp", "_rdlink._tcp", "_apple-mobdev2._tcp",
        "_airport._tcp", "_sleep-proxy._udp", "_touch-able._tcp",
    ]
    /// File-sharing-only services a Samba host typically advertises.
    static let fileSharingTypes: Set<String> = ["_smb._tcp", "_afpovertcp._tcp", "_adisk._tcp"]

    /// ESPHome TXT: "board=esp32-s3-devkitc-1 platform=ESP32 version=2025.4.1" → ("ESP32-S3", "ESPHome 2025.4.1").
    static func esphome(_ txt: [String: String]) -> (model: String?, osHint: String) {
        let board = (txt["board"] ?? "").lowercased()
        var model = txt["platform"].flatMap { $0.isEmpty ? nil : $0.uppercased() }
        for variant in ["s2", "s3", "c2", "c3", "c5", "c6", "h2", "p4"]
        where board.hasPrefix("esp32-\(variant)") || board.hasPrefix("esp32\(variant)") {
            model = "ESP32-\(variant.uppercased())"
        }
        let version = txt["version"].flatMap { $0.isEmpty ? nil : $0 }
        return (model, version.map { "ESPHome \($0)" } ?? "ESPHome")
    }

    /// Higher is better. A name is only emitted if it is at least as good as the best seen for that IP.
    static func namePriority(_ type: String) -> Int {
        switch type {
        case "_device-info._tcp", "_airplay._tcp", "_googlecast._tcp": 3
        case "_http._tcp", "_workstation._tcp": 1
        default: 2
        }
    }

    static func cleanName(_ instance: String, type: String, txt: [String: String]) -> String? {
        if opaqueNameTypes.contains(type) { return nil }
        var n = instance
        if type == "_googlecast._tcp" {
            guard let fn = txt["fn"], !fn.isEmpty else { return nil }
            n = fn
        }
        if type == "_raop._tcp", let at = n.firstIndex(of: "@") {
            n = String(n[n.index(after: at)...])
        }
        if type == "_workstation._tcp", let br = n.lastIndex(of: "["), n.hasSuffix("]") {
            n = String(n[..<br])
        }
        n = n.trimmingCharacters(in: .whitespaces)
        // Drop conflict-resolution suffixes like " (2)".
        if n.hasSuffix(")"), let open = n.lastIndex(of: "(") {
            let inner = n[n.index(after: open)..<n.index(before: n.endIndex)]
            if !inner.isEmpty, inner.allSatisfy(\.isNumber) {
                n = String(n[..<open]).trimmingCharacters(in: .whitespaces)
            }
        }
        return n.isEmpty ? nil : n
    }

    static func kind(type: String, model: String?, txt: [String: String]) -> DeviceKind? {
        // _device-info "model" is a Finder icon hint that Samba/NAS boxes fake (e.g. "MacPro7,1").
        if type == "_device-info._tcp" { return nil }
        if printerTypes.contains(type) { return .printer }
        switch type {
        case "_sonos._tcp": return .speaker
        case "_hap._tcp", "_homekit._tcp": return .iot
        case "_workstation._tcp", "_nvstream._tcp": return .computer
        case "_esphomelib._tcp", "_shelly._tcp", "_wled._tcp", "_hue._tcp", "_ewelink._tcp", "_home-assistant._tcp":
            return .iot
        case "_androidtvremote2._tcp": return .tv
        case "_airport._tcp": return .router
        case "_googlecast._tcp":
            let md = txt["md"] ?? ""
            if md.localizedCaseInsensitiveContains("Chromecast") || md.localizedCaseInsensitiveContains("TV") {
                return .tv
            }
        default: break
        }
        return kind(forModel: model)
    }

    /// Kind implied by a friendly Apple model name.
    static func kind(forModel model: String?) -> DeviceKind? {
        guard let m = model else { return nil }
        if m.hasPrefix("iPhone") { return .phone }
        if m.hasPrefix("iPad") { return .tablet }
        if m.hasPrefix("Mac") || m.hasPrefix("iMac") { return .computer }
        if m == "Apple TV" { return .tv }
        if m == "HomePod" { return .speaker }
        return nil
    }
}

// MARK: - Scanner

/// Discovers devices on the local network via Bonjour (DNS-SD): browse → resolve → IPv4 address.
public final class BonjourScanner: Sendable {
    public static let serviceTypes: [String] = [
        "_airplay._tcp", "_raop._tcp", "_googlecast._tcp", "_ipp._tcp", "_ipps._tcp", "_printer._tcp",
        "_pdl-datastream._tcp", "_http._tcp", "_smb._tcp", "_afpovertcp._tcp", "_ssh._tcp", "_sftp-ssh._tcp",
        "_rfb._tcp", "_device-info._tcp", "_companion-link._tcp", "_hap._tcp", "_homekit._tcp",
        "_spotify-connect._tcp", "_sonos._tcp", "_workstation._tcp", "_scanner._tcp", "_uscan._tcp",
        "_amzn-wplay._tcp", "_apple-mobdev2._tcp", "_touch-able._tcp", "_rdlink._tcp", "_airport._tcp",
        "_adisk._tcp", "_esphomelib._tcp", "_shelly._tcp", "_wled._tcp", "_androidtvremote2._tcp",
        "_matter._tcp", "_hue._tcp", "_ewelink._tcp", "_mqtt._tcp", "_home-assistant._tcp", "_nvstream._tcp",
        "_daap._tcp", "_sleep-proxy._udp", "_meshcop._udp", "_trel._udp",
    ]

    public init() {}

    /// Streams patches for each resolved service, finishing after `duration` (or on cancellation).
    public func scan(duration: Duration = .seconds(5)) -> AsyncStream<DevicePatch> {
        AsyncStream { continuation in
            let session = BonjourSession(continuation: continuation)
            continuation.onTermination = { _ in session.stop() }
            session.start(types: Self.serviceTypes, duration: duration)
        }
    }
}

/// Context handed to dns_sd callbacks via `Unmanaged`. Retained by the session until teardown.
private final class OpContext {
    unowned let session: BonjourSession
    let type: String
    var instance = ""
    var hostname: String?
    var txt: [String: String] = [:]

    init(session: BonjourSession, type: String) {
        self.session = session
        self.type = type
    }
}

/// All mutable state is confined to `queue`; dns_sd callbacks are delivered on it via
/// `DNSServiceSetDispatchQueue`.
private final class BonjourSession: @unchecked Sendable {
    let queue = DispatchQueue(label: "LanternfishKit.BonjourScanner")
    private let continuation: AsyncStream<DevicePatch>.Continuation
    private var refs: [DNSServiceRef] = []
    private var contexts: [OpContext] = []
    private var stopped = false
    private var seen: Set<PatchKey> = []
    private var resolving: Set<String> = []
    private var bestNamePriority: [IPv4Address: Int] = [:]
    private var typesByIP: [IPv4Address: Set<String>] = [:]
    /// `_device-info` models waiting for proof that the host is really an Apple device.
    private var deferredDeviceInfo: [IPv4Address: String] = [:]

    init(continuation: AsyncStream<DevicePatch>.Continuation) {
        self.continuation = continuation
    }

    func start(types: [String], duration: Duration) {
        queue.async { [self] in
            for type in types { browse(type) }
        }
        queue.asyncAfter(deadline: .now() + duration.dispatchInterval) { [self] in teardown() }
    }

    func stop() {
        queue.async { [self] in teardown() }
    }

    private func teardown() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !stopped else { return }
        stopped = true
        flushDeferredDeviceInfo()
        for r in refs { DNSServiceRefDeallocate(r) }
        refs.removeAll()
        contexts.removeAll()
        continuation.finish()
    }

    private func register(_ ref: DNSServiceRef?, _ err: DNSServiceErrorType, _ ctx: OpContext) {
        guard err == kDNSServiceErr_NoError, let ref else { return }
        if DNSServiceSetDispatchQueue(ref, queue) != kDNSServiceErr_NoError {
            DNSServiceRefDeallocate(ref)
            return
        }
        refs.append(ref)
        contexts.append(ctx)
    }

    // MARK: Browse

    private func browse(_ type: String) {
        guard !stopped else { return }
        let ctx = OpContext(session: self, type: type)
        var ref: DNSServiceRef?
        let err = DNSServiceBrowse(
            &ref, 0, 0, type, "local.",
            { _, flags, ifIndex, err, name, regtype, domain, raw in
                guard err == kDNSServiceErr_NoError, flags & DNSServiceFlags(kDNSServiceFlagsAdd) != 0,
                    let raw, let name, let regtype, let domain
                else { return }
                let ctx = Unmanaged<OpContext>.fromOpaque(raw).takeUnretainedValue()
                ctx.session.resolve(
                    name: String(cString: name), regtype: String(cString: regtype),
                    domain: String(cString: domain), ifIndex: ifIndex, type: ctx.type)
            }, Unmanaged.passUnretained(ctx).toOpaque())
        register(ref, err, ctx)
    }

    // MARK: Resolve

    fileprivate func resolve(name: String, regtype: String, domain: String, ifIndex: UInt32, type: String) {
        guard !stopped else { return }
        let key = "\(type)|\(name)|\(domain)|\(ifIndex)"
        guard resolving.insert(key).inserted else { return }
        let ctx = OpContext(session: self, type: type)
        ctx.instance = name
        var ref: DNSServiceRef?
        let err = DNSServiceResolve(
            &ref, 0, ifIndex, name, regtype, domain,
            { _, _, ifIndex, err, _, host, _, txtLen, txtRecord, raw in
                guard err == kDNSServiceErr_NoError, let raw, let host else { return }
                let ctx = Unmanaged<OpContext>.fromOpaque(raw).takeUnretainedValue()
                let txt = txtRecord.map { BonjourTXT.parse(Data(bytes: $0, count: Int(txtLen))) } ?? [:]
                ctx.session.lookupAddress(host: String(cString: host), ifIndex: ifIndex, from: ctx, txt: txt)
            }, Unmanaged.passUnretained(ctx).toOpaque())
        register(ref, err, ctx)
    }

    // MARK: Address

    fileprivate func lookupAddress(host: String, ifIndex: UInt32, from resolveCtx: OpContext, txt: [String: String]) {
        guard !stopped else { return }
        let ctx = OpContext(session: self, type: resolveCtx.type)
        ctx.instance = resolveCtx.instance
        ctx.txt = txt
        var h = host
        while h.hasSuffix(".") { h.removeLast() }
        ctx.hostname = h.isEmpty ? nil : h
        var ref: DNSServiceRef?
        let err = DNSServiceGetAddrInfo(
            &ref, 0, ifIndex, DNSServiceProtocol(kDNSServiceProtocol_IPv4), host,
            { _, flags, _, err, _, addr, _, raw in
                guard err == kDNSServiceErr_NoError, flags & DNSServiceFlags(kDNSServiceFlagsAdd) != 0,
                    let raw, let addr, addr.pointee.sa_family == sa_family_t(AF_INET)
                else { return }
                let ctx = Unmanaged<OpContext>.fromOpaque(raw).takeUnretainedValue()
                let ip = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    IPv4Address(UInt32(bigEndian: $0.pointee.sin_addr.s_addr))
                }
                ctx.session.emit(ip: ip, ctx: ctx)
            }, Unmanaged.passUnretained(ctx).toOpaque())
        register(ref, err, ctx)
    }

    // MARK: Emit

    fileprivate func emit(ip: IPv4Address, ctx: OpContext) {
        guard !stopped, ip.value != 0 else { return }
        let type = ctx.type
        var patch = DevicePatch(ip: ip)
        patch.hostname = ctx.hostname
        var modelTXT = ctx.txt
        // In _raop TXT, "md" is the supported metadata list ("0,1,2"), not a model.
        if type == "_raop._tcp" { modelTXT["md"] = nil }
        patch.model = BonjourTXT.model(from: modelTXT)
        let label = BonjourServiceLabels.label(for: type)
        if !label.isEmpty { patch.services = [label] }
        patch.kind = BonjourNaming.kind(type: type, model: patch.model, txt: ctx.txt)
        typesByIP[ip, default: []].insert(type)
        let isAppleHost = !typesByIP[ip, default: []].isDisjoint(with: BonjourNaming.appleOnlyTypes)
        if type == "_device-info._tcp", let model = patch.model {
            if isAppleHost {
                patch.kind = BonjourNaming.kind(forModel: model)
            } else {
                patch.model = nil
                deferredDeviceInfo[ip] = model
            }
        }
        if isAppleHost, let model = deferredDeviceInfo.removeValue(forKey: ip), patch.model == nil {
            patch.model = model
            patch.kind = patch.kind ?? BonjourNaming.kind(forModel: model)
        }
        if type == "_esphomelib._tcp" {
            let e = BonjourNaming.esphome(ctx.txt)
            patch.model = e.model
            patch.osHint = e.osHint
            if e.model?.hasPrefix("ESP") == true { patch.manufacturer = "Espressif" }
        }
        if let name = BonjourNaming.cleanName(ctx.instance, type: type, txt: ctx.txt) {
            let prio = BonjourNaming.namePriority(type)
            if prio >= bestNamePriority[ip, default: 0] {
                bestNamePriority[ip] = prio
                patch.name = name
            }
        }
        let key = PatchKey(patch)
        guard seen.insert(key).inserted else { return }
        continuation.yield(patch)
    }

    /// At the end of the browse: hosts whose `_device-info` claims an Apple model but which never
    /// advertised an Apple-only service are Samba servers faking a Finder icon — drop the model.
    private func flushDeferredDeviceInfo() {
        for (ip, model) in deferredDeviceInfo {
            var patch = DevicePatch(ip: ip)
            if BonjourTXT.isAppleFamilyName(model) {
                let types = typesByIP[ip, default: []]
                guard !types.isDisjoint(with: BonjourNaming.fileSharingTypes) else { continue }
                patch.osHint = "Samba"
            } else {
                patch.model = model
            }
            continuation.yield(patch)
        }
        deferredDeviceInfo.removeAll()
    }
}

private struct PatchKey: Hashable {
    let ip: IPv4Address
    let name: String?
    let hostname: String?
    let model: String?
    let kind: DeviceKind?
    let services: Set<String>
    let osHint: String?
    let manufacturer: String?

    init(_ p: DevicePatch) {
        ip = p.ip
        name = p.name
        hostname = p.hostname
        model = p.model
        kind = p.kind
        services = p.services
        osHint = p.osHint
        manufacturer = p.manufacturer
    }
}
