import CodeEditorDocuments
import Foundation

/// Typed relative-path security for workspace FS (audit §8.3).
///
/// Rejects absolute paths, empty segments, `.` / `..`, NUL, platform separators,
/// and string-prefix false friends. Prefer descriptor-relative resolution under an
/// opened root — never implement security with unvalidated substring checks alone.
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
        // Reject Windows-style drive or UNC.
        if path.contains("://") {
            throw WorkspaceFileSystemError.pathEscapesRoot(path)
        }
    }

    /// Join root + relative path and ensure the result cannot escape the root.
    public static func resolveUnderRoot(root: URL, relativePath: String) throws -> URL {
        try validateRelativePath(relativePath)
        let base = root.standardizedFileURL
        let url: URL
        if relativePath.isEmpty {
            url = base
        } else {
            // Append component-by-component to avoid `//` normalization surprises.
            var current = base
            for part in relativePath.split(separator: "/", omittingEmptySubsequences: true) {
                current = current.appendingPathComponent(String(part), isDirectory: false)
            }
            url = current
        }
        guard isContained(url: url, inRoot: base) else {
            throw WorkspaceFileSystemError.pathEscapesRoot(relativePath)
        }
        // After symlink resolution still contained.
        let resolved = url.resolvingSymlinksInPath()
        guard isContained(url: resolved, inRoot: base) else {
            throw WorkspaceFileSystemError.pathEscapesRoot(relativePath)
        }
        return url.standardizedFileURL
    }
}
