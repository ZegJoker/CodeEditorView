import CodeEditorCore
import Foundation

/// Host decision when a conflict-safe save detects external modification (DOC-N02).
public enum SaveConflictPolicy: Sendable, Hashable, Codable {
    case overwrite
    case cancel
    /// Host should open save-as / conflict UI; this layer returns ``DocumentSaveOutcome/conflict``.
    case requireHostDecision
}

/// Durability level for a save (DOC-N10).
public enum SaveDurability: Sendable, Hashable, Codable {
    /// Best-effort write (still atomic replace when possible).
    case bestEffort
    /// fsync content, atomic replace, fsync parent directory.
    case durable
}

/// Authoritative save request used by every save path (DOC-N02).
public struct DocumentSaveRequest: Sendable, Hashable {
    public let snapshot: DocumentSnapshot
    public let target: DocumentURI
    public let encoding: DocumentEncoding
    public let expectedIdentity: DocumentFileIdentity?
    public let conflictPolicy: SaveConflictPolicy
    public let durability: SaveDurability

    public init(
        snapshot: DocumentSnapshot,
        target: DocumentURI,
        encoding: DocumentEncoding,
        expectedIdentity: DocumentFileIdentity?,
        conflictPolicy: SaveConflictPolicy = .requireHostDecision,
        durability: SaveDurability = .durable
    ) {
        self.snapshot = snapshot
        self.target = target
        self.encoding = encoding
        self.expectedIdentity = expectedIdentity
        self.conflictPolicy = conflictPolicy
        self.durability = durability
    }
}

/// Result of a conflict-aware save (DOC-N02).
public enum DocumentSaveOutcome: Sendable, Equatable {
    case saved(DocumentFileIdentity?)
    case conflict(live: DocumentFileIdentity?, change: DocumentFileChange)
    case cancelled
    /// Provider cannot compare identities; never silent success under conflict policy.
    case unsupportedConflictDetection
}

/// Content-state savepoint for dirty tracking (DOC-N01).
public struct DocumentSavepoint: Sendable, Hashable, Codable {
    public let contentState: DocumentContentStateID
    public let fileIdentity: DocumentFileIdentity?
    public let encoding: DocumentEncoding
    public let lineEnding: LineEnding

    public init(
        contentState: DocumentContentStateID,
        fileIdentity: DocumentFileIdentity? = nil,
        encoding: DocumentEncoding,
        lineEnding: LineEnding
    ) {
        self.contentState = contentState
        self.fileIdentity = fileIdentity
        self.encoding = encoding
        self.lineEnding = lineEnding
    }
}

/// Legacy alias retained for call-site migration.
public typealias SaveResult = DocumentSaveOutcome
