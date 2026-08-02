import CodeEditorCore
import Foundation

/// Events emitted by a shared ``TextDocument``.
///
/// Every event carries a monotonic sequence. When a bounded stream drops events,
/// a ``streamGap`` marker is published so consumers resync from a snapshot (DOC-N06).
public enum TextDocumentEvent: Sendable, Equatable {
    /// Transaction about to apply; snapshot is pre-edit.
    case willApply(EditTransaction, DocumentSnapshot, sequence: UInt64)
    /// Transaction applied (content generation advanced).
    case didApply(AppliedEditTransaction, sequence: UInt64)
    case dirtyStateDidChange(Bool, sequence: UInt64)
    case uriDidChange(DocumentURI, sequence: UInt64)
    /// Content replaced from an external source (reload / provider).
    case externalContentReplace(DocumentSnapshot, sequence: UInt64)
    /// One or more prior events were dropped from a bounded buffer (DOC-N06).
    case streamGap(droppedCount: Int, lastSequence: UInt64, sequence: UInt64)

    public var sequence: UInt64 {
        switch self {
        case .willApply(_, _, let s),
            .didApply(_, let s),
            .dirtyStateDidChange(_, let s),
            .uriDidChange(_, let s),
            .externalContentReplace(_, let s),
            .streamGap(_, _, let s):
            return s
        }
    }
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
    public var fileIdentity: DocumentFileIdentity?
    public var hadBOM: Bool

    public init(
        text: String,
        encoding: DocumentEncoding = .utf8,
        lineEnding: LineEnding? = nil,
        fileIdentity: DocumentFileIdentity? = nil,
        hadBOM: Bool = false
    ) {
        self.text = text
        self.encoding = encoding
        self.lineEnding = lineEnding
        self.fileIdentity = fileIdentity
        self.hadBOM = hadBOM
    }
}

extension DocumentExternalChangePolicy {
    /// Prefer conflict when dirty and external change detected (caller decides).
    public static var preferConflictWhenDirty: DocumentExternalChangePolicy { .reloadIfClean }
}
