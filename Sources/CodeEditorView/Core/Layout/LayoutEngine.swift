import CoreGraphics
import CoreText
import Foundation

/// Builds and maintains line layout for a code document.
@MainActor
public final class LayoutEngine {
    public private(set) var lineIndex = LineIndex<TextLine>()
    public var wrapLines: Bool = true {
        didSet { if oldValue != wrapLines { invalidateAll() } }
    }
    public var lineHeightMultiplier: CGFloat = 1.0 {
        didSet { if oldValue != lineHeightMultiplier { invalidateAll() } }
    }
    public var lineBreakStrategy: LineBreakStrategy = .word {
        didSet {
            if oldValue != lineBreakStrategy {
                typesetter = Typesetter(breakStrategy: lineBreakStrategy)
                invalidateAll()
            }
        }
    }
    public var edgeInsets: HorizontalEdgeInsets = .zero
    public var verticalLayoutPadding: CGFloat = 350

    public private(set) var contentSize: CGSize = .zero
    public private(set) var estimatedLineHeight: CGFloat = 16
    /// Collapsed fold ranges currently applied to line heights (Phase 10).
    public private(set) var collapsedFolds: [FoldRange] = []
    /// Extra height under lines that show diagnostic annotation bands (Phase 12).
    public private(set) var annotationBandHeights: [Int: CGFloat] = [:]

    private var typesetter = Typesetter()
    private weak var document: DocumentStore?
    private var typingAttributes: [NSAttributedString.Key: Any] = [:]
    private var transactionDepth = 0
    private var needsFullRebuild = false
    private var pendingEdits: [(range: NSRange, delta: Int)] = []

    /// Inline attachments participating in typeset and hit-testing.
    public let attachments = AttachmentStore()

    public init() {}

    public func attach(document: DocumentStore, typingAttributes: [NSAttributedString.Key: Any]) {
        self.document = document
        self.typingAttributes = typingAttributes
        recomputeEstimatedLineHeight()
        rebuildFromDocument()
    }

    public func updateTypingAttributes(_ attributes: [NSAttributedString.Key: Any]) {
        typingAttributes = attributes
        recomputeEstimatedLineHeight()
    }

    public func beginTransaction() {
        transactionDepth += 1
    }

    public func endTransaction() {
        transactionDepth = max(0, transactionDepth - 1)
        guard transactionDepth == 0 else { return }
        if needsFullRebuild {
            pendingEdits.removeAll()
            rebuildFromDocument()
            return
        }
        let edits = pendingEdits
        pendingEdits.removeAll()
        for edit in edits {
            applyLocalizedEdit(range: edit.range, delta: edit.delta)
        }
    }

    public func invalidateAll() {
        if transactionDepth > 0 {
            needsFullRebuild = true
            return
        }
        // Preserve collapsed fold set across full rebuild (heights are wiped).
        let preserved = collapsedFolds
        rebuildFromDocument()
        if !preserved.isEmpty {
            let doc = document?.fullString ?? ""
            applyCollapsedFoldHeights(
                collapsedFolds: preserved,
                hideCloserLines: false,
                document: doc
            )
        }
    }

    /// Reacts to a text replacement that already landed in the document store.
    public func documentDidReplace(range: NSRange, delta: Int) {
        attachments.shift(forEditAt: range.location, delta: delta, replacedLength: range.length)
        if transactionDepth > 0 {
            pendingEdits.append((range, delta))
            return
        }
        applyLocalizedEdit(range: range, delta: delta)
    }

    /// Forces typeset refresh for lines intersecting `range`.
    public func invalidateTypeset(in range: NSRange) {
        guard let start = lineIndex.line(atUTF16Offset: range.location) else { return }
        let endOffset = max(range.location, range.location + max(0, range.length) - 1)
        let end = lineIndex.line(atUTF16Offset: endOffset) ?? start
        for index in start.index...end.index {
            lineIndex.line(atIndex: index)?.payload.markNeedsTypeset()
        }
    }

    public func layoutViewport(
        visibleRect: CGRect,
        containerWidth: CGFloat
    ) -> LayoutSnapshot {
        guard let document else { return .empty }

        let layoutWidth = wrapLines
            ? max(1, containerWidth - edgeInsets.horizontal)
            : CGFloat.greatestFiniteMagnitude

        let minY = max(0, visibleRect.minY - verticalLayoutPadding)
        let maxY = visibleRect.maxY + verticalLayoutPadding

        var laidOut: [LaidOutFragment] = []
        var maxContentWidth: CGFloat = 0

        let docNS = document.fullString as NSString
        // Ensure collapsed heights survive wrap/resize rebuilds that reintroduce estimated heights.
        if !collapsedFolds.isEmpty {
            reassertCollapsedHeightsIfNeeded(document: docNS)
        }

        lineIndex.enumerateLines(inYRange: minY, maxY: maxY) { position in
            // Skip / re-zero collapsed body lines only — keep real closer lines (`}`) visible.
            if self.isLineHiddenByCollapsedFold(position.utf16Range) {
                if position.metrics.height >= 0.5 {
                    self.lineIndex.updateMetrics(
                        atIndex: position.index,
                        metrics: LineMetrics(utf16Length: position.metrics.utf16Length, height: 0)
                    )
                    position.payload.applyTypeset(fragments: [], height: 0)
                }
                return
            }
            if position.metrics.height < 0.5 { return }
            let line = position.payload
            if line.needsTypeset || line.fragments.isEmpty {
                typesetLine(position: position, document: document, maxWidth: layoutWidth)
            }

            // Re-read position after potential height update.
            guard let refreshed = self.lineIndex.line(atIndex: position.index) else { return }
            if refreshed.metrics.height < 0.5 { return }
            var y = refreshed.yOffset
            for fragment in refreshed.payload.fragments {
                let frame = CGRect(
                    x: self.edgeInsets.leading,
                    y: y,
                    width: fragment.width,
                    height: fragment.height
                )
                laidOut.append(LaidOutFragment(fragment: fragment, frame: frame, lineIndex: refreshed.index))
                maxContentWidth = max(maxContentWidth, fragment.width + self.edgeInsets.horizontal)
                y += fragment.height
            }
        }

        // Ensure content size is current after typesetting.
        let width = wrapLines
            ? containerWidth
            : max(containerWidth, maxContentWidth, maxLineWidth())
        contentSize = CGSize(width: width, height: lineIndex.height)
        return LayoutSnapshot(contentSize: contentSize, fragments: laidOut)
    }

    /// If any collapsed fold line has non-zero height (e.g. after wrap resize), re-zero them.
    private func reassertCollapsedHeightsIfNeeded(document: NSString) {
        var needsPass = false
        for fold in collapsedFolds where fold.isCollapsed {
            // Probe a few offsets inside the fold body.
            let mid = (fold.range.lowerBound + fold.range.upperBound) / 2
            if let line = lineIndex.line(atUTF16Offset: mid),
               line.metrics.height >= 0.5,
               isLineHiddenByCollapsedFold(line.utf16Range)
                || isCloserLineHiddenByCollapsedFold(line.utf16Range, document: document) {
                needsPass = true
                break
            }
        }
        guard needsPass else { return }
        applyCollapsedFoldHeights(
            collapsedFolds: collapsedFolds,
            hideCloserLines: false,
            document: document as String
        )
    }

    /// Zero height for lines strictly inside collapsed folds; restore others via typeset.
    ///
    /// - Parameter hideCloserLines: When true, also hide a following line that is only a
    ///   closing delimiter (`}`, `)`, …) so it can be drawn after the `···` bubble (Xcode).
    public func applyCollapsedFoldHeights(
        collapsedFolds: [FoldRange],
        hideCloserLines: Bool = false,
        document: String = ""
    ) {
        self.collapsedFolds = collapsedFolds
        guard lineIndex.count > 0 else { return }
        let estimated = estimatedLineHeight * lineHeightMultiplier
        let ns = document as NSString
        for index in 0..<lineIndex.count {
            guard let pos = lineIndex.line(atIndex: index) else { continue }
            var hidden = isLineHiddenByCollapsedFold(pos.utf16Range)
            if !hidden, hideCloserLines, !document.isEmpty {
                hidden = isCloserLineHiddenByCollapsedFold(pos.utf16Range, document: ns)
            }
            if hidden {
                if pos.metrics.height > 0.5 {
                    lineIndex.updateMetrics(
                        atIndex: index,
                        metrics: LineMetrics(utf16Length: pos.metrics.utf16Length, height: 0)
                    )
                }
                pos.payload.applyTypeset(fragments: [], height: 0)
            } else if pos.metrics.height < 0.5 {
                // Was hidden — restore a provisional height; typeset will refine.
                lineIndex.updateMetrics(
                    atIndex: index,
                    metrics: LineMetrics(utf16Length: pos.metrics.utf16Length, height: estimated)
                )
                pos.payload.markNeedsTypeset()
            } else {
                // Ensure fold-start lines re-typeset to pick up placeholders.
                if collapsedFolds.contains(where: { fold in
                    fold.isCollapsed && NSLocationInRange(fold.range.lowerBound, pos.utf16Range)
                }) {
                    pos.payload.markNeedsTypeset()
                }
            }
        }
        contentSize = CGSize(width: contentSize.width, height: lineIndex.height)
    }

    /// Whether a line lies strictly inside a collapsed fold (not the fold-start line).
    ///
    /// Any line that **starts** inside the fold range (after the header) is hidden, including
    /// whole body lines whose ranges are covered by a line-snapped fold end.
    public func isLineHiddenByCollapsedFold(_ lineRange: NSRange) -> Bool {
        guard !collapsedFolds.isEmpty, lineRange.length >= 0 else { return false }
        let lineStart = lineRange.location
        let lineEnd = lineRange.location + lineRange.length
        for fold in collapsedFolds where fold.isCollapsed {
            let fStart = fold.range.lowerBound
            let fEnd = fold.range.upperBound
            // Header line (contains fold start) stays visible — shows prefix + bubble.
            if lineStart <= fStart && fStart < lineEnd {
                continue
            }
            // Line starts inside the fold body.
            if lineStart >= fStart && lineStart < fEnd {
                return true
            }
            // Line fully covered by fold (belt-and-suspenders).
            if lineStart > fStart && lineEnd <= fEnd {
                return true
            }
        }
        return false
    }

    /// Hide a simple closer line (`}`, `fi`, …) that immediately follows a collapsed fold end
    /// (that glyph is re-drawn after the bubble on the header line).
    func isCloserLineHiddenByCollapsedFold(_ lineRange: NSRange, document: NSString) -> Bool {
        for fold in collapsedFolds where fold.isCollapsed {
            if let info = closerLineInfo(for: fold, document: document),
               info.lineRange.location == lineRange.location {
                return true
            }
        }
        return false
    }

    /// Hit-test fold placeholders using laid-out fragment frames.
    public func foldPlaceholder(at point: CGPoint, containerWidth: CGFloat) -> LineFoldPlaceholder? {
        let snapshot = layoutViewport(
            visibleRect: CGRect(x: 0, y: max(0, point.y - 2), width: containerWidth, height: 4),
            containerWidth: containerWidth
        )
        for item in snapshot.fragments {
            guard !item.fragment.attachments.isEmpty else { continue }
            let textWidth: CGFloat
            if let ctLine = item.fragment.ctLine {
                textWidth = CGFloat(CTLineGetTypographicBounds(ctLine, nil, nil, nil))
            } else {
                textWidth = 0
            }
            var x = item.frame.minX + textWidth
            for att in item.fragment.attachments {
                let rect = CGRect(x: x, y: item.frame.minY, width: att.width, height: item.frame.height)
                if rect.insetBy(dx: -2, dy: -2).contains(point),
                   let placeholder = att.attachment as? LineFoldPlaceholder {
                    return placeholder
                }
                x += att.width
            }
        }
        return nil
    }

    public func invalidateTypesetForVisibleLines() {
        for index in 0..<lineIndex.count {
            guard let pos = lineIndex.line(atIndex: index) else { continue }
            if pos.metrics.height >= 0.5 {
                pos.payload.markNeedsTypeset()
            }
        }
    }

    public func caretRect(atUTF16Offset offset: Int, containerWidth: CGFloat) -> CGRect? {
        _ = layoutViewport(
            visibleRect: CGRect(x: 0, y: 0, width: containerWidth, height: contentSize.height),
            containerWidth: containerWidth
        )
        guard let line = lineIndex.line(atUTF16Offset: offset) else { return nil }
        let relative = offset - line.utf16Offset
        var y = line.yOffset
        for fragment in line.payload.fragments {
            let fragStart = fragment.lineRelativeRange.location
            let fragEnd = fragStart + fragment.lineRelativeRange.length
            if relative < fragStart {
                return CGRect(x: edgeInsets.leading, y: y, width: 1, height: fragment.height)
            }
            if relative <= fragEnd {
                let x: CGFloat
                if let ctLine = fragment.ctLine {
                    let local = relative - fragStart
                    x = edgeInsets.leading + CGFloat(CTLineGetOffsetForStringIndex(ctLine, local, nil))
                } else {
                    x = edgeInsets.leading
                }
                return CGRect(x: x, y: y, width: 1, height: fragment.height)
            }
            y += fragment.height
        }
        // End of line.
        if let last = line.payload.fragments.last {
            return CGRect(
                x: edgeInsets.leading + last.width,
                y: line.yOffset + line.metrics.height - last.height,
                width: 1,
                height: last.height
            )
        }
        return CGRect(x: edgeInsets.leading, y: line.yOffset, width: 1, height: line.metrics.height)
    }

    public func utf16Offset(at point: CGPoint, containerWidth: CGFloat) -> Int {
        _ = layoutViewport(
            visibleRect: CGRect(x: 0, y: max(0, point.y - 1), width: containerWidth, height: 2),
            containerWidth: containerWidth
        )
        // Prefer the first non-zero-height line at/above this Y so ghost collapsed
        // rows never steal clicks meant for the real closer line below.
        guard let line = visibleLine(atY: point.y) else { return 0 }
        var y = line.yOffset
        let localX = point.x - edgeInsets.leading

        // Click in the gutter / left margin → column 0 of this line (not end of previous).
        if localX <= 0 {
            return line.utf16Offset
        }

        let fragments = line.payload.fragments
        // Content length excludes trailing line ending so clicks past text land before `\n`.
        let contentLength = contentUTF16Length(of: line)

        for (fragmentIndex, fragment) in fragments.enumerated() {
            let maxY = y + fragment.height
            if point.y <= maxY || fragmentIndex == fragments.count - 1 {
                // Collapsed fold header: text | ··· bubble | (rest of line is fold body).
                // Clicks past the bubble jump to the end of the fold (start of real `}` line).
                if let fold = collapsedFoldStarting(on: line) {
                    let textWidth: CGFloat
                    if let ctLine = fragment.ctLine {
                        textWidth = CGFloat(CTLineGetTypographicBounds(ctLine, nil, nil, nil))
                    } else {
                        textWidth = 0
                    }
                    let bubbleW = fragment.attachments
                        .filter { $0.attachment is LineFoldPlaceholder }
                        .reduce(CGFloat(0)) { $0 + $1.width }
                    // Bubble line is the first body row: indent | ··· | (end of fold body).
                    if localX > textWidth + bubbleW + 2 {
                        return fold.range.upperBound
                    }
                    if localX >= textWidth {
                        return fold.range.lowerBound
                    }
                }

                if let ctLine = fragment.ctLine {
                    let index = CTLineGetStringIndexForPosition(ctLine, CGPoint(x: localX, y: 0))
                    let fragLen = fragment.lineRelativeRange.length
                    let clamped = min(max(0, index), fragLen)
                    let absolute = line.utf16Offset + fragment.lineRelativeRange.location + clamped
                    // Don't place the caret on the trailing newline character itself.
                    return min(absolute, line.utf16Offset + contentLength)
                }
                return line.utf16Offset + fragment.lineRelativeRange.location
            }
            y = maxY
        }
        return line.utf16Offset + contentLength
    }

    /// First laid-out (non-zero height) line containing or above `y`.
    private func visibleLine(atY y: CGFloat) -> LinePosition<TextLine>? {
        if let line = lineIndex.line(atY: y), line.metrics.height >= 0.5 {
            return line
        }
        // Walk upward for a visible line (collapsed rows have height 0).
        var probe = y
        for _ in 0..<64 {
            probe -= max(estimatedLineHeight, 8)
            if probe < 0 {
                return lineIndex.first.flatMap { $0.metrics.height >= 0.5 ? $0 : nil }
            }
            if let line = lineIndex.line(atY: max(0, probe)), line.metrics.height >= 0.5 {
                return line
            }
        }
        // Fallback: last visible line at or below y.
        var best: LinePosition<TextLine>?
        lineIndex.forEach { pos in
            if pos.metrics.height >= 0.5, pos.yOffset <= y {
                best = pos
            }
        }
        return best ?? lineIndex.line(atY: y)
    }

    private func collapsedFoldStarting(on line: LinePosition<TextLine>) -> FoldRange? {
        let start = line.utf16Offset
        let end = start + max(line.metrics.utf16Length, 1)
        return collapsedFolds.first { fold in
            fold.isCollapsed && fold.range.lowerBound >= start && fold.range.lowerBound < end
        }
    }

    /// UTF-16 length of a line excluding a trailing `\n` / `\r\n` / `\r`.
    private func contentUTF16Length(of line: LinePosition<TextLine>) -> Int {
        guard let document, line.metrics.utf16Length > 0 else { return 0 }
        let range = line.utf16Range
        guard range.location + range.length <= document.length else {
            return max(0, document.length - line.utf16Offset)
        }
        let text = document.substring(from: range) ?? ""
        if text.hasSuffix("\r\n") { return max(0, line.metrics.utf16Length - 2) }
        if text.hasSuffix("\n") || text.hasSuffix("\r") { return max(0, line.metrics.utf16Length - 1) }
        return line.metrics.utf16Length
    }

    // MARK: - Private

    private func applyLocalizedEdit(range: NSRange, delta: Int) {
        guard let document else {
            rebuildFromDocument()
            return
        }
        if lineIndex.isEmpty || document.length == 0 {
            rebuildFromDocument()
            return
        }

        // Tree still reflects pre-edit lengths; `range` is the pre-edit mutation range.
        let preDocLength = lineIndex.length
        guard preDocLength + delta == document.length else {
            rebuildFromDocument()
            return
        }

        let endProbe = max(range.location, range.location + max(0, range.length) - (range.length > 0 ? 1 : 0))
        guard
            let startLine = lineIndex.line(atUTF16Offset: min(range.location, max(0, preDocLength - 1))),
            let endLine = lineIndex.line(atUTF16Offset: min(endProbe, max(0, preDocLength - 1)))
        else {
            rebuildFromDocument()
            return
        }

        // Expand by one line of context on each side. Deleting a line terminator only
        // dirties that line by offset, but the next line must be re-merged into the
        // block or we leave a terminator-less row + a lone `\n` phantom blank
        // (the CESE-style "Delete at col 0 of blank" path).
        let firstLineIndex = max(0, min(startLine.index, endLine.index) - 1)
        let lastLineIndex = min(lineIndex.count - 1, max(startLine.index, endLine.index) + 1)
        let dirtyCount = lastLineIndex - firstLineIndex + 1
        if dirtyCount > 200 || dirtyCount > lineIndex.count / 2 {
            rebuildFromDocument()
            return
        }

        guard
            let firstPos = lineIndex.line(atIndex: firstLineIndex),
            let lastPos = lineIndex.line(atIndex: lastLineIndex)
        else {
            rebuildFromDocument()
            return
        }

        let oldBlockStart = firstPos.utf16Offset
        let oldBlockEnd = lastPos.utf16Offset + lastPos.metrics.utf16Length
        // Map old block end into post-edit document coordinates.
        let newBlockStart = oldBlockStart
        let newBlockEnd = oldBlockEnd + delta
        guard newBlockStart >= 0, newBlockEnd >= newBlockStart, newBlockEnd <= document.length else {
            rebuildFromDocument()
            return
        }

        let substring = document.substring(
            from: NSRange(location: newBlockStart, length: newBlockEnd - newBlockStart)
        ) ?? ""
        // Never append a trailing empty line for a localized slice — only full rebuilds do that.
        let newMetrics = LayoutInvalidation.splitLines(
            in: substring,
            estimatedHeight: estimatedLineHeight * lineHeightMultiplier,
            includeTrailingEmptyLine: false
        )

        for index in stride(from: lastLineIndex, through: firstLineIndex, by: -1) {
            lineIndex.remove(atIndex: index)
        }
        // newMetrics may be empty when a whole line was deleted (e.g. blank-line Delete).
        for (offset, metrics) in newMetrics.enumerated() {
            let line = TextLine()
            line.markNeedsTypeset()
            lineIndex.insert(payload: line, metrics: metrics, atIndex: firstLineIndex + offset)
        }

        // Never leave the index empty if the document still has content or needs a caret row.
        if lineIndex.isEmpty {
            rebuildFromDocument()
            return
        }

        // Coverage check: every document UTF-16 unit must belong to exactly one line,
        // and there must be no zero-length phantom rows mid-document (offset collisions).
        // Non-final lines must end with a terminator — otherwise a prior join left a
        // terminator-less row and a following lone-`\n` "blank" that cannot be deleted.
        if lineIndex.length != document.length {
            rebuildFromDocument()
            return
        }
        var covered = 0
        var ok = true
        var seenEmptyMid = false
        var seenBareMidLine = false
        let lineCount = lineIndex.count
        lineIndex.forEach { pos in
            if pos.utf16Offset != covered { ok = false }
            if pos.metrics.utf16Length == 0 {
                // Trailing empty after final newline is OK; mid-document empty is not.
                if covered != document.length {
                    seenEmptyMid = true
                }
            } else if pos.index < lineCount - 1 {
                // Non-final line must consume a trailing line ending.
                let r = pos.utf16Range
                if r.location + r.length <= document.length,
                   let text = document.substring(from: r),
                   !(text.hasSuffix("\n") || text.hasSuffix("\r")) {
                    seenBareMidLine = true
                }
            }
            covered += pos.metrics.utf16Length
        }
        if !ok || covered != document.length || seenEmptyMid || seenBareMidLine {
            rebuildFromDocument()
            return
        }
        // Localized slices never invent a trailing empty row (mid-document `\n` would
        // create phantoms). After the edit, restore full-document trailing-caret
        // semantics: if the buffer ends with a line ending, the caret needs a final
        // zero-length line — otherwise the first Return at EOF only bumps column
        // (caret sits on the terminator of the last content line with no new row).
        ensureTrailingCaretLine()
        // Localized metrics rebuild can restore estimated heights on collapsed lines.
        if !collapsedFolds.isEmpty {
            applyCollapsedFoldHeights(
                collapsedFolds: collapsedFolds,
                hideCloserLines: false,
                document: document.fullString
            )
        } else {
            contentSize = CGSize(width: contentSize.width, height: lineIndex.height)
        }
    }

    /// Matches full-rebuild behavior: a document that ends with `\n`/`\r` gets a final
    /// zero-length line so the caret can sit after the last terminator.
    private func ensureTrailingCaretLine() {
        guard let document, document.length > 0, lineIndex.count > 0 else { return }
        let ns = document.fullString as NSString
        let lastUnit = ns.character(at: document.length - 1)
        let endsWithTerminator = lastUnit == 0x0A || lastUnit == 0x0D
        let estimated = estimatedLineHeight * lineHeightMultiplier

        if endsWithTerminator {
            if let last = lineIndex.last, last.metrics.utf16Length > 0 {
                let line = TextLine()
                line.markNeedsTypeset()
                lineIndex.insert(
                    payload: line,
                    metrics: LineMetrics(utf16Length: 0, height: estimated),
                    atIndex: lineIndex.count
                )
            }
        } else if let last = lineIndex.last,
                  last.metrics.utf16Length == 0,
                  lineIndex.count > 1 {
            // Document no longer ends with a terminator — drop a stale trailing empty.
            lineIndex.remove(atIndex: lineIndex.count - 1)
        }
    }

    private func rebuildFromDocument() {
        needsFullRebuild = false
        pendingEdits.removeAll()
        guard let document else {
            lineIndex.removeAll()
            contentSize = .zero
            return
        }
        recomputeEstimatedLineHeight()
        lineIndex = LineIndex.build(
            from: document.fullString,
            estimatedLineHeight: estimatedLineHeight * lineHeightMultiplier
        ) { _ in TextLine() }
        contentSize = CGSize(width: contentSize.width, height: lineIndex.height)
    }

    private func typesetLine(
        position: LinePosition<TextLine>,
        document: DocumentStore,
        maxWidth: CGFloat
    ) {
        let range = position.utf16Range
        if isLineHiddenByCollapsedFold(range) {
            position.payload.applyTypeset(fragments: [], height: 0)
            if position.metrics.height > 0.5 {
                lineIndex.updateMetrics(
                    atIndex: position.index,
                    metrics: LineMetrics(utf16Length: position.metrics.utf16Length, height: 0)
                )
            }
            return
        }
        // Guard against transient line-index/document desync (would throw in attributedSubstring).
        guard range.location >= 0,
              range.location <= document.length,
              range.location + range.length <= document.length
        else {
            position.payload.applyTypeset(fragments: [], height: estimatedLineHeight * lineHeightMultiplier)
            return
        }

        // Collapsed fold whose body *starts* on this line: show leading indent + `···` only
        // (bubble at the folded line start — not after `{` on the header line).
        let collapsedStart = collapsedFolds.first { fold in
            fold.isCollapsed && fold.range.lowerBound >= range.location
                && fold.range.lowerBound < range.location + max(range.length, 1)
        }
        let prefixRange: NSRange
        let displayString: NSAttributedString
        let lineAttachments: [AnyTextAttachment]
        if collapsedStart != nil {
            // Keep original indent spaces/tabs so the bubble aligns with body indent.
            let indentLen = leadingWhitespaceLength(in: range, document: document)
            prefixRange = NSRange(location: range.location, length: indentLen)
            if indentLen > 0 {
                displayString = stripLineEnding(document.attributedSubstring(from: prefixRange))
            } else {
                displayString = NSAttributedString(string: "", attributes: typingAttributes)
            }
            lineAttachments = attachments.attachments(overlapping: range).filter {
                $0.attachment is LineFoldPlaceholder
            }
        } else {
            prefixRange = range
            let substring: NSAttributedString
            if range.length == 0 {
                substring = NSAttributedString(string: "", attributes: typingAttributes)
            } else {
                substring = document.attributedSubstring(from: range)
            }
            displayString = stripLineEnding(substring)
            lineAttachments = attachments.attachments(overlapping: range)
        }
        let display = TypesetDisplayData(
            maxWidth: maxWidth,
            lineHeightMultiplier: lineHeightMultiplier,
            estimatedLineHeight: estimatedLineHeight
        )
        let result = typesetter.typeset(
            displayString,
            documentRange: prefixRange,
            display: display,
            attachments: lineAttachments
        )
        let band = annotationBandHeights[position.index] ?? 0
        // Keep fragment heights as code-only; total line height includes annotation band.
        let totalHeight = result.totalHeight + band
        position.payload.applyTypeset(fragments: result.fragments, height: totalHeight)
        if abs(totalHeight - position.metrics.height) > 0.5 {
            lineIndex.updateMetrics(
                atIndex: position.index,
                metrics: LineMetrics(utf16Length: position.metrics.utf16Length, height: totalHeight)
            )
        }
    }

    /// Apply under-line annotation band heights (line index → extra height).
    /// Re-typesets affected lines so scroll metrics stay consistent.
    public func setAnnotationBandHeights(_ heights: [Int: CGFloat]) {
        let old = annotationBandHeights
        annotationBandHeights = heights
        let keys = Set(old.keys).union(heights.keys)
        for index in keys {
            guard let pos = lineIndex.line(atIndex: index) else { continue }
            if isLineHiddenByCollapsedFold(pos.utf16Range) { continue }
            pos.payload.markNeedsTypeset()
            // Provisional height bump so content size updates before next viewport typeset.
            let codeEstimate = max(pos.metrics.height - (old[index] ?? 0), estimatedLineHeight * lineHeightMultiplier)
            let band = heights[index] ?? 0
            let newH = codeEstimate + band
            if abs(newH - pos.metrics.height) > 0.5 {
                lineIndex.updateMetrics(
                    atIndex: index,
                    metrics: LineMetrics(utf16Length: pos.metrics.utf16Length, height: newH)
                )
            }
        }
        contentSize = CGSize(width: contentSize.width, height: lineIndex.height)
    }

    /// Locate a simple closer line right after a fold end (`}`, `)`, …).
    func closerLineInfo(
        for fold: FoldRange,
        document: NSString
    ) -> (lineRange: NSRange, token: String, tokenRange: NSRange)? {
        let end = fold.range.upperBound
        guard document.length > 0 else { return nil }

        // Prefer the line that begins at/after the fold end (typical endFold position).
        let probe = min(max(0, end), document.length - 1)
        var lineStart = 0, lineEnd = 0, contentsEnd = 0
        document.getLineStart(
            &lineStart,
            end: &lineEnd,
            contentsEnd: &contentsEnd,
            for: NSRange(location: probe, length: 0)
        )
        // If probe landed on the previous line, step forward to the next line start.
        if lineEnd <= end, lineEnd < document.length {
            document.getLineStart(
                &lineStart,
                end: &lineEnd,
                contentsEnd: &contentsEnd,
                for: NSRange(location: lineEnd, length: 0)
            )
        }

        let lineRange = NSRange(location: lineStart, length: lineEnd - lineStart)
        let contentRange = NSRange(location: lineStart, length: max(0, contentsEnd - lineStart))
        guard contentRange.length > 0 else { return nil }
        let content = document.substring(with: contentRange)
        let trimmed = content.trimmingCharacters(in: .whitespaces)
        let closers: Set<String> = ["}", ")", "]", "fi", "done", "esac"]
        guard closers.contains(trimmed) else { return nil }

        // Only accept closers that belong to this fold (line starts near fold end).
        guard abs(lineStart - end) <= 8 || (lineStart >= end && lineStart <= end + 8) else {
            return nil
        }

        let leading = content.prefix { $0 == " " || $0 == "\t" }.count
        let tokenRange = NSRange(location: lineStart + leading, length: trimmed.utf16.count)
        return (lineRange, trimmed, tokenRange)
    }

    private func stripLineEnding(_ string: NSAttributedString) -> NSAttributedString {
        guard string.length > 0 else { return string }
        let ns = string.string as NSString
        var length = string.length
        if length > 0 {
            let last = ns.character(at: length - 1)
            if last == 0x0A {
                length -= 1
                if length > 0, ns.character(at: length - 1) == 0x0D {
                    length -= 1
                }
            } else if last == 0x0D {
                length -= 1
            }
        }
        if length == string.length { return string }
        return string.attributedSubstring(from: NSRange(location: 0, length: length))
    }

    private func leadingWhitespaceLength(in range: NSRange, document: DocumentStore) -> Int {
        guard range.length > 0, let text = document.substring(from: range) else { return 0 }
        var count = 0
        for ch in text {
            if ch == " " || ch == "\t" {
                count += 1
            } else {
                break
            }
        }
        return count
    }

    private func recomputeEstimatedLineHeight() {
        let font = typingAttributes[.font] as? PlatformFont
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        let lineHeight = font?.boundingRectForFont.height ?? 16
        #elseif canImport(UIKit)
        let lineHeight = font?.lineHeight ?? 16
        #else
        let lineHeight: CGFloat = 16
        #endif
        estimatedLineHeight = max(lineHeight, 1)
    }

    private func maxLineWidth() -> CGFloat {
        var maxWidth: CGFloat = 0
        lineIndex.forEach { position in
            for fragment in position.payload.fragments {
                maxWidth = max(maxWidth, fragment.width + edgeInsets.horizontal)
            }
            if position.payload.needsTypeset {
                maxWidth = max(maxWidth, 100)
            }
        }
        return maxWidth
    }
}

// Platform font access for height estimation only — see PlatformTypes.
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
