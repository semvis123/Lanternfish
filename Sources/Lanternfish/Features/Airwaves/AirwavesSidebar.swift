import Charts
import LanternfishKit
import SwiftUI

/// Inspector: your connection, channel advice for the shown band, and the selected network's
/// signal over the last five minutes.
struct AirwavesSidebar: View {
    let model: AirwavesModel
    let band: WiFiBand
    let selection: String?

    private var routerBrand: String? {
        let own = model.ownID(in: band).flatMap { id in model.results.first { $0.id == id } } ?? model.current
        return own.flatMap(AirwavesFormat.brand)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                WiFiConnectionCard(model: model)
                WiFiAdviceCard(advice: model.advice(for: band), router: routerBrand)
                WiFiHistoryCard(model: model, selection: selection)
            }
            .padding(12)
        }
        .scrollBounceBehavior(.basedOnSize)
        .environment(\.cardsOnGlass, true)
    }
}

// MARK: - Connection

private struct WiFiConnectionCard: View {
    let model: AirwavesModel

    var body: some View {
        let wifi = model.connection
        OverviewCard(title: "Your Connection", symbol: "wifi", tint: .blue) {
            if let q = wifi?.quality, wifi?.isAssociated == true {
                WiFiQualityBadge(quality: q)
            }
        } content: {
            if let wifi {
                if !wifi.powerOn {
                    message("Wi-Fi is turned off")
                } else if !wifi.isAssociated {
                    message("Not connected to a Wi-Fi network")
                } else {
                    rows(wifi)
                }
            } else {
                message("No Wi-Fi interface")
            }
        }
    }

    private func message(_ s: String) -> some View {
        Text(s).foregroundStyle(.secondary).font(.callout).padding(.vertical, 8)
    }

    @ViewBuilder
    private func rows(_ w: WiFiInfo) -> some View {
        let scan = model.current
        OverviewRow(label: "Network") { ssid(w) }
        if let b = w.bssid ?? scan?.bssid {
            OverviewRow(label: "BSSID") {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(b.uppercased()).font(.callout.monospaced())
                    if let brand = scan.flatMap(AirwavesFormat.brand) {
                        Text(brand).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        OverviewRow("Channel", channel(w, scan: scan))
        OverviewRow(label: "Signal") {
            if let rssi = w.rssi {
                HStack(spacing: 6) {
                    SignalMeter(rssi: rssi, tint: OverviewFormat.color(w.quality ?? .poor))
                    Text("\(rssi) dBm").monospacedDigit()
                }
            } else {
                Text("—").foregroundStyle(.tertiary)
            }
        }
        OverviewRow("Noise", w.noise.map { "\($0) dBm" }, monospaced: true)
        OverviewRow(label: "SNR") {
            if let snr = w.snr {
                let word = Text(" · \(Self.snrWord(snr))").foregroundStyle(.secondary)
                Text("\(snr) dB\(word)").monospacedDigit()
            } else {
                Text("—").foregroundStyle(.tertiary)
            }
        }
        OverviewRow("Tx Rate", OverviewFormat.txRate(w.txRate), monospaced: true)
        OverviewRow("Standard", w.phyMode)
        OverviewRow("Security", w.security, divider: false)
    }

    @ViewBuilder
    private func ssid(_ w: WiFiInfo) -> some View {
        if let s = w.ssid {
            Text(s).fontWeight(.medium)
        } else if model.location.state == .authorized {
            Text("Hidden").foregroundStyle(.tertiary)
        } else {
            Button(model.location.requestTitle) {
                model.location.request()
            }
            .controlSize(.small)
            .help("macOS shows the Wi-Fi name only to apps allowed to use Location Services")
        }
    }

    private func channel(_ w: WiFiInfo, scan: WiFiScanResult?) -> String? {
        guard let ch = w.channel else { return nil }
        var first = "\(ch)"
        if let scan, scan.width > 20, scan.centerChannel != ch { first += " (\(scan.centerChannel))" }
        var parts = [first, w.band.label]
        if let width = w.channelWidth ?? scan?.width { parts.append("\(width) MHz") }
        return parts.joined(separator: " · ")
    }

    static func snrWord(_ snr: Int) -> String {
        switch snr {
        case 40...: "Excellent"
        case 25..<40: "Good"
        case 15..<25: "Fair"
        default: "Poor"
        }
    }
}

// MARK: - Channel advice

private struct WiFiAdviceCard: View {
    let advice: ChannelAdvice
    let router: String?

    /// Rows to list: all candidates when few, else the quietest six, plus your channel.
    private var shown: [ChannelCandidate] {
        var list = advice.candidates
        if list.count > 7 {
            let quiet = list.sorted { ($0.score, $0.channel) < ($1.score, $1.channel) }.prefix(6)
            list = list.filter { c in quiet.contains(c) || advice.isCurrent(c) }
        }
        if let cur = advice.current, !list.contains(where: { $0.span == cur.span }) {
            list.append(cur)
            list.sort { $0.span.center < $1.span.center }
        }
        return list
    }

    var body: some View {
        OverviewCard(title: "Channel Advice", symbol: "dial.medium", tint: .orange) {
            Text(advice.band.label).font(.caption).foregroundStyle(.secondary)
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                Text(advice.summary(router: router))
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                if advice.networkCount > 0 || advice.current != nil {
                    VStack(spacing: 6) {
                        ForEach(shown) { c in
                            CandidateRow(
                                c: c, band: advice.band, isCurrent: advice.isCurrent(c),
                                isBest: c.span == advice.best?.span && advice.best != nil)
                        }
                    }
                }
                Text(footnote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 8)
        }
    }

    private var footnote: String {
        var s = "Bars show the combined signal of networks overlapping each \(advice.width) MHz channel"
        switch advice.band {
        case .ghz2: s += " (1, 6 and 11 don't overlap each other)"
        case .ghz5: s += "; DFS channels count extra because radar can force a switch"
        case .ghz6: s += "; only preferred scanning channels are suggested"
        default: break
        }
        s += ". This Mac hears how loud neighbours are, not how busy they are — channels change on the router."
        return s
    }
}

private struct CandidateRow: View {
    let c: ChannelCandidate
    let band: WiFiBand
    let isCurrent: Bool
    let isBest: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.callout.monospacedDigit().weight(isCurrent || isBest ? .semibold : .regular))
                .frame(width: 58, alignment: .leading)
            LevelBar(level: c.level)
            Text(c.level.map { String(format: "%.0f dBm", $0) } ?? "Clear")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)
            HStack(spacing: 3) {
                if isCurrent { Badge("Now", .accentColor) }
                if isBest { Badge("Best", .green) }
                if c.isDFS { Badge("DFS", .orange) }
            }
            .frame(width: 70, alignment: .leading)
        }
        .help(
            "\(c.overlapping == 1 ? "1 overlapping network" : "\(c.overlapping) overlapping networks")"
                + (c.strongestRSSI.map { ", strongest \($0) dBm" } ?? ""))
    }

    private var label: String {
        let subs = WiFiChannels.subchannels(of: c.span, band: band)
        if c.span.width > 20, let a = subs.first, let b = subs.last, a != b { return "\(a)–\(b)" }
        return "Ch \(c.channel)"
    }
}

private struct LevelBar: View {
    let level: Double?

    var body: some View {
        GeometryReader { geo in
            let f = level.map { AirwavesFormat.signalFraction($0, minimum: 0.04) } ?? 0
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(color.gradient).frame(width: max(geo.size.width * f, f > 0 ? 5 : 0))
            }
        }
        .frame(height: 6)
        .animation(.smooth, value: level)
    }

    private var color: Color {
        guard let level else { return .green }
        return level < -80 ? .green : level < -67 ? .yellow : level < -55 ? .orange : .red
    }
}

private struct Badge: View {
    let text: String
    let color: Color
    init(_ text: String, _ color: Color) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(color)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(color.opacity(0.14), in: Capsule())
            .fixedSize()
    }
}

// MARK: - Signal history

private struct WiFiHistoryCard: View {
    let model: AirwavesModel
    let selection: String?

    /// Selected row's networks (a group selects all its members), else your network.
    private var targets: [WiFiScanResult] {
        if let selection {
            if selection.hasPrefix("ssid:") {
                let name = String(selection.dropFirst(5))
                return model.results.filter { $0.ssid == name }.sorted { $0.rssi > $1.rssi }
            }
            if let r = model.results.first(where: { $0.id == selection }) { return [r] }
        }
        return model.current.map { [$0] } ?? []
    }

    var body: some View {
        let targets = targets
        OverviewCard(title: "Signal History", symbol: "waveform.path.ecg", tint: .green) {
            Text("Last 5 min").font(.caption).foregroundStyle(.secondary)
        } content: {
            if let first = targets.first {
                VStack(alignment: .leading, spacing: 8) {
                    header(first, count: targets.count)
                    SignalHistoryChart(
                        series: targets.prefix(4).map { r in
                            SignalSeries(
                                id: r.id, name: seriesName(r, multiple: targets.count > 1),
                                samples: model.history.samples(for: r.id))
                        }
                    )
                    .frame(height: 120)
                    stats(model.history.samples(for: first.id))
                    if targets.count == 1 { details(first) }
                }
                .padding(.vertical, 8)
            } else {
                Text("Select a network to see its signal over the last five minutes.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 8)
            }
        }
    }

    private func seriesName(_ r: WiFiScanResult, multiple: Bool) -> String {
        guard multiple else { return r.displayName }
        return "\(r.band.label) · ch \(r.channel)"
    }

    private func header(_ r: WiFiScanResult, count: Int) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 1) {
                Text(r.displayName).font(.headline).lineLimit(1)
                Text(count > 1 ? "\(count) access points" : "\(r.band.label) · channel \(r.channelLabel)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text("\(r.rssi)")
                    .font(.system(size: 22, weight: .semibold, design: .rounded).monospacedDigit())
                    .contentTransition(.numericText(value: Double(r.rssi)))
                    .animation(.smooth, value: r.rssi)
                Text("dBm").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func stats(_ samples: [WiFiSignalHistory.Sample]) -> some View {
        let values = samples.map(\.rssi)
        if let lo = values.min(), let hi = values.max() {
            let avg = Double(values.reduce(0, +)) / Double(values.count)
            HStack {
                stat("Min", "\(lo)")
                stat("Avg", String(format: "%.0f", avg))
                stat("Max", "\(hi)")
                stat("Samples", "\(values.count)")
            }
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.callout.monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func details(_ r: WiFiScanResult) -> some View {
        VStack(spacing: 0) {
            Divider().opacity(0.6)
            OverviewRow("Frequencies", "\(Int(r.span.lower))–\(Int(r.span.upper)) MHz", monospaced: true)
            OverviewRow("Width", "\(r.width) MHz" + (r.isDFS ? " · DFS" : ""))
            OverviewRow("Security", r.security.label)
            OverviewRow(
                "Brand", AirwavesFormat.brand(r) ?? (r.isLocallyAdministered ? "Private address" : nil),
                divider: false)
        }
    }
}

private struct SignalSeries: Identifiable {
    let id: String
    let name: String
    let samples: [WiFiSignalHistory.Sample]
}

/// RSSI over `AirwavesModel.historyWindow`, on `AirwavesFormat.signalRange`.
private struct SignalHistoryChart: View {
    let series: [SignalSeries]

    var body: some View {
        let now = Date()
        let single = series.count == 1
        let floor = Int(AirwavesFormat.signalRange.lowerBound)
        let ceiling = Int(AirwavesFormat.signalRange.upperBound)
        Chart {
            ForEach(series) { s in
                ForEach(s.samples, id: \.date) { p in
                    if single {
                        AreaMark(
                            x: .value("Time", p.date), yStart: .value("Floor", floor), yEnd: .value("Signal", p.rssi)
                        )
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.accentColor.opacity(0.28), .accentColor.opacity(0.02)],
                                startPoint: .top, endPoint: .bottom)
                        )
                        .interpolationMethod(.monotone)
                    }
                    LineMark(x: .value("Time", p.date), y: .value("Signal", p.rssi))
                        .foregroundStyle(by: .value("Access point", s.name))
                        .interpolationMethod(.monotone)
                        .lineStyle(StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                    if s.samples.count == 1 {
                        PointMark(x: .value("Time", p.date), y: .value("Signal", p.rssi))
                            .foregroundStyle(by: .value("Access point", s.name))
                            .symbolSize(24)
                    }
                }
            }
        }
        .chartForegroundStyleScale(range: single ? [Color.accentColor] : [.accentColor, .orange, .green, .pink])
        .chartLegend(single ? .hidden : .visible)
        .chartLegend(position: .bottom, spacing: 6)
        .chartXScale(domain: now.addingTimeInterval(-AirwavesModel.historyWindow)...now)
        .chartYScale(domain: floor...ceiling)
        .chartYAxis {
            AxisMarks(position: .leading, values: [-90, -70, -50, -30]) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                AxisValueLabel()
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .minute)) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
            }
        }
        .chartPlotStyle { $0.padding(.bottom, 2) }
        .overlay(alignment: .bottom) {
            HStack {
                Text("5 min ago")
                Spacer()
                Text("now")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.leading, 30)
            .offset(y: 14)
        }
        .padding(.bottom, 14)
    }
}
