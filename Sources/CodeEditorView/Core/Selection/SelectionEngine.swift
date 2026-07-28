import CoreGraphics
import Foundation
import TextStory

/// Manages selection state and keyboard/pointer-driven navigation.
@MainActor
public final class SelectionEngine {
    public private(set) var selection: TextRangeSelection
    public var isEnabled: Bool = true

    private weak var document: DocumentStore?
    private weak var layout: LayoutEngine?

    public init(selection: TextRangeSelection = .insertionPoint(0)) {
        self.selection = selection
    }

    public func attach(document: DocumentStore, layout: LayoutEngine) {
        self.document = document
        self.layout = layout
        clampToDocument()
    }

    public var selectedRange: NSRange { selection.range }

    public func setSelectedRange(_ range: NSRange, preferredX: CGFloat? = nil) {
        guard isEnabled else { return }
        let clamped = clamp(range)
        selection = TextRangeSelection(range: clamped, preferredX: preferredX ?? selection.preferredX)
    }

    public func setInsertionPoint(_ location: Int, preferredX: CGFloat? = nil) {
        setSelectedRange(NSRange(location: location, length: 0), preferredX: preferredX)
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

        let anchor: Int
        let head: Int
        if extending {
            anchor = selection.range.location
            head = selection.end
        } else {
            // Collapse to edge in movement direction when not extending.
            switch direction {
            case .left, .up:
                head = selection.range.location
                anchor = head
            case .right, .down:
                head = selection.end
                anchor = head
            }
        }

        let newHead: Int
        switch (direction, granularity) {
        case (.left, .character):
            newHead = max(0, head - 1)
        case (.right, .character):
            newHead = min(document.length, head + 1)
        case (.left, .word):
            newHead = document.findPrecedingOccurrenceOfCharacter(
                in: .alphanumerics.inverted,
                from: head
            ) ?? 0
        case (.right, .word):
            newHead = document.findNextOccurrenceOfCharacter(
                in: .alphanumerics.inverted,
                from: head
            ) ?? document.length
        case (.left, .line), (.up, .line):
            newHead = document.findStartOfLine(containing: head)
        case (.right, .line), (.down, .line):
            let end = document.findEndOfLine(containing: head)
            // Prefer before trailing newline when present.
            if end > 0, end <= document.length {
                let prev = end - 1
                if let ch = document.substring(from: NSRange(location: prev, length: 1)),
                   ch == "\n" || ch == "\r" {
                    newHead = prev
                } else {
                    newHead = end
                }
            } else {
                newHead = end
            }
        case (.left, .document), (.up, .document):
            newHead = 0
        case (.right, .document), (.down, .document):
            newHead = document.length
        case (.up, .character), (.up, .word), (.up, .paragraph):
            newHead = verticalMove(from: head, direction: .up, containerWidth: containerWidth, layout: layout)
        case (.down, .character), (.down, .word), (.down, .paragraph):
            newHead = verticalMove(from: head, direction: .down, containerWidth: containerWidth, layout: layout)
        case (_, .paragraph):
            // Paragraph treated as line for MVP.
            if direction == .left || direction == .up {
                newHead = document.findStartOfLine(containing: head)
            } else {
                newHead = document.findEndOfLine(containing: head)
            }
        }

        if extending {
            let location = min(anchor, newHead)
            let length = abs(anchor - newHead)
            setSelectedRange(NSRange(location: location, length: length), preferredX: selection.preferredX)
        } else {
            let preferred: CGFloat?
            if direction == .up || direction == .down {
                preferred = selection.preferredX ?? layout.caretRect(atUTF16Offset: head, containerWidth: containerWidth)?.minX
            } else {
                preferred = layout.caretRect(atUTF16Offset: newHead, containerWidth: containerWidth)?.minX
            }
            setInsertionPoint(newHead, preferredX: preferred)
        }
    }

    public func replaceSelection(with string: String) -> TextEdit? {
        guard isEnabled, let document else { return nil }
        let edit = document.replaceCharacters(in: selection.range, with: string)
        let newLocation = selection.range.location + string.utf16.count
        setInsertionPoint(newLocation)
        return edit
    }

    // MARK: - Private

    private func verticalMove(
        from head: Int,
        direction: NavigationDirection,
        containerWidth: CGFloat,
        layout: LayoutEngine
    ) -> Int {
        guard let caret = layout.caretRect(atUTF16Offset: head, containerWidth: containerWidth) else {
            return head
        }
        let preferredX = selection.preferredX ?? caret.minX
        selection.preferredX = preferredX
        let targetY: CGFloat
        switch direction {
        case .up:
            targetY = caret.minY - max(1, caret.height * 0.5)
        case .down:
            targetY = caret.maxY + max(1, caret.height * 0.5)
        default:
            return head
        }
        return layout.utf16Offset(
            at: CGPoint(x: preferredX, y: max(0, targetY)),
            containerWidth: containerWidth
        )
    }

    private func clampToDocument() {
        selection.range = clamp(selection.range)
    }

    private func clamp(_ range: NSRange) -> NSRange {
        let length = document?.length ?? 0
        let location = min(max(0, range.location), length)
        let maxLen = length - location
        let len = min(max(0, range.length), maxLen)
        return NSRange(location: location, length: len)
    }
}
