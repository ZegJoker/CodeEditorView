import CodeEditorCore
import CodeEditorDocuments
import CodeEditorLanguageServices
import CodeEditorLanguageSupport
import Foundation

// Internal LSP wire types (subset). Not part of the public module API surface intent,
// but SwiftPM modules make them public by default — treat as implementation detail.

struct LSPPosition: Codable, Sendable, Hashable {
    var line: Int
    var character: Int
}

struct LSPRange: Codable, Sendable, Hashable {
    var start: LSPPosition
    var end: LSPPosition
}

struct LSPTextEdit: Codable, Sendable, Hashable {
    var range: LSPRange
    var newText: String
}

struct LSPLocation: Codable, Sendable, Hashable {
    var uri: String
    var range: LSPRange
}

struct LSPLocationLink: Codable, Sendable, Hashable {
    var originSelectionRange: LSPRange?
    var targetUri: String
    var targetRange: LSPRange
    var targetSelectionRange: LSPRange?
}

struct LSPMarkupContent: Codable, Sendable, Hashable {
    var kind: String
    var value: String
}

// MARK: - Conversion helpers

enum LSPConvert {
    static func position(_ p: TextPosition, in text: String) -> LSPPosition {
        lineCharacter(utf16Offset: p.utf16Offset, in: text)
    }

    static func range(_ r: CodeEditorCore.TextRange, in text: String) -> LSPRange {
        LSPRange(
            start: position(r.start, in: text),
            end: position(r.end, in: text)
        )
    }

    static func textPosition(_ p: LSPPosition, in text: String) -> TextPosition {
        TextPosition(utf16Offset: utf16Offset(line: p.line, character: p.character, in: text))
    }

    static func textRange(_ r: LSPRange, in text: String) -> CodeEditorCore.TextRange {
        CodeEditorCore.TextRange(
            start: textPosition(r.start, in: text),
            end: textPosition(r.end, in: text)
        )
    }

    static func lineCharacter(utf16Offset: Int, in text: String) -> LSPPosition {
        let ns = text as NSString
        // DOC-003: clamp only out-of-bounds carets; never invent mid-document EOF redirects.
        let loc: Int
        if TextOffsetSemantics.isValidUTF16Offset(utf16Offset, documentUTF16Length: ns.length) {
            loc = utf16Offset
        } else if utf16Offset < 0 {
            loc = 0
        } else {
            loc = ns.length
        }
        var line = 0
        var lineStart = 0
        var i = 0
        while i < loc {
            let ch = ns.character(at: i)
            i += 1
            if ch == 0x0A {
                line += 1
                lineStart = i
            } else if ch == 0x0D {
                if i < ns.length, ns.character(at: i) == 0x0A { i += 1 }
                line += 1
                lineStart = i
            }
        }
        return LSPPosition(line: line, character: max(0, loc - lineStart))
    }

    static func utf16Offset(line: Int, character: Int, in text: String) -> Int {
        let ns = text as NSString
        var currentLine = 0
        var i = 0
        let targetLine = max(0, line)
        while i < ns.length && currentLine < targetLine {
            let ch = ns.character(at: i)
            i += 1
            if ch == 0x0A {
                currentLine += 1
            } else if ch == 0x0D {
                if i < ns.length, ns.character(at: i) == 0x0A { i += 1 }
                currentLine += 1
            }
        }
        // Advance character within line (UTF-16)
        let lineStart = i
        var col = 0
        while i < ns.length && col < character {
            let ch = ns.character(at: i)
            if ch == 0x0A || ch == 0x0D { break }
            i += 1
            col += 1
        }
        _ = lineStart
        // Result is always a valid caret offset in [0, length].
        return i
    }

    static func textEditPlan(_ edit: LSPTextEdit, in text: String) -> TextEditPlan {
        TextEditPlan(range: textRange(edit.range, in: text), newText: edit.newText)
    }

    static func location(_ loc: LSPLocation, textForTarget: String) -> Location {
        Location(
            uri: DocumentURI(rawValue: loc.uri),
            range: textRange(loc.range, in: textForTarget)
        )
    }

    static func locationLink(_ link: LSPLocationLink, textForTarget: String) -> LocationLink {
        LocationLink(
            targetURI: DocumentURI(rawValue: link.targetUri),
            targetRange: textRange(link.targetRange, in: textForTarget),
            targetSelectionRange: link.targetSelectionRange.map { textRange($0, in: textForTarget) },
            originSelectionRange: link.originSelectionRange.map { textRange($0, in: textForTarget) }
        )
    }

    static func diagnostic(
        _ d: LSPDiagnostic,
        in text: String
    ) -> LanguageDiagnostic {
        LanguageDiagnostic(
            range: textRange(d.range, in: text),
            severity: mapSeverity(d.severity),
            message: d.message,
            code: d.codeString,
            source: d.source
        )
    }

    static func mapSeverity(_ raw: Int?) -> LanguageDiagnosticSeverity {
        switch raw {
        case 1: return .error
        case 2: return .warning
        case 3: return .information
        case 4: return .hint
        default: return .information
        }
    }

    static func completionItem(_ item: LSPCompletionItem, in text: String) -> CompletionItem {
        let kind = mapCompletionKind(item.kind)
        var documentation: MarkupContent?
        if let doc = item.documentation {
            switch doc {
            case .string(let s):
                documentation = .plain(s)
            case .markup(let m):
                documentation = MarkupContent(
                    kind: m.kind == "markdown" ? .markdown : .plaintext,
                    value: m.value
                )
            }
        }
        let textEdit: TextEditPlan?
        if let te = item.textEdit {
            textEdit = textEditPlan(te, in: text)
        } else {
            textEdit = nil
        }
        return CompletionItem(
            label: item.label,
            kind: kind,
            detail: item.detail,
            documentation: documentation,
            insertText: item.insertText,
            textEdit: textEdit,
            additionalTextEdits: (item.additionalTextEdits ?? []).map { textEditPlan($0, in: text) },
            sortText: item.sortText,
            filterText: item.filterText,
            commandID: item.command?.command
        )
    }

    static func mapCompletionKind(_ raw: Int?) -> CompletionItemKind? {
        guard let raw else { return nil }
        // LSP CompletionItemKind 1...25
        let all = CompletionItemKind.allCases
        let index = raw - 1
        guard index >= 0, index < all.count else { return .text }
        return all[index]
    }

    static func captureName(tokenType: String?) -> CaptureName? {
        guard let tokenType else { return nil }
        return CaptureName.from(capture: tokenType)
    }
}

// MARK: - Wire models used by adapters

struct LSPDiagnostic: Codable, Sendable {
    var range: LSPRange
    var severity: Int?
    var code: LSPDiagnosticCode?
    var source: String?
    var message: String

    var codeString: String? {
        switch code {
        case .int(let i): return String(i)
        case .string(let s): return s
        case .none: return nil
        }
    }
}

enum LSPDiagnosticCode: Codable, Sendable {
    case int(Int)
    case string(String)

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let i = try? c.decode(Int.self) {
            self = .int(i)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "code")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .int(let i): try c.encode(i)
        case .string(let s): try c.encode(s)
        }
    }
}

struct LSPPublishDiagnosticsParams: Codable, Sendable {
    var uri: String
    var version: Int?
    var diagnostics: [LSPDiagnostic]
}

struct LSPCompletionItem: Codable, Sendable {
    var label: String
    var kind: Int?
    var detail: String?
    var documentation: LSPCompletionDocumentation?
    var insertText: String?
    var textEdit: LSPTextEdit?
    var additionalTextEdits: [LSPTextEdit]?
    var sortText: String?
    var filterText: String?
    var command: LSPCommand?
}

enum LSPCompletionDocumentation: Codable, Sendable {
    case string(String)
    case markup(LSPMarkupContent)

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let m = try? c.decode(LSPMarkupContent.self) {
            self = .markup(m)
        } else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "documentation")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .markup(let m): try c.encode(m)
        }
    }
}

struct LSPCommand: Codable, Sendable {
    var title: String
    var command: String
}

struct LSPCompletionList: Codable, Sendable {
    var isIncomplete: Bool?
    var items: [LSPCompletionItem]
}

struct LSPHover: Codable, Sendable {
    var contents: LSPHoverContents
    var range: LSPRange?
}

enum LSPHoverContents: Codable, Sendable {
    case markup(LSPMarkupContent)
    case markedString(String)
    case markedStringArray([String])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let m = try? c.decode(LSPMarkupContent.self) {
            self = .markup(m)
        } else if let s = try? c.decode(String.self) {
            self = .markedString(s)
        } else if let arr = try? c.decode([String].self) {
            self = .markedStringArray(arr)
        } else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "hover contents")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .markup(let m): try c.encode(m)
        case .markedString(let s): try c.encode(s)
        case .markedStringArray(let a): try c.encode(a)
        }
    }
}

struct LSPSemanticTokens: Codable, Sendable {
    var resultId: String?
    var data: [UInt32]
}

struct LSPTextEditResult: Codable, Sendable {
    // array of text edits at top level handled as [LSPTextEdit]
}

/// LSP textDocumentSync change kind (LSP-N04).
public enum TextDocumentSyncKind: Int, Sendable, Hashable, Codable {
    case none = 0
    case full = 1
    case incremental = 2
}

// Capabilities snapshot (public)
public struct ServerCapabilitiesSnapshot: Sendable, Hashable {
    public var completion: Bool
    public var completionResolve: Bool
    public var hover: Bool
    public var definition: Bool
    public var declaration: Bool
    public var implementation: Bool
    public var references: Bool
    public var diagnostics: Bool
    public var pullDiagnostics: Bool
    public var documentSymbol: Bool
    public var workspaceSymbol: Bool
    public var formatting: Bool
    public var rangeFormatting: Bool
    public var rename: Bool
    public var codeAction: Bool
    public var codeActionResolve: Bool
    public var semanticTokens: Bool
    public var semanticTokensRange: Bool
    public var semanticTokensDelta: Bool
    public var foldingRange: Bool
    public var signatureHelp: Bool
    public var documentLink: Bool
    public var documentColor: Bool
    public var inlayHint: Bool
    public var inlayHintResolve: Bool
    public var documentHighlight: Bool
    public var typeHierarchy: Bool
    public var callHierarchy: Bool
    public var executeCommand: Bool
    public var incrementalSync: Bool
    public var textDocumentSyncKind: TextDocumentSyncKind
    public var workspaceFolders: Bool
    public var supportedCommands: [String]

    public static let empty = ServerCapabilitiesSnapshot(
        completion: false, completionResolve: false, hover: false, definition: false,
        declaration: false, implementation: false, references: false, diagnostics: false,
        pullDiagnostics: false, documentSymbol: false, workspaceSymbol: false,
        formatting: false, rangeFormatting: false, rename: false, codeAction: false,
        codeActionResolve: false, semanticTokens: false, semanticTokensRange: false,
        semanticTokensDelta: false, foldingRange: false, signatureHelp: false,
        documentLink: false, documentColor: false, inlayHint: false, inlayHintResolve: false,
        documentHighlight: false, typeHierarchy: false, callHierarchy: false,
        executeCommand: false, incrementalSync: false, textDocumentSyncKind: .none,
        workspaceFolders: false,
        supportedCommands: []
    )

    static func parse(from result: [String: Any]) -> ServerCapabilitiesSnapshot {
        let caps = result["capabilities"] as? [String: Any] ?? result
        func has(_ key: String) -> Bool {
            if caps[key] is Bool { return caps[key] as? Bool ?? false }
            return caps[key] != nil
        }
        var syncKind: TextDocumentSyncKind = .none
        if let sync = caps["textDocumentSync"] as? Int {
            syncKind = TextDocumentSyncKind(rawValue: sync) ?? .none
        } else if let sync = caps["textDocumentSync"] as? [String: Any] {
            if let change = sync["change"] as? Int {
                syncKind = TextDocumentSyncKind(rawValue: change) ?? .none
            } else if sync["openClose"] as? Bool == true {
                syncKind = .full
            }
        }
        let incremental = syncKind == .incremental
        let completionProvider = caps["completionProvider"] as? [String: Any]
        let completionResolve = completionProvider?["resolveProvider"] as? Bool ?? false
        let codeActionProvider = caps["codeActionProvider"]
        var codeActionResolve = false
        if let dict = codeActionProvider as? [String: Any] {
            codeActionResolve = dict["resolveProvider"] as? Bool ?? false
        }
        let semantic = caps["semanticTokensProvider"] as? [String: Any]
        var tokensFull = has("semanticTokensProvider")
        var tokensRange = false
        var tokensDelta = false
        if let semantic {
            tokensFull = true
            if let full = semantic["full"] as? Bool {
                tokensFull = full
            } else if let full = semantic["full"] as? [String: Any] {
                tokensFull = true
                tokensDelta = full["delta"] as? Bool ?? false
            }
            if semantic["range"] is Bool || semantic["range"] is [String: Any] {
                tokensRange = true
            }
        }
        let inlay = caps["inlayHintProvider"] as? [String: Any]
        let inlayResolve = inlay?["resolveProvider"] as? Bool ?? false
        let exec = caps["executeCommandProvider"] as? [String: Any]
        let commands = exec?["commands"] as? [String] ?? []
        let workspace = caps["workspace"] as? [String: Any]
        let folders = workspace?["workspaceFolders"]
        let foldersSupported: Bool
        if let b = folders as? Bool {
            foldersSupported = b
        } else {
            foldersSupported = folders != nil
        }
        let diagnosticProvider = caps["diagnosticProvider"]
        return ServerCapabilitiesSnapshot(
            completion: has("completionProvider"),
            completionResolve: completionResolve,
            hover: has("hoverProvider"),
            definition: has("definitionProvider"),
            declaration: has("declarationProvider"),
            implementation: has("implementationProvider"),
            references: has("referencesProvider"),
            diagnostics: true,
            pullDiagnostics: diagnosticProvider != nil,
            documentSymbol: has("documentSymbolProvider"),
            workspaceSymbol: has("workspaceSymbolProvider"),
            formatting: has("documentFormattingProvider"),
            rangeFormatting: has("documentRangeFormattingProvider"),
            rename: has("renameProvider"),
            codeAction: has("codeActionProvider"),
            codeActionResolve: codeActionResolve,
            semanticTokens: tokensFull,
            semanticTokensRange: tokensRange,
            semanticTokensDelta: tokensDelta,
            foldingRange: has("foldingRangeProvider"),
            signatureHelp: has("signatureHelpProvider"),
            documentLink: has("documentLinkProvider"),
            documentColor: has("colorProvider"),
            inlayHint: has("inlayHintProvider"),
            inlayHintResolve: inlayResolve,
            documentHighlight: has("documentHighlightProvider"),
            typeHierarchy: has("typeHierarchyProvider"),
            callHierarchy: has("callHierarchyProvider"),
            executeCommand: has("executeCommandProvider"),
            incrementalSync: incremental,
            textDocumentSyncKind: syncKind,
            workspaceFolders: foldersSupported,
            supportedCommands: commands
        )
    }
}
