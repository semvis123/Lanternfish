import LanternfishKit
import SwiftUI

/// Traceroute sheet: live hop table with latency bars, and a field to trace another host.
struct TracerouteView: View {
    let target: TracerouteTarget
    @Environment(\.dismiss) private var dismiss
    @State private var model = TracerouteModel()
    @State private var hostField = ""

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 12)
            TracerouteHopTable(model: model)
            Divider()
            footer
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
        }
        .frame(minWidth: 620, idealWidth: 620, minHeight: 440, idealHeight: 440)
        .onAppear {
            hostField = target.host
            model.start(target.host)
        }
        .onDisappear { model.stop() }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "point.3.filled.connected.trianglepath.dotted")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(Color.accentColor.gradient, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("Traceroute to \(model.host.isEmpty ? target.host : model.host)")
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let ip = model.resolved, ip.description != model.host {
                        Text(ip.description)
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                status
            }
            Spacer(minLength: 8)
            if model.isRunning {
                Button("Stop") { model.stop() }
            } else {
                Button("Trace Again", systemImage: "arrow.clockwise") { model.start(model.host) }
                    .disabled(model.host.isEmpty)
            }
        }
    }

    @ViewBuilder private var status: some View {
        HStack(spacing: 5) {
            switch model.status {
            case .idle, .resolving:
                ProgressView().controlSize(.mini)
                Text("Resolving…").foregroundStyle(.secondary)
            case .tracing:
                ProgressView().controlSize(.mini)
                Text(model.hops.isEmpty ? "Tracing…" : "Tracing… \(model.hops.count) hops so far")
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            case .finished(reached: true):
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                let n = model.hopCount ?? 0
                Text("Reached in \(n) \(n == 1 ? "hop" : "hops")").foregroundStyle(.secondary)
            case .finished(reached: false):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("Destination didn’t respond within \(TracerouteModel.maxHops) hops").foregroundStyle(.secondary)
            case .stopped:
                Image(systemName: "stop.circle").foregroundStyle(.secondary)
                Text("Stopped").foregroundStyle(.secondary)
            case .failed(let message):
                Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                Text(message).foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .lineLimit(1)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            TextField("Host or IP address", text: $hostField, prompt: Text("e.g. 1.1.1.1 or apple.com"))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 240)
                .onSubmit(trace)
            Button("Trace", action: trace)
                .disabled(hostField.trimmingCharacters(in: .whitespaces).isEmpty)
            Spacer()
            CopyButton(help: "Copy the hops as text", showsTitle: true) { model.text }
                .disabled(model.hops.isEmpty)
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
    }

    private func trace() {
        let host = hostField.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return }
        model.start(host)
    }
}

// MARK: - Hop table

private struct HopRow: Identifiable, Hashable {
    let hop: TracerouteHop
    var id: Int { hop.ttl }
}

private struct TracerouteHopTable: View {
    let model: TracerouteModel
    @State private var selection = Set<HopRow.ID>()

    var body: some View {
        let rows = model.hops.map(HopRow.init)
        let peak = model.maxAverage
        Table(rows, selection: $selection) {
            TableColumn("#") { row in
                Text("\(row.hop.ttl)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(24)
            TableColumn("Address") { row in
                if let a = row.hop.address {
                    Text(a.description)
                        .monospacedDigit()
                        .foregroundStyle(a == model.resolved ? Color.accentColor : .primary)
                } else {
                    Text(row.hop.rtts.isEmpty ? "…" : "*").foregroundStyle(.tertiary)
                }
            }
            .width(min: 96, ideal: 110)
            TableColumn("Hostname") { row in
                Text(row.hop.hostname ?? "")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(row.hop.hostname ?? "")
            }
            .width(min: 80, ideal: 150)
            TableColumn("RTT 1") { row in RTTCell(hop: row.hop, index: 0) }.width(56)
            TableColumn("RTT 2") { row in RTTCell(hop: row.hop, index: 1) }.width(56)
            TableColumn("RTT 3") { row in RTTCell(hop: row.hop, index: 2) }.width(56)
            TableColumn("Avg") { row in
                HStack(spacing: 6) {
                    LatencyBar(value: row.hop.averageRTT, peak: peak)
                    Text(row.hop.averageRTT.map(PingFormat.rtt) ?? "—")
                        .monospacedDigit()
                        .foregroundStyle(row.hop.averageRTT == nil ? .tertiary : .primary)
                        .frame(minWidth: 52, alignment: .trailing)
                }
            }
            .width(min: 110, ideal: 120)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: HopRow.ID.self) { ids in
            if let ttl = ids.first, let hop = model.hops.first(where: { $0.ttl == ttl }), let a = hop.address {
                Button("Copy Address") { DeviceActions.copy(a.description) }
                if let name = hop.hostname {
                    Button("Copy Hostname") { DeviceActions.copy(name) }
                }
            }
        }
        .overlay {
            if rows.isEmpty, model.isRunning {
                ProgressView().controlSize(.small)
            } else if rows.isEmpty, case .failed = model.status {
                ContentUnavailableView(
                    "No Route", systemImage: "point.3.connected.trianglepath.dotted",
                    description: Text("Check the host name and try again."))
            }
        }
    }
}

/// One probe's RTT, "*" for a timeout, blank while pending.
private struct RTTCell: View {
    let hop: TracerouteHop
    let index: Int

    var body: some View {
        Group {
            if index < hop.rtts.count {
                if let rtt = hop.rtts[index] {
                    Text(PingFormat.rtt(rtt))
                } else {
                    Text("*").foregroundStyle(.tertiary)
                }
            } else {
                Text("")
            }
        }
        .monospacedDigit()
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

/// Small horizontal bar: average latency relative to the slowest hop.
private struct LatencyBar: View {
    let value: Duration?
    let peak: Duration?
    private let width: CGFloat = 44

    var body: some View {
        let fraction: Double = {
            guard let value, let peak, peak > .zero else { return 0 }
            return min(1, max(0.04, PingFormat.ms(value) / PingFormat.ms(peak)))
        }()
        ZStack(alignment: .leading) {
            Capsule().fill(.fill.tertiary)
            Capsule()
                .fill(tint.gradient)
                .frame(width: width * fraction)
        }
        .frame(width: width, height: 5)
        .animation(.easeOut(duration: 0.25), value: fraction)
        .accessibilityHidden(true)
    }

    private var tint: Color {
        guard let value else { return .gray }
        switch PingFormat.ms(value) {
        case ..<40: return .green
        case ..<150: return .yellow
        default: return .orange
        }
    }
}
