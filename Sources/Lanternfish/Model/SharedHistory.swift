import AppKit
import Foundation
import LanternfishKit
import Observation

/// The single owner and writer of `history.json`, shared by every `ScanStore`.
///
/// All access is on the main actor, so recordings from several stores interleave safely (each
/// mutation runs to completion). Saving snapshots the store (copy-on-write, so free) and encodes
/// and writes it on one serial background queue; quitting flushes synchronously.
///
/// Write frequency follows `Urgency`: user edits and finished scans are written within ~2 s;
/// scan progress and watch checks (which change history every few seconds) within 5 min.
///
/// Safety: only a missing file starts a fresh history; a file that couldn't be read blocks saving;
/// a lossy decode (or a newer file version) is backed up before the first save; a second running
/// instance (inter-process lock on `history.lock`) never writes.
@MainActor
@Observable
final class SharedHistory {
    /// The in-memory history. Mutate in place (`history.data.record(…)`), then call `changed(_:)`.
    var data: HistoryStore

    enum Urgency {
        /// User edits, finished scans: written within ~2 s.
        case soon
        /// Scan progress, watch checks, presence: written within 5 min (and on quit).
        case background

        var delay: TimeInterval { self == .soon ? 2 : 300 }
    }

    @ObservationIgnored private let directory: URL?
    /// Bumped by every `changed(_:)`.
    @ObservationIgnored private var revision = 0
    /// Last revision handed to the writer, and the last one written successfully.
    @ObservationIgnored private var queuedRevision = 0
    @ObservationIgnored private var writtenRevision = 0
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var saveDeadline: Date?
    @ObservationIgnored private let ioQueue = DispatchQueue(label: "Lanternfish.history", qos: .utility)
    @ObservationIgnored private var listeners: [ObjectIdentifier: () -> Void] = [:]
    /// False: never write (unreadable file, or another instance owns the directory).
    @ObservationIgnored private(set) var canSave = true
    /// The original file, to keep as a backup before the first save overwrites it.
    @ObservationIgnored private var pendingBackup: Data?
    @ObservationIgnored private var lock: HistoryFileLock?
    @ObservationIgnored private var lastCompaction = Date()
    private static let compactionInterval: TimeInterval = 6 * 3600

    /// `directory` nil keeps history in memory only (previews, tests).
    init(directory: URL?) {
        self.directory = directory
        guard let directory else {
            data = HistoryStore()
            return
        }
        lock = HistoryFileLock.acquire(in: directory)
        let clock = ContinuousClock()
        let start = clock.now
        let result = HistoryStore.loadResult(from: directory)
        data = result.store
        pendingBackup = result.backup
        canSave = result.canSave && lock != nil
        let loadTime = clock.now - start
        let deviceCount = data.networks.values.reduce(0) { $0 + $1.devices.count }
        alertsLog(
            "history: %@ (%ld networks, %ld devices) in %@", String(describing: result.status),
            data.networks.count, deviceCount, loadTime.formatted(.units(allowed: [.milliseconds])))
        if lock == nil { alertsLog("history: another instance holds %@; not saving", HistoryFileLock.fileName) }
        if !result.canSave { alertsLog("history: file unreadable; not saving to avoid overwriting it") }
        let report = data.compact()
        if !report.isEmpty {
            alertsLog(
                "history: compacted (dropped %ld networks, %ld devices; folded %ld)",
                report.droppedNetworks, report.droppedDevices, report.foldedDevices)
            changed(.soon)
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.save(waitUntilWritten: true) }
        }
    }

    /// Default location: LANTERNFISH_DATA_DIR if set, else ~/Library/Application Support/Lanternfish.
    static func defaultDirectory() -> URL {
        if let dir = DebugEnv.values["LANTERNFISH_DATA_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir, isDirectory: true)
        }
        return HistoryStore.defaultDirectory()
    }

    /// Notes that `data` changed and schedules a write (see `Urgency`).
    func changed(_ urgency: Urgency) {
        revision &+= 1
        scheduleSave(urgency)
    }

    private func scheduleSave(_ urgency: Urgency) {
        guard directory != nil, canSave else { return }
        let deadline = Date().addingTimeInterval(urgency.delay)
        // A sooner write already pending covers this one.
        if saveTask != nil, let pending = saveDeadline, pending <= deadline { return }
        saveTask?.cancel()
        saveDeadline = deadline
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(urgency.delay))
            guard !Task.isCancelled, let self else { return }
            self.saveTask = nil
            self.saveDeadline = nil
            self.save()
        }
    }

    /// Writes pending changes now (also on quit). Encoding and writing run on the I/O queue.
    func save(waitUntilWritten: Bool = false) {
        saveTask?.cancel()
        saveTask = nil
        saveDeadline = nil
        guard let directory, canSave, revision != queuedRevision else { return }
        if Date().timeIntervalSince(lastCompaction) > Self.compactionInterval {
            lastCompaction = Date()
            data.compact()
        }
        let snapshot = data
        let rev = revision
        let backup = pendingBackup
        pendingBackup = nil
        queuedRevision = rev
        let work: @Sendable () -> Bool = {
            do {
                if let backup {
                    let name = try HistoryStore.writeBackup(backup, to: directory)
                    alertsLog("history: kept the previous file as %@", name)
                }
                try HistoryStore.write(try snapshot.encoded(), to: directory)
                return true
            } catch {
                alertsLog("history: save failed: %@", error.localizedDescription)
                return false
            }
        }
        if waitUntilWritten {
            finished(rev, ok: ioQueue.sync(execute: work), backup: backup)
        } else {
            ioQueue.async { [weak self] in
                let ok = work()
                Task { @MainActor in self?.finished(rev, ok: ok, backup: backup) }
            }
        }
    }

    private func finished(_ rev: Int, ok: Bool, backup: Data?) {
        if ok {
            writtenRevision = max(writtenRevision, rev)
            return
        }
        // Not written: retry later (keeping the backup for that attempt).
        if pendingBackup == nil { pendingBackup = backup }
        if queuedRevision == rev { queuedRevision = writtenRevision }
        scheduleSave(.background)
    }

    // MARK: Cross-store edits

    /// `owner`'s callback runs when another store edits history by hand (rename, forget…), so
    /// stores showing the same network can refresh their device lists.
    func addListener(_ owner: AnyObject, _ body: @escaping () -> Void) {
        listeners[ObjectIdentifier(owner)] = body
    }

    func removeListener(_ owner: AnyObject) {
        listeners[ObjectIdentifier(owner)] = nil
    }

    /// Called after a user edit: notify every other store, then save soon.
    func edited(by owner: AnyObject) {
        let me = ObjectIdentifier(owner)
        for (id, body) in listeners where id != me { body() }
        changed(.soon)
    }
}
