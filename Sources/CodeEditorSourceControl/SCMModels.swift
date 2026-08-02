import CodeEditorCore
import CodeEditorDocuments
import Foundation

// MARK: - Repository identity (SCM-N01)

/// Stable per-repository identity derived from a canonical root path (not a constant `"git"`).
public struct SCMRepositoryIdentity: Sendable, Hashable, Codable, RawRepresentable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// Identity from symlink-resolved, standardized absolute path.
    public static func git(repositoryRoot: URL) -> SCMRepositoryIdentity {
        let canonical = repositoryRoot.resolvingSymlinksInPath().standardizedFileURL
        return SCMRepositoryIdentity(rawValue: "git:\(canonical.path)")
    }
}

// MARK: - Path state (dual index/worktree — SCM-N04)

/// Single-side path state (index X or worktree Y porcelain column).
public enum SCMPathState: String, Sendable, Hashable, Codable, CaseIterable {
    case unmodified
    case modified
    case added
    case deleted
    case renamed
    case copied
    case unmerged
    case untracked
    case ignored
    case typeChanged
}

/// Aggregated display state for badges (derived from dual columns).
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
    case typeChanged
}

public struct SCMFileStatus: Sendable, Hashable, Identifiable {
    public var id: String { uri.rawValue }
    public var uri: DocumentURI
    public var path: String
    /// Index (staged) column — porcelain X.
    public var index: SCMPathState
    /// Worktree column — porcelain Y.
    public var worktree: SCMPathState
    public var originalPath: String?
    public var isSubmodule: Bool
    /// Intent-to-add (`git add -N`) when index is added without full content.
    public var isIntentToAdd: Bool
    /// True when either column is unmerged / conflict.
    public var unmerged: Bool

    public init(
        uri: DocumentURI,
        path: String,
        index: SCMPathState,
        worktree: SCMPathState,
        originalPath: String? = nil,
        isSubmodule: Bool = false,
        isIntentToAdd: Bool = false,
        unmerged: Bool = false
    ) {
        self.uri = uri
        self.path = path
        self.index = index
        self.worktree = worktree
        self.originalPath = originalPath
        self.isSubmodule = isSubmodule
        self.isIntentToAdd = isIntentToAdd
        self.unmerged = unmerged
            || index == .unmerged
            || worktree == .unmerged
    }

    /// Compatibility initializer mapping a single display state + staged flag.
    public init(
        uri: DocumentURI,
        path: String,
        state: SCMState,
        staged: Bool = false,
        originalPath: String? = nil,
        isSubmodule: Bool = false
    ) {
        let pathState = SCMPathState.from(display: state)
        let index: SCMPathState
        let worktree: SCMPathState
        switch state {
        case .untracked:
            index = .untracked
            worktree = .untracked
        case .ignored:
            index = .ignored
            worktree = .ignored
        case .conflicted:
            index = .unmerged
            worktree = .unmerged
        default:
            if staged {
                index = pathState
                worktree = .unmodified
            } else {
                index = .unmodified
                worktree = pathState
            }
        }
        self.init(
            uri: uri,
            path: path,
            index: index,
            worktree: worktree,
            originalPath: originalPath,
            isSubmodule: isSubmodule || state == .submodule,
            isIntentToAdd: false,
            unmerged: state == .conflicted
        )
    }

    /// True when the index column has a non-empty change (staged).
    public var staged: Bool {
        switch index {
        case .unmodified, .untracked, .ignored:
            return false
        default:
            return true
        }
    }

    public var hasUnstagedChanges: Bool {
        switch worktree {
        case .unmodified, .ignored:
            return false
        case .untracked:
            return true
        default:
            return true
        }
    }

    /// Primary display state for UI badges.
    public var state: SCMState {
        if isSubmodule { return .submodule }
        if unmerged { return .conflicted }
        if index == .untracked || worktree == .untracked { return .untracked }
        if index == .ignored || worktree == .ignored { return .ignored }
        if index == .renamed || worktree == .renamed { return .renamed }
        if index == .copied || worktree == .copied { return .copied }
        if index == .typeChanged || worktree == .typeChanged { return .typeChanged }
        if index == .deleted || worktree == .deleted { return .deleted }
        if index == .added || worktree == .added { return .added }
        if index == .modified || worktree == .modified { return .modified }
        return .unmodified
    }
}

extension SCMPathState {
    static func from(display state: SCMState) -> SCMPathState {
        switch state {
        case .unmodified: return .unmodified
        case .modified: return .modified
        case .added: return .added
        case .deleted: return .deleted
        case .untracked: return .untracked
        case .conflicted: return .unmerged
        case .ignored: return .ignored
        case .renamed: return .renamed
        case .copied: return .copied
        case .submodule: return .modified
        case .typeChanged: return .typeChanged
        }
    }

    static func fromPorcelain(_ c: Character) -> SCMPathState {
        switch c {
        case " ": return .unmodified
        case "M": return .modified
        case "A": return .added
        case "D": return .deleted
        case "R": return .renamed
        case "C": return .copied
        case "U": return .unmerged
        case "?": return .untracked
        case "!": return .ignored
        case "T": return .typeChanged
        case "S": return .modified  // submodule marker handled separately
        default: return .unmodified
        }
    }
}

// MARK: - Branches / tags / remotes / log

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

// MARK: - Diff / hunks (SCM-N07)

public struct SCMDiffHunk: Sendable, Hashable {
    public var header: String
    public var oldStart: Int
    public var oldCount: Int
    public var newStart: Int
    public var newCount: Int
    public var lines: [String]
    public var noNewlineAtEndOfFile: Bool

    public init(
        header: String,
        oldStart: Int,
        oldCount: Int,
        newStart: Int,
        newCount: Int,
        lines: [String],
        noNewlineAtEndOfFile: Bool = false
    ) {
        self.header = header
        self.oldStart = oldStart
        self.oldCount = oldCount
        self.newStart = newStart
        self.newCount = newCount
        self.lines = lines
        self.noNewlineAtEndOfFile = noNewlineAtEndOfFile
    }
}

public struct SCMDiff: Sendable, Hashable {
    public var path: String
    public var raw: String
    public var hunks: [SCMDiffHunk]
    public var isBinary: Bool

    public init(path: String, raw: String, hunks: [SCMDiffHunk] = [], isBinary: Bool = false) {
        self.path = path
        self.raw = raw
        self.hunks = hunks
        self.isBinary = isBinary
    }
}

public enum SCMConflictSide: String, Sendable, Hashable {
    case ours
    case theirs
    case base
}

// MARK: - Errors

public enum SCMError: Error, Sendable, Equatable {
    case noProvider
    case failed(String)
    case notARepository
    case unsupported(String)
    case pathEscape(String)
    case untrusted
    case cancelled
    case notFound(String)
    /// Auth required but no callback configured (SCM-N02 fail-closed).
    case authRequired
    case authFailed(String)
    /// Destructive op blocked by open dirty editor buffers (SCM-N06).
    case dirtyDocuments([String])
    /// Destructive op attempted without a bound document coordinator (SCM-N06 fail-closed).
    case documentCoordinatorRequired
    /// Process stdout/stderr exceeded bound (SCM-N09).
    case outputOverflow(stream: String, droppedBytes: Int)
    /// `git apply --check` failed before mutation (SCM-N07).
    case patchCheckFailed(String)
    case operationInProgress(String)
    case staleStatus
}

// MARK: - Auth (SCM-N02)

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

// MARK: - Progress (SCM-N03)

public enum SCMProgressEvent: Sendable, Hashable {
    case started(operation: String, repositoryID: String)
    case message(String)
    case fraction(Double)
    case finished(operation: String, success: Bool)
    case cancelled(operation: String)
}

public enum SCMOperationCategory: Sendable, Hashable {
    case read
    case mutate
    case network
}

// MARK: - Status snapshot stream (SCM-N08)

public struct SCMStatusSnapshot: Sendable, Hashable {
    public var repositoryID: String
    public var statuses: [SCMFileStatus]
    public var isStale: Bool
    public var sequence: UInt64

    public init(
        repositoryID: String,
        statuses: [SCMFileStatus],
        isStale: Bool = false,
        sequence: UInt64 = 0
    ) {
        self.repositoryID = repositoryID
        self.statuses = statuses
        self.isStale = isStale
        self.sequence = sequence
    }
}

// MARK: - Log sanitizer (SCM-N02 / SCM-N09)

public enum SCMLogSanitizer {
    /// Redact credentials and secrets from process / error text.
    public static func sanitize(_ text: String) -> String {
        var result = text
        // user:password@host
        if let re = try? NSRegularExpression(
            pattern: #"(?i)(://)([^:@/\s]+):([^@/\s]+)@"#,
            options: []
        ) {
            result = re.stringByReplacingMatches(
                in: result,
                options: [],
                range: NSRange(result.startIndex..., in: result),
                withTemplate: "$1$2:***@"
            )
        }
        // password= / pass= / token=
        if let re = try? NSRegularExpression(
            pattern: #"(?i)\b(password|passwd|pass|token|secret|authorization)\s*[=:]\s*\S+"#,
            options: []
        ) {
            result = re.stringByReplacingMatches(
                in: result,
                options: [],
                range: NSRange(result.startIndex..., in: result),
                withTemplate: "$1=***"
            )
        }
        // Bearer tokens
        if let re = try? NSRegularExpression(
            pattern: #"(?i)Bearer\s+\S+"#,
            options: []
        ) {
            result = re.stringByReplacingMatches(
                in: result,
                options: [],
                range: NSRange(result.startIndex..., in: result),
                withTemplate: "Bearer ***"
            )
        }
        return result
    }
}

// MARK: - Provider protocol

/// Full source-control provider surface. Unsupported ops must throw ``SCMError/unsupported``.
public protocol SourceControlProvider: Sendable {
    var id: String { get }
    var repositoryIdentity: SCMRepositoryIdentity { get }
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

extension SourceControlProvider {
    public var repositoryIdentity: SCMRepositoryIdentity {
        SCMRepositoryIdentity(rawValue: id)
    }

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
