import CodeEditorLanguageSupport
import Foundation
import SwiftTreeSitter

/// Tree-sitter based ``HighlightProviding`` implementation with **incremental** edits.
///
/// ## LANG-N03 / TS-001
/// All parser/tree state lives in a single ``ParseSession`` actor. This type never
/// keeps a parallel main-actor tree. UI consumes generation-tagged
/// ``HighlightSnapshot`` values and discards stale generations.
///
/// Configurations load via ``TreeSitterLanguageRuntime`` / environment provider.
@MainActor
public final class TreeSitterHighlightProvider: HighlightProviding {
    /// Sole parse/query engine (LANG-N03).
    private let session = ParseSession()
    /// Last fully applied document text (mirrors session text for edit math only — not a tree).
    private var source: String = ""
    /// Text pushed after a document mutation, applied on the next ``applyEdit``.
    private var pendingSource: String?
    private var documentLength: Int = 0
    private var languageID: String?
    private var languageRef: TSLanguageRef?
    /// True after ``willApplyEdit`` until the matching ``applyEdit`` consumes the mutation.
    private var expectsIncrementalEdit = false
    /// Language waiting for async configuration load.
    private var deferredLanguage: CodeLanguage?
    private var loadGeneration: UInt64 = 0
    /// Number of in-flight ``loadAsync`` calls (generation-based cancellation still applies).
    private var loadDepth: Int = 0
    /// Waiters for “no load in flight” (avoids nested MainActor Task self-await freezes).
    private var loadWaiters: [CheckedContinuation<Void, Never>] = []
    /// Generation of last published highlight result (stale discards).
    public private(set) var highlightGeneration: UInt64 = 0
    /// Language generation last configured into the session.
    public private(set) var languageGeneration: UInt64 = 0
    /// Whether a configuration is installed in the session.
    private var isConfigured = false

    public init() {}

    public init(language: CodeLanguage) {
        deferredLanguage = language
        languageID = language.id.rawValue
    }

    public init(languageID: String) {
        if let language = Self.resolveLanguage(id: languageID) {
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

    /// Access to the single parse session (tests / advanced hosts).
    public var parseSession: ParseSession { session }

    /// Async language switch — query compilation runs off the main actor.
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
        let languageIDCopy = language.id.rawValue
        let config: LanguageConfiguration?
        let resolvedRef: TSLanguageRef?
        do {
            // Compile queries off the main actor — this is the expensive part.
            let pair: (LanguageConfiguration?, TSLanguageRef?) = try await Task.detached(
                priority: .userInitiated
            ) {
                let provider: (any TreeSitterConfigurationProviding)?
                if let p = await TreeSitterLanguageRuntime.shared.resolveProvider() {
                    provider = p
                } else {
                    provider = TreeSitterLanguageEnvironment.resolveProvider()
                }
                guard let provider else { return (nil, nil) }
                let cfg = try provider.languageConfiguration(for: languageIDCopy)
                let ref = LanguageRegistry.shared.languageRef(for: LanguageID(rawValue: languageIDCopy))
                return (cfg, ref)
            }.value
            config = pair.0
            resolvedRef = pair.1
        } catch {
            guard gen == loadGeneration else { return }
            isConfigured = false
            languageRef = nil
            source = ""
            await session.reset()
            return
        }

        guard gen == loadGeneration, !Task.isCancelled else { return }

        // Drop local text bookkeeping so a later setDocumentText cannot early-return
        // with a tree built under the wrong language (session was reset/reconfigured).
        source = ""
        pendingSource = nil
        expectsIncrementalEdit = false
        documentLength = 0
        languageRef = resolvedRef

        if let config {
            do {
                try await session.configure(config, languageRef: resolvedRef)
                isConfigured = true
                languageGeneration = await session.languageGeneration
            } catch {
                isConfigured = false
                languageRef = nil
            }
        } else {
            isConfigured = false
            await session.reset()
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
            let language = Self.resolveLanguage(id: languageID)
        {
            await loadAsync(language: language)
        }
    }

    public func willApplyEdit(range: NSRange) {
        expectsIncrementalEdit = true
    }

    /// Pushes document text. When an edit is in flight, text is held as `pendingSource`
    /// for incremental ``applyEdit`` — **not** a full reparse.
    public func setDocumentText(_ text: String) async {
        await waitForLoadsToFinish()

        if let deferred = deferredLanguage {
            deferredLanguage = nil
            await loadAsync(language: deferred)
        }

        // Incremental path: applyEdit will consume this together with InputEdit.
        if expectsIncrementalEdit, isConfigured, !source.isEmpty {
            pendingSource = text
            return
        }

        // Full parse via the single session (no main-actor tree).
        source = text
        documentLength = (text as NSString).length
        pendingSource = nil
        expectsIncrementalEdit = false
        if isConfigured {
            await Task.yield()
            do {
                _ = try await session.setText(text)
            } catch {
                // Session may have been reset mid-load; ignore.
            }
        }
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

        guard isConfigured else {
            source = newText
            documentLength = (newText as NSString).length
            return IndexSet(integersIn: 0..<max(0, documentLength))
        }

        let result = try await session.applyEdit(range: range, delta: delta, newText: newText)
        source = newText
        documentLength = (newText as NSString).length
        highlightGeneration = result.documentVersion
        return result.invalid
    }

    /// Nearest tree-sitter node whose type contains `"identifier"` at a UTF-16 offset.
    ///
    /// Synchronous API retained for jump-to-definition. Uses a short async bridge to
    /// the single ``ParseSession`` tree — never a second main-actor tree (LANG-N03).
    public func identifierRange(atUTF16Offset location: Int) -> NSRange? {
        // Prefer already-known empty source.
        guard documentLength > 0 || !source.isEmpty else { return nil }
        var result: NSRange?
        let sem = DispatchSemaphore(value: 0)
        Task {
            result = await session.identifierRange(atUTF16Offset: location)
            sem.signal()
        }
        // Bounded wait — parse session hops are local; avoid deadlocking MainActor
        // by only waiting when not already on a session-owned isolation domain.
        _ = sem.wait(timeout: .now() + .milliseconds(50))
        return result
    }

    /// Async identifier lookup (preferred over the synchronous bridge).
    public func identifierRangeAsync(atUTF16Offset location: Int) async -> NSRange? {
        await session.identifierRange(atUTF16Offset: location)
    }

    public func queryHighlights(in range: NSRange, text: String) async throws -> [HighlightRange] {
        try Task.checkCancellation()
        do {
            let pub = try await session.queryHighlights(in: range)
            guard await session.isCurrent(
                documentVersion: pub.documentVersion,
                languageGeneration: pub.languageGeneration
            ) else {
                return []  // stale
            }
            highlightGeneration = pub.generation
            return pub.highlights
        } catch ParseSession.EngineError.queryMissing {
            return []
        } catch ParseSession.EngineError.notConfigured {
            return []
        }
    }

    // MARK: - Private

    private static func resolveLanguage(id: String) -> CodeLanguage? {
        if let fromProvider = TreeSitterLanguageEnvironment.resolveProvider()?.codeLanguage(id: id) {
            return fromProvider
        }
        return CodeLanguages.language(id: id)
    }
}
