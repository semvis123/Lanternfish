import Foundation

/// One channel option, scored by how much of the nearby networks' signal falls inside it.
public struct ChannelCandidate: Sendable, Hashable, Identifiable {
    /// Primary channel (the lowest 20 MHz channel of a wide block).
    public var channel: Int
    public var span: ChannelSpan
    /// Overlap-weighted sum of neighbour signal power, in mW (0 = nothing heard).
    public var score: Double
    /// Networks that overlap the span at all.
    public var overlapping: Int
    public var strongestRSSI: Int?
    public var isDFS: Bool
    public var isPSC: Bool

    public var id: Int { channel }

    /// Combined neighbour signal in dBm; nil when nothing overlaps.
    public var level: Double? { score > 0 ? 10 * log10(score) : nil }
}

/// Channel advice for one band.
public struct ChannelAdvice: Sendable, Hashable {
    public var band: WiFiBand
    /// Width the candidates were evaluated for (your channel width when connected on this band).
    public var width: Int
    /// Candidate channels in channel order.
    public var candidates: [ChannelCandidate]
    /// Your network's channel, evaluated the same way (nil when not connected on this band).
    public var current: ChannelCandidate?
    /// Recommended channel: the quietest, preferring non-DFS unless a DFS option is much quieter.
    public var best: ChannelCandidate?
    /// Number of networks heard on this band (excluding yours).
    public var networkCount: Int

    /// True when `best` carries clearly less neighbour signal (≥ 3 dB) than your channel.
    public var shouldSwitch: Bool {
        guard let current, let best, best.span != current.span else { return false }
        return current.score > 0 && best.score <= current.score / 2
    }

    public func isCurrent(_ c: ChannelCandidate) -> Bool { current?.span == c.span }

    /// Plain-language summary, e.g. "Your Netgear is on channel 8, which overlaps 5 networks.
    /// Channel 1 is quieter." `router` is the brand of your access point, if known.
    public func summary(router: String?) -> String {
        let who = router.map { "Your \($0)" } ?? "Your router"
        func networks(_ n: Int) -> String { n == 1 ? "1 network" : "\(n) networks" }
        func name(_ c: ChannelCandidate) -> String {
            c.isDFS ? "DFS channel \(c.channel)" : "Channel \(c.channel)"
        }
        guard networkCount > 0 || current != nil else {
            return "No other networks heard on \(band.label)."
        }
        if let current {
            let overlap =
                current.overlapping == 0
                ? "which no other network overlaps"
                : "which overlaps \(networks(current.overlapping))"
            let head = "\(who) is on channel \(current.channel), \(overlap)."
            if shouldSwitch, let best {
                let extra = best.overlapping == 0 ? " and clear of other networks" : ""
                return "\(head) \(name(best)) is quieter\(extra)."
            }
            return current.overlapping == 0
                ? "\(head) No change needed."
                : "\(head) That's already about as quiet as it gets here."
        }
        guard let best else { return "No channel to recommend on \(band.label)." }
        let clear = best.overlapping == 0 ? "clear of other networks" : "overlaps \(networks(best.overlapping))"
        return "Quietest \(band.label) option: \(name(best).lowercased()) (\(clear))."
    }
}

/// Scores channels by the signal of overlapping networks. This is a proxy for congestion: a Mac
/// can measure how loud neighbours are, not how much airtime they actually use.
public enum ChannelAdvisor {
    /// Received power in mW. Signal power — not network count — is what interferes.
    public static func weight(rssi: Int) -> Double { pow(10, Double(rssi) / 10) }

    /// Congestion of `span`: Σ overlap fraction × signal weight over `networks`.
    public static func congestion(of span: ChannelSpan, networks: [WiFiScanResult])
        -> (score: Double, overlapping: Int, strongest: Int?)
    {
        var score = 0.0
        var count = 0
        var strongest: Int?
        for n in networks {
            let f = span.overlapFraction(with: n.span)
            guard f > 0 else { continue }
            score += f * weight(rssi: n.rssi)
            count += 1
            strongest = max(strongest ?? n.rssi, n.rssi)
        }
        return (score, count, strongest)
    }

    /// Candidate primaries: 2.4 GHz 1/6/11; 5 GHz every channel up to 165 (DFS flagged); 6 GHz PSCs.
    public static func candidateChannels(band: WiFiBand) -> [Int] {
        switch band {
        case .ghz2: [1, 6, 11]
        case .ghz5: WiFiChannels.channels(in: .ghz5)
        case .ghz6: WiFiChannels.channels(in: .ghz6).filter { WiFiChannels.isPSC(channel: $0, band: .ghz6) }
        case .unknown: []
        }
    }

    /// Default width when you aren't connected on the band.
    public static func defaultWidth(band: WiFiBand) -> Int {
        switch band {
        case .ghz2: 20
        case .ghz5: 80
        case .ghz6: 160
        case .unknown: 20
        }
    }

    /// - Parameters:
    ///   - networks: everything heard (any band; filtered to `band`).
    ///   - currentID: id of your network's scan result, excluded from the neighbours.
    ///   - connection: your channel (used when on `band`).
    public static func advise(
        band: WiFiBand, networks: [WiFiScanResult], currentID: String?,
        connection: WiFiInfo?
    ) -> ChannelAdvice {
        let neighbours = networks.filter { $0.band == band && $0.id != currentID }
        let own = networks.first { $0.id == currentID && $0.band == band }

        // Your channel and width: the scan result first (it knows the 40 MHz side), else the connection.
        var currentSpan: ChannelSpan?
        var currentChannel: Int?
        var width = defaultWidth(band: band)
        if let own {
            currentSpan = own.span
            currentChannel = own.channel
            width = own.width
        } else if let c = connection, c.isAssociated, c.band == band, let ch = c.channel {
            let w = c.channelWidth ?? 20
            currentSpan =
                WiFiChannels.span(primary: ch, width: w, band: band)
                ?? WiFiChannels.span(primary: ch, width: 20, band: band)
            currentChannel = ch
            if currentSpan?.width == w { width = w }
        }
        if band == .ghz2 { width = 20 }  // 40 MHz in 2.4 GHz can't avoid overlap; advise on 20 MHz.

        var seen = Set<ChannelSpan>()
        var candidates: [ChannelCandidate] = []
        for ch in candidateChannels(band: band) {
            guard let span = WiFiChannels.span(primary: ch, width: width, band: band),
                band != .ghz5 || span.upper <= 5835,  // UNII-4 (169–177) isn't allowed in most countries
                seen.insert(span).inserted
            else { continue }
            candidates.append(candidate(ch, span: span, band: band, neighbours: neighbours))
        }

        var current: ChannelCandidate?
        if let ch = currentChannel, let span = currentSpan {
            current = candidate(ch, span: span, band: band, neighbours: neighbours)
        }

        // Quietest first; DFS options count 4× (6 dB) louder since radar can force a channel change.
        func cost(_ c: ChannelCandidate) -> Double { (c.score + 1e-12) * (c.isDFS ? 4 : 1) }
        let best = candidates.min { a, b in
            (cost(a), a.overlapping, a.channel) < (cost(b), b.overlapping, b.channel)
        }
        return ChannelAdvice(
            band: band, width: width, candidates: candidates, current: current, best: best,
            networkCount: neighbours.count)
    }

    private static func candidate(
        _ ch: Int, span: ChannelSpan, band: WiFiBand,
        neighbours: [WiFiScanResult]
    ) -> ChannelCandidate {
        let c = congestion(of: span, networks: neighbours)
        return ChannelCandidate(
            channel: ch, span: span, score: c.score, overlapping: c.overlapping,
            strongestRSSI: c.strongest,
            isDFS: WiFiChannels.touchesDFS(span, band: band),
            isPSC: WiFiChannels.isPSC(channel: ch, band: band))
    }
}
