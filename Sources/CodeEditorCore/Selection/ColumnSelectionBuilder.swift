import CoreGraphics
import CoreText
import Foundation

/// Minimal fragment geometry for rectangular column selection.
///
/// View-layer layout produces ``LaidOutFragment`` values and maps them into this
/// Core-friendly shape so selection does not depend on typesetting types.
///
/// `@unchecked Sendable`: `CTLine` is not Sendable; fragments are value snapshots
/// used only on the layout/main actor and never mutated across isolation domains.
public struct ColumnSelectionFragment: @unchecked Sendable {
    public var frame: CGRect
    public var documentRange: NSRange
    public var ctLine: CTLine?

    public init(frame: CGRect, documentRange: NSRange, ctLine: CTLine?) {
        self.frame = frame
        self.documentRange = documentRange
        self.ctLine = ctLine
    }
}

/// Builds per-line selection ranges from a rectangular column selection.
public enum ColumnSelectionBuilder {
    /// Returns document ranges for text whose caret x falls inside `[minX, maxX]` on lines
    /// intersecting `[minY, maxY]`.
    public static func ranges(
        in rect: CGRect,
        fragments: [ColumnSelectionFragment],
        documentLength: Int
    ) -> [NSRange] {
        let minX = min(rect.minX, rect.maxX)
        let maxX = max(rect.minX, rect.maxX)
        let minY = min(rect.minY, rect.maxY)
        let maxY = max(rect.minY, rect.maxY)

        var result: [NSRange] = []
        for item in fragments {
            let frame = item.frame
            guard frame.maxY > minY, frame.minY < maxY else { continue }
            guard let ctLine = item.ctLine else {
                // Empty visual line: insertion at line start if column covers leading edge.
                if minX <= frame.minX, maxX >= frame.minX {
                    let loc = item.documentRange.location
                    result.append(NSRange(location: loc, length: 0))
                }
                continue
            }

            let localMin = max(0, minX - frame.minX)
            let localMax = max(0, maxX - frame.minX)
            let startIndex = CTLineGetStringIndexForPosition(ctLine, CGPoint(x: localMin, y: 0))
            let endIndex = CTLineGetStringIndexForPosition(ctLine, CGPoint(x: localMax, y: 0))
            let fragStart = item.documentRange.location
            let fragLen = item.documentRange.length
            let a = min(max(0, startIndex), fragLen)
            let b = min(max(0, endIndex), fragLen)
            let location = fragStart + min(a, b)
            let length = abs(a - b)
            if length > 0 || a == b {
                result.append(NSRange(location: location, length: length))
            }
        }

        return MultiRangeEdit.normalize(result, documentLength: documentLength)
    }
}
