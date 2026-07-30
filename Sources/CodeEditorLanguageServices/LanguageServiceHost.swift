import Foundation
import CodeEditorCore
import CodeEditorDocuments

/// Routes language-service requests through the registry with merge policies and version checks.
public struct LanguageServiceHost: Sendable {
    public let registry: LanguageServiceRegistry

    /// Optional hover section cap (default 8).
    public var maxHoverSections: Int

    public init(registry: LanguageServiceRegistry, maxHoverSections: Int = 8) {
        self.registry = registry
        self.maxHoverSections = maxHoverSections
    }

    // MARK: - Completions

    public func completions(
        for request: CompletionRequest,
        currentVersion: @Sendable () -> DocumentVersion
    ) async throws -> CompletionList {
        try ensureVersion(request.document.version, current: currentVersion)
        try Task.checkCancellation()

        let providers = await registry.matchingCompletions(
            languageID: request.context.languageID,
            uri: request.context.uri
        )
        var batches: [(priority: Int, list: CompletionList)] = []
        for provider in providers {
            try Task.checkCancellation()
            do {
                let list = try await provider.completions(for: request)
                batches.append((provider.priority, list))
            } catch is CancellationError {
                throw LanguageServiceError.cancelled
            } catch let error as LanguageServiceError where error == .cancelled {
                throw error
            } catch {
                continue
            }
        }
        try ensureVersion(request.document.version, current: currentVersion)
        return LanguageServiceMerge.completions(from: batches)
    }

    // MARK: - Hover

    public func hover(
        for request: PositionRequest,
        currentVersion: @Sendable () -> DocumentVersion
    ) async throws -> Hover? {
        try ensureVersion(request.document.version, current: currentVersion)
        try Task.checkCancellation()

        let providers = await registry.matchingHovers(
            languageID: request.context.languageID,
            uri: request.context.uri
        )
        var batches: [Hover] = []
        for provider in providers {
            try Task.checkCancellation()
            if let result = try? await provider.hover(for: request) {
                batches.append(result)
            }
        }
        try ensureVersion(request.document.version, current: currentVersion)
        return LanguageServiceMerge.hoverSections(batches, max: maxHoverSections)
    }

    // MARK: - Navigation

    public func definitions(
        for request: PositionRequest,
        currentVersion: @Sendable () -> DocumentVersion
    ) async throws -> [LocationLink] {
        try ensureVersion(request.document.version, current: currentVersion)
        try Task.checkCancellation()
        let providers = await registry.matchingDefinitions(
            languageID: request.context.languageID,
            uri: request.context.uri
        )
        var batches: [[LocationLink]] = []
        for provider in providers {
            try Task.checkCancellation()
            if let links = try? await provider.definitions(for: request) {
                batches.append(links)
            }
        }
        try ensureVersion(request.document.version, current: currentVersion)
        return LanguageServiceMerge.locationLinks(batches)
    }

    public func declarations(
        for request: PositionRequest,
        currentVersion: @Sendable () -> DocumentVersion
    ) async throws -> [LocationLink] {
        try ensureVersion(request.document.version, current: currentVersion)
        try Task.checkCancellation()
        let providers = await registry.matchingDeclarations(
            languageID: request.context.languageID,
            uri: request.context.uri
        )
        var batches: [[LocationLink]] = []
        for provider in providers {
            try Task.checkCancellation()
            if let links = try? await provider.declarations(for: request) {
                batches.append(links)
            }
        }
        try ensureVersion(request.document.version, current: currentVersion)
        return LanguageServiceMerge.locationLinks(batches)
    }

    public func implementations(
        for request: PositionRequest,
        currentVersion: @Sendable () -> DocumentVersion
    ) async throws -> [LocationLink] {
        try ensureVersion(request.document.version, current: currentVersion)
        try Task.checkCancellation()
        let providers = await registry.matchingImplementations(
            languageID: request.context.languageID,
            uri: request.context.uri
        )
        var batches: [[LocationLink]] = []
        for provider in providers {
            try Task.checkCancellation()
            if let links = try? await provider.implementations(for: request) {
                batches.append(links)
            }
        }
        try ensureVersion(request.document.version, current: currentVersion)
        return LanguageServiceMerge.locationLinks(batches)
    }

    public func references(
        for request: PositionRequest,
        includeDeclaration: Bool = true,
        currentVersion: @Sendable () -> DocumentVersion
    ) async throws -> [Location] {
        try ensureVersion(request.document.version, current: currentVersion)
        try Task.checkCancellation()
        let providers = await registry.matchingReferences(
            languageID: request.context.languageID,
            uri: request.context.uri
        )
        var batches: [[Location]] = []
        for provider in providers {
            try Task.checkCancellation()
            if let list = try? await provider.references(
                for: request,
                includeDeclaration: includeDeclaration
            ) {
                batches.append(list)
            }
        }
        try ensureVersion(request.document.version, current: currentVersion)
        return LanguageServiceMerge.locations(batches)
    }

    // MARK: - Diagnostics / symbols

    public func diagnostics(
        for request: DocumentRequest,
        currentVersion: @Sendable () -> DocumentVersion
    ) async throws -> [LanguageDiagnostic] {
        try ensureVersion(request.document.version, current: currentVersion)
        try Task.checkCancellation()
        let providers = await registry.matchingDiagnostics(
            languageID: request.context.languageID,
            uri: request.context.uri
        )
        var batches: [[LanguageDiagnostic]] = []
        for provider in providers {
            try Task.checkCancellation()
            if let list = try? await provider.diagnostics(for: request) {
                batches.append(list)
            }
        }
        try ensureVersion(request.document.version, current: currentVersion)
        return LanguageServiceMerge.diagnostics(batches)
    }

    public func documentSymbols(
        for request: DocumentRequest,
        currentVersion: @Sendable () -> DocumentVersion
    ) async throws -> [DocumentSymbol] {
        try ensureVersion(request.document.version, current: currentVersion)
        try Task.checkCancellation()
        let providers = await registry.matchingDocumentSymbols(
            languageID: request.context.languageID,
            uri: request.context.uri
        )
        var batches: [[DocumentSymbol]] = []
        for provider in providers {
            try Task.checkCancellation()
            if let list = try? await provider.documentSymbols(for: request) {
                batches.append(list)
            }
        }
        try ensureVersion(request.document.version, current: currentVersion)
        return LanguageServiceMerge.documentSymbols(batches)
    }

    public func workspaceSymbols(
        query: String,
        context: LanguageServiceContext
    ) async throws -> [WorkspaceSymbol] {
        try Task.checkCancellation()
        let providers = await registry.matchingWorkspaceSymbols(
            languageID: context.languageID,
            uri: context.uri
        )
        var batches: [[WorkspaceSymbol]] = []
        for provider in providers {
            try Task.checkCancellation()
            if let list = try? await provider.workspaceSymbols(query: query, context: context) {
                batches.append(list)
            }
        }
        return LanguageServiceMerge.workspaceSymbols(batches)
    }

    // MARK: - Formatting / rename (highest priority only)

    public func format(
        _ request: DocumentRequest,
        options: FormattingOptions = FormattingOptions(),
        currentVersion: @Sendable () -> DocumentVersion
    ) async throws -> [TextEditPlan] {
        try ensureVersion(request.document.version, current: currentVersion)
        try Task.checkCancellation()
        let providers = await registry.matchingFormatting(
            languageID: request.context.languageID,
            uri: request.context.uri
        )
        for provider in providers {
            try Task.checkCancellation()
            if let edits = try? await provider.format(request, options: options), !edits.isEmpty {
                try ensureVersion(request.document.version, current: currentVersion)
                return edits
            }
        }
        try ensureVersion(request.document.version, current: currentVersion)
        return []
    }

    public func formatRange(
        _ request: RangeRequest,
        options: FormattingOptions = FormattingOptions(),
        currentVersion: @Sendable () -> DocumentVersion
    ) async throws -> [TextEditPlan] {
        try ensureVersion(request.document.version, current: currentVersion)
        try Task.checkCancellation()
        let providers = await registry.matchingFormatting(
            languageID: request.context.languageID,
            uri: request.context.uri
        )
        for provider in providers {
            try Task.checkCancellation()
            if let edits = try? await provider.formatRange(request, options: options), !edits.isEmpty {
                try ensureVersion(request.document.version, current: currentVersion)
                return edits
            }
        }
        try ensureVersion(request.document.version, current: currentVersion)
        return []
    }

    public func rename(
        _ request: PositionRequest,
        newName: String,
        currentVersion: @Sendable () -> DocumentVersion
    ) async throws -> WorkspaceEditPlan {
        try ensureVersion(request.document.version, current: currentVersion)
        try Task.checkCancellation()
        let providers = await registry.matchingRenames(
            languageID: request.context.languageID,
            uri: request.context.uri
        )
        for provider in providers {
            try Task.checkCancellation()
            if let plan = try? await provider.rename(request, newName: newName) {
                try ensureVersion(request.document.version, current: currentVersion)
                return plan
            }
        }
        try ensureVersion(request.document.version, current: currentVersion)
        return WorkspaceEditPlan()
    }

    // MARK: - Code actions / semantic / inlays / folds / signature / links / colors

    public func codeActions(
        for request: RangeRequest,
        diagnostics: [LanguageDiagnostic] = [],
        currentVersion: @Sendable () -> DocumentVersion
    ) async throws -> [CodeAction] {
        try ensureVersion(request.document.version, current: currentVersion)
        try Task.checkCancellation()
        let providers = await registry.matchingCodeActions(
            languageID: request.context.languageID,
            uri: request.context.uri
        )
        var batches: [[CodeAction]] = []
        for provider in providers {
            try Task.checkCancellation()
            if let list = try? await provider.codeActions(for: request, diagnostics: diagnostics) {
                batches.append(list)
            }
        }
        try ensureVersion(request.document.version, current: currentVersion)
        return LanguageServiceMerge.codeActions(batches)
    }

    public func semanticTokens(
        for request: DocumentRequest,
        currentVersion: @Sendable () -> DocumentVersion
    ) async throws -> [SemanticTokenSpan] {
        try ensureVersion(request.document.version, current: currentVersion)
        try Task.checkCancellation()
        let providers = await registry.matchingSemanticTokens(
            languageID: request.context.languageID,
            uri: request.context.uri
        )
        var batches: [[SemanticTokenSpan]] = []
        for provider in providers {
            try Task.checkCancellation()
            if let list = try? await provider.semanticTokens(for: request) {
                let tagged = list.map { span -> SemanticTokenSpan in
                    var copy = span
                    if copy.providerID == nil {
                        copy.providerID = provider.id.rawValue
                    }
                    return copy
                }
                batches.append(tagged)
            }
        }
        try ensureVersion(request.document.version, current: currentVersion)
        return LanguageServiceMerge.semanticTokens(batches)
    }

    public func inlayHints(
        for request: RangeRequest,
        currentVersion: @Sendable () -> DocumentVersion
    ) async throws -> [InlayHint] {
        try ensureVersion(request.document.version, current: currentVersion)
        try Task.checkCancellation()
        let providers = await registry.matchingInlayHints(
            languageID: request.context.languageID,
            uri: request.context.uri
        )
        var batches: [[InlayHint]] = []
        for provider in providers {
            try Task.checkCancellation()
            if let list = try? await provider.inlayHints(for: request) {
                batches.append(list)
            }
        }
        try ensureVersion(request.document.version, current: currentVersion)
        return LanguageServiceMerge.inlayHints(batches)
    }

    public func foldingRanges(
        for request: DocumentRequest,
        currentVersion: @Sendable () -> DocumentVersion
    ) async throws -> [FoldingRange] {
        try ensureVersion(request.document.version, current: currentVersion)
        try Task.checkCancellation()
        let providers = await registry.matchingFolding(
            languageID: request.context.languageID,
            uri: request.context.uri
        )
        var batches: [[FoldingRange]] = []
        for provider in providers {
            try Task.checkCancellation()
            if let list = try? await provider.foldingRanges(for: request) {
                batches.append(list)
            }
        }
        try ensureVersion(request.document.version, current: currentVersion)
        return LanguageServiceMerge.foldingRanges(batches)
    }

    public func signatureHelp(
        for request: PositionRequest,
        currentVersion: @Sendable () -> DocumentVersion
    ) async throws -> SignatureHelp? {
        try ensureVersion(request.document.version, current: currentVersion)
        try Task.checkCancellation()
        let providers = await registry.matchingSignatures(
            languageID: request.context.languageID,
            uri: request.context.uri
        )
        for provider in providers {
            try Task.checkCancellation()
            if let help = try? await provider.signatureHelp(for: request) {
                try ensureVersion(request.document.version, current: currentVersion)
                return help
            }
        }
        try ensureVersion(request.document.version, current: currentVersion)
        return nil
    }

    public func documentLinks(
        for request: DocumentRequest,
        currentVersion: @Sendable () -> DocumentVersion
    ) async throws -> [DocumentLink] {
        try ensureVersion(request.document.version, current: currentVersion)
        try Task.checkCancellation()
        let providers = await registry.matchingLinks(
            languageID: request.context.languageID,
            uri: request.context.uri
        )
        var batches: [[DocumentLink]] = []
        for provider in providers {
            try Task.checkCancellation()
            if let list = try? await provider.documentLinks(for: request) {
                batches.append(list)
            }
        }
        try ensureVersion(request.document.version, current: currentVersion)
        return LanguageServiceMerge.documentLinks(batches)
    }

    public func documentColors(
        for request: DocumentRequest,
        currentVersion: @Sendable () -> DocumentVersion
    ) async throws -> [ColorInformation] {
        try ensureVersion(request.document.version, current: currentVersion)
        try Task.checkCancellation()
        let providers = await registry.matchingColors(
            languageID: request.context.languageID,
            uri: request.context.uri
        )
        var batches: [[ColorInformation]] = []
        for provider in providers {
            try Task.checkCancellation()
            if let list = try? await provider.documentColors(for: request) {
                batches.append(list)
            }
        }
        try ensureVersion(request.document.version, current: currentVersion)
        return LanguageServiceMerge.documentColors(batches)
    }

    // MARK: - Helpers

    private func ensureVersion(
        _ requestVersion: DocumentVersion,
        current: @Sendable () -> DocumentVersion
    ) throws {
        try LanguageServiceVersioning.ensureCurrent(
            requestVersion: requestVersion,
            current: current
        )
    }
}
