import CodeEditorCore
import CodeEditorDocuments
import CodeEditorWorkspace
import Foundation

public actor SourceControlService {
    private var providers: [String: any SourceControlProvider] = [:]
    private var activeID: String?
    private let statusHub = AsyncBroadcastHub<SCMStatusSnapshot>(maxHistory: 32)
    private var statusSequence: UInt64 = 0
    private var statusFinished = false
    public private(set) var lastStatus: [SCMFileStatus] = []
    public private(set) var lastSnapshot: SCMStatusSnapshot?
    public private(set) var trusted: Bool = true
    private var documentCoordinator: SCMDocumentCoordinator?

    // SCM-N08 watcher-driven status
    private var watchBackend: (any WorkspaceFileWatchBackend)?
    private var watchRootID: WorkspaceRootID?
    private var watchDebounceTask: Task<Void, Never>?
    private var watchDebounce: Duration = .milliseconds(200)
    public private(set) var isStatusWatching = false

    public init() {}

    public func setTrusted(_ value: Bool) {
        trusted = value
    }

    /// Bind dirty-buffer coordination. Required for all destructive ops (SCM-N06 fail-closed).
    public func setDocumentCoordinator(_ coordinator: SCMDocumentCoordinator?) async {
        documentCoordinator = coordinator
        for p in providers.values {
            if let git = p as? GitCLIProvider {
                await git.setDocumentCoordinator(coordinator)
            }
        }
    }

    /// Multicast status stream (SCM-N08). Independent subscribers with optional replay.
    public func makeStatusStream(
        policy: AsyncBroadcastHub<SCMStatusSnapshot>.OverflowPolicy = .dropOldest(
            capacity: 32, emitGap: true),
        replay: ReplayPolicy = .none
    ) async -> AsyncStream<StreamItem<AsyncBroadcastHub<SCMStatusSnapshot>.Envelope>> {
        await statusHub.subscribe(policy: policy, replay: replay)
    }

    /// Root ID used by the active status watcher (tests / diagnostics).
    public var statusWatchRootID: WorkspaceRootID? { watchRootID }

    /// Start watcher-driven status refresh with debounce and explicit stale state (SCM-N08).
    public func startStatusWatching(
        root: URL? = nil,
        debounce: Duration = .milliseconds(200),
        backend: (any WorkspaceFileWatchBackend)? = nil
    ) async {
        await stopStatusWatching()
        let watchURL: URL
        if let root {
            watchURL = root.resolvingSymlinksInPath().standardizedFileURL
        } else if let active = activeRepositoryRoot() {
            watchURL = active
        } else {
            return
        }
        watchDebounce = debounce
        let rootID = WorkspaceRootID()
        watchRootID = rootID
        let chosen = backend ?? FSEventsWorkspaceWatcher()
        watchBackend = chosen
        isStatusWatching = true
        let serviceBox = UncheckedServiceBox(self)
        chosen.start(
            rootID: rootID,
            url: watchURL,
            excludedNames: [".git/objects", ".git/objects/pack"]
        ) { signal in
            Task {
                await serviceBox.service?.handleWatchSignal(signal)
            }
        }
    }

    public func stopStatusWatching() async {
        watchDebounceTask?.cancel()
        watchDebounceTask = nil
        if let rootID = watchRootID {
            watchBackend?.stop(rootID: rootID)
        }
        watchBackend?.stopAll()
        watchBackend = nil
        watchRootID = nil
        isStatusWatching = false
    }

    /// Inject a watch signal (tests) or host-forwarded FS event.
    public func handleWatchSignal(_ signal: WorkspaceWatchSignal) async {
        guard isStatusWatching else { return }
        switch signal {
        case .changed, .overflow:
            await publishStaleSnapshot()
            scheduleDebouncedRefresh()
        case .stopped:
            break
        }
    }

    public func setProvider(_ provider: (any SourceControlProvider)?) async {
        if let provider {
            providers[provider.id] = provider
            activeID = provider.id
            statusFinished = false
            if let git = provider as? GitCLIProvider, let documentCoordinator {
                await git.setDocumentCoordinator(documentCoordinator)
            }
        } else if let activeID {
            await removeProvider(id: activeID)
        }
    }

    public func registerProvider(_ provider: any SourceControlProvider) async {
        providers[provider.id] = provider
        if activeID == nil { activeID = provider.id }
        statusFinished = false
        if let git = provider as? GitCLIProvider, let documentCoordinator {
            await git.setDocumentCoordinator(documentCoordinator)
        }
    }

    public func removeProvider(id: String) async {
        providers.removeValue(forKey: id)
        if activeID == id {
            activeID = providers.keys.sorted().first
        }
        statusSequence &+= 1
        let stale = SCMStatusSnapshot(
            repositoryID: id,
            statuses: [],
            isStale: true,
            sequence: statusSequence
        )
        lastSnapshot = stale
        lastStatus = []
        await statusHub.publish(stale)
        if providers.isEmpty && !statusFinished {
            statusFinished = true
            await statusHub.finish(.completed)
            await stopStatusWatching()
        }
    }

    public func selectProvider(id: String) throws {
        guard providers[id] != nil else { throw SCMError.notFound(id) }
        activeID = id
    }

    public func currentProviderID() -> String? {
        activeID
    }

    public func allProviderIDs() -> [String] {
        providers.keys.sorted()
    }

    private func provider() throws -> any SourceControlProvider {
        guard let activeID, let p = providers[activeID] else { throw SCMError.noProvider }
        return p
    }

    private func activeRepositoryRoot() -> URL? {
        guard let activeID, let p = providers[activeID] else { return nil }
        if let git = p as? GitCLIProvider {
            return git.repositoryRoot
        }
        let raw = p.repositoryIdentity.rawValue
        if raw.hasPrefix("git:") {
            return URL(fileURLWithPath: String(raw.dropFirst(4)))
        }
        return nil
    }

    @discardableResult
    public func refresh() async throws -> [SCMFileStatus] {
        let p = try provider()
        let status = try await p.status()
        lastStatus = status
        statusSequence &+= 1
        let snap = SCMStatusSnapshot(
            repositoryID: p.id,
            statuses: status,
            isStale: false,
            sequence: statusSequence
        )
        lastSnapshot = snap
        await statusHub.publish(snap)
        return status
    }

    public func branches() async throws -> SCMBranchList {
        try await provider().branches()
    }

    public func tags() async throws -> [SCMTag] {
        try await provider().tags()
    }

    public func remotes() async throws -> [SCMRemote] {
        try await provider().remotes()
    }

    public func log(limit: Int = 50) async throws -> [SCMCommit] {
        try await provider().log(limit: limit)
    }

    public func blame(uri: DocumentURI) async throws -> [SCMBlameLine] {
        try await provider().blame(uri: uri)
    }

    public func diff(uri: DocumentURI) async throws -> SCMDiff {
        try await provider().diff(uri: uri)
    }

    public func stage(uris: [DocumentURI]) async throws {
        try requireTrusted()
        try await provider().stage(uris: uris)
        _ = try await refresh()
    }

    public func unstage(uris: [DocumentURI]) async throws {
        try requireTrusted()
        try await provider().unstage(uris: uris)
        _ = try await refresh()
    }

    public func discard(uris: [DocumentURI]) async throws {
        try requireTrusted()
        try await assertCleanForDestructive(uris: uris, wholeRepository: false)
        try await provider().discard(uris: uris)
        _ = try await refresh()
    }

    public func commit(message: String) async throws {
        try requireTrusted()
        try await provider().commit(message: message)
        _ = try await refresh()
    }

    public func checkout(branch: String) async throws {
        try requireTrusted()
        try await assertCleanForDestructive(uris: [], wholeRepository: true)
        try await provider().checkout(branch: branch)
        _ = try await refresh()
    }

    public func createBranch(_ name: String) async throws {
        try requireTrusted()
        try await provider().createBranch(name)
    }

    public func deleteBranch(_ name: String) async throws {
        try requireTrusted()
        try await provider().deleteBranch(name)
    }

    public func fetch(remote: String? = nil) async throws {
        try requireTrusted()
        try await provider().fetch(remote: remote)
    }

    public func pull(remote: String? = nil, branch: String? = nil) async throws {
        try requireTrusted()
        try await assertCleanForDestructive(uris: [], wholeRepository: true)
        try await provider().pull(remote: remote, branch: branch)
        _ = try await refresh()
    }

    public func push(remote: String? = nil, branch: String? = nil) async throws {
        try requireTrusted()
        try await provider().push(remote: remote, branch: branch)
    }

    public func resolveConflict(uri: DocumentURI, side: SCMConflictSide) async throws {
        try requireTrusted()
        try await provider().resolveConflict(uri: uri, side: side)
        _ = try await refresh()
    }

    public func cancel() async {
        try? await provider().cancel()
    }

    /// Discover git roots under workspace folders and register CLI providers.
    public func discoverAndRegister(
        roots: [URL],
        platformProfile: PlatformCapabilityProfile = .default()
    ) async {
        for root in roots {
            if let repo = GitRepositoryDiscovery.discover(from: root) {
                let provider = GitCLIProvider(
                    repositoryRoot: repo,
                    platformProfile: platformProfile,
                    trusted: trusted,
                    documentCoordinator: documentCoordinator
                )
                providers[provider.id] = provider
                if activeID == nil { activeID = provider.id }
            }
        }
    }

    private func requireTrusted() throws {
        if !trusted { throw SCMError.untrusted }
    }

    /// SCM-N06: fail closed — missing coordinator is never a soft pass-through.
    private func assertCleanForDestructive(
        uris: [DocumentURI],
        wholeRepository: Bool
    ) async throws {
        guard let coordinator = documentCoordinator else {
            throw SCMError.documentCoordinatorRequired
        }
        guard let root = activeRepositoryRoot() else {
            throw SCMError.failed("no repository root for dirty-buffer check")
        }
        let relative: [String]
        if wholeRepository {
            relative = []
        } else {
            relative = try uris.map { uri in
                guard let path = uri.fileURL?.path else {
                    return uri.rawValue
                }
                let full = URL(fileURLWithPath: path).standardizedFileURL
                let rootURL = root.standardizedFileURL
                var rel = String(full.path.dropFirst(rootURL.path.count))
                if rel.hasPrefix("/") { rel = String(rel.dropFirst()) }
                return rel
            }
        }
        try await coordinator.assertClean(repositoryRoot: root, relativePaths: relative)
    }

    private func publishStaleSnapshot() async {
        let repoID = activeID ?? "unknown"
        statusSequence &+= 1
        let stale = SCMStatusSnapshot(
            repositoryID: repoID,
            statuses: lastStatus,
            isStale: true,
            sequence: statusSequence
        )
        lastSnapshot = stale
        await statusHub.publish(stale)
    }

    private func scheduleDebouncedRefresh() {
        watchDebounceTask?.cancel()
        let delay = watchDebounce
        watchDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            _ = try? await self.refresh()
        }
    }
}

/// Weak box so FSEvents callbacks can hop into the service actor without retaining cycles.
private final class UncheckedServiceBox: @unchecked Sendable {
    weak var service: SourceControlService?
    init(_ service: SourceControlService) { self.service = service }
}

/// Explicit unavailable provider for iOS / fail-closed profiles.
public struct UnavailableSourceControlProvider: SourceControlProvider {
    public let id: String
    public let reason: String
    public var repositoryIdentity: SCMRepositoryIdentity {
        SCMRepositoryIdentity(rawValue: id)
    }

    public init(id: String = "unavailable", reason: String) {
        self.id = id
        self.reason = reason
    }

    public func status() async throws -> [SCMFileStatus] {
        throw SCMError.unsupported(reason)
    }

    public func branches() async throws -> SCMBranchList {
        throw SCMError.unsupported(reason)
    }
}
