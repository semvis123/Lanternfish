import Foundation
import LanternfishKit
import Observation
import SwiftUI

// MARK: - Items

enum PaletteSection: Int, CaseIterable {
    case top, quick, recent, devices, offline, commands, networks, actions

    var title: String {
        switch self {
        case .top: "Top Hit"
        case .quick: "Quick Actions"
        case .recent: "Recent"
        case .devices: "Devices"
        case .offline: "Offline Devices"
        case .commands: "Commands"
        case .networks: "Networks"
        case .actions: "Actions"
        }
    }
}

enum PaletteIcon {
    case device(DeviceKind, dimmed: Bool)
    case symbol(String, Color)
}

/// One row of the palette: something to show or run.
struct PaletteItem: Identifiable {
    /// Stable identity (used for recents), e.g. "cmd:rescan", "device:<network>:<key>".
    let id: String
    var title: String
    var subtitle: String?
    var icon: PaletteIcon
    /// Right-aligned detail, e.g. "Wi-Fi · 3d ago".
    var hint: String?
    /// Right-aligned key equivalent, e.g. "⌘R".
    var shortcut: String?
    /// Extra searchable text that isn't shown.
    var keywords: [String] = []
    /// Shown dimmed; running it does nothing. `disabledReason` replaces the subtitle.
    var disabledReason: String?
    /// Verb for the footer's ↩ hint ("Show", "Run", "Open").
    var verb = "Run"
    /// The default action.
    var perform: @MainActor () -> Void
    /// Further actions (Tab / → / ⌘↩). The first is the default action again.
    var actions: (@MainActor () -> [PaletteItem])?
    /// Record in the recents list when run.
    var isRecordable = true

    var isDisabled: Bool { disabledReason != nil }
}

/// An item placed in the visible list, with match highlights.
struct PaletteRow: Identifiable {
    let item: PaletteItem
    let section: PaletteSection
    var titleHits: [Int] = []
    var subtitleHits: [Int] = []
    var score = 0
    /// The query is exactly this item's IP / MAC / name.
    var isExact = false
    var id: String { "\(section.rawValue)|\(item.id)" }
}

/// Prepared search text for an item.
struct PaletteEntry {
    var item: PaletteItem
    let section: PaletteSection
    let fields: [FuzzyText]
    let weights: [Int]
    /// Lowercased strings that, typed in full, make this the top hit (IP, MAC, name).
    let exactKeys: Set<String>

    init(
        _ item: PaletteItem, section: PaletteSection, extra: [String?] = [], extraWeight: Int = 70,
        exactKeys: [String?] = []
    ) {
        self.item = item
        self.section = section
        self.exactKeys = Set(exactKeys.compactMap { $0?.lowercased() }.filter { !$0.isEmpty })
        var f = [FuzzyText(item.title), FuzzyText(item.subtitle ?? "")]
        var w = [100, 85]
        for e in extra + item.keywords.map(Optional.some) {
            guard let e, !e.isEmpty else { continue }
            f.append(FuzzyText(e))
            w.append(extraWeight)
        }
        fields = f
        weights = w
    }
}

// MARK: - Recents

/// A small frecency list of run items, persisted in user defaults.
private struct PaletteRecents {
    private struct Entry: Codable {
        var id: String
        var count: Int
        var last: Date
    }

    private static let key = "CommandPaletteRecents"
    private static let limit = 24
    private var entries: [Entry]

    init() {
        let data = UserDefaults.standard.data(forKey: Self.key)
        entries = data.flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []
    }

    /// Ids, most "frecent" first.
    var ranked: [String] {
        let now = Date()
        func rank(_ e: Entry) -> Double {
            let days = max(0, now.timeIntervalSince(e.last)) / 86_400
            return Double(min(e.count, 20)) / (1 + days) + (days < 1 / 24 ? 5 : 0)
        }
        return entries.sorted { rank($0) > rank($1) }.map(\.id)
    }

    mutating func record(_ id: String) {
        if let i = entries.firstIndex(where: { $0.id == id }) {
            entries[i].count += 1
            entries[i].last = Date()
        } else {
            entries.append(Entry(id: id, count: 1, last: Date()))
        }
        if entries.count > Self.limit {
            entries = Array(entries.sorted { $0.last > $1.last }.prefix(Self.limit))
        }
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}

// MARK: - Model

/// State of the ⌘K palette: the query, the filtered rows, keyboard selection and the
/// action sub-list. Search runs synchronously over a prepared index (built on open).
@MainActor
@Observable
final class CommandPaletteModel {
    let hub: NetworkHub

    var query = "" {
        didSet { if oldValue != query { refilter() } }
    }
    private(set) var rows: [PaletteRow] = []
    var selectedID: String?
    /// Set while showing the action sub-list of a root item.
    private(set) var actionsTarget: PaletteItem?
    /// Arbitrary-IP ping sheet ("Ping 1.2.3.4" for an address that isn't a known device).
    var hostPing: HostPingTarget?

    @ObservationIgnored var openSettings: (() -> Void)?
    @ObservationIgnored var close: (() -> Void)?

    @ObservationIgnored private var entries: [PaletteEntry] = []
    @ObservationIgnored private var byID: [String: PaletteEntry] = [:]
    @ObservationIgnored private var actionEntries: [PaletteEntry] = []
    @ObservationIgnored private var rootQuery = ""
    @ObservationIgnored private var recents = PaletteRecents()

    init(hub: NetworkHub) { self.hub = hub }

    // MARK: Lifecycle

    /// Called when the palette opens: rebuilds the index, keeps nothing from last time.
    func prepare(query initial: String = "") {
        actionsTarget = nil
        actionEntries = []
        rebuildIndex()
        query = initial
        refilter()
    }

    /// Re-reads devices and commands (e.g. a scan finished while the palette is open).
    func rebuildIndex() {
        entries = PaletteCatalog(hub: hub, model: self).entries()
        byID = Dictionary(entries.map { ($0.item.id, $0) }, uniquingKeysWith: { a, _ in a })
        if let target = actionsTarget, let fresh = byID[target.id] {
            actionsTarget = fresh.item
            actionEntries = (fresh.item.actions?() ?? []).map { PaletteEntry($0, section: .actions) }
        }
        refilter()
    }

    // MARK: Filtering

    private func refilter() {
        let previous = selectedID
        if actionsTarget != nil {
            rows = filter(actionEntries, query: FuzzyQuery(query), keepOrder: false)
        } else if query.trimmingCharacters(in: .whitespaces).isEmpty {
            rows = emptyQueryRows()
        } else {
            rows = searchRows()
        }
        // Same query (index refreshed): keep the selection. New query: start at the best result.
        if query == lastFilteredQuery, let previous, rows.contains(where: { $0.id == previous }) {
            selectedID = previous
        } else {
            selectedID = rows.first(where: { !$0.item.isDisabled })?.id ?? rows.first?.id
        }
        lastFilteredQuery = query
    }

    @ObservationIgnored private var lastFilteredQuery = ""

    private func filter(_ list: [PaletteEntry], query: FuzzyQuery, keepOrder: Bool) -> [PaletteRow] {
        var out: [PaletteRow] = []
        let typed = query.raw.trimmingCharacters(in: .whitespaces).lowercased()
        for e in list {
            guard let m = Fuzzy.match(query, fields: e.fields, weights: e.weights) else { continue }
            let exact = e.exactKeys.contains(typed)
            out.append(
                PaletteRow(
                    item: e.item, section: e.section, titleHits: m.positions[0] ?? [],
                    subtitleHits: m.positions[1] ?? [], score: m.score + (exact ? 200 : 0),
                    isExact: exact))
        }
        if !keepOrder, !query.isEmpty { out.sort { $0.score > $1.score } }
        return out
    }

    private func searchRows() -> [PaletteRow] {
        let q = FuzzyQuery(query)
        var bySection: [PaletteSection: [PaletteRow]] = [:]
        for row in filter(entries, query: q, keepOrder: false) {
            bySection[row.section, default: []].append(row)
        }
        let recentRank = Dictionary(recents.ranked.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        var sections: [(PaletteSection, [PaletteRow])] = []
        for (section, var list) in bySection {
            // Recently used items get a small boost; ties sort by title.
            for i in list.indices {
                if let r = recentRank[list[i].item.id] { list[i].score += max(0, 12 - r) }
            }
            list.sort {
                $0.score != $1.score
                    ? $0.score > $1.score
                    : $0.item.title.localizedStandardCompare($1.item.title) == .orderedAscending
            }
            sections.append((section, Array(list.prefix(section == .devices || section == .offline ? 60 : 12))))
        }
        sections.sort { a, b in
            let sa = a.1.first?.score ?? 0
            let sb = b.1.first?.score ?? 0
            // Online devices before offline ones unless the offline match is clearly better.
            if a.0 == .devices, b.0 == .offline { return sa + 25 >= sb }
            if a.0 == .offline, b.0 == .devices { return sa > sb + 25 }
            return sa != sb ? sa > sb : a.0.rawValue < b.0.rawValue
        }
        let quick = PaletteCatalog(hub: hub, model: self).quickActions(for: query)
            .map { PaletteRow(item: $0, section: .quick) }
        // A device named exactly (IP, MAC, name) leads as the top hit, then typed-host actions.
        var result: [PaletteRow] = []
        if let first = sections.first?.1.first, first.isExact {
            result.append(
                PaletteRow(
                    item: first.item, section: .top, titleHits: first.titleHits,
                    subtitleHits: first.subtitleHits, score: first.score, isExact: true))
            sections[0].1.removeFirst()
        }
        result += quick
        for (_, list) in sections { result += list }
        return result
    }

    private func emptyQueryRows() -> [PaletteRow] {
        var rows: [PaletteRow] = []
        var seen: Set<String> = []
        for id in recents.ranked {
            guard let e = byID[id], !e.item.isDisabled else { continue }
            rows.append(PaletteRow(item: e.item, section: .recent))
            seen.insert(id)
            if rows.count == 5 { break }
        }
        let suggested = ["cmd:rescan", "cmd:overview", hubViewToggleID, "cmd:offline", "cmd:speedtest", "cmd:settings"]
        for id in suggested where !seen.contains(id) {
            if let e = byID[id] { rows.append(PaletteRow(item: e.item, section: .commands)) }
        }
        for e in entries where e.section == .networks && !seen.contains(e.item.id) {
            rows.append(PaletteRow(item: e.item, section: .networks))
        }
        return rows
    }

    private var hubViewToggleID: String { Router.shared.viewMode == .table ? "cmd:view.map" : "cmd:view.table" }

    // MARK: Selection & running

    var selectedRow: PaletteRow? { rows.first { $0.id == selectedID } ?? rows.first }

    func moveSelection(_ delta: Int) {
        guard !rows.isEmpty else { return }
        let current = rows.firstIndex { $0.id == selectedID } ?? 0
        let next = (current + delta + rows.count) % rows.count
        selectedID = rows[next].id
    }

    /// ↩: runs the selected row's default action.
    func runSelected() {
        guard let row = selectedRow else { return }
        run(row.item)
    }

    /// ⌘↩: the selected root item's second action (e.g. "Open in Browser"), else its default.
    func runSecondary() {
        guard let row = selectedRow else { return }
        if actionsTarget == nil, let second = secondaryAction(for: row.item) {
            record(row.item)
            run(second, recordAs: nil)
        } else {
            run(row.item)
        }
    }

    func secondaryAction(for item: PaletteItem) -> PaletteItem? {
        guard actionsTarget == nil, let list = item.actions?() else { return nil }
        return list.dropFirst().first { !$0.isDisabled }
    }

    func run(_ item: PaletteItem) {
        if let target = actionsTarget {
            run(item, recordAs: target)
        } else {
            run(item, recordAs: item)
        }
    }

    private func run(_ item: PaletteItem, recordAs: PaletteItem?) {
        guard !item.isDisabled else {
            NSSound.beep()
            return
        }
        if let recordAs { record(recordAs) }
        close?()
        // Let the overlay go away first (sheets and focus changes behave better).
        DispatchQueue.main.async { item.perform() }
    }

    private func record(_ item: PaletteItem) {
        guard item.isRecordable else { return }
        recents.record(item.id)
    }

    /// Tab / →: shows the selected root item's actions.
    @discardableResult
    func showActions() -> Bool {
        guard actionsTarget == nil, let item = selectedRow?.item, let list = item.actions?(), !list.isEmpty else {
            return false
        }
        rootQuery = query
        actionsTarget = item
        actionEntries = list.map { PaletteEntry($0, section: .actions) }
        selectedID = nil
        query = ""
        refilter()
        selectedID = rows.first(where: { !$0.item.isDisabled })?.id
        return true
    }

    /// Esc / ← / ⌫ in the action list: back to the results.
    @discardableResult
    func leaveActions() -> Bool {
        guard let target = actionsTarget else { return false }
        actionsTarget = nil
        actionEntries = []
        query = rootQuery
        refilter()
        let match = rows.first { $0.item.id == target.id }
        selectedID = match?.id ?? rows.first?.id
        return true
    }
}

struct HostPingTarget: Identifiable {
    let ip: IPv4Address
    let store: ScanStore
    var id: IPv4Address { ip }
}
