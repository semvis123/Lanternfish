import LanternfishKit
import SwiftUI

/// The Health card at the top of the Network Overview popover: score, grade, and a way in.
struct OverviewHealthSection: View {
    let store: ScanStore

    var body: some View {
        let context = HealthContext(store: store)
        let report = context.report
        OverviewCard(title: "Health", symbol: "checkmark.shield.fill", tint: report.isEmpty ? .gray : report.grade.tint)
        {
            if let saved = context.savedLabel {
                Text(saved).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            } else if !report.isEmpty {
                StatusPill(text: report.grade.label, color: report.grade.tint).font(.caption)
            }
        } content: {
            HStack(spacing: 12) {
                HealthScoreRing(score: report.score, grade: report.grade, size: 44, showsLabel: false)
                    .opacity(report.isEmpty ? 0.35 : 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(report.summary)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    if let counts = counts(report) {
                        Text(counts)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                Button("Show Details…") {
                    Router.shared.showOverview = false
                    Router.shared.showHealth = true
                }
                .controlSize(.small)
                .disabled(report.isEmpty)
                .help("Network Health (⇧⌘H)")
            }
            .padding(.vertical, 8)
        }
    }

    private func counts(_ r: HealthReport) -> String? {
        let info = r.findings(.info).count
        var parts: [String] = []
        if r.criticalCount > 0 { parts.append("\(r.criticalCount) critical") }
        if r.warningCount > 0 { parts.append(r.warningCount == 1 ? "1 warning" : "\(r.warningCount) warnings") }
        if info > 0 { parts.append(info == 1 ? "1 note" : "\(info) notes") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
