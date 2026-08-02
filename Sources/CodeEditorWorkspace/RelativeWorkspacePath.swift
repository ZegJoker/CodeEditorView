import Foundation

/// Symlink traversal policy for workspace path resolution (audit §8.3).
public enum WorkspaceSymlinkPolicy: Sendable, Hashable, Codable {
    /// Refuse any path whose symlink-resolved form leaves the root (default).
    case denyEscape
    /// Allow symlinks only when the resolved target stays under the root.
    case allowIfStaysInRoot
    /// Follow symlinks without containment check (unsafe; tests only).
    case allowAll
}

/// Options for resolving paths under a workspace root.
public struct WorkspacePathResolveOptions: Sendable, Hashable, Codable {
    public var symlinkPolicy: WorkspaceSymlinkPolicy
    /// When true, require the resolved path to share the root's volume/device ID.
    public var requireSameVolume: Bool
    /// Prefer `openat`/`unlinkat`/`renameat` with `O_NOFOLLOW` for mutations (WSP-N08).
    public var useDescriptorRelativeIO: Bool

    public init(
        symlinkPolicy: WorkspaceSymlinkPolicy = .denyEscape,
        requireSameVolume: Bool = false,
        useDescriptorRelativeIO: Bool = true
    ) {
        self.symlinkPolicy = symlinkPolicy
        self.requireSameVolume = requireSameVolume
        self.useDescriptorRelativeIO = useDescriptorRelativeIO
    }

    public static let `default` = WorkspacePathResolveOptions()
}

/// Typed relative workspace path — validated segments only (audit §8.3).
///
/// Never constructed from unvalidated string joins. Empty path = workspace root.
public struct RelativeWorkspacePath: Sendable, Hashable, Codable, CustomStringConvertible {
    /// Path segments (no `/`, no `.`/`..`, no NUL).
    public let segments: [String]

    /// Empty path representing the workspace root itself.
    public static let root = RelativeWorkspacePath(validatedSegments: [])

    public var isRoot: Bool { segments.isEmpty }

    public var description: String {
        segments.joined(separator: "/")
    }

    /// Slash-joined relative path (empty for root).
    public var pathString: String { description }

    private init(validatedSegments: [String]) {
        self.segments = validatedSegments
    }

    /// Parse and validate a relative path string.
    public init(validating path: String) throws {
        if path.isEmpty {
            self.segments = []
            return
        }
        try WorkspacePathSecurity.validateRelativePath(path)
        // validateRelativePath already rejects empty segments, `.`, `..`, NUL, abs.
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !parts.contains(where: { $0.isEmpty }) else {
            throw WorkspaceFileSystemError.invalidName
        }
        for part in parts {
            if part == "." || part == ".." {
                throw WorkspaceFileSystemError.invalidName
            }
        }
        self.segments = parts
    }

    /// Append a single validated name component.
    public func appending(_ name: String) throws -> RelativeWorkspacePath {
        try WorkspacePathSecurity.validateRelativePath(name)
        guard !name.contains("/"), name != ".", name != ".." else {
            throw WorkspaceFileSystemError.invalidName
        }
        return RelativeWorkspacePath(validatedSegments: segments + [name])
    }

    /// Parent path, or `nil` when already at root.
    public var parent: RelativeWorkspacePath? {
        guard !segments.isEmpty else { return nil }
        return RelativeWorkspacePath(validatedSegments: Array(segments.dropLast()))
    }

    public var lastComponent: String? {
        segments.last
    }
}
