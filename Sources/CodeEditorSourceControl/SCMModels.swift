import CodeEditorDocuments
import Foundation

public enum SCMState: String, Sendable, Hashable, Codable, CaseIterable {
    case unmodified
    case modified
    case added
    case deleted
    case untracked
    case conflicted
    case ignored
    case renamed
    case copied
    case submodule
}

public struct SCMFileStatus: Sendable, Hashable, Identifiable {
    public var id: String { uri.rawValue }
    public var uri: DocumentURI
    public var path: String
    public var state: SCMState
    public var staged: Bool
    public var originalPath: String?
    public var isSubmodule: Bool

    public init(
        uri: DocumentURI,
        path: String,
        state: SCMState,
        staged: Bool = false,
        originalPath: String? = nil,
        isSubmodule: Bool = false
    ) {
        self.uri = uri
        self.path = path
        self.state = state
        self.staged = staged
        self.originalPath = originalPath
        self.isSubmodule = isSubmodule
    }
}

public struct SCMBranch: Sendable, Hashable, Identifiable {
    public var id: String { name }
    public var name: String
    public var isCurrent: Bool
    public var isRemote: Bool

    public init(name: String, isCurrent: Bool = false, isRemote: Bool = false) {
        self.name = name
        self.isCurrent = isCurrent
        self.isRemote = isRemote
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

public struct SCMTag: Sendable, Hashable, Identifiable {
    public var id: String { name }
    public var name: String
    public init(name: String) { self.name = name }
}

public struct SCMRemote: Sendable, Hashable, Identifiable {
    public var id: String { name }
    public var name: String
    public var url: String?
    public init(name: String, url: String? = nil) {
        self.name = name
        self.url = url
    }
}

public struct SCMCommit: Sendable, Hashable, Identifiable {
    public var id: String { hash }
    public var hash: String
    public var subject: String
    public var author: String?
    public var date: String?

    public init(hash: String, subject: String, author: String? = nil, date: String? = nil) {
        self.hash = hash
        self.subject = subject
        self.author = author
        self.date = date
    }
}

public struct SCMBlameLine: Sendable, Hashable {
    public var lineNumber: Int
    public var commitHash: String
    public var author: String?
    public var summary: String?
    public var content: String

    public init(lineNumber: Int, commitHash: String, author: String? = nil, summary: String? = nil, content: String) {
        self.lineNumber = lineNumber
        self.commitHash = commitHash
        self.author = author
        self.summary = summary
        self.content = content
    }
}

public struct SCMDiffHunk: Sendable, Hashable {
    public var header: String
    public var oldStart: Int
    public var oldCount: Int
    public var newStart: Int
    public var newCount: Int
    public var lines: [String]

    public init(
        header: String,
        oldStart: Int,
        oldCount: Int,
        newStart: Int,
        newCount: Int,
        lines: [String]
    ) {
        self.header = header
        self.oldStart = oldStart
        self.oldCount = oldCount
        self.newStart = newStart
        self.newCount = newCount
        self.lines = lines
    }
}

public struct SCMDiff: Sendable, Hashable {
    public var path: String
    public var raw: String
    public var hunks: [SCMDiffHunk]

    public init(path: String, raw: String, hunks: [SCMDiffHunk] = []) {
        self.path = path
        self.raw = raw
        self.hunks = hunks
    }
}

public enum SCMConflictSide: String, Sendable, Hashable {
    case ours
    case theirs
    case base
}

public enum SCMError: Error, Sendable, Equatable {
    case noProvider
    case failed(String)
    case notARepository
    case unsupported(String)
    case pathEscape(String)
    case untrusted
    case cancelled
    case notFound(String)
}

public struct SCMAuthRequest: Sendable {
    public var protocolName: String
    public var host: String
    public var path: String
    public init(protocolName: String, host: String, path: String) {
        self.protocolName = protocolName
        self.host = host
        self.path = path
    }
}

public struct SCMCredentials: Sendable {
    public var username: String?
    public var password: String?
    public init(username: String? = nil, password: String? = nil) {
        self.username = username
        self.password = password
    }
}

public protocol SCMAuthCallback: Sendable {
    func credentials(for request: SCMAuthRequest) async -> SCMCredentials?
}

public enum SCMProgressEvent: Sendable, Hashable {
    case started(String)
    case message(String)
    case finished(String)
}

/// Full source-control provider surface. Unsupported ops must throw ``SCMError/unsupported``.
public protocol SourceControlProvider: Sendable {
    var id: String { get }
    func status() async throws -> [SCMFileStatus]
    func branches() async throws -> SCMBranchList
    func tags() async throws -> [SCMTag]
    func remotes() async throws -> [SCMRemote]
    func log(limit: Int) async throws -> [SCMCommit]
    func blame(uri: DocumentURI) async throws -> [SCMBlameLine]
    func diff(uri: DocumentURI) async throws -> SCMDiff
    func stage(uris: [DocumentURI]) async throws
    func unstage(uris: [DocumentURI]) async throws
    func discard(uris: [DocumentURI]) async throws
    func stageHunk(_ hunk: SCMDiffHunk, uri: DocumentURI) async throws
    func unstageHunk(_ hunk: SCMDiffHunk, uri: DocumentURI) async throws
    func discardHunk(_ hunk: SCMDiffHunk, uri: DocumentURI) async throws
    func commit(message: String) async throws
    func checkout(branch: String) async throws
    func createBranch(_ name: String) async throws
    func deleteBranch(_ name: String) async throws
    func fetch(remote: String?) async throws
    func pull(remote: String?, branch: String?) async throws
    func push(remote: String?, branch: String?) async throws
    func resolveConflict(uri: DocumentURI, side: SCMConflictSide) async throws
    func cancel() async
}

public protocol SourceControlProviderDefaults {}

// No silent no-ops: defaults throw unsupported.
extension SourceControlProvider {
    public func tags() async throws -> [SCMTag] { throw SCMError.unsupported("tags") }
    public func remotes() async throws -> [SCMRemote] { throw SCMError.unsupported("remotes") }
    public func log(limit: Int) async throws -> [SCMCommit] { throw SCMError.unsupported("log") }
    public func blame(uri: DocumentURI) async throws -> [SCMBlameLine] { throw SCMError.unsupported("blame") }
    public func diff(uri: DocumentURI) async throws -> SCMDiff { throw SCMError.unsupported("diff") }
    public func stage(uris: [DocumentURI]) async throws { throw SCMError.unsupported("stage") }
    public func unstage(uris: [DocumentURI]) async throws { throw SCMError.unsupported("unstage") }
    public func discard(uris: [DocumentURI]) async throws { throw SCMError.unsupported("discard") }
    public func stageHunk(_ hunk: SCMDiffHunk, uri: DocumentURI) async throws {
        throw SCMError.unsupported("stageHunk")
    }
    public func unstageHunk(_ hunk: SCMDiffHunk, uri: DocumentURI) async throws {
        throw SCMError.unsupported("unstageHunk")
    }
    public func discardHunk(_ hunk: SCMDiffHunk, uri: DocumentURI) async throws {
        throw SCMError.unsupported("discardHunk")
    }
    public func commit(message: String) async throws { throw SCMError.unsupported("commit") }
    public func checkout(branch: String) async throws { throw SCMError.unsupported("checkout") }
    public func createBranch(_ name: String) async throws { throw SCMError.unsupported("createBranch") }
    public func deleteBranch(_ name: String) async throws { throw SCMError.unsupported("deleteBranch") }
    public func fetch(remote: String?) async throws { throw SCMError.unsupported("fetch") }
    public func pull(remote: String?, branch: String?) async throws { throw SCMError.unsupported("pull") }
    public func push(remote: String?, branch: String?) async throws { throw SCMError.unsupported("push") }
    public func resolveConflict(uri: DocumentURI, side: SCMConflictSide) async throws {
        throw SCMError.unsupported("resolveConflict")
    }
    public func cancel() async {}
}
