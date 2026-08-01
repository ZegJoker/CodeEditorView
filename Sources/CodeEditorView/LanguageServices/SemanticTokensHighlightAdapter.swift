import CodeEditorCore
import CodeEditorDocuments
import CodeEditorLanguageServices
import CodeEditorLanguageSupport
import Foundation

/// Caches semantic token spans from a language-service host and exposes them as ``HighlightProviding``.
@MainActor
public final class SemanticTokensHighlightAdapter: HighlightProviding {
    public let host: LanguageServiceHost
    public var context: LanguageServiceContext

    private var documentText: String = ""
    private var tokens: [SemanticTokenSpan] = []
    private var languageID: String?

    public init(
        host: LanguageServiceHost,
        context: LanguageServiceContext = LanguageServiceContext()
    ) {
        self.host = host
        self.context = context
    }

    public func setUp(documentLength: Int, languageID: String?) async {
        _ = documentLength
        self.languageID = languageID
        if context.languageID == nil {
            context.languageID = languageID
        }
    }

    public func setDocumentText(_ text: String) async {
        documentText = text
        await refreshTokens()
    }

    public func applyEdit(range: NSRange, delta: Int) async throws -> IndexSet {
        // Rebuild whole-document tokens after edit (Phase 8; incremental later with LSP).
        _ = range
        _ = delta
        await refreshTokens()
        return IndexSet(integersIn: 0..<(documentText as NSString).length)
    }

    public func queryHighlights(in range: NSRange, text: String) async throws -> [HighlightRange] {
        _ = text
        let end = range.location + range.length
        return tokens.compactMap { span in
            let r = span.range.nsRange
            let spanEnd = r.location + r.length
            guard r.location < end, spanEnd > range.location else { return nil }
            return HighlightRange(
                range: r,
                capture: span.capture,
                rawCapture: span.rawType
            )
        }
    }

    /// Force refresh from the host using the current document text.
    public func refreshTokens() async {
        let snapshot = DocumentSnapshot(version: .zero, text: documentText)
        var ctx = context
        if ctx.languageID == nil { ctx.languageID = languageID }
        let request = DocumentRequest(document: snapshot, context: ctx)
        do {
            tokens = try await host.semanticTokens(for: request) { .zero }
        } catch {
            tokens = []
        }
    }

    /// Replace tokens without contacting the host (tests / offline injection).
    public func setTokens(_ tokens: [SemanticTokenSpan]) {
        self.tokens = tokens
    }
}
