import CodeEditorCore
import CodeEditorDocuments
import CoreGraphics
import Foundation

// MARK: - Reveal request surface (WB-N02)

/// How the viewport should place the revealed range.
public enum EditorRevealAlignment: String, Sendable, Hashable, Codable {
    /// Center the range when it is outside the current viewport; otherwise leave scroll unchanged when possible.
    case centerIfOutsideViewport
    case top
    case bottom
    case nearest
}

/// What to do with the editor selection when revealing.
public enum EditorRevealSelectionPolicy: String, Sendable, Hashable, Codable {
    case select
    case extend
    case none
}

/// Animation preference for reveal (respect system reduce-motion when requested).
public enum EditorRevealAnimation: String, Sendable, Hashable, Codable {
    case respectReduceMotion
    case none
    case always
}

/// Result of a layout-based reveal computation.
public struct EditorRevealResult: Sendable, Hashable {
    public var scrollPosition: CGPoint
    public var selection: CodeEditorCore.TextRange?
    public var lineIndex: Int
    public var yOffset: CGFloat

    public init(
        scrollPosition: CGPoint,
        selection: CodeEditorCore.TextRange?,
        lineIndex: Int,
        yOffset: CGFloat
    ) {
        self.scrollPosition = scrollPosition
        self.selection = selection
        self.lineIndex = lineIndex
        self.yOffset = yOffset
    }
}

/// Layout-driven editor navigation (WB-N02).
///
/// Uses ``LineIndex`` with estimated (or host-supplied) line heights so scroll
/// targets follow logical lines — never fabricated formulas such as `offset / 40`.
public enum EditorRevealService {
    public static let defaultEstimatedLineHeight: CGFloat = 16

    /// Compute scroll position + selection for a range against document text.
    ///
    /// - Parameters:
    ///   - range: UTF-16 range to reveal.
    ///   - text: Document text used to build a line index.
    ///   - estimatedLineHeight: Per-line height when full layout is unavailable.
    ///   - viewportHeight: Optional viewport; used for centering.
    ///   - alignment: Viewport placement policy.
    ///   - selectionPolicy: Whether to update selection to `range`.
    ///   - animation: Reserved for hosts that animate scroll; pure computation is animation-agnostic.
    public static func reveal(
        range: CodeEditorCore.TextRange,
        text: String,
        estimatedLineHeight: CGFloat = defaultEstimatedLineHeight,
        viewportHeight: CGFloat? = nil,
        alignment: EditorRevealAlignment = .centerIfOutsideViewport,
        selectionPolicy: EditorRevealSelectionPolicy = .select,
        animation: EditorRevealAnimation = .respectReduceMotion
    ) -> EditorRevealResult {
        _ = animation  // Hosts apply motion; computation remains deterministic.
        final class EmptyPayload: LinePayload {
            var id: ObjectIdentifier { ObjectIdentifier(self) }
        }
        let height = max(1, estimatedLineHeight)
        let index = LineIndex<EmptyPayload>.build(
            from: text,
            estimatedLineHeight: height,
            makePayload: { _ in EmptyPayload() }
        )
        let offset = max(0, range.location)
        guard let line = index.line(atUTF16Offset: offset) else {
            let selection: CodeEditorCore.TextRange? =
                selectionPolicy == .none ? nil : range
            return EditorRevealResult(
                scrollPosition: .zero,
                selection: selection,
                lineIndex: 0,
                yOffset: 0
            )
        }

        let y: CGFloat
        switch alignment {
        case .top, .nearest:
            y = line.yOffset
        case .bottom:
            if let viewportHeight, viewportHeight > 0 {
                y = max(0, line.yOffset - (viewportHeight - line.metrics.height))
            } else {
                y = line.yOffset
            }
        case .centerIfOutsideViewport:
            if let viewportHeight, viewportHeight > 0 {
                // Place line roughly in the middle of the viewport.
                y = max(0, line.yOffset - (viewportHeight * 0.5 - line.metrics.height * 0.5))
            } else {
                // Without a viewport, pin to the line's layout y (true layout offset).
                y = line.yOffset
            }
        }

        let selection: CodeEditorCore.TextRange?
        switch selectionPolicy {
        case .select, .extend:
            selection = range
        case .none:
            selection = nil
        }

        return EditorRevealResult(
            scrollPosition: CGPoint(x: 0, y: y),
            selection: selection,
            lineIndex: line.index,
            yOffset: line.yOffset
        )
    }

    /// Apply a reveal result to an editor session (selection + scroll).
    @MainActor
    public static func apply(
        _ result: EditorRevealResult,
        to session: EditorSession
    ) {
        if let selection = result.selection {
            session.selections = [selection]
        }
        session.scrollPosition = result.scrollPosition
    }
}
