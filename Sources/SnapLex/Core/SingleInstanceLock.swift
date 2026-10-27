import Darwin
import Foundation

/// An OS-held file lock elects one owner across simultaneous launches and
/// copies of the app. The file remains in place; the kernel releases its lock
/// when the process exits, including after a crash.
final class SingleInstanceLock {
    enum Acquisition {
        case acquired(SingleInstanceLock)
        case alreadyRunning(processIdentifier: pid_t?)
    }

    private let descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        close(descriptor)
    }

    static var applicationLockURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SnapLex", isDirectory: true)
            .appendingPathComponent("instance.lock")
    }

    static func acquire(at url: URL) throws -> Acquisition {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw posixError() }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            defer { close(descriptor) }
            guard code == EWOULDBLOCK || code == EAGAIN else { throw posixError(code) }
            var buffer = [UInt8](repeating: 0, count: 32)
            let count = pread(descriptor, &buffer, buffer.count, 0)
            let owner = count > 0 ? pid_t(String(decoding: buffer.prefix(count), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) : nil
            return .alreadyRunning(processIdentifier: owner)
        }

        // The PID is only an activation hint. Ownership is decided exclusively
        // by flock, so stale PID files never prevent a clean restart.
        let pid = Array("\(getpid())\n".utf8)
        guard ftruncate(descriptor, 0) == 0,
              pid.withUnsafeBytes({ pwrite(descriptor, $0.baseAddress, $0.count, 0) }) == pid.count else {
            let error = posixError()
            close(descriptor)
            throw error
        }
        return .acquired(SingleInstanceLock(descriptor: descriptor))
    }

    private static func posixError(_ code: Int32 = errno) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }
}
