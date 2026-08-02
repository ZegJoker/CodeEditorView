import Foundation
import TextStory

/// Why a content mutation was produced.
public enum EditOrigin: String, Sendable, Codable, Hashable {
    case typing
    case paste
    case drop
    case undo
    case redo
    case programmatic
    case structure
    case formation
    case unknown
}

/// One UTF-16 replacement relative to the **pre-edit** document.
public struct TextChange: Sendable, Codable, Hashable {
    public let replacedRange: TextRange
    public let replacement: String

    public init(replacedRange: TextRange, replacement: String) {
        self.replacedRange = replacedRange
        self.replacement = replacement
    }

    public init(range: NSRange, replacement: String) {
        self.replacedRange = TextRange(range)
        self.replacement = replacement
    }
}

/// Ordered set of content changes applied as a single versioned transaction.
///
/// Multi-range edits should list changes in **high→low** UTF-16 location order so
/// each range remains valid against the pre-edit document when applied top-down.
/// Equal-offset pure insertions appear in **declaration order** in the resulting
/// text (DOC-N03).
public struct EditTransaction: Sendable, Codable, Hashable {
    public let id: UUID
    public let changes: [TextChange]
    public let origin: EditOrigin

    public init(
        id: UUID = UUID(),
        changes: [TextChange],
        origin: EditOrigin = .unknown
    ) {
        self.id = id
        self.changes = changes
        self.origin = origin
    }

    public static func single(
        range: NSRange,
        replacement: String,
        origin: EditOrigin = .unknown,
        id: UUID = UUID()
    ) -> EditTransaction {
        EditTransaction(
            id: id,
            changes: [TextChange(range: range, replacement: replacement)],
            origin: origin
        )
    }
}

/// Result of applying an ``EditTransaction`` to a document.
public struct AppliedEditTransaction: Sendable, Equatable {
    public let transaction: EditTransaction
    public let oldVersion: DocumentVersion
    public let newVersion: DocumentVersion
    /// Content state before the transaction (restored on undo) (DOC-N01).
    public let beforeState: DocumentContentStateID
    /// Content state after the transaction (restored on redo) (DOC-N01).
    public let afterState: DocumentContentStateID
    public let inverse: EditTransaction
    /// Per-change `TextEdit` records in application order, for undo registration.
    public let textEdits: [TextEdit]

    public init(
        transaction: EditTransaction,
        oldVersion: DocumentVersion,
        newVersion: DocumentVersion,
        beforeState: DocumentContentStateID,
        afterState: DocumentContentStateID,
        inverse: EditTransaction,
        textEdits: [TextEdit]
    ) {
        self.transaction = transaction
        self.oldVersion = oldVersion
        self.newVersion = newVersion
        self.beforeState = beforeState
        self.afterState = afterState
        self.inverse = inverse
        self.textEdits = textEdits
    }
}

extension TextEdit {
    /// Wraps this single mutation as a versioned transaction description (not yet applied).
    public func asTransaction(origin: EditOrigin = .unknown, id: UUID = UUID()) -> EditTransaction {
        EditTransaction.single(range: range, replacement: replacement, origin: origin, id: id)
    }
}
