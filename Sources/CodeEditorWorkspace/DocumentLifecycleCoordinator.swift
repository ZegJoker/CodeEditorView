import CodeEditorCore
import CodeEditorDocuments
import Foundation

/// Why a document is being closed/removed (WSP-N10).
public enum DocumentLifecycleCloseReason: Sendable, Hashable {
    case explicit
    case finalLeaseRelease
    case deletedFromWorkspace
    case renamedAway
    case workspaceShutdown
    case transactionRollback
}

/// Errors from the document lifecycle coordinator (WSP-N10).
public enum DocumentLifecycleError: Error, Sendable, Equatable {
    case notRegistered(DocumentID)
    case alreadyRegistered(DocumentID)
    case dirtyRequiresDecision
}

/// Sole owner of document registry mutations for workspace hosts (WSP-N10).
///
/// Workspace, workbench, SCM, search-replace, and extensions must open/move/rename/close
/// documents through this coordinator — never via ad-hoc `DocumentRegistry.remove`.
@MainActor
public final class DocumentLifecycleCoordinator {
    public private(set) var registry: DocumentRegistry
    /// Optional lease registry for final-release coordination.
    public weak var leases: DocumentLeaseRegistry?

    public private(set) var registeredIDs: Set<DocumentID> = []

    /// Host hooks (LSP close, syntax dispose, recovery) — fail-closed optional.
    public var willClose: (@MainActor (TextDocument, DocumentLifecycleCloseReason) async -> Void)?
    public var didOpen: (@MainActor (TextDocument) async -> Void)?
    public var didRename: (@MainActor (TextDocument, DocumentURI, DocumentURI) async -> Void)?

    public init(registry: DocumentRegistry = DocumentRegistry()) {
        self.registry = registry
    }

    public var registeredCount: Int { registeredIDs.count }

    public func isRegistered(_ id: DocumentID) -> Bool {
        registeredIDs.contains(id)
    }

    /// Register an already-constructed document (open path).
    @discardableResult
    public func openExisting(_ document: TextDocument) async throws -> TextDocument {
        if registeredIDs.contains(document.id) {
            return document
        }
        if let existing = registry.document(id: document.id) {
            registeredIDs.insert(existing.id)
            return existing
        }
        if let byURI = registry.document(uri: document.uri) {
            registeredIDs.insert(byURI.id)
            return byURI
        }
        registry.register(document)
        registeredIDs.insert(document.id)
        if let didOpen {
            await didOpen(document)
        }
        return document
    }

    /// Load from provider and register.
    @discardableResult
    public func open(
        uri: DocumentURI,
        provider: any DocumentContentProvider
    ) async throws -> TextDocument {
        if let existing = registry.document(uri: uri) {
            registeredIDs.insert(existing.id)
            return existing
        }
        let doc = TextDocument(uri: uri, text: "")
        try await doc.load(from: provider, uri: uri)
        registry.register(doc)
        registeredIDs.insert(doc.id)
        if let didOpen {
            await didOpen(doc)
        }
        return doc
    }

    /// Retarget URI after filesystem rename/move.
    public func rename(documentID: DocumentID, to newURI: DocumentURI) async throws {
        guard let doc = registry.document(id: documentID) else {
            throw DocumentLifecycleError.notRegistered(documentID)
        }
        let old = doc.uri
        doc.setURI(newURI)
        registry.reindexURI(for: doc)
        if let didRename {
            await didRename(doc, old, newURI)
        }
    }

    /// Remove from registry after host has resolved dirty/leases.
    @discardableResult
    public func close(
        documentID: DocumentID,
        reason: DocumentLifecycleCloseReason
    ) async throws -> TextDocument? {
        guard let doc = registry.document(id: documentID) else {
            registeredIDs.remove(documentID)
            return nil
        }
        if let willClose {
            await willClose(doc, reason)
        }
        let removed = registry.remove(id: documentID)
        registeredIDs.remove(documentID)
        return removed
    }

    /// Final lease release path — only lifecycle may drop the registry entry.
    public func handleFinalLeaseRelease(documentID: DocumentID) {
        Task { @MainActor in
            _ = try? await self.close(documentID: documentID, reason: .finalLeaseRelease)
        }
    }

    /// Synchronous final-lease path used when already on MainActor (lease callback).
    public func handleFinalLeaseReleaseSync(documentID: DocumentID) {
        if let willClose, let doc = registry.document(id: documentID) {
            // Fire-and-forget async hook; registry remove is synchronous and authoritative.
            Task { await willClose(doc, .finalLeaseRelease) }
        }
        _ = registry.remove(id: documentID)
        registeredIDs.remove(documentID)
    }

    public func document(id: DocumentID) -> TextDocument? {
        registry.document(id: id)
    }

    public func document(uri: DocumentURI) -> TextDocument? {
        registry.document(uri: uri)
    }

    public var documents: [TextDocument] {
        registry.documents
    }
}
