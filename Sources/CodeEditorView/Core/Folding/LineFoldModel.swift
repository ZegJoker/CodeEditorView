import Foundation

/// Conductor between fold calculation, storage, and UI (CESE `LineFoldModel`, no Combine).
@MainActor
public final class LineFoldModel {
    public static let emphasisGroup = "lineFolding"

    public private(set) var foldCache: LineFoldStorage
    public var foldProvider: any LineFoldProvider
    public var onFoldsDidChange: (() -> Void)?

    private var rebuildTask: Task<Void, Never>?
    private var generation: UInt64 = 0

    public init(
        documentLength: Int = 0,
        foldProvider: (any LineFoldProvider)? = nil
    ) {
        self.foldCache = LineFoldStorage(documentLength: documentLength)
        self.foldProvider = foldProvider ?? LineIndentationFoldProvider()
    }

    /// Immediate range shift after an edit; schedule a full rebuild.
    public func documentDidEdit(
        editedRange: NSRange,
        delta: Int,
        context: LineFoldProviderContext
    ) {
        foldCache.storageUpdated(editedRange: editedRange, changeInLength: delta)
        scheduleRebuild(context: context)
    }

    /// Force rebuild (e.g. language/indent change, first load).
    public func rebuild(context: LineFoldProviderContext) {
        scheduleRebuild(context: context, immediate: true)
    }

    public func folds(in range: NSRange) -> [FoldRange] {
        let upper = range.location + max(0, range.length)
        return foldCache.folds(in: range.location..<max(range.location, upper))
    }

    public func deepestFold(atLineRange lineRange: NSRange) -> FoldRange? {
        foldCache.deepestFold(covering: lineRange)
    }

    public func toggleCollapse(forFold fold: FoldRange) {
        foldCache.toggleCollapse(forFold: fold)
        onFoldsDidChange?()
    }

    public func setCollapsed(_ collapsed: Bool, forFold fold: FoldRange) {
        foldCache.setCollapsed(collapsed, forFold: fold)
        onFoldsDidChange?()
    }

    /// Expand every collapsed fold that contains `offset`.
    @discardableResult
    public func expandFolds(containing offset: Int) -> Bool {
        var changed = false
        for fold in foldCache.collapsedFolds where fold.range.contains(offset)
            || (offset == fold.range.upperBound && fold.range.lowerBound < offset)
            || (fold.range.lowerBound <= offset && offset < fold.range.upperBound)
        {
            foldCache.setCollapsed(false, forFold: fold)
            changed = true
        }
        if changed { onFoldsDidChange?() }
        return changed
    }

    public var collapsedFolds: [FoldRange] { foldCache.collapsedFolds }

    // MARK: - Private

    private func scheduleRebuild(context: LineFoldProviderContext, immediate: Bool = false) {
        generation &+= 1
        let gen = generation
        rebuildTask?.cancel()
        let work = { [weak self] in
            guard let self, self.generation == gen else { return }
            self.performRebuild(context: context)
        }
        if immediate {
            work()
            return
        }
        rebuildTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(24))
            guard !Task.isCancelled else { return }
            work()
        }
    }

    private func performRebuild(context: LineFoldProviderContext) {
        // Capture collapsed keys from current placeholders / cache.
        var collapsed: Set<LineFoldStorage.DepthStartPair> = []
        for fold in foldCache.collapsedFolds {
            collapsed.insert(LineFoldStorage.DepthStartPair(depth: fold.depth, start: fold.range.lowerBound))
        }

        let lines = LineFoldCalculator.lineRanges(in: context.document)
        let raw = LineFoldCalculator.buildRawFolds(
            context: context,
            lineRanges: lines,
            provider: foldProvider
        )

        // Resize store if document length changed.
        if foldCache.documentLength != context.documentLength {
            foldCache = LineFoldStorage(
                documentLength: context.documentLength,
                folds: raw,
                collapsedRanges: collapsed
            )
        } else {
            foldCache.updateFolds(from: raw, collapsedRanges: collapsed)
        }
        onFoldsDidChange?()
    }
}
