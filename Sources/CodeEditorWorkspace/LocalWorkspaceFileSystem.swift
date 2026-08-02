import CodeEditorCore
import CodeEditorDocuments
import Foundation

#if canImport(Darwin)
    import Darwin
#endif

/// Actor-isolated local disk implementation of ``WorkspaceFileSystem`` (WSP-N04 / §8.4).
///
/// Blocking FileManager work runs on bounded worker tasks with cancellation checkpoints.
/// Event subscriptions register synchronously on the actor and start with a snapshot (WSP-N07).
public actor LocalWorkspaceFileSystem: WorkspaceFileSystem {
    private var rootList: [WorkspaceRoot] = []
    private var rootURLs: [WorkspaceRootID: URL] = [:]
    private var rootDirfds: [WorkspaceRootID: Int32] = [:]
    private var settings: WorkspaceSettings
    private let eventHub = AsyncBroadcastHub<WorkspaceFileEvent>(maxHistory: 128)
    private let progressHub = AsyncBroadcastHub<WorkspaceFSProgressEvent>(maxHistory: 64)
    private var eventSequence: UInt64 = 0
    /// Counts how many times `children` hits the filesystem (tests assert laziness).
    public private(set) var directoryListCount: Int = 0
    /// When true (default), install recursive watches per root.
    public var enablesDirectoryWatching: Bool
    private let watcher: any WorkspaceFileWatchBackend
    private var pathOptions: WorkspacePathResolveOptions
    /// Test/observability: last listing used a background worker (WSP-N04).
    public private(set) var lastWorkerUsedBackgroundExecutor: Bool = false
    /// Test/observability: last mutation used descriptor-relative IO (WSP-N08).
    public private(set) var lastMutationUsedDescriptorRelativeIO: Bool = false

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
        for fd in rootDirfds.values {
            DescriptorRelativeIO.close(fd)
        }
    }

    public var roots: [WorkspaceRoot] { rootList }

    public func children(of item: WorkspaceItemID) async throws -> [WorkspaceItem] {
        var all: [WorkspaceItem] = []
        for try await batch in childrenBatches(of: item) {
            all.append(contentsOf: batch)
        }
        return all
    }

    /// Stream directory entries in batches with cancellation checkpoints (WSP-N04).
    public nonisolated func childrenBatches(
        of item: WorkspaceItemID
    ) -> AsyncThrowingStream<[WorkspaceItem], Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let batches = try await self.listChildrenInBatches(item)
                    for batch in batches {
                        try Task.checkCancellation()
                        continuation.yield(batch)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func progressEvents() async -> AsyncStream<StreamItem<AsyncBroadcastHub<WorkspaceFSProgressEvent>.Envelope>> {
        await progressHub.subscribe(
            policy: .dropOldest(capacity: 64, emitGap: true),
            replay: .none
        )
    }

    /// Sequenced workspace events with authoritative snapshot first (WSP-N07).
    public func workspaceEvents() async -> AsyncStream<WorkspaceStreamItem<WorkspaceFileEvent>> {
        // Snapshot is authoritative; live stream starts after registration with no replay
        // so startup events cannot race past the snapshot (WSP-N07).
        let snapshot = WorkspaceFilesystemSnapshot(roots: rootList, sequence: eventSequence)
        let hubStream = await eventHub.subscribe(
            policy: .dropOldest(capacity: 128, emitGap: true),
            replay: .none
        )
        return AsyncStream { continuation in
            continuation.yield(.snapshot(snapshot, sequence: snapshot.sequence))
            let task = Task {
                for await item in hubStream {
                    switch item {
                    case .value(let envelope):
                        continuation.yield(
                            .event(
                                WorkspaceEventEnvelope(
                                    sequence: envelope.sequence,
                                    event: envelope.event
                                )
                            )
                        )
                    case .gap(let from, let to):
                        continuation.yield(.gap(expected: from, actual: to))
                    case .finished:
                        continuation.finish()
                        return
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
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
        await progressHub.publish(.mutationStarted("createFile:\(name)"))
        defer {
            Task { await progressHub.publish(.mutationFinished("createFile:\(name)")) }
        }

        if pathOptions.useDescriptorRelativeIO, let dirfd = try? dirfdForItem(parent) {
            do {
                let owned = dirfd.owns
                defer { if owned { DescriptorRelativeIO.close(dirfd.fd) } }
                try DescriptorRelativeIO.writeNewFile(dirfd: dirfd.fd, name: name, contents: contents)
                lastMutationUsedDescriptorRelativeIO = true
                let dest = try fileURL(for: parent).appendingPathComponent(name)
                let item = makeItem(
                    rootID: parent.rootID, parentPath: parent.path, name: name, isDirectory: false, url: dest
                )
                await yieldEvent(.added(item))
                return item
            } catch let error as DescriptorRelativeIOError {
                if case .notSupported = error {
                    // fall through to FileManager
                } else if FileManager.default.fileExists(
                    atPath: (try? fileURL(for: parent).appendingPathComponent(name).path) ?? ""
                ) {
                    throw WorkspaceFileSystemError.alreadyExists(name)
                } else {
                    throw WorkspaceFileSystemError.ioFailure(String(describing: error))
                }
            } catch {
                throw WorkspaceFileSystemError.ioFailure(String(describing: error))
            }
        }

        let parentURL = try fileURL(for: parent)
        let dest = parentURL.appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: dest.path) else {
            throw WorkspaceFileSystemError.alreadyExists(name)
        }
        // Revalidate containment immediately before mutation (WSP-N08).
        _ = try WorkspacePathSecurity.resolveUnderRoot(
            root: rootURLs[parent.rootID]!,
            relativePath: WorkspacePath.join(parent.path, name),
            options: pathOptions
        )
        do {
            try contents.write(to: dest, options: .atomic)
        } catch {
            throw WorkspaceFileSystemError.ioFailure(error.localizedDescription)
        }
        lastMutationUsedDescriptorRelativeIO = false
        let item = makeItem(rootID: parent.rootID, parentPath: parent.path, name: name, isDirectory: false, url: dest)
        await yieldEvent(.added(item))
        return item
    }

    public func createDirectory(in parent: WorkspaceItemID, name: String) async throws -> WorkspaceItem {
        try validateName(name)
        try Task.checkCancellation()
        if pathOptions.useDescriptorRelativeIO, let dirfd = try? dirfdForItem(parent) {
            do {
                let owned = dirfd.owns
                defer { if owned { DescriptorRelativeIO.close(dirfd.fd) } }
                try DescriptorRelativeIO.mkdirAt(dirfd: dirfd.fd, relativePath: name)
                lastMutationUsedDescriptorRelativeIO = true
                let dest = try fileURL(for: parent).appendingPathComponent(name)
                let item = makeItem(
                    rootID: parent.rootID, parentPath: parent.path, name: name, isDirectory: true, url: dest
                )
                await yieldEvent(.added(item))
                return item
            } catch let error as DescriptorRelativeIOError {
                if case .notSupported = error {
                    // fall through
                } else {
                    throw WorkspaceFileSystemError.ioFailure(String(describing: error))
                }
            }
        }
        let parentURL = try fileURL(for: parent)
        let dest = parentURL.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: false)
        } catch {
            throw WorkspaceFileSystemError.ioFailure(error.localizedDescription)
        }
        lastMutationUsedDescriptorRelativeIO = false
        let item = makeItem(rootID: parent.rootID, parentPath: parent.path, name: name, isDirectory: true, url: dest)
        await yieldEvent(.added(item))
        return item
    }

    public func move(item: WorkspaceItemID, to parent: WorkspaceItemID, newName: String?) async throws -> WorkspaceItem {
        try Task.checkCancellation()
        let name = newName ?? item.name
        if let newName { try validateName(newName) }

        if pathOptions.useDescriptorRelativeIO,
            let fromPair = try? parentDirfdAndLeaf(for: item),
            let toPair = try? dirfdForItem(parent)
        {
            do {
                defer {
                    if fromPair.owns { DescriptorRelativeIO.close(fromPair.fd) }
                    if toPair.owns { DescriptorRelativeIO.close(toPair.fd) }
                }
                try DescriptorRelativeIO.renameAt(
                    fromDirfd: fromPair.fd,
                    fromRelative: fromPair.name,
                    toDirfd: toPair.fd,
                    toRelative: name
                )
                lastMutationUsedDescriptorRelativeIO = true
                let dest = try fileURL(for: parent).appendingPathComponent(name)
                var isDir: ObjCBool = false
                _ = FileManager.default.fileExists(atPath: dest.path, isDirectory: &isDir)
                let moved = makeItem(
                    rootID: parent.rootID, parentPath: parent.path, name: name, isDirectory: isDir.boolValue, url: dest
                )
                await yieldEvent(.renamed(from: item, to: moved))
                return moved
            } catch let error as DescriptorRelativeIOError {
                if case .notSupported = error {
                    // fall through
                } else {
                    throw WorkspaceFileSystemError.ioFailure(String(describing: error))
                }
            }
        }

        let sourceURL = try fileURL(for: item)
        let destParent = try fileURL(for: parent)
        let dest = destParent.appendingPathComponent(name)
        do {
            try FileManager.default.moveItem(at: sourceURL, to: dest)
        } catch {
            throw WorkspaceFileSystemError.ioFailure(error.localizedDescription)
        }
        lastMutationUsedDescriptorRelativeIO = false
        var isDir: ObjCBool = false
        _ = FileManager.default.fileExists(atPath: dest.path, isDirectory: &isDir)
        let moved = makeItem(
            rootID: parent.rootID, parentPath: parent.path, name: name, isDirectory: isDir.boolValue, url: dest)
        await yieldEvent(.renamed(from: item, to: moved))
        return moved
    }

    public func copy(item: WorkspaceItemID, to parent: WorkspaceItemID, newName: String?) async throws -> WorkspaceItem {
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
        await yieldEvent(.added(copied))
        return copied
    }

    public func delete(item: WorkspaceItemID) async throws {
        try Task.checkCancellation()
        await progressHub.publish(.mutationStarted("delete:\(item.path)"))
        defer {
            Task { await progressHub.publish(.mutationFinished("delete:\(item.path)")) }
        }

        if pathOptions.useDescriptorRelativeIO, let pair = try? parentDirfdAndLeaf(for: item) {
            do {
                defer { if pair.owns { DescriptorRelativeIO.close(pair.fd) } }
                var isDir = false
                if let st = try? DescriptorRelativeIO.statAt(dirfd: pair.fd, relativePath: pair.name) {
                    #if canImport(Darwin)
                        isDir = (st.st_mode & S_IFMT) == S_IFDIR
                    #endif
                }
                try DescriptorRelativeIO.unlinkAt(dirfd: pair.fd, relativePath: pair.name, directory: isDir)
                // Recursive directory delete if not empty: fall back to removeItem for trees.
                lastMutationUsedDescriptorRelativeIO = true
                await yieldEvent(.removed(item))
                return
            } catch let error as DescriptorRelativeIOError {
                // Directory not empty etc. — fall back.
                if case .notSupported = error {
                    // fall through
                } else {
                    // Try full tree delete via FileManager after path revalidation.
                    let url = try fileURL(for: item)
                    do {
                        try FileManager.default.removeItem(at: url)
                        lastMutationUsedDescriptorRelativeIO = true
                        await yieldEvent(.removed(item))
                        return
                    } catch {
                        throw WorkspaceFileSystemError.ioFailure(String(describing: error))
                    }
                }
            } catch {
                // unlink may fail for non-empty dirs
                let url = try fileURL(for: item)
                do {
                    try FileManager.default.removeItem(at: url)
                    lastMutationUsedDescriptorRelativeIO = true
                    await yieldEvent(.removed(item))
                    return
                } catch {
                    throw WorkspaceFileSystemError.ioFailure(error.localizedDescription)
                }
            }
        }

        let url = try fileURL(for: item)
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            throw WorkspaceFileSystemError.ioFailure(error.localizedDescription)
        }
        lastMutationUsedDescriptorRelativeIO = false
        await yieldEvent(.removed(item))
    }

    /// Notify that an item was removed out-of-band (e.g. trash staging) (WSP-N02).
    public func noteRemoved(item: WorkspaceItemID) async {
        await yieldEvent(.removed(item))
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
        if pathOptions.useDescriptorRelativeIO {
            if let fd = try? DescriptorRelativeIO.openDirectory(at: standardized) {
                rootDirfds[root.id] = fd
            }
        }
        startWatching(rootID: root.id, url: standardized)
        await yieldEvent(.rootAdded(root))
        return root
    }

    public func removeRoot(id: WorkspaceRootID) async throws {
        guard rootURLs[id] != nil else { throw WorkspaceFileSystemError.rootNotFound }
        stopWatching(rootID: id)
        if let fd = rootDirfds.removeValue(forKey: id) {
            DescriptorRelativeIO.close(fd)
        }
        rootList.removeAll { $0.id == id }
        rootURLs.removeValue(forKey: id)
        await yieldEvent(.rootRemoved(id))
    }

    /// Legacy unsequenced stream — prefer ``workspaceEvents()`` (WSP-N07).
    public func events() async -> AsyncThrowingStream<WorkspaceFileEvent, Error> {
        let stream = await workspaceEvents()
        return AsyncThrowingStream { continuation in
            let task = Task {
                for await item in stream {
                    switch item {
                    case .event(let envelope):
                        continuation.yield(envelope.event)
                    case .snapshot, .gap:
                        continue
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Inject a rescan signal (tests / overflow path).
    public func signalRescan(rootID: WorkspaceRootID?) {
        Task { await yieldEvent(.rescanRequired(rootID)) }
    }

    // MARK: - Listing workers (WSP-N04)

    private func listChildrenInBatches(_ item: WorkspaceItemID) async throws -> [[WorkspaceItem]] {
        try Task.checkCancellation()
        await progressHub.publish(.listingStarted(item))
        let limits = settings.filesystemLimits
        let url = try fileURL(for: item)

        // Run blocking enumeration off the actor executor.
        let policy = settings
        let batchSize = limits.batchSize
        let listed: [WorkspaceItem] = try await withCheckedThrowingContinuation { continuation in
            Task.detached(priority: .userInitiated) {
                do {
                    try Task.checkCancellation()
                    var isDir: ObjCBool = false
                    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
                        throw WorkspaceFileSystemError.itemNotFound(item.path)
                    }
                    if !item.path.isEmpty && !isDir.boolValue {
                        throw WorkspaceFileSystemError.notADirectory
                    }
                    let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .nameKey]
                    let contents = try FileManager.default.contentsOfDirectory(
                        at: url,
                        includingPropertiesForKeys: keys,
                        options: []  // host policy applied below (WSP-N09)
                    )
                    var items: [WorkspaceItem] = []
                    for childURL in contents.sorted(by: {
                        $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
                    }) {
                        try Task.checkCancellation()
                        let name = childURL.lastPathComponent
                        guard policy.shouldList(name: name) else { continue }
                        let values = try? childURL.resourceValues(forKeys: Set(keys))
                        if !policy.followSymlinks, values?.isSymbolicLink == true { continue }
                        let isDirectory = values?.isDirectory == true
                        let childPath = WorkspacePath.join(item.path, name)
                        do {
                            _ = try RelativeWorkspacePath(validating: childPath)
                        } catch {
                            continue
                        }
                        if items.count >= limits.maxFileCount {
                            break
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
                    continuation.resume(returning: items)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }

        lastWorkerUsedBackgroundExecutor = true
        directoryListCount += 1

        var batches: [[WorkspaceItem]] = []
        var index = 0
        while index < listed.count {
            try Task.checkCancellation()
            let end = min(index + batchSize, listed.count)
            let batch = Array(listed[index..<end])
            batches.append(batch)
            await progressHub.publish(.listingBatch(item, count: batch.count))
            index = end
        }
        await progressHub.publish(.listingFinished(item, total: listed.count))
        return batches
    }

    // MARK: - Private

    private func yieldEvent(_ event: WorkspaceFileEvent) async {
        eventSequence &+= 1
        await eventHub.publish(event)
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

    private func dirfdForItem(_ item: WorkspaceItemID) throws -> (fd: Int32, owns: Bool) {
        guard let rootFd = rootDirfds[item.rootID] else {
            guard let rootURL = rootURLs[item.rootID] else {
                throw WorkspaceFileSystemError.rootNotFound
            }
            let fd = try DescriptorRelativeIO.openDirectory(at: rootURL)
            if item.path.isEmpty { return (fd, true) }
            let rel = try RelativeWorkspacePath(validating: item.path)
            let nested = try DescriptorRelativeIO.openNestedDirectory(
                rootDirfd: fd,
                segments: rel.segments
            )
            DescriptorRelativeIO.close(fd)
            return (nested, true)
        }
        if item.path.isEmpty { return (rootFd, false) }
        let rel = try RelativeWorkspacePath(validating: item.path)
        let nested = try DescriptorRelativeIO.openNestedDirectory(
            rootDirfd: rootFd,
            segments: rel.segments
        )
        return (nested, true)
    }

    private func parentDirfdAndLeaf(for item: WorkspaceItemID) throws -> (fd: Int32, name: String, owns: Bool) {
        guard !item.path.isEmpty else {
            throw WorkspaceFileSystemError.invalidName
        }
        guard let rootFd = rootDirfds[item.rootID] else {
            guard let rootURL = rootURLs[item.rootID] else {
                throw WorkspaceFileSystemError.rootNotFound
            }
            let fd = try DescriptorRelativeIO.openDirectory(at: rootURL)
            let pair = try DescriptorRelativeIO.parentDirfdAndName(rootDirfd: fd, relativePath: item.path)
            if !pair.ownsDirfd {
                // pair uses root fd which we own here
                return (pair.dirfd, pair.name, true)
            }
            DescriptorRelativeIO.close(fd)
            return (pair.dirfd, pair.name, true)
        }
        let pair = try DescriptorRelativeIO.parentDirfdAndName(rootDirfd: rootFd, relativePath: item.path)
        return (pair.dirfd, pair.name, pair.ownsDirfd)
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
            Task { await yieldEvent(.rescanRequired(rootID)) }
        case .overflow(let rootID):
            Task { await yieldEvent(.rescanRequired(rootID)) }
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
