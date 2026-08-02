import CodeEditorDocuments
import Foundation

/// Decision for a single dirty document during close (WSP-001).
public enum CloseDecision: Sendable, Hashable {
    case save
    case discard
    case cancel
}

/// Candidate document about to lose its last editor lease.
public struct CloseCandidate: Sendable, Hashable {
    public var documentID: DocumentID
    public var uri: DocumentURI
    public var isDirty: Bool
    public var remainingTabCount: Int

    public init(
        documentID: DocumentID,
        uri: DocumentURI,
        isDirty: Bool,
        remainingTabCount: Int
    ) {
        self.documentID = documentID
        self.uri = uri
        self.isDirty = isDirty
        self.remainingTabCount = remainingTabCount
    }
}

/// Host UI/policy bridge for dirty-close transactions.
public protocol WorkspaceCloseDelegate: AnyObject, Sendable {
    func decideClose(_ documents: [CloseCandidate]) async -> [DocumentID: CloseDecision]
}

/// Result of a close transaction.
public enum CloseTransactionResult: Sendable, Equatable {
    case closed
    /// User or policy cancelled; no tabs/documents were removed.
    case cancelled
    /// Save failed for one or more documents; nothing was closed.
    case saveFailed(DocumentID, String)
}

/// Gathered decisions before any save/close mutation (WSP-N03 decision phase).
public struct BulkCloseDecisionPlan: Sendable {
    public var candidates: [CloseCandidate]
    public var decisions: [DocumentID: CloseDecision]
    public var atomicity: BulkCloseAtomicity

    public init(
        candidates: [CloseCandidate],
        decisions: [DocumentID: CloseDecision],
        atomicity: BulkCloseAtomicity
    ) {
        self.candidates = candidates
        self.decisions = decisions
        self.atomicity = atomicity
    }

    /// True when any dirty candidate chose cancel.
    public var hasCancel: Bool {
        candidates.contains { decisions[$0.documentID] == .cancel }
    }
}

/// Central close coordinator — every tab/pane/window close path must use this (WSP-001 / WSP-N03).
@MainActor
public final class WorkspaceCloseCoordinator {
    public weak var delegate: (any WorkspaceCloseDelegate)?
    public var defaultPolicy: DirtyTabClosePolicy

    public init(defaultPolicy: DirtyTabClosePolicy = .prompt) {
        self.defaultPolicy = defaultPolicy
    }

    /// Resolves decisions for dirty documents that would be orphaned by the proposed tab removals.
    public func resolveDecisions(
        candidates: [CloseCandidate],
        policy: DirtyTabClosePolicy? = nil
    ) async -> [DocumentID: CloseDecision] {
        let dirty = candidates.filter(\.isDirty)
        guard !dirty.isEmpty else {
            return Dictionary(uniqueKeysWithValues: candidates.map { ($0.documentID, .discard) })
        }
        let policy = policy ?? defaultPolicy
        switch policy {
        case .save:
            return Dictionary(uniqueKeysWithValues: dirty.map { ($0.documentID, .save) })
        case .discard:
            return Dictionary(uniqueKeysWithValues: dirty.map { ($0.documentID, .discard) })
        case .cancel:
            return Dictionary(uniqueKeysWithValues: dirty.map { ($0.documentID, .cancel) })
        case .prompt:
            if let delegate {
                // Decision phase: host sees **all** dirty candidates together (WSP-N03).
                return await delegate.decideClose(dirty)
            }
            // Fail closed: without a host delegate, never discard dirty data.
            return Dictionary(uniqueKeysWithValues: dirty.map { ($0.documentID, .cancel) })
        }
    }

    /// Decision phase only — no filesystem or tab mutation (WSP-N03).
    public func planBulkClose(
        candidates: [CloseCandidate],
        policy: DirtyTabClosePolicy? = nil,
        atomicity: BulkCloseAtomicity
    ) async -> BulkCloseDecisionPlan {
        let decisions = await resolveDecisions(candidates: candidates, policy: policy)
        return BulkCloseDecisionPlan(
            candidates: candidates,
            decisions: decisions,
            atomicity: atomicity
        )
    }
}
