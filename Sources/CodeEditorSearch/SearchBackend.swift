import CodeEditorCore
import CodeEditorDocuments
import Foundation

/// Pluggable search execution surface.
public protocol SearchBackend: Sendable {
    func search(_ query: SearchQuery, context: WorkspaceSearchContext) -> AsyncThrowingStream<SearchEvent, Error>
}

/// Native filesystem + open-document search (default).
public struct NativeSearchBackend: SearchBackend {
    public var maxFileBytes: Int
    public var respectGitIgnore: Bool
    /// Bounded concurrent file workers (SRCH-N04).
    public var maxConcurrentWorkers: Int
    /// Cap matches emitted per single file (SRCH-N06).
    public var maxMatchesPerFile: Int
    /// Soft per-file regex wall time (nanoseconds); 0 = unlimited (SRCH-N06).
    public var perFileTimeBudgetNanoseconds: UInt64

    public init(
        maxFileBytes: Int = 1_048_576,
        respectGitIgnore: Bool = true,
        maxConcurrentWorkers: Int = 4,
        maxMatchesPerFile: Int = 10_000,
        perFileTimeBudgetNanoseconds: UInt64 = 0
    ) {
        self.maxFileBytes = maxFileBytes
        self.respectGitIgnore = respectGitIgnore
        self.maxConcurrentWorkers = max(1, maxConcurrentWorkers)
        self.maxMatchesPerFile = max(1, maxMatchesPerFile)
        self.perFileTimeBudgetNanoseconds = perFileTimeBudgetNanoseconds
    }

    public func search(
        _ query: SearchQuery,
        context: WorkspaceSearchContext
    ) -> AsyncThrowingStream<SearchEvent, Error> {
        WorkspaceSearchService(context: context, backendOptions: self).search(query)
    }
}
