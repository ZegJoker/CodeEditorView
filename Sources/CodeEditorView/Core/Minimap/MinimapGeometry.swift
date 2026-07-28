import CoreGraphics
import Foundation

/// Pure geometry helpers for the minimap strip (no document ownership).
public enum MinimapGeometry: Sendable {
    /// Strip width for a given host width when minimap is enabled.
    public static func width(hostWidth: CGFloat) -> CGFloat {
        let relative = hostWidth * MinimapMetrics.relativeWidth
        return min(MinimapMetrics.maxWidth, max(MinimapMetrics.minWidth, relative))
    }

    /// Map an editor content Y into minimap content coordinates.
    public static func minimapY(
        editorY: CGFloat,
        editorHeight: CGFloat,
        minimapHeight: CGFloat
    ) -> CGFloat {
        guard editorHeight > 0, minimapHeight > 0 else { return 0 }
        return (editorY / editorHeight) * minimapHeight
    }

    /// Viewport indicator height in minimap space.
    public static func viewportHeight(
        editorVisibleHeight: CGFloat,
        editorHeight: CGFloat,
        minimapHeight: CGFloat
    ) -> CGFloat {
        guard editorHeight > 0, minimapHeight > 0 else { return 0 }
        let ratio = min(1, max(0, editorVisibleHeight / editorHeight))
        return max(MinimapMetrics.lineHeight, ratio * minimapHeight)
    }

    /// Content height for the minimap given the editor’s laid-out height.
    public static func contentHeight(
        editorHeight: CGFloat,
        estimatedEditorLineHeight: CGFloat
    ) -> CGFloat {
        let base = max(1, estimatedEditorLineHeight)
        let scale = MinimapMetrics.lineHeight / base
        return max(MinimapMetrics.lineHeight, editorHeight * scale)
    }

    /// Map minimap Y (content) back to editor content Y.
    public static func editorY(
        minimapY: CGFloat,
        editorHeight: CGFloat,
        minimapHeight: CGFloat
    ) -> CGFloat {
        guard minimapHeight > 0 else { return 0 }
        return (minimapY / minimapHeight) * editorHeight
    }

    /// Normalized scroll position 0...1 from editor offset.
    public static func scrollFraction(
        editorOffsetY: CGFloat,
        editorHeight: CGFloat,
        editorVisibleHeight: CGFloat
    ) -> CGFloat {
        let maxScroll = max(0, editorHeight - editorVisibleHeight)
        guard maxScroll > 0 else { return 0 }
        return min(1, max(0, editorOffsetY / maxScroll))
    }

    /// CESE-aligned viewport indicator within the strip.
    ///
    /// - When content is shorter than the strip, the track is content height and the
    ///   box covers the visible fraction of the document (often nearly the whole track).
    /// - When content is taller, the track is the strip height and the box scales by
    ///   `contentHeight / editorHeight`.
    /// - Y is `scrollFraction * (track - boxHeight)` so the overlay follows the scroller.
    public static func viewportFrame(
        editorOffsetY: CGFloat,
        editorVisibleHeight: CGFloat,
        editorHeight: CGFloat,
        contentHeight: CGFloat,
        stripHeight: CGFloat
    ) -> CGRect {
        let editorH = max(editorHeight, 1)
        let visibleH = max(editorVisibleHeight, 1)
        let docMiniH = max(contentHeight, 1)
        let stripH = max(stripHeight, 1)
        let availableH = min(docMiniH, stripH)

        let multiplier: CGFloat
        if docMiniH < stripH {
            multiplier = min(1, max(0, visibleH / editorH))
        } else {
            multiplier = min(1, max(0, docMiniH / editorH))
        }
        let boxH = max(MinimapMetrics.lineHeight, availableH * multiplier)
        let fraction = scrollFraction(
            editorOffsetY: editorOffsetY,
            editorHeight: editorH,
            editorVisibleHeight: visibleH
        )
        let travel = max(0, availableH - boxH)
        let boxY = travel * fraction
        return CGRect(x: 0, y: boxY, width: 0, height: boxH)
    }
}
