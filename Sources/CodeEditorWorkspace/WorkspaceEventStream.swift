import CodeEditorCore
import Foundation

/// Sequenced envelope for workspace filesystem events (WSP-N07).
public struct WorkspaceEventEnvelope<Event: Sendable>: Sendable {
    public let sequence: UInt64
    public let event: Event

    public init(sequence: UInt64, event: Event) {
        self.sequence = sequence
        self.event = event
    }
}

/// Authoritative subscription items: snapshot first, then sequenced events / gaps (WSP-N07).
public enum WorkspaceStreamItem<Event: Sendable>: Sendable {
    case snapshot(WorkspaceFilesystemSnapshot, sequence: UInt64)
    case event(WorkspaceEventEnvelope<Event>)
    case gap(expected: UInt64, actual: UInt64)
}

/// Lightweight filesystem snapshot delivered on subscribe (WSP-N07).
public struct WorkspaceFilesystemSnapshot: Sendable, Hashable {
    public var roots: [WorkspaceRoot]
    public var sequence: UInt64

    public init(roots: [WorkspaceRoot], sequence: UInt64) {
        self.roots = roots
        self.sequence = sequence
    }
}

/// Progress events for background filesystem workers (WSP-N04).
public enum WorkspaceFSProgressEvent: Sendable, Hashable {
    case listingStarted(WorkspaceItemID)
    case listingBatch(WorkspaceItemID, count: Int)
    case listingFinished(WorkspaceItemID, total: Int)
    case mutationStarted(String)
    case mutationFinished(String)
    case cancelled(String)
    case limited(reason: String)
}

/// Caps for blocking filesystem work (WSP-N04).
public struct WorkspaceFilesystemLimits: Sendable, Hashable, Codable {
    public var maxDepth: Int
    public var maxFileCount: Int
    public var maxBytes: UInt64
    public var batchSize: Int
    public var maxElapsed: TimeInterval

    public init(
        maxDepth: Int = 64,
        maxFileCount: Int = 100_000,
        maxBytes: UInt64 = 2_000_000_000,
        batchSize: Int = 64,
        maxElapsed: TimeInterval = 120
    ) {
        self.maxDepth = max(1, maxDepth)
        self.maxFileCount = max(1, maxFileCount)
        self.maxBytes = maxBytes
        self.batchSize = max(1, batchSize)
        self.maxElapsed = max(0.1, maxElapsed)
    }

    public static let `default` = WorkspaceFilesystemLimits()
}

/// Host policy for hidden files, packages, and explicit reveals (WSP-N09).
public enum WorkspaceHiddenFilePolicy: String, Sendable, Hashable, Codable, CaseIterable {
    /// List every entry (still subject to ``WorkspaceSettings/excludedNames``).
    case showAll
    /// Skip names beginning with `.` unless explicitly revealed.
    case hideDotfiles
    /// Skip names beginning with `.` and common package bundles (extension-based).
    case hideDotfilesAndPackages
}

/// Atomicity policy for bulk close (WSP-N03).
public enum BulkCloseAtomicity: String, Sendable, Hashable, Codable, CaseIterable {
    /// Gather all decisions first; any cancel aborts without saving/closing (default).
    case allOrNothing
    /// Apply decisions independently; cancel on one does not undo earlier closes.
    case bestEffort
}
