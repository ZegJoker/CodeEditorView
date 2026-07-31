import Foundation
import CodeEditorExtensionAPI

/// Per-extension sandboxed key-value + file storage under a host-provided root.
public final class ExtensionStorage: @unchecked Sendable {
    public let extensionID: ExtensionID
    public let rootDirectory: URL
    private let granted: Set<ExtensionPermission>
    private let lock = NSLock()
    private var memory: [String: Data] = [:]

    public init(
        extensionID: ExtensionID,
        rootDirectory: URL,
        grantedPermissions: Set<ExtensionPermission>
    ) {
        self.extensionID = extensionID
        self.rootDirectory = rootDirectory
        self.granted = grantedPermissions
        try? FileManager.default.createDirectory(
            at: rootDirectory,
            withIntermediateDirectories: true
        )
    }

    public func setValue(_ data: Data, forKey key: String) throws {
        lock.lock()
        memory[key] = data
        lock.unlock()
        let url = try resolvedFileURL(forRelativePath: "kv/\(sanitized(key)).bin")
        try data.write(to: url, options: .atomic)
    }

    public func value(forKey key: String) throws -> Data? {
        lock.lock()
        if let cached = memory[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()
        let url = try resolvedFileURL(forRelativePath: "kv/\(sanitized(key)).bin")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    public func removeValue(forKey key: String) throws {
        lock.lock()
        memory.removeValue(forKey: key)
        lock.unlock()
        let url = try resolvedFileURL(forRelativePath: "kv/\(sanitized(key)).bin")
        try? FileManager.default.removeItem(at: url)
    }

    /// Write a file relative to the extension sandbox.
    public func writeFile(relativePath: String, data: Data) throws {
        let url = try resolvedFileURL(forRelativePath: relativePath)
        try data.write(to: url, options: .atomic)
    }

    public func readFile(relativePath: String) throws -> Data {
        let url = try resolvedFileURL(forRelativePath: relativePath)
        return try Data(contentsOf: url)
    }

    /// Resolve and validate a relative path stays inside the sandbox.
    public func resolvedFileURL(forRelativePath relativePath: String) throws -> URL {
        let trimmed = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty
            || trimmed.hasPrefix("/")
            || trimmed.split(separator: "/").contains(where: { $0 == ".." })
        {
            throw ExtensionError.storagePathEscape
        }
        let base = rootDirectory.standardizedFileURL
        let url = base.appendingPathComponent(trimmed).standardizedFileURL
        let basePath = base.path
        let urlPath = url.path
        guard urlPath == basePath || urlPath.hasPrefix(basePath + "/") else {
            throw ExtensionError.storagePathEscape
        }
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        return url
    }

    private func sanitized(_ key: String) -> String {
        key.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
    }
}
