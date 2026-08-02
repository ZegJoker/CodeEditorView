import CodeEditorCore
import CodeEditorDocuments
import Foundation

/// Workspace text search with bounded workers, encoding-aware decoding, and precise metrics
/// (SRCH-N04…SRCH-N07).
public actor WorkspaceSearchService {
    private let context: WorkspaceSearchContext
    private let options: NativeSearchBackend

    public init(context: WorkspaceSearchContext, backendOptions: NativeSearchBackend = NativeSearchBackend()) {
        self.context = context
        self.options = backendOptions
    }

    /// Independent stream per call (SRCH-N04): each subscription runs its own search task.
    nonisolated public func search(_ query: SearchQuery) -> AsyncThrowingStream<SearchEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.runSearch(query, continuation: continuation)
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: SearchError.cancelled)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Pipeline

    private struct FileWork: Sendable {
        var path: String
        var uri: DocumentURI
        var text: String?
        var fromOpen: Bool
        var data: Data?
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

        let maxBytes = min(query.maxFileBytes, options.maxFileBytes)
        let deadline: ContinuousClock.Instant? = query.timeBudgetNanoseconds.map {
            ContinuousClock.now + .nanoseconds(Int64(clamping: $0))
        }

        var metrics = SearchCompletionMetrics()
        var matchCount = 0
        var filesWithMatches = Set<String>()
        var openCanonicalPaths = Set<String>()
        for uri in context.openDocuments.keys {
            if let path = Self.canonicalPath(for: uri) {
                openCanonicalPaths.insert(path)
            }
        }

        // ---- Open documents first (in-memory / dirty). ----
        for (uri, text) in context.openDocuments.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            try Task.checkCancellation()
            try Self.checkDeadline(deadline)
            let path = Self.canonicalPath(for: uri) ?? uri.rawValue
            metrics.discovered += 1

            if SearchPathMatching.isExcluded(path: path, excludes: query.excludeGlobs) {
                metrics.skipped += 1
                continuation.yield(.skipped(SearchSkip(path: path, reason: .excluded)))
                continue
            }
            if !SearchPathMatching.isIncluded(path: path, includes: query.includeGlobs) {
                continue
            }
            metrics.eligible += 1

            let utf16Len = (text as NSString).length
            // Approximate open-doc size as UTF-16 units * 2 for budget.
            if utf16Len * 2 > maxBytes {
                metrics.skipped += 1
                continuation.yield(.skipped(SearchSkip(path: path, reason: .tooLarge)))
                continue
            }

            metrics.opened += 1
            metrics.decoded += 1
            metrics.scanned += 1
            continuation.yield(
                .progress(
                    SearchProgress(
                        filesScanned: metrics.scanned,
                        matchesFound: matchCount,
                        currentPath: path
                    )
                )
            )

            let (matches, limited) = Self.findMatchesBounded(
                in: text,
                uri: uri,
                regex: regex,
                fromOpen: true,
                maxMatches: options.maxMatchesPerFile,
                perFileBudget: options.perFileTimeBudgetNanoseconds
            )
            if limited {
                metrics.skipped += 1
                continuation.yield(
                    .skipped(
                        SearchSkip(
                            path: path,
                            reason: matches.count >= options.maxMatchesPerFile
                                ? .matchLimitExceeded : .regexBudgetExceeded
                        )
                    )
                )
            }
            if !matches.isEmpty {
                filesWithMatches.insert(path)
                metrics.matched = filesWithMatches.count
            }
            for m in matches {
                matchCount += 1
                metrics.matchCount = matchCount
                continuation.yield(.match(m))
                if matchCount >= query.maxResults {
                    continuation.yield(.finished(metrics))
                    return
                }
            }
        }

        // ---- Disk roots: discover + bounded workers (SRCH-N04). ----
        for root in context.rootDirectories {
            try Task.checkCancellation()
            try Self.checkDeadline(deadline)

            let ignore = options.respectGitIgnore ? GitIgnoreLoader.load(root: root) : GitIgnoreRules()
            var pending: [FileWork] = []

            // Discovery uses skipsHiddenFiles for normal content walk; gitignore load already
            // discovered nested ignores without that flag (SRCH-N01).
            let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            )

            while let item = enumerator?.nextObject() as? URL {
                try Task.checkCancellation()
                try Self.checkDeadline(deadline)

                let path = item.standardizedFileURL.path
                let relative = String(path.dropFirst(root.standardizedFileURL.path.count))
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                let values = try? item.resourceValues(forKeys: [
                    .isRegularFileKey, .fileSizeKey, .isDirectoryKey,
                ])
                let isDir = values?.isDirectory == true
                metrics.discovered += 1

                if ignore.isIgnored(relativePath: relative, isDirectory: isDir) {
                    if isDir { enumerator?.skipDescendants() }
                    metrics.skipped += 1
                    if !isDir {
                        continuation.yield(.skipped(SearchSkip(path: path, reason: .ignored)))
                    }
                    continue
                }
                if SearchPathMatching.isExcluded(path: path, excludes: query.excludeGlobs)
                    || SearchPathMatching.isExcluded(path: relative, excludes: query.excludeGlobs)
                {
                    if isDir { enumerator?.skipDescendants() }
                    metrics.skipped += 1
                    continue
                }
                if path.contains("/.git/") || path.contains("/.build/") {
                    if isDir { enumerator?.skipDescendants() }
                    continue
                }
                guard !isDir else { continue }
                let included =
                    query.includeGlobs.isEmpty
                    || SearchPathMatching.isIncluded(path: path, includes: query.includeGlobs)
                    || SearchPathMatching.isIncluded(path: relative, includes: query.includeGlobs)
                guard included else { continue }
                guard values?.isRegularFile == true else { continue }
                if let size = values?.fileSize, size > maxBytes {
                    metrics.skipped += 1
                    continuation.yield(.skipped(SearchSkip(path: path, reason: .tooLarge)))
                    continue
                }
                if openCanonicalPaths.contains(path) { continue }

                metrics.eligible += 1
                pending.append(
                    FileWork(
                        path: path,
                        uri: DocumentURI(fileURL: item.standardizedFileURL),
                        text: nil,
                        fromOpen: false,
                        data: nil
                    )
                )

                if pending.count >= options.maxConcurrentWorkers {
                    try await processBatch(
                        pending,
                        regex: regex,
                        maxBytes: maxBytes,
                        query: query,
                        metrics: &metrics,
                        matchCount: &matchCount,
                        filesWithMatches: &filesWithMatches,
                        continuation: continuation,
                        deadline: deadline
                    )
                    pending.removeAll(keepingCapacity: true)
                    if matchCount >= query.maxResults {
                        continuation.yield(.finished(metrics))
                        return
                    }
                }
            }

            if !pending.isEmpty {
                try await processBatch(
                    pending,
                    regex: regex,
                    maxBytes: maxBytes,
                    query: query,
                    metrics: &metrics,
                    matchCount: &matchCount,
                    filesWithMatches: &filesWithMatches,
                    continuation: continuation,
                    deadline: deadline
                )
                if matchCount >= query.maxResults {
                    continuation.yield(.finished(metrics))
                    return
                }
            }
        }

        continuation.yield(.finished(metrics))
    }

    private func processBatch(
        _ batch: [FileWork],
        regex: NSRegularExpression,
        maxBytes: Int,
        query: SearchQuery,
        metrics: inout SearchCompletionMetrics,
        matchCount: inout Int,
        filesWithMatches: inout Set<String>,
        continuation: AsyncThrowingStream<SearchEvent, Error>.Continuation,
        deadline: ContinuousClock.Instant?
    ) async throws {
        try Task.checkCancellation()
        try Self.checkDeadline(deadline)

        // Read + decode off the actor in parallel (bounded by batch size).
        let maxMatchesPerFile = options.maxMatchesPerFile
        let perFileBudget = options.perFileTimeBudgetNanoseconds
        let results: [FileScanResult] = await withTaskGroup(of: FileScanResult.self) { group in
            for work in batch {
                group.addTask {
                    Self.scanFile(
                        work,
                        regex: regex,
                        maxBytes: maxBytes,
                        maxMatchesPerFile: maxMatchesPerFile,
                        perFileBudget: perFileBudget
                    )
                }
            }
            var collected: [FileScanResult] = []
            for await r in group {
                collected.append(r)
            }
            // Stable order by path for deterministic aggregation (SRCH-N04).
            return collected.sorted { $0.path < $1.path }
        }

        for r in results {
            try Task.checkCancellation()
            try Self.checkDeadline(deadline)
            if let skip = r.skip {
                metrics.skipped += 1
                if skip.reason == .openFailed || skip.reason == .encodingFailed {
                    metrics.failed += 1
                }
                continuation.yield(.skipped(skip))
                continue
            }
            metrics.opened += 1
            if r.decoded { metrics.decoded += 1 }
            metrics.scanned += 1
            if metrics.scanned % 25 == 0 || matchCount == 0 {
                continuation.yield(
                    .progress(
                        SearchProgress(
                            filesScanned: metrics.scanned,
                            matchesFound: matchCount,
                            currentPath: r.path
                        )
                    )
                )
            }
            if r.limited {
                metrics.skipped += 1
                continuation.yield(
                    .skipped(
                        SearchSkip(
                            path: r.path,
                            reason: r.matches.count >= maxMatchesPerFile
                                ? .matchLimitExceeded : .regexBudgetExceeded
                        )
                    )
                )
            }
            if !r.matches.isEmpty {
                filesWithMatches.insert(r.path)
                metrics.matched = filesWithMatches.count
            }
            for m in r.matches {
                matchCount += 1
                metrics.matchCount = matchCount
                continuation.yield(.match(m))
                if matchCount >= query.maxResults { return }
            }
        }
    }

    private struct FileScanResult: Sendable {
        var path: String
        var matches: [SearchMatch]
        var skip: SearchSkip?
        var decoded: Bool
        var limited: Bool
    }

    nonisolated private static func scanFile(
        _ work: FileWork,
        regex: NSRegularExpression,
        maxBytes: Int,
        maxMatchesPerFile: Int,
        perFileBudget: UInt64
    ) -> FileScanResult {
        if Task.isCancelled {
            return FileScanResult(
                path: work.path,
                matches: [],
                skip: SearchSkip(path: work.path, reason: .cancelled),
                decoded: false,
                limited: false
            )
        }
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: work.path))
        } catch {
            return FileScanResult(
                path: work.path,
                matches: [],
                skip: SearchSkip(path: work.path, reason: .openFailed, detail: String(describing: error)),
                decoded: false,
                limited: false
            )
        }
        if data.count > maxBytes {
            return FileScanResult(
                path: work.path,
                matches: [],
                skip: SearchSkip(path: work.path, reason: .tooLarge),
                decoded: false,
                limited: false
            )
        }

        // SRCH-N05: DocumentCodec first (UTF-16 BOM has NUL bytes that look "binary").
        let text: String
        do {
            let decoded = try DocumentCodec.decode(data)
            text = decoded.text
        } catch let err as DocumentIOError {
            // Only classify as binary after codec reject — UTF-16 is never silent-dropped.
            if SearchPathMatching.isBinary(data) {
                return FileScanResult(
                    path: work.path,
                    matches: [],
                    skip: SearchSkip(path: work.path, reason: .binary),
                    decoded: false,
                    limited: false
                )
            }
            let reason: SearchSkipReason
            switch err {
            case .unsupportedEncoding:
                reason = .unsupportedEncoding
            case .encodingFailed:
                reason = .encodingFailed
            default:
                reason = .encodingFailed
            }
            return FileScanResult(
                path: work.path,
                matches: [],
                skip: SearchSkip(path: work.path, reason: reason, detail: String(describing: err)),
                decoded: false,
                limited: false
            )
        } catch {
            if SearchPathMatching.isBinary(data) {
                return FileScanResult(
                    path: work.path,
                    matches: [],
                    skip: SearchSkip(path: work.path, reason: .binary),
                    decoded: false,
                    limited: false
                )
            }
            return FileScanResult(
                path: work.path,
                matches: [],
                skip: SearchSkip(path: work.path, reason: .encodingFailed, detail: String(describing: error)),
                decoded: false,
                limited: false
            )
        }

        let (matches, limited) = findMatchesBounded(
            in: text,
            uri: work.uri,
            regex: regex,
            fromOpen: work.fromOpen,
            maxMatches: maxMatchesPerFile,
            perFileBudget: perFileBudget
        )
        return FileScanResult(
            path: work.path,
            matches: matches,
            skip: nil,
            decoded: true,
            limited: limited
        )
    }

    // MARK: - Matching

    nonisolated static func makeRegex(_ query: SearchQuery) throws -> NSRegularExpression {
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
            pattern = "^(?:\(pattern))"
        case .endsWith:
            pattern = "(?:\(pattern))$"
        case .regularExpression:
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

    /// Bounded match enumeration with zero-width progress and per-file caps (SRCH-N06).
    nonisolated static func findMatchesBounded(
        in text: String,
        uri: DocumentURI,
        regex: NSRegularExpression,
        fromOpen: Bool,
        maxMatches: Int,
        perFileBudget: UInt64
    ) -> (matches: [SearchMatch], limited: Bool) {
        let ns = text as NSString
        let fullLen = ns.length
        var matches: [SearchMatch] = []
        var limited = false
        let start = ContinuousClock.now
        var location = 0

        while location <= fullLen {
            if Task.isCancelled { break }
            if perFileBudget > 0 {
                let elapsed = ContinuousClock.now - start
                if elapsed >= .nanoseconds(Int64(clamping: perFileBudget)) {
                    limited = true
                    break
                }
            }
            let searchRange = NSRange(location: location, length: fullLen - location)
            guard let result = regex.firstMatch(in: text, options: [], range: searchRange) else {
                break
            }
            let range = result.range
            if range.location == NSNotFound { break }

            let lc = SearchTextGeometry.lineColumn(utf16Offset: range.location, in: text)
            let preview = SearchTextGeometry.linePreview(utf16Offset: range.location, in: text)
            matches.append(
                SearchMatch(
                    uri: uri,
                    range: CodeEditorCore.TextRange(location: range.location, length: range.length),
                    line: lc.line,
                    column: lc.column,
                    preview: preview,
                    fromOpenDocument: fromOpen
                )
            )
            if matches.count >= maxMatches {
                limited = true
                break
            }

            // Zero-width progress: always advance at least one UTF-16 unit.
            if range.length == 0 {
                location = range.location + 1
            } else {
                location = range.location + range.length
            }
            if location > fullLen { break }
        }
        return (matches, limited)
    }

    nonisolated static func findMatches(
        in text: String,
        uri: DocumentURI,
        regex: NSRegularExpression,
        fromOpen: Bool
    ) -> [SearchMatch] {
        findMatchesBounded(
            in: text,
            uri: uri,
            regex: regex,
            fromOpen: fromOpen,
            maxMatches: Int.max,
            perFileBudget: 0
        ).matches
    }

    /// Normalized filesystem path for open-document / disk de-duplication.
    nonisolated static func canonicalPath(for uri: DocumentURI) -> String? {
        guard let url = uri.fileURL else { return nil }
        return url.standardizedFileURL.path
    }

    nonisolated private static func checkDeadline(_ deadline: ContinuousClock.Instant?) throws {
        guard let deadline else { return }
        if ContinuousClock.now >= deadline {
            throw SearchError.timeBudgetExceeded
        }
    }
}
