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

    private var typesetter = Typesetter()
    private weak var document: DocumentStore?
    private var typingAttributes: [NSAttributedString.Key: Any] = [:]
    private var transactionDepth = 0
    private var needsFullRebuild = false

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
        if transactionDepth == 0, needsFullRebuild {
            rebuildFromDocument()
        }
    }

    public func invalidateAll() {
        if transactionDepth > 0 {
            needsFullRebuild = true
            return
        }
        rebuildFromDocument()
    }

    /// Reacts to a text replacement that already landed in the document store.
    public func documentDidReplace(range: NSRange, delta: Int) {
        // MVP: full rebuild. Phase 2 can do localized line surgery.
        invalidateAll()
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

        lineIndex.enumerateLines(inYRange: minY, maxY: maxY) { position in
            let line = position.payload
            if line.needsTypeset || line.fragments.isEmpty {
                typesetLine(position: position, document: document, maxWidth: layoutWidth)
            }

            // Re-read position after potential height update.
            guard let refreshed = self.lineIndex.line(atIndex: position.index) else { return }
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
        guard let line = lineIndex.line(atY: point.y) else { return 0 }
        var y = line.yOffset
        let localX = point.x - edgeInsets.leading

        let fragments = line.payload.fragments
        for (fragmentIndex, fragment) in fragments.enumerated() {
            let maxY = y + fragment.height
            if point.y <= maxY || fragmentIndex == fragments.count - 1 {
                if let ctLine = fragment.ctLine {
                    let index = CTLineGetStringIndexForPosition(ctLine, CGPoint(x: localX, y: 0))
                    let clamped = min(max(0, index), fragment.lineRelativeRange.length)
                    return line.utf16Offset + fragment.lineRelativeRange.location + clamped
                }
                return line.utf16Offset + fragment.lineRelativeRange.location
            }
            y = maxY
        }
        return line.utf16Offset + line.metrics.utf16Length
    }

    // MARK: - Private

    private func rebuildFromDocument() {
        needsFullRebuild = false
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
        let substring: NSAttributedString
        if range.length == 0 {
            substring = NSAttributedString(string: "", attributes: typingAttributes)
        } else {
            substring = document.attributedSubstring(from: range)
        }

        // Strip trailing line endings from typesetting width calculations, keep range metadata intact.
        let displayString = stripLineEnding(substring)
        let display = TypesetDisplayData(
            maxWidth: maxWidth,
            lineHeightMultiplier: lineHeightMultiplier,
            estimatedLineHeight: estimatedLineHeight
        )
        let result = typesetter.typeset(displayString, documentRange: range, display: display)
        position.payload.applyTypeset(fragments: result.fragments, height: result.totalHeight)
        if abs(result.totalHeight - position.metrics.height) > 0.5 {
            lineIndex.updateMetrics(
                atIndex: position.index,
                metrics: LineMetrics(utf16Length: position.metrics.utf16Length, height: result.totalHeight)
            )
        }
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
