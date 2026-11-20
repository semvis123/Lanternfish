import LanternfishKit
import SwiftUI

/// Network Health sheet: one score plus plain-language findings for the displayed network
/// (live or saved), built only from what scans already found.
struct HealthView: View {
    let hub: NetworkHub
    @Environment(\.dismiss) private var dismiss
    @State private var expanded: Set<String> = []
    @State private var didSetInitialExpansion = false

    var body: some View {
        let context = HealthContext(store: hub.displayedStore)
        let report = context.report
        VStack(spacing: 0) {
            HealthHeader(context: context)
                .padding(.horizontal, 22)
                .padding(.top, 20)
                .padding(.bottom, 16)
            Divider()
            if report.isEmpty {
                ContentUnavailableView {
                    Label("No Devices Yet", systemImage: "network")
                } description: {
                    Text(
                        context.isPartial
                            ? "The scan is still looking for devices." : "Scan the network to check its health.")
                }
                .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach([HealthSeverity.critical, .warning, .info], id: \.self) { severity in
                            let items = report.findings(severity)
                            if !items.isEmpty {
                                VStack(alignment: .leading, spacing: 8) {
                                    HealthSectionHeader(severity: severity, count: items.count)
                                    ForEach(items) { f in
                                        HealthFindingCard(finding: f, context: context, isExpanded: binding(f.id))
                                    }
                                }
                            }
                        }
                        if !report.passed.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                HealthSectionHeader(severity: .passed, count: report.passed.count)
                                HealthPassedCard(items: report.passed)
                            }
                        }
                    }
                    .padding(20)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            Divider()
            footer
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
        }
        .frame(minWidth: 560, idealWidth: 580, maxWidth: 760, minHeight: 480, idealHeight: 640)
        .onAppear { setInitialExpansion(report) }
        .onChange(of: report.findings.map(\.id)) { setInitialExpansion(report) }
    }

    private func binding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { expanded.contains(id) },
            set: { if $0 { expanded.insert(id) } else { expanded.remove(id) } })
    }

    /// Critical findings open; warnings too when there are only a few of them.
    private func setInitialExpansion(_ report: HealthReport) {
        guard !didSetInitialExpansion, !report.findings.isEmpty else { return }
        didSetInitialExpansion = true
        let few = report.criticalCount + report.warningCount <= 3
        expanded = Set(
            report.findings.filter { $0.severity == .critical || (few && $0.severity == .warning) }.map(\.id))
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.shield")
                .foregroundStyle(.secondary)
            Text("Uses only what scans already found. Never tries passwords or logins.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer(minLength: 8)
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
    }
}

/// Score ring, grade, summary and which network (live or saved) this is about.
private struct HealthHeader: View {
    let context: HealthContext

    var body: some View {
        let report = context.report
        HStack(alignment: .center, spacing: 18) {
            HealthScoreRing(score: report.score, grade: report.grade, size: 92)
                .opacity(report.isEmpty ? 0.35 : 1)
            VStack(alignment: .leading, spacing: 5) {
                Text("Network Health")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Text(report.isEmpty ? "Not Checked Yet" : report.grade.label)
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(
                        report.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(report.grade.tint.gradient))
                Text(report.summary)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                networkLine
            }
            Spacer(minLength: 0)
        }
    }

    private var networkLine: some View {
        HStack(spacing: 6) {
            if let saved = context.savedLabel {
                Label(saved, systemImage: "clock.arrow.circlepath")
                    .labelStyle(HealthTagLabelStyle(tint: .secondary))
            } else if context.isPartial {
                Label("Scanning, results may change", systemImage: "dot.radiowaves.up.forward")
                    .labelStyle(HealthTagLabelStyle(tint: .orange))
            } else {
                Label("Live", systemImage: "circle.fill")
                    .labelStyle(HealthTagLabelStyle(tint: .green, smallIcon: true))
            }
            Text(context.networkName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.top, 2)
    }
}

private struct HealthTagLabelStyle: LabelStyle {
    let tint: Color
    var smallIcon = false

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon
                .font(.system(size: smallIcon ? 6 : 9, weight: .semibold))
                .foregroundStyle(tint)
            configuration.title
                .font(.caption.weight(.medium))
                .foregroundStyle(tint == .secondary ? Color.secondary : Color.primary)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(tint.opacity(tint == .secondary ? 0.12 : 0.14), in: Capsule())
    }
}
