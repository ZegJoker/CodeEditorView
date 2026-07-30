import Foundation
import CodeEditorCore
import CodeEditorDocuments
import CodeEditorLanguageSupport

/// Deterministic multi-capability mock for tests (no LSP).
///
/// Register the same instance for every protocol it conforms to, or call
/// ``register(in:)`` to attach all capabilities at once.
public struct MockLanguageSuite: Sendable {
    public var id: ProviderID
    public var selector: DocumentSelector
    public var priority: Int

    public var completionItems: [CompletionItem]
    public var hover: Hover?
    public var definitions: [LocationLink]
    public var declarations: [LocationLink]
    public var implementations: [LocationLink]
    public var references: [Location]
    public var diagnostics: [LanguageDiagnostic]
    public var documentSymbols: [DocumentSymbol]
    public var workspaceSymbols: [WorkspaceSymbol]
    public var formatEdits: [TextEditPlan]
    public var renamePlan: WorkspaceEditPlan
    public var codeActions: [CodeAction]
    public var semanticTokens: [SemanticTokenSpan]
    public var inlayHints: [InlayHint]
    public var foldingRanges: [FoldingRange]
    public var signatureHelp: SignatureHelp?
    public var documentLinks: [DocumentLink]
    public var documentColors: [ColorInformation]

    /// Artificial delay before each response (for stale-version tests).
    public var delayNanoseconds: UInt64
    /// When non-nil, every capability throws this error.
    public var failure: LanguageServiceError?

    public init(
        id: ProviderID = "mock",
        selector: DocumentSelector = .any,
        priority: Int = 0,
        completionItems: [CompletionItem] = [],
        hover: Hover? = nil,
        definitions: [LocationLink] = [],
        declarations: [LocationLink] = [],
        implementations: [LocationLink] = [],
        references: [Location] = [],
        diagnostics: [LanguageDiagnostic] = [],
        documentSymbols: [DocumentSymbol] = [],
        workspaceSymbols: [WorkspaceSymbol] = [],
        formatEdits: [TextEditPlan] = [],
        renamePlan: WorkspaceEditPlan = WorkspaceEditPlan(),
        codeActions: [CodeAction] = [],
        semanticTokens: [SemanticTokenSpan] = [],
        inlayHints: [InlayHint] = [],
        foldingRanges: [FoldingRange] = [],
        signatureHelp: SignatureHelp? = nil,
        documentLinks: [DocumentLink] = [],
        documentColors: [ColorInformation] = [],
        delayNanoseconds: UInt64 = 0,
        failure: LanguageServiceError? = nil
    ) {
        self.id = id
        self.selector = selector
        self.priority = priority
        self.completionItems = completionItems
        self.hover = hover
        self.definitions = definitions
        self.declarations = declarations
        self.implementations = implementations
        self.references = references
        self.diagnostics = diagnostics
        self.documentSymbols = documentSymbols
        self.workspaceSymbols = workspaceSymbols
        self.formatEdits = formatEdits
        self.renamePlan = renamePlan
        self.codeActions = codeActions
        self.semanticTokens = semanticTokens
        self.inlayHints = inlayHints
        self.foldingRanges = foldingRanges
        self.signatureHelp = signatureHelp
        self.documentLinks = documentLinks
        self.documentColors = documentColors
        self.delayNanoseconds = delayNanoseconds
        self.failure = failure
    }

    /// Registers this suite for every capability protocol.
    public func register(in registry: LanguageServiceRegistry) async {
        await registry.register(self as any CompletionProvider)
        await registry.register(self as any HoverProvider)
        await registry.register(self as any DefinitionProvider)
        await registry.register(self as any DeclarationProvider)
        await registry.register(self as any ImplementationProvider)
        await registry.register(self as any ReferencesProvider)
        await registry.register(self as any DiagnosticsProvider)
        await registry.register(self as any DocumentSymbolProvider)
        await registry.register(self as any WorkspaceSymbolProvider)
        await registry.register(self as any FormattingProvider)
        await registry.register(self as any RenameProvider)
        await registry.register(self as any CodeActionProvider)
        await registry.register(self as any SemanticTokensProvider)
        await registry.register(self as any InlayHintProvider)
        await registry.register(self as any FoldingRangeProvider)
        await registry.register(self as any SignatureHelpProvider)
        await registry.register(self as any DocumentLinkProvider)
        await registry.register(self as any DocumentColorProvider)
    }

    private func gate() async throws {
        if delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: delayNanoseconds)
        }
        try Task.checkCancellation()
        if let failure {
            throw failure
        }
    }
}

// MARK: - Capability conformance

extension MockLanguageSuite: CompletionProvider {
    public func completions(for request: CompletionRequest) async throws -> CompletionList {
        try await gate()
        _ = request
        return CompletionList(items: completionItems)
    }
}

extension MockLanguageSuite: HoverProvider {
    public func hover(for request: PositionRequest) async throws -> Hover? {
        try await gate()
        _ = request
        return hover
    }
}

extension MockLanguageSuite: DefinitionProvider {
    public func definitions(for request: PositionRequest) async throws -> [LocationLink] {
        try await gate()
        _ = request
        return definitions
    }
}

extension MockLanguageSuite: DeclarationProvider {
    public func declarations(for request: PositionRequest) async throws -> [LocationLink] {
        try await gate()
        _ = request
        return declarations
    }
}

extension MockLanguageSuite: ImplementationProvider {
    public func implementations(for request: PositionRequest) async throws -> [LocationLink] {
        try await gate()
        _ = request
        return implementations
    }
}

extension MockLanguageSuite: ReferencesProvider {
    public func references(
        for request: PositionRequest,
        includeDeclaration: Bool
    ) async throws -> [Location] {
        try await gate()
        _ = request
        _ = includeDeclaration
        return references
    }
}

extension MockLanguageSuite: DiagnosticsProvider {
    public func diagnostics(for request: DocumentRequest) async throws -> [LanguageDiagnostic] {
        try await gate()
        _ = request
        return diagnostics
    }
}

extension MockLanguageSuite: DocumentSymbolProvider {
    public func documentSymbols(for request: DocumentRequest) async throws -> [DocumentSymbol] {
        try await gate()
        _ = request
        return documentSymbols
    }
}

extension MockLanguageSuite: WorkspaceSymbolProvider {
    public func workspaceSymbols(
        query: String,
        context: LanguageServiceContext
    ) async throws -> [WorkspaceSymbol] {
        try await gate()
        _ = context
        if query.isEmpty { return workspaceSymbols }
        return workspaceSymbols.filter {
            $0.name.localizedCaseInsensitiveContains(query)
        }
    }
}

extension MockLanguageSuite: FormattingProvider {
    public func format(
        _ request: DocumentRequest,
        options: FormattingOptions
    ) async throws -> [TextEditPlan] {
        try await gate()
        _ = request
        _ = options
        return formatEdits
    }
}

extension MockLanguageSuite: RenameProvider {
    public func rename(
        _ request: PositionRequest,
        newName: String
    ) async throws -> WorkspaceEditPlan {
        try await gate()
        _ = request
        _ = newName
        return renamePlan
    }
}

extension MockLanguageSuite: CodeActionProvider {
    public func codeActions(
        for request: RangeRequest,
        diagnostics: [LanguageDiagnostic]
    ) async throws -> [CodeAction] {
        try await gate()
        _ = request
        _ = diagnostics
        return codeActions
    }
}

extension MockLanguageSuite: SemanticTokensProvider {
    public func semanticTokens(for request: DocumentRequest) async throws -> [SemanticTokenSpan] {
        try await gate()
        _ = request
        return semanticTokens
    }
}

extension MockLanguageSuite: InlayHintProvider {
    public func inlayHints(for request: RangeRequest) async throws -> [InlayHint] {
        try await gate()
        _ = request
        return inlayHints
    }
}

extension MockLanguageSuite: FoldingRangeProvider {
    public func foldingRanges(for request: DocumentRequest) async throws -> [FoldingRange] {
        try await gate()
        _ = request
        return foldingRanges
    }
}

extension MockLanguageSuite: SignatureHelpProvider {
    public func signatureHelp(for request: PositionRequest) async throws -> SignatureHelp? {
        try await gate()
        _ = request
        return signatureHelp
    }
}

extension MockLanguageSuite: DocumentLinkProvider {
    public func documentLinks(for request: DocumentRequest) async throws -> [DocumentLink] {
        try await gate()
        _ = request
        return documentLinks
    }
}

extension MockLanguageSuite: DocumentColorProvider {
    public func documentColors(for request: DocumentRequest) async throws -> [ColorInformation] {
        try await gate()
        _ = request
        return documentColors
    }
}

// MARK: - Fixtures

public extension MockLanguageSuite {
    /// A small multi-capability fixture for smoke tests.
    static func sample(
        uri: DocumentURI = DocumentURI(rawValue: "inmemory:sample"),
        priority: Int = 10
    ) -> MockLanguageSuite {
        let range = CodeEditorCore.TextRange(location: 0, length: 3)
        return MockLanguageSuite(
            id: "mock.sample",
            selector: .any,
            priority: priority,
            completionItems: [
                CompletionItem(
                    label: "hello",
                    kind: .function,
                    detail: "() -> Void",
                    insertText: "hello()",
                    textEdit: TextEditPlan(range: range, newText: "hello()"),
                    sortText: "0_hello"
                ),
                CompletionItem(label: "world", kind: .variable, insertText: "world"),
            ],
            hover: Hover(sections: [
                HoverSection(content: .markdown("**hello** sample"), range: range),
            ]),
            definitions: [
                LocationLink(targetURI: uri, targetRange: range, targetSelectionRange: range),
            ],
            declarations: [
                LocationLink(targetURI: uri, targetRange: range),
            ],
            implementations: [
                LocationLink(targetURI: uri, targetRange: range),
            ],
            references: [
                Location(uri: uri, range: range),
            ],
            diagnostics: [
                LanguageDiagnostic(
                    range: range,
                    severity: .warning,
                    message: "sample warning",
                    code: "S001",
                    source: "mock"
                ),
            ],
            documentSymbols: [
                DocumentSymbol(
                    name: "hello",
                    kind: .function,
                    range: range,
                    selectionRange: range
                ),
            ],
            workspaceSymbols: [
                WorkspaceSymbol(
                    name: "hello",
                    kind: .function,
                    location: Location(uri: uri, range: range)
                ),
            ],
            formatEdits: [
                TextEditPlan(range: range, newText: "hi "),
            ],
            renamePlan: WorkspaceEditPlan(documentEdits: [
                DocumentEditPlan(uri: uri, edits: [
                    TextEditPlan(range: range, newText: "renamed"),
                ]),
            ]),
            codeActions: [
                CodeAction(title: "Fix sample", kind: "quickfix", isPreferred: true),
            ],
            semanticTokens: [
                SemanticTokenSpan(range: range, capture: .function, rawType: "function"),
            ],
            inlayHints: [
                InlayHint(position: TextPosition(utf16Offset: 3), label: ": Int", kind: .type),
            ],
            foldingRanges: [
                FoldingRange(startLine: 0, endLine: 2, kind: "region"),
            ],
            signatureHelp: SignatureHelp(
                signatures: [
                    SignatureInformation(
                        label: "hello(name: String)",
                        parameters: [ParameterInformation(label: "name: String")]
                    ),
                ],
                activeSignature: 0,
                activeParameter: 0
            ),
            documentLinks: [
                DocumentLink(range: range, target: uri),
            ],
            documentColors: [
                ColorInformation(
                    range: range,
                    color: ColorValue(red: 1, green: 0, blue: 0, alpha: 1)
                ),
            ]
        )
    }
}
