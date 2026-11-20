import Foundation
import Testing

@testable import LanternfishKit

@Suite struct HealthCheckTests {
    private static let gateway = IPv4Address("192.168.1.1")!

    private func device(
        _ last: UInt32, kind: DeviceKind = .unknown, ports: [UInt16] = [],
        services: Set<String> = [], name: String? = "Device", mac: String? = "00:11:22:33:44:55",
        isNew: Bool = false
    ) -> Device {
        var d = Device(ip: IPv4Address(0xC0A8_0100 + last))
        d.kind = kind
        d.openPorts = ports.map { OpenPort(port: $0, service: CommonPorts.all[$0]) }
        d.services = services
        d.name = name
        d.mac = mac.flatMap(MACAddress.init)
        d.isNew = isNew
        return d
    }

    private func router(ports: [UInt16] = [53, 80, 443], services: Set<String> = []) -> Device {
        device(1, kind: .router, ports: ports, services: services, name: "Router")
    }

    private func evaluate(_ devices: [Device], wifi: String? = nil) -> HealthReport {
        HealthCheck.evaluate(devices: devices, gateway: Self.gateway, wifiSecurity: wifi)
    }

    private func finding(_ r: HealthReport, _ rule: HealthRule) -> HealthFinding? {
        r.findings.first { $0.rule == rule }
    }

    // MARK: Clean network

    @Test func cleanNetworkScoresFullAndReadsNicely() {
        let r = evaluate(
            [router(), device(10, kind: .phone), device(20, kind: .computer, ports: [22, 445, 5900])],
            wifi: "WPA2/WPA3 Personal")
        #expect(r.score == 100)
        #expect(r.grade == .excellent)
        #expect(r.findings.isEmpty)
        #expect(r.summary == "No problems found on 3 devices.")
        let titles = r.passed.map(\.title)
        #expect(titles.contains("No risky ports open"))
        #expect(titles.contains("Router admin page uses HTTPS"))
        #expect(titles.contains("Wi-Fi is encrypted"))
        #expect(titles.contains("No new devices to review"))
        #expect(titles.contains("Every device is identified"))
        // The all-clear replaces the individual port passes.
        #expect(!titles.contains("No unencrypted remote access"))
    }

    @Test func emptyNetwork() {
        let r = evaluate([])
        #expect(r.isEmpty)
        #expect(r.score == 100)
        #expect(r.findings.isEmpty)
        #expect(r.passed.isEmpty)
        #expect(r.summary == "No devices found yet.")
    }

    // MARK: Remote access

    @Test func telnetIsCriticalAndCapsScore() {
        let r = evaluate([router(), device(30, kind: .iot, ports: [23, 80])])
        let f = finding(r, .telnet)
        #expect(f?.severity == .critical)
        #expect(f?.deviceIDs == [IPv4Address("192.168.1.30")!])
        #expect(f?.title == "1 device has Telnet open")
        #expect(r.score <= 60)
        #expect(r.grade == .fair)
        #expect(r.summary == "1 critical issue needs your attention.")
    }

    @Test func ftpIsAWarning() {
        let r = evaluate([router(), device(6, kind: .printer, ports: [21, 80, 443, 631])])
        #expect(finding(r, .ftp)?.severity == .warning)
        #expect(r.score == 88)
        #expect(r.grade == .good)
        #expect(r.passed.contains { $0.title == "No risky sharing on smart devices" })
        #expect(!r.passed.contains { $0.title == "No risky ports open" })
    }

    // MARK: SMB / RDP / VNC

    @Test func smbOnComputersAndNASIsFine() {
        let r = evaluate([
            router(), device(2, kind: .computer, ports: [445]), device(3, kind: .nas, ports: [445, 443]),
            device(4, kind: .unknown, ports: [445]),
        ])
        #expect(finding(r, .fileSharing) == nil)
    }

    @Test func smbOnRouterOrSmartDeviceWarns() {
        let r = evaluate([router(ports: [53, 80, 443, 445]), device(5, kind: .tv, services: ["File Sharing (SMB)"])])
        let f = finding(r, .fileSharing)
        #expect(f?.severity == .warning)
        #expect(f?.deviceIDs.count == 2)
    }

    @Test func gatewayCountsAsRouterEvenIfUnclassified() {
        let gw = device(1, kind: .unknown, ports: [80, 445])
        let r = evaluate([gw])
        #expect(finding(r, .fileSharing)?.deviceIDs == [Self.gateway])
        #expect(finding(r, .fileSharing)?.title == "Your router shares files over SMB")
        #expect(finding(r, .routerAdminHTTP)?.deviceIDs == [Self.gateway])
    }

    @Test func vncOnMacLikeNASIsNotFlagged() {
        // A Mac sharing Time Machine gets classified as storage; Screen Sharing is normal there.
        let mac = device(
            42, kind: .nas, ports: [80, 443, 445, 5900], services: ["Time Machine", "File Sharing (SMB)"])
        let r = evaluate([router(), mac])
        #expect(finding(r, .remoteDesktop) == nil)
        #expect(finding(r, .fileSharing) == nil)
    }

    @Test func rdpOnCameraWarns() {
        let r = evaluate([router(), device(50, kind: .camera, ports: [443, 3389])])
        #expect(finding(r, .remoteDesktop)?.deviceIDs == [IPv4Address("192.168.1.50")!])
    }

    @Test func vncOnComputerIsFine() {
        let r = evaluate([router(), device(7, kind: .computer, ports: [5900], services: ["Screen Sharing"])])
        #expect(finding(r, .remoteDesktop) == nil)
    }

    // MARK: Router

    @Test func routerHTTPOnlyWarns() {
        let r = evaluate([router(ports: [53, 80])])
        #expect(finding(r, .routerAdminHTTP)?.severity == .warning)
        #expect(!r.passed.contains { $0.rule == .routerAdminHTTP })
    }

    @Test func routerWithoutWebPageSaysNothing() {
        let r = evaluate([router(ports: [53])])
        #expect(finding(r, .routerAdminHTTP) == nil)
        #expect(!r.passed.contains { $0.rule == .routerAdminHTTP })
    }

    @Test func upnpOnGatewayIsInfoOnly() {
        let r = evaluate([router(services: ["UPnP"]), device(9, kind: .tv, services: ["UPnP"])])
        let f = finding(r, .routerUPnP)
        #expect(f?.severity == .info)
        #expect(f?.deviceIDs == [Self.gateway])
        #expect(r.score == 100)
    }

    @Test func upnpOnOtherDevicesIsIgnored() {
        let r = evaluate([router(), device(9, kind: .tv, services: ["UPnP"])])
        #expect(finding(r, .routerUPnP) == nil)
    }

    // MARK: Web interfaces

    @Test func httpOnlyCameraNASAndPrinterWarn() {
        let r = evaluate([
            router(), device(11, kind: .camera, ports: [80, 554]), device(12, kind: .nas, ports: [5000]),
            device(13, kind: .printer, ports: [80, 631]), device(14, kind: .printer, ports: [80, 443]),
            device(15, kind: .iot, ports: [80]), device(16, kind: .computer, ports: [5000]),
        ])
        let f = finding(r, .webWithoutHTTPS)
        #expect(f?.deviceIDs == ["192.168.1.11", "192.168.1.12", "192.168.1.13"].compactMap(IPv4Address.init))
        #expect(f?.title == "3 web interfaces have no HTTPS")
    }

    @Test func synologyWithHTTPSIsFine() {
        let r = evaluate([router(), device(12, kind: .nas, ports: [5000, 5001])])
        #expect(finding(r, .webWithoutHTTPS) == nil)
    }

    // MARK: MQTT / developer services

    @Test func mqttWithoutTLSWarns() {
        let r = evaluate([
            router(), device(20, kind: .iot, ports: [1883]), device(21, kind: .printer, ports: [8883]),
            device(22, kind: .iot, ports: [1883, 8883]),
        ])
        #expect(finding(r, .mqttPlaintext)?.deviceIDs == [IPv4Address("192.168.1.20")!])
    }

    @Test func dockerAndADBWarn() {
        let r = evaluate([
            router(), device(30, kind: .computer, ports: [2375]), device(31, kind: .tv, ports: [5555]),
            device(32, kind: .computer, ports: [2376]),
        ])
        #expect(finding(r, .developerServices)?.deviceIDs.count == 2)
    }

    // MARK: Inventory

    @Test func newUnknownAndPrivateDevicesAreInfoOnly() {
        let r = evaluate([
            router(),
            device(40, name: nil, isNew: true),
            device(41, kind: .phone, name: nil, mac: "DA:11:22:33:44:55"),
            device(42, name: nil, mac: "3E:11:22:33:44:55"),
            device(43, kind: .tablet, mac: "06:11:22:33:44:55"),
        ])
        #expect(finding(r, .newDevices)?.deviceIDs == [IPv4Address("192.168.1.40")!])
        #expect(finding(r, .newDevices)?.title == "1 new device to review")
        // Unknown and unnamed only: the unnamed phone has a known type.
        #expect(finding(r, .unidentified)?.deviceIDs == ["192.168.1.40", "192.168.1.42"].compactMap(IPv4Address.init))
        #expect(finding(r, .unidentified)?.title == "2 devices you haven't identified or named")
        #expect(finding(r, .privateMACs)?.deviceIDs.count == 3)
        #expect(r.findings.allSatisfy { $0.severity == .info })
        #expect(r.score == 100)
    }

    @Test func customNameOrKindIdentifies() {
        var a = device(40, name: nil)
        a.customName = "Thermostat"
        var b = device(41, name: nil)
        b.customKind = .iot
        var selfMac = device(42, name: nil)
        selfMac.isSelf = true
        let r = evaluate([router(), a, b, selfMac])
        #expect(finding(r, .unidentified) == nil)
        #expect(r.passed.contains { $0.rule == .unidentified })
    }

    @Test func fewPrivateMACsSayNothing() {
        let r = evaluate([
            router(), device(41, kind: .phone, mac: "DA:11:22:33:44:55"),
            device(42, kind: .phone, mac: "3E:11:22:33:44:55"),
        ])
        #expect(finding(r, .privateMACs) == nil)
    }

    // MARK: Wi-Fi

    @Test(arguments: [
        ("None", HealthSeverity.critical), ("WEP", .critical), ("Dynamic WEP", .critical),
        ("WPA Personal", .warning), ("WPA Enterprise", .warning),
        ("WPA2 Personal", .passed), ("WPA/WPA2 Personal", .passed), ("WPA3 Personal", .passed),
        ("Enhanced Open (OWE)", .passed), ("Personal", .passed),
    ])
    func wifiSecurity(label: String, expected: HealthSeverity) {
        let r = evaluate([router()], wifi: label)
        let f = r.findings.first { $0.rule == .wifiSecurity } ?? r.passed.first { $0.rule == .wifiSecurity }
        #expect(f?.severity == expected)
    }

    @Test func unknownOrMissingWiFiSecuritySaysNothing() {
        for label in [nil, "", "Something New"] {
            let r = evaluate([router()], wifi: label)
            #expect(!(r.findings + r.passed).contains { $0.rule == .wifiSecurity })
        }
    }

    // MARK: Score

    @Test func scoreAndOrdering() {
        let r = evaluate(
            [
                router(ports: [53, 80, 445]), device(30, kind: .iot, ports: [23]),
                device(31, kind: .iot, ports: [21, 1883]),
            ],
            wifi: "WEP")
        // Most severe first.
        #expect(r.findings.map(\.severity) == r.findings.map(\.severity).sorted())
        #expect(r.criticalCount == 2)
        #expect(r.grade == .atRisk)
        #expect(r.summary == "2 critical issues and 4 warnings need your attention.")
        #expect(r.score >= 0)
    }

    @Test func extraDevicesCostLessThanExtraFindings() {
        let one = HealthCheck.score(for: [
            HealthFinding(
                rule: .ftp, severity: .warning, title: "", detail: "",
                deviceIDs: [Self.gateway])
        ])
        let three = HealthCheck.score(for: [
            HealthFinding(
                rule: .ftp, severity: .warning, title: "", detail: "",
                deviceIDs: Array(repeating: Self.gateway, count: 3))
        ])
        let many = HealthCheck.score(for: [
            HealthFinding(
                rule: .ftp, severity: .warning, title: "", detail: "",
                deviceIDs: Array(repeating: Self.gateway, count: 30))
        ])
        #expect(one == 88)
        #expect(three == 84)
        #expect(many == 82)
    }

    @Test func grades() {
        #expect(HealthGrade(score: 100) == .excellent)
        #expect(HealthGrade(score: 90) == .excellent)
        #expect(HealthGrade(score: 89) == .good)
        #expect(HealthGrade(score: 70) == .good)
        #expect(HealthGrade(score: 69) == .fair)
        #expect(HealthGrade(score: 45) == .fair)
        #expect(HealthGrade(score: 44) == .atRisk)
    }
}
