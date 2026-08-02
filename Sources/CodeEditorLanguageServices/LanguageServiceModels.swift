import CodeEditorCore
import CodeEditorDocuments
import CodeEditorLanguageSupport
import Foundation

// MARK: - Edits

public struct TextEditPlan: Sendable, Hashable, Codable {
    public var range: CodeEditorCore.TextRange
    public var newText: String

    public init(range: CodeEditorCore.TextRange, newText: String) {
        self.range = range
        self.newText = newText
    }

    public init(nsRange: NSRange, newText: String) {
        self.range = CodeEditorCore.TextRange(nsRange)
        self.newText = newText
    }
}

public struct DocumentEditPlan: Sendable, Hashable, Codable {
    public var uri: DocumentURI
    public var edits: [TextEditPlan]

    public init(uri: DocumentURI, edits: [TextEditPlan]) {
        self.uri = uri
        self.edits = edits
    }
}

public struct WorkspaceEditPlan: Sendable, Hashable, Codable {
    public var documentEdits: [DocumentEditPlan]

    public init(documentEdits: [DocumentEditPlan] = []) {
        self.documentEdits = documentEdits
    }
}

// MARK: - Markup / locations

public enum MarkupKind: String, Sendable, Codable, Hashable {
    case plaintext
    case markdown
}

public struct MarkupContent: Sendable, Hashable, Codable {
    public var kind: MarkupKind
    public var value: String

    public init(kind: MarkupKind = .markdown, value: String) {
        self.kind = kind
        self.value = value
    }

    public static func plain(_ value: String) -> MarkupContent {
        MarkupContent(kind: .plaintext, value: value)
    }

    public static func markdown(_ value: String) -> MarkupContent {
        MarkupContent(kind: .markdown, value: value)
    }
}

public struct Location: Sendable, Hashable, Codable {
    public var uri: DocumentURI
    public var range: CodeEditorCore.TextRange

    public init(uri: DocumentURI, range: CodeEditorCore.TextRange) {
        self.uri = uri
        self.range = range
    }
}

public struct LocationLink: Sendable, Hashable, Codable {
    public var targetURI: DocumentURI
    public var targetRange: CodeEditorCore.TextRange
    public var targetSelectionRange: CodeEditorCore.TextRange?
    public var originSelectionRange: CodeEditorCore.TextRange?

    public init(
        targetURI: DocumentURI,
        targetRange: CodeEditorCore.TextRange,
        targetSelectionRange: CodeEditorCore.TextRange? = nil,
        originSelectionRange: CodeEditorCore.TextRange? = nil
    ) {
        self.targetURI = targetURI
        self.targetRange = targetRange
        self.targetSelectionRange = targetSelectionRange
        self.originSelectionRange = originSelectionRange
    }
}

// MARK: - Diagnostics

public enum LanguageDiagnosticSeverity: String, Sendable, Codable, Hashable, CaseIterable {
    case error
    case warning
    case information
    case hint
}

public struct LanguageDiagnostic: Sendable, Hashable, Codable {
    public var range: CodeEditorCore.TextRange
    public var severity: LanguageDiagnosticSeverity
    public var message: String
    public var code: String?
    public var source: String?

    public init(
        range: CodeEditorCore.TextRange,
        severity: LanguageDiagnosticSeverity,
        message: String,
        code: String? = nil,
        source: String? = nil
    ) {
        self.range = range
        self.severity = severity
        self.message = message
        self.code = code
        self.source = source
    }
}

// MARK: - Completion

public enum CompletionTriggerKind: String, Sendable, Codable, Hashable {
    case invoked
    case triggerCharacter
    case triggerForIncompleteCompletions
}

public struct CompletionTrigger: Sendable, Hashable, Codable {
    public var kind: CompletionTriggerKind
    public var character: String?

    public init(kind: CompletionTriggerKind = .invoked, character: String? = nil) {
        self.kind = kind
        self.character = character
    }

    public static let invoked = CompletionTrigger(kind: .invoked)
}

public enum CompletionItemKind: String, Sendable, Codable, Hashable, CaseIterable {
    case text, method, function, constructor, field, variable, `class`, `interface`
    case module, property, unit, value, `enum`, keyword, snippet, color, file, reference
    case folder, enumMember, constant, `struct`, event, `operator`, typeParameter
}

public struct CompletionItem: Sendable, Hashable, Codable {
    public var label: String
    public var kind: CompletionItemKind?
    public var detail: String?
    public var documentation: MarkupContent?
    public var insertText: String?
    public var textEdit: TextEditPlan?
    public var additionalTextEdits: [TextEditPlan]
    public var sortText: String?
    public var filterText: String?
    public var commandID: String?

    public init(
        label: String,
        kind: CompletionItemKind? = nil,
        detail: String? = nil,
        documentation: MarkupContent? = nil,
        insertText: String? = nil,
        textEdit: TextEditPlan? = nil,
        additionalTextEdits: [TextEditPlan] = [],
        sortText: String? = nil,
        filterText: String? = nil,
        commandID: String? = nil
    ) {
        self.label = label
        self.kind = kind
        self.detail = detail
        self.documentation = documentation
        self.insertText = insertText
        self.textEdit = textEdit
        self.additionalTextEdits = additionalTextEdits
        self.sortText = sortText
        self.filterText = filterText
        self.commandID = commandID
    }
}

public struct CompletionList: Sendable, Hashable, Codable {
    public var isIncomplete: Bool
    public var items: [CompletionItem]

    public init(isIncomplete: Bool = false, items: [CompletionItem]) {
        self.isIncomplete = isIncomplete
        self.items = items
    }

    public static let empty = CompletionList(items: [])
}

// MARK: - Hover

public struct HoverSection: Sendable, Hashable, Codable {
    public var content: MarkupContent
    public var range: CodeEditorCore.TextRange?

    public init(content: MarkupContent, range: CodeEditorCore.TextRange? = nil) {
        self.content = content
        self.range = range
    }
}

public struct Hover: Sendable, Hashable, Codable {
    public var sections: [HoverSection]

    public init(sections: [HoverSection]) {
        self.sections = sections
    }
}

// MARK: - Symbols

public enum SymbolKind: String, Sendable, Codable, Hashable, CaseIterable {
    case file, module, namespace, package, `class`, method, property, field, constructor
    case `enum`, `interface`, function, variable, constant, string, number, boolean, array
    case object, key, null, enumMember, `struct`, event, `operator`, typeParameter
}

public struct DocumentSymbol: Sendable, Hashable, Codable {
    public var name: String
    public var detail: String?
    public var kind: SymbolKind
    public var range: CodeEditorCore.TextRange
    public var selectionRange: CodeEditorCore.TextRange
    public var children: [DocumentSymbol]

    public init(
        name: String,
        detail: String? = nil,
        kind: SymbolKind,
        range: CodeEditorCore.TextRange,
        selectionRange: CodeEditorCore.TextRange,
        children: [DocumentSymbol] = []
    ) {
        self.name = name
        self.detail = detail
        self.kind = kind
        self.range = range
        self.selectionRange = selectionRange
        self.children = children
    }
}

public struct WorkspaceSymbol: Sendable, Hashable, Codable {
    public var name: String
    public var kind: SymbolKind
    public var location: Location
    public var containerName: String?

    public init(name: String, kind: SymbolKind, location: Location, containerName: String? = nil) {
        self.name = name
        self.kind = kind
        self.location = location
        self.containerName = containerName
    }
}

// MARK: - Code actions / formatting / rename

public struct FormattingOptions: Sendable, Hashable, Codable {
    public var tabSize: Int
    public var insertSpaces: Bool

    public init(tabSize: Int = 4, insertSpaces: Bool = true) {
        self.tabSize = tabSize
        self.insertSpaces = insertSpaces
    }
}

public struct CodeAction: Sendable, Hashable, Codable {
    public var title: String
    public var kind: String?
    public var edit: WorkspaceEditPlan?
    public var commandID: String?
    public var isPreferred: Bool

    public init(
        title: String,
        kind: String? = nil,
        edit: WorkspaceEditPlan? = nil,
        commandID: String? = nil,
        isPreferred: Bool = false
    ) {
        self.title = title
        self.kind = kind
        self.edit = edit
        self.commandID = commandID
        self.isPreferred = isPreferred
    }
}

// MARK: - Semantic tokens / inlays / folding / signature / links / colors

public struct SemanticTokenSpan: Sendable, Hashable {
    public var range: CodeEditorCore.TextRange
    public var capture: CaptureName?
    public var rawType: String?
    public var providerID: String?

    public init(
        range: CodeEditorCore.TextRange,
        capture: CaptureName? = nil,
        rawType: String? = nil,
        providerID: String? = nil
    ) {
        self.range = range
        self.capture = capture
        self.rawType = rawType
        self.providerID = providerID
    }
}

public enum InlayHintKind: String, Sendable, Codable, Hashable {
    case type
    case parameter
    case other
}

public struct InlayHint: Sendable, Hashable, Codable {
    public var position: TextPosition
    public var label: String
    public var kind: InlayHintKind?

    public init(position: TextPosition, label: String, kind: InlayHintKind? = nil) {
        self.position = position
        self.label = label
        self.kind = kind
    }
}

public struct FoldingRange: Sendable, Hashable, Codable {
    public var startLine: Int
    public var endLine: Int
    public var startCharacter: Int?
    public var endCharacter: Int?
    public var kind: String?

    public init(
        startLine: Int,
        endLine: Int,
        startCharacter: Int? = nil,
        endCharacter: Int? = nil,
        kind: String? = nil
    ) {
        self.startLine = startLine
        self.endLine = endLine
        self.startCharacter = startCharacter
        self.endCharacter = endCharacter
        self.kind = kind
    }
}

public struct ParameterInformation: Sendable, Hashable, Codable {
    public var label: String
    public var documentation: MarkupContent?

    public init(label: String, documentation: MarkupContent? = nil) {
        self.label = label
        self.documentation = documentation
    }
}

public struct SignatureInformation: Sendable, Hashable, Codable {
    public var label: String
    public var documentation: MarkupContent?
    public var parameters: [ParameterInformation]

    public init(
        label: String,
        documentation: MarkupContent? = nil,
        parameters: [ParameterInformation] = []
    ) {
        self.label = label
        self.documentation = documentation
        self.parameters = parameters
    }
}

public struct SignatureHelp: Sendable, Hashable, Codable {
    public var signatures: [SignatureInformation]
    public var activeSignature: Int
    public var activeParameter: Int

    public init(
        signatures: [SignatureInformation],
        activeSignature: Int = 0,
        activeParameter: Int = 0
    ) {
        self.signatures = signatures
        self.activeSignature = activeSignature
        self.activeParameter = activeParameter
    }
}

public struct DocumentLink: Sendable, Hashable, Codable {
    public var range: CodeEditorCore.TextRange
    public var target: DocumentURI?

    public init(range: CodeEditorCore.TextRange, target: DocumentURI? = nil) {
        self.range = range
        self.target = target
    }
}

public struct ColorValue: Sendable, Hashable, Codable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }
}

public struct ColorInformation: Sendable, Hashable, Codable {
    public var range: CodeEditorCore.TextRange
    public var color: ColorValue

    public init(range: CodeEditorCore.TextRange, color: ColorValue) {
        self.range = range
        self.color = color
    }
}

// MARK: - Document highlights / hierarchy / command / pull diagnostics

public enum DocumentHighlightKind: String, Sendable, Codable, Hashable {
    case text
    case read
    case write
}

public struct DocumentHighlight: Sendable, Hashable, Codable {
    public var range: CodeEditorCore.TextRange
    public var kind: DocumentHighlightKind

    public init(range: CodeEditorCore.TextRange, kind: DocumentHighlightKind = .text) {
        self.range = range
        self.kind = kind
    }
}

public struct HierarchyItem: Sendable, Hashable, Codable {
    public var name: String
    public var kind: SymbolKind
    public var detail: String?
    public var uri: DocumentURI
    public var range: CodeEditorCore.TextRange
    public var selectionRange: CodeEditorCore.TextRange
    public var tags: [String]

    public init(
        name: String,
        kind: SymbolKind,
        detail: String? = nil,
        uri: DocumentURI,
        range: CodeEditorCore.TextRange,
        selectionRange: CodeEditorCore.TextRange,
        tags: [String] = []
    ) {
        self.name = name
        self.kind = kind
        self.detail = detail
        self.uri = uri
        self.range = range
        self.selectionRange = selectionRange
        self.tags = tags
    }
}

public struct CallHierarchyItem: Sendable, Hashable, Codable {
    public var name: String
    public var kind: SymbolKind
    public var detail: String?
    public var uri: DocumentURI
    public var range: CodeEditorCore.TextRange
    public var selectionRange: CodeEditorCore.TextRange

    public init(
        name: String,
        kind: SymbolKind,
        detail: String? = nil,
        uri: DocumentURI,
        range: CodeEditorCore.TextRange,
        selectionRange: CodeEditorCore.TextRange
    ) {
        self.name = name
        self.kind = kind
        self.detail = detail
        self.uri = uri
        self.range = range
        self.selectionRange = selectionRange
    }
}

public struct CallHierarchyIncomingCall: Sendable, Hashable, Codable {
    public var from: CallHierarchyItem
    public var fromRanges: [CodeEditorCore.TextRange]

    public init(from: CallHierarchyItem, fromRanges: [CodeEditorCore.TextRange]) {
        self.from = from
        self.fromRanges = fromRanges
    }
}

public struct CallHierarchyOutgoingCall: Sendable, Hashable, Codable {
    public var to: CallHierarchyItem
    public var fromRanges: [CodeEditorCore.TextRange]

    public init(to: CallHierarchyItem, fromRanges: [CodeEditorCore.TextRange]) {
        self.to = to
        self.fromRanges = fromRanges
    }
}

public struct ExecuteCommandRequest: Sendable, Hashable {
    public var command: String
    public var argumentsJSON: String?
    public var context: LanguageServiceContext

    public init(
        command: String,
        argumentsJSON: String? = nil,
        context: LanguageServiceContext = LanguageServiceContext()
    ) {
        self.command = command
        self.argumentsJSON = argumentsJSON
        self.context = context
    }
}

public struct ExecuteCommandResult: Sendable, Hashable {
    public var appliedEdit: WorkspaceEditPlan?
    public var message: String?

    public init(appliedEdit: WorkspaceEditPlan? = nil, message: String? = nil) {
        self.appliedEdit = appliedEdit
        self.message = message
    }
}

public struct PullDiagnosticsResult: Sendable, Hashable {
    public var kind: String
    public var resultID: String?
    public var items: [LanguageDiagnostic]

    public init(kind: String = "full", resultID: String? = nil, items: [LanguageDiagnostic]) {
        self.kind = kind
        self.resultID = resultID
        self.items = items
    }
}

// MARK: - Limits / health / errors / sanitization

/// Bounds applied by ``LanguageServiceHost`` after provider work.
public struct LanguageServiceLimits: Sendable, Hashable {
    public var providerTimeout: Duration
    public var maxCompletionItems: Int
    public var maxHoverSections: Int
    public var maxDiagnostics: Int
    public var maxLocations: Int
    public var maxSymbols: Int
    public var maxCodeActions: Int
    public var maxSemanticTokens: Int
    public var maxInlayHints: Int
    public var maxFoldingRanges: Int
    public var maxDocumentLinks: Int
    public var maxColors: Int
    public var maxHighlights: Int
    public var maxHierarchyItems: Int
    public var maxMarkupCharacters: Int

    public init(
        providerTimeout: Duration = .seconds(5),
        maxCompletionItems: Int = 500,
        maxHoverSections: Int = 8,
        maxDiagnostics: Int = 2_000,
        maxLocations: Int = 2_000,
        maxSymbols: Int = 5_000,
        maxCodeActions: Int = 200,
        maxSemanticTokens: Int = 50_000,
        maxInlayHints: Int = 5_000,
        maxFoldingRanges: Int = 10_000,
        maxDocumentLinks: Int = 2_000,
        maxColors: Int = 2_000,
        maxHighlights: Int = 2_000,
        maxHierarchyItems: Int = 500,
        maxMarkupCharacters: Int = 32_768
    ) {
        self.providerTimeout = providerTimeout
        self.maxCompletionItems = maxCompletionItems
        self.maxHoverSections = maxHoverSections
        self.maxDiagnostics = maxDiagnostics
        self.maxLocations = maxLocations
        self.maxSymbols = maxSymbols
        self.maxCodeActions = maxCodeActions
        self.maxSemanticTokens = maxSemanticTokens
        self.maxInlayHints = maxInlayHints
        self.maxFoldingRanges = maxFoldingRanges
        self.maxDocumentLinks = maxDocumentLinks
        self.maxColors = maxColors
        self.maxHighlights = maxHighlights
        self.maxHierarchyItems = maxHierarchyItems
        self.maxMarkupCharacters = maxMarkupCharacters
    }

    public static let `default` = LanguageServiceLimits()
}

/// Per-provider health counters observed by the registry / host.
public struct ProviderHealthSnapshot: Sendable, Hashable {
    public var providerID: ProviderID
    public var successCount: UInt64
    public var failureCount: UInt64
    public var timeoutCount: UInt64
    public var cancelCount: UInt64
    public var lastErrorDescription: String?
    public var lastUpdated: Date?

    public init(
        providerID: ProviderID,
        successCount: UInt64 = 0,
        failureCount: UInt64 = 0,
        timeoutCount: UInt64 = 0,
        cancelCount: UInt64 = 0,
        lastErrorDescription: String? = nil,
        lastUpdated: Date? = nil
    ) {
        self.providerID = providerID
        self.successCount = successCount
        self.failureCount = failureCount
        self.timeoutCount = timeoutCount
        self.cancelCount = cancelCount
        self.lastErrorDescription = lastErrorDescription
        self.lastUpdated = lastUpdated
    }
}

public enum LanguageServiceError: Error, Sendable, Equatable {
    case cancelled
    case staleVersion(expected: UInt64, actual: UInt64)
    case unavailable
    case provider(String)
    case timeout(providerID: String)
    case noProvider
    case providerFailed(id: String, message: String)
    case limitExceeded(String)
    case invalidEdit(String)
}

public enum LanguageServiceVersioning {
    public static func ensureCurrent(
        requestVersion: DocumentVersion,
        current: () -> DocumentVersion
    ) throws {
        let now = current()
        if requestVersion != now {
            throw LanguageServiceError.staleVersion(
                expected: requestVersion.rawValue,
                actual: now.rawValue
            )
        }
    }
}

/// Range / edit / markup sanitization for provider results.
public enum LanguageServiceSanitize {
    public static func clampRange(
        _ range: CodeEditorCore.TextRange,
        documentLength: Int
    ) -> CodeEditorCore.TextRange? {
        guard documentLength >= 0 else { return nil }
        // DOC-N05: use overflow-safe end — never bare location+length on untrusted ranges.
        let rawLength = max(0, range.length)
        let rawEnd: Int
        if let safe = try? TextOffsetSemantics.utf16EndOffset(
            location: max(0, range.location),
            length: rawLength
        ) {
            rawEnd = safe
        } else {
            // Arithmetic overflow: fail closed — clamp from bounded location to document end.
            let loc = max(0, min(range.location, documentLength))
            return CodeEditorCore.TextRange(location: loc, length: documentLength - loc)
        }
        let loc = max(0, min(range.location, documentLength))
        let end = max(loc, min(rawEnd, documentLength))
        let length = end - loc
        guard length >= 0 else { return nil }
        if let verified = try? TextOffsetSemantics.utf16EndOffset(location: loc, length: length),
            verified <= documentLength
        {
            if range.location < 0 || range.location > documentLength || range.length < 0
                || rawEnd > documentLength
            {
                return CodeEditorCore.TextRange(location: loc, length: length)
            }
            return range
        }
        return CodeEditorCore.TextRange(location: loc, length: length)
    }

    /// Overflow-safe half-open range intersection (DOC-N05 / semantic-token filters).
    public static func rangesIntersect(
        _ a: CodeEditorCore.TextRange,
        _ b: CodeEditorCore.TextRange
    ) -> Bool {
        // Prefer stored ends (overflow-safe TextRange construction).
        a.location < b.endUTF16Offset && a.endUTF16Offset > b.location
    }

    public static func sanitizeEdit(
        _ edit: TextEditPlan,
        documentLength: Int
    ) -> TextEditPlan? {
        guard let range = clampRange(edit.range, documentLength: documentLength) else {
            return nil
        }
        return TextEditPlan(range: range, newText: edit.newText)
    }

    public static func sanitizeEdits(
        _ edits: [TextEditPlan],
        documentLength: Int
    ) -> [TextEditPlan] {
        edits.compactMap { sanitizeEdit($0, documentLength: documentLength) }
    }

    public static func truncateMarkup(
        _ content: MarkupContent,
        maxCharacters: Int
    ) -> MarkupContent {
        guard maxCharacters > 0, content.value.count > maxCharacters else { return content }
        let idx = content.value.index(content.value.startIndex, offsetBy: maxCharacters)
        return MarkupContent(kind: content.kind, value: String(content.value[..<idx]))
    }

    public static func capped<T>(_ items: [T], max: Int) throws -> [T] {
        guard max >= 0 else { throw LanguageServiceError.limitExceeded("negative max") }
        if items.count <= max { return items }
        return Array(items.prefix(max))
    }
}
