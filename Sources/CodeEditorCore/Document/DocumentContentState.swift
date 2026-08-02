import Foundation

/// Identity of a document's text content independent of monotonic event generation.
///
/// Undo restores a prior content state; save records a content-state savepoint.
/// ``DocumentVersion`` remains the synchronization / ordering counter (DOC-N01).
public struct DocumentContentStateID: Hashable, Sendable, Codable, Equatable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

/// Ownership model for mutable document storage (CORE-N01).
///
/// Mutations must run on the owning isolation. Cross-isolation clients use
/// ``DocumentSnapshot`` only.
public enum DocumentOwnershipModel: Sendable, Hashable, Codable {
    /// All mutations hop to / run on the main actor.
    case mainActor
}

/// Result of checking document storage ownership without trapping (CORE-N01).
public enum DocumentOwnershipCheckResult: Sendable, Hashable, Codable {
    /// Caller is on the owning isolation (main thread / main queue).
    case ok
    /// Caller is off the owning isolation; ``DocumentStore/assertOwnership()`` will trap.
    case violated
}
