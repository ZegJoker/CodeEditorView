import Foundation
import CodeEditorCore

/// Events emitted by a shared ``TextDocument``.
public enum TextDocumentEvent: Sendable {
    /// Transaction about to apply; snapshot is pre-edit.
    case willApply(EditTransaction, DocumentSnapshot)
    /// Transaction applied (content generation advanced).
    case didApply(AppliedEditTransaction)
    case dirtyStateDidChange(Bool)
    case uriDidChange(DocumentURI)
    /// Content replaced from an external source (reload / provider).
    case externalContentReplace(DocumentSnapshot)
}

/// Host policy when an external content change is detected.
public enum DocumentExternalChangePolicy: Sendable, Hashable, Codable {
    /// Ignore the external content.
    case ignore
    /// Replace content only when the document is clean.
    case reloadIfClean
    /// Always replace content (marks clean after replace).
    case alwaysReload
}

/// Result of loading document bytes through a ``DocumentContentProvider``.
public struct LoadedDocument: Sendable, Hashable {
    public var text: String
    public var encoding: DocumentEncoding
    public var lineEnding: LineEnding?

    public init(text: String, encoding: DocumentEncoding = .utf8, lineEnding: LineEnding? = nil) {
        self.text = text
        self.encoding = encoding
        self.lineEnding = lineEnding
    }
}
