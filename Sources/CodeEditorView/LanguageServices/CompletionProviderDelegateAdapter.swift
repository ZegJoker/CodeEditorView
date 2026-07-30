import Foundation
import CodeEditorCore
import CodeEditorDocuments
import CodeEditorLanguageServices

/// Bridges ``LanguageServiceHost`` completions into the editor's ``CodeSuggestionDelegate``.
@MainActor
public final class CompletionProviderDelegateAdapter: CodeSuggestionDelegate {
    public let host: LanguageServiceHost
    public var context: LanguageServiceContext
    public var triggerCharacters: Set<String>
    /// Last items returned (used for fast cursor-move filtering).
    private var lastItems: [LanguageCompletionItem] = []

    public init(
        host: LanguageServiceHost,
        context: LanguageServiceContext = LanguageServiceContext(),
        triggerCharacters: Set<String> = ["."]
    ) {
        self.host = host
        self.context = context
        self.triggerCharacters = triggerCharacters
    }

    public func completionTriggerCharacters() -> Set<String> { triggerCharacters }

    public func completionSuggestionsRequested(
        textView: EditorController,
        cursorPosition: CursorPosition
    ) async -> (windowPosition: CursorPosition, items: [any CodeSuggestionEntry])? {
        let snapshot = textView.textDocument.snapshot()
        var ctx = context
        if ctx.languageID == nil {
            ctx.languageID = textView.languageID
        }
        if ctx.uri == nil {
            ctx.uri = textView.textDocument.uri
        }

        let request = CompletionRequest(
            document: snapshot,
            position: TextPosition(utf16Offset: cursorPosition.range.location),
            trigger: .invoked,
            context: ctx
        )
        do {
            // Host version checks use the request snapshot; discard if the live doc moved on.
            let list = try await host.completions(for: request) { snapshot.version }
            guard textView.textDocument.version == snapshot.version else { return nil }

            let items = list.items.map { LanguageCompletionItem(item: $0) }
            lastItems = items
            return items.isEmpty ? nil : (cursorPosition, items)
        } catch {
            return nil
        }
    }

    public func completionOnCursorMove(
        textView: EditorController,
        cursorPosition: CursorPosition
    ) -> [any CodeSuggestionEntry]? {
        let prefix = Self.wordPrefix(at: cursorPosition.range.location, in: textView.text)
        guard !prefix.isEmpty else { return nil }
        let filtered = lastItems.filter {
            $0.label.lowercased().hasPrefix(prefix.lowercased())
                || ($0.item.filterText?.lowercased().hasPrefix(prefix.lowercased()) ?? false)
        }
        return filtered.isEmpty ? nil : filtered
    }

    public func completionWindowApplyCompletion(
        item: any CodeSuggestionEntry,
        textView: EditorController,
        cursorPosition: CursorPosition?
    ) {
        let loc = cursorPosition?.range.location ?? textView.selectedRange.location

        if let languageItem = item as? LanguageCompletionItem {
            apply(languageItem: languageItem, textView: textView, caretUTF16: loc)
            return
        }

        // Fallback: simple prefix replace with label.
        let prefix = Self.wordPrefix(at: loc, in: textView.text)
        let start = loc - prefix.utf16.count
        textView.replaceCharacters(
            in: NSRange(location: max(0, start), length: prefix.utf16.count),
            with: item.label
        )
    }

    /// Applies a language-service completion using ``TextEditPlan`` when present.
    public static func apply(
        languageItem: LanguageCompletionItem,
        textView: EditorController,
        caretUTF16: Int
    ) {
        // Additional edits first (high → low) so primary edit ranges stay valid.
        let additional = languageItem.additionalTextEdits.sorted {
            $0.range.location > $1.range.location
        }
        for edit in additional {
            textView.replaceCharacters(in: edit.range.nsRange, with: edit.newText)
        }

        if let primary = languageItem.textEdit {
            textView.replaceCharacters(in: primary.range.nsRange, with: primary.newText)
            return
        }

        let prefix = wordPrefix(at: caretUTF16, in: textView.text)
        let start = caretUTF16 - prefix.utf16.count
        textView.replaceCharacters(
            in: NSRange(location: max(0, start), length: prefix.utf16.count),
            with: languageItem.insertText
        )
    }

    private func apply(
        languageItem: LanguageCompletionItem,
        textView: EditorController,
        caretUTF16: Int
    ) {
        Self.apply(languageItem: languageItem, textView: textView, caretUTF16: caretUTF16)
    }

    public static func wordPrefix(at location: Int, in text: String) -> String {
        let ns = text as NSString
        var i = min(max(0, location), ns.length)
        var chars: [Character] = []
        while i > 0 {
            let ch = ns.substring(with: NSRange(location: i - 1, length: 1))
            guard let c = ch.first, c.isLetter || c.isNumber || c == "_" else { break }
            chars.insert(c, at: 0)
            i -= 1
        }
        return String(chars)
    }
}
