// CalendarRegistryProcessLock.swift — process-shared ownership for calendar-registry effects

import CryptoKit
import Darwin
import Foundation

public enum CalendarRegistryProcessLockError: Error, LocalizedError, Equatable {
    case operationActive(String)
    case storageFailure(String)
    case releaseFailure(String)

    public var errorDescription: String? {
        switch self {
        case .operationActive(let key):
            return "calendar-registry operation is already active in another process: \(key)"
        case .storageFailure(let reason):
            return "calendar-registry process lock failed: \(reason)"
        case .releaseFailure(let reason):
            return "calendar-registry process lock release failed: \(reason)"
        }
    }
}

public protocol CalendarRegistryProcessLockHandle: AnyObject, Sendable {
    var idempotencyKey: String { get }
    func release() throws
}

public protocol CalendarRegistryProcessLocking: Sendable {
    var coordinatorNamespace: String { get }
    func acquire(idempotencyKey: String) throws -> any CalendarRegistryProcessLockHandle
}

public final class FileCalendarRegistryProcessLockHandle: CalendarRegistryProcessLockHandle, @unchecked Sendable {
    public let idempotencyKey: String
    public let fileURL: URL

    private let stateLock = NSLock()
    private var descriptor: Int32

    fileprivate init(idempotencyKey: String, fileURL: URL, descriptor: Int32) {
        self.idempotencyKey = idempotencyKey
        self.fileURL = fileURL
        self.descriptor = descriptor
    }

    public func release() throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard descriptor >= 0 else { return }
        let fd = descriptor
        descriptor = -1
        var failures: [String] = []
        if flock(fd, LOCK_UN) != 0 {
            failures.append("flock unlock errno=\(errno): \(String(cString: strerror(errno)))")
        }
        if close(fd) != 0 {
            failures.append("close errno=\(errno): \(String(cString: strerror(errno)))")
        }
        if !failures.isEmpty {
            throw CalendarRegistryProcessLockError.releaseFailure(failures.joined(separator: " | "))
        }
    }

    deinit {
        stateLock.lock()
        let fd = descriptor
        descriptor = -1
        stateLock.unlock()
        if fd >= 0 {
            _ = flock(fd, LOCK_UN)
            _ = close(fd)
        }
    }
}

public struct FileCalendarRegistryProcessLockCoordinator: CalendarRegistryProcessLocking, Sendable {
    public let rootURL: URL
    public let coordinatorNamespace: String

    public init(rootURL: URL) throws {
        let standardized = rootURL.standardizedFileURL
        self.rootURL = standardized
        self.coordinatorNamespace = "local-" + SHA256.hash(data: Data(standardized.path.utf8))
            .prefix(12).map { String(format: "%02x", $0) }.joined()
        try FileManager.default.createDirectory(
            at: standardized,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try Self.validateRoot(standardized)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutable = standardized
        try? mutable.setResourceValues(values)
    }

    private static func validateRoot(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            throw CalendarRegistryProcessLockError.storageFailure(
                "lstat \(url.path) errno=\(errno): \(String(cString: strerror(errno)))"
            )
        }
        guard (info.st_mode & S_IFMT) == S_IFDIR else {
            throw CalendarRegistryProcessLockError.storageFailure("lock root is not a directory: \(url.path)")
        }
        guard info.st_uid == geteuid() else {
            throw CalendarRegistryProcessLockError.storageFailure("lock root is not owned by the current user: \(url.path)")
        }
        if (info.st_mode & 0o077) != 0 {
            guard chmod(url.path, mode_t(S_IRWXU)) == 0 else {
                throw CalendarRegistryProcessLockError.storageFailure(
                    "chmod lock root errno=\(errno): \(String(cString: strerror(errno)))"
                )
            }
            var repaired = stat()
            guard lstat(url.path, &repaired) == 0, (repaired.st_mode & 0o077) == 0 else {
                throw CalendarRegistryProcessLockError.storageFailure(
                    "lock root permissions remain unsafe after repair: \(url.path)"
                )
            }
        }
    }

    public func lockURL(idempotencyKey: String) -> URL {
        let digest = SHA256.hash(data: Data(idempotencyKey.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return rootURL.appendingPathComponent("\(digest).lock", isDirectory: false)
    }

    public func acquire(idempotencyKey: String) throws -> any CalendarRegistryProcessLockHandle {
        guard !idempotencyKey.isEmpty else {
            throw CalendarRegistryProcessLockError.storageFailure("idempotency key is empty")
        }
        let url = lockURL(idempotencyKey: idempotencyKey)
        let flags = O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW
        let fd = Darwin.open(url.path, flags, mode_t(S_IRUSR | S_IWUSR))
        guard fd >= 0 else {
            throw CalendarRegistryProcessLockError.storageFailure(
                "open \(url.path) errno=\(errno): \(String(cString: strerror(errno)))"
            )
        }
        var info = stat()
        guard fstat(fd, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == geteuid(),
              info.st_nlink == 1 else {
            let captured = errno
            _ = close(fd)
            throw CalendarRegistryProcessLockError.storageFailure(
                "unsafe lock file \(url.path) errno=\(captured): \(String(cString: strerror(captured)))"
            )
        }
        guard fchmod(fd, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
            let captured = errno
            _ = close(fd)
            throw CalendarRegistryProcessLockError.storageFailure(
                "chmod lock file errno=\(captured): \(String(cString: strerror(captured)))"
            )
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let captured = errno
            _ = close(fd)
            if captured == EWOULDBLOCK || captured == EAGAIN {
                throw CalendarRegistryProcessLockError.operationActive(idempotencyKey)
            }
            throw CalendarRegistryProcessLockError.storageFailure(
                "flock \(url.path) errno=\(captured): \(String(cString: strerror(captured)))"
            )
        }

        let owner = "pid=\(ProcessInfo.processInfo.processIdentifier) key=\(idempotencyKey)\n"
        if ftruncate(fd, 0) != 0 || owner.withCString({ write(fd, $0, strlen($0)) }) < 0 {
            let captured = errno
            _ = flock(fd, LOCK_UN)
            _ = close(fd)
            throw CalendarRegistryProcessLockError.storageFailure(
                "write lock owner errno=\(captured): \(String(cString: strerror(captured)))"
            )
        }
        guard fsync(fd) == 0 else {
            let captured = errno
            _ = flock(fd, LOCK_UN)
            _ = close(fd)
            throw CalendarRegistryProcessLockError.storageFailure(
                "fsync lock owner errno=\(captured): \(String(cString: strerror(captured)))"
            )
        }
        return FileCalendarRegistryProcessLockHandle(
            idempotencyKey: idempotencyKey,
            fileURL: url,
            descriptor: fd
        )
    }
}

public final class InMemoryCalendarRegistryProcessLockCoordinator: CalendarRegistryProcessLocking, @unchecked Sendable {
    public static let shared = InMemoryCalendarRegistryProcessLockCoordinator()

    public let coordinatorNamespace: String
    private let stateLock = NSLock()
    private var active: Set<String> = []

    public init(coordinatorNamespace: String = "in-memory-test") {
        self.coordinatorNamespace = coordinatorNamespace
    }

    public func acquire(idempotencyKey: String) throws -> any CalendarRegistryProcessLockHandle {
        stateLock.lock()
        let inserted = active.insert(idempotencyKey).inserted
        stateLock.unlock()
        guard inserted else { throw CalendarRegistryProcessLockError.operationActive(idempotencyKey) }
        return InMemoryHandle(idempotencyKey: idempotencyKey) { [weak self] key in
            self?.stateLock.lock()
            self?.active.remove(key)
            self?.stateLock.unlock()
        }
    }

    private final class InMemoryHandle: CalendarRegistryProcessLockHandle, @unchecked Sendable {
        let idempotencyKey: String
        private let stateLock = NSLock()
        private var releaseBody: (@Sendable (String) -> Void)?

        init(idempotencyKey: String, releaseBody: @escaping @Sendable (String) -> Void) {
            self.idempotencyKey = idempotencyKey
            self.releaseBody = releaseBody
        }

        func release() throws {
            stateLock.lock()
            let body = releaseBody
            releaseBody = nil
            stateLock.unlock()
            body?(idempotencyKey)
        }

        deinit { try? release() }
    }
}
