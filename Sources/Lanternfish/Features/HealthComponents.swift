import LanternfishKit
import SwiftUI

/// The score as a ring with the number in the middle.
struct HealthScoreRing: View {
    let score: Int
    let grade: HealthGrade
    var size: CGFloat = 88
    var showsLabel = true
    @State private var shown: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var lineWidth: CGFloat { max(4, size * 0.1) }

    var body: some View {
        ZStack {
            Circle()
                .stroke(grade.tint.opacity(0.16), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: shown)
                .stroke(
                    AngularGradient(
                        colors: [grade.tint.opacity(0.75), grade.tint],
                        center: .center, startAngle: .degrees(0), endAngle: .degrees(360 * shown)),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
            VStack(spacing: -1) {
                Text("\(score)")
                    .font(.system(size: size * 0.34, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(score)))
                if showsLabel {
                    Text("of 100")
                        .font(.system(size: max(9, size * 0.11), weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: size, height: size)
        .onAppear { animate() }
        .onChange(of: score) { animate() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Health score \(score) of 100, \(grade.label)")
    }

    private func animate() {
        let target = max(0.004, Double(score) / 100)
        if reduceMotion {
            shown = target
        } else {
            withAnimation(.smooth(duration: 0.8)) { shown = target }
        }
    }
}

/// Small rounded-square badge with a symbol, tinted.
private struct HealthBadge: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 26

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// One finding: icon, title, explanation; expands to list the affected devices.
struct HealthFindingCard: View {
    let finding: HealthFinding
    let context: HealthContext
    @Binding var isExpanded: Bool

    private var devices: [Device] { finding.deviceIDs.compactMap(context.device) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.snappy(duration: 0.22)) { isExpanded.toggle() }
            } label: {
                header.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(devices.isEmpty)
            .accessibilityHint(devices.isEmpty ? "" : isExpanded ? "Hides the devices" : "Shows the devices")
            if isExpanded, !devices.isEmpty {
                VStack(spacing: 0) {
                    ForEach(devices) { d in
                        Divider().padding(.leading, 46)
                        HealthDeviceRow(device: d, rule: finding.rule, isLive: context.isLive) { context.select(d) }
                    }
                }
                .padding(.bottom, 4)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .cardBackground(cornerRadius: 10)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            HealthBadge(symbol: finding.rule.symbol, tint: finding.severity.tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(finding.title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(finding.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            if !devices.isEmpty {
                HStack(spacing: 4) {
                    Text("\(devices.count)")
                        .font(.caption.weight(.medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .padding(.top, 2)
                .accessibilityHidden(true)
            }
        }
        .padding(10)
    }
}

/// An affected device; clicking selects it in the main window.
private struct HealthDeviceRow: View {
    let device: Device
    let rule: HealthRule
    let isLive: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                DeviceIconView(device: device, size: 24, dimmed: isLive && !device.isOnline)
                VStack(alignment: .leading, spacing: 1) {
                    Text(device.listName)
                        .font(.callout)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                Text("Show")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.accentColor)
                    .opacity(hovering ? 1 : 0)
                Image(systemName: "arrow.forward.circle.fill")
                    .foregroundStyle(hovering ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
            }
            .padding(.leading, 12)
            .padding(.trailing, 10)
            .padding(.vertical, 6)
            .background(hovering ? Color.primary.opacity(0.05) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Show \(device.listName) in the device list")
        .accessibilityLabel("\(device.listName), \(detail)")
        .accessibilityHint("Selects the device in the main window")
    }

    private var detail: String {
        var parts = [device.ip.description]
        let ports = device.openPorts.filter { rule.ports.contains($0.port) }
        if !ports.isEmpty {
            parts.append(
                ports.map { p in p.service.map { "\(p.port) \($0)" } ?? "Port \(p.port)" }
                    .joined(separator: ", "))
        } else if let brand = device.brandModel, brand != device.listName {
            parts.append(brand)
        }
        if device.isPrivateMAC, rule == .privateMACs || rule == .unidentified { parts.append("Private address") }
        return parts.joined(separator: " · ")
    }
}

/// The "Looking Good" list: compact rows in one card.
struct HealthPassedCard: View {
    let items: [HealthFinding]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { i, f in
                if i > 0 { Divider().padding(.leading, 46) }
                HStack(alignment: .top, spacing: 10) {
                    HealthBadge(symbol: "checkmark", tint: .green, size: 22)
                        .padding(.leading, 2)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(f.title).font(.callout.weight(.medium))
                        Text(f.detail).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .accessibilityElement(children: .combine)
            }
        }
        .cardBackground(cornerRadius: 10)
    }
}

/// Section title with the severity's icon and a count.
struct HealthSectionHeader: View {
    let severity: HealthSeverity
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: severity.symbol)
                .foregroundStyle(severity.tint)
            Text(severity.label)
                .font(.subheadline.weight(.semibold))
            Text("\(count)")
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(.quaternary.opacity(0.6), in: Capsule())
            Spacer()
        }
        .padding(.horizontal, 2)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}
