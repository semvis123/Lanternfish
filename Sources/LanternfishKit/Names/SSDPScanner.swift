import Darwin
import Foundation
import Synchronization

// MARK: - Pure helpers

public enum SSDP {
    static let multicastAddress = "239.255.255.250"
    static let port: UInt16 = 1900
    static let userAgent = "macOS/27 UPnP/1.1 Lanternfish/1.0"

    /// Parses an HTTP-over-UDP SSDP message into headers with lowercased keys.
    /// The first (status / request) line is skipped. Accepts `\r\n` or `\n` line endings.
    /// For duplicate keys the first value wins.
    public static func parseHeaders(_ response: String) -> [String: String] {
        var headers: [String: String] = [:]
        let lines =
            response
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            guard !key.isEmpty, headers[key] == nil else { continue }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }
        return headers
    }

    static func mSearch(st: String) -> String {
        "M-SEARCH * HTTP/1.1\r\n"
            + "HOST: \(multicastAddress):\(port)\r\n"
            + "MAN: \"ssdp:discover\"\r\n"
            + "MX: 1\r\n"
            + "ST: \(st)\r\n"
            + "USER-AGENT: \(userAgent)\r\n"
            + "\r\n"
    }

    /// Maps a UPnP root deviceType (plus manufacturer/name hints) to a kind.
    static func kind(for d: UPnPDescription) -> DeviceKind? {
        guard let type = d.deviceType?.lowercased() else { return nil }
        let maker = (d.manufacturer ?? "").lowercased()
        let name = (d.friendlyName ?? "").lowercased()
        if type.contains("internetgatewaydevice") || type.contains("wandevice")
            || type.contains("wfadevice") || type.contains("landevice")
        {
            return .router
        }
        if type.contains("zoneplayer") { return .speaker }
        if type.contains("mediarenderer") {
            return maker.contains("sonos") || maker.contains("bose") ? .speaker : .tv
        }
        if type.contains("mediaserver") {
            if maker.contains("microsoft") || name.contains("windows") { return .computer }
            if maker.contains("sonos") { return .speaker }
            return .nas
        }
        if type.contains("printer") { return .printer }
        if type.contains("digitalsecuritycamera") { return .camera }
        // DIAL (second-screen casting) receivers are TVs and streaming sticks.
        if type.contains("dial-multiscreen-org:device:dial") { return .tv }
        return nil
    }

    /// "modelName modelNumber", omitting a modelNumber that is already included or looks like a serial.
    static func model(name: String?, number: String?) -> String? {
        let name = name?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        var number = number?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        if let n = number, isSerialish(n) || (name?.localizedCaseInsensitiveContains(n) ?? false) {
            number = nil
        }
        switch (name, number) {
        case (let n?, let num?): return "\(n) \(num)"
        case (let n?, nil): return n
        case (nil, let num?): return num
        default: return nil
        }
    }

    private static func isSerialish(_ s: String) -> Bool {
        if s.count > 16 { return true }
        let hex = s.filter { $0 != "-" && $0 != ":" }
        if hex.count >= 10, hex.allSatisfy(\.isHexDigit), hex.contains(where: \.isNumber) { return true }
        return false
    }

    static func patch(ip: IPv4Address, description d: UPnPDescription?, server: String?) -> DevicePatch {
        var p = DevicePatch(ip: ip)
        p.services = ["UPnP"]
        if let d {
            p.manufacturer = NameCleanup.manufacturer(d.manufacturer)
            p.model = NameCleanup.model(model(name: d.modelName, number: d.modelNumber))
            // Board/firmware ids ("GRX350_1600_MR_AXEPOINT_6X_WAV60") become "Brand Model".
            p.name = NameCleanup.friendlyName(d.friendlyName, manufacturer: p.manufacturer, model: p.model)
            p.kind = kind(for: d)
        } else if let server = server?.lowercased() {
            // e.g. "Linux UPnP/1.0 Sonos/70.3-35220 (ZPS9)"
            if server.contains("sonos") {
                p.manufacturer = "Sonos"
                p.kind = .speaker
            }
        }
        return p
    }
}

extension String {
    fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
}

// MARK: - Bambu Lab printers

/// Bambu Lab 3D printers answer an SSDP-like M-SEARCH on UDP 1990 (and broadcast NOTIFYs to 2021)
/// with `DevModel.bambu.com` / `DevName.bambu.com` headers instead of a UPnP description.
public enum BambuSSDP {
    public static let port: UInt16 = 1990
    public static let searchTarget = "urn:bambulab-com:device:3dprinter:1"

    static func mSearch() -> String {
        "M-SEARCH * HTTP/1.1\r\n"
            + "HOST: \(SSDP.multicastAddress):\(port)\r\n"
            + "MAN: \"ssdp:discover\"\r\n"
            + "MX: 1\r\n"
            + "ST: \(searchTarget)\r\n"
            + "\r\n"
    }

    /// Bambu's internal model codes (as seen in `DevModel.bambu.com`).
    static let models: [String: String] = [
        "BL-P001": "X1 Carbon", "BL-P002": "X1", "C13": "X1E", "C11": "P1P", "C12": "P1S",
        "N1": "A1 mini", "N2S": "A1", "N7": "P2S", "O1D": "H2D", "O1S": "H2S",
    ]

    /// A patch from parsed headers (lowercased keys), or nil if they aren't a Bambu announcement.
    public static func patch(ip: IPv4Address, headers: [String: String]) -> DevicePatch? {
        guard let code = headers["devmodel.bambu.com"]?.trimmingCharacters(in: .whitespaces), !code.isEmpty
        else { return nil }
        var p = DevicePatch(ip: ip)
        p.manufacturer = "Bambu Lab"
        p.model = models[code].map { "\($0) 3D Printer" } ?? "3D Printer (\(code))"
        p.kind = .printer
        if let name = headers["devname.bambu.com"]?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
            p.name = name
        }
        if let v = headers["devversion.bambu.com"], !v.isEmpty { p.osHint = "Bambu firmware \(v)" }
        p.services = ["Bambu Lab"]
        return p
    }
}

// MARK: - UPnP device description

public struct UPnPDescription: Sendable, Equatable {
    public var friendlyName: String?
    public var manufacturer: String?
    public var modelName: String?
    public var modelNumber: String?
    public var deviceType: String?

    public init(
        friendlyName: String? = nil, manufacturer: String? = nil, modelName: String? = nil,
        modelNumber: String? = nil, deviceType: String? = nil
    ) {
        self.friendlyName = friendlyName
        self.manufacturer = manufacturer
        self.modelName = modelName
        self.modelNumber = modelNumber
        self.deviceType = deviceType
    }

    /// Parses a UPnP device description, reading fields from the first (root) `<device>` only.
    public static func parse(_ data: Data) -> UPnPDescription? {
        let parser = XMLParser(data: data)
        let delegate = DescriptionParserDelegate()
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        _ = parser.parse()
        guard delegate.sawDevice else { return nil }
        return delegate.result
    }
}

private final class DescriptionParserDelegate: NSObject, XMLParserDelegate {
    var result = UPnPDescription()
    var sawDevice = false
    private var deviceDepth = 0  // number of open <device> elements
    private var rootClosed = false
    private var elementStack: [String] = []
    private var text = ""

    private static func local(_ name: String) -> String {
        name.split(separator: ":").last.map(String.init) ?? name
    }

    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
        qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]
    ) {
        let name = Self.local(elementName)
        if name == "device" {
            deviceDepth += 1
            sawDevice = true
        }
        elementStack.append(name)
        text = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(
        _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let name = Self.local(elementName)
        _ = elementStack.popLast()
        if name == "device" {
            deviceDepth -= 1
            if deviceDepth == 0 {
                rootClosed = true
                parser.abortParsing()
            }
            return
        }
        // Only direct children of the root <device>.
        guard !rootClosed, deviceDepth == 1, elementStack.last == "device" else { return }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        switch name {
        case "friendlyName": result.friendlyName = result.friendlyName ?? value
        case "manufacturer": result.manufacturer = result.manufacturer ?? value
        case "modelName": result.modelName = result.modelName ?? value
        case "modelNumber": result.modelNumber = result.modelNumber ?? value
        case "deviceType": result.deviceType = result.deviceType ?? value
        default: break
        }
    }
}

// MARK: - Scanner

/// Discovers UPnP devices with SSDP M-SEARCH and enriches them from their description XML.
public final class SSDPScanner: Sendable {
    /// Local address of the interface M-SEARCH multicasts leave from (nil: the system default,
    /// i.e. the primary interface). Needed to reach networks on secondary interfaces.
    public let interfaceAddress: IPv4Address?

    public init(interfaceAddress: IPv4Address? = nil) {
        self.interfaceAddress = interfaceAddress
    }

    public func scan(duration: Duration = .seconds(3)) -> AsyncStream<DevicePatch> {
        AsyncStream { [interfaceAddress] continuation in
            let work = Task {
                await Self.run(duration: duration, interfaceAddress: interfaceAddress, output: continuation)
                continuation.finish()
            }
            // Hard cap: discovery window plus 2 s for in-flight description fetches.
            let cap = Task {
                try? await Task.sleep(for: duration + .seconds(2))
                work.cancel()
            }
            continuation.onTermination = { _ in
                work.cancel()
                cap.cancel()
            }
        }
    }

    private enum Event: Sendable {
        case response(IPv4Address, [String: String])
        case fetchDue(IPv4Address)
    }

    private struct Seen {
        var location: String?
        var isRoot = false
        var server: String?
        var fetched = false
    }

    private static func run(
        duration: Duration, interfaceAddress: IPv4Address?,
        output: AsyncStream<DevicePatch>.Continuation
    ) async {
        guard let socket = UDPSocket.open(interfaceAddress: interfaceAddress) else { return }
        let (events, eventSink) = AsyncStream<Event>.makeStream()

        let queue = DispatchQueue(label: "ssdp.read")
        let source = DispatchSource.makeReadSource(fileDescriptor: socket.rawFD, queue: queue)
        let fd = socket.rawFD
        source.setEventHandler {
            // Dispatch never runs the event handler after the cancel handler, so `fd` is open here.
            for (ip, text) in UDPSocket.drain(fd) {
                eventSink.yield(.response(ip, SSDP.parseHeaders(text)))
            }
        }
        source.setCancelHandler {
            // Closing is serialized with `send` (which then becomes a no-op), so a sender waking
            // up late can't write to a descriptor number the system has reused.
            socket.close()
            eventSink.finish()
        }
        source.activate()
        let sourceBox = SourceBox(source)

        await withTaskCancellationHandler {
            await withTaskGroup(of: Void.self) { group in
                // Every search goes out twice, ~300 ms apart, since multicast UDP is easily dropped.
                group.addTask {
                    socket.send(SSDP.mSearch(st: "ssdp:all"))
                    socket.send(SSDP.mSearch(st: "upnp:rootdevice"))
                    socket.send(BambuSSDP.mSearch(), port: BambuSSDP.port)
                    try? await Task.sleep(for: .milliseconds(300))
                    guard !Task.isCancelled else { return }
                    socket.send(BambuSSDP.mSearch(), port: BambuSSDP.port)
                    socket.send(SSDP.mSearch(st: "ssdp:all"))
                    socket.send(SSDP.mSearch(st: "upnp:rootdevice"))
                }
                // Listening window.
                group.addTask {
                    try? await Task.sleep(for: duration)
                    sourceBox.source.cancel()
                }

                var seen: [IPv4Address: Seen] = [:]

                func startFetch(_ ip: IPv4Address) {
                    guard var s = seen[ip], !s.fetched else { return }
                    s.fetched = true
                    seen[ip] = s
                    let location = s.location
                    let server = s.server
                    group.addTask {
                        let desc = await fetchDescription(location, ip: ip)
                        guard !Task.isCancelled else { return }
                        output.yield(SSDP.patch(ip: ip, description: desc, server: server))
                    }
                }

                for await event in events {
                    switch event {
                    case .response(let ip, let headers):
                        if let bambu = BambuSSDP.patch(ip: ip, headers: headers) {
                            if seen[ip]?.fetched != true {
                                seen[ip] = Seen(fetched: true)
                                output.yield(bambu)
                            }
                            continue
                        }
                        let isNew = seen[ip] == nil
                        var s = seen[ip] ?? Seen()
                        let st = (headers["st"] ?? headers["nt"] ?? "").lowercased()
                        let usn = (headers["usn"] ?? "").lowercased()
                        let root = st == "upnp:rootdevice" || usn.hasSuffix("::upnp:rootdevice")
                        if let loc = headers["location"], !loc.isEmpty, !s.fetched {
                            if s.location == nil || (root && !s.isRoot) {
                                s.location = loc
                                s.isRoot = root
                            }
                        }
                        if s.server == nil { s.server = headers["server"] }
                        seen[ip] = s
                        if s.isRoot {
                            startFetch(ip)
                        } else if isNew {
                            // Give the root-device response a moment to arrive before fetching.
                            group.addTask {
                                try? await Task.sleep(for: .milliseconds(400))
                                guard !Task.isCancelled else { return }
                                eventSink.yield(.fetchDue(ip))
                            }
                        }
                    case .fetchDue(let ip):
                        startFetch(ip)
                    }
                }
                // Window closed: fetch anything still pending.
                for ip in seen.keys { startFetch(ip) }
                await group.waitForAll()
            }
        } onCancel: {
            sourceBox.source.cancel()
        }
    }

    /// UPnP descriptions are small; this bounds a hostile or broken device.
    private static let descriptionCap = 256 * 1024

    private static func fetchDescription(_ location: String?, ip: IPv4Address) async -> UPnPDescription? {
        guard let url = descriptionURL(location, ip: ip) else { return nil }
        // LANSession only follows redirects that stay on private addresses; the read is capped.
        guard
            let data = await ServiceBanners.fetchData(
                url, timeout: .seconds(2), cap: descriptionCap,
                userAgent: SSDP.userAgent)
        else { return nil }
        return UPnPDescription.parse(data)
    }

    /// The description URL, if it's http(s) and served by the responding host itself.
    static func descriptionURL(_ location: String?, ip: IPv4Address) -> URL? {
        guard let location, let url = URL(string: location),
            let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
            url.host == ip.description
        else { return nil }
        return url
    }
}

/// Lets the dispatch source be cancelled from concurrent contexts (cancel() is thread-safe).
private final class SourceBox: @unchecked Sendable {
    let source: any DispatchSourceRead
    init(_ source: any DispatchSourceRead) { self.source = source }
}

// MARK: - BSD UDP socket

final class UDPSocket: Sendable {
    /// The descriptor, or -1 once closed. Sends hold the lock so they can't race `close()`.
    private let fd: Mutex<Int32>
    /// For the dispatch source and `drain` only (which dispatch orders before the close).
    let rawFD: Int32

    private init(fd: Int32) {
        self.fd = Mutex(fd)
        rawFD = fd
    }

    static func open(interfaceAddress: IPv4Address? = nil) -> UDPSocket? {
        let fd = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return nil }
        var addr = sockaddr_in.make(IPv4Address(0), port: 0)  // INADDR_ANY
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            Darwin.close(fd)
            return nil
        }
        var ttl: UInt8 = 2
        setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout<UInt8>.size))
        if let interfaceAddress {
            var ifAddr = in_addr(s_addr: interfaceAddress.value.bigEndian)
            setsockopt(fd, IPPROTO_IP, IP_MULTICAST_IF, &ifAddr, socklen_t(MemoryLayout<in_addr>.size))
        }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        return UDPSocket(fd: fd)
    }

    // A valid dotted-quad literal, so the unwrap can't fail.
    private static let multicastGroup = IPv4Address(SSDP.multicastAddress)!

    /// Sends to the SSDP multicast group; a no-op after `close()`.
    func send(_ message: String, port: UInt16 = SSDP.port) {
        var dest = sockaddr_in.make(Self.multicastGroup, port: port)
        let bytes = Array(message.utf8)
        fd.withLock { fd in
            guard fd >= 0 else { return }
            _ = bytes.withUnsafeBytes { buf in
                withUnsafePointer(to: &dest) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.sendto(fd, buf.baseAddress, buf.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
        }
    }

    func close() {
        fd.withLock { fd in
            guard fd >= 0 else { return }
            Darwin.close(fd)
            fd = -1
        }
    }

    /// Reads all pending datagrams without blocking.
    static func drain(_ fd: Int32) -> [(IPv4Address, String)] {
        var out: [(IPv4Address, String)] = []
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            var from = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = buffer.withUnsafeMutableBytes { buf in
                withUnsafeMutablePointer(to: &from) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.recvfrom(fd, buf.baseAddress, buf.count, 0, $0, &len)
                    }
                }
            }
            guard n > 0 else { break }
            let ip = IPv4Address(UInt32(bigEndian: from.sin_addr.s_addr))
            if let text = String(bytes: buffer[0..<n], encoding: .utf8)
                ?? String(bytes: buffer[0..<n], encoding: .isoLatin1)
            {
                out.append((ip, text))
            }
        }
        return out
    }
}
