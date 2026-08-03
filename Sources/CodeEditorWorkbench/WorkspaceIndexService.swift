import CodeEditorDocuments
import CodeEditorWorkspace
import Foundation

/// Cancellable workspace file index for Open Quickly / project views.
public protocol WorkspaceIndexService: AnyObject, Sendable {
    @MainActor
    func rebuild(workspace: Workspace) async throws -> [OpenQuicklyItem]
}

/// Why the latest file-tree index snapshot was produced (WB-N04).
public enum FileTreeIndexUpdateReason: String, Sendable, Hashable {
    case fullRebuild
    /// Watcher-driven refresh of one or more roots (incremental relative to idle baseline).
    case watcherIncremental
    case watcherOverflowRescan
    case cancelled
}

/// Immutable snapshot of a file-tree index generation (WB-N04).
public struct FileTreeIndexSnapshot: Sendable, Hashable {
    public var generation: UInt64
    public var items: [OpenQuicklyItem]
    public var reason: FileTreeIndexUpdateReason

    public init(
        generation: UInt64,
        items: [OpenQuicklyItem],
        reason: FileTreeIndexUpdateReason = .fullRebuild
    ) {
        self.generation = generation
        self.items = items
        self.reason = reason
    }
}

/// Background actor that walks the filesystem without touching the MainActor file tree (WB-N04).
///
/// Uses ``WorkspaceFileSystem`` listing only — never ``WorkspaceFileTree/expand`` — so Open Quickly
/// indexing cannot freeze the UI or force-expand the project navigator.
public actor FileTreeIndexEngine {
    public var maxDepth: Int
    public var maxFiles: Int
    public var ignoredDirectoryNames: Set<String>
    /// Batch size when yielding partial results to the UI (bounded).
    public var batchSize: Int
    public private(set) var generation: UInt64 = 0

    public init(
        maxDepth: Int = 12,
        maxFiles: Int = 20_000,
        ignoredDirectoryNames: Set<String> = [".git", "node_modules", ".build", "DerivedData", "Pods"],
        batchSize: Int = 256
    ) {
        self.maxDepth = maxDepth
        self.maxFiles = maxFiles
        self.ignoredDirectoryNames = ignoredDirectoryNames
        self.batchSize = max(1, batchSize)
    }

    /// Diagnostics: engine methods run on the actor executor, not the MainActor.
    public func isRunningOffMainActor() -> Bool {
        !Thread.isMainThread
    }

    /// Full rebuild from the workspace filesystem (off MainActor).
    public func rebuild(fileSystem: any WorkspaceFileSystem) async throws -> [OpenQuicklyItem] {
        let snap = try await rebuildSnapshot(fileSystem: fileSystem, reason: .fullRebuild)
        return snap.items
    }

    /// Rebuild and return an immutable snapshot with generation.
    public func rebuildSnapshot(
        fileSystem: any WorkspaceFileSystem,
        reason: FileTreeIndexUpdateReason = .fullRebuild
    ) async throws -> FileTreeIndexSnapshot {
        generation &+= 1
        var collected: [OpenQuicklyItem] = []
        collected.reserveCapacity(min(1024, maxFiles))
        let roots = await fileSystem.roots
        for root in roots {
            try Task.checkCancellation()
            let rootItem = WorkspaceItemID(rootID: root.id, path: "")
            try await collect(
                from: rootItem,
                rootName: root.name,
                fileSystem: fileSystem,
                into: &collected,
                depth: 0
            )
            if collected.count >= maxFiles { break }
        }
        if collected.count > maxFiles {
            collected = Array(collected.prefix(maxFiles))
        }
        return FileTreeIndexSnapshot(generation: generation, items: collected, reason: reason)
    }

    /// Incremental re-walk of a single root, merging items from other roots in `previous` (WB-N04).
    public func refreshRoot(
        rootID: WorkspaceRootID,
        fileSystem: any WorkspaceFileSystem,
        previous: FileTreeIndexSnapshot?,
        reason: FileTreeIndexUpdateReason = .watcherIncremental
    ) async throws -> FileTreeIndexSnapshot {
        generation &+= 1
        try Task.checkCancellation()
        let roots = await fileSystem.roots
        guard let root = roots.first(where: { $0.id == rootID }) else {
            // Unknown root: fall back to full rebuild.
            return try await rebuildSnapshot(fileSystem: fileSystem, reason: reason)
        }

        var collected: [OpenQuicklyItem] = []
        collected.reserveCapacity(min(1024, maxFiles))

        // Retain prior items that do not live under the refreshed root (multi-root incremental merge).
        if let previous {
            let rootPath = root.uri.fileURL?
                .resolvingSymlinksInPath()
                .standardizedFileURL
                .path
            let kept = previous.items.filter { item in
                guard let rootPath, let fileURL = item.uri?.fileURL else {
                    // Without a root URL, drop path-prefixed entries for this root name.
                    let p = item.path
                    if p == root.name { return false }
                    if p.hasPrefix(root.name + "/") { return false }
                    return true
                }
                let itemPath = fileURL.resolvingSymlinksInPath().standardizedFileURL.path
                if itemPath == rootPath { return false }
                if itemPath.hasPrefix(rootPath + "/") { return false }
                return true
            }
            collected.append(contentsOf: kept)
        }

        let rootItem = WorkspaceItemID(rootID: root.id, path: "")
        try await collect(
            from: rootItem,
            rootName: root.name,
            fileSystem: fileSystem,
            into: &collected,
            depth: 0
        )
        if collected.count > maxFiles {
            collected = Array(collected.prefix(maxFiles))
        }
        return FileTreeIndexSnapshot(generation: generation, items: collected, reason: reason)
    }

    private func collect(
        from item: WorkspaceItemID,
        rootName: String,
        fileSystem: any WorkspaceFileSystem,
        into collected: inout [OpenQuicklyItem],
        depth: Int
    ) async throws {
        try Task.checkCancellation()
        if depth > maxDepth || collected.count >= maxFiles { return }

        // Direct filesystem listing — not MainActor WorkspaceFileTree.
        let children = try await fileSystem.children(of: item)
        var batchCount = 0
        for child in children {
            try Task.checkCancellation()
            if collected.count >= maxFiles { return }
            if ignoredDirectoryNames.contains(child.name) { continue }
            if child.isDirectory {
                try await collect(
                    from: child.id,
                    rootName: rootName,
                    fileSystem: fileSystem,
                    into: &collected,
                    depth: depth + 1
                )
            } else {
                let uri = child.uri
                let path = child.id.path.isEmpty ? child.name : "\(rootName)/\(child.id.path)"
                collected.append(OpenQuicklyItem(uri: uri, name: child.name, path: path))
                batchCount += 1
                // Cooperative yield every batch so cancellation is responsive on large trees.
                if batchCount % batchSize == 0 {
                    await Task.yield()
                }
            }
        }
    }
}

/// Default index service: background ``FileTreeIndexEngine`` + watcher-driven updates (WB-N04).
@MainActor
public final class FileTreeIndexService: WorkspaceIndexService, @unchecked Sendable {
    public var maxDepth: Int
    public var maxFiles: Int
    public var ignoredDirectoryNames: Set<String>

    public private(set) var isScanning: Bool = false
    public private(set) var latestSnapshot: FileTreeIndexSnapshot?
    public private(set) var lastUpdateReason: FileTreeIndexUpdateReason?
    public private(set) var isWatching: Bool = false
    /// Root IDs currently watched (tests / diagnostics).
    public private(set) var watchedRootIDs: [WorkspaceRootID] = []

    private let engine: FileTreeIndexEngine
    /// Owns watcher callback + debounce tasks (WB-N05/N04 lifecycle).
    public let taskBag = WorkbenchTaskBag(scope: "service.fileTreeIndex")
    private var scanTask: Task<Void, Never>?
    private var scanGeneration: UInt64 = 0
    private var watchBackend: (any WorkspaceFileWatchBackend)?
    private var watchDebounceTaskID: UUID?
    private var watchDebounce: Duration = .milliseconds(200)
    private var boundFileSystem: (any WorkspaceFileSystem)?
    private var rootURLs: [WorkspaceRootID: URL] = [:]

    public init(
        maxDepth: Int = 12,
        maxFiles: Int = 20_000,
        ignoredDirectoryNames: Set<String> = [".git", "node_modules", ".build", "DerivedData", "Pods"]
    ) {
        self.maxDepth = maxDepth
        self.maxFiles = maxFiles
        self.ignoredDirectoryNames = ignoredDirectoryNames
        self.engine = FileTreeIndexEngine(
            maxDepth: maxDepth,
            maxFiles: maxFiles,
            ignoredDirectoryNames: ignoredDirectoryNames
        )
    }

    /// Background engine used for walks (tests may await isolation probes).
    public var indexEngine: FileTreeIndexEngine { engine }

    @MainActor
    public func rebuild(workspace: Workspace) async throws -> [OpenQuicklyItem] {
        let snapshot = try await rebuildSnapshot(workspace: workspace, reason: .fullRebuild)
        return snapshot.items
    }

    /// Full rebuild returning an immutable snapshot; cancellable via ``cancelScan()``.
    @MainActor
    public func rebuildSnapshot(
        workspace: Workspace,
        reason: FileTreeIndexUpdateReason = .fullRebuild
    ) async throws -> FileTreeIndexSnapshot {
        cancelInFlightScanPreservingWatch()
        scanGeneration &+= 1
        let generation = scanGeneration
        isScanning = true
        lastUpdateReason = reason
        defer {
            if generation == scanGeneration {
                isScanning = false
            }
        }

        let fileSystem = workspace.fileSystem
        boundFileSystem = fileSystem
        await engine.setLimits(
            maxDepth: maxDepth,
            maxFiles: maxFiles,
            ignoredDirectoryNames: ignoredDirectoryNames
        )
        do {
            let snapshot = try await engine.rebuildSnapshot(fileSystem: fileSystem, reason: reason)
            guard generation == scanGeneration else {
                throw CancellationError()
            }
            latestSnapshot = snapshot
            lastUpdateReason = snapshot.reason
            return snapshot
        } catch is CancellationError {
            lastUpdateReason = .cancelled
            throw CancellationError()
        }
    }

    /// Cancel any in-flight scan. Leaves ``isScanning`` false (WB-N04).
    @MainActor
    public func cancelScan() {
        scanGeneration &+= 1
        scanTask?.cancel()
        scanTask = nil
        isScanning = false
        lastUpdateReason = .cancelled
    }

    /// Start watcher-driven incremental index updates for workspace roots (WB-N04).
    @MainActor
    public func startWatching(
        workspace: Workspace,
        debounce: Duration = .milliseconds(200),
        backend: (any WorkspaceFileWatchBackend)? = nil
    ) async {
        stopWatching()
        watchDebounce = debounce
        let fileSystem = workspace.fileSystem
        boundFileSystem = fileSystem
        let roots = await fileSystem.roots
        let chosen = backend ?? FSEventsWorkspaceWatcher()
        watchBackend = chosen
        watchedRootIDs = roots.map(\.id)
        rootURLs = [:]
        for root in roots {
            guard let url = root.uri.fileURL else { continue }
            rootURLs[root.id] = url.resolvingSymlinksInPath().standardizedFileURL
            let rootID = root.id
            chosen.start(
                rootID: rootID,
                url: rootURLs[rootID]!,
                excludedNames: ignoredDirectoryNames
            ) { [weak self] signal in
                guard let self else { return }
                self.taskBag.store(Task { @MainActor in
                    self.handleWatchSignal(signal)
                })
            }
        }
        isWatching = !watchedRootIDs.isEmpty
        // Seed snapshot if empty so incremental merges have a base.
        if latestSnapshot == nil {
            _ = try? await rebuildSnapshot(workspace: workspace, reason: .fullRebuild)
        }
    }

    @MainActor
    public func stopWatching() {
        if let watchDebounceTaskID {
            taskBag.cancel(watchDebounceTaskID)
            self.watchDebounceTaskID = nil
        }
        cancelScan()
        taskBag.cancelAll()
        for id in watchedRootIDs {
            watchBackend?.stop(rootID: id)
        }
        watchBackend?.stopAll()
        watchBackend = nil
        watchedRootIDs = []
        rootURLs = [:]
        isWatching = false
    }

    /// Inject a watch signal (tests) or host-forwarded FS event (WB-N04).
    @MainActor
    public func handleWatchSignal(_ signal: WorkspaceWatchSignal) {
        guard isWatching else { return }
        switch signal {
        case .changed(let rootID):
            scheduleDebouncedRefresh(rootID: rootID, overflow: false)
        case .overflow(let rootID):
            scheduleDebouncedRefresh(rootID: rootID, overflow: true)
        case .stopped:
            break
        }
    }

    // MARK: - Private

    @MainActor
    private func cancelInFlightScanPreservingWatch() {
        scanTask?.cancel()
        scanTask = nil
    }

    @MainActor
    private func scheduleDebouncedRefresh(rootID: WorkspaceRootID, overflow: Bool) {
        if let watchDebounceTaskID {
            taskBag.cancel(watchDebounceTaskID)
            self.watchDebounceTaskID = nil
        }
        let delay = watchDebounce
        let genBump = scanGeneration
        watchDebounceTaskID = taskBag.store(Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            await self.performWatcherRefresh(rootID: rootID, overflow: overflow, scheduledAt: genBump)
        })
    }

    @MainActor
    private func performWatcherRefresh(
        rootID: WorkspaceRootID,
        overflow: Bool,
        scheduledAt: UInt64
    ) async {
        _ = scheduledAt
        guard let fileSystem = boundFileSystem else { return }
        cancelInFlightScanPreservingWatch()
        scanGeneration &+= 1
        let generation = scanGeneration
        isScanning = true
        let reason: FileTreeIndexUpdateReason = overflow ? .watcherOverflowRescan : .watcherIncremental
        lastUpdateReason = reason
        defer {
            if generation == scanGeneration {
                isScanning = false
            }
        }
        await engine.setLimits(
            maxDepth: maxDepth,
            maxFiles: maxFiles,
            ignoredDirectoryNames: ignoredDirectoryNames
        )
        do {
            let snapshot: FileTreeIndexSnapshot
            if overflow {
                snapshot = try await engine.rebuildSnapshot(fileSystem: fileSystem, reason: reason)
            } else {
                snapshot = try await engine.refreshRoot(
                    rootID: rootID,
                    fileSystem: fileSystem,
                    previous: latestSnapshot,
                    reason: reason
                )
            }
            guard generation == scanGeneration else { return }
            latestSnapshot = snapshot
            lastUpdateReason = snapshot.reason
        } catch is CancellationError {
            if generation == scanGeneration {
                lastUpdateReason = .cancelled
            }
        } catch {
            // Keep previous snapshot on IO failure.
        }
    }
}

extension FileTreeIndexEngine {
    fileprivate func setLimits(
        maxDepth: Int,
        maxFiles: Int,
        ignoredDirectoryNames: Set<String>
    ) {
        self.maxDepth = maxDepth
        self.maxFiles = maxFiles
        self.ignoredDirectoryNames = ignoredDirectoryNames
    }
}
