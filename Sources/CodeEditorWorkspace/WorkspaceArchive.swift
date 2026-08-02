import Foundation

#if canImport(Darwin)
    import Darwin
#endif

/// Typed workspace directory archive used for transaction rollback materials (WSP-N05).
///
/// Honesty contract: this format is **not** a full POSIX matrix capture.
/// Supported entry kinds are regular files (bytes + POSIX mode + mtime), directories
/// (mode + mtime), and symlinks (link text, no-follow). ACLs, extended attributes,
/// hard links, sparse holes, resource forks, and ownership are **not** claimed.
public struct WorkspaceArchive: Sendable, Hashable, Codable {
    public enum EntryKind: String, Sendable, Hashable, Codable {
        case regularFile
        case directory
        case symlink
    }

    public struct Entry: Sendable, Hashable, Codable {
        public var relativePath: String
        public var kind: EntryKind
        /// File bytes (regular files only).
        public var dataBase64: String?
        /// Symlink destination text (symlinks only).
        public var linkDestination: String?
        public var posixPermissions: UInt16?
        public var modificationTime: TimeInterval?

        public init(
            relativePath: String,
            kind: EntryKind,
            dataBase64: String? = nil,
            linkDestination: String? = nil,
            posixPermissions: UInt16? = nil,
            modificationTime: TimeInterval? = nil
        ) {
            self.relativePath = relativePath
            self.kind = kind
            self.dataBase64 = dataBase64
            self.linkDestination = linkDestination
            self.posixPermissions = posixPermissions
            self.modificationTime = modificationTime
        }
    }

    public enum Format {
        public static let version = 1
        /// Full POSIX matrix (ACL/xattr/hardlink/sparse/resource-fork/ownership) is **not** claimed.
        public static let claimsFullPOSIXMatrix = false
        public static let supportedKinds: Set<EntryKind> = [.regularFile, .directory, .symlink]
    }

    public var formatVersion: Int
    public var entries: [Entry]
    public var supportedEntryKinds: [EntryKind]
    /// True only when every entry is within the supported matrix above.
    public var claimsByteExactMetadata: Bool

    public init(
        formatVersion: Int = Format.version,
        entries: [Entry],
        supportedEntryKinds: [EntryKind] = Array(Format.supportedKinds),
        claimsByteExactMetadata: Bool = false
    ) {
        self.formatVersion = formatVersion
        self.entries = entries
        self.supportedEntryKinds = supportedEntryKinds
        // Never claim full exactness; only supported kinds are preserved.
        self.claimsByteExactMetadata = claimsByteExactMetadata && !Format.claimsFullPOSIXMatrix
            ? false
            : claimsByteExactMetadata && Format.claimsFullPOSIXMatrix
    }

    /// Capture a directory tree without following symlinks.
    public static func capture(directory url: URL) throws -> WorkspaceArchive {
        var entries: [Entry] = []
        // Root directory itself is recreated on restore; capture children.
        try walkNoFollow(root: url, current: url, relative: "", into: &entries)
        return WorkspaceArchive(
            entries: entries,
            supportedEntryKinds: Array(Format.supportedKinds),
            claimsByteExactMetadata: false
        )
    }

    public static func restore(_ archive: WorkspaceArchive, to destination: URL) throws {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        // Directories → regular files → symlinks so `fileExists` on relative links works
        // and parents exist before children.
        let ordered = archive.entries.sorted { lhs, rhs in
            func rank(_ k: EntryKind) -> Int {
                switch k {
                case .directory: return 0
                case .regularFile: return 1
                case .symlink: return 2
                }
            }
            let lr = rank(lhs.kind)
            let rr = rank(rhs.kind)
            if lr != rr { return lr < rr }
            return lhs.relativePath < rhs.relativePath
        }
        for entry in ordered {
            let dest: URL
            if entry.relativePath.isEmpty {
                dest = destination
            } else {
                dest = destination.appendingPathComponent(entry.relativePath)
            }
            switch entry.kind {
            case .directory:
                try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
                try applyMetadata(entry, at: dest)
            case .regularFile:
                try FileManager.default.createDirectory(
                    at: dest.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let data = Data(base64Encoded: entry.dataBase64 ?? "") ?? Data()
                try data.write(to: dest, options: .atomic)
                try applyMetadata(entry, at: dest)
            case .symlink:
                try FileManager.default.createDirectory(
                    at: dest.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                if FileManager.default.fileExists(atPath: dest.path) {
                    try FileManager.default.removeItem(at: dest)
                }
                let target = entry.linkDestination ?? ""
                try FileManager.default.createSymbolicLink(
                    atPath: dest.path,
                    withDestinationPath: target
                )
            }
        }
    }

    /// Encode archive to durable bytes (JSON + length header).
    public func encodePayload() throws -> Data {
        try JSONEncoder().encode(self)
    }

    public static func decodePayload(_ data: Data) throws -> WorkspaceArchive {
        try JSONDecoder().decode(WorkspaceArchive.self, from: data)
    }

    // MARK: - Private

    private static func applyMetadata(_ entry: Entry, at url: URL) throws {
        var attrs: [FileAttributeKey: Any] = [:]
        if let mode = entry.posixPermissions {
            attrs[.posixPermissions] = NSNumber(value: mode)
        }
        if let mtime = entry.modificationTime {
            attrs[.modificationDate] = Date(timeIntervalSince1970: mtime)
        }
        if !attrs.isEmpty {
            try FileManager.default.setAttributes(attrs, ofItemAtPath: url.path)
        }
    }

    private static func walkNoFollow(
        root: URL,
        current: URL,
        relative: String,
        into entries: inout [Entry]
    ) throws {
        #if canImport(Darwin)
            let path = current.path
            var st = stat()
            // lstat — never follow.
            guard lstat(path, &st) == 0 else {
                throw WorkspaceFileSystemError.ioFailure("lstat failed: \(path)")
            }
            if !relative.isEmpty {
                if (st.st_mode & S_IFMT) == S_IFLNK {
                    let dest = try FileManager.default.destinationOfSymbolicLink(atPath: path)
                    entries.append(
                        Entry(
                            relativePath: relative,
                            kind: .symlink,
                            linkDestination: dest
                        )
                    )
                    return
                }
                if (st.st_mode & S_IFMT) == S_IFDIR {
                    entries.append(
                        Entry(
                            relativePath: relative,
                            kind: .directory,
                            posixPermissions: UInt16(st.st_mode & 0o7777),
                            modificationTime: TimeInterval(st.st_mtimespec.tv_sec)
                        )
                    )
                } else if (st.st_mode & S_IFMT) == S_IFREG {
                    let data = try Data(contentsOf: current, options: [.mappedIfSafe])
                    entries.append(
                        Entry(
                            relativePath: relative,
                            kind: .regularFile,
                            dataBase64: data.base64EncodedString(),
                            posixPermissions: UInt16(st.st_mode & 0o7777),
                            modificationTime: TimeInterval(st.st_mtimespec.tv_sec)
                        )
                    )
                    return
                } else {
                    // Unsupported special files — omit (do not claim exactness).
                    return
                }
            }
            if (st.st_mode & S_IFMT) == S_IFDIR {
                let children = try FileManager.default.contentsOfDirectory(
                    at: current,
                    includingPropertiesForKeys: nil,
                    options: [.skipsPackageDescendants]
                )
                for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                    let name = child.lastPathComponent
                    let childRel = relative.isEmpty ? name : relative + "/" + name
                    try walkNoFollow(root: root, current: child, relative: childRel, into: &entries)
                }
            }
        #else
            // Fallback: FileManager walk without symlink following for contents.
            let keys: [URLResourceKey] = [
                .isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey,
                .fileSizeKey, .contentModificationDateKey, .fileResourceIdentifierKey,
            ]
            if !relative.isEmpty {
                let values = try current.resourceValues(forKeys: Set(keys))
                if values.isSymbolicLink == true {
                    let dest = try FileManager.default.destinationOfSymbolicLink(atPath: current.path)
                    entries.append(
                        Entry(relativePath: relative, kind: .symlink, linkDestination: dest)
                    )
                    return
                }
                if values.isDirectory == true {
                    let attrs = try FileManager.default.attributesOfItem(atPath: current.path)
                    entries.append(
                        Entry(
                            relativePath: relative,
                            kind: .directory,
                            posixPermissions: (attrs[.posixPermissions] as? NSNumber).map { UInt16(truncating: $0) },
                            modificationTime: (attrs[.modificationDate] as? Date)?.timeIntervalSince1970
                        )
                    )
                } else if values.isRegularFile == true {
                    let data = try Data(contentsOf: current)
                    let attrs = try FileManager.default.attributesOfItem(atPath: current.path)
                    entries.append(
                        Entry(
                            relativePath: relative,
                            kind: .regularFile,
                            dataBase64: data.base64EncodedString(),
                            posixPermissions: (attrs[.posixPermissions] as? NSNumber).map { UInt16(truncating: $0) },
                            modificationTime: (attrs[.modificationDate] as? Date)?.timeIntervalSince1970
                        )
                    )
                    return
                }
            }
            let values = try current.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values.isDirectory == true, values.isSymbolicLink != true {
                let children = try FileManager.default.contentsOfDirectory(
                    at: current,
                    includingPropertiesForKeys: keys,
                    options: []
                )
                for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                    let name = child.lastPathComponent
                    let childRel = relative.isEmpty ? name : relative + "/" + name
                    try walkNoFollow(root: root, current: child, relative: childRel, into: &entries)
                }
            }
        #endif
    }
}
