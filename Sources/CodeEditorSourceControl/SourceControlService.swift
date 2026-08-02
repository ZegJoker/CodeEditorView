import CodeEditorCore
import CodeEditorDocuments
import Foundation

public actor SourceControlService {
    private var providers: [String: any SourceControlProvider] = [:]
    private var activeID: String?
    private var continuation: AsyncStream<[SCMFileStatus]>.Continuation?
    public let statusStream: AsyncStream<[SCMFileStatus]>
    public private(set) var lastStatus: [SCMFileStatus] = []
    public var trusted: Bool = true

    public init() {
        var cont: AsyncStream<[SCMFileStatus]>.Continuation!
        self.statusStream = AsyncStream { cont = $0 }
        self.continuation = cont
    }

    public func setProvider(_ provider: (any SourceControlProvider)?) {
        if let provider {
            providers[provider.id] = provider
            activeID = provider.id
        } else if let activeID {
            providers.removeValue(forKey: activeID)
            self.activeID = providers.keys.sorted().first
        }
    }

    public func registerProvider(_ provider: any SourceControlProvider) {
        providers[provider.id] = provider
        if activeID == nil { activeID = provider.id }
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

    @discardableResult
    public func refresh() async throws -> [SCMFileStatus] {
        let p = try provider()
        let status = try await p.status()
        lastStatus = status
        continuation?.yield(status)
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
    ) {
        for root in roots {
            if let repo = GitRepositoryDiscovery.discover(from: root) {
                let provider = GitCLIProvider(
                    repositoryRoot: repo,
                    platformProfile: platformProfile,
                    trusted: trusted
                )
                providers["git:\(repo.path)"] = provider
                if activeID == nil { activeID = "git:\(repo.path)" }
            }
        }
    }

    private func requireTrusted() throws {
        if !trusted { throw SCMError.untrusted }
    }
}

/// Explicit unavailable provider for iOS / fail-closed profiles.
public struct UnavailableSourceControlProvider: SourceControlProvider {
    public let id: String
    public let reason: String

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
