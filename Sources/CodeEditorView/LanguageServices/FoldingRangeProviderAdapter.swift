import Foundation
import CodeEditorCore
import CodeEditorLanguageServices

/// Adapts language-service ``FoldingRange`` values to the editor's line-scan ``LineFoldProvider``.
@MainActor
public final class FoldingRangeProviderAdapter: LineFoldProvider {
    /// Precomputed fold ranges (startLine/endLine, zero-based inclusive-ish).
    public private(set) var ranges: [FoldingRange]
    /// Per-line start/end events derived from ranges.
    private var eventsByLine: [Int: [LineFoldProviderLineInfo]] = [:]

    public init(ranges: [FoldingRange] = []) {
        self.ranges = ranges
        rebuildEvents()
    }

    public func setRanges(_ ranges: [FoldingRange]) {
        self.ranges = ranges
        rebuildEvents()
    }

    public func foldLevelAtLine(
        lineNumber: Int,
        lineRange: NSRange,
        previousDepth: Int,
        context: LineFoldProviderContext
    ) -> [LineFoldProviderLineInfo] {
        _ = previousDepth
        _ = context
        guard let events = eventsByLine[lineNumber] else { return [] }
        // Clamp range indices into the line when providers omit characters.
        return events.map { event in
            switch event {
            case .startFold(let start, let depth):
                let clamped = max(lineRange.location, min(start, lineRange.location + lineRange.length))
                return .startFold(rangeStart: clamped, newDepth: depth)
            case .endFold(let end, let depth):
                let clamped = max(lineRange.location, min(end, lineRange.location + lineRange.length))
                return .endFold(rangeEnd: clamped, newDepth: depth)
            }
        }
    }

    private func rebuildEvents() {
        eventsByLine = [:]
        // Sort by start then end for stable nesting approximation.
        let sorted = ranges.sorted {
            if $0.startLine != $1.startLine { return $0.startLine < $1.startLine }
            return $0.endLine > $1.endLine
        }
        var depth = 0
        for range in sorted where range.endLine > range.startLine {
            depth += 1
            let startChar = range.startCharacter ?? 0
            let endChar = range.endCharacter ?? Int.max / 4
            eventsByLine[range.startLine, default: []].append(
                .startFold(rangeStart: startChar, newDepth: depth)
            )
            eventsByLine[range.endLine, default: []].append(
                .endFold(rangeEnd: endChar, newDepth: max(0, depth - 1))
            )
            depth = max(0, depth - 1)
        }
    }
}
