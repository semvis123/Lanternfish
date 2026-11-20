import LanternfishKit
import SwiftUI

// MARK: - Kind styling

extension Color {
    /// An sRGB color from 0xRRGGBB.
    init(hex: UInt32) {
        self.init(
            .sRGB, red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255)
    }
}

extension DeviceKind {
    /// Per-kind accent used for the device icon badge.
    var tint: Color {
        switch self {
        case .router: .blue
        case .computer: .indigo
        case .phone, .tablet: .teal
        case .tv: .purple
        case .printer: .brown
        case .speaker: .pink
        case .camera: .red
        case .gameConsole: .green
        case .nas: .orange
        case .iot: .yellow
        case .unknown: .gray
        }
    }

    /// Deeper tone for the icon tile, so the white glyph stays legible (≥ 3.5:1 contrast,
    /// also at the gradient's lighter top). `tint` stays vivid for map rings and accents.
    var badgeColor: Color {
        switch self {
        case .router: Color(hex: 0x1E6FE0)
        case .computer: Color(hex: 0x5A4BD6)
        case .phone, .tablet: Color(hex: 0x0D7F86)
        case .tv: Color(hex: 0x9A3CC6)
        case .printer: Color(hex: 0x8A6040)
        case .speaker: Color(hex: 0xCC3366)
        case .camera: Color(hex: 0xCC3333)
        case .gameConsole: Color(hex: 0x2A8346)
        case .nas: Color(hex: 0xC05A12)
        case .iot: Color(hex: 0x9C7200)
        case .unknown: Color(hex: 0x6B7079)
        }
    }

    /// Symbol drawn inside the icon badge. Unknown devices get a generic glyph instead of "?".
    var badgeSymbol: String {
        self == .unknown ? "network" : symbolName
    }
}

/// A white glyph on a small tinted rounded square, System Settings style.
///
/// With a `device`, the glyph is product-specific where the product is clear (`ProductSymbol`,
/// e.g. a HomePod mini), a brand monogram for unclassified devices with a known brand
/// (`BrandMonogram`, e.g. "S" for Sonos), and the kind symbol otherwise.
struct DeviceIconView: View {
    let kind: DeviceKind
    var size: CGFloat = 20
    /// Greyed out (offline devices).
    var dimmed = false
    /// The device itself, when known, for product-specific icons.
    var device: Device? = nil

    init(kind: DeviceKind, size: CGFloat = 20, dimmed: Bool = false) {
        self.kind = kind
        self.size = size
        self.dimmed = dimmed
    }

    /// Icon for a specific device (its effective kind, and its product where recognized).
    init(device: Device, size: CGFloat = 20, dimmed: Bool = false) {
        self.kind = device.effectiveKind
        self.size = size
        self.dimmed = dimmed
        self.device = device
    }

    private enum Glyph {
        case symbol(String, scale: CGFloat)
        case monogram(String)
    }

    private struct Content {
        let glyph: Glyph
        let tint: Color
        let label: String
    }

    private var content: Content {
        if let device {
            if let m = ProductSymbol.match(for: device) {
                return Content(
                    glyph: .symbol(m.symbol, scale: Self.symbolScale[m.symbol] ?? 1),
                    tint: m.kind.badgeColor, label: m.label)
            }
            if kind == .unknown, let brand = device.brand, let letters = BrandMonogram.letters(for: brand) {
                return Content(
                    glyph: .monogram(letters), tint: BrandMonogram.color(for: brand),
                    label: "\(Device.shortBrand(brand)) device")
            }
        }
        return Content(glyph: .symbol(kind.badgeSymbol, scale: 1), tint: kind.badgeColor, label: kind.label)
    }

    /// Optical size corrections so wide or heavy product glyphs match the kind symbols.
    private static let symbolScale: [String: CGFloat] = [
        "playstation.logo": 0.86, "xbox.logo": 0.86, "mediastick": 0.88, "visionpro": 0.9,
        "tv.and.mediabox": 0.92, "cube.fill": 0.9, "hifispeaker.2": 0.94, "macmini": 0.94, "macstudio": 0.94,
        "airport.extreme": 0.94,
    ]

    /// Slightly lighter at the top, like system icons; kept subtle so contrast holds.
    private static func tileGradient(_ base: Color) -> LinearGradient {
        LinearGradient(colors: [base.mix(with: .white, by: 0.12), base], startPoint: .top, endPoint: .bottom)
    }

    var body: some View {
        let c = content
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            .fill(dimmed ? AnyShapeStyle(.quaternary) : AnyShapeStyle(Self.tileGradient(c.tint)))
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                    .strokeBorder(.black.opacity(0.08), lineWidth: 0.5)
            }
            .overlay {
                // Offline: a neutral tile with a secondary-colored glyph, legible in light and dark.
                glyph(c.glyph)
                    .foregroundStyle(dimmed ? AnyShapeStyle(.secondary) : AnyShapeStyle(.white))
                    .shadow(color: .black.opacity(dimmed ? 0 : 0.15), radius: 0.5, y: 0.5)
            }
            .frame(width: size, height: size)
            .accessibilityElement()
            .accessibilityLabel(c.label)
    }

    @ViewBuilder
    private func glyph(_ g: Glyph) -> some View {
        switch g {
        case .symbol(let name, let scale):
            Image(systemName: name)
                .font(.system(size: size * 0.52 * scale, weight: .medium))
                .symbolRenderingMode(.monochrome)
        case .monogram(let letters):
            Text(letters)
                .font(.system(size: size * (letters.count > 1 ? 0.4 : 0.5), weight: .bold, design: .rounded))
                .kerning(letters.count > 1 ? -0.02 * size : 0)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .padding(.horizontal, size * 0.08)
        }
    }
}

extension BrandMonogram {
    /// Muted, saturated tones that keep white letters legible in light and dark mode.
    private static let palette: [Color] = [
        Color(hex: 0x4F5BD5),  // periwinkle
        Color(hex: 0x16777E),  // teal
        Color(hex: 0xC0473F),  // brick
        Color(hex: 0x8A55C8),  // violet
        Color(hex: 0xB0600F),  // amber
        Color(hex: 0x2F7D48),  // green
        Color(hex: 0xC03E80),  // raspberry
        Color(hex: 0x3A6EA5),  // steel blue
        Color(hex: 0x8F6A44),  // bronze
        Color(hex: 0x6B7418),  // olive (no grey: that reads as "unknown")
    ]

    /// The brand's badge color, stable across launches.
    static func color(for brand: String) -> Color {
        palette[paletteIndex(for: brand, count: palette.count)]
    }
}

// MARK: - Display helpers

extension Device {
    /// Manufacturer from discovery, else OUI vendor.
    var brand: String? {
        let b = manufacturer ?? vendor
        return b?.isEmpty == false ? b : nil
    }

    /// True when the device has a custom name, announced a name or has a hostname
    /// (displayName isn't a fallback).
    var hasRealName: Bool {
        (customName?.isEmpty == false) || (name?.isEmpty == false) || (hostname?.isEmpty == false)
    }

    /// The name the device would have without the user's custom name (rename placeholder).
    var automaticName: String {
        var d = self
        d.customName = nil
        return d.listName
    }

    /// Label used in place of a fallback name, e.g. "Espressif Smart Device", "Zyxel Router".
    var fallbackLabel: String {
        let k = effectiveKind
        let kindPart = k == .unknown ? "Device" : k.label
        if let b = brand { return "\(Self.shortBrand(b)) \(kindPart)" }
        return k == .unknown ? "Unknown Device" : k.label
    }

    /// The label shown in the Name column.
    var listName: String { hasRealName ? displayName : fallbackLabel }

    /// Brand and secondary detail (model, else OS hint) for the Brand / Model column.
    var brandDetail: (primary: String?, secondary: String?) {
        var m = model?.trimmingCharacters(in: .whitespaces)
        if let b = brand, let mm = m, mm.lowercased().hasPrefix(b.lowercased()) {
            let rest = mm.dropFirst(b.count).trimmingCharacters(in: .whitespaces)
            m = rest.isEmpty ? nil : rest
        }
        if m?.isEmpty == true { m = nil }
        let os = osHint?.isEmpty == false ? osHint : nil
        if let b = brand { return (b, m ?? os) }
        if let m { return (m, os) }
        return (nil, os)
    }

    /// Drops corporate suffixes: "Zyxel Communications" → "Zyxel", "IKEA of Sweden" → "IKEA".
    static func shortBrand(_ brand: String) -> String {
        var b = brand
        let suffixes = [
            " Communications", " Electronics", " Technologies", " Technology", " Corporation",
            " Co., Ltd.", " Co.,Ltd.", " Co., Ltd", " Co.", " Ltd.", " Ltd", " Inc.", " Inc",
            " Corp.", " Corp", " GmbH", " AB", " of Sweden", " International", " Systems",
            " Limited", ",",
        ]
        var changed = true
        while changed {
            changed = false
            for s in suffixes where b.count > s.count + 1 && b.lowercased().hasSuffix(s.lowercased()) {
                b.removeLast(s.count)
                b = b.trimmingCharacters(in: .whitespaces)
                changed = true
            }
        }
        return b
    }

    // Sort keys for table columns.
    var nameSortKey: String { listName }
    /// Online devices by response time, then offline ones, most recently seen first.
    var responseSortKey: Duration {
        if isOnline { return responseTime ?? .seconds(1_000_000) }
        return .seconds(2_000_000) + .seconds(max(0, -(lastSeen ?? .distantPast).timeIntervalSinceNow))
    }

    /// "3d ago", "5m ago", "just now".
    @MainActor var lastSeenShort: String? { lastSeen.map(RelativeTime.short) }
}

enum RelativeTime {
    /// Formatters are expensive to make; these are only used on the main actor.
    @MainActor private static let shortFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    @MainActor private static let fullFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    /// True when `date` is recent enough to read "just now".
    private static func isJustNow(_ date: Date) -> Bool { date.timeIntervalSinceNow > -60 }

    /// "3d ago", "just now".
    @MainActor
    static func short(_ date: Date) -> String {
        if isJustNow(date) { return "just now" }
        return shortFormatter.localizedString(for: date, relativeTo: .now)
    }

    /// "3 days ago", "just now".
    @MainActor
    static func full(_ date: Date) -> String {
        if isJustNow(date) { return "just now" }
        return fullFormatter.localizedString(for: date, relativeTo: .now)
    }
}

/// Re-renders `content` every 30 s so relative times ("5 min ago") stay current.
struct RelativeTimeRefresh<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { _ in content() }
    }
}

extension KnownNetwork {
    /// The user's name, else e.g. "Zyxel NR7101 — 192.168.1.0/24", else the subnet.
    var displayName: String { customName ?? defaultName }

    var defaultName: String {
        gatewayLabel.map { "\($0) — \(subnet)" } ?? subnet
    }

    /// Compact name for the toolbar: the user's name, else the router's brand and model, else the subnet.
    var shortName: String { customName ?? gatewayLabel ?? subnet }

    /// The router's brand and model, e.g. "Zyxel NR7101".
    private var gatewayLabel: String? {
        guard let gw = gatewayDevice?.offlineDevice() else { return nil }
        if let brand = gw.brand.map(Device.shortBrand) {
            var model = gw.model?.trimmingCharacters(in: .whitespaces)
            if let m = model, m.lowercased().hasPrefix(brand.lowercased()) {
                model = m.dropFirst(brand.count).trimmingCharacters(in: .whitespaces)
            }
            return model?.isEmpty == false ? "\(brand) \(model!)" : brand
        }
        if let m = gw.model, !m.isEmpty { return m }
        return nil
    }
}

/// Small accent capsule marking devices first seen on a known network.
struct NewBadge: View {
    var body: some View {
        Text("New")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Color.accentColor, in: Capsule())
            .fixedSize()
            .help("First seen on this network recently")
    }
}

extension NetworkInterfaceInfo {
    /// SF Symbol for the picker.
    var symbolName: String {
        let n = displayName.lowercased()
        if n.contains("wi-fi") || n.contains("wifi") || n.contains("airport") { return "wifi" }
        if n.contains("thunderbolt") { return "bolt.horizontal" }
        if n.contains("iphone") || n.contains("usb") && n.contains("phone") { return "iphone" }
        if name.hasPrefix("utun") || n.contains("vpn") { return "lock.shield" }
        return "cable.connector"
    }
}

// MARK: - Small shared views

/// The "—" shown in place of a value that isn't known.
struct NoValue: View {
    var body: some View {
        Text("—").foregroundStyle(.tertiary)
    }
}

/// The "This Mac" capsule next to this Mac's name (table, menu bar).
struct ThisMacTag: View {
    var body: some View {
        Text("This Mac")
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(.fill.tertiary, in: Capsule())
            .fixedSize()
    }
}

/// The app's one copy button: copies text and briefly turns into a green checkmark ("Copied",
/// also announced to VoiceOver).
///
/// Three looks: an inline borderless icon (`CopyButton(text:help:)`, next to values), a bordered
/// icon button (`bordered: true`, sheet headers) and a titled button (`showsTitle: true`).
struct CopyButton: View {
    let title: String
    var symbol = "doc.on.doc"
    let help: String
    var bordered = false
    var showsTitle = false
    let text: () -> String?
    @State private var copied = false

    init(
        _ title: String = "Copy", symbol: String = "doc.on.doc", help: String, bordered: Bool = false,
        showsTitle: Bool = false, text: @escaping () -> String?
    ) {
        self.title = title
        self.symbol = symbol
        self.help = help
        self.bordered = bordered
        self.showsTitle = showsTitle
        self.text = text
    }

    /// Inline icon that copies `text`.
    init(text: String, symbol: String = "doc.on.doc", help: String = "Copy") {
        self.init(help, symbol: symbol, help: help, text: { text })
    }

    var body: some View {
        let button = Button(action: copy) {
            Label(copied ? "Copied" : title, systemImage: copied ? "checkmark" : symbol)
                .contentTransition(.symbolEffect(.replace))
        }
        .help(help)
        if showsTitle {
            button
        } else if bordered {
            button.labelStyle(.iconOnly)
        } else {
            button
                .labelStyle(InlineCopyLabelStyle())
                .buttonStyle(.borderless)
                .foregroundStyle(copied ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                .accessibilityLabel(copied ? "Copied" : help)
        }
    }

    private func copy() {
        guard let s = text() else { return }
        DeviceActions.copy(s)
        copied = true
        AccessibilityNotification.Announcement("Copied").post()
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }
}

/// Icon only, in a fixed-width slot so the checkmark doesn't shift neighbours.
private struct InlineCopyLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.icon.frame(width: 16)
    }
}

/// Capsule tag for a service name.
struct TagView: View {
    let text: String
    var font: Font = .caption

    var body: some View {
        Text(text)
            .font(font)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(.fill.tertiary, in: Capsule())
    }
}

/// Simple wrapping layout for tag chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4
    var lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for i in row.indices {
                let s = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(
                    at: CGPoint(x: x, y: y + (row.height - s.height) / 2),
                    proposal: ProposedViewSize(s))
                x += s.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for (i, sv) in subviews.enumerated() {
            let s = sv.sizeThatFits(.unspecified)
            if !rows[rows.count - 1].indices.isEmpty, rows[rows.count - 1].width + spacing + s.width > width {
                rows.append(Row())
            }
            var r = rows[rows.count - 1]
            r.width += (r.indices.isEmpty ? 0 : spacing) + s.width
            r.height = max(r.height, s.height)
            r.indices.append(i)
            rows[rows.count - 1] = r
        }
        return rows.filter { !$0.indices.isEmpty }
    }
}
