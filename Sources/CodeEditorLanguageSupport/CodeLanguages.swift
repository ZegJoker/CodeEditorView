import Foundation

/// Registry and lookup helpers for ``CodeLanguage`` catalog metadata.
///
/// Highlight configuration compilation lives in the umbrella / Tree-sitter layers
/// (see language pack bootstrap). Metadata lookup here never links grammars.
public enum CodeLanguages: Sendable {
    public static var all: [CodeLanguage] { CodeLanguage.allLanguages }

    /// Languages with a tree-sitter parser currently registered in ``LanguageRegistry``.
    public static var highlightable: [CodeLanguage] {
        CodeLanguage.allLanguages.filter {
            $0.id != .plainText && LanguageRegistry.shared.hasParser(for: $0.languageID)
        }
    }

    public static func language(id: String) -> CodeLanguage? {
        let key = id.lowercased()
        // Prefer exact ID match so `typescript` does not resolve to TSX (shared tsName).
        if let exact = all.first(where: { $0.id.rawValue.lowercased() == key }) {
            return exact
        }
        return all.first {
            $0.tsName == key
                || $0.aliases.contains(key)
                || $0.displayName.lowercased() == key
        }
    }

    public static func language(id: TreeSitterLanguageID) -> CodeLanguage? {
        all.first { $0.id == id }
    }

    public static func language(id: LanguageID) -> CodeLanguage? {
        language(id: id.rawValue)
    }

    public static func language(forFileExtension ext: String) -> CodeLanguage? {
        let key = ext.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if key == "dockerfile" { return .dockerfile }
        return all.first { $0.extensions.contains(key) }
    }
}
