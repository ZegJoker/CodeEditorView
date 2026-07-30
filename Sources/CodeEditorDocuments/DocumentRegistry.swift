import Foundation

/// In-process registry of open ``TextDocument`` instances.
@MainActor
public final class DocumentRegistry {
    public static let shared = DocumentRegistry()

    private var byID: [DocumentID: TextDocument] = [:]
    private var byURI: [DocumentURI: DocumentID] = [:]

    public init() {}

    public func register(_ document: TextDocument) {
        byID[document.id] = document
        byURI[document.uri] = document.id
    }

    public func document(id: DocumentID) -> TextDocument? {
        byID[id]
    }

    public func document(uri: DocumentURI) -> TextDocument? {
        guard let id = byURI[uri] else { return nil }
        return byID[id]
    }

    @discardableResult
    public func remove(id: DocumentID) -> TextDocument? {
        guard let doc = byID.removeValue(forKey: id) else { return nil }
        if byURI[doc.uri] == id {
            byURI.removeValue(forKey: doc.uri)
        }
        return doc
    }

    public func removeAll() {
        byID.removeAll()
        byURI.removeAll()
    }

    public var documents: [TextDocument] {
        Array(byID.values)
    }

    /// Updates URI index after ``TextDocument/setURI``.
    public func reindexURI(for document: TextDocument) {
        // Drop stale URI keys pointing at this id.
        for (uri, id) in byURI where id == document.id && uri != document.uri {
            byURI.removeValue(forKey: uri)
        }
        byURI[document.uri] = document.id
        byID[document.id] = document
    }
}
