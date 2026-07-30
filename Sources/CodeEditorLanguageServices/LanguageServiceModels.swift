import Foundation
import CodeEditorCore
import CodeEditorDocuments
import CodeEditorLanguageSupport

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

// MARK: - Errors / versioning

public enum LanguageServiceError: Error, Sendable, Equatable {
    case cancelled
    case staleVersion(expected: UInt64, actual: UInt64)
    case unavailable
    case provider(String)
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
