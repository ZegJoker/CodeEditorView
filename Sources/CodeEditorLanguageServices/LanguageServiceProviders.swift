import Foundation
import CodeEditorCore
import CodeEditorDocuments

/// Base metadata for language service providers.
public protocol LanguageServiceProvider: Sendable {
    var id: ProviderID { get }
    var selector: DocumentSelector { get }
    /// Higher values run first / win single-select policies.
    var priority: Int { get }
}

public extension LanguageServiceProvider {
    var priority: Int { 0 }
}

// MARK: - Requests

public struct CompletionRequest: Sendable {
    public var document: DocumentSnapshot
    public var position: TextPosition
    public var trigger: CompletionTrigger
    public var context: LanguageServiceContext

    public init(
        document: DocumentSnapshot,
        position: TextPosition,
        trigger: CompletionTrigger = .invoked,
        context: LanguageServiceContext = LanguageServiceContext()
    ) {
        self.document = document
        self.position = position
        self.trigger = trigger
        self.context = context
    }
}

public struct PositionRequest: Sendable {
    public var document: DocumentSnapshot
    public var position: TextPosition
    public var context: LanguageServiceContext

    public init(
        document: DocumentSnapshot,
        position: TextPosition,
        context: LanguageServiceContext = LanguageServiceContext()
    ) {
        self.document = document
        self.position = position
        self.context = context
    }
}

public struct RangeRequest: Sendable {
    public var document: DocumentSnapshot
    public var range: CodeEditorCore.TextRange
    public var context: LanguageServiceContext

    public init(
        document: DocumentSnapshot,
        range: CodeEditorCore.TextRange,
        context: LanguageServiceContext = LanguageServiceContext()
    ) {
        self.document = document
        self.range = range
        self.context = context
    }
}

public struct DocumentRequest: Sendable {
    public var document: DocumentSnapshot
    public var context: LanguageServiceContext

    public init(
        document: DocumentSnapshot,
        context: LanguageServiceContext = LanguageServiceContext()
    ) {
        self.document = document
        self.context = context
    }
}

// MARK: - Protocols

public protocol CompletionProvider: LanguageServiceProvider {
    func completions(for request: CompletionRequest) async throws -> CompletionList
}

public protocol HoverProvider: LanguageServiceProvider {
    func hover(for request: PositionRequest) async throws -> Hover?
}

public protocol DefinitionProvider: LanguageServiceProvider {
    func definitions(for request: PositionRequest) async throws -> [LocationLink]
}

public protocol DeclarationProvider: LanguageServiceProvider {
    func declarations(for request: PositionRequest) async throws -> [LocationLink]
}

public protocol ImplementationProvider: LanguageServiceProvider {
    func implementations(for request: PositionRequest) async throws -> [LocationLink]
}

public protocol ReferencesProvider: LanguageServiceProvider {
    func references(
        for request: PositionRequest,
        includeDeclaration: Bool
    ) async throws -> [Location]
}

public protocol DiagnosticsProvider: LanguageServiceProvider {
    func diagnostics(for request: DocumentRequest) async throws -> [LanguageDiagnostic]
}

public protocol DocumentSymbolProvider: LanguageServiceProvider {
    func documentSymbols(for request: DocumentRequest) async throws -> [DocumentSymbol]
}

public protocol WorkspaceSymbolProvider: LanguageServiceProvider {
    func workspaceSymbols(
        query: String,
        context: LanguageServiceContext
    ) async throws -> [WorkspaceSymbol]
}

public protocol FormattingProvider: LanguageServiceProvider {
    func format(
        _ request: DocumentRequest,
        options: FormattingOptions
    ) async throws -> [TextEditPlan]

    func formatRange(
        _ request: RangeRequest,
        options: FormattingOptions
    ) async throws -> [TextEditPlan]
}

public extension FormattingProvider {
    func formatRange(
        _ request: RangeRequest,
        options: FormattingOptions
    ) async throws -> [TextEditPlan] {
        try await format(
            DocumentRequest(document: request.document, context: request.context),
            options: options
        )
    }
}

public protocol RenameProvider: LanguageServiceProvider {
    func rename(
        _ request: PositionRequest,
        newName: String
    ) async throws -> WorkspaceEditPlan
}

public protocol CodeActionProvider: LanguageServiceProvider {
    func codeActions(
        for request: RangeRequest,
        diagnostics: [LanguageDiagnostic]
    ) async throws -> [CodeAction]
}

public protocol SemanticTokensProvider: LanguageServiceProvider {
    func semanticTokens(for request: DocumentRequest) async throws -> [SemanticTokenSpan]
    func semanticTokens(for request: RangeRequest) async throws -> [SemanticTokenSpan]
}

public extension SemanticTokensProvider {
    func semanticTokens(for request: RangeRequest) async throws -> [SemanticTokenSpan] {
        let all = try await semanticTokens(
            for: DocumentRequest(document: request.document, context: request.context)
        )
        return all.filter {
            let r = $0.range
            return r.location < request.range.location + request.range.length
                && r.location + r.length > request.range.location
        }
    }
}

public protocol InlayHintProvider: LanguageServiceProvider {
    func inlayHints(for request: RangeRequest) async throws -> [InlayHint]
}

public protocol FoldingRangeProvider: LanguageServiceProvider {
    func foldingRanges(for request: DocumentRequest) async throws -> [FoldingRange]
}

public protocol SignatureHelpProvider: LanguageServiceProvider {
    func signatureHelp(for request: PositionRequest) async throws -> SignatureHelp?
}

public protocol DocumentLinkProvider: LanguageServiceProvider {
    func documentLinks(for request: DocumentRequest) async throws -> [DocumentLink]
}

public protocol DocumentColorProvider: LanguageServiceProvider {
    func documentColors(for request: DocumentRequest) async throws -> [ColorInformation]
}
