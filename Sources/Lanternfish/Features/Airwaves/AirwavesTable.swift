import LanternfishKit
import SwiftUI

/// A table row: one BSS, or (when grouping) all access points of one network name.
private struct WiFiRow: Identifiable, Hashable {
    let id: String
    /// The BSS shown in the row (a group's strongest member).
    let network: WiFiScanResult
    /// Group members (nil for plain rows).
    var children: [WiFiRow]?
    var memberIDs: Set<String>

    init(_ r: WiFiScanResult) {
        id = r.id
        network = r
        memberIDs = [r.id]
    }

    init(group: WiFiNetworkGroup) {
        id = group.id
        network = group.strongest
        children = group.members.map(WiFiRow.init)
        memberIDs = Set(group.members.map(\.id))
    }

    var isGroup: Bool { children != nil }
    var members: [WiFiScanResult] { children?.map(\.network) ?? [network] }

    // Sort keys (non-optional so KeyPathComparator works).
    var name: String { network.displayName.lowercased() }
    var rssi: Int { network.rssi }
    var bssid: String { network.bssid ?? "~" }
    var brand: String { AirwavesFormat.brand(network) ?? "~" }
    var noise: Int { network.noise ?? -200 }
    var channel: Int { network.band.rawValue * 1000 + network.channel }
    var band: Int { network.band.rawValue }
    var width: Int { network.width }
    var security: String { network.security.label }
    var standard: Int { network.standard?.rawValue ?? 0 }
    var beacon: Int { network.beaconInterval ?? 0 }
    var country: String { network.countryCode ?? "~" }
}

struct WiFiNetworkTable: View {
    let results: [WiFiScanResult]
    let currentID: String?
    let currentSSID: String?
    let groupByName: Bool
    @Binding var hover: WiFiHover?
    @Binding var selection: String?
    @State private var sortOrder = [KeyPathComparator(\WiFiRow.rssi, order: .reverse)]

    private var rows: [WiFiRow] {
        var rows: [WiFiRow]
        if groupByName {
            rows = WiFiNetworkGroup.group(results).map { g in
                g.members.count == 1 ? WiFiRow(g.members[0]) : WiFiRow(group: g)
            }
        } else {
            rows = results.map(WiFiRow.init)
        }
        rows.sort(using: sortOrder)
        for i in rows.indices where rows[i].children != nil {
            rows[i].children?.sort(using: sortOrder)
        }
        return rows
    }

    var body: some View {
        Table(rows, children: \.children, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { row in
                cell(row) { NameCell(row: row, isCurrent: row.memberIDs.contains(currentID ?? "-"), tint: tint(row)) }
            }
            .width(min: 150, ideal: 210)
            TableColumn("Signal", value: \.rssi) { row in
                cell(row) { SignalCell(r: row.network) }
            }
            .width(min: 150, ideal: 176)
            TableColumn("Channel", value: \.channel) { row in
                cell(row) {
                    if row.isGroup {
                        Text(row.members.map { "\($0.channel)" }.joined(separator: ", "))
                            .foregroundStyle(.secondary)
                    } else {
                        ChannelCell(r: row.network)
                    }
                }
            }
            .width(min: 64, ideal: 104)
            TableColumn("Band", value: \.band) { row in
                cell(row) {
                    Text(row.isGroup ? Self.bands(row.members) : row.network.band.label)
                        .foregroundStyle(row.isGroup ? .secondary : .primary)
                }
            }
            .width(min: 50, ideal: 76)
            TableColumn("Width", value: \.width) { row in
                cell(row) {
                    if !row.isGroup { Text(AirwavesFormat.width(row.network.width)).monospacedDigit() }
                }
            }
            .width(min: 50, ideal: 62)
            TableColumn("Security", value: \.security) { row in
                cell(row) { SecurityCell(security: row.network.security) }
            }
            .width(min: 80, ideal: 110)
            TableColumn("BSSID", value: \.bssid) { row in
                cell(row) {
                    if row.isGroup {
                        Text("\(row.members.count) access points").foregroundStyle(.secondary)
                    } else if let b = row.network.bssid {
                        Text(b.uppercased()).font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
                    } else {
                        Text("Hidden by macOS").foregroundStyle(.tertiary)
                    }
                }
            }
            .width(min: 110, ideal: 150)
            TableColumn("Brand", value: \.brand) { row in
                cell(row) {
                    if let b = AirwavesFormat.brand(row.network) {
                        Text(b)
                    } else {
                        Text("—").foregroundStyle(.tertiary)
                            .help(
                                row.network.isLocallyAdministered
                                    ? "Private (locally administered) BSSID" : "Unknown manufacturer")
                    }
                }
            }
            .width(min: 60, ideal: 96)
            TableColumn("Standard", value: \.standard) { row in
                cell(row) {
                    if let s = row.network.standard {
                        HStack(spacing: 4) {
                            Text(s.name)
                            if let g = s.generation { Text(g).foregroundStyle(.secondary) }
                        }
                    } else {
                        Text("—").foregroundStyle(.tertiary)
                    }
                }
            }
            .width(min: 70, ideal: 130)
            Group {
                TableColumn("Noise", value: \.noise) { row in
                    cell(row) { optional(row.network.noise.map { "\($0) dBm" }) }
                }
                .width(min: 50, ideal: 70)
                TableColumn("Beacon", value: \.beacon) { row in
                    cell(row) { optional(AirwavesFormat.beacon(row.network.beaconInterval)) }
                }
                .width(min: 50, ideal: 64)
                TableColumn("Country", value: \.country) { row in
                    cell(row) { optional(row.network.countryCode) }
                }
                .width(min: 44, ideal: 56)
            }
        }
        .animation(.default, value: groupByName)
    }

    private func tint(_ row: WiFiRow) -> Color {
        AirwavesFormat.color(for: row.network, currentID: currentID, currentSSID: currentSSID)
    }

    @ViewBuilder
    private func optional(_ s: String?) -> some View {
        if let s { Text(s).monospacedDigit() } else { Text("—").foregroundStyle(.tertiary) }
    }

    /// Wraps a cell: dims rows that aren't the hovered hill, and reports row hover to the graph.
    private func cell<C: View>(_ row: WiFiRow, @ViewBuilder _ content: () -> C) -> some View {
        let dim = hover.map { $0.fromGraph && !row.memberIDs.contains($0.id) } ?? false
        return content()
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .opacity(dim ? 0.38 : 1)
            .onHover { inside in
                if inside {
                    hover = WiFiHover(id: row.network.id, fromGraph: false)
                } else if hover?.id == row.network.id, hover?.fromGraph == false {
                    hover = nil
                }
            }
    }

    private static func bands(_ members: [WiFiScanResult]) -> String {
        let set = Set(members.map(\.band)).sorted { $0.rawValue < $1.rawValue }
        return set.map { $0.label.replacingOccurrences(of: " GHz", with: "") }.joined(separator: "/") + " GHz"
    }
}

private struct NameCell: View {
    let row: WiFiRow
    let isCurrent: Bool
    let tint: Color

    var body: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                .fill(tint)
                .frame(width: 10, height: 10)
            Text(row.network.displayName)
                .fontWeight(isCurrent ? .semibold : .regular)
                .italic(row.network.ssid == nil)
                .foregroundStyle(row.network.ssid == nil ? .secondary : .primary)
                .truncationMode(.tail)
            if isCurrent { WiFiYouBadge() }
            if row.isGroup {
                Text("\(row.members.count)")
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(.quaternary))
                    .help("\(row.members.count) access points share this name")
            }
        }
    }
}

private struct SignalCell: View {
    let r: WiFiScanResult

    var body: some View {
        let q = r.quality
        HStack(spacing: 6) {
            SignalMeter(rssi: r.rssi, tint: OverviewFormat.color(q))
            Text("\(r.rssi) dBm")
                .monospacedDigit()
                .frame(width: 58, alignment: .trailing)
            Text(q.label)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A short horizontal bar on `AirwavesFormat.signalRange`.
struct SignalMeter: View {
    let rssi: Int
    let tint: Color
    var width: CGFloat = 34

    var body: some View {
        let f = AirwavesFormat.signalFraction(Double(rssi), minimum: 0.03)
        ZStack(alignment: .leading) {
            Capsule().fill(.quaternary)
            Capsule().fill(tint.gradient).frame(width: width * f)
        }
        .frame(width: width, height: 5)
        .animation(.smooth, value: rssi)
    }
}

private struct ChannelCell: View {
    let r: WiFiScanResult

    var body: some View {
        HStack(spacing: 4) {
            Text("\(r.channel)").monospacedDigit()
            if r.width > 20, r.centerChannel != r.channel {
                Text("(\(r.centerChannel))").foregroundStyle(.secondary).monospacedDigit()
                    .help("Center channel of the \(r.width) MHz channel")
            }
            if r.isDFS {
                Text("DFS")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(.orange)
                    .help("Shares radar frequencies: the router must leave this channel if it detects radar")
            }
        }
    }
}

private struct SecurityCell: View {
    let security: WiFiSecurity

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: security == .open || security == .owe ? "lock.open" : "lock.fill")
                .font(.caption)
                .foregroundStyle(security.isWeak ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
            Text(security.label)
                .foregroundStyle(security.isWeak ? AnyShapeStyle(.orange) : AnyShapeStyle(.primary))
        }
    }
}
