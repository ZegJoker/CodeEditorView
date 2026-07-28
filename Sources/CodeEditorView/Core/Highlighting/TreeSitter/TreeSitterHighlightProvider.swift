import Foundation
import SwiftTreeSitter
import CodeEditorLanguages

/// Tree-sitter based ``HighlightProviding`` implementation with **incremental** edits.
///
/// Language / query loading is performed off the main actor so switching languages does not ANR.
///
/// Edit pipeline (SwiftTreeSitter):
/// 1. Build ``InputEdit`` from the UTF-16 mutation
/// 2. `tree.edit(edit)`
/// 3. Incremental `parser.parse(tree:editedTree, string:newSource)`
/// 4. Invalidate via `changedRanges` (+ the edited span)
@MainActor
public final class TreeSitterHighlightProvider: HighlightProviding {
    private var configuration: LanguageConfiguration?
    private var parser = Parser()
    private var tree: MutableTree?
    /// Last fully applied document text (matches `tree`).
    private var source: String = ""
    /// Text pushed after a document mutation, applied on the next ``applyEdit``.
    private var pendingSource: String?
    private var documentLength: Int = 0
    private var languageID: String?
    /// True after ``willApplyEdit`` until the matching ``applyEdit`` consumes the mutation.
    private var expectsIncrementalEdit = false
    /// Language waiting for async configuration load.
    private var deferredLanguage: CodeLanguage?
    private var loadGeneration: UInt64 = 0
    /// Number of in-flight ``loadAsync`` calls (generation-based cancellation still applies).
    private var loadDepth: Int = 0
    /// Waiters for “no load in flight” (avoids nested MainActor Task self-await freezes).
    private var loadWaiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public init(language: CodeLanguage) {
        deferredLanguage = language
        languageID = language.id.rawValue
    }

    public init(languageID: String) {
        if let language = CodeLanguages.language(id: languageID) {
            deferredLanguage = language
            self.languageID = language.id.rawValue
        } else {
            self.languageID = languageID
        }
    }

    /// Convenience factory; returns `nil` for plain text / unknown languages.
    /// Does **not** compile queries on the calling thread — load happens in ``setUp`` / ``loadAsync``.
    public static func make(for language: CodeLanguage) -> TreeSitterHighlightProvider? {
        guard language.id != .plainText else { return nil }
        return TreeSitterHighlightProvider(language: language)
    }

    /// Async language switch — query compilation runs off the main actor.
    ///
    /// Runs **inline** on the caller’s async context (no nested `Task` + `await value` on MainActor,
    /// which can freeze the UI when many switches queue under SwiftUI updates).
    public func loadAsync(language: CodeLanguage) async {
        loadGeneration &+= 1
        let gen = loadGeneration
        languageID = language.id.rawValue
        deferredLanguage = nil

        loadDepth += 1
        defer {
            loadDepth = max(0, loadDepth - 1)
            if loadDepth == 0 {
                let waiters = loadWaiters
                loadWaiters = []
                for waiter in waiters {
                    waiter.resume()
                }
            }
        }

        await performLoad(language: language, generation: gen)
    }

    /// Suspends until every in-flight ``loadAsync`` finishes (or is superseded and drained).
    private func waitForLoadsToFinish() async {
        if loadDepth == 0 { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            if loadDepth == 0 {
                cont.resume()
            } else {
                loadWaiters.append(cont)
            }
        }
    }

    private func performLoad(language: CodeLanguage, generation gen: UInt64) async {
        let languageCopy = language
        let config: LanguageConfiguration?
        do {
            // Compile queries off the main actor — this is the expensive part.
            config = try await Task.detached(priority: .userInitiated) {
                try CodeLanguages.languageConfiguration(for: languageCopy)
            }.value
        } catch {
            guard gen == loadGeneration else { return }
            configuration = nil
            tree = nil
            source = ""
            return
        }

        guard gen == loadGeneration, !Task.isCancelled else { return }

        configuration = config
        // Drop any tree/source from the previous grammar so a later setDocumentText cannot
        // early-return on `text == source` with a tree built under the wrong language.
        tree = nil
        source = ""
        pendingSource = nil
        expectsIncrementalEdit = false
        documentLength = 0

        if let config {
            do {
                // setLanguage only installs a language pointer — cheap. Query compile already ran off-main.
                try parser.setLanguage(config.language)
            } catch {
                configuration = nil
            }
        }
    }

    public func setUp(documentLength: Int, languageID: String?) async {
        self.documentLength = max(0, documentLength)

        if let deferred = deferredLanguage {
            deferredLanguage = nil
            await loadAsync(language: deferred)
            return
        }

        if let languageID, languageID != self.languageID,
           let language = CodeLanguages.language(id: languageID) {
            await loadAsync(language: language)
        }
    }

    public func willApplyEdit(range: NSRange) {
        expectsIncrementalEdit = true
    }

    /// Pushes document text. When a parse tree already exists and an edit is in flight,
    /// text is held as `pendingSource` for incremental ``applyEdit`` — **not** a full reparse.
    public func setDocumentText(_ text: String) async {
        // Wait for in-flight language load so we never parse with the wrong grammar mid-switch.
        await waitForLoadsToFinish()

        // Finish deferred language load before parsing.
        if let deferred = deferredLanguage {
            deferredLanguage = nil
            await loadAsync(language: deferred)
        }

        // Initial load / full replace with no tree yet.
        if tree == nil {
            source = text
            documentLength = (text as NSString).length
            pendingSource = nil
            expectsIncrementalEdit = false
            if configuration != nil {
                await Task.yield()
                fullParse(text)
            }
            return
        }

        // Wholesale replace (e.g. `text =` assignment) without a tracked edit.
        if !expectsIncrementalEdit {
            if text == source, tree != nil { return }
            source = text
            documentLength = (text as NSString).length
            pendingSource = nil
            await Task.yield()
            fullParse(text)
            return
        }

        // Incremental path: applyEdit will consume this together with InputEdit.
        pendingSource = text
    }

    public func applyEdit(range: NSRange, delta: Int) async throws -> IndexSet {
        try Task.checkCancellation()

        let newText: String
        if let pending = pendingSource {
            newText = pending
            pendingSource = nil
        } else {
            documentLength = max(0, documentLength + delta)
            expectsIncrementalEdit = false
            let start = max(0, range.location)
            let end = min(documentLength, range.location + max(0, range.length + delta))
            return IndexSet(integersIn: start..<max(start, end))
        }

        defer { expectsIncrementalEdit = false }

        guard configuration != nil else {
            source = newText
            documentLength = (newText as NSString).length
            tree = nil
            return IndexSet(integersIn: 0..<max(0, documentLength))
        }

        guard let existingTree = tree else {
            source = newText
            documentLength = (newText as NSString).length
            fullParse(newText)
            return IndexSet(integersIn: 0..<max(0, documentLength))
        }

        let inputEdit = TreeSitterEdit.make(
            range: range,
            delta: delta,
            oldSource: source,
            newSource: newText
        )

        existingTree.edit(inputEdit)

        let oldTree = existingTree
        source = newText
        documentLength = (newText as NSString).length
        let newTree = parser.parse(tree: oldTree, string: newText)
        tree = newTree

        var invalid = IndexSet()
        if let newTree {
            let changed = oldTree.changedRanges(from: newTree)
            invalid.formUnion(TreeSitterEdit.indexSet(from: changed, documentLength: documentLength))
        }

        let editStart = max(0, range.location)
        let editEnd = min(documentLength, range.location + max(0, range.length + delta))
        if editEnd > editStart {
            invalid.insert(integersIn: editStart..<editEnd)
        }

        if let first = invalid.min(), let last = invalid.max() {
            let pad = 64
            let start = max(0, first - pad)
            let end = min(documentLength, last + 1 + pad)
            invalid.insert(integersIn: start..<end)
        }

        if invalid.isEmpty, documentLength > 0 {
            invalid.insert(integersIn: 0..<documentLength)
        }
        return invalid
    }

    public func queryHighlights(in range: NSRange, text: String) async throws -> [HighlightRange] {
        try Task.checkCancellation()
        guard let configuration,
              let highlightsQuery = configuration.queries[.highlights],
              let tree,
              range.length > 0,
              !source.isEmpty else {
            return []
        }

        // Bound work per frame; large ranges are still OK for demos but stay cancellable.
        let cursor = highlightsQuery.execute(in: tree)
        cursor.setRange(range)

        let named = cursor
            .resolve(with: Predicate.Context(string: source))
            .highlights()

        var results: [HighlightRange] = []
        results.reserveCapacity(min(named.count, 256))
        for namedRange in named {
            try Task.checkCancellation()
            let intersection = NSIntersectionRange(namedRange.range, range)
            guard intersection.length > 0 else { continue }
            let capture = CaptureName.from(capture: namedRange.name)
            // Skip only explicit "none" captures (from() returns nil).
            if capture == nil, namedRange.name == "none" || namedRange.name.hasPrefix("none") {
                continue
            }
            results.append(
                HighlightRange(
                    range: intersection,
                    capture: capture,
                    rawCapture: namedRange.name
                )
            )
        }
        return results
    }

    // MARK: - Private

    private func fullParse(_ text: String) {
        guard configuration != nil else {
            tree = nil
            return
        }
        tree = parser.parse(text)
    }
}
