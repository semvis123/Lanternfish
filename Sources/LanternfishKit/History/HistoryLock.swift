import Darwin
import Foundation

/// An exclusive, inter-process lock on a history directory (`flock` on `history.lock`), held for
/// the lifetime of the object. A second app instance can't take it and must not write history,
/// or the two would overwrite each other's changes.
public final class HistoryFileLock: @unchecked Sendable {
    public static let fileName = "history.lock"
    private let fd: Int32

    private init(fd: Int32) { self.fd = fd }

    /// Takes the lock without waiting. Nil when another process (or another lock object) holds it
    /// or the lock file can't be created.
    public static func acquire(in directory: URL) -> HistoryFileLock? {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appending(path: fileName).path
        let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return nil
        }
        return HistoryFileLock(fd: fd)
    }

    deinit {
        flock(fd, LOCK_UN)
        close(fd)
    }
}
