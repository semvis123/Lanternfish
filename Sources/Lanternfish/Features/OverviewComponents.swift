import LanternfishKit
import SwiftUI

/// A titled, rounded card like the grouped sections in System Settings.
struct OverviewCard<Content: View, Accessory: View>: View {
    let title: String
    let symbol: String
    var tint: Color = .accentColor
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 18, height: 18)
                    .background(tint.gradient, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                Text(title)
                    .font(.headline)
                Spacer(minLength: 4)
                accessory
            }
            .padding(.horizontal, 2)
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .cardBackground(cornerRadius: 9)
        }
    }
}

extension EnvironmentValues {
    /// Set on views inside a Liquid Glass pane (the inspector). An opaque background there gets
    /// the pane's vibrancy applied and turns flat grey in dark mode, so cards use a translucent
    /// fill instead, like grouped `Form` sections.
    @Entry var cardsOnGlass = false
}

extension View {
    /// The grouped-section look shared by the Overview, Health and Airwaves cards: the secondary
    /// background (or a translucent fill on glass) with a hairline border.
    func cardBackground(cornerRadius: CGFloat) -> some View {
        modifier(CardBackground(cornerRadius: cornerRadius))
    }
}

private struct CardBackground: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.cardsOnGlass) private var onGlass

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if onGlass {
            content.background(.fill.quaternary, in: shape)
        } else {
            content.background(.background.secondary, in: shape)
                .overlay { shape.strokeBorder(.separator.opacity(0.6), lineWidth: 0.5) }
        }
    }
}

extension OverviewCard where Accessory == EmptyView {
    init(title: String, symbol: String, tint: Color = .accentColor, @ViewBuilder content: () -> Content) {
        self.init(title: title, symbol: symbol, tint: tint, accessory: { EmptyView() }, content: content)
    }
}

/// Label / value row with a hairline divider below, values selectable for copying.
struct OverviewRow<Value: View>: View {
    let label: String
    var divider = true
    @ViewBuilder var value: Value

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(label)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .layoutPriority(1)
                Spacer(minLength: 8)
                value
                    .multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
            }
            .font(.callout)
            .padding(.vertical, 5)
            if divider { Divider().opacity(0.6) }
        }
    }
}

extension OverviewRow where Value == Text {
    init(_ label: String, _ value: String?, divider: Bool = true, monospaced: Bool = false) {
        self.label = label
        self.divider = divider
        let text = Text(value ?? "—")
        self.value = value == nil ? text.foregroundStyle(.tertiary) : (monospaced ? text.monospacedDigit() : text)
    }
}

/// Four signal-strength bars.
struct SignalBars: View {
    let bars: Int
    var tint: Color

    var body: some View {
        HStack(alignment: .bottom, spacing: 1.5) {
            ForEach(1...4, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(i <= bars ? AnyShapeStyle(tint) : AnyShapeStyle(.quaternary))
                    .frame(width: 3, height: 3 + CGFloat(i) * 2.5)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Signal bars and the quality word ("Good"), for a card's header.
struct WiFiQualityBadge: View {
    let quality: WiFiInfo.Quality

    var body: some View {
        HStack(spacing: 5) {
            SignalBars(bars: quality.bars, tint: OverviewFormat.color(quality))
            Text(quality.label).font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Signal \(quality.label)")
    }
}

/// Green / red / gray status dot with a label.
struct StatusPill: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text)
        }
    }
}
