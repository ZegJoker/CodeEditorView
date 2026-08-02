import CodeEditorDocuments
import Foundation

/// Owner kind for a document lease (view tab, preview, language session, extension).
public enum DocumentLeaseOwner: Sendable, Hashable {
    case tab(EditorTabID)
    case preview(EditorTabID)
    case languageSession(String)
    case extensionHost(String)
    case other(String)
}

/// Reference-counted document leases (WSP-006 / audit §8.8).
///
/// A document may be opened in multiple editor tabs; closing one view must not
/// dispose the document until the last lease is released.
@MainActor
public final class DocumentLeaseRegistry {
    private struct Lease: Hashable {
        var documentID: DocumentID
        var owner: DocumentLeaseOwner
    }

    private var leases: [Lease] = []
    /// Optional hooks invoked when the last lease for a document is released.
    public var onFinalRelease: ((DocumentID) -> Void)?

    public init() {}

    /// Acquire a lease. Duplicate (document, owner) pairs are idempotent.
    public func acquire(documentID: DocumentID, owner: DocumentLeaseOwner) {
        let lease = Lease(documentID: documentID, owner: owner)
        if !leases.contains(lease) {
            leases.append(lease)
        }
    }

    /// Release a lease. Returns `true` if this was the final lease for the document.
    @discardableResult
    public func release(documentID: DocumentID, owner: DocumentLeaseOwner) -> Bool {
        let lease = Lease(documentID: documentID, owner: owner)
        leases.removeAll { $0 == lease }
        let remaining = count(for: documentID)
        if remaining == 0 {
            onFinalRelease?(documentID)
            return true
        }
        return false
    }

    /// Release every lease owned by a tab (used when force-closing a tab).
    @discardableResult
    public func releaseAll(forTab tabID: EditorTabID) -> [DocumentID] {
        let owned = leases.filter {
            if case .tab(let id) = $0.owner, id == tabID { return true }
            if case .preview(let id) = $0.owner, id == tabID { return true }
            return false
        }
        var finalized: [DocumentID] = []
        for lease in owned {
            if release(documentID: lease.documentID, owner: lease.owner) {
                finalized.append(lease.documentID)
            }
        }
        return finalized
    }

    public func count(for documentID: DocumentID) -> Int {
        leases.filter { $0.documentID == documentID }.count
    }

    public func hasLeases(for documentID: DocumentID) -> Bool {
        count(for: documentID) > 0
    }

    public func owners(for documentID: DocumentID) -> [DocumentLeaseOwner] {
        leases.filter { $0.documentID == documentID }.map(\.owner)
    }

    public func removeAll() {
        leases.removeAll()
    }
}
