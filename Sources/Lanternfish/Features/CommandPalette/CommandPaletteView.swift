import LanternfishKit
import SwiftUI

/// The ⌘K panel: search field, sectioned results and a footer with key hints.
struct CommandPalettePanel: View {
    @Bindable var model: CommandPaletteModel
    @FocusState private var fieldFocused: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    // Sizes scale with the text size (Dynamic Type), from these defaults.
    @ScaledMetric(relativeTo: .body) private var width: CGFloat = 620
    @ScaledMetric(relativeTo: .body) private var rowHeight: CGFloat = 40
    @ScaledMetric(relativeTo: .body) private var headerHeight: CGFloat = 26
    @ScaledMetric(relativeTo: .body) private var maxListHeight: CGFloat = 392
    @ScaledMetric(relativeTo: .title2) private var fieldFontSize: CGFloat = 19
    @ScaledMetric(relativeTo: .title2) private var fieldHeight: CGFloat = 52
    @ScaledMetric(relativeTo: .caption) private var headerFontSize: CGFloat = 11
    @ScaledMetric(relativeTo: .caption) private var footerFontSize: CGFloat = 11.5
    @ScaledMetric(relativeTo: .caption) private var footerHeight: CGFloat = 34

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider().opacity(0.6)
            results
            Divider().opacity(0.6)
            footer
        }
        .frame(width: min(width, 900))
        .background {
            // A thick, blurred material under a strong window-coloured tint: the table / map
            // behind the panel only shows as a soft hint of colour, never as readable text.
            // With Reduce Transparency the panel is solid.
            ZStack {
                if reduceTransparency {
                    Rectangle().fill(Color(nsColor: .windowBackgroundColor))
                } else {
                    Rectangle().fill(.thickMaterial)
                    Rectangle().fill(Color(nsColor: .windowBackgroundColor).opacity(colorScheme == .dark ? 0.86 : 0.84))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.primary.opacity(colorScheme == .dark ? 0.14 : 0.08), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.45 : 0.18), radius: 30, y: 14)
        .onAppear {
            DispatchQueue.main.async { fieldFocused = true }
        }
    }

    // MARK: Search field

    private var searchField: some View {
        HStack(spacing: 10) {
            if let target = model.actionsTarget {
                Button {
                    model.leaveActions()
                } label: {
                    HStack(spacing: 5) {
                        PaletteIconView(icon: target.icon, size: 18)
                        Text(target.title)
                            .lineLimit(1)
                            .frame(maxWidth: 200)
                            .fixedSize()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.leading, 4)
                    .padding(.trailing, 6)
                    .padding(.vertical, 3)
                    .background(.fill.tertiary, in: Capsule())
                }
                .buttonStyle(.plain)
                .help("Back to results (Esc)")
            } else {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: fieldFontSize - 1, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            TextField(
                "", text: $model.query,
                prompt: Text(model.actionsTarget == nil ? "Search devices, IPs and commands…" : "Search actions…")
            )
            .textFieldStyle(.plain)
            .font(.system(size: fieldFontSize))
            .focused($fieldFocused)
            .accessibilityLabel("Quick Search")
            if !model.query.isEmpty {
                Button {
                    model.query = ""
                } label: {
                    Label("Clear Search", systemImage: "xmark.circle.fill")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear")
            }
        }
        .padding(.horizontal, 16)
        .frame(height: fieldHeight)
    }

    // MARK: Results

    private var results: some View {
        let groups = grouped(model.rows)
        let height = groups.reduce(CGFloat(12)) { h, g in
            h + (g.section == nil ? 0 : headerHeight) + CGFloat(g.rows.count) * rowHeight
        }
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(groups, id: \.key) { group in
                        if let section = group.section {
                            Text(section.title)
                                .font(.system(size: headerFontSize, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 14)
                                .frame(height: headerHeight, alignment: .bottomLeading)
                                .padding(.bottom, 2)
                        }
                        ForEach(group.rows) { row in
                            PaletteRowView(
                                row: row, isSelected: row.id == model.selectedID,
                                showsActionsHint: model.actionsTarget == nil && row.item.actions != nil
                            )
                            .frame(height: rowHeight)
                            .id(row.id)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                model.selectedID = row.id
                                model.run(row.item)
                            }
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 6)
            }
            .scrollIndicators(.automatic)
            .frame(height: model.rows.isEmpty ? 0 : min(height, maxListHeight))
            .overlay {
                if model.rows.isEmpty { emptyState }
            }
            .frame(minHeight: model.rows.isEmpty ? 88 : 0)
            .onChange(of: model.selectedID) { _, id in
                guard let id else { return }
                if id == model.rows.first?.id {
                    proxy.scrollTo(groups.first?.key, anchor: .top)
                } else {
                    proxy.scrollTo(id)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 4) {
            Text(model.query.isEmpty ? "No actions" : "No results for “\(model.query)”")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Try a device name, IP or MAC address, brand, or a command like “rescan”.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding()
    }

    private struct Group {
        let key: String
        let section: PaletteSection?
        var rows: [PaletteRow]
    }

    /// Consecutive rows of the same section, with a header unless it is the action list.
    private func grouped(_ rows: [PaletteRow]) -> [Group] {
        var out: [Group] = []
        for row in rows {
            if let last = out.last, last.rows.last?.section == row.section {
                out[out.count - 1].rows.append(row)
            } else {
                let showHeader = row.section != .actions || model.actionsTarget == nil
                out.append(
                    Group(
                        key: "g\(out.count)-\(row.section.rawValue)",
                        section: showHeader ? row.section : nil, rows: [row]))
            }
        }
        return out
    }

    // MARK: Footer

    private var footer: some View {
        let selected = model.selectedRow?.item
        let secondary = selected.flatMap(model.secondaryAction(for:))
        return HStack(spacing: 14) {
            if let target = model.actionsTarget {
                Label("Actions for \(target.title)", systemImage: "bolt.fill")
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            } else {
                Label("Lanternfish", systemImage: "network")
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if let selected, !selected.isDisabled {
                KeyHint(title: model.actionsTarget == nil ? selected.verb : "Run", keys: "↩")
            }
            if let secondary {
                Divider().frame(height: 12)
                KeyHint(title: secondary.title, keys: "⌘↩")
            }
            if model.actionsTarget == nil, selected?.actions != nil {
                Divider().frame(height: 12)
                KeyHint(title: "Actions", keys: "⇥")
            } else if model.actionsTarget != nil {
                Divider().frame(height: 12)
                KeyHint(title: "Back", keys: "esc")
            }
        }
        .font(.system(size: footerFontSize))
        .labelStyle(.titleAndIcon)
        .padding(.horizontal, 14)
        .frame(height: footerHeight)
    }
}

/// "Show ↩" with the keys in a small keycap.
private struct KeyHint: View {
    let title: String
    let keys: String
    @ScaledMetric(relativeTo: .caption2) private var keySize: CGFloat = 10.5

    var body: some View {
        HStack(spacing: 5) {
            Text(title)
                .lineLimit(1)
                .foregroundStyle(.secondary)
            Text(keys)
                .font(.system(size: keySize, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .frame(minWidth: 18, minHeight: 17)
                .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
    }
}

// MARK: - Row

private struct PaletteRowView: View {
    let row: PaletteRow
    let isSelected: Bool
    let showsActionsHint: Bool
    @ScaledMetric(relativeTo: .body) private var titleSize: CGFloat = 13
    @ScaledMetric(relativeTo: .caption) private var detailSize: CGFloat = 11
    @ScaledMetric(relativeTo: .body) private var iconSize: CGFloat = 26
    @Environment(\.colorScheme) private var inheritedColorScheme

    var body: some View {
        let item = row.item
        HStack(spacing: 10) {
            PaletteIconView(icon: item.icon, size: iconSize, onAccent: isSelected)
                .opacity(item.isDisabled ? 0.45 : 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(highlighted(item.title, hits: row.titleHits, isTitle: true))
                    .font(.system(size: titleSize))
                    .lineLimit(1)
                if let sub = item.disabledReason ?? item.subtitle {
                    Text(highlighted(sub, hits: item.isDisabled ? [] : row.subtitleHits, isTitle: false))
                        .font(.system(size: detailSize))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .opacity(item.isDisabled ? 0.55 : 1)
            Spacer(minLength: 8)
            if let hint = item.hint {
                Text(hint)
                    .font(.system(size: detailSize + 0.5))
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.tertiary))
                    .lineLimit(1)
                    .layoutPriority(-1)
            }
            if let shortcut = item.shortcut {
                Text(shortcut)
                    .font(.system(size: detailSize + 1, weight: .medium, design: .rounded))
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.tertiary))
            }
            if isSelected, showsActionsHint {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.75))
                    .help("Actions (Tab)")
            }
        }
        .padding(.horizontal, 8)
        .frame(maxHeight: .infinity)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.accentColor.gradient)
            }
        }
        // The accent-filled selection always draws its text and icon as on a dark background.
        .environment(\.colorScheme, isSelected ? .dark : inheritedColorScheme)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// `s` with the matched characters in bold.
    private func highlighted(_ s: String, hits: [Int], isTitle: Bool) -> AttributedString {
        var out = AttributedString()
        let normal = isSelected ? Color.white.opacity(isTitle ? 1 : 0.8) : nil
        if hits.isEmpty {
            var a = AttributedString(s)
            if let normal { a.foregroundColor = normal } else if !isTitle { a.foregroundColor = .secondary }
            return a
        }
        let set = Set(hits)
        var run = ""
        var runHit = false
        func flush() {
            guard !run.isEmpty else { return }
            var a = AttributedString(run)
            if runHit {
                a.font = .system(size: isTitle ? titleSize : detailSize, weight: .bold)
                a.foregroundColor = isSelected ? .white : .primary
            } else if let normal {
                a.foregroundColor = normal
            } else if !isTitle {
                a.foregroundColor = .secondary
            }
            out += a
            run = ""
        }
        for (i, c) in s.enumerated() {
            let hit = set.contains(i)
            if hit != runHit {
                flush()
                runHit = hit
            }
            run.append(c)
        }
        flush()
        return out
    }
}

private struct PaletteIconView: View {
    let icon: PaletteIcon
    var size: CGFloat = 26
    /// Drawn on the selection's accent background: white glyph on a translucent tile.
    var onAccent = false

    var body: some View {
        switch icon {
        case .device(let kind, let dimmed):
            DeviceIconView(kind: kind, size: size, dimmed: dimmed)
        case .symbol(let name, let tint):
            RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                .fill(onAccent ? Color.white.opacity(0.22) : tint.opacity(0.16))
                .overlay {
                    Image(systemName: name)
                        .font(.system(size: size * 0.5, weight: .semibold))
                        .foregroundStyle(onAccent ? Color.white : tint)
                }
                .frame(width: size, height: size)
        }
    }
}
