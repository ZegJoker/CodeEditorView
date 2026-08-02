import CodeEditorDocuments
import Foundation

#if canImport(Darwin)
    import Darwin
#endif

/// Typed relative-path security for workspace FS (audit §8.3 / WSP-003).
///
/// Rejects absolute paths, empty segments, `.` / `..`, NUL, platform separators,
/// and string-prefix false friends. Prefer component-join under an opened root —
/// never implement security with unvalidated substring checks alone.
public enum WorkspacePathSecurity: Sendable {
    /// Returns true if `url` is strictly under or equal to `root` after resolving symlinks
    /// using **path-component** comparison (not string prefix alone).
    public static func isContained(url: URL, inRoot root: URL) -> Bool {
        let resolvedURL = url.resolvingSymlinksInPath().standardizedFileURL
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let urlComponents = resolvedURL.pathComponents
        let rootComponents = resolvedRoot.pathComponents
        guard urlComponents.count >= rootComponents.count else { return false }
        return Array(urlComponents.prefix(rootComponents.count)) == rootComponents
    }

    /// Validates a relative workspace path (no absolute, no empty segments, no `.`/`..`, no NUL).
    public static func validateRelativePath(_ path: String) throws {
        if path.isEmpty { return }
        // Absolute paths are never relative workspace paths.
        if path.hasPrefix("/") || path.hasPrefix("\\") {
            throw WorkspaceFileSystemError.pathEscapesRoot(path)
        }
        if path.contains("\0") {
            throw WorkspaceFileSystemError.invalidName
        }
        // Keep empty segments from duplicate/trailing separators — they are invalid.
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if parts.contains(where: { $0.isEmpty }) {
            throw WorkspaceFileSystemError.invalidName
        }
        for part in parts {
            if part == "." || part == ".." {
                throw WorkspaceFileSystemError.invalidName
            }
            if part.contains("\\") || part.contains(":") {
                throw WorkspaceFileSystemError.invalidName
            }
        }
        // Reject scheme-looking paths / Windows UNC-ish.
        if path.contains("://") {
            throw WorkspaceFileSystemError.pathEscapesRoot(path)
        }
    }

    /// Join root + relative path and ensure the result cannot escape the root.
    public static func resolveUnderRoot(
        root: URL,
        relativePath: String,
        options: WorkspacePathResolveOptions = .default
    ) throws -> URL {
        let relative = try RelativeWorkspacePath(validating: relativePath)
        return try resolveUnderRoot(root: root, relative: relative, options: options)
    }

    /// Resolve a typed relative path under an opened root.
    public static func resolveUnderRoot(
        root: URL,
        relative: RelativeWorkspacePath,
        options: WorkspacePathResolveOptions = .default
    ) throws -> URL {
        let base = root.standardizedFileURL
        var current = base
        for part in relative.segments {
            current = current.appendingPathComponent(part, isDirectory: false)
        }
        let url = current

        // Lexical containment before any symlink follow.
        guard isContained(url: url, inRoot: base) || relative.isRoot else {
            // isContained uses symlink resolution; also check path components lexically.
            let urlParts = url.standardizedFileURL.pathComponents
            let rootParts = base.pathComponents
            guard urlParts.count >= rootParts.count,
                Array(urlParts.prefix(rootParts.count)) == rootParts
            else {
                throw WorkspaceFileSystemError.pathEscapesRoot(relative.pathString)
            }
            return try applySymlinkAndVolumePolicy(url: url, base: base, relative: relative, options: options)
        }

        return try applySymlinkAndVolumePolicy(url: url, base: base, relative: relative, options: options)
    }

    private static func applySymlinkAndVolumePolicy(
        url: URL,
        base: URL,
        relative: RelativeWorkspacePath,
        options: WorkspacePathResolveOptions
    ) throws -> URL {
        switch options.symlinkPolicy {
        case .allowAll:
            break
        case .denyEscape, .allowIfStaysInRoot:
            let resolved = url.resolvingSymlinksInPath()
            guard isContained(url: resolved, inRoot: base) else {
                throw WorkspaceFileSystemError.pathEscapesRoot(relative.pathString)
            }
        }

        if options.requireSameVolume {
            try assertSameVolume(url: url, root: base)
        }

        return url.standardizedFileURL
    }

    /// Volume/device boundary check when `requireSameVolume` is set.
    public static func assertSameVolume(url: URL, root: URL) throws {
        #if canImport(Darwin)
            var urlStat = stat()
            var rootStat = stat()
            let urlOK = stat(url.path, &urlStat) == 0
            let rootOK = stat(root.path, &rootStat) == 0
            if !urlOK || !rootOK {
                // If the path does not exist yet (create), check parent.
                let parent = url.deletingLastPathComponent()
                guard stat(parent.path, &urlStat) == 0, stat(root.path, &rootStat) == 0 else {
                    throw WorkspaceFileSystemError.pathEscapesRoot(url.path)
                }
            }
            guard urlStat.st_dev == rootStat.st_dev else {
                throw WorkspaceFileSystemError.pathEscapesRoot(url.path)
            }
        #endif
    }
}
