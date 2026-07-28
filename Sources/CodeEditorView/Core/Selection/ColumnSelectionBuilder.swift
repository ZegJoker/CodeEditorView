import CoreGraphics
import CoreText
import Foundation

/// Builds per-line selection ranges from a rectangular column selection.
public enum ColumnSelectionBuilder {
    /// Returns document ranges for text whose caret x falls inside `[minX, maxX]` on lines
    /// intersecting `[minY, maxY]`.
    public static func ranges(
        in rect: CGRect,
        fragments: [LaidOutFragment],
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
            guard let ctLine = item.fragment.ctLine else {
                // Empty visual line: insertion at line start if column covers leading edge.
                if minX <= frame.minX, maxX >= frame.minX {
                    let loc = item.fragment.documentRange.location
                    result.append(NSRange(location: loc, length: 0))
                }
                continue
            }

            let localMin = max(0, minX - frame.minX)
            let localMax = max(0, maxX - frame.minX)
            let startIndex = CTLineGetStringIndexForPosition(ctLine, CGPoint(x: localMin, y: 0))
            let endIndex = CTLineGetStringIndexForPosition(ctLine, CGPoint(x: localMax, y: 0))
            let fragStart = item.fragment.documentRange.location
            let fragLen = item.fragment.documentRange.length
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
