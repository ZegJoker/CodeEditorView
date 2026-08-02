import CodeEditorLanguageSupport
import Foundation
import SwiftTreeSitter

extension CodeLanguage {
    /// Tree-sitter language for this definition, if a grammar is registered.
    ///
    /// Prefer the host-owned ``registry`` parameter (LANG-N07). Defaults to
    /// ``LanguageRegistry/shared`` for bootstrap compatibility.
    public func tsLanguage(registry: LanguageRegistry = .shared) -> Language? {
        guard let pointer = registry.parser(for: languageID) else { return nil }
        return Language(language: pointer)
    }

    /// Owned language handle documenting static grammar lifetime (LANG-N04).
    public func languageRef(registry: LanguageRegistry = .shared) -> TSLanguageRef? {
        registry.languageRef(for: languageID)
    }

    /// Tree-sitter language via the shared registry (compatibility).
    public var tsLanguage: Language? {
        tsLanguage(registry: .shared)
    }
}
