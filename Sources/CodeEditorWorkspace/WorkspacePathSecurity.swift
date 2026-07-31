import Foundation
import CodeEditorDocuments

/// Path canonicalization and root-containment checks for workspace FS.
public enum WorkspacePathSecurity: Sendable {
    /// Returns true if `url` is strictly under or equal to `root` after resolving symlinks.
    public static func isContained(url: URL, inRoot root: URL) -> Bool {
        let resolvedURL = url.resolvingSymlinksInPath().standardizedFileURL
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let urlPath = resolvedURL.path
        let rootPath = resolvedRoot.path
        if urlPath == rootPath { return true }
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        return urlPath.hasPrefix(prefix)
    }

    /// Validates a relative workspace path segment list (no absolute, no `..`).
    public static func validateRelativePath(_ path: String) throws {
        if path.isEmpty { return }
        let parts = path.split(separator: "/").map(String.init)
        for part in parts {
            if part.isEmpty || part == "." || part == ".." {
                throw WorkspaceFileSystemError.invalidName
            }
            if part.contains("\0") {
                throw WorkspaceFileSystemError.invalidName
            }
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
            url = base.appendingPathComponent(relativePath)
        }
        guard isContained(url: url, inRoot: base) else {
            throw WorkspaceFileSystemError.pathEscapesRoot(relativePath)
        }
        // After symlink resolution still contained.
        guard isContained(url: url.resolvingSymlinksInPath(), inRoot: base) else {
            throw WorkspaceFileSystemError.pathEscapesRoot(relativePath)
        }
        return url.standardizedFileURL
    }
}
