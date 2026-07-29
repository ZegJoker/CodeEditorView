import Foundation

// MARK: - Line annotations / diagnostics (Phase 12)

extension EditorController {
    /// Current line annotations (CESE Line Annotations design).
    public var annotations: [LineAnnotation] { _annotationStore.items }

    /// Annotations grouped by zero-based line index.
    public var annotationsByLine: [Int: [LineAnnotation]] { _annotationStore.byLine }

    /// Replace all annotations for the open document.
    public func setAnnotations(_ items: [LineAnnotation]) {
        _annotationStore.setAnnotations(items)
        _annotationStore.clampLines(lineCount: max(1, layout.lineIndex.count))
        applyAnnotationLayoutAndEmphasis()
        onNeedsDisplay?()
    }

    /// Remove all annotations and restore line heights.
    public func clearAnnotations() {
        _annotationStore.clear()
        applyAnnotationLayoutAndEmphasis()
        onNeedsDisplay?()
    }

    func noteAnnotationEdit(range: NSRange, delta: Int) {
        guard !_annotationStore.items.isEmpty else { return }
        // Must not run while the layout transaction is open — line offsets are stale.
        // Callers should go through `noteDidEdit` which defers until `onTransactionEnded`.
        guard !layout.isInTransaction else { return }
        _annotationStore.documentDidEdit(editedRange: range, delta: delta)
        // Re-map line indices from ranges when possible.
        remapAnnotationLinesFromRanges()
        _annotationStore.clampLines(lineCount: max(1, layout.lineIndex.count))
        applyAnnotationLayoutAndEmphasis()
    }

    private func remapAnnotationLinesFromRanges() {
        var updated: [LineAnnotation] = []
        for var ann in _annotationStore.items {
            if let range = ann.range, let line = layout.lineIndex.line(atUTF16Offset: range.location) {
                ann.line = line.index
                ann.column = max(0, range.location - line.utf16Offset)
            }
            updated.append(ann)
        }
        _annotationStore.setAnnotations(updated)
    }

    private func applyAnnotationLayoutAndEmphasis() {
        // mchakravarty style: trailing chips on the line — no extra line height.
        layout.setAnnotationBandHeights([:])

        // Severity-colored underlines only when a precise token range is provided
        // (error = red, warning = yellow). Whole-line chips without `range` get no squiggle.
        emphasis.removeAll(in: EmphasisGroup.diagnostics)
        for ann in _annotationStore.items {
            guard let range = ann.range, range.length > 0 else { continue }
            let loc = max(0, min(range.location, document.length))
            let len = max(0, min(range.length, document.length - loc))
            guard len > 0 else { continue }
            emphasis.add(
                Emphasis(
                    range: NSRange(location: loc, length: len),
                    style: .underline,
                    flash: false,
                    inactive: false,
                    selectInDocument: false,
                    group: EmphasisGroup.diagnostics,
                    color: ann.severity.color.cgColor
                )
            )
        }
        syncContentSizeFromLayout()
        onNeedsDisplay?()
    }
}
