import Foundation

/// Monotonic document content generation counter.
///
/// Versions **only increase** (including across undo/redo). Equality means “same
/// content generation,” not a historical revision index. Attribute-only paints
/// (syntax highlighting) do **not** advance the version.
public struct DocumentVersion: RawRepresentable, Sendable, Codable, Hashable, Comparable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public static let zero = DocumentVersion(rawValue: 0)

    public func advanced(by delta: UInt64 = 1) -> DocumentVersion {
        DocumentVersion(rawValue: rawValue &+ delta)
    }

    public static func < (lhs: DocumentVersion, rhs: DocumentVersion) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Immutable plain-text view of a document at a specific version.
public struct DocumentSnapshot: Sendable, Hashable {
    public let version: DocumentVersion
    public let text: String
    public let utf16Length: Int
    /// Content-state identity at snapshot time (DOC-N01).
    public let contentState: DocumentContentStateID

    public init(
        version: DocumentVersion,
        text: String,
        contentState: DocumentContentStateID = DocumentContentStateID()
    ) {
        self.version = version
        self.text = text
        self.utf16Length = (text as NSString).length
        self.contentState = contentState
    }
}
