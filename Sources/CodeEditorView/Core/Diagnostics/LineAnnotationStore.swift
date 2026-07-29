import Foundation

/// Stores line annotations for the open document and groups them by line.
@MainActor
public final class LineAnnotationStore {
    public private(set) var items: [LineAnnotation] = []
    /// lineIndex → annotations sorted by column then severity.
    public private(set) var byLine: [Int: [LineAnnotation]] = [:]

    public init() {}

    public func setAnnotations(_ annotations: [LineAnnotation]) {
        items = annotations
        rebuildIndex()
    }

    public func clear() {
        items = []
        byLine = [:]
    }

    public func annotations(onLine line: Int) -> [LineAnnotation] {
        byLine[line] ?? []
    }

    public func bandHeight(forLine line: Int) -> CGFloat {
        AnnotationMetrics.bandHeight(forCount: annotations(onLine: line).count)
    }

    /// Drop annotations whose line is out of range after an edit rebuild.
    public func clampLines(lineCount: Int) {
        let maxLine = max(0, lineCount - 1)
        let filtered = items.filter { $0.line <= maxLine }
        if filtered.count != items.count {
            items = filtered
            rebuildIndex()
        }
    }

    /// Shift annotations that have a UTF-16 `range` when the document is edited.
    /// Line indices are recomputed by the controller from the live line index when needed.
    public func documentDidEdit(editedRange: NSRange, delta: Int) {
        guard delta != 0, !items.isEmpty else { return }
        var next: [LineAnnotation] = []
        next.reserveCapacity(items.count)
        for var ann in items {
            guard var range = ann.range else {
                next.append(ann)
                continue
            }
            let editEnd = editedRange.location + editedRange.length
            if range.location >= editEnd {
                range.location += delta
                ann.range = range
                next.append(ann)
            } else if range.location + range.length <= editedRange.location {
                next.append(ann)
            } else {
                // Overlaps edit — drop stale diagnostic.
                continue
            }
        }
        if next.count != items.count || zip(next, items).contains(where: { $0.range != $1.range }) {
            items = next
            rebuildIndex()
        }
    }

    private func rebuildIndex() {
        var map: [Int: [LineAnnotation]] = [:]
        for ann in items {
            map[ann.line, default: []].append(ann)
        }
        for key in map.keys {
            map[key]?.sort { a, b in
                if a.column != b.column { return a.column < b.column }
                return a.severity.rawValue < b.severity.rawValue
            }
        }
        byLine = map
    }
}
