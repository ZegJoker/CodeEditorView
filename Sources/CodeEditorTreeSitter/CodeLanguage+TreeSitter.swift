import CodeEditorLanguageSupport
import Foundation
import SwiftTreeSitter

extension CodeLanguage {
    /// Tree-sitter language for this definition, if a grammar is registered in ``LanguageRegistry``.
    public var tsLanguage: Language? {
        guard let pointer = LanguageRegistry.shared.parser(for: languageID) else { return nil }
        return Language(language: pointer)
    }
}
