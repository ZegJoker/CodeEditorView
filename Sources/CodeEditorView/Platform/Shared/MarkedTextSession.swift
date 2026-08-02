import Foundation

/// IME / marked-text composition state separate from committed document history (UI-001 / UI-002).
///
/// While `isActive`, provisional composition text may exist in the document buffer for display,
/// but callers must pass `registerUndo: false` and suppress LSP/typing side effects until
/// ``commit`` / ``clear``.
public struct MarkedTextSession: Sendable, Equatable {
    /// Document UTF-16 range of the current composition, or `NSNotFound` when inactive.
    public var range: NSRange
    /// Composition string (UTF-16 length matches `range.length` when active).
    public var text: String
    /// Sub-selection within the composition (UTF-16 relative to composition start).
    public var selectedRangeInMarked: NSRange
    /// Number of document versions / undos suppressed during this composition.
    public private(set) var compositionEditCount: Int

    public static let inactive = MarkedTextSession(
        range: NSRange(location: NSNotFound, length: 0),
        text: "",
        selectedRangeInMarked: NSRange(location: 0, length: 0),
        compositionEditCount: 0
    )

    public init(
        range: NSRange,
        text: String,
        selectedRangeInMarked: NSRange,
        compositionEditCount: Int = 0
    ) {
        self.range = range
        self.text = text
        self.selectedRangeInMarked = selectedRangeInMarked
        self.compositionEditCount = compositionEditCount
    }

    public var isActive: Bool {
        range.location != NSNotFound && range.length >= 0
    }

    /// Absolute caret range inside the document for the marked sub-selection.
    public var absoluteSelectedRange: NSRange? {
        guard isActive else { return nil }
        let loc = range.location + selectedRangeInMarked.location
        return NSRange(location: loc, length: selectedRangeInMarked.length)
    }

    /// Apply a new marked string at `documentReplaceRange` (pre-edit coords).
    public mutating func setMarked(
        text newText: String,
        selectedRangeInMarked selected: NSRange,
        documentReplaceRange: NSRange
    ) {
        let len = (newText as NSString).length
        range = NSRange(location: documentReplaceRange.location, length: len)
        text = newText
        if selected.location != NSNotFound,
            selected.location >= 0,
            selected.location + selected.length <= len
        {
            selectedRangeInMarked = selected
        } else {
            selectedRangeInMarked = NSRange(location: len, length: 0)
        }
        compositionEditCount += 1
    }

    public mutating func clear() {
        self = .inactive
    }
}
