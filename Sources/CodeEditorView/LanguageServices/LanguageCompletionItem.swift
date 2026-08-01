import CodeEditorCore
import CodeEditorLanguageServices
import Foundation

/// ``CodeSuggestionEntry`` backed by a language-service ``CompletionItem``.
public final class LanguageCompletionItem: CodeSuggestionEntry {
    public let item: CompletionItem
    public let providerID: ProviderID?

    public var label: String { item.label }
    public var detail: String? { item.detail }
    public var documentation: String? { item.documentation?.value }
    public var systemImage: String { Self.systemImage(for: item.kind) }
    public var imageColorToken: SuggestionImageColorToken { Self.imageColor(for: item.kind) }

    public init(item: CompletionItem, providerID: ProviderID? = nil) {
        self.item = item
        self.providerID = providerID
    }

    /// Preferred insert/replace text from the language-service item.
    public var insertText: String {
        item.insertText ?? item.textEdit?.newText ?? item.label
    }

    /// Optional primary text edit plan (hosts apply; completion never mutates the buffer itself).
    public var textEdit: TextEditPlan? { item.textEdit }
    public var additionalTextEdits: [TextEditPlan] { item.additionalTextEdits }

    public static func systemImage(for kind: CompletionItemKind?) -> String {
        switch kind {
        case .method, .function: return "function"
        case .constructor: return "plus.square"
        case .field, .variable, .property: return "v.square"
        case .class, .struct, .interface, .enum: return "s.square"
        case .module, .file, .folder: return "folder"
        case .keyword: return "k.square"
        case .snippet: return "text.badge.plus"
        case .constant, .enumMember: return "c.square"
        case .operator: return "plus.forwardslash.minus"
        case .typeParameter: return "t.square"
        default: return "character.cursor.ibeam"
        }
    }

    public static func imageColor(for kind: CompletionItemKind?) -> SuggestionImageColorToken {
        switch kind {
        case .method, .function, .constructor: return .purple
        case .class, .struct, .interface, .enum, .typeParameter: return .blue
        case .keyword: return .pink
        case .variable, .field, .property: return .green
        case .constant, .enumMember: return .orange
        case .snippet: return .yellow
        default: return .gray
        }
    }
}
