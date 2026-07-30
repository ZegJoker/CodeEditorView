import Foundation

/// Selection payload for versioned editor events and lifecycle observers.
public struct SelectionChangeEvent: Sendable, Equatable {
    public let selections: [TextRange]
    public let version: DocumentVersion

    public init(selections: [TextRange], version: DocumentVersion) {
        self.selections = selections
        self.version = version
    }

    public init(nsRanges: [NSRange], version: DocumentVersion) {
        self.selections = nsRanges.map { TextRange($0) }
        self.version = version
    }
}

/// Lightweight attach/detach context (no view controller reference).
public struct EditorContext: Sendable, Equatable {
    public let documentVersion: DocumentVersion

    public init(documentVersion: DocumentVersion) {
        self.documentVersion = documentVersion
    }
}
