import CodeEditorCore
import CodeEditorDocuments
import Foundation

/// Routes language-service requests through the registry with merge policies,
/// per-provider timeouts, cancellation, stale-revision checks, and failure isolation.
public struct LanguageServiceHost: Sendable {
    public let registry: LanguageServiceRegistry
    public var limits: LanguageServiceLimits

    public init(
        registry: LanguageServiceRegistry,
        limits: LanguageServiceLimits = .default,
        maxHoverSections: Int? = nil
    ) {
        self.registry = registry
        var limits = limits
        if let maxHoverSections {
            limits.maxHoverSections = maxHoverSections
        }
        self.limits = limits
    }

    /// Convenience accessor used by older call sites.
    public var maxHoverSections: Int {
        get { limits.maxHoverSections }
        set { limits.maxHoverSections = newValue }
    }

    // MARK: - Completions

    public func completions(
        for request: CompletionRequest,
        currentVersion: @escaping @Sendable () -> DocumentVersion
    ) async throws -> CompletionList {
        try preflight(request.document.version, currentVersion)
        let providers = await registry.matchingCompletions(
            languageID: request.context.languageID,
            uri: request.context.uri
        )
        var batches: [(priority: Int, list: CompletionList)] = []
        let docLen = request.document.text.utf16.count
        for provider in providers {
            try Task.checkCancellation()
            guard
                let list = try await invoke(
                    id: provider.id,
                    requestVersion: request.document.version,
                    currentVersion: currentVersion,
                    work: { try await provider.completions(for: request) }
                )
            else { continue }

            var sanitized = list
            let cappedItems: [CompletionItem] = try LanguageServiceSanitize.capped(
                list.items,
                max: limits.maxCompletionItems
            )
            sanitized.items = cappedItems
            for i in sanitized.items.indices {
                if let doc = sanitized.items[i].documentation {
                    sanitized.items[i].documentation = LanguageServiceSanitize.truncateMarkup(
                        doc,
                        maxCharacters: limits.maxMarkupCharacters
                    )
                }
                if let edit = sanitized.items[i].textEdit {
                    sanitized.items[i].textEdit = LanguageServiceSanitize.sanitizeEdit(
                        edit,
                        documentLength: docLen
                    )
                }
            }
            batches.append((provider.priority, sanitized))
        }
        try ensureVersion(request.document.version, current: currentVersion)
        return LanguageServiceMerge.completions(from: batches)
    }

    // MARK: - Hover

    public func hover(
        for request: PositionRequest,
        currentVersion: @escaping @Sendable () -> DocumentVersion
    ) async throws -> Hover? {
        try preflight(request.document.version, currentVersion)
        let providers = await registry.matchingHovers(
            languageID: request.context.languageID,
            uri: request.context.uri
        )
        var batches: [Hover] = []
        let docLen = request.document.text.utf16.count
        for provider in providers {
            try Task.checkCancellation()
            guard
                let maybeHover = try await invoke(
                    id: provider.id,
                    requestVersion: request.document.version,
                    currentVersion: currentVersion,
                    work: { try await provider.hover(for: request) }
                ), let result = maybeHover
            else { continue }

            let sections = result.sections.prefix(limits.maxHoverSections).map { section in
                HoverSection(
                    content: LanguageServiceSanitize.truncateMarkup(
                        section.content,
                        maxCharacters: limits.maxMarkupCharacters
                    ),
                    range: section.range.flatMap {
                        LanguageServiceSanitize.clampRange($0, documentLength: docLen)
                    }
                )
            }
            if !sections.isEmpty {
                batches.append(Hover(sections: Array(sections)))
            }
        }
        try ensureVersion(request.document.version, current: currentVersion)
        return LanguageServiceMerge.hoverSections(batches, max: limits.maxHoverSections)
    }

    // MARK: - Navigation

    public func definitions(
        for request: PositionRequest,
        currentVersion: @escaping @Sendable () -> DocumentVersion
    ) async throws -> [LocationLink] {
        try preflight(request.document.version, currentVersion)
        let providers = await registry.matchingDefinitions(
            languageID: request.context.languageID,
            uri: request.context.uri
        )
        var batches: [[LocationLink]] = []
        for provider in providers {
            try Task.checkCancellation()
            if let list = try await invoke(
                id: provider.id,
                requestVersion: request.document.version,
                currentVersion: currentVersion,
                work: { try await provider.definitions(for: request) }
            ) {
                batches.append(try LanguageServiceSanitize.capped(list, max: limits.maxLocations))
            }
        }
        try ensureVersion(request.document.version, current: currentVersion)
        return try LanguageServiceSanitize.capped(
            LanguageServiceMerge.locationLinks(batches),
            max: limits.maxLocations
        )
    }

    public func declarations(
        for request: PositionRequest,
        currentVersion: @escaping @Sendable () -> DocumentVersion
    ) async throws -> [LocationLink] {
        try preflight(request.document.version, currentVersion)
        let providers = await registry.matchingDeclarations(
            languageID: request.context.languageID,
            uri: request.context.uri
        )
        var batches: [[LocationLink]] = []
        for provider in providers {
            try Task.checkCancellation()
            if let list = try await invoke(
                id: provider.id,
                requestVersion: request.document.version,
                currentVersion: currentVersion,
                work: { try await provider.declarations(for: request) }
            ) {
                batches.append(try LanguageServiceSanitize.capped(list, max: limits.maxLocations))
            }
        }
        try ensureVersion(request.document.version, current: currentVersion)
        return try LanguageServiceSanitize.capped(
            LanguageServiceMerge.locationLinks(batches),
            max: limits.maxLocations
        )
    }

    public func implementations(
        for request: PositionRequest,
        currentVersion: @escaping @Sendable () -> DocumentVersion
    ) async throws -> [LocationLink] {
        try preflight(request.document.version, currentVersion)
        let providers = await registry.matchingImplementations(
            languageID: request.context.languageID,
            uri: request.context.uri
        )
        var batches: [[LocationLink]] = []
        for provider in providers {
            try Task.checkCancellation()
            if let list = try await invoke(
                id: provider.id,
                requestVersion: request.document.version,
                currentVersion: currentVersion,
                work: { try await provider.implementations(for: request) }
            ) {
                batches.append(try LanguageServiceSanitize.capped(list, max: limits.maxLocations))
            }
        }
        try ensureVersion(request.document.version, current: currentVersion)
        return try LanguageServiceSanitize.capped(
            LanguageServiceMerge.locationLinks(batches),
            max: limits.maxLocations
        )
    }

    public func references(
        for request: PositionRequest,
        includeDeclaration: Bool = true,
        currentVersion: @escaping @Sendable () -> DocumentVersion
    ) async throws -> [Location] {
        try preflight(request.document.version, currentVersion)
        let providers = await registry.matchingReferences(
            languageID: request.context.languageID,
            uri: request.context.uri
        )
        var batches: [[Location]] = []
        for provider in providers {
            try Task.checkCancellation()
            if let list = try await invoke(
                id: provider.id,
                requestVersion: request.document.version,
                currentVersion: currentVersion,
                work: { try await provider.references(for: request, includeDeclaration: includeDeclaration) }
            ) {
                batches.append(try LanguageServiceSanitize.capped(list, max: limits.maxLocations))
            }
        }
        try ensureVersion(request.document.version, current: currentVersion)
        return try LanguageServiceSanitize.capped(
            LanguageServiceMerge.locations(batches),
            max: limits.maxLocations
        )
    }

    // MARK: - Diagnostics / symbols

    public func diagnostics(
        for request: DocumentRequest,
        currentVersion: @escaping @Sendable () -> DocumentVersion
    ) async throws -> [LanguageDiagnostic] {
        try preflight(request.document.version, currentVersion)
        let providers = await registry.matchingDiagnostics(
            languageID: request.context.languageID,
            uri: request.context.uri
        )
        var batches: [[LanguageDiagnostic]] = []
        let docLen = request.document.text.utf16.count
        for provider in providers {
            try Task.checkCancellation()
            if let list = try await invoke(
                id: provider.id,
                requestVersion: request.document.version,
                currentVersion: currentVersion,
                work: { try await provider.diagnostics(for: request) }
            ) {
                let owned = list.compactMap { diag -> LanguageDiagnostic? in
                    guard let range = LanguageServiceSanitize.clampRange(diag.range, documentLength: docLen)
                    else { return nil }
                    var copy = diag
                    copy.range = range
                    if copy.source == nil {
                        copy.source = provider.id.rawValue
                    }
                    return copy
                }
                batches.append(try LanguageServiceSanitize.capped(owned, max: limits.maxDiagnostics))
            }
        }
        try ensureVersion(request.document.version, current: currentVersion)
        return try LanguageServiceSanitize.capped(
            LanguageServiceMerge.diagnostics(batches),
            max: limits.maxDiagnostics
        )
    }

    public func pullDiagnostics(
        for request: DocumentRequest,
        currentVersion: @escaping @Sendable () -> DocumentVersion
    ) async throws -> PullDiagnosticsResult {
        try preflight(request.document.version, currentVersion)
        let providers = await registry.matchingPullDiagnostics(
            languageID: request.context.languageID,
            uri: request.context.uri
        )
        var items: [LanguageDiagnostic] = []
        var kind = "full"
        var resultID: String?
        for provider in providers {
            try Task.checkCancellation()
            if let result = try await invoke(
                id: provider.id,
                requestVersion: request.document.version,
                currentVersion: currentVersion,
                work: { try await provider.pullDiagnostics(for: request) }
            ) {
                kind = result.kind
                if resultID == nil { resultID = result.resultID }
                items.append(contentsOf: result.items)
            }
        }
        try ensureVersion(request.document.version, current: currentVersion)
        let merged = try LanguageServiceSanitize.capped(
            LanguageServiceMerge.diagnostics([items]),
            max: limits.maxDiagnostics
        )
        return PullDiagnosticsResult(kind: kind, resultID: resultID, items: merged)
    }

    public func documentSymbols(
        for request: DocumentRequest,
        currentVersion: @escaping @Sendable () -> DocumentVersion
    ) async throws -> [DocumentSymbol] {
        try preflight(request.document.version, currentVersion)
        let providers = await registry.matchingDocumentSymbols(
            languageID: request.context.languageID,
            uri: request.context.uri
        )
        var batches: [[DocumentSymbol]] = []
        for provider in providers {
            try Task.checkCancellation()
            if let list = try await invoke(
                id: provider.id,
                requestVersion: request.document.version,
                currentVersion: currentVersion,
                work: { try await provider.documentSymbols(for: request) }
            ) {
                batches.append(try LanguageServiceSanitize.capped(list, max: limits.maxSymbols))
            }
        }
        try ensureVersion(request.document.version, current: currentVersion)
        return try LanguageServiceSanitize.capped(
            LanguageServiceMerge.documentSymbols(batches),
            max: limits.maxSymbols
        )
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
            if let list = try await invoke(
                id: provider.id,
                requestVersion: nil as DocumentVersion?,
                currentVersion: nil as (@Sendable () -> DocumentVersion)?,
                work: { try await provider.workspaceSymbols(query: query, context: context) }
            ) {
                batches.append(try LanguageServiceSanitize.capped(list, max: limits.maxSymbols))
            }
        }
        return try LanguageServiceSanitize.capped(
            LanguageServiceMerge.workspaceSymbols(batches),
            max: limits.maxSymbols
        )
    }

    // MARK: - Formatting / rename (highest priority only)

    public func format(
        _ request: DocumentRequest,
        options: FormattingOptions = FormattingOptions(),
        currentVersion: @escaping @Sendable () -> DocumentVersion
    ) async throws -> [TextEditPlan] {
        try preflight(request.document.version, currentVersion)
        let providers = await registry.matchingFormatting(
            languageID: request.context.languageID,
            uri: request.context.uri
        )
        let docLen = request.document.text.utf16.count
        for provider in providers {
            try Task.checkCancellation()
            if let edits = try await invoke(
                id: provider.id,
                requestVersion: request.document.version,
                currentVersion: currentVersion,
                work: { try await provider.format(request, options: options) }
            ) {
                let sanitized = LanguageServiceSanitize.sanitizeEdits(edits, documentLength: docLen)
                if !sanitized.isEmpty {
                    try ensureVersion(request.document.version, current: currentVersion)
                    return sanitized
                }
            }
        }
        try ensureVersion(request.document.version, current: currentVersion)
        return []
    }

    public func formatRange(
        _ request: RangeRequest,
        options: FormattingOptions = FormattingOptions(),
        currentVersion: @escaping @Sendable () -> DocumentVersion
    ) async throws -> [TextEditPlan] {
        try preflight(request.document.version, currentVersion)
        let providers = await registry.matchingFormatting(
            languageID: request.context.languageID,
            uri: request.context.uri
        )
        let docLen = request.document.text.utf16.count
        for provider in providers {
            try Task.checkCancellation()
            if let edits = try await invoke(
                id: provider.id,
                requestVersion: request.document.version,
                currentVersion: currentVersion,
                work: { try await provider.formatRange(request, options: options) }
            ) {
                let sanitized = LanguageServiceSanitize.sanitizeEdits(edits, documentLength: docLen)
                if !sanitized.isEmpty {
                    try ensureVersion(request.document.version, current: currentVersion)
                    return sanitized
                }
            }
        }
        try ensureVersion(request.document.version, current: currentVersion)
        return []
    }

    public func rename(
        _ request: PositionRequest,
        newName: String,
        currentVersion: @escaping @Sendable () -> DocumentVersion
    ) async throws -> WorkspaceEditPlan {
        try preflight(request.document.version, currentVersion)
        let providers = await registry.matchingRenames(
            languageID: request.context.languageID,
            uri: request.context.uri
        )
        for provider in providers {
            try Task.checkCancellation()
            if let plan = try await invoke(
                id: provider.id,
                requestVersion: request.document.version,
                currentVersion: currentVersion,
                work: { try await provider.rename(request, newName: newName) }
            ), !plan.documentEdits.isEmpty {
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
        currentVersion: @escaping @Sendable () -> DocumentVersion
    ) async throws -> [CodeAction] {
        try preflight(request.document.version, currentVersion)
        let providers = await registry.matchingCodeActions(
            languageID: request.context.languageID,
            uri: request.context.uri
        )
        var batches: [[CodeAction]] = []
        for provider in providers {
            try Task.checkCancellation()
            if let list = try await invoke(
                id: provider.id,
                requestVersion: request.document.version,
                currentVersion: currentVersion,
                work: { try await provider.codeActions(for: request, diagnostics: diagnostics) }
            ) {
                batches.append(try LanguageServiceSanitize.capped(list, max: limits.maxCodeActions))
            }
        }
        try ensureVersion(request.document.version, current: currentVersion)
        return try LanguageServiceSanitize.capped(
            LanguageServiceMerge.codeActions(batches),
            max: limits.maxCodeActions
        )
    }

    public func semanticTokens(
        for request: DocumentRequest,
        currentVersion: @escaping @Sendable () -> DocumentVersion
    ) async throws -> [SemanticTokenSpan] {
        try preflight(request.document.version, currentVersion)
        let providers = await registry.matchingSemanticTokens(
            languageID: request.context.languageID,
            uri: request.context.uri
        )
        var batches: [[SemanticTokenSpan]] = []
        let docLen = request.document.text.utf16.count
        for provider in providers {
            try Task.checkCancellation()
            if let list = try await invoke(
                id: provider.id,
                requestVersion: request.document.version,
                currentVersion: currentVersion,
                work: { try await provider.semanticTokens(for: request) }
            ) {
                let tagged = list.compactMap { span -> SemanticTokenSpan? in
                    guard let range = LanguageServiceSanitize.clampRange(span.range, documentLength: docLen)
                    else { return nil }
                    var copy = span
                    copy.range = range
                    if copy.providerID == nil {
                        copy.providerID = provider.id.rawValue
                    }
                    return copy
                }
                batches.append(try LanguageServiceSanitize.capped(tagged, max: limits.maxSemanticTokens))
            }
        }
        try ensureVersion(request.document.version, current: currentVersion)
        return try LanguageServiceSanitize.capped(
            LanguageServiceMerge.semanticTokens(batches),
            max: limits.maxSemanticTokens
        )
    }

    public func semanticTokens(
        for request: RangeRequest,
        currentVersion: @escaping @Sendable () -> DocumentVersion
    ) async throws -> [SemanticTokenSpan] {
        try preflight(request.document.version, currentVersion)
        let providers = await registry.matchingSemanticTokens(
            languageID: request.context.languageID,
            uri: request.context.uri
        )
        var batches: [[SemanticTokenSpan]] = []
        for provider in providers {
            try Task.checkCancellation()
            if let list = try await invoke(
                id: provider.id,
                requestVersion: request.document.version,
                currentVersion: currentVersion,
                work: { try await provider.semanticTokens(for: request) }
            ) {
                batches.append(try LanguageServiceSanitize.capped(list, max: limits.maxSemanticTokens))
            }
        }
        try ensureVersion(request.document.version, current: currentVersion)
        return try LanguageServiceSanitize.capped(
            LanguageServiceMerge.semanticTokens(batches),
            max: limits.maxSemanticTokens
        )
    }

    public func inlayHints(
        for request: RangeRequest,
        currentVersion: @escaping @Sendable () -> DocumentVersion
    ) async throws -> [InlayHint] {
        try preflight(request.document.version, currentVersion)
        let providers = await registry.matchingInlayHints(
            languageID: request.context.languageID,
            uri: request.context.uri
        )
        var batches: [[InlayHint]] = []
        for provider in providers {
            try Task.checkCancellation()
            if let list = try await invoke(
                id: provider.id,
                requestVersion: request.document.version,
                currentVersion: currentVersion,
                work: { try await provider.inlayHints(for: request) }
            ) {
                batches.append(try LanguageServiceSanitize.capped(list, max: limits.maxInlayHints))
            }
        }
        try ensureVersion(request.document.version, current: currentVersion)
        return try LanguageServiceSanitize.capped(
            LanguageServiceMerge.inlayHints(batches),
            max: limits.maxInlayHints
        )
    }

    public func foldingRanges(
        for request: DocumentRequest,
        currentVersion: @escaping @Sendable () -> DocumentVersion
    ) async throws -> [FoldingRange] {
        try preflight(request.document.version, currentVersion)
        let providers = await registry.matchingFolding(
            languageID: request.context.languageID,
            uri: request.context.uri
        )
        var batches: [[FoldingRange]] = []
        for provider in providers {
            try Task.checkCancellation()
            if let list = try await invoke(
                id: provider.id,
                requestVersion: request.document.version,
                currentVersion: currentVersion,
                work: { try await provider.foldingRanges(for: request) }
            ) {
                batches.append(try LanguageServiceSanitize.capped(list, max: limits.maxFoldingRanges))
            }
        }
        try ensureVersion(request.document.version, current: currentVersion)
        return try LanguageServiceSanitize.capped(
            LanguageServiceMerge.foldingRanges(batches),
            max: limits.maxFoldingRanges
        )
    }

    public func signatureHelp(
        for request: PositionRequest,
        currentVersion: @escaping @Sendable () -> DocumentVersion
    ) async throws -> SignatureHelp? {
        try preflight(request.document.version, currentVersion)
        let providers = await registry.matchingSignatures(
            languageID: request.context.languageID,
            uri: request.context.uri
        )
        for provider in providers {
            try Task.checkCancellation()
            if let maybeHelp = try await invoke(
                id: provider.id,
                requestVersion: request.document.version,
                currentVersion: currentVersion,
                work: { try await provider.signatureHelp(for: request) }
            ), let help = maybeHelp {
                try ensureVersion(request.document.version, current: currentVersion)
                return help
            }
        }
        try ensureVersion(request.document.version, current: currentVersion)
        return nil
    }

    public func documentLinks(
        for request: DocumentRequest,
        currentVersion: @escaping @Sendable () -> DocumentVersion
    ) async throws -> [DocumentLink] {
        try preflight(request.document.version, currentVersion)
        let providers = await registry.matchingLinks(
            languageID: request.context.languageID,
            uri: request.context.uri
        )
        var batches: [[DocumentLink]] = []
        let docLen = request.document.text.utf16.count
        for provider in providers {
            try Task.checkCancellation()
            if let list = try await invoke(
                id: provider.id,
                requestVersion: request.document.version,
                currentVersion: currentVersion,
                work: { try await provider.documentLinks(for: request) }
            ) {
                let clamped = list.compactMap { link -> DocumentLink? in
                    guard let range = LanguageServiceSanitize.clampRange(link.range, documentLength: docLen)
                    else { return nil }
                    return DocumentLink(range: range, target: link.target)
                }
                batches.append(try LanguageServiceSanitize.capped(clamped, max: limits.maxDocumentLinks))
            }
        }
        try ensureVersion(request.document.version, current: currentVersion)
        return try LanguageServiceSanitize.capped(
            LanguageServiceMerge.documentLinks(batches),
            max: limits.maxDocumentLinks
        )
    }

    public func documentColors(
        for request: DocumentRequest,
        currentVersion: @escaping @Sendable () -> DocumentVersion
    ) async throws -> [ColorInformation] {
        try preflight(request.document.version, currentVersion)
        let providers = await registry.matchingColors(
            languageID: request.context.languageID,
            uri: request.context.uri
        )
        var batches: [[ColorInformation]] = []
        let docLen = request.document.text.utf16.count
        for provider in providers {
            try Task.checkCancellation()
            if let list = try await invoke(
                id: provider.id,
                requestVersion: request.document.version,
                currentVersion: currentVersion,
                work: { try await provider.documentColors(for: request) }
            ) {
                let clamped = list.compactMap { info -> ColorInformation? in
                    guard let range = LanguageServiceSanitize.clampRange(info.range, documentLength: docLen)
                    else { return nil }
                    return ColorInformation(range: range, color: info.color)
                }
                batches.append(try LanguageServiceSanitize.capped(clamped, max: limits.maxColors))
            }
        }
        try ensureVersion(request.document.version, current: currentVersion)
        return try LanguageServiceSanitize.capped(
            LanguageServiceMerge.documentColors(batches),
            max: limits.maxColors
        )
    }

    // MARK: - Highlights / hierarchy / execute command

    public func documentHighlights(
        for request: PositionRequest,
        currentVersion: @escaping @Sendable () -> DocumentVersion
    ) async throws -> [DocumentHighlight] {
        try preflight(request.document.version, currentVersion)
        let providers = await registry.matchingHighlights(
            languageID: request.context.languageID,
            uri: request.context.uri
        )
        var batches: [[DocumentHighlight]] = []
        let docLen = request.document.text.utf16.count
        for provider in providers {
            try Task.checkCancellation()
            if let list = try await invoke(
                id: provider.id,
                requestVersion: request.document.version,
                currentVersion: currentVersion,
                work: { try await provider.documentHighlights(for: request) }
            ) {
                let clamped = list.compactMap { h -> DocumentHighlight? in
                    guard let range = LanguageServiceSanitize.clampRange(h.range, documentLength: docLen)
                    else { return nil }
                    return DocumentHighlight(range: range, kind: h.kind)
                }
                batches.append(try LanguageServiceSanitize.capped(clamped, max: limits.maxHighlights))
            }
        }
        try ensureVersion(request.document.version, current: currentVersion)
        return try LanguageServiceSanitize.capped(
            LanguageServiceMerge.documentHighlights(batches),
            max: limits.maxHighlights
        )
    }

    public func prepareTypeHierarchy(
        for request: PositionRequest,
        currentVersion: @escaping @Sendable () -> DocumentVersion
    ) async throws -> [HierarchyItem] {
        try preflight(request.document.version, currentVersion)
        let providers = await registry.matchingTypeHierarchies(
            languageID: request.context.languageID,
            uri: request.context.uri
        )
        var batches: [[HierarchyItem]] = []
        for provider in providers {
            try Task.checkCancellation()
            if let list = try await invoke(
                id: provider.id,
                requestVersion: request.document.version,
                currentVersion: currentVersion,
                work: { try await provider.prepareTypeHierarchy(for: request) }
            ) {
                batches.append(try LanguageServiceSanitize.capped(list, max: limits.maxHierarchyItems))
            }
        }
        try ensureVersion(request.document.version, current: currentVersion)
        return try LanguageServiceSanitize.capped(
            LanguageServiceMerge.hierarchyItems(batches),
            max: limits.maxHierarchyItems
        )
    }

    public func prepareCallHierarchy(
        for request: PositionRequest,
        currentVersion: @escaping @Sendable () -> DocumentVersion
    ) async throws -> [CallHierarchyItem] {
        try preflight(request.document.version, currentVersion)
        let providers = await registry.matchingCallHierarchies(
            languageID: request.context.languageID,
            uri: request.context.uri
        )
        var batches: [[CallHierarchyItem]] = []
        for provider in providers {
            try Task.checkCancellation()
            if let list = try await invoke(
                id: provider.id,
                requestVersion: request.document.version,
                currentVersion: currentVersion,
                work: { try await provider.prepareCallHierarchy(for: request) }
            ) {
                batches.append(try LanguageServiceSanitize.capped(list, max: limits.maxHierarchyItems))
            }
        }
        try ensureVersion(request.document.version, current: currentVersion)
        return try LanguageServiceSanitize.capped(
            LanguageServiceMerge.callHierarchyItems(batches),
            max: limits.maxHierarchyItems
        )
    }

    public func executeCommand(
        _ request: ExecuteCommandRequest
    ) async throws -> ExecuteCommandResult {
        try Task.checkCancellation()
        let providers = await registry.matchingExecuteCommands(
            languageID: request.context.languageID,
            uri: request.context.uri
        )
        let candidates = providers.filter {
            $0.supportedCommands.isEmpty || $0.supportedCommands.contains(request.command)
        }
        for provider in candidates {
            try Task.checkCancellation()
            if let result = try await invoke(
                id: provider.id,
                requestVersion: nil as DocumentVersion?,
                currentVersion: nil as (@Sendable () -> DocumentVersion)?,
                work: { try await provider.execute(request) }
            ) {
                return result
            }
        }
        throw LanguageServiceError.noProvider
    }

    // MARK: - Policy engine

    /// Invokes a provider with timeout, cancellation, and failure isolation.
    /// Returns `nil` when the provider failed or timed out (isolated).
    /// Rethrows cancellation and stale-version errors.
    private func invoke<T: Sendable>(
        id: ProviderID,
        requestVersion: DocumentVersion?,
        currentVersion: (@Sendable () -> DocumentVersion)?,
        work: @Sendable @escaping () async throws -> T
    ) async throws -> T? {
        try Task.checkCancellation()
        if let requestVersion, let currentVersion {
            try ensureVersion(requestVersion, current: currentVersion)
        }

        let timeout = limits.providerTimeout
        do {
            let result: T = try await withThrowingTaskGroup(of: T.self) { group in
                group.addTask {
                    try await work()
                }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw LanguageServiceError.timeout(providerID: id.rawValue)
                }
                defer { group.cancelAll() }
                return try await group.next()!
            }
            if let requestVersion, let currentVersion {
                try ensureVersion(requestVersion, current: currentVersion)
            }
            await registry.recordSuccess(id: id)
            return result
        } catch is CancellationError {
            await registry.recordCancel(id: id)
            throw LanguageServiceError.cancelled
        } catch let error as LanguageServiceError {
            switch error {
            case .cancelled:
                await registry.recordCancel(id: id)
                throw error
            case .staleVersion:
                throw error
            case .timeout:
                await registry.recordTimeout(id: id)
                return nil
            default:
                await registry.recordFailure(id: id, message: String(describing: error))
                return nil
            }
        } catch {
            await registry.recordFailure(id: id, message: String(describing: error))
            return nil
        }
    }

    private func preflight(
        _ requestVersion: DocumentVersion,
        _ current: @escaping @Sendable () -> DocumentVersion
    ) throws {
        try ensureVersion(requestVersion, current: current)
        try Task.checkCancellation()
    }

    private func ensureVersion(
        _ requestVersion: DocumentVersion,
        current: @escaping @Sendable () -> DocumentVersion
    ) throws {
        try LanguageServiceVersioning.ensureCurrent(
            requestVersion: requestVersion,
            current: current
        )
    }
}
