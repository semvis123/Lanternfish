import LanternfishKit
import SwiftUI

// MARK: - Internet

struct OverviewInternetSection: View {
    let model: OverviewModel

    var body: some View {
        OverviewCard(title: "Internet", symbol: "globe", tint: .blue) {
            status
        } content: {
            let info = model.internet
            OverviewRow("Public IPv4", info?.ipv4 ?? placeholder, monospaced: true)
            if let v6 = info?.ipv6 {
                OverviewRow("Public IPv6", v6, monospaced: true)
            }
            OverviewRow("Provider", provider(info))
            OverviewRow("Location", location(info))
            OverviewRow(label: "Latency to 1.1.1.1") {
                latency
            }
            HStack {
                if let colo = info?.colo {
                    Text("Cloudflare edge \(colo)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Button {
                    Router.shared.showOverview = false
                    Router.shared.traceroute = TracerouteTarget(host: "1.1.1.1")
                } label: {
                    Label("Traceroute to 1.1.1.1", systemImage: "point.3.connected.trianglepath.dotted")
                }
                .controlSize(.small)
            }
            .padding(.vertical, 6)
        }
    }

    private var placeholder: String? {
        model.isLoadingInternet ? "Loading…" : nil
    }

    @ViewBuilder private var status: some View {
        switch model.isOnline {
        case true?: StatusPill(text: "Online", color: .green).font(.caption)
        case false?: StatusPill(text: "Offline", color: .red).font(.caption)
        case nil:
            ProgressView().controlSize(.mini)
        }
    }

    @ViewBuilder private var latency: some View {
        if model.isPinging {
            Text("Measuring…").foregroundStyle(.secondary)
        } else if let ms = model.latencyMs {
            let lost = model.pings.filter { $0 == nil }.count
            HStack(spacing: 4) {
                Text(OverviewFormat.ms(ms)).monospacedDigit()
                if lost > 0 {
                    Text("· \(lost)/\(model.pings.count) lost").foregroundStyle(.orange)
                }
            }
        } else if !model.pings.isEmpty {
            Text("No reply").foregroundStyle(.red)
        } else {
            Text("—").foregroundStyle(.tertiary)
        }
    }

    private func provider(_ info: InternetInfo?) -> String? {
        guard let info else { return placeholder }
        switch (info.organization, info.asn) {
        case (let org?, let asn?): return "\(org) (AS\(asn))"
        case (let org?, nil): return org
        case (nil, let asn?): return "AS\(asn)"
        default: return nil
        }
    }

    private func location(_ info: InternetInfo?) -> String? {
        guard let info else { return placeholder }
        let country = info.country.map { Locale.current.localizedString(forRegionCode: $0) ?? $0 }
        let parts = [info.city, country].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}

// MARK: - Local network

struct OverviewLocalSection: View {
    let model: OverviewModel
    let interface: NetworkInterfaceInfo?
    let gatewayDevice: Device?

    var body: some View {
        OverviewCard(title: "Local Network", symbol: "network", tint: .indigo) {
            if let link = model.link {
                Text(link.medium.label).font(.caption).foregroundStyle(.secondary)
            }
        } content: {
            if let interface {
                OverviewRow("Interface", "\(interface.displayName) (\(interface.name))")
                OverviewRow("IP Address", interface.address.description, monospaced: true)
                OverviewRow("Subnet", interface.subnet.description, monospaced: true)
                OverviewRow(label: "Router") { router(interface) }
                OverviewRow(label: "DNS") { dns }
                if !model.dns.searchDomains.isEmpty {
                    OverviewRow("Search Domains", model.dns.searchDomains.joined(separator: ", "))
                }
                OverviewRow(label: "IPv6") { ipv6 }
                OverviewRow(
                    "MTU", model.link?.mtu.map(String.init),
                    divider: model.link?.linkSpeed != nil && model.link?.medium == .ethernet,
                    monospaced: true)
                if let speed = model.link?.linkSpeed, model.link?.medium == .ethernet {
                    OverviewRow("Link Speed", LinkInfo.formatSpeed(speed), divider: false)
                }
            } else {
                Text("Not connected to a network")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            }
        }
    }

    @ViewBuilder private func router(_ interface: NetworkInterfaceInfo) -> some View {
        if let gw = interface.gateway {
            VStack(alignment: .trailing, spacing: 1) {
                Text(gw.description).monospacedDigit()
                if let d = gatewayDevice {
                    let name = d.hasRealName ? d.displayName : nil
                    let brand = d.brandModel == name ? nil : d.brandModel
                    let detail = [name, brand].compactMap { $0 }
                    if !detail.isEmpty {
                        Text(detail.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } else {
            Text("None").foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder private var dns: some View {
        let servers = model.dns.servers
        if servers.isEmpty {
            Text("—").foregroundStyle(.tertiary)
        } else {
            VStack(alignment: .trailing, spacing: 1) {
                ForEach(servers, id: \.self) { s in
                    HStack(spacing: 4) {
                        if let gw = interface?.gateway, IPv4Address(s) == gw {
                            Text("Router").font(.caption).foregroundStyle(.secondary)
                        } else if let name = DNSConfiguration.publicResolverName(s) {
                            Text(name).font(.caption).foregroundStyle(.secondary)
                        }
                        Text(s).monospacedDigit()
                    }
                }
            }
        }
    }

    @ViewBuilder private var ipv6: some View {
        if let link = model.link {
            VStack(alignment: .trailing, spacing: 1) {
                Text(link.ipv6Status)
                    .foregroundStyle(link.ipv6Addresses.isEmpty ? .secondary : .primary)
                ForEach(link.ipv6Addresses.prefix(2), id: \.self) { a in
                    Text(a).font(.caption.monospaced()).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
        } else {
            Text("—").foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Wi-Fi

struct OverviewWiFiSection: View {
    let model: OverviewModel
    let wifi: WiFiInfo

    var body: some View {
        OverviewCard(title: "Wi-Fi", symbol: "wifi", tint: .teal) {
            if let q = wifi.quality {
                WiFiQualityBadge(quality: q)
            }
        } content: {
            if !wifi.powerOn {
                Text("Wi-Fi is turned off").foregroundStyle(.secondary).padding(.vertical, 8)
            } else if !wifi.isAssociated {
                Text("Not connected to a Wi-Fi network").foregroundStyle(.secondary).padding(.vertical, 8)
            } else {
                OverviewRow(label: "Network") { ssid }
                if let bssid = wifi.bssid {
                    OverviewRow("BSSID", bssid.uppercased(), monospaced: true)
                }
                OverviewRow("Channel", channel)
                OverviewRow(label: "Signal") { signal }
                OverviewRow("Tx Rate", OverviewFormat.txRate(wifi.txRate), monospaced: true)
                OverviewRow("Security", wifi.security)
                OverviewRow("PHY Mode", wifi.phyMode)
                OverviewRow("Country", wifi.countryCode, divider: false)
            }
        }
    }

    @ViewBuilder private var ssid: some View {
        if let s = wifi.ssid {
            Text(s).fontWeight(.medium)
        } else {
            switch model.location.state {
            case .authorized:
                Text("Hidden").foregroundStyle(.tertiary)
            case .notDetermined, .denied:
                VStack(alignment: .trailing, spacing: 3) {
                    Text("Allow Location access to see the Wi-Fi name")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button(model.location.requestTitle) {
                        model.location.request()
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    private var channel: String? {
        guard let ch = wifi.channel else { return nil }
        var parts = ["\(ch)", wifi.band.label]
        if let w = wifi.channelWidth { parts.append("\(w) MHz") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var signal: some View {
        VStack(alignment: .trailing, spacing: 1) {
            if let rssi = wifi.rssi {
                Text("\(rssi) dBm").monospacedDigit()
            }
            HStack(spacing: 6) {
                if let noise = wifi.noise { Text("Noise \(noise) dBm") }
                if let snr = wifi.snr { Text("SNR \(snr) dB") }
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }
}

enum OverviewFormat {
    static func ms(_ v: Double) -> String { Latency.format(ms: v) }

    static func mbps(_ v: Double) -> String {
        switch v {
        case ..<10: String(format: "%.2f", v)
        case ..<100: String(format: "%.1f", v)
        default: String(format: "%.0f", v)
        }
    }

    static func txRate(_ mbps: Double?) -> String? { mbps.map { String(format: "%.0f Mbit/s", $0) } }

    static func color(_ q: WiFiInfo.Quality) -> Color {
        switch q {
        case .excellent, .good: .green
        case .fair: .orange
        case .poor: .red
        }
    }
}
