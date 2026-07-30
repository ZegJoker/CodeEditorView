import Foundation
import CodeEditorDocuments

/// Local disk implementation of ``WorkspaceFileSystem`` with lazy directory reads.
///
/// Intended to be used from a single concurrent context (e.g. MainActor workspace
/// orchestration). Marked `@unchecked Sendable` for protocol conformance.
public final class LocalWorkspaceFileSystem: WorkspaceFileSystem, @unchecked Sendable {
    private var rootList: [WorkspaceRoot] = []
    private var rootURLs: [WorkspaceRootID: URL] = [:]
    private var settings: WorkspaceSettings
    private var eventContinuations: [UUID: AsyncThrowingStream<WorkspaceFileEvent, Error>.Continuation] = [:]
    /// Counts how many times `children` hits the filesystem (tests assert laziness).
    public private(set) var directoryListCount: Int = 0

    public init(settings: WorkspaceSettings = .default) {
        self.settings = settings
    }

    public init(rootDirectories: [URL], settings: WorkspaceSettings = .default) throws {
        self.settings = settings
        for url in rootDirectories {
            _ = try addRootSync(directoryURL: url)
        }
    }

    public var roots: [WorkspaceRoot] { rootList }

    public func children(of item: WorkspaceItemID) async throws -> [WorkspaceItem] {
        let url = try fileURL(for: item)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            throw WorkspaceFileSystemError.itemNotFound(item.path)
        }
        if !item.path.isEmpty && !isDir.boolValue {
            throw WorkspaceFileSystemError.notADirectory
        }
        directoryListCount += 1
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .nameKey]
        let contents: [URL]
        do {
            contents = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw WorkspaceFileSystemError.ioFailure(error.localizedDescription)
        }

        var items: [WorkspaceItem] = []
        for childURL in contents.sorted(by: {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }) {
            let name = childURL.lastPathComponent
            if settings.excludedNames.contains(name) { continue }
            let values = try? childURL.resourceValues(forKeys: Set(keys))
            if !settings.followSymlinks, values?.isSymbolicLink == true { continue }
            let isDirectory = values?.isDirectory == true
            let childPath = WorkspacePath.join(item.path, name)
            let childID = WorkspaceItemID(rootID: item.rootID, path: childPath)
            items.append(
                WorkspaceItem(
                    id: childID,
                    name: name,
                    isDirectory: isDirectory,
                    uri: DocumentURI(fileURL: childURL.standardizedFileURL)
                )
            )
        }
        return items
    }

    public func item(for uri: DocumentURI) -> WorkspaceItem? {
        guard let fileURL = uri.fileURL?.standardizedFileURL else { return nil }
        for root in rootList {
            guard let rootURL = rootURLs[root.id] else { continue }
            let rootPath = rootURL.standardizedFileURL.path
            let path = fileURL.path
            guard path == rootPath || path.hasPrefix(rootPath + "/") else { continue }
            let relative: String
            if path == rootPath {
                relative = ""
            } else {
                relative = String(path.dropFirst(rootPath.count + 1))
            }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { continue }
            return WorkspaceItem(
                id: WorkspaceItemID(rootID: root.id, path: relative),
                name: relative.isEmpty ? root.name : (relative as NSString).lastPathComponent,
                isDirectory: isDir.boolValue,
                uri: DocumentURI(fileURL: fileURL)
            )
        }
        return nil
    }

    public func uri(for item: WorkspaceItemID) -> DocumentURI? {
        guard let url = try? fileURL(for: item) else { return nil }
        return DocumentURI(fileURL: url)
    }

    public func createFile(in parent: WorkspaceItemID, name: String, contents: Data) async throws -> WorkspaceItem {
        try validateName(name)
        let parentURL = try fileURL(for: parent)
        let dest = parentURL.appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: dest.path) else {
            throw WorkspaceFileSystemError.alreadyExists(name)
        }
        do {
            try contents.write(to: dest, options: .atomic)
        } catch {
            throw WorkspaceFileSystemError.ioFailure(error.localizedDescription)
        }
        let item = makeItem(rootID: parent.rootID, parentPath: parent.path, name: name, isDirectory: false, url: dest)
        yield(.added(item))
        return item
    }

    public func createDirectory(in parent: WorkspaceItemID, name: String) async throws -> WorkspaceItem {
        try validateName(name)
        let parentURL = try fileURL(for: parent)
        let dest = parentURL.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: false)
        } catch {
            throw WorkspaceFileSystemError.ioFailure(error.localizedDescription)
        }
        let item = makeItem(rootID: parent.rootID, parentPath: parent.path, name: name, isDirectory: true, url: dest)
        yield(.added(item))
        return item
    }

    public func move(item: WorkspaceItemID, to parent: WorkspaceItemID, newName: String?) async throws -> WorkspaceItem {
        let sourceURL = try fileURL(for: item)
        let name = newName ?? item.name
        if let newName { try validateName(newName) }
        let destParent = try fileURL(for: parent)
        let dest = destParent.appendingPathComponent(name)
        do {
            try FileManager.default.moveItem(at: sourceURL, to: dest)
        } catch {
            throw WorkspaceFileSystemError.ioFailure(error.localizedDescription)
        }
        var isDir: ObjCBool = false
        _ = FileManager.default.fileExists(atPath: dest.path, isDirectory: &isDir)
        let moved = makeItem(rootID: parent.rootID, parentPath: parent.path, name: name, isDirectory: isDir.boolValue, url: dest)
        yield(.renamed(from: item, to: moved))
        return moved
    }

    public func copy(item: WorkspaceItemID, to parent: WorkspaceItemID, newName: String?) async throws -> WorkspaceItem {
        let sourceURL = try fileURL(for: item)
        let name = newName ?? item.name
        if let newName { try validateName(newName) }
        let destParent = try fileURL(for: parent)
        let dest = destParent.appendingPathComponent(name)
        do {
            try FileManager.default.copyItem(at: sourceURL, to: dest)
        } catch {
            throw WorkspaceFileSystemError.ioFailure(error.localizedDescription)
        }
        var isDir: ObjCBool = false
        _ = FileManager.default.fileExists(atPath: dest.path, isDirectory: &isDir)
        let copied = makeItem(rootID: parent.rootID, parentPath: parent.path, name: name, isDirectory: isDir.boolValue, url: dest)
        yield(.added(copied))
        return copied
    }

    public func delete(item: WorkspaceItemID) async throws {
        let url = try fileURL(for: item)
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            throw WorkspaceFileSystemError.ioFailure(error.localizedDescription)
        }
        yield(.removed(item))
    }

    public func addRoot(directoryURL: URL) async throws -> WorkspaceRoot {
        try addRootSync(directoryURL: directoryURL)
    }

    public func removeRoot(id: WorkspaceRootID) async throws {
        guard rootURLs[id] != nil else { throw WorkspaceFileSystemError.rootNotFound }
        rootList.removeAll { $0.id == id }
        rootURLs.removeValue(forKey: id)
        yield(.rootRemoved(id))
    }

    public func events() -> AsyncThrowingStream<WorkspaceFileEvent, Error> {
        let id = UUID()
        return AsyncThrowingStream { [weak self] continuation in
            self?.eventContinuations[id] = continuation
            continuation.onTermination = { @Sendable [weak self] _ in
                self?.eventContinuations[id] = nil
            }
        }
    }

    // MARK: - Private

    @discardableResult
    private func addRootSync(directoryURL: URL) throws -> WorkspaceRoot {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directoryURL.path, isDirectory: &isDir), isDir.boolValue else {
            throw WorkspaceFileSystemError.notADirectory
        }
        let standardized = directoryURL.standardizedFileURL
        let root = WorkspaceRoot(directoryURL: standardized)
        rootList.append(root)
        rootURLs[root.id] = standardized
        yield(.rootAdded(root))
        return root
    }

    private func yield(_ event: WorkspaceFileEvent) {
        for continuation in eventContinuations.values {
            continuation.yield(event)
        }
    }

    private func fileURL(for item: WorkspaceItemID) throws -> URL {
        guard let rootURL = rootURLs[item.rootID] else {
            throw WorkspaceFileSystemError.rootNotFound
        }
        if item.path.isEmpty { return rootURL }
        return rootURL.appendingPathComponent(item.path)
    }

    private func validateName(_ name: String) throws {
        guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else {
            throw WorkspaceFileSystemError.invalidName
        }
    }

    private func makeItem(
        rootID: WorkspaceRootID,
        parentPath: String,
        name: String,
        isDirectory: Bool,
        url: URL
    ) -> WorkspaceItem {
        let path = WorkspacePath.join(parentPath, name)
        return WorkspaceItem(
            id: WorkspaceItemID(rootID: rootID, path: path),
            name: name,
            isDirectory: isDirectory,
            uri: DocumentURI(fileURL: url.standardizedFileURL)
        )
    }
}
