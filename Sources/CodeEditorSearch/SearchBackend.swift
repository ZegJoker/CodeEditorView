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

    public init(maxFileBytes: Int = 1_048_576, respectGitIgnore: Bool = true) {
        self.maxFileBytes = maxFileBytes
        self.respectGitIgnore = respectGitIgnore
    }

    public func search(
        _ query: SearchQuery,
        context: WorkspaceSearchContext
    ) -> AsyncThrowingStream<SearchEvent, Error> {
        WorkspaceSearchService(context: context, backendOptions: self).search(query)
    }
}
