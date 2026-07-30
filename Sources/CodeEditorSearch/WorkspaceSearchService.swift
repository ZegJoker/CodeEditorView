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
        var filesWithMatches = Set<String>()

        // Canonical paths of open docs so disk enumeration does not double-count
        // the same file when DocumentURI string forms differ (e.g. absoluteString).
        var openCanonicalPaths = Set<String>()
        for uri in context.openDocuments.keys {
            if let path = Self.canonicalPath(for: uri) {
                openCanonicalPaths.insert(path)
            }
        }

        // Open documents first (in-memory).
        for (uri, text) in context.openDocuments.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            try Task.checkCancellation()
            let path = Self.canonicalPath(for: uri) ?? uri.rawValue
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
            if !matches.isEmpty {
                filesWithMatches.insert(path)
            }
            for m in matches {
                matchCount += 1
                continuation.yield(.match(m))
                if matchCount >= query.maxResults {
                    continuation.yield(.finished(
                        filesScanned: filesWithMatches.count,
                        matchCount: matchCount
                    ))
                    return
                }
            }
        }

        // Disk roots (skip files already covered via open documents).
        for root in context.rootDirectories {
            try Task.checkCancellation()
            let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            )
            while let item = enumerator?.nextObject() as? URL {
                try Task.checkCancellation()
                let path = item.standardizedFileURL.path
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

                if openCanonicalPaths.contains(path) { continue } // already searched in-memory

                let uri = DocumentURI(fileURL: item.standardizedFileURL)
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
                if !matches.isEmpty {
                    filesWithMatches.insert(path)
                }
                for m in matches {
                    matchCount += 1
                    continuation.yield(.match(m))
                    if matchCount >= query.maxResults {
                        continuation.yield(.finished(
                            filesScanned: filesWithMatches.count,
                            matchCount: matchCount
                        ))
                        return
                    }
                }
            }
        }

        // `filesScanned` in finished = unique files that produced matches (Xcode-style summary).
        continuation.yield(.finished(filesScanned: filesWithMatches.count, matchCount: matchCount))
    }

    /// Normalized filesystem path for open-document / disk de-duplication.
    static func canonicalPath(for uri: DocumentURI) -> String? {
        guard let url = uri.fileURL else { return nil }
        return url.standardizedFileURL.path
    }

    static func makeRegex(_ query: SearchQuery) throws -> NSRegularExpression {
        let mode = query.matchMode
        var pattern = query.pattern
        if mode != .regularExpression {
            pattern = NSRegularExpression.escapedPattern(for: pattern)
        }
        switch mode {
        case .contains:
            break
        case .matchesWord:
            pattern = "\\b(?:\(pattern))\\b"
        case .startsWith:
            // Start of line (Xcode-style “Starts With” in file search).
            pattern = "^(?:\(pattern))"
        case .endsWith:
            pattern = "(?:\(pattern))$"
        case .regularExpression:
            // Whole-word can combine with regex (wrap user pattern).
            if query.wholeWord {
                pattern = "\\b(?:\(pattern))\\b"
            }
        }

        var options: NSRegularExpression.Options = []
        if !query.caseSensitive {
            options.insert(.caseInsensitive)
        }
        if mode == .startsWith || mode == .endsWith {
            options.insert(.anchorsMatchLines)
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
