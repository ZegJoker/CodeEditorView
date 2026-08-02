import Foundation

#if canImport(Darwin)
    import Darwin
#endif

/// Errors from descriptor-relative filesystem operations (WSP-N08).
public enum DescriptorRelativeIOError: Error, Sendable, Equatable {
    case openFailed(String)
    case operationFailed(String)
    case notSupported
    case symlinkRefused(String)
    case pathEscape(String)
}

/// Directory-fd relative IO with no-follow semantics for security boundaries (WSP-N08).
public enum DescriptorRelativeIO: Sendable {
    #if canImport(Darwin)
        public static let O_RDONLY = Darwin.O_RDONLY
        public static let O_WRONLY = Darwin.O_WRONLY
        public static let O_RDWR = Darwin.O_RDWR
        public static let O_CREAT = Darwin.O_CREAT
        public static let O_EXCL = Darwin.O_EXCL
        public static let O_TRUNC = Darwin.O_TRUNC
        public static let O_DIRECTORY = Darwin.O_DIRECTORY
        public static let O_NOFOLLOW = Darwin.O_NOFOLLOW
        public static let O_CLOEXEC = Darwin.O_CLOEXEC
    #else
        public static let O_RDONLY = 0
        public static let O_WRONLY = 1
        public static let O_RDWR = 2
        public static let O_CREAT = 0x200
        public static let O_EXCL = 0x800
        public static let O_TRUNC = 0x400
        public static let O_DIRECTORY = 0
        public static let O_NOFOLLOW = 0
        public static let O_CLOEXEC = 0
    #endif

    /// Open a directory as a file descriptor (CLOEXEC + DIRECTORY when available).
    public static func openDirectory(at url: URL) throws -> Int32 {
        #if canImport(Darwin)
            let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            guard fd >= 0 else {
                throw DescriptorRelativeIOError.openFailed(String(cString: strerror(errno)))
            }
            return fd
        #else
            throw DescriptorRelativeIOError.notSupported
        #endif
    }

    public static func close(_ fd: Int32) {
        #if canImport(Darwin)
            _ = Darwin.close(fd)
        #endif
    }

    /// `openat` relative to `dirfd` with caller-supplied flags (include `O_NOFOLLOW` for no-follow).
    public static func openAt(dirfd: Int32, relativePath: String, flags: Int32, mode: mode_t = 0o644) throws -> Int32 {
        #if canImport(Darwin)
            try validateRelativeComponentPath(relativePath)
            let fd = openat(dirfd, relativePath, flags | O_CLOEXEC, mode)
            guard fd >= 0 else {
                let err = errno
                if err == ELOOP || err == EMLINK {
                    throw DescriptorRelativeIOError.symlinkRefused(relativePath)
                }
                throw DescriptorRelativeIOError.openFailed(String(cString: strerror(err)))
            }
            return fd
        #else
            throw DescriptorRelativeIOError.notSupported
        #endif
    }

    public static func unlinkAt(dirfd: Int32, relativePath: String, directory: Bool = false) throws {
        #if canImport(Darwin)
            try validateRelativeComponentPath(relativePath)
            let flags: Int32 = directory ? AT_REMOVEDIR : 0
            // AT_SYMLINK_NOFOLLOW is for fstatat/fchmodat; unlinkat removes the link itself.
            let rc = unlinkat(dirfd, relativePath, flags)
            guard rc == 0 else {
                throw DescriptorRelativeIOError.operationFailed(String(cString: strerror(errno)))
            }
        #else
            throw DescriptorRelativeIOError.notSupported
        #endif
    }

    public static func renameAt(
        fromDirfd: Int32,
        fromRelative: String,
        toDirfd: Int32,
        toRelative: String
    ) throws {
        #if canImport(Darwin)
            try validateRelativeComponentPath(fromRelative)
            try validateRelativeComponentPath(toRelative)
            let rc = renameat(fromDirfd, fromRelative, toDirfd, toRelative)
            guard rc == 0 else {
                throw DescriptorRelativeIOError.operationFailed(String(cString: strerror(errno)))
            }
        #else
            throw DescriptorRelativeIOError.notSupported
        #endif
    }

    public static func mkdirAt(dirfd: Int32, relativePath: String, mode: mode_t = 0o755) throws {
        #if canImport(Darwin)
            try validateRelativeComponentPath(relativePath)
            let rc = mkdirat(dirfd, relativePath, mode)
            guard rc == 0 else {
                throw DescriptorRelativeIOError.operationFailed(String(cString: strerror(errno)))
            }
        #else
            throw DescriptorRelativeIOError.notSupported
        #endif
    }

    /// fstatat with AT_SYMLINK_NOFOLLOW.
    public static func statAt(dirfd: Int32, relativePath: String) throws -> stat {
        #if canImport(Darwin)
            try validateRelativeComponentPath(relativePath)
            var st = stat()
            let rc = fstatat(dirfd, relativePath, &st, AT_SYMLINK_NOFOLLOW)
            guard rc == 0 else {
                throw DescriptorRelativeIOError.operationFailed(String(cString: strerror(errno)))
            }
            return st
        #else
            throw DescriptorRelativeIOError.notSupported
        #endif
    }

    /// Write bytes to a new file via openat(O_CREAT|O_EXCL|O_NOFOLLOW) + write + fsync.
    public static func writeNewFile(dirfd: Int32, name: String, contents: Data, mode: mode_t = 0o644) throws {
        #if canImport(Darwin)
            try validateRelativeComponentPath(name)
            let fd = try openAt(
                dirfd: dirfd,
                relativePath: name,
                flags: O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
                mode: mode
            )
            defer { close(fd) }
            if !contents.isEmpty {
                let written = contents.withUnsafeBytes { buf -> Int in
                    guard let base = buf.baseAddress else { return -1 }
                    return write(fd, base, buf.count)
                }
                guard written == contents.count else {
                    throw DescriptorRelativeIOError.operationFailed("short write")
                }
            }
            _ = fsync(fd)
        #else
            throw DescriptorRelativeIOError.notSupported
        #endif
    }

    /// Open nested relative path component-by-component with O_NOFOLLOW | O_DIRECTORY for parents.
    public static func openNestedDirectory(rootDirfd: Int32, segments: [String]) throws -> Int32 {
        #if canImport(Darwin)
            var current = rootDirfd
            var owned: [Int32] = []
            defer {
                // Close intermediate fds, not the root (caller owns root).
                for fd in owned where fd != rootDirfd {
                    close(fd)
                }
            }
            for (index, segment) in segments.enumerated() {
                try validateRelativeComponentPath(segment)
                let isLast = index == segments.count - 1
                let flags = O_RDONLY | O_CLOEXEC | O_NOFOLLOW | (isLast ? O_DIRECTORY : O_DIRECTORY)
                let next = openat(current, segment, flags)
                guard next >= 0 else {
                    let err = errno
                    if err == ELOOP || err == EMLINK {
                        throw DescriptorRelativeIOError.symlinkRefused(segment)
                    }
                    throw DescriptorRelativeIOError.openFailed(String(cString: strerror(err)))
                }
                if current != rootDirfd {
                    close(current)
                }
                current = next
                owned.append(next)
            }
            // Transfer ownership of final fd out — clear owned so defer doesn't close it.
            if let last = owned.last {
                owned.removeAll()
                return last
            }
            return rootDirfd
        #else
            throw DescriptorRelativeIOError.notSupported
        #endif
    }

    /// Resolve parent dirfd + leaf name for a relative path under rootDirfd.
    public static func parentDirfdAndName(
        rootDirfd: Int32,
        relativePath: String
    ) throws -> (dirfd: Int32, name: String, ownsDirfd: Bool) {
        let parts = relativePath.split(separator: "/").map(String.init).filter { !$0.isEmpty }
        guard let name = parts.last else {
            throw DescriptorRelativeIOError.pathEscape(relativePath)
        }
        if parts.count == 1 {
            return (rootDirfd, name, false)
        }
        let parentSegments = Array(parts.dropLast())
        let dirfd = try openNestedDirectory(rootDirfd: rootDirfd, segments: parentSegments)
        return (dirfd, name, true)
    }

    private static func validateRelativeComponentPath(_ path: String) throws {
        if path.isEmpty || path.hasPrefix("/") || path.contains("\0") {
            throw DescriptorRelativeIOError.pathEscape(path)
        }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        for part in parts {
            if part.isEmpty || part == "." || part == ".." {
                throw DescriptorRelativeIOError.pathEscape(path)
            }
        }
    }
}
