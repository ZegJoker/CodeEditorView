import CodeEditorDocuments
import Foundation

/// Actor-isolated local disk implementation of ``WorkspaceFileSystem`` (WSP-004 / §8.4).
///
/// All mutable root/watch/event state lives on the actor. FileManager work runs
/// inside the actor with cooperative cancellation checks (WSP §8.5).
public actor LocalWorkspaceFileSystem: WorkspaceFileSystem {
    private var rootList: [WorkspaceRoot] = []
    private var rootURLs: [WorkspaceRootID: URL] = [:]
    private var settings: WorkspaceSettings
    private var eventContinuations: [UUID: AsyncThrowingStream<WorkspaceFileEvent, Error>.Continuation] = [:]
    /// Counts how many times `children` hits the filesystem (tests assert laziness).
    public private(set) var directoryListCount: Int = 0
    /// When true (default), install recursive watches per root.
    public var enablesDirectoryWatching: Bool
    private let watcher: any WorkspaceFileWatchBackend
    private var pathOptions: WorkspacePathResolveOptions

    public init(
        settings: WorkspaceSettings = .default,
        enablesDirectoryWatching: Bool = true,
        watcher: (any WorkspaceFileWatchBackend)? = nil
    ) {
        self.settings = settings
        self.enablesDirectoryWatching = enablesDirectoryWatching
        self.watcher = watcher ?? FSEventsWorkspaceWatcher()
        self.pathOptions = settings.pathResolveOptions
    }

    public init(
        rootDirectories: [URL],
        settings: WorkspaceSettings = .default,
        enablesDirectoryWatching: Bool = true,
        watcher: (any WorkspaceFileWatchBackend)? = nil
    ) async throws {
        self.settings = settings
        self.enablesDirectoryWatching = enablesDirectoryWatching
        self.watcher = watcher ?? FSEventsWorkspaceWatcher()
        self.pathOptions = settings.pathResolveOptions
        for url in rootDirectories {
            _ = try await addRoot(directoryURL: url)
        }
    }

    deinit {
        watcher.stopAll()
    }

    public var roots: [WorkspaceRoot] { rootList }

    public func children(of item: WorkspaceItemID) async throws -> [WorkspaceItem] {
        try Task.checkCancellation()
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
            try Task.checkCancellation()
            let name = childURL.lastPathComponent
            if settings.excludedNames.contains(name) { continue }
            let values = try? childURL.resourceValues(forKeys: Set(keys))
            if !settings.followSymlinks, values?.isSymbolicLink == true { continue }
            let isDirectory = values?.isDirectory == true
            let childPath = WorkspacePath.join(item.path, name)
            // Reject paths that fail security after join.
            do {
                _ = try RelativeWorkspacePath(validating: childPath)
            } catch {
                continue
            }
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

    public func item(for uri: DocumentURI) async -> WorkspaceItem? {
        guard let fileURL = uri.fileURL?.standardizedFileURL else { return nil }
        for root in rootList {
            guard let rootURL = rootURLs[root.id] else { continue }
            guard WorkspacePathSecurity.isContained(url: fileURL, inRoot: rootURL) else { continue }
            let rootPath = rootURL.standardizedFileURL.path
            let path = fileURL.path
            let relative: String
            if path == rootPath {
                relative = ""
            } else {
                relative = String(path.dropFirst(rootPath.count + 1))
            }
            do {
                _ = try RelativeWorkspacePath(validating: relative)
            } catch {
                continue
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

    public func uri(for item: WorkspaceItemID) async -> DocumentURI? {
        guard let url = try? fileURL(for: item) else { return nil }
        return DocumentURI(fileURL: url)
    }

    public func createFile(in parent: WorkspaceItemID, name: String, contents: Data) async throws -> WorkspaceItem {
        try validateName(name)
        try Task.checkCancellation()
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
        try Task.checkCancellation()
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

    public func move(item: WorkspaceItemID, to parent: WorkspaceItemID, newName: String?) async throws -> WorkspaceItem
    {
        try Task.checkCancellation()
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
        let moved = makeItem(
            rootID: parent.rootID, parentPath: parent.path, name: name, isDirectory: isDir.boolValue, url: dest)
        yield(.renamed(from: item, to: moved))
        return moved
    }

    public func copy(item: WorkspaceItemID, to parent: WorkspaceItemID, newName: String?) async throws -> WorkspaceItem
    {
        try Task.checkCancellation()
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
        let copied = makeItem(
            rootID: parent.rootID, parentPath: parent.path, name: name, isDirectory: isDir.boolValue, url: dest)
        yield(.added(copied))
        return copied
    }

    public func delete(item: WorkspaceItemID) async throws {
        try Task.checkCancellation()
        let url = try fileURL(for: item)
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            throw WorkspaceFileSystemError.ioFailure(error.localizedDescription)
        }
        yield(.removed(item))
    }

    public func addRoot(directoryURL: URL) async throws -> WorkspaceRoot {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directoryURL.path, isDirectory: &isDir), isDir.boolValue else {
            throw WorkspaceFileSystemError.notADirectory
        }
        let standardized = directoryURL.standardizedFileURL
        let root = WorkspaceRoot(directoryURL: standardized)
        rootList.append(root)
        rootURLs[root.id] = standardized
        startWatching(rootID: root.id, url: standardized)
        yield(.rootAdded(root))
        return root
    }

    public func removeRoot(id: WorkspaceRootID) async throws {
        guard rootURLs[id] != nil else { throw WorkspaceFileSystemError.rootNotFound }
        stopWatching(rootID: id)
        rootList.removeAll { $0.id == id }
        rootURLs.removeValue(forKey: id)
        yield(.rootRemoved(id))
    }

    public func events() async -> AsyncThrowingStream<WorkspaceFileEvent, Error> {
        let id = UUID()
        return AsyncThrowingStream { continuation in
            // Schedule registration on the actor.
            Task { await self.registerContinuation(id: id, continuation: continuation) }
            continuation.onTermination = { @Sendable _ in
                Task { await self.unregisterContinuation(id: id) }
            }
        }
    }

    /// Inject a rescan signal (tests / overflow path).
    public func signalRescan(rootID: WorkspaceRootID?) {
        yield(.rescanRequired(rootID))
    }

    // MARK: - Private

    private func registerContinuation(
        id: UUID,
        continuation: AsyncThrowingStream<WorkspaceFileEvent, Error>.Continuation
    ) {
        eventContinuations[id] = continuation
    }

    private func unregisterContinuation(id: UUID) {
        eventContinuations[id] = nil
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
        return try WorkspacePathSecurity.resolveUnderRoot(
            root: rootURL,
            relativePath: item.path,
            options: pathOptions
        )
    }

    private func validateName(_ name: String) throws {
        guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else {
            throw WorkspaceFileSystemError.invalidName
        }
        try WorkspacePathSecurity.validateRelativePath(name)
    }

    private func startWatching(rootID: WorkspaceRootID, url: URL) {
        guard enablesDirectoryWatching else { return }
        stopWatching(rootID: rootID)
        watcher.start(
            rootID: rootID,
            url: url,
            excludedNames: settings.watchExcludedNames
        ) { [weak self] signal in
            Task { await self?.handleWatchSignal(signal) }
        }
    }

    private func stopWatching(rootID: WorkspaceRootID) {
        watcher.stop(rootID: rootID)
    }

    private func handleWatchSignal(_ signal: WorkspaceWatchSignal) {
        switch signal {
        case .changed(let rootID):
            yield(.rescanRequired(rootID))
        case .overflow(let rootID):
            yield(.rescanRequired(rootID))
        case .stopped:
            break
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
