import Foundation
import CodeEditorDocuments

public actor SourceControlService {
    private var provider: (any SourceControlProvider)?
    private var continuation: AsyncStream<[SCMFileStatus]>.Continuation?
    public let statusStream: AsyncStream<[SCMFileStatus]>
    public private(set) var lastStatus: [SCMFileStatus] = []

    public init() {
        var cont: AsyncStream<[SCMFileStatus]>.Continuation!
        self.statusStream = AsyncStream { cont = $0 }
        self.continuation = cont
    }

    public func setProvider(_ provider: (any SourceControlProvider)?) {
        self.provider = provider
    }

    public func currentProviderID() -> String? {
        provider?.id
    }

    @discardableResult
    public func refresh() async throws -> [SCMFileStatus] {
        guard let provider else { throw SCMError.noProvider }
        let status = try await provider.status()
        lastStatus = status
        continuation?.yield(status)
        return status
    }

    public func branches() async throws -> SCMBranchList {
        guard let provider else { throw SCMError.noProvider }
        return try await provider.branches()
    }

    public func diff(uri: DocumentURI) async throws -> String {
        guard let provider else { throw SCMError.noProvider }
        return try await provider.diff(uri: uri)
    }

    public func stage(uris: [DocumentURI]) async throws {
        guard let provider else { throw SCMError.noProvider }
        try await provider.stage(uris: uris)
        _ = try await refresh()
    }

    public func commit(message: String) async throws {
        guard let provider else { throw SCMError.noProvider }
        try await provider.commit(message: message)
        _ = try await refresh()
    }
}
