import Foundation

/// Actionable failure when a language pack cannot locate committed grammar/query artifacts.
///
/// PKG-001: language packs must not silently skip missing resources.
public enum LanguagePackError: Error, Sendable, Equatable, CustomStringConvertible {
    /// Required Tree-sitter query (`.scm`) was not found in the pack resource bundle.
    case missingQuery(language: LanguageID, query: String, searchedPaths: [String])
    /// Grammar / pack artifact missing or unreadable.
    case missingGrammarArtifact(language: LanguageID, detail: String)

    public var description: String {
        switch self {
        case .missingQuery(let language, let query, let searchedPaths):
            let paths = searchedPaths.isEmpty ? "(no paths recorded)" : searchedPaths.joined(separator: ", ")
            return "Language pack \(language.rawValue): missing query '\(query).scm'. Searched: \(paths)"
        case .missingGrammarArtifact(let language, let detail):
            return "Language pack \(language.rawValue): missing grammar artifact — \(detail)"
        }
    }
}

/// Process-wide record of language-pack registration failures from static initializers.
public enum LanguagePackRegistration: Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _errors: [LanguagePackError] = []

    public static func record(_ error: LanguagePackError) {
        lock.lock()
        defer { lock.unlock() }
        _errors.append(error)
    }

    public static var errors: [LanguagePackError] {
        lock.lock()
        defer { lock.unlock() }
        return _errors
    }

    public static func resetForTests() {
        lock.lock()
        defer { lock.unlock() }
        _errors = []
    }
}
