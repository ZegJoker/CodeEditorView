import CoreGraphics
import Foundation

/// A non-whitespace run to paint as a bubble in the minimap.
public struct MinimapBubbleRun: Equatable, Sendable {
    /// UTF-16 column within the line (document line-relative).
    public var column: Int
    /// UTF-16 length of the run.
    public var length: Int
    /// Optional capture for themed coloring (nil → default text color).
    public var capture: CaptureName?

    public init(column: Int, length: Int, capture: CaptureName?) {
        self.column = max(0, column)
        self.length = max(0, length)
        self.capture = capture
    }

    public var minimapX: CGFloat {
        MinimapMetrics.contentLeading + CGFloat(column) * MinimapMetrics.charWidthScale
    }

    public var minimapWidth: CGFloat {
        max(1, CGFloat(length) * MinimapMetrics.charWidthScale)
    }
}

/// Builds minimap bubble runs for a single logical line of text.
public enum MinimapRunBuilder: Sendable {
    /// Produce non-whitespace runs for `lineText` using optional capture runs.
    ///
    /// - Parameters:
    ///   - lineText: Full line including terminator if present (whitespace in terminator skipped).
    ///   - captureRuns: Runs covering the same UTF-16 span as `lineText` (local offsets 0..<n).
    public static func bubbles(
        lineText: String,
        captureRuns: [(range: NSRange, capture: CaptureName?)] = []
    ) -> [MinimapBubbleRun] {
        let ns = lineText as NSString
        let length = ns.length
        guard length > 0 else { return [] }

        // Flatten capture at each unit for O(n) walk.
        var captures = [CaptureName?](repeating: nil, count: length)
        for run in captureRuns {
            let start = max(0, run.range.location)
            let end = min(length, run.range.location + run.range.length)
            guard start < end else { continue }
            for i in start..<end {
                captures[i] = run.capture
            }
        }

        var result: [MinimapBubbleRun] = []
        var i = 0
        while i < length {
            let ch = ns.character(at: i)
            if isWhitespace(ch) {
                i += 1
                continue
            }
            let start = i
            let capture = captures[i]
            i += 1
            while i < length {
                let next = ns.character(at: i)
                if isWhitespace(next) { break }
                if captures[i] != capture { break }
                i += 1
            }
            result.append(MinimapBubbleRun(column: start, length: i - start, capture: capture))
        }
        return result
    }

    private static func isWhitespace(_ unit: unichar) -> Bool {
        unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0x0D
            || (UnicodeScalar(unit).map { CharacterSet.whitespacesAndNewlines.contains($0) } ?? false)
    }
}
