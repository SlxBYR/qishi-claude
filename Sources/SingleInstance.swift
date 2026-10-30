import Foundation
import Darwin

/// Hold the descriptor for the entire process lifetime. The kernel releases the
/// lock after both normal exits and crashes; never unlink a live lock file.
final class SingleInstanceLock {
    private var descriptor: Int32 = -1
    let url: URL

    init(url: URL) { self.url = url }

    func acquire() throws -> Bool {
        precondition(descriptor == -1)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let fd = Darwin.open(url.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let failure = errno
            close(fd)
            if failure == EWOULDBLOCK { return false }
            throw POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO)
        }
        descriptor = fd
        return true
    }

    deinit { if descriptor >= 0 { close(descriptor) } }
}
