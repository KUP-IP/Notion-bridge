// CalendarRegistryCoordinatorTrust.swift — filesystem trust boundary for the disabled pairing coordinator

import CryptoKit
import Darwin
import Foundation

package enum CalendarRegistryCoordinatorTrustError: Error, LocalizedError, Equatable {
    case unsafe(String)

    package var errorDescription: String? {
        switch self {
        case .unsafe(let reason): return "calendar-registry coordinator is unsafe: \(reason)"
        }
    }
}

package struct CalendarRegistryFilesystemIdentity: Sendable, Equatable {
    package let resolvedPath: String
    package let device: UInt64
    package let inode: UInt64

    package var namespace: String {
        let canonical = "\(device):\(inode):\(resolvedPath)"
        return "local-" + SHA256.hash(data: Data(canonical.utf8))
            .prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}

package enum CalendarRegistryCoordinatorTrust {
    private static let ownerOnlyDirectory = mode_t(S_IRWXU)
    private static let ownerOnlyFile = mode_t(S_IRUSR | S_IWUSR)

    package static func prepareDirectory(_ requestedURL: URL) throws -> (url: URL, identity: CalendarRegistryFilesystemIdentity) {
        let standardized = requestedURL.standardizedFileURL
        try rejectSymlinkComponents(standardized)
        let resolved = standardized.resolvingSymlinksInPath()
        try FileManager.default.createDirectory(
            at: resolved,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int(ownerOnlyDirectory))]
        )
        var info = stat()
        guard lstat(resolved.path, &info) == 0 else { throw failure("lstat directory \(resolved.path)") }
        guard (info.st_mode & S_IFMT) == S_IFDIR else {
            throw CalendarRegistryCoordinatorTrustError.unsafe("not a directory: \(resolved.path)")
        }
        guard info.st_uid == geteuid() else {
            throw CalendarRegistryCoordinatorTrustError.unsafe("directory is not owned by the current user: \(resolved.path)")
        }
        guard chmod(resolved.path, ownerOnlyDirectory) == 0 else { throw failure("chmod directory \(resolved.path)") }
        var verified = stat()
        guard lstat(resolved.path, &verified) == 0,
              (verified.st_mode & S_IFMT) == S_IFDIR,
              verified.st_uid == geteuid(),
              (verified.st_mode & 0o077) == 0 else {
            throw CalendarRegistryCoordinatorTrustError.unsafe("directory permissions or identity changed: \(resolved.path)")
        }
        let values = try resolved.resourceValues(forKeys: [.volumeIsLocalKey])
        guard values.volumeIsLocal == true else {
            throw CalendarRegistryCoordinatorTrustError.unsafe("coordinator volume is not local: \(resolved.path)")
        }
        var backupValues = URLResourceValues()
        backupValues.isExcludedFromBackup = true
        var mutable = resolved
        try? mutable.setResourceValues(backupValues)
        return (resolved, identity(path: resolved.path, info: verified))
    }

    package static func prepareRegularFile(_ requestedURL: URL) throws -> CalendarRegistryFilesystemIdentity {
        let url = requestedURL.standardizedFileURL
        let fd = Darwin.open(url.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, ownerOnlyFile)
        guard fd >= 0 else { throw failure("open file \(url.path)") }
        defer { _ = close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw failure("fstat file \(url.path)") }
        try validateRegular(info, path: url.path)
        guard fchmod(fd, ownerOnlyFile) == 0 else { throw failure("chmod file \(url.path)") }
        guard fsync(fd) == 0 else { throw failure("fsync file \(url.path)") }
        return identity(path: url.path, info: info)
    }

    package static func validateRegularFileIfPresent(_ requestedURL: URL) throws -> CalendarRegistryFilesystemIdentity? {
        let url = requestedURL.standardizedFileURL
        var info = stat()
        if lstat(url.path, &info) != 0 {
            if errno == ENOENT { return nil }
            throw failure("lstat file \(url.path)")
        }
        try validateRegular(info, path: url.path)
        guard chmod(url.path, ownerOnlyFile) == 0 else { throw failure("chmod file \(url.path)") }
        var verified = stat()
        guard lstat(url.path, &verified) == 0 else { throw failure("re-lstat file \(url.path)") }
        try validateRegular(verified, path: url.path)
        return identity(path: url.path, info: verified)
    }

    package static func requireStable(
        _ expected: CalendarRegistryFilesystemIdentity,
        actual: CalendarRegistryFilesystemIdentity,
        label: String
    ) throws {
        guard expected.device == actual.device, expected.inode == actual.inode else {
            throw CalendarRegistryCoordinatorTrustError.unsafe("\(label) device/inode changed during bootstrap")
        }
    }

    package static func syncDirectory(_ requestedURL: URL) throws {
        let url = requestedURL.standardizedFileURL
        let fd = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_DIRECTORY)
        guard fd >= 0 else { throw failure("open directory for fsync \(url.path)") }
        defer { _ = close(fd) }
        guard fsync(fd) == 0 else { throw failure("fsync directory \(url.path)") }
    }


    private static func rejectSymlinkComponents(_ url: URL) throws {
        let standardized = url.standardizedFileURL
        let anchors = [
            FileManager.default.temporaryDirectory.standardizedFileURL,
            FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        ]
        let anchor = anchors
            .filter { standardized.path == $0.path || standardized.path.hasPrefix($0.path + "/") }
            .max { $0.path.count < $1.path.count }
            ?? URL(fileURLWithPath: "/", isDirectory: true)
        let anchorPath = anchor.path == "/" ? "" : anchor.path
        let relative = String(standardized.path.dropFirst(anchorPath.count))
        var current = anchor.resolvingSymlinksInPath()
        for component in relative.split(separator: "/").map(String.init) {
            current.appendPathComponent(component)
            var info = stat()
            if lstat(current.path, &info) != 0 {
                if errno == ENOENT { break }
                throw failure("lstat path component \(current.path)")
            }
            if (info.st_mode & S_IFMT) == S_IFLNK {
                throw CalendarRegistryCoordinatorTrustError.unsafe("symlinked path component: \(current.path)")
            }
        }
    }

    private static func validateRegular(_ info: stat, path: String) throws {
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            throw CalendarRegistryCoordinatorTrustError.unsafe("not a regular file: \(path)")
        }
        guard info.st_uid == geteuid() else {
            throw CalendarRegistryCoordinatorTrustError.unsafe("file is not owned by the current user: \(path)")
        }
        guard info.st_nlink == 1 else {
            throw CalendarRegistryCoordinatorTrustError.unsafe("file link count is not one: \(path)")
        }
        guard (info.st_mode & 0o077) == 0 else {
            throw CalendarRegistryCoordinatorTrustError.unsafe("file permissions expose group or other access: \(path)")
        }
    }

    private static func identity(path: String, info: stat) -> CalendarRegistryFilesystemIdentity {
        CalendarRegistryFilesystemIdentity(
            resolvedPath: path,
            device: UInt64(info.st_dev),
            inode: UInt64(info.st_ino)
        )
    }

    private static func failure(_ operation: String) -> CalendarRegistryCoordinatorTrustError {
        let code = errno
        return .unsafe("\(operation) errno=\(code): \(String(cString: strerror(code)))")
    }
}
