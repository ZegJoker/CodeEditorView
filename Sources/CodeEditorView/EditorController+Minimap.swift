import CoreGraphics
import Foundation

// MARK: - Minimap (Phase 9)

extension EditorController {
    /// Trailing strip width when minimap is enabled; `0` when hidden.
    public var minimapWidth: CGFloat {
        guard configuration.peripherals.showMinimap else { return 0 }
        // Host should pass real width; fall back to max when unknown.
        let host = contentSize.width > 0 ? contentSize.width : 800
        return MinimapGeometry.width(hostWidth: host)
    }

    public func minimapWidth(forHostWidth hostWidth: CGFloat) -> CGFloat {
        guard configuration.peripherals.showMinimap else { return 0 }
        return MinimapGeometry.width(hostWidth: hostWidth)
    }

    /// Total height of minimap content (scaled from editor layout height).
    public func minimapContentHeight() -> CGFloat {
        let editorH = max(layout.lineIndex.height, contentSize.height)
        let estimated = max(1, layout.estimatedLineHeight * configuration.lineHeightMultiplier)
        return MinimapGeometry.contentHeight(
            editorHeight: editorH,
            estimatedEditorLineHeight: estimated
        )
    }

    /// Build a paint snapshot for the given minimap content Y range.
    public func minimapSnapshot(visibleMinimapRect: CGRect) -> MinimapSnapshot {
        let editorH = max(layout.lineIndex.height, contentSize.height, 1)
        let miniH = minimapContentHeight()
        guard miniH > 0, layout.lineIndex.count > 0 else { return .empty }

        let scale = miniH / editorH
        let minY = max(0, visibleMinimapRect.minY)
        let maxY = min(miniH, visibleMinimapRect.maxY)
        guard minY < maxY else {
            return MinimapSnapshot(contentHeight: miniH, lines: [], selectionRects: [])
        }

        // Map minimap Y → editor Y for line enumeration.
        let editorMinY = minY / scale
        let editorMaxY = maxY / scale

        var lines: [MinimapLinePaint] = []
        var utf16Union = NSRange(location: 0, length: 0)

        layout.lineIndex.enumerateLines(inYRange: editorMinY, maxY: editorMaxY) { line in
            let y = line.yOffset * scale
            let h = max(MinimapMetrics.lineHeight, line.metrics.height * scale)
            let range = line.utf16Range
            let text = document.substring(from: range) ?? ""
            let captures = highlighter?.captureRuns(in: range) ?? []
            // Convert document-absolute capture ranges to line-local.
            let local: [(NSRange, CaptureName?)] = captures.map { run in
                let loc = run.range.location - range.location
                return (NSRange(location: max(0, loc), length: run.range.length), run.capture)
            }
            let bubbles = MinimapRunBuilder.bubbles(lineText: text, captureRuns: local)
            lines.append(MinimapLinePaint(y: y, height: h, bubbles: bubbles, lineIndex: line.index))
            if utf16Union.length == 0 {
                utf16Union = range
            } else {
                utf16Union = NSUnionRange(utf16Union, range)
            }
        }

        if utf16Union.length > 0 {
            highlighter?.expandVisibleRange(utf16Union)
        }

        // Selection overlays in minimap space.
        var selectionRects: [CGRect] = []
        for sel in selectedRanges where sel.length > 0 {
            guard let startLine = layout.lineIndex.line(atUTF16Offset: sel.location),
                  let endLine = layout.lineIndex.line(
                    atUTF16Offset: max(sel.location, sel.location + sel.length - 1)
                  )
            else { continue }
            let y0 = startLine.yOffset * scale
            let y1 = (endLine.yOffset + endLine.metrics.height) * scale
            selectionRects.append(
                CGRect(x: 0, y: y0, width: MinimapMetrics.maxWidth, height: max(1, y1 - y0))
            )
        }

        return MinimapSnapshot(contentHeight: miniH, lines: lines, selectionRects: selectionRects)
    }

    /// Map a minimap content Y to an editor content Y for scrolling.
    public func editorContentY(fromMinimapY minimapY: CGFloat) -> CGFloat {
        let editorH = max(layout.lineIndex.height, contentSize.height, 1)
        let miniH = max(minimapContentHeight(), 1)
        return MinimapGeometry.editorY(minimapY: minimapY, editorHeight: editorH, minimapHeight: miniH)
    }

    /// Apply trailing inset for minimap width (call when host width known).
    func updateMinimapTrailingInset(hostWidth: CGFloat) {
        let model = makeGutterModel()
        let gutter = configuration.peripherals.showGutter ? model.width : 0
        // Keep public gutterWidth property in sync when possible (same module file owns the setter).
        applyHorizontalInsets(gutterWidth: gutter, minimapWidth: configuration.peripherals.showMinimap
            ? MinimapGeometry.width(hostWidth: hostWidth)
            : 0)
    }
}
