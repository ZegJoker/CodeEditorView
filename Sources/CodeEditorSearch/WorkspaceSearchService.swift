import Foundation
import CodeEditorCore
import CodeEditorDocuments

public actor WorkspaceSearchService {
    private let context: WorkspaceSearchContext

    public init(context: WorkspaceSearchContext) {
        self.context = context
    }

    public func search(_ query: SearchQuery) -> AsyncThrowingStream<SearchEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.runSearch(query, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func runSearch(
        _ query: SearchQuery,
        continuation: AsyncThrowingStream<SearchEvent, Error>.Continuation
    ) async throws {
        let pattern = query.pattern
        guard !pattern.isEmpty else { throw SearchError.emptyPattern }

        let regex: NSRegularExpression
        do {
            regex = try Self.makeRegex(query)
        } catch {
            throw SearchError.invalidRegex(String(describing: error))
        }

        var filesScanned = 0
        var matchCount = 0

        // Open documents first (in-memory).
        for (uri, text) in context.openDocuments.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            try Task.checkCancellation()
            let path = uri.fileURL?.path ?? uri.rawValue
            if SearchPathMatching.isExcluded(path: path, excludes: query.excludeGlobs) { continue }
            if !SearchPathMatching.isIncluded(path: path, includes: query.includeGlobs) { continue }

            filesScanned += 1
            continuation.yield(.progress(SearchProgress(
                filesScanned: filesScanned,
                matchesFound: matchCount,
                currentPath: path
            )))

            let matches = Self.findMatches(
                in: text,
                uri: uri,
                regex: regex,
                fromOpen: true
            )
            for m in matches {
                matchCount += 1
                continuation.yield(.match(m))
                if matchCount >= query.maxResults {
                    continuation.yield(.finished(filesScanned: filesScanned, matchCount: matchCount))
                    return
                }
            }
        }

        // Disk roots
        let openURIs = Set(context.openDocuments.keys)
        for root in context.rootDirectories {
            try Task.checkCancellation()
            let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            )
            while let item = enumerator?.nextObject() as? URL {
                try Task.checkCancellation()
                let path = item.path
                if SearchPathMatching.isExcluded(path: path, excludes: query.excludeGlobs) {
                    enumerator?.skipDescendants()
                    continue
                }
                // Also skip named components quickly
                if path.contains("/.git/") || path.contains("/.build/") {
                    enumerator?.skipDescendants()
                    continue
                }
                guard SearchPathMatching.isIncluded(path: path, includes: query.includeGlobs) else {
                    continue
                }
                let values = try? item.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard values?.isRegularFile == true else { continue }
                if let size = values?.fileSize, size > query.maxFileBytes { continue }

                let uri = DocumentURI(fileURL: item)
                if openURIs.contains(uri) { continue } // already searched in-memory

                guard let data = try? Data(contentsOf: item) else { continue }
                if data.count > query.maxFileBytes { continue }
                if SearchPathMatching.isBinary(data) { continue }
                guard let text = String(data: data, encoding: .utf8) else { continue }

                filesScanned += 1
                if filesScanned % 25 == 0 {
                    continuation.yield(.progress(SearchProgress(
                        filesScanned: filesScanned,
                        matchesFound: matchCount,
                        currentPath: path
                    )))
                }

                let matches = Self.findMatches(
                    in: text,
                    uri: uri,
                    regex: regex,
                    fromOpen: false
                )
                for m in matches {
                    matchCount += 1
                    continuation.yield(.match(m))
                    if matchCount >= query.maxResults {
                        continuation.yield(.finished(filesScanned: filesScanned, matchCount: matchCount))
                        return
                    }
                }
            }
        }

        continuation.yield(.finished(filesScanned: filesScanned, matchCount: matchCount))
    }

    static func makeRegex(_ query: SearchQuery) throws -> NSRegularExpression {
        var pattern = query.pattern
        if !query.isRegex {
            pattern = NSRegularExpression.escapedPattern(for: pattern)
        }
        if query.wholeWord {
            pattern = "\\b(?:\(pattern))\\b"
        }
        var options: NSRegularExpression.Options = []
        if !query.caseSensitive {
            options.insert(.caseInsensitive)
        }
        return try NSRegularExpression(pattern: pattern, options: options)
    }

    static func findMatches(
        in text: String,
        uri: DocumentURI,
        regex: NSRegularExpression,
        fromOpen: Bool
    ) -> [SearchMatch] {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        let results = regex.matches(in: text, options: [], range: full)
        return results.map { result in
            let range = result.range
            let lc = SearchTextGeometry.lineColumn(utf16Offset: range.location, in: text)
            let preview = SearchTextGeometry.linePreview(utf16Offset: range.location, in: text)
            return SearchMatch(
                uri: uri,
                range: CodeEditorCore.TextRange(location: range.location, length: range.length),
                line: lc.line,
                column: lc.column,
                preview: preview,
                fromOpenDocument: fromOpen
            )
        }
    }
}
