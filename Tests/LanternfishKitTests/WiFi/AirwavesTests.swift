import Foundation
import Testing

@testable import LanternfishKit

@Suite struct AirwavesTests {
    // MARK: Frequency mapping

    @Test func twoPointFourFrequencies() {
        #expect(WiFiChannels.frequency(channel: 1, band: .ghz2) == 2412)
        #expect(WiFiChannels.frequency(channel: 6, band: .ghz2) == 2437)
        #expect(WiFiChannels.frequency(channel: 13, band: .ghz2) == 2472)
        #expect(WiFiChannels.frequency(channel: 14, band: .ghz2) == 2484)
        #expect(WiFiChannels.frequency(channel: 0, band: .ghz2) == nil)
        #expect(WiFiChannels.frequency(channel: 15, band: .ghz2) == nil)
    }

    @Test func fiveAndSixGHzFrequencies() {
        #expect(WiFiChannels.frequency(channel: 36, band: .ghz5) == 5180)
        #expect(WiFiChannels.frequency(channel: 149, band: .ghz5) == 5745)
        #expect(WiFiChannels.frequency(channel: 165, band: .ghz5) == 5825)
        #expect(WiFiChannels.frequency(channel: 1, band: .ghz6) == 5955)
        #expect(WiFiChannels.frequency(channel: 37, band: .ghz6) == 6135)
        #expect(WiFiChannels.frequency(channel: 233, band: .ghz6) == 7115)
        #expect(WiFiChannels.frequency(channel: 2, band: .ghz6) == 5935)
        #expect(WiFiChannels.frequency(channel: 3, band: .ghz6) == nil, "not a 20 MHz 6 GHz channel")
    }

    @Test func frequencyRoundTrips() throws {
        for band in [WiFiBand.ghz2, .ghz5, .ghz6] {
            for ch in WiFiChannels.channels(in: band) {
                let f = try #require(WiFiChannels.frequency(channel: ch, band: band))
                let back = WiFiChannels.channel(frequency: f)
                #expect(back?.channel == ch && back?.band == band, "\(band.label) channel \(ch)")
            }
        }
        #expect(WiFiChannels.channel(frequency: 2400) == nil)
    }

    @Test func channelLists() {
        #expect(WiFiChannels.channels(in: .ghz2) == Array(1...14))
        let five = WiFiChannels.channels(in: .ghz5)
        #expect(five.first == 36 && five.last == 177)
        #expect(!five.contains(68) && !five.contains(96) && five.contains(144) && five.contains(149))
        #expect(WiFiChannels.channels(in: .ghz6).count == 59)
    }

    @Test func dfsAndPSC() {
        #expect(!WiFiChannels.isDFS(channel: 48, band: .ghz5))
        #expect(WiFiChannels.isDFS(channel: 52, band: .ghz5))
        #expect(WiFiChannels.isDFS(channel: 144, band: .ghz5))
        #expect(!WiFiChannels.isDFS(channel: 149, band: .ghz5))
        #expect(!WiFiChannels.isDFS(channel: 52, band: .ghz6))
        #expect(WiFiChannels.isPSC(channel: 5, band: .ghz6))
        #expect(WiFiChannels.isPSC(channel: 37, band: .ghz6))
        #expect(WiFiChannels.isPSC(channel: 229, band: .ghz6))
        #expect(!WiFiChannels.isPSC(channel: 1, band: .ghz6))
        #expect(!WiFiChannels.isPSC(channel: 5, band: .ghz5))
        // 160 MHz at 36 spans 36–64 and so touches DFS.
        let wide = WiFiChannels.span(primary: 36, width: 160, band: .ghz5)!
        #expect(WiFiChannels.touchesDFS(wide, band: .ghz5))
        #expect(!WiFiChannels.touchesDFS(WiFiChannels.span(primary: 36, width: 80, band: .ghz5)!, band: .ghz5))
    }

    // MARK: Channel spans

    @Test func twoPointFourSpans() throws {
        let s20 = try #require(WiFiChannels.span(primary: 6, width: 20, band: .ghz2))
        #expect(s20.lower == 2427 && s20.upper == 2447)
        // 20 MHz on channel 6 reaches the centers of channels 4 and 8 (±2 channels).
        #expect(s20.lower == Double(WiFiChannels.frequency(channel: 4, band: .ghz2)!))
        #expect(s20.upper == Double(WiFiChannels.frequency(channel: 8, band: .ghz2)!))
        #expect(WiFiChannels.subchannels(of: s20, band: .ghz2) == [5, 6, 7])

        let above = try #require(WiFiChannels.span(primary: 1, width: 40, band: .ghz2, secondary: .above))
        #expect(above.center == 2422 && above.width == 40)  // center channel 3
        let below = try #require(WiFiChannels.span(primary: 11, width: 40, band: .ghz2, secondary: .below))
        #expect(below.center == 2452)  // center channel 9
        #expect(WiFiChannels.centerChannel(primary: 6, width: 40, band: .ghz2, secondary: .above) == 8)
        #expect(WiFiChannels.centerChannel(primary: 6, width: 40, band: .ghz2, secondary: .below) == 4)
    }

    @Test func twoPointFourFortyFallsBackToAValidSide() {
        // Unknown side: low channels above, high channels below.
        #expect(WiFiChannels.centerChannel(primary: 3, width: 40, band: .ghz2) == 5)
        #expect(WiFiChannels.centerChannel(primary: 11, width: 40, band: .ghz2) == 9)
        // Impossible sides flip.
        #expect(WiFiChannels.centerChannel(primary: 2, width: 40, band: .ghz2, secondary: .below) == 4)
        #expect(WiFiChannels.centerChannel(primary: 12, width: 40, band: .ghz2, secondary: .above) == 10)
        #expect(WiFiChannels.centerChannel(primary: 6, width: 80, band: .ghz2) == nil)
        #expect(WiFiChannels.centerChannel(primary: 14, width: 40, band: .ghz2) == nil)
    }

    @Test func fiveGHzBonding() {
        func center(_ p: Int, _ w: Int) -> Int? { WiFiChannels.centerChannel(primary: p, width: w, band: .ghz5) }
        #expect(center(36, 20) == 36)
        #expect(center(36, 40) == 38)
        #expect(center(40, 40) == 38)
        #expect(center(44, 40) == 46)
        #expect(center(36, 80) == 42)
        #expect(center(48, 80) == 42)
        #expect(center(52, 80) == 58)
        #expect(center(100, 80) == 106)
        #expect(center(140, 80) == 138)
        #expect(center(149, 80) == 155)
        #expect(center(165, 80) == 171)
        #expect(center(36, 160) == 50)
        #expect(center(64, 160) == 50)
        #expect(center(112, 160) == 114)
        #expect(center(132, 160) == nil, "132–160 would leave UNII-2C")
        #expect(center(149, 160) == 163)
        #expect(center(144, 40) == 142)
        #expect(center(36, 320) == nil)
        #expect(center(37, 20) == nil)

        let s = WiFiChannels.span(primary: 44, width: 80, band: .ghz5)!
        #expect(s.lower == 5170 && s.upper == 5250)
        #expect(WiFiChannels.subchannels(of: s, band: .ghz5) == [36, 40, 44, 48])
    }

    @Test func sixGHzBonding() {
        func center(_ p: Int, _ w: Int) -> Int? { WiFiChannels.centerChannel(primary: p, width: w, band: .ghz6) }
        #expect(center(1, 40) == 3)
        #expect(center(5, 40) == 3)
        #expect(center(37, 80) == 39)
        #expect(center(37, 160) == 47)
        #expect(center(5, 160) == 15)
        #expect(center(5, 320) == 31)
        #expect(center(69, 320) == 95)
        #expect(center(197, 320) == nil, "the last 320 MHz block would pass channel 233")
        #expect(center(233, 20) == 233)
        let s = WiFiChannels.span(primary: 37, width: 160, band: .ghz6)!
        #expect(s.center == 6185 && s.lower == 6105 && s.upper == 6265)
    }

    @Test func spanOverlap() {
        let a = ChannelSpan(center: 2412, width: 20)
        let b = ChannelSpan(center: 2437, width: 20)
        #expect(a.overlap(with: b) == 0)
        #expect(!a.overlaps(b))
        let c = ChannelSpan(center: 2422, width: 20)
        #expect(a.overlap(with: c) == 10)
        #expect(a.overlapFraction(with: c) == 0.5)
        let wide = ChannelSpan(center: 5210, width: 80)
        #expect(ChannelSpan(center: 5180, width: 20).overlapFraction(with: wide) == 1)
        #expect(wide.overlapFraction(with: ChannelSpan(center: 5180, width: 20)) == 0.25)
    }

    // MARK: Axis

    @Test func bandAxisMapsSegmentsAndGaps() {
        let axis = BandAxis(band: .ghz5)
        #expect(axis.position(of: 5165) == 0)
        #expect(abs(axis.position(of: 5900) - 1) < 1e-9)
        let endFirst = axis.position(of: 5335)
        let startSecond = axis.position(of: 5485)
        #expect(abs(startSecond - endFirst - axis.gapFraction) < 1e-9)
        // Inside the gap snaps to an edge; frequency(at:) inside the gap is nil.
        #expect(axis.position(of: 5340) == endFirst)
        #expect(axis.frequency(at: endFirst + axis.gapFraction / 2) == nil)
        for f in [5180.0, 5320, 5500, 5745, 5885] {
            #expect(abs(axis.frequency(at: axis.position(of: f))! - f) < 1e-6)
        }
        #expect(axis.gaps.count == 1)
        #expect(BandAxis(band: .ghz2).gaps.isEmpty)
    }

    // MARK: Model

    @Test func hiddenAndRedactedNames() {
        let hidden = WiFiScanResult(ssid: "", bssid: "AA:BB:CC:00:11:22", rssi: -60, channel: 6, band: .ghz2)
        #expect(hidden.ssid == nil)
        #expect(hidden.isHidden)
        #expect(hidden.displayName == "Hidden network")
        let nul = WiFiScanResult(ssid: "\0\0\0", bssid: "AA:BB:CC:00:11:23", rssi: -60, channel: 6, band: .ghz2)
        #expect(nul.isHidden)
        let redacted = WiFiScanResult(ssid: nil, bssid: nil, isNameRedacted: true, rssi: -60, channel: 6, band: .ghz2)
        #expect(!redacted.isHidden)
        #expect(redacted.displayName == "Unnamed network")
        let named = WiFiScanResult(ssid: "Home", bssid: "aa-bb-cc-00-11-22", rssi: -50, channel: 36, band: .ghz5)
        #expect(named.displayName == "Home")
        #expect(named.bssid == "aa:bb:cc:00:11:22")
        #expect(named.id == "aa:bb:cc:00:11:22")
    }

    @Test func invalidWidthFallsBackToTwenty() {
        let r = WiFiScanResult(rssi: -60, channel: 140, band: .ghz5)
        #expect(r.width == 20)
        let wide = WiFiScanResult(rssi: -60, channel: 140, band: .ghz5, width: 160)
        #expect(wide.width == 20)
        let ok = WiFiScanResult(rssi: -60, channel: 140, band: .ghz5, width: 80)
        #expect(ok.width == 80 && ok.centerChannel == 138 && ok.channelLabel == "140 (138)")
        #expect(ok.isDFS)
    }

    @Test func brandFromBSSID() {
        let db = VendorDatabase(tsv: "A0B1C2\tNetgear\n")
        let r = WiFiScanResult(bssid: "a0:b1:c2:01:02:03", rssi: -50, channel: 1, band: .ghz2)
        #expect(r.brand(in: db) == "Netgear")
        // Locally administered (second bit of the first octet): no brand.
        let local = WiFiScanResult(bssid: "a2:b1:c2:01:02:03", rssi: -50, channel: 1, band: .ghz2)
        #expect(local.isLocallyAdministered)
        #expect(local.brand(in: db) == nil)
        #expect(WiFiScanResult(rssi: -50, channel: 1, band: .ghz2).brand(in: db) == nil)
    }

    @Test func securityFromSupportedModes() {
        #expect(WiFiSecurity.from(supported: [0]) == .open)
        #expect(WiFiSecurity.from(supported: [1]) == .wep)
        #expect(WiFiSecurity.from(supported: [4]) == .wpa2)
        #expect(WiFiSecurity.from(supported: [3, 4]) == .wpaWPA2)
        #expect(WiFiSecurity.from(supported: [11]) == .wpa3)
        #expect(WiFiSecurity.from(supported: [4, 11]) == .wpa2WPA3)
        #expect(WiFiSecurity.from(supported: [4, 11, 13]) == .wpa2WPA3)
        #expect(WiFiSecurity.from(supported: [9]) == .wpa2Enterprise)
        #expect(WiFiSecurity.from(supported: [9, 12]) == .wpa3Enterprise)
        #expect(WiFiSecurity.from(supported: [14]) == .owe)
        #expect(WiFiSecurity.from(supported: []) == .unknown)
        #expect(WiFiSecurity.open.isWeak && !WiFiSecurity.wpa2.isWeak)
    }

    @Test func standardFromModes() {
        #expect(WiFiStandard.highest(supported: [1, 4, 5, 6]) == .ax)
        #expect(WiFiStandard.highest(supported: [2, 3]) == .g)
        #expect(WiFiStandard.highest(supported: [7, 6]) == .be)
        #expect(WiFiStandard.highest(supported: []) == nil)
        #expect(WiFiStandard.ax.label == "802.11ax (Wi-Fi 6)")
        #expect(WiFiStandard.g.label == "802.11g")
    }

    @Test func parsesInformationElements() {
        // SSID "ab", HT Operation (primary 6, secondary below), VHT caps, HE caps (ext 35).
        let bytes: [UInt8] =
            [
                0, 2, 0x61, 0x62,
                61, 22, 6, 0x07,
            ] + Array(repeating: 0, count: 20)
            + [191, 12] + Array(repeating: 0, count: 12)
            + [255, 3, 35, 0, 0]
        let ies = WiFiInformationElements(data: Data(bytes))
        #expect(ies.elements[0] == Data([0x61, 0x62]))
        #expect(ies.htSecondaryChannel == .below)
        #expect(ies.standard == .ax)
        let above = WiFiInformationElements(data: Data([61, 2, 1, 0x05]))
        #expect(above.htSecondaryChannel == .above)
        #expect(above.standard == nil)
        // Truncated element: parsing stops without crashing.
        #expect(WiFiInformationElements(data: Data([61, 9, 1])).htSecondaryChannel == nil)
    }

    @Test func idsAreUniqueWithoutBSSIDs() {
        let a = WiFiScanResult(isNameRedacted: true, rssi: -70, channel: 6, band: .ghz2)
        let b = WiFiScanResult(isNameRedacted: true, rssi: -50, channel: 6, band: .ghz2)
        let c = WiFiScanResult(bssid: "00:11:22:33:44:55", rssi: -60, channel: 6, band: .ghz2)
        let dupe = WiFiScanResult(bssid: "00:11:22:33:44:55", rssi: -80, channel: 6, band: .ghz2)
        #expect(a.id == b.id)
        let out = WiFiScanner.assignIDs([a, b, c, dupe])
        #expect(out.count == 3)
        #expect(Set(out.map(\.id)).count == 3)
        // The strongest keeps the bare key.
        #expect(out.first { $0.rssi == -50 }?.id == b.id)
        #expect(out.first { $0.rssi == -70 }?.id == b.id + "#2")
        #expect(out.first { $0.bssid != nil }?.rssi == -60)
    }

    @Test func groupsBySSID() {
        let results = [
            WiFiScanResult(ssid: "Home", bssid: "00:00:00:00:00:01", rssi: -60, channel: 1, band: .ghz2),
            WiFiScanResult(ssid: "Home", bssid: "00:00:00:00:00:02", rssi: -45, channel: 36, band: .ghz5),
            WiFiScanResult(ssid: nil, bssid: "00:00:00:00:00:03", rssi: -70, channel: 6, band: .ghz2),
            WiFiScanResult(ssid: nil, bssid: "00:00:00:00:00:04", rssi: -72, channel: 11, band: .ghz2),
            WiFiScanResult(ssid: "Cafe", bssid: "00:00:00:00:00:05", rssi: -80, channel: 11, band: .ghz2),
        ]
        let groups = WiFiNetworkGroup.group(results)
        #expect(groups.count == 4, "hidden networks are not merged")
        #expect(groups[0].name == "Home")
        #expect(groups[0].members.map(\.rssi) == [-45, -60])
        #expect(groups[0].bands == [.ghz2, .ghz5])
        #expect(groups.last?.name == "Cafe")
        #expect(groups.filter { $0.name == "Hidden network" }.count == 2)
    }

    @Test func signalHistoryKeepsAWindow() {
        var h = WiFiSignalHistory(window: 300)
        let t0 = Date(timeIntervalSince1970: 1_000)
        let r = WiFiScanResult(bssid: "00:00:00:00:00:01", rssi: -60, channel: 1, band: .ghz2)
        h.record([r], at: t0)
        h.record([r], at: t0.addingTimeInterval(200))
        #expect(h.samples(for: r.id).count == 2)
        h.record([], at: t0.addingTimeInterval(400))
        #expect(h.samples(for: r.id).map(\.date) == [t0.addingTimeInterval(200)])
        h.trim(now: t0.addingTimeInterval(1_000))
        #expect(h.samples(for: r.id).isEmpty)
        #expect(h.samples.isEmpty)
    }

    @Test func matchesCurrentNetwork() {
        let results = [
            WiFiScanResult(ssid: "Home", bssid: "00:00:00:00:00:01", rssi: -48, channel: 36, band: .ghz5, width: 80),
            WiFiScanResult(ssid: "Other", bssid: "00:00:00:00:00:02", rssi: -70, channel: 36, band: .ghz5),
        ]
        let byBSSID = WiFiInfo(
            interfaceName: "en0", ssid: "Home", bssid: "0:0:0:0:0:1", channel: 36, band: .ghz5, rssi: -50)
        #expect(WiFiScanResult.currentID(in: results, connection: byBSSID) == "00:00:00:00:00:01")
        // Redacted: same channel, closest RSSI.
        let redacted = results.map {
            WiFiScanResult(isNameRedacted: true, rssi: $0.rssi, channel: $0.channel, band: $0.band, width: $0.width)
        }
        let anon = WiFiInfo(interfaceName: "en0", channel: 36, band: .ghz5, rssi: -51)
        #expect(WiFiScanResult.currentID(in: redacted, connection: anon) == redacted[0].id)
        let far = WiFiInfo(interfaceName: "en0", channel: 36, band: .ghz5, rssi: -95)
        #expect(WiFiScanResult.currentID(in: redacted, connection: far) == nil)
        #expect(WiFiScanResult.currentID(in: results, connection: nil) == nil)
    }

    // MARK: Channel advice

    private func net(_ ch: Int, _ rssi: Int, band: WiFiBand = .ghz2, width: Int = 20, id: Int) -> WiFiScanResult {
        WiFiScanResult(
            bssid: String(format: "00:00:00:00:01:%02x", id), rssi: rssi, channel: ch, band: band, width: width)
    }

    @Test func weightIsLinearPower() {
        #expect(abs(ChannelAdvisor.weight(rssi: -50) / ChannelAdvisor.weight(rssi: -60) - 10) < 1e-9)
        #expect(abs(ChannelAdvisor.weight(rssi: -30) - 0.001) < 1e-12)
    }

    @Test func congestionUsesOverlapFraction() {
        let span = WiFiChannels.span(primary: 1, width: 20, band: .ghz2)!
        // Channel 3 overlaps channel 1 by 10 of 20 MHz; channel 6 doesn't overlap.
        let c = ChannelAdvisor.congestion(of: span, networks: [net(3, -50, id: 1), net(6, -40, id: 2)])
        #expect(c.overlapping == 1)
        #expect(abs(c.score - 0.5 * ChannelAdvisor.weight(rssi: -50)) < 1e-15)
        #expect(c.strongest == -50)
    }

    @Test func recommendsLeastCongestedTwoPointFour() {
        let mine = net(8, -45, id: 0)
        let others = [
            net(6, -55, id: 1), net(6, -60, id: 2), net(9, -65, id: 3), net(11, -58, id: 4),
            net(10, -70, id: 5), net(1, -85, id: 6),
        ]
        let connection = WiFiInfo(interfaceName: "en0", bssid: mine.bssid, channel: 8, band: .ghz2, rssi: -45)
        let advice = ChannelAdvisor.advise(
            band: .ghz2, networks: [mine] + others, currentID: mine.id,
            connection: connection)
        #expect(advice.candidates.map(\.channel) == [1, 6, 11])
        #expect(advice.best?.channel == 1)
        #expect(advice.current?.channel == 8)
        #expect(advice.current?.overlapping == 5)
        #expect(advice.networkCount == 6)
        #expect(advice.shouldSwitch)
        #expect(
            advice.summary(router: "Netgear")
                == "Your Netgear is on channel 8, which overlaps 5 networks. Channel 1 is quieter.")
    }

    @Test func staysPutWhenAlreadyQuietest() {
        let mine = net(1, -40, id: 0)
        let others = [net(6, -50, id: 1), net(11, -52, id: 2), net(3, -88, id: 3)]
        let advice = ChannelAdvisor.advise(band: .ghz2, networks: [mine] + others, currentID: mine.id, connection: nil)
        #expect(advice.best?.channel == 1)
        #expect(!advice.shouldSwitch)
        #expect(advice.summary(router: nil).hasPrefix("Your router is on channel 1, which overlaps 1 network."))
    }

    @Test func fiveGHzPrefersNonDFSAndUsesYourWidth() {
        let mine = net(36, -45, band: .ghz5, width: 80, id: 0)
        let others = [
            net(40, -50, band: .ghz5, width: 80, id: 1), net(149, -75, band: .ghz5, width: 80, id: 2),
            net(161, -80, band: .ghz5, id: 3),
        ]
        let advice = ChannelAdvisor.advise(band: .ghz5, networks: [mine] + others, currentID: mine.id, connection: nil)
        #expect(advice.width == 80)
        // One candidate per 80 MHz block, UNII-4 excluded.
        #expect(advice.candidates.map(\.channel) == [36, 52, 100, 116, 132, 149])
        #expect(advice.candidates.filter(\.isDFS).map(\.channel) == [52, 100, 116, 132])
        // Both non-DFS blocks carry signal while the DFS blocks are silent: a DFS block wins (flagged).
        #expect(advice.best?.isDFS == true)
        #expect(advice.current?.overlapping == 1)
        #expect(advice.isCurrent(advice.candidates[0]))
    }

    @Test func fiveGHzNonDFSWinsWhenDFSIsOnlySlightlyQuieter() {
        // Every block carries signal; DFS block 52 is 3 dB quieter than 149, not enough to beat the 6 dB penalty.
        var others: [WiFiScanResult] = []
        for (i, ch) in [36, 100, 116, 132].enumerated() { others.append(net(ch, -50, band: .ghz5, width: 80, id: i)) }
        others.append(net(52, -73, band: .ghz5, width: 80, id: 10))
        others.append(net(149, -70, band: .ghz5, width: 80, id: 11))
        let advice = ChannelAdvisor.advise(band: .ghz5, networks: others, currentID: nil, connection: nil)
        #expect(advice.current == nil)
        #expect(advice.best?.channel == 149)
        #expect(advice.summary(router: nil) == "Quietest 5 GHz option: channel 149 (overlaps 1 network).")
    }

    @Test func sixGHzCandidatesArePSCs() {
        let advice = ChannelAdvisor.advise(
            band: .ghz6, networks: [net(37, -60, band: .ghz6, width: 160, id: 1)],
            currentID: nil, connection: nil)
        #expect(advice.width == 160)
        #expect(advice.candidates.allSatisfy { $0.isPSC })
        #expect(advice.candidates.map(\.channel).prefix(3) == [5, 37, 69])
        #expect(advice.best?.channel == 5)
        #expect(advice.best?.overlapping == 0)
        #expect(advice.best?.level == nil)
    }

    @Test func emptyBandSummary() {
        let advice = ChannelAdvisor.advise(band: .ghz6, networks: [], currentID: nil, connection: nil)
        #expect(advice.summary(router: nil) == "No other networks heard on 6 GHz.")
    }
}
