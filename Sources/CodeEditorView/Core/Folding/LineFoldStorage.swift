import CodeEditorCore
import Foundation

/// Sendable fold index over a document (CESE `LineFoldStorage` semantics on our `RangeStore`).
public struct LineFoldStorage: Sendable {
    /// Temporary fold before stable IDs are assigned.
    public struct RawFold: Sendable, Equatable {
        public let depth: Int
        public let range: Range<Int>

        public init(depth: Int, range: Range<Int>) {
            self.depth = depth
            self.range = range
        }
    }

    public struct DepthStartPair: Hashable, Sendable {
        public let depth: Int
        public let start: Int

        public init(depth: Int, start: Int) {
            self.depth = depth
            self.start = start
        }
    }

    struct FoldStoreElement: RangeStoreElement, Sendable {
        let id: FoldRange.FoldIdentifier
        let depth: Int
    }

    private var idCounter = FoldRange.FoldIdentifier.zero
    private var store: RangeStore<FoldStoreElement>
    private var foldRanges: [FoldRange.FoldIdentifier: FoldRange] = [:]

    public var documentLength: Int { store.length }

    public init(documentLength: Int, folds: [RawFold] = [], collapsedRanges: Set<DepthStartPair> = []) {
        self.store = RangeStore(documentLength: max(0, documentLength))
        if !folds.isEmpty {
            updateFolds(from: folds, collapsedRanges: collapsedRanges)
        }
    }

    private mutating func nextFoldId() -> FoldRange.FoldIdentifier {
        idCounter += 1
        return idCounter
    }

    /// Replace fold data from raw folds, preserving collapse when `(depth, start)` matches.
    public mutating func updateFolds(from rawFolds: [RawFold], collapsedRanges: Set<DepthStartPair>) {
        var reuseMap: [DepthStartPair: FoldRange] = [:]
        for region in foldRanges.values {
            reuseMap[DepthStartPair(depth: region.depth, start: region.range.lowerBound)] = region
        }

        foldRanges.removeAll(keepingCapacity: true)
        let length = store.length
        store = RangeStore(documentLength: length)

        for raw in rawFolds {
            guard raw.range.lowerBound < raw.range.upperBound else { continue }
            let clampedLower = max(0, min(raw.range.lowerBound, length))
            let clampedUpper = max(clampedLower, min(raw.range.upperBound, length))
            guard clampedLower < clampedUpper else { continue }

            let key = DepthStartPair(depth: raw.depth, start: clampedLower)
            let prior = reuseMap[key]
            let id = prior?.id ?? nextFoldId()
            let wasCollapsed = prior?.isCollapsed ?? false
            let isCollapsed = collapsedRanges.contains(key) || wasCollapsed
            let fold = FoldRange(
                id: id,
                depth: raw.depth,
                range: clampedLower..<clampedUpper,
                isCollapsed: isCollapsed
            )
            foldRanges[id] = fold
            store.set(
                value: FoldStoreElement(id: id, depth: raw.depth),
                for: NSRange(location: clampedLower, length: clampedUpper - clampedLower)
            )
        }
    }

    /// Keep fold offsets in sync after a document mutation.
    public mutating func storageUpdated(editedRange: NSRange, changeInLength delta: Int) {
        store.storageEdited(editRange: editedRange, delta: delta)
        // Remap fold dict ranges coarsely; full rebuild will re-sync.
        var next: [FoldRange.FoldIdentifier: FoldRange] = [:]
        for (id, fold) in foldRanges {
            let ns = fold.nsRange
            let remapped = MultiRangeEdit.remap(range: ns, editLocation: editedRange.location, delta: delta)
            guard remapped.length > 0 else { continue }
            next[id] = FoldRange(
                id: id,
                depth: fold.depth,
                range: remapped.location..<(remapped.location + remapped.length),
                isCollapsed: fold.isCollapsed
            )
        }
        foldRanges = next
    }

    public mutating func toggleCollapse(forFold fold: FoldRange) {
        guard var existing = foldRanges[fold.id] else { return }
        existing.isCollapsed.toggle()
        foldRanges[fold.id] = existing
    }

    public mutating func setCollapsed(_ collapsed: Bool, forFold fold: FoldRange) {
        guard var existing = foldRanges[fold.id] else { return }
        existing.isCollapsed = collapsed
        foldRanges[fold.id] = existing
    }

    /// All folds intersecting `queryRange`, ordered by start.
    public func folds(in queryRange: Range<Int>) -> [FoldRange] {
        let length = store.length
        guard length > 0 else { return [] }
        let lower = max(0, queryRange.lowerBound)
        let upper = min(length, queryRange.upperBound)
        guard lower < upper else { return [] }

        let runs = store.runs(in: NSRange(location: lower, length: upper - lower))
        var seen: Set<FoldRange.FoldIdentifier> = []
        var result: [FoldRange] = []
        for run in runs {
            guard let elem = run.value, !seen.contains(elem.id), let range = foldRanges[elem.id] else {
                continue
            }
            result.append(range)
            seen.insert(elem.id)
        }
        return result.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    /// Deepest fold covering `lineRange`, preferring collapsed folds (CESE ribbon click target).
    public func deepestFold(covering lineRange: NSRange) -> FoldRange? {
        let query = lineRange.location..<(lineRange.location + max(0, lineRange.length))
        let candidates = folds(in: query)
        return candidates.max { a, b in
            if a.isCollapsed != b.isCollapsed {
                return !a.isCollapsed && b.isCollapsed  // collapsed wins
            }
            if a.isCollapsed {
                return a.depth < b.depth
            }
            return a.depth > b.depth
        }
    }

    public var collapsedFolds: [FoldRange] {
        foldRanges.values.filter(\.isCollapsed).sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    public var allFolds: [FoldRange] {
        foldRanges.values.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }
}
