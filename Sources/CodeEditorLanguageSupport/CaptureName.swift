import Foundation

/// Semantic token names used for theme attribute lookup and syntax highlighting.
public enum CaptureName: String, Sendable, Hashable, CaseIterable {
    case keyword
    case keywordReturn = "keyword.return"
    case keywordFunction = "keyword.function"
    case comment
    case `variable`
    case variableBuiltin = "variable.builtin"
    case property
    case function
    case method
    case number
    case float
    case string
    case type
    case typeAlternate = "type.alternate"
    case parameter
    case constructor
    case boolean
    case `include`
    case `repeat`
    case conditional
    case tag
    case character
    case command
    case attribute
    case value
    case text
    case `operator`
    case punctuation
    case constant

    /// Maps a tree-sitter-style capture string (e.g. `"keyword.return"`, `"@type.builtin"`) to a known name.
    ///
    /// Returns `nil` only for captures that should not be painted (e.g. `none`).
    public static func from(capture: String) -> CaptureName? {
        var normalized = capture.hasPrefix("@") ? String(capture.dropFirst()) : capture
        // Some queries use dotted paths with trailing modifiers.
        normalized = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }

        if normalized == "none" || normalized.hasPrefix("none.") {
            return nil
        }

        if let exact = CaptureName(rawValue: normalized) {
            return exact
        }

        let parts = normalized.split(separator: ".").map(String.init)
        if parts.count >= 2 {
            let compound = parts[0] + "." + parts[1]
            if let match = CaptureName(rawValue: compound) {
                return match
            }
        }

        let root = parts.first ?? normalized
        switch root {
        case "keyword", "conditional", "repeat", "include", "import", "export",
             "storage", "directive", "preproc", "module":
            return .keyword
        case "comment", "documentation":
            return .comment
        case "string", "character", "regex", "escape":
            return root == "character" ? .character : .string
        case "number", "float", "integer":
            return .number
        case "type", "class", "struct", "enum", "interface", "namespace",
             "constructor", "type_identifier":
            return root == "constructor" ? .constructor : .type
        case "function", "method", "call", "procedure":
            return .function
        case "variable", "identifier", "constant", "field", "property",
             "parameter", "argument", "symbol":
            if root == "constant" { return .constant }
            if root == "property" || root == "field" { return .property }
            if root == "parameter" || root == "argument" { return .parameter }
            return .variable
        case "boolean", "null", "nil", "true", "false":
            return .boolean
        case "attribute", "annotation", "decorator", "label", "tag":
            return root == "tag" ? .tag : .attribute
        case "operator":
            return .operator
        case "punctuation", "bracket", "delimiter", "separator":
            return .punctuation
        case "value", "literal":
            return .value
        case "text", "spell", "markup", "title", "emphasis", "strong":
            return .text
        default:
            // Prefer painting something over dropping the capture entirely.
            if let match = CaptureName(rawValue: root) {
                return match
            }
            return .text
        }
    }
}
