import CoreGraphics
import Foundation
import TextStory

/// Layout queries required for vertical caret movement and preferred-X tracking.
///
/// Implemented by the view-layer ``LayoutEngine``; kept in Core so selection
/// navigation does not depend on typesetting/layout modules.
@MainActor
public protocol CaretLayoutQuerying: AnyObject {
    func caretRect(atUTF16Offset offset: Int, containerWidth: CGFloat) -> CGRect?
    func utf16Offset(at point: CGPoint, containerWidth: CGFloat) -> Int
}

/// Manages multi-range selection state and keyboard/pointer-driven navigation.
@MainActor
public final class SelectionEngine {
    /// Ordered selections; index 0 is the primary caret for chrome defaults.
    public private(set) var selections: [TextRangeSelection]
    public var isEnabled: Bool = true
    public var mode: SelectionMode = .character

    private weak var document: DocumentStore?
    private weak var layout: (any CaretLayoutQuerying)?

    public init(selection: TextRangeSelection = .insertionPoint(0)) {
        self.selections = [selection]
    }

    public func attach(document: DocumentStore, layout: some CaretLayoutQuerying) {
        self.document = document
        self.layout = layout
        clampToDocument()
    }

    public var selectedRange: NSRange { selections.first?.range ?? NSRange(location: 0, length: 0) }

    public var selectedRanges: [NSRange] { selections.map(\.range) }

    public var primarySelection: TextRangeSelection {
        selections.first ?? .insertionPoint(0)
    }

    public func setSelectedRange(_ range: NSRange, preferredX: CGFloat? = nil) {
        setSelectedRanges([range], preferredX: preferredX)
    }

    public func setSelectedRanges(_ ranges: [NSRange], preferredX: CGFloat? = nil) {
        guard isEnabled else { return }
        let length = document?.length ?? 0
        let normalized = MultiRangeEdit.normalize(ranges, documentLength: length)
        selections = normalized.map { TextRangeSelection(range: $0, preferredX: preferredX) }
        if selections.isEmpty {
            selections = [.insertionPoint(0)]
        }
    }

    public func setInsertionPoint(_ location: Int, preferredX: CGFloat? = nil) {
        setSelectedRange(NSRange(location: location, length: 0), preferredX: preferredX)
    }

    /// Adds a caret/selection without clearing existing ones (multi-cursor).
    public func addSelection(_ range: NSRange, preferredX: CGFloat? = nil) {
        guard isEnabled else { return }
        var ranges = selectedRanges
        ranges.append(range)
        setSelectedRanges(ranges, preferredX: preferredX)
    }

    public func collapseToPrimary() {
        setSelectedRange(selectedRange)
    }

    public func selectAll() {
        guard let document else { return }
        setSelectedRange(NSRange(location: 0, length: document.length))
    }

    public func move(
        direction: NavigationDirection,
        granularity: NavigationGranularity = .character,
        extending: Bool = false,
        containerWidth: CGFloat
    ) {
        guard isEnabled, let document, let layout else { return }

        var next: [TextRangeSelection] = []
        for selection in selections {
            next.append(
                movedSelection(
                    selection,
                    direction: direction,
                    granularity: granularity,
                    extending: extending,
                    containerWidth: containerWidth,
                    document: document,
                    layout: layout
                )
            )
        }
        let ranges = next.map(\.range)
        let preferred = next.first?.preferredX
        setSelectedRanges(ranges, preferredX: preferred)
        // Restore per-selection preferred X where possible.
        if next.count == selections.count {
            for i in selections.indices {
                selections[i].preferredX = next[i].preferredX
            }
        }
    }

    /// Replaces every selection with `string` (high → low) as **one** versioned transaction.
    /// Returns edits in application order.
    @discardableResult
    public func replaceAllSelections(with string: String) -> [TextEdit] {
        guard isEnabled, let document else { return [] }
        let working = selectedRanges.sorted { $0.location > $1.location }
        guard !working.isEmpty else { return [] }

        let changes = working.map { TextChange(range: $0, replacement: string) }
        let transaction = EditTransaction(changes: changes, origin: .typing)
        guard let applied = try? document.apply(transaction) else { return [] }

        var carets: [Int] = []
        carets.reserveCapacity(applied.textEdits.count)
        for edit in applied.textEdits {
            carets.append(
                MultiRangeEdit.caretAfterReplace(
                    range: edit.range,
                    replacementUTF16Count: string.utf16.count
                )
            )
        }

        // Carets collected high→low; reverse to document order.
        let orderedCarets = carets.reversed().map { NSRange(location: $0, length: 0) }
        setSelectedRanges(orderedCarets)
        return applied.textEdits
    }

    /// Legacy single-selection replace.
    public func replaceSelection(with string: String) -> TextEdit? {
        replaceAllSelections(with: string).last
    }

    // MARK: - Private

    private func movedSelection(
        _ selection: TextRangeSelection,
        direction: NavigationDirection,
        granularity: NavigationGranularity,
        extending: Bool,
        containerWidth: CGFloat,
        document: DocumentStore,
        layout: any CaretLayoutQuerying
    ) -> TextRangeSelection {
        let anchor: Int
        let head: Int
        if extending {
            anchor = selection.range.location
            head = selection.end
        } else {
            switch direction {
            case .left, .up:
                head = selection.range.location
                anchor = head
            case .right, .down:
                head = selection.end
                anchor = head
            }
        }

        let newHead = computeHead(
            from: head,
            direction: direction,
            granularity: granularity,
            preferredX: selection.preferredX,
            containerWidth: containerWidth,
            document: document,
            layout: layout
        )

        if extending {
            let location = min(anchor, newHead)
            let length = abs(anchor - newHead)
            return TextRangeSelection(
                range: NSRange(location: location, length: length),
                preferredX: selection.preferredX
            )
        }

        let preferred: CGFloat?
        if direction == .up || direction == .down {
            preferred = selection.preferredX
                ?? layout.caretRect(atUTF16Offset: head, containerWidth: containerWidth)?.minX
        } else {
            preferred = layout.caretRect(atUTF16Offset: newHead, containerWidth: containerWidth)?.minX
        }
        return TextRangeSelection(range: NSRange(location: newHead, length: 0), preferredX: preferred)
    }

    private func computeHead(
        from head: Int,
        direction: NavigationDirection,
        granularity: NavigationGranularity,
        preferredX: CGFloat?,
        containerWidth: CGFloat,
        document: DocumentStore,
        layout: any CaretLayoutQuerying
    ) -> Int {
        switch (direction, granularity) {
        case (.left, .character):
            return max(0, head - 1)
        case (.right, .character):
            return min(document.length, head + 1)
        case (.left, .word):
            return document.findPrecedingOccurrenceOfCharacter(in: .alphanumerics.inverted, from: head) ?? 0
        case (.right, .word):
            return document.findNextOccurrenceOfCharacter(in: .alphanumerics.inverted, from: head) ?? document.length
        case (.left, .line), (.up, .line):
            return document.findStartOfLine(containing: head)
        case (.right, .line), (.down, .line):
            let end = document.findEndOfLine(containing: head)
            if end > 0, end <= document.length {
                let prev = end - 1
                if let ch = document.substring(from: NSRange(location: prev, length: 1)),
                   ch == "\n" || ch == "\r" {
                    return prev
                }
            }
            return end
        case (.left, .document), (.up, .document):
            return 0
        case (.right, .document), (.down, .document):
            return document.length
        case (.up, .character), (.up, .word), (.up, .paragraph):
            return verticalMove(from: head, direction: .up, preferredX: preferredX, containerWidth: containerWidth, layout: layout)
        case (.down, .character), (.down, .word), (.down, .paragraph):
            return verticalMove(from: head, direction: .down, preferredX: preferredX, containerWidth: containerWidth, layout: layout)
        case (_, .paragraph):
            if direction == .left || direction == .up {
                return document.findStartOfLine(containing: head)
            }
            return document.findEndOfLine(containing: head)
        }
    }

    private func verticalMove(
        from head: Int,
        direction: NavigationDirection,
        preferredX: CGFloat?,
        containerWidth: CGFloat,
        layout: any CaretLayoutQuerying
    ) -> Int {
        guard let caret = layout.caretRect(atUTF16Offset: head, containerWidth: containerWidth) else {
            return head
        }
        let x = preferredX ?? caret.minX
        let targetY: CGFloat
        switch direction {
        case .up:
            targetY = caret.minY - max(1, caret.height * 0.5)
        case .down:
            targetY = caret.maxY + max(1, caret.height * 0.5)
        default:
            return head
        }
        return layout.utf16Offset(at: CGPoint(x: x, y: max(0, targetY)), containerWidth: containerWidth)
    }

    private func clampToDocument() {
        setSelectedRanges(selectedRanges)
    }
}
