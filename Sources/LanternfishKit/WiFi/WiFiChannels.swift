import Foundation

public typealias WiFiBand = WiFiInfo.Band

/// Where a 40 MHz channel's secondary 20 MHz half sits relative to the primary (HT "40+" / "40−").
public enum SecondaryChannel: Sendable, Hashable {
    case above, below
}

/// The frequency range a transmission occupies.
public struct ChannelSpan: Sendable, Hashable {
    /// Center frequency in MHz.
    public var center: Double
    /// Width in MHz.
    public var width: Int

    public init(center: Double, width: Int) {
        self.center = center
        self.width = width
    }

    public var lower: Double { center - Double(width) / 2 }
    public var upper: Double { center + Double(width) / 2 }

    /// MHz shared with `other` (0 when they don't touch).
    public func overlap(with other: ChannelSpan) -> Double {
        max(0, min(upper, other.upper) - max(lower, other.lower))
    }

    /// Share of *this* span covered by `other`, 0...1.
    public func overlapFraction(with other: ChannelSpan) -> Double {
        width > 0 ? overlap(with: other) / Double(width) : 0
    }

    public func overlaps(_ other: ChannelSpan) -> Bool { overlap(with: other) > 0 }
}

/// Channel plans of the 2.4, 5 and 6 GHz bands: channel ↔ frequency, bonding of wide channels,
/// DFS and preferred scanning channels. Channel numbers step 5 MHz in every band.
public enum WiFiChannels {
    // MARK: Channel ↔ frequency

    /// Center frequency (MHz) of a 20 MHz channel number, nil when it isn't a channel of `band`.
    public static func frequency(channel: Int, band: WiFiBand) -> Int? {
        switch band {
        case .ghz2:
            if channel == 14 { return 2484 }
            return (1...13).contains(channel) ? 2407 + 5 * channel : nil
        case .ghz5:
            return isFiveGHzChannel(channel) ? 5000 + 5 * channel : nil
        case .ghz6:
            if channel == 2 { return 5935 }
            return (1...233).contains(channel) && channel % 4 == 1 ? 5950 + 5 * channel : nil
        case .unknown:
            return nil
        }
    }

    /// Center frequency of a (possibly bonded) center channel number; unlike `frequency(channel:)`
    /// this accepts the odd center numbers of wide 6 GHz channels (3, 7, 15, 31…).
    public static func centerFrequency(channel: Int, band: WiFiBand) -> Double? {
        switch band {
        case .ghz2:
            if channel == 14 { return 2484 }
            return (1...13).contains(channel) ? Double(2407 + 5 * channel) : nil
        case .ghz5: return (32...177).contains(channel) ? Double(5000 + 5 * channel) : nil
        case .ghz6: return (1...233).contains(channel) ? Double(5950 + 5 * channel) : nil
        case .unknown: return nil
        }
    }

    /// The 20 MHz channel and band at a center frequency (MHz).
    public static func channel(frequency f: Int) -> (channel: Int, band: WiFiBand)? {
        switch f {
        case 2484: return (14, .ghz2)
        case 2412...2472 where (f - 2407) % 5 == 0: return ((f - 2407) / 5, .ghz2)
        case 5935: return (2, .ghz6)
        case 5160...5885 where f % 5 == 0 && isFiveGHzChannel((f - 5000) / 5): return ((f - 5000) / 5, .ghz5)
        case 5955...7115 where (f - 5950) % 20 == 5: return ((f - 5950) / 5, .ghz6)
        default: return nil
        }
    }

    /// Valid 20 MHz (primary) channels of a band, ascending.
    public static func channels(in band: WiFiBand) -> [Int] {
        switch band {
        case .ghz2: Array(1...14)
        case .ghz5: fiveGHzSegments.flatMap { Array(stride(from: $0.lowerBound, through: $0.upperBound, by: 4)) }
        case .ghz6: Array(stride(from: 1, through: 233, by: 4))
        case .unknown: []
        }
    }

    /// 20 MHz 5 GHz channels: 32–144 in steps of 4, then 149–177.
    private static func isFiveGHzChannel(_ c: Int) -> Bool {
        ((32...144).contains(c) && c % 4 == 0) || ((149...177).contains(c) && (c - 149) % 4 == 0)
    }

    /// 5 GHz channel runs that bond into wider channels (UNII-1/2A, UNII-2C, UNII-3/4).
    private static let fiveGHzSegments: [ClosedRange<Int>] = [36...64, 100...144, 149...177]

    // MARK: DFS / PSC

    /// 5 GHz channels that need radar detection (UNII-2A and UNII-2C).
    public static func isDFS(channel: Int, band: WiFiBand) -> Bool {
        band == .ghz5 && (52...144).contains(channel)
    }

    /// True when any 20 MHz subchannel inside `span` is a DFS channel.
    public static func touchesDFS(_ span: ChannelSpan, band: WiFiBand) -> Bool {
        band == .ghz5 && subchannels(of: span, band: band).contains { isDFS(channel: $0, band: band) }
    }

    /// 6 GHz Preferred Scanning Channels (5, 21, 37, … 229): where 6 GHz-only APs are found fastest.
    public static func isPSC(channel: Int, band: WiFiBand) -> Bool {
        band == .ghz6 && (5...229).contains(channel) && (channel - 5) % 16 == 0
    }

    /// The 20 MHz channels covered by `span`.
    public static func subchannels(of span: ChannelSpan, band: WiFiBand) -> [Int] {
        channels(in: band).filter { ch in
            guard let f = frequency(channel: ch, band: band) else { return false }
            return Double(f) > span.lower && Double(f) < span.upper
        }
    }

    // MARK: Bonding

    /// Center channel number of a `width` MHz channel whose primary 20 MHz channel is `primary`.
    ///
    /// 2.4 GHz: 40 MHz uses `secondary` (above → +2, below → −2); without it, channels 1–7 assume
    /// "above" and 8–13 "below", flipped when the chosen side would leave the band.
    /// 5/6 GHz: wide channels are fixed blocks, so the primary alone determines the center.
    /// Returns nil when the width doesn't exist at that primary (e.g. 160 MHz on channel 140,
    /// whose block would run past channel 144; on channel 149 it fits).
    public static func centerChannel(
        primary: Int, width: Int, band: WiFiBand,
        secondary: SecondaryChannel? = nil
    ) -> Int? {
        guard frequency(channel: primary, band: band) != nil else { return nil }
        if width == 20 { return primary }
        switch band {
        case .ghz2:
            guard width == 40, primary <= 13 else { return nil }
            var side = secondary ?? (primary <= 7 ? .above : .below)
            if side == .above, primary + 4 > 13 { side = .below }
            if side == .below, primary - 4 < 1 { side = .above }
            return side == .above ? primary + 2 : primary - 2
        case .ghz5:
            guard [40, 80, 160].contains(width),
                let segment = fiveGHzSegments.first(where: { $0.contains(primary) })
            else { return nil }
            return blockCenter(primary: primary, start: segment.lowerBound, end: segment.upperBound, width: width)
        case .ghz6:
            guard [40, 80, 160, 320].contains(width) else { return nil }
            return blockCenter(primary: primary, start: 1, end: 233, width: width)
        case .unknown:
            return nil
        }
    }

    /// Fixed-block bonding: blocks of `width/20` channels laid out from `start`.
    private static func blockCenter(primary: Int, start: Int, end: Int, width: Int) -> Int? {
        let n = width / 20
        let offset = primary - start
        guard offset >= 0, offset % 4 == 0 else { return nil }
        let first = start + (offset / 4) / n * n * 4
        let last = first + 4 * (n - 1)
        guard last <= end else { return nil }
        return first + 2 * (n - 1)
    }

    /// Frequency span of a channel; nil when the channel/width combination is invalid.
    public static func span(
        primary: Int, width: Int, band: WiFiBand,
        secondary: SecondaryChannel? = nil
    ) -> ChannelSpan? {
        guard let c = centerChannel(primary: primary, width: width, band: band, secondary: secondary),
            let f = centerFrequency(channel: c, band: band)
        else { return nil }
        return ChannelSpan(center: f, width: width)
    }

    // MARK: Axis layout

    /// Frequency runs drawn on a band's channel graph; 5 GHz skips the unused 5350–5470 MHz gap.
    public static func axisSegments(_ band: WiFiBand) -> [ClosedRange<Double>] {
        switch band {
        case .ghz2: [2399...2497]
        case .ghz5: [5165...5335, 5485...5900]
        case .ghz6: [5940...7130]
        case .unknown: []
        }
    }

    /// Named sub-bands (frequency ranges in MHz).
    public static func subBands(_ band: WiFiBand) -> [(name: String, range: ClosedRange<Double>)] {
        switch band {
        case .ghz5:
            [
                ("UNII-1", 5170...5250), ("UNII-2A", 5250...5330), ("UNII-2C", 5490...5730),
                ("UNII-3", 5735...5835), ("UNII-4", 5835...5895),
            ]
        case .ghz6:
            [("UNII-5", 5925...6425), ("UNII-6", 6425...6525), ("UNII-7", 6525...6875), ("UNII-8", 6875...7125)]
        default: []
        }
    }
}

/// Maps frequencies to 0...1 positions along a band's graph, with fixed-size gaps between segments.
public struct BandAxis: Sendable {
    public let segments: [ClosedRange<Double>]
    /// Width of each gap as a fraction of the whole axis.
    public let gapFraction: Double

    public init(segments: [ClosedRange<Double>], gapFraction: Double = 0.025) {
        self.segments = segments
        self.gapFraction = segments.count > 1 ? gapFraction : 0
    }

    public init(band: WiFiBand) {
        self.init(segments: WiFiChannels.axisSegments(band))
    }

    private var totalMHz: Double { segments.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) } }
    private var scale: Double {
        let gaps = Double(max(segments.count - 1, 0)) * gapFraction
        return totalMHz > 0 ? (1 - gaps) / totalMHz : 0
    }

    /// 0...1 position of a frequency; values outside every segment clamp to the nearest edge.
    public func position(of f: Double) -> Double {
        guard let first = segments.first else { return 0 }
        if f <= first.lowerBound { return 0 }
        var x = 0.0
        for (i, s) in segments.enumerated() {
            if f <= s.upperBound {
                return x + max(0, f - s.lowerBound) * scale
            }
            x += (s.upperBound - s.lowerBound) * scale
            if i < segments.count - 1 {
                // In the gap: snap to the nearer side.
                let next = segments[i + 1]
                if f < next.lowerBound {
                    return f - s.upperBound < next.lowerBound - f ? x : x + gapFraction
                }
                x += gapFraction
            }
        }
        return 1
    }

    /// Frequency at a 0...1 position, nil inside a gap.
    public func frequency(at p: Double) -> Double? {
        var x = 0.0
        for (i, s) in segments.enumerated() {
            let w = (s.upperBound - s.lowerBound) * scale
            if p <= x + w { return p < x ? nil : s.lowerBound + (p - x) / scale }
            x += w
            if i < segments.count - 1 { x += gapFraction }
        }
        return nil
    }

    /// 0...1 ranges of the gaps between segments.
    public var gaps: [ClosedRange<Double>] {
        guard segments.count > 1 else { return [] }
        return segments.dropLast().map { s in
            let x = position(of: s.upperBound)
            return x...(x + gapFraction)
        }
    }
}
