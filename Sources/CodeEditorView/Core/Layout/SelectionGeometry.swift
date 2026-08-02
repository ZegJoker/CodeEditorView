import CodeEditorCore
import CoreGraphics
import CoreText
import Foundation

/// One visual selection fragment for platform hosts (UI-N03).
public struct SelectionFragmentRect: Sendable, Equatable {
    public let rect: CGRect
    public let containsStart: Bool
    public let containsEnd: Bool
    public let writingDirectionRTL: Bool

    public init(rect: CGRect, containsStart: Bool, containsEnd: Bool, writingDirectionRTL: Bool = false) {
        self.rect = rect
        self.containsStart = containsStart
        self.containsEnd = containsEnd
        self.writingDirectionRTL = writingDirectionRTL
    }
}

/// Fragment-based selection geometry — O(visible fragments), not O(selection UTF-16) (UI-N03).
public enum SelectionGeometry: Sendable {
    /// Intersects `range` with layout fragments; virtualizes offscreen via `visibleRect`.
    public static func selectionRects(
        for range: NSRange,
        layout: EditorLayoutSnapshot,
        visibleRect: CGRect?
    ) -> [SelectionFragmentRect] {
        guard range.length > 0, range.location >= 0 else { return [] }
        let selStart = range.location
        let selEnd = range.location + range.length
        var out: [SelectionFragmentRect] = []
        out.reserveCapacity(min(layout.fragments.count, 64))

        for frag in layout.fragments {
            if let visible = visibleRect, !frag.frame.intersects(visible) {
                continue
            }
            let fStart = frag.documentRange.location
            let fEnd = fStart + frag.documentRange.length
            let iStart = max(selStart, fStart)
            let iEnd = min(selEnd, fEnd)
            guard iStart < iEnd || (iStart == iEnd && selStart < selEnd && iStart >= fStart && iStart <= fEnd)
            else { continue }
            // Empty intersection only when selection edge lands exactly at fragment end with no span.
            guard iStart < iEnd else { continue }

            let x0 = xPosition(in: frag, documentOffset: iStart)
            let x1 = xPosition(in: frag, documentOffset: iEnd)
            let minX = min(x0, x1)
            let maxX = max(x0, x1)
            let width = max(1, maxX - minX)
            let rect = CGRect(
                x: minX,
                y: frag.frame.minY,
                width: width,
                height: max(1, frag.frame.height)
            )
            out.append(
                SelectionFragmentRect(
                    rect: rect,
                    containsStart: selStart >= fStart && selStart < fEnd,
                    containsEnd: selEnd > fStart && selEnd <= fEnd,
                    writingDirectionRTL: frag.isRTL
                )
            )
        }
        return out
    }

    /// Multi-range / multi-cursor selection rects (UI-N03).
    public static func selectionRects(
        for ranges: [NSRange],
        layout: EditorLayoutSnapshot,
        visibleRect: CGRect?
    ) -> [SelectionFragmentRect] {
        var all: [SelectionFragmentRect] = []
        for r in ranges {
            all.append(contentsOf: selectionRects(for: r, layout: layout, visibleRect: visibleRect))
        }
        return all
    }

    private static func xPosition(in frag: EditorLayoutSnapshot.Fragment, documentOffset: Int) -> CGFloat {
        let start = frag.documentRange.location
        let end = start + frag.documentRange.length
        let clamped = min(max(documentOffset, start), end)
        if let ctLine = frag.ctLine {
            let local = clamped - start
            return frag.frame.minX + CGFloat(CTLineGetOffsetForStringIndex(ctLine, local, nil))
        }
        if end <= start { return frag.frame.minX }
        let t = CGFloat(clamped - start) / CGFloat(frag.documentRange.length)
        return frag.frame.minX + t * frag.frame.width
    }
}
