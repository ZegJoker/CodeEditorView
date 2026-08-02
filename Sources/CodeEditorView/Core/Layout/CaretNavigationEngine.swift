import CodeEditorCore
import CoreGraphics
import CoreText
import Foundation

/// Visual caret movement direction (platform-neutral).
public enum VisualDirection: Sendable, Hashable {
    case left
    case right
    case up
    case down
}

/// Result of a single caret navigation step (UI-N01).
public struct CaretMovementResult: Sendable, Equatable {
    public let position: TextPosition
    public let preferredX: CGFloat?

    public init(position: TextPosition, preferredX: CGFloat?) {
        self.position = position
        self.preferredX = preferredX
    }
}

/// Immutable layout snapshot for caret navigation and selection geometry (UI-N01 / UI-N03).
///
/// Built from a live ``LayoutEngine`` viewport; pure consumers never touch mutable layout state.
public struct EditorLayoutSnapshot: @unchecked Sendable {
    public struct Fragment: @unchecked Sendable {
        public let documentRange: NSRange
        public let frame: CGRect
        public let ctLine: CTLine?
        public let isRTL: Bool

        public init(documentRange: NSRange, frame: CGRect, ctLine: CTLine?, isRTL: Bool) {
            self.documentRange = documentRange
            self.frame = frame
            self.ctLine = ctLine
            self.isRTL = isRTL
        }
    }

    public let contentSize: CGSize
    public let fragments: [Fragment]
    public let documentUTF16Length: Int
    public let documentText: String
    public let edgeInsetsLeading: CGFloat

    public init(
        contentSize: CGSize,
        fragments: [Fragment],
        documentUTF16Length: Int,
        documentText: String,
        edgeInsetsLeading: CGFloat
    ) {
        self.contentSize = contentSize
        self.fragments = fragments
        self.documentUTF16Length = documentUTF16Length
        self.documentText = documentText
        self.edgeInsetsLeading = edgeInsetsLeading
    }

    public static let empty = EditorLayoutSnapshot(
        contentSize: .zero,
        fragments: [],
        documentUTF16Length: 0,
        documentText: "",
        edgeInsetsLeading: 0
    )

    /// Caret rectangle for a document UTF-16 offset (grapheme-snapped).
    public func caretRect(atUTF16Offset rawOffset: Int) -> CGRect? {
        let offset = NativeInputPositions.clampedGraphemePosition(
            utf16Offset: rawOffset,
            in: documentText
        )
        guard !fragments.isEmpty else {
            return CGRect(x: edgeInsetsLeading, y: 0, width: 1, height: 16)
        }
        for frag in fragments {
            let start = frag.documentRange.location
            let end = start + frag.documentRange.length
            if offset < start { continue }
            if offset <= end {
                let x: CGFloat
                if let ctLine = frag.ctLine {
                    let local = offset - start
                    x = frag.frame.minX + CGFloat(CTLineGetOffsetForStringIndex(ctLine, local, nil))
                } else if end > start {
                    let t = CGFloat(offset - start) / CGFloat(max(1, frag.documentRange.length))
                    x = frag.frame.minX + t * frag.frame.width
                } else {
                    x = frag.frame.minX
                }
                return CGRect(x: x, y: frag.frame.minY, width: 1, height: max(1, frag.frame.height))
            }
        }
        // Past last fragment.
        if let last = fragments.last {
            return CGRect(
                x: last.frame.maxX,
                y: last.frame.minY,
                width: 1,
                height: max(1, last.frame.height)
            )
        }
        return nil
    }

    /// Hit-test a document point to a grapheme-valid UTF-16 offset.
    public func utf16Offset(at point: CGPoint) -> Int {
        guard !fragments.isEmpty else { return 0 }
        // Prefer fragment whose Y span contains the point; else nearest by center Y.
        var best: Fragment?
        var bestDist = CGFloat.greatestFiniteMagnitude
        for frag in fragments {
            if point.y >= frag.frame.minY, point.y <= frag.frame.maxY {
                best = frag
                bestDist = 0
                break
            }
            let cy = frag.frame.midY
            let d = abs(cy - point.y)
            if d < bestDist {
                bestDist = d
                best = frag
            }
        }
        guard let frag = best else { return 0 }
        let localX = point.x - frag.frame.minX
        if localX <= 0 {
            return snap(frag.documentRange.location)
        }
        if let ctLine = frag.ctLine {
            let index = CTLineGetStringIndexForPosition(ctLine, CGPoint(x: localX, y: 0))
            let clamped = min(max(0, index), frag.documentRange.length)
            return snap(frag.documentRange.location + clamped)
        }
        if frag.frame.width <= 0 {
            return snap(frag.documentRange.location)
        }
        let t = min(1, max(0, localX / frag.frame.width))
        let rel = Int((t * CGFloat(frag.documentRange.length)).rounded())
        return snap(frag.documentRange.location + min(rel, frag.documentRange.length))
    }

    private func snap(_ offset: Int) -> Int {
        NativeInputPositions.clampedGraphemePosition(utf16Offset: offset, in: documentText)
    }
}

/// Platform-neutral caret navigation driven by immutable layout snapshots (UI-N01).
public enum CaretNavigationEngine: Sendable {
    /// Moves `caret` one visual step in `direction`, preserving `preferredX` for vertical motion.
    public static func move(
        caret: TextPosition,
        direction: VisualDirection,
        preferredX: CGFloat?,
        layout: EditorLayoutSnapshot
    ) -> CaretMovementResult {
        let text = layout.documentText
        let len = layout.documentUTF16Length
        let start = NativeInputPositions.clampedGraphemePosition(
            utf16Offset: min(max(0, caret.utf16Offset), len),
            in: text
        )

        switch direction {
        case .left:
            let next =
                (try? TextOffsetSemantics.graphemeBoundaryBefore(utf16Offset: start, in: text)) ?? max(0, start - 1)
            let x = layout.caretRect(atUTF16Offset: next)?.minX
            return CaretMovementResult(position: TextPosition(utf16Offset: next), preferredX: x)
        case .right:
            let next =
                (try? TextOffsetSemantics.graphemeBoundaryAfter(utf16Offset: start, in: text)) ?? min(len, start + 1)
            let x = layout.caretRect(atUTF16Offset: next)?.minX
            return CaretMovementResult(position: TextPosition(utf16Offset: next), preferredX: x)
        case .up, .down:
            guard let caretRect = layout.caretRect(atUTF16Offset: start) else {
                return CaretMovementResult(position: TextPosition(utf16Offset: start), preferredX: preferredX)
            }
            let x = preferredX ?? caretRect.minX
            let targetY: CGFloat
            if direction == .up {
                targetY = caretRect.minY - max(1, caretRect.height * 0.5)
            } else {
                targetY = caretRect.maxY + max(1, caretRect.height * 0.5)
            }
            let raw = layout.utf16Offset(at: CGPoint(x: x, y: max(0, targetY)))
            let snapped = NativeInputPositions.clampedGraphemePosition(utf16Offset: raw, in: text)
            return CaretMovementResult(
                position: TextPosition(utf16Offset: snapped),
                preferredX: x
            )
        }
    }
}

extension LayoutEngine {
    /// Builds an immutable navigation/selection snapshot for the current layout (UI-N01).
    public func makeEditorLayoutSnapshot(
        containerWidth: CGFloat,
        documentText: String
    ) -> EditorLayoutSnapshot {
        let height = max(contentSize.height, 1)
        let viewport = layoutViewport(
            visibleRect: CGRect(x: 0, y: 0, width: containerWidth, height: height),
            containerWidth: containerWidth
        )
        let frags: [EditorLayoutSnapshot.Fragment] = viewport.fragments.map { item in
            let rtl: Bool
            if let ctLine = item.fragment.ctLine {
                // Platform typesetter supplies glyph runs; use first run status when available.
                let runs = CTLineGetGlyphRuns(ctLine) as NSArray
                if let run = runs.firstObject {
                    let runRef = run as! CTRun
                    let status = CTRunGetStatus(runRef)
                    rtl = status.contains(.rightToLeft)
                } else {
                    rtl = false
                }
            } else {
                rtl = false
            }
            return EditorLayoutSnapshot.Fragment(
                documentRange: item.fragment.documentRange,
                frame: item.frame,
                ctLine: item.fragment.ctLine,
                isRTL: rtl
            )
        }
        return EditorLayoutSnapshot(
            contentSize: viewport.contentSize,
            fragments: frags,
            documentUTF16Length: (documentText as NSString).length,
            documentText: documentText,
            edgeInsetsLeading: edgeInsets.leading
        )
    }
}
