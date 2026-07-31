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
        let key = document.uri.canonicalized()
        byURI[key] = document.id
        byURI[document.uri] = document.id
    }

    public func document(id: DocumentID) -> TextDocument? {
        byID[id]
    }

    public func document(uri: DocumentURI) -> TextDocument? {
        let key = uri.canonicalized()
        if let id = byURI[key] { return byID[id] }
        if let id = byURI[uri] { return byID[id] }
        return nil
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
        let canonical = document.uri.canonicalized()
        // Drop stale URI keys pointing at this id.
        for (uri, id) in byURI where id == document.id && uri != document.uri && uri != canonical {
            byURI.removeValue(forKey: uri)
        }
        byURI[document.uri] = document.id
        byURI[canonical] = document.id
        byID[document.id] = document
    }
}
