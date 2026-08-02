import CoreGraphics
import Foundation

// MARK: - Line folding (Phase 10)

extension EditorController {
    /// Fold discovery + collapse state (CESE-aligned, no Combine).
    public var foldModel: LineFoldModel { _foldModel }

    /// Override the default indentation fold provider.
    public var foldProvider: any LineFoldProvider {
        get { _foldModel.foldProvider }
        set {
            _foldModel.foldProvider = newValue
            rebuildFolds()
        }
    }

    public func folds(in range: NSRange) -> [FoldRange] {
        _foldModel.folds(in: range)
    }

    public func deepestFold(atLine lineIndex: Int) -> FoldRange? {
        guard let line = layout.lineIndex.line(atIndex: lineIndex) else { return nil }
        return _foldModel.deepestFold(atLineRange: line.utf16Range)
    }

    /// Prefer the fold whose **header** is this line (line before the first body line).
    ///
    /// Body ranges start at the first indented line (where the `···` bubble lives when
    /// collapsed); the disclosure chevron and click target stay on the header (`func … {`).
    public func foldStarting(atLine lineIndex: Int) -> FoldRange? {
        guard layout.lineIndex.line(atIndex: lineIndex) != nil else { return nil }
        // Skip blanks between header and first body line.
        var bodyIdx = lineIndex + 1
        while let body = layout.lineIndex.line(atIndex: bodyIdx) {
            let snip =
                document.substring(from: body.utf16Range)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if snip.isEmpty {
                bodyIdx += 1
                continue
            }
            let bodyStart = body.utf16Offset
            let bodyEnd = bodyStart + max(body.metrics.utf16Length, 1)
            let candidates = _foldModel.foldCache.allFolds.filter { fold in
                fold.range.lowerBound >= bodyStart && fold.range.lowerBound < bodyEnd
            }
            return candidates.min(by: { $0.depth < $1.depth })
        }
        return nil
    }

    /// Toggle fold for a ribbon click on the header line.
    public func toggleFold(atLine lineIndex: Int) {
        guard configuration.peripherals.showFoldingRibbon else { return }
        guard let fold = foldStarting(atLine: lineIndex) else { return }
        applyFoldToggle(fold)
    }

    /// Expand collapsed folds containing `offset` (e.g. find navigation).
    @discardableResult
    public func expandFolds(containing offset: Int) -> Bool {
        let changed = _foldModel.expandFolds(containing: offset)
        if changed {
            selectedFoldPlaceholderID = nil
            syncFoldPlaceholdersAndHeights()
            onNeedsDisplay?()
        }
        return changed
    }

    /// Clear placeholder selection (click outside bubble).
    public func clearFoldPlaceholderSelection() {
        guard selectedFoldPlaceholderID != nil else { return }
        selectedFoldPlaceholderID = nil
        applyPlaceholderSelectionStyles()
        onNeedsDisplay?()
    }

    /// Handle a click on a fold placeholder (Xcode: select → expand).
    public func handleFoldPlaceholderClick(_ fold: FoldRange) {
        if selectedFoldPlaceholderID == fold.id {
            // Second click: expand.
            expandFoldFromPlaceholder(fold)
        } else {
            selectedFoldPlaceholderID = fold.id
            applyPlaceholderSelectionStyles()
            onNeedsDisplay?()
        }
    }

    func installFoldingIfNeeded() {
        guard !_foldingInstalled else { return }
        _foldingInstalled = true
        _foldModel.onFoldsDidChange = { [weak self] in
            self?.syncFoldPlaceholdersAndHeights()
            self?.onNeedsDisplay?()
        }
        rebuildFolds()
    }

    func rebuildFolds() {
        // Large-file mode disables folding work (UI-N09).
        guard largeFileMode.foldingEnabled, effectivePeripherals.showFoldingRibbon || !_foldModel.collapsedFolds.isEmpty
        else {
            if !largeFileMode.foldingEnabled {
                for fold in _foldModel.collapsedFolds {
                    _foldModel.setCollapsed(false, forFold: fold)
                }
                syncFoldPlaceholdersAndHeights()
            }
            return
        }
        let ctx = LineFoldProviderContext(
            document: document.fullString,
            indentOption: configuration.behavior.indentOption,
            lineCount: max(1, layout.lineIndex.count)
        )
        _foldModel.rebuild(context: ctx)
        syncFoldPlaceholdersAndHeights()
    }

    func noteFoldingEdit(range: NSRange, delta: Int) {
        guard largeFileMode.foldingEnabled else { return }
        let shouldTrack =
            configuration.peripherals.showFoldingRibbon
            || !_foldModel.collapsedFolds.isEmpty
        guard shouldTrack else { return }
        let ctx = LineFoldProviderContext(
            document: document.fullString,
            indentOption: configuration.behavior.indentOption,
            lineCount: max(1, layout.lineIndex.count)
        )
        _foldModel.documentDidEdit(editedRange: range, delta: delta, context: ctx)
    }

    private func applyFoldToggle(_ fold: FoldRange) {
        let willCollapse = !fold.isCollapsed
        selectedFoldPlaceholderID = nil
        _foldModel.toggleCollapse(forFold: fold)
        if willCollapse {
            addFoldPlaceholder(for: fold)
        } else {
            removeFoldPlaceholder(for: fold)
        }
        // Capture heights before/after for a short animation pulse.
        let heightBefore = layout.lineIndex.height
        syncFoldPlaceholdersAndHeights()
        let heightAfter = layout.lineIndex.height
        foldAnimationProgress = willCollapse ? 0 : 1
        runFoldAnimation(from: heightBefore, to: heightAfter, collapsing: willCollapse)
        onNeedsDisplay?()
    }

    private func addFoldPlaceholder(for fold: FoldRange) {
        guard let current = _foldModel.foldCache.allFolds.first(where: { $0.id == fold.id }) else { return }
        removeFoldPlaceholder(for: current)
        let style = LineFoldPlaceholderStyle.from(theme: configuration.theme)
        let charW = max(configuration.characterWidth, 1)
        // Bubble only — the real `}` stays on its original line (clickable / editable).
        let placeholder = LineFoldPlaceholder(
            fold: current,
            charWidth: charW,
            style: style,
            onSelect: { [weak self] f in self?.handleFoldPlaceholderClick(f) },
            onExpand: { [weak self] f in self?.expandFoldFromPlaceholder(f) }
        )
        placeholder.isSelected = (selectedFoldPlaceholderID == current.id)
        layout.attachments.add(
            placeholder,
            range: NSRange(location: current.range.lowerBound, length: max(1, current.nsRange.length))
        )
    }

    /// Expand a selection so it fully covers any collapsed fold it intersects
    /// (allows select-all-block + Delete to remove the whole folded body).
    public func selectionExpandedForCollapsedFolds(_ range: NSRange) -> NSRange {
        var start = range.location
        var end = range.location + range.length
        for fold in _foldModel.collapsedFolds {
            let fr = fold.nsRange
            let intersects =
                NSIntersectionRange(range, fr).length > 0
                || (range.length == 0 && range.location > fr.location && range.location < fr.location + fr.length)
            // Also: selected fold bubble counts as selecting the fold body.
            let bubbleSelected = selectedFoldPlaceholderID == fold.id && range.length == 0
            guard intersects || bubbleSelected else { continue }
            start = min(start, fr.location)
            end = max(end, fr.location + fr.length)
        }
        return NSRange(location: start, length: max(0, end - start))
    }

    /// Expand collapsed folds that intersect `range` so rebuild won't re-collapse deleted bodies.
    func expandCollapsedFoldsIntersecting(_ range: NSRange) {
        var changed = false
        for fold in _foldModel.collapsedFolds {
            if NSIntersectionRange(range, fold.nsRange).length > 0
                || (range.location <= fold.range.lowerBound
                    && range.location + range.length >= fold.range.upperBound)
            {
                _foldModel.setCollapsed(false, forFold: fold)
                removeFoldPlaceholder(for: fold)
                changed = true
            }
        }
        if changed {
            selectedFoldPlaceholderID = nil
        }
    }

    private func removeFoldPlaceholder(for fold: FoldRange) {
        layout.attachments.remove { item in
            guard let p = item.attachment as? LineFoldPlaceholder else { return false }
            return p.fold.id == fold.id
        }
    }

    private func expandFoldFromPlaceholder(_ fold: FoldRange) {
        selectedFoldPlaceholderID = nil
        let heightBefore = layout.lineIndex.height
        _foldModel.setCollapsed(false, forFold: fold)
        removeFoldPlaceholder(for: fold)
        syncFoldPlaceholdersAndHeights()
        let heightAfter = layout.lineIndex.height
        runFoldAnimation(from: heightBefore, to: heightAfter, collapsing: false)
        onNeedsDisplay?()
    }

    private func applyPlaceholderSelectionStyles() {
        for item in layout.attachments.items {
            guard let p = item.attachment as? LineFoldPlaceholder else { continue }
            p.isSelected = (p.fold.id == selectedFoldPlaceholderID)
        }
    }

    /// Align placeholders with collapsed set and zero-height hidden lines.
    func syncFoldPlaceholdersAndHeights() {
        let collapsed = Set(_foldModel.collapsedFolds.map(\.id))
        layout.attachments.remove { item in
            guard let p = item.attachment as? LineFoldPlaceholder else { return false }
            return !collapsed.contains(p.fold.id)
        }
        for fold in _foldModel.collapsedFolds {
            let has = layout.attachments.items.contains {
                ($0.attachment as? LineFoldPlaceholder)?.fold.id == fold.id
            }
            if !has {
                addFoldPlaceholder(for: fold)
            }
        }
        // Keep the real closer line (`}`) visible and editable; only hide the body.
        let folds = _foldModel.collapsedFolds
        layout.applyCollapsedFoldHeights(
            collapsedFolds: folds,
            hideCloserLines: false,
            document: document.fullString
        )
        applyPlaceholderSelectionStyles()
        layout.invalidateTypesetForVisibleLines()
        syncContentSizeFromLayout()
    }

    // MARK: - Animation

    private func runFoldAnimation(from heightBefore: CGFloat, to heightAfter: CGFloat, collapsing: Bool) {
        foldAnimationTask?.cancel()
        // Short eased redraw pulse so collapse/expand doesn't hard-cut.
        foldAnimationTask = Task { @MainActor [weak self] in
            let steps = 10
            let durationNs: UInt64 = 14_000_000  // ~140ms total
            for step in 0...steps {
                guard !Task.isCancelled else { return }
                let t = CGFloat(step) / CGFloat(steps)
                // ease-in-out
                let eased = t * t * (3 - 2 * t)
                self?.foldAnimationProgress = collapsing ? eased : (1 - eased)
                self?.onNeedsDisplay?()
                if step < steps {
                    try? await Task.sleep(nanoseconds: durationNs)
                }
            }
            self?.foldAnimationProgress = 1
            self?.onNeedsDisplay?()
        }
    }
}
