import Foundation
import CodeEditorDocuments

/// Thread-safe registration of language service providers by capability.
public actor LanguageServiceRegistry {
    public init() {}

    private var completions: [any CompletionProvider] = []
    private var hovers: [any HoverProvider] = []
    private var definitions: [any DefinitionProvider] = []
    private var declarations: [any DeclarationProvider] = []
    private var implementations: [any ImplementationProvider] = []
    private var references: [any ReferencesProvider] = []
    private var diagnostics: [any DiagnosticsProvider] = []
    private var documentSymbols: [any DocumentSymbolProvider] = []
    private var workspaceSymbols: [any WorkspaceSymbolProvider] = []
    private var formatting: [any FormattingProvider] = []
    private var renames: [any RenameProvider] = []
    private var codeActions: [any CodeActionProvider] = []
    private var semanticTokens: [any SemanticTokensProvider] = []
    private var inlayHints: [any InlayHintProvider] = []
    private var folding: [any FoldingRangeProvider] = []
    private var signatures: [any SignatureHelpProvider] = []
    private var links: [any DocumentLinkProvider] = []
    private var colors: [any DocumentColorProvider] = []
    private var highlights: [any DocumentHighlightProvider] = []
    private var typeHierarchies: [any TypeHierarchyProvider] = []
    private var callHierarchies: [any CallHierarchyProvider] = []
    private var executeCommands: [any ExecuteCommandProvider] = []
    private var pullDiagnostics: [any PullDiagnosticsProvider] = []

    private var health: [ProviderID: ProviderHealthSnapshot] = [:]

    // MARK: - Health

    public func healthSnapshot(for id: ProviderID) -> ProviderHealthSnapshot {
        health[id] ?? ProviderHealthSnapshot(providerID: id)
    }

    public func allHealthSnapshots() -> [ProviderHealthSnapshot] {
        health.values.sorted { $0.providerID.rawValue < $1.providerID.rawValue }
    }

    public func recordSuccess(id: ProviderID) {
        var snap = health[id] ?? ProviderHealthSnapshot(providerID: id)
        snap.successCount += 1
        snap.lastUpdated = Date()
        health[id] = snap
    }

    public func recordFailure(id: ProviderID, message: String) {
        var snap = health[id] ?? ProviderHealthSnapshot(providerID: id)
        snap.failureCount += 1
        snap.lastErrorDescription = message
        snap.lastUpdated = Date()
        health[id] = snap
    }

    public func recordTimeout(id: ProviderID) {
        var snap = health[id] ?? ProviderHealthSnapshot(providerID: id)
        snap.timeoutCount += 1
        snap.lastErrorDescription = "timeout"
        snap.lastUpdated = Date()
        health[id] = snap
    }

    public func recordCancel(id: ProviderID) {
        var snap = health[id] ?? ProviderHealthSnapshot(providerID: id)
        snap.cancelCount += 1
        snap.lastUpdated = Date()
        health[id] = snap
    }

    // MARK: - Register

    public func register(_ provider: any CompletionProvider) {
        completions.removeAll { $0.id == provider.id }
        completions.append(provider)
        completions.sort { $0.priority > $1.priority }
        ensureHealth(provider.id)
    }

    public func register(_ provider: any HoverProvider) {
        hovers.removeAll { $0.id == provider.id }
        hovers.append(provider)
        hovers.sort { $0.priority > $1.priority }
        ensureHealth(provider.id)
    }

    public func register(_ provider: any DefinitionProvider) {
        definitions.removeAll { $0.id == provider.id }
        definitions.append(provider)
        definitions.sort { $0.priority > $1.priority }
        ensureHealth(provider.id)
    }

    public func register(_ provider: any DeclarationProvider) {
        declarations.removeAll { $0.id == provider.id }
        declarations.append(provider)
        declarations.sort { $0.priority > $1.priority }
        ensureHealth(provider.id)
    }

    public func register(_ provider: any ImplementationProvider) {
        implementations.removeAll { $0.id == provider.id }
        implementations.append(provider)
        implementations.sort { $0.priority > $1.priority }
        ensureHealth(provider.id)
    }

    public func register(_ provider: any ReferencesProvider) {
        references.removeAll { $0.id == provider.id }
        references.append(provider)
        references.sort { $0.priority > $1.priority }
        ensureHealth(provider.id)
    }

    public func register(_ provider: any DiagnosticsProvider) {
        diagnostics.removeAll { $0.id == provider.id }
        diagnostics.append(provider)
        diagnostics.sort { $0.priority > $1.priority }
        ensureHealth(provider.id)
    }

    public func register(_ provider: any DocumentSymbolProvider) {
        documentSymbols.removeAll { $0.id == provider.id }
        documentSymbols.append(provider)
        documentSymbols.sort { $0.priority > $1.priority }
        ensureHealth(provider.id)
    }

    public func register(_ provider: any WorkspaceSymbolProvider) {
        workspaceSymbols.removeAll { $0.id == provider.id }
        workspaceSymbols.append(provider)
        workspaceSymbols.sort { $0.priority > $1.priority }
        ensureHealth(provider.id)
    }

    public func register(_ provider: any FormattingProvider) {
        formatting.removeAll { $0.id == provider.id }
        formatting.append(provider)
        formatting.sort { $0.priority > $1.priority }
        ensureHealth(provider.id)
    }

    public func register(_ provider: any RenameProvider) {
        renames.removeAll { $0.id == provider.id }
        renames.append(provider)
        renames.sort { $0.priority > $1.priority }
        ensureHealth(provider.id)
    }

    public func register(_ provider: any CodeActionProvider) {
        codeActions.removeAll { $0.id == provider.id }
        codeActions.append(provider)
        codeActions.sort { $0.priority > $1.priority }
        ensureHealth(provider.id)
    }

    public func register(_ provider: any SemanticTokensProvider) {
        semanticTokens.removeAll { $0.id == provider.id }
        semanticTokens.append(provider)
        semanticTokens.sort { $0.priority > $1.priority }
        ensureHealth(provider.id)
    }

    public func register(_ provider: any InlayHintProvider) {
        inlayHints.removeAll { $0.id == provider.id }
        inlayHints.append(provider)
        inlayHints.sort { $0.priority > $1.priority }
        ensureHealth(provider.id)
    }

    public func register(_ provider: any FoldingRangeProvider) {
        folding.removeAll { $0.id == provider.id }
        folding.append(provider)
        folding.sort { $0.priority > $1.priority }
        ensureHealth(provider.id)
    }

    public func register(_ provider: any SignatureHelpProvider) {
        signatures.removeAll { $0.id == provider.id }
        signatures.append(provider)
        signatures.sort { $0.priority > $1.priority }
        ensureHealth(provider.id)
    }

    public func register(_ provider: any DocumentLinkProvider) {
        links.removeAll { $0.id == provider.id }
        links.append(provider)
        links.sort { $0.priority > $1.priority }
        ensureHealth(provider.id)
    }

    public func register(_ provider: any DocumentColorProvider) {
        colors.removeAll { $0.id == provider.id }
        colors.append(provider)
        colors.sort { $0.priority > $1.priority }
        ensureHealth(provider.id)
    }

    public func register(_ provider: any DocumentHighlightProvider) {
        highlights.removeAll { $0.id == provider.id }
        highlights.append(provider)
        highlights.sort { $0.priority > $1.priority }
        ensureHealth(provider.id)
    }

    public func register(_ provider: any TypeHierarchyProvider) {
        typeHierarchies.removeAll { $0.id == provider.id }
        typeHierarchies.append(provider)
        typeHierarchies.sort { $0.priority > $1.priority }
        ensureHealth(provider.id)
    }

    public func register(_ provider: any CallHierarchyProvider) {
        callHierarchies.removeAll { $0.id == provider.id }
        callHierarchies.append(provider)
        callHierarchies.sort { $0.priority > $1.priority }
        ensureHealth(provider.id)
    }

    public func register(_ provider: any ExecuteCommandProvider) {
        executeCommands.removeAll { $0.id == provider.id }
        executeCommands.append(provider)
        executeCommands.sort { $0.priority > $1.priority }
        ensureHealth(provider.id)
    }

    public func register(_ provider: any PullDiagnosticsProvider) {
        pullDiagnostics.removeAll { $0.id == provider.id }
        pullDiagnostics.append(provider)
        pullDiagnostics.sort { $0.priority > $1.priority }
        ensureHealth(provider.id)
    }

    public func unregister(id: ProviderID) {
        completions.removeAll { $0.id == id }
        hovers.removeAll { $0.id == id }
        definitions.removeAll { $0.id == id }
        declarations.removeAll { $0.id == id }
        implementations.removeAll { $0.id == id }
        references.removeAll { $0.id == id }
        diagnostics.removeAll { $0.id == id }
        documentSymbols.removeAll { $0.id == id }
        workspaceSymbols.removeAll { $0.id == id }
        formatting.removeAll { $0.id == id }
        renames.removeAll { $0.id == id }
        codeActions.removeAll { $0.id == id }
        semanticTokens.removeAll { $0.id == id }
        inlayHints.removeAll { $0.id == id }
        folding.removeAll { $0.id == id }
        signatures.removeAll { $0.id == id }
        links.removeAll { $0.id == id }
        colors.removeAll { $0.id == id }
        highlights.removeAll { $0.id == id }
        typeHierarchies.removeAll { $0.id == id }
        callHierarchies.removeAll { $0.id == id }
        executeCommands.removeAll { $0.id == id }
        pullDiagnostics.removeAll { $0.id == id }
        health.removeValue(forKey: id)
    }

    // MARK: - Matching

    func matchingCompletions(languageID: String?, uri: DocumentURI?) -> [any CompletionProvider] {
        completions.filter { $0.selector.matches(languageID: languageID, uri: uri) }
    }

    func matchingHovers(languageID: String?, uri: DocumentURI?) -> [any HoverProvider] {
        hovers.filter { $0.selector.matches(languageID: languageID, uri: uri) }
    }

    func matchingDefinitions(languageID: String?, uri: DocumentURI?) -> [any DefinitionProvider] {
        definitions.filter { $0.selector.matches(languageID: languageID, uri: uri) }
    }

    func matchingDeclarations(languageID: String?, uri: DocumentURI?) -> [any DeclarationProvider] {
        declarations.filter { $0.selector.matches(languageID: languageID, uri: uri) }
    }

    func matchingImplementations(languageID: String?, uri: DocumentURI?) -> [any ImplementationProvider] {
        implementations.filter { $0.selector.matches(languageID: languageID, uri: uri) }
    }

    func matchingReferences(languageID: String?, uri: DocumentURI?) -> [any ReferencesProvider] {
        references.filter { $0.selector.matches(languageID: languageID, uri: uri) }
    }

    func matchingDiagnostics(languageID: String?, uri: DocumentURI?) -> [any DiagnosticsProvider] {
        diagnostics.filter { $0.selector.matches(languageID: languageID, uri: uri) }
    }

    func matchingDocumentSymbols(languageID: String?, uri: DocumentURI?) -> [any DocumentSymbolProvider] {
        documentSymbols.filter { $0.selector.matches(languageID: languageID, uri: uri) }
    }

    func matchingWorkspaceSymbols(languageID: String?, uri: DocumentURI?) -> [any WorkspaceSymbolProvider] {
        workspaceSymbols.filter { $0.selector.matches(languageID: languageID, uri: uri) }
    }

    func matchingFormatting(languageID: String?, uri: DocumentURI?) -> [any FormattingProvider] {
        formatting.filter { $0.selector.matches(languageID: languageID, uri: uri) }
    }

    func matchingRenames(languageID: String?, uri: DocumentURI?) -> [any RenameProvider] {
        renames.filter { $0.selector.matches(languageID: languageID, uri: uri) }
    }

    func matchingCodeActions(languageID: String?, uri: DocumentURI?) -> [any CodeActionProvider] {
        codeActions.filter { $0.selector.matches(languageID: languageID, uri: uri) }
    }

    func matchingSemanticTokens(languageID: String?, uri: DocumentURI?) -> [any SemanticTokensProvider] {
        semanticTokens.filter { $0.selector.matches(languageID: languageID, uri: uri) }
    }

    func matchingInlayHints(languageID: String?, uri: DocumentURI?) -> [any InlayHintProvider] {
        inlayHints.filter { $0.selector.matches(languageID: languageID, uri: uri) }
    }

    func matchingFolding(languageID: String?, uri: DocumentURI?) -> [any FoldingRangeProvider] {
        folding.filter { $0.selector.matches(languageID: languageID, uri: uri) }
    }

    func matchingSignatures(languageID: String?, uri: DocumentURI?) -> [any SignatureHelpProvider] {
        signatures.filter { $0.selector.matches(languageID: languageID, uri: uri) }
    }

    func matchingLinks(languageID: String?, uri: DocumentURI?) -> [any DocumentLinkProvider] {
        links.filter { $0.selector.matches(languageID: languageID, uri: uri) }
    }

    func matchingColors(languageID: String?, uri: DocumentURI?) -> [any DocumentColorProvider] {
        colors.filter { $0.selector.matches(languageID: languageID, uri: uri) }
    }

    func matchingHighlights(languageID: String?, uri: DocumentURI?) -> [any DocumentHighlightProvider] {
        highlights.filter { $0.selector.matches(languageID: languageID, uri: uri) }
    }

    func matchingTypeHierarchies(languageID: String?, uri: DocumentURI?) -> [any TypeHierarchyProvider] {
        typeHierarchies.filter { $0.selector.matches(languageID: languageID, uri: uri) }
    }

    func matchingCallHierarchies(languageID: String?, uri: DocumentURI?) -> [any CallHierarchyProvider] {
        callHierarchies.filter { $0.selector.matches(languageID: languageID, uri: uri) }
    }

    func matchingExecuteCommands(languageID: String?, uri: DocumentURI?) -> [any ExecuteCommandProvider] {
        executeCommands.filter { $0.selector.matches(languageID: languageID, uri: uri) }
    }

    func matchingPullDiagnostics(languageID: String?, uri: DocumentURI?) -> [any PullDiagnosticsProvider] {
        pullDiagnostics.filter { $0.selector.matches(languageID: languageID, uri: uri) }
    }

    private func ensureHealth(_ id: ProviderID) {
        if health[id] == nil {
            health[id] = ProviderHealthSnapshot(providerID: id)
        }
    }
}
