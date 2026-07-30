import Foundation
import CodeEditorDocuments

public enum SCMState: String, Sendable, Hashable, Codable, CaseIterable {
    case unmodified
    case modified
    case added
    case deleted
    case untracked
    case conflicted
    case ignored
    case renamed
}

public struct SCMFileStatus: Sendable, Hashable, Identifiable {
    public var id: String { uri.rawValue }
    public var uri: DocumentURI
    public var path: String
    public var state: SCMState
    public var staged: Bool

    public init(uri: DocumentURI, path: String, state: SCMState, staged: Bool = false) {
        self.uri = uri
        self.path = path
        self.state = state
        self.staged = staged
    }
}

public struct SCMBranch: Sendable, Hashable, Identifiable {
    public var id: String { name }
    public var name: String
    public var isCurrent: Bool

    public init(name: String, isCurrent: Bool = false) {
        self.name = name
        self.isCurrent = isCurrent
    }
}

public struct SCMBranchList: Sendable, Hashable {
    public var branches: [SCMBranch]
    public var current: String?

    public init(branches: [SCMBranch] = [], current: String? = nil) {
        self.branches = branches
        self.current = current
    }
}

public enum SCMError: Error, Sendable, Equatable {
    case noProvider
    case failed(String)
    case notARepository
}

public protocol SourceControlProvider: Sendable {
    var id: String { get }
    func status() async throws -> [SCMFileStatus]
    func branches() async throws -> SCMBranchList
    func diff(uri: DocumentURI) async throws -> String
    func stage(uris: [DocumentURI]) async throws
    func unstage(uris: [DocumentURI]) async throws
    func commit(message: String) async throws
    func discard(uris: [DocumentURI]) async throws
}

public extension SourceControlProvider {
    func stage(uris: [DocumentURI]) async throws {}
    func unstage(uris: [DocumentURI]) async throws {}
    func commit(message: String) async throws {}
    func discard(uris: [DocumentURI]) async throws {}
}
