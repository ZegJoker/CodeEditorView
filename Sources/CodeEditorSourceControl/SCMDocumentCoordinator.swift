import CodeEditorDocuments
import CodeEditorWorkspace
import Foundation

/// Coordinates destructive SCM operations with open editor buffers (SCM-N06).
///
/// Fail-closed: discard / checkout / pull / reset must not run while a dirty
/// document covers an affected path. Hosts bind ``DocumentLifecycleCoordinator``.
public struct SCMDocumentCoordinator: Sendable {
    public typealias Check = @Sendable (_ repositoryRoot: URL, _ relativePaths: [String]) async throws -> Void

    private let check: Check

    public init(check: @escaping Check) {
        self.check = check
    }

    /// Assert no dirty open documents intersect `relativePaths` under `repositoryRoot`.
    /// Empty `relativePaths` means whole-repository mutation (checkout/pull/merge).
    public func assertClean(repositoryRoot: URL, relativePaths: [String]) async throws {
        try await check(repositoryRoot, relativePaths)
    }

    /// Bind a MainActor lifecycle registry for dirty-buffer preflight.
    @MainActor
    public static func binding(_ lifecycle: DocumentLifecycleCoordinator) -> SCMDocumentCoordinator {
        SCMDocumentCoordinator { root, relativePaths in
            try await MainActor.run {
                try Self.assertCleanOnMain(lifecycle: lifecycle, root: root, relativePaths: relativePaths)
            }
        }
    }

    @MainActor
    private static func assertCleanOnMain(
        lifecycle: DocumentLifecycleCoordinator,
        root: URL,
        relativePaths: [String]
    ) throws {
        let rootURL = root.resolvingSymlinksInPath().standardizedFileURL
        let rootParts = rootURL.pathComponents
        var dirty: [String] = []
        let pathFilter: Set<String> = Set(relativePaths.map { $0 as String })

        for doc in lifecycle.documents where doc.isDirty {
            guard let fileURL = doc.uri.fileURL?.resolvingSymlinksInPath().standardizedFileURL else {
                continue
            }
            let fullParts = fileURL.pathComponents
            guard fullParts.count >= rootParts.count,
                Array(fullParts.prefix(rootParts.count)) == rootParts
            else {
                continue
            }
            var rel = String(fileURL.path.dropFirst(rootURL.path.count))
            if rel.hasPrefix("/") { rel = String(rel.dropFirst()) }
            if pathFilter.isEmpty || pathFilter.contains(rel) {
                dirty.append(doc.uri.rawValue)
            }
        }
        if !dirty.isEmpty {
            throw SCMError.dirtyDocuments(dirty)
        }
    }
}
