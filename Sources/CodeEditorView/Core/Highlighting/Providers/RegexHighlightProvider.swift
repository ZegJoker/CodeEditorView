import CodeEditorLanguageSupport
import Foundation

/// Simple regex-based highlight provider for tests and lightweight demos.
@MainActor
public final class RegexHighlightProvider: HighlightProviding {
    public struct Rule: Sendable {
        public var pattern: String
        public var capture: CaptureName
        public var options: NSRegularExpression.Options

        public init(
            pattern: String,
            capture: CaptureName,
            options: NSRegularExpression.Options = []
        ) {
            self.pattern = pattern
            self.capture = capture
            self.options = options
        }
    }

    private var rules: [(NSRegularExpression, CaptureName)]
    private var documentLength: Int = 0

    public init(rules: [Rule]) {
        self.rules = rules.compactMap { rule in
            guard let regex = try? NSRegularExpression(pattern: rule.pattern, options: rule.options) else {
                return nil
            }
            return (regex, rule.capture)
        }
    }

    /// Lightweight multi-language defaults for demos (Swift/TS/JS/C-family-ish).
    ///
    /// Rules are ordered carefully so longer/more-specific matches win when the
    /// style container applies later ranges over earlier ones.
    public static func swiftLike() -> RegexHighlightProvider {
        RegexHighlightProvider(rules: [
            // Block comments before line comments / strings.
            .init(pattern: #"/\*[\s\S]*?\*/"#, capture: .comment),
            .init(pattern: #"//[^\n]*"#, capture: .comment),
            .init(pattern: #"#(?:[^\n]*)"#, capture: .comment),  // python/ruby/shell-ish
            // Strings (simple double/single quotes).
            .init(pattern: #""([^"\\]|\\.)*""#, capture: .string),
            .init(pattern: #"'([^'\\]|\\.)*'"#, capture: .string),
            .init(pattern: #"`([^`\\]|\\.)*`"#, capture: .string),
            // Keywords (common across Swift / TS / JS / C-like).
            .init(
                pattern:
                    #"\b(func|function|fn|def|let|var|const|if|else|return|import|export|from|struct|class|enum|protocol|interface|type|guard|switch|case|for|while|in|of|true|false|nil|null|undefined|self|this|async|await|throws|try|catch|public|private|static|void|string|int|bool|new|as|is)\b"#,
                capture: .keyword
            ),
            .init(pattern: #"\b\d+(?:\.\d+)?\b"#, capture: .number),
            // Types: Capitalized identifiers (applied last so they don't eat keywords).
            .init(pattern: #"\b[A-Z][A-Za-z0-9_]*\b"#, capture: .type),
        ])
    }

    public func setUp(documentLength: Int, languageID: String?) async {
        self.documentLength = max(0, documentLength)
    }

    public func applyEdit(range: NSRange, delta: Int) async throws -> IndexSet {
        documentLength = max(0, documentLength + delta)
        let start = max(0, range.location - 64)
        let end = min(documentLength, range.location + max(range.length + delta, 0) + 64)
        return IndexSet(integersIn: start..<max(start, end))
    }

    public func queryHighlights(in range: NSRange, text: String) async throws -> [HighlightRange] {
        try Task.checkCancellation()
        guard range.length > 0, !text.isEmpty else { return [] }

        let ns = text as NSString
        let local = NSRange(location: 0, length: ns.length)
        var results: [HighlightRange] = []

        for (regex, capture) in rules {
            try Task.checkCancellation()
            regex.enumerateMatches(in: text, options: [], range: local) { match, _, _ in
                guard let match else { return }
                let global = NSRange(
                    location: range.location + match.range.location,
                    length: match.range.length
                )
                results.append(HighlightRange(range: global, capture: capture))
            }
        }

        results.sort { $0.range.location < $1.range.location }
        return results
    }
}
