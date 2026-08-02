import CodeEditorCore
import CoreGraphics
import Foundation

/// Helpers that enforce native input first-rect / attributed-substring contracts (UI-N05).
public enum NativeInputContracts: Sendable {
    public struct AttributedSubstringResult: @unchecked Sendable {
        public let string: NSAttributedString
        public let actualRange: NSRange

        public init(string: NSAttributedString, actualRange: NSRange) {
            self.string = string
            self.actualRange = actualRange
        }
    }

    public struct FirstRectResult: Sendable {
        public let rect: CGRect
        public let actualRange: NSRange

        public init(rect: CGRect, actualRange: NSRange) {
            self.rect = rect
            self.actualRange = actualRange
        }
    }

    /// Returns substring and the actual UTF-16 range of returned content.
    ///
    /// Invalid proposed ranges yield empty content and empty `actualRange` (fail closed).
    public static func attributedSubstring(
        proposedRange: NSRange,
        documentLength: Int,
        substring: (NSRange) -> NSAttributedString
    ) -> AttributedSubstringResult {
        guard documentLength >= 0 else {
            return AttributedSubstringResult(
                string: NSAttributedString(string: ""),
                actualRange: NSRange(location: 0, length: 0)
            )
        }
        guard proposedRange.location >= 0,
            proposedRange.location <= documentLength,
            proposedRange.length >= 0
        else {
            return AttributedSubstringResult(
                string: NSAttributedString(string: ""),
                actualRange: NSRange(location: 0, length: 0)
            )
        }
        let (_, overflow) = proposedRange.location.addingReportingOverflow(proposedRange.length)
        guard !overflow else {
            return AttributedSubstringResult(
                string: NSAttributedString(string: ""),
                actualRange: NSRange(location: 0, length: 0)
            )
        }
        let clampedLen = min(proposedRange.length, documentLength - proposedRange.location)
        let actual = NSRange(location: proposedRange.location, length: max(0, clampedLen))
        if actual.length == 0 {
            return AttributedSubstringResult(
                string: NSAttributedString(string: ""),
                actualRange: actual
            )
        }
        let content = substring(actual)
        // Contract: actual range length matches returned content UTF-16 length.
        let contentLen = content.length
        let matched = NSRange(location: actual.location, length: min(actual.length, contentLen))
        if contentLen != actual.length {
            // Prefer content-derived length when store clamped further.
            return AttributedSubstringResult(string: content, actualRange: matched)
        }
        return AttributedSubstringResult(string: content, actualRange: actual)
    }

    /// First selection/IME candidate rect for `range` with actual covered range.
    public static func firstRect(
        for range: NSRange,
        layout: EditorLayoutSnapshot
    ) -> FirstRectResult {
        let len = layout.documentUTF16Length
        guard range.location >= 0, range.location <= len else {
            return FirstRectResult(rect: .zero, actualRange: NSRange(location: 0, length: 0))
        }
        let start = NativeInputPositions.clampedGraphemePosition(
            utf16Offset: range.location,
            in: layout.documentText
        )
        var actualLen = max(0, range.length)
        if start + actualLen > len {
            actualLen = max(0, len - start)
        }
        // Advance actual end to grapheme boundary.
        let endRaw = min(len, start + max(actualLen, range.length == 0 ? 0 : max(1, actualLen)))
        let end = NativeInputPositions.clampedGraphemePosition(
            utf16Offset: endRaw,
            in: layout.documentText
        )
        let actual = NSRange(location: start, length: max(0, end - start))
        guard let caret = layout.caretRect(atUTF16Offset: start) else {
            return FirstRectResult(rect: .zero, actualRange: actual)
        }
        if actual.length == 0 {
            return FirstRectResult(rect: caret, actualRange: actual)
        }
        // Expand width to end caret when on same fragment line.
        if let endCaret = layout.caretRect(atUTF16Offset: end),
            abs(endCaret.minY - caret.minY) < 0.5
        {
            let minX = min(caret.minX, endCaret.minX)
            let maxX = max(caret.maxX, endCaret.maxX)
            let rect = CGRect(
                x: minX,
                y: caret.minY,
                width: max(1, maxX - minX),
                height: max(1, caret.height)
            )
            return FirstRectResult(rect: rect, actualRange: actual)
        }
        return FirstRectResult(rect: caret, actualRange: actual)
    }
}

/// Factory for grapheme-valid document positions used by UITextInput adapters (UI-N02).
public enum NativeInputPositions: Sendable {
    /// Clamps to document bounds and snaps to a grapheme boundary (never mid-cluster).
    public static func clampedGraphemePosition(utf16Offset: Int, in text: String) -> Int {
        let len = (text as NSString).length
        let raw = min(max(0, utf16Offset), len)
        if TextOffsetSemantics.isGraphemeBoundary(utf16Offset: raw, in: text) {
            return raw
        }
        return
            (try? TextOffsetSemantics.validatedInsertionPoint(
                utf16Offset: raw,
                in: text,
                policy: .roundToGrapheme
            )) ?? raw
    }

    /// Validates a selection range so both endpoints are grapheme boundaries.
    public static func clampedGraphemeRange(_ range: NSRange, in text: String) -> NSRange {
        let len = (text as NSString).length
        guard range.location >= 0 else {
            return NSRange(location: 0, length: 0)
        }
        let start = clampedGraphemePosition(utf16Offset: range.location, in: text)
        let endRaw = min(len, max(start, range.location + max(0, range.length)))
        let end = clampedGraphemePosition(utf16Offset: endRaw, in: text)
        return NSRange(location: start, length: max(0, end - start))
    }
}
