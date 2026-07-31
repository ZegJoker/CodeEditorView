import Foundation

/// Diagnostic produced while parsing a when-clause string.
public struct WhenClauseDiagnostic: Sendable, Hashable, Equatable {
    public var message: String
    public var offset: Int
    public var length: Int

    public init(message: String, offset: Int, length: Int = 0) {
        self.message = message
        self.offset = offset
        self.length = length
    }
}

public struct WhenClauseParseResult: Sendable, Hashable {
    public var expression: ContextExpression
    public var diagnostics: [WhenClauseDiagnostic]

    public init(expression: ContextExpression, diagnostics: [WhenClauseDiagnostic] = []) {
        self.expression = expression
        self.diagnostics = diagnostics
    }
}

/// Parses VS Code–style when-clause strings into ``ContextExpression``.
///
/// Supported:
/// - `true` / `false` / `always` / `never`
/// - `editorTextFocus`, `editorHasSelection`, `editorReadonly` (mapped)
/// - `resourceExtname == .swift` → language (best-effort)
/// - `!expr`, `a && b`, `a || b`, parentheses
/// - bare identifiers → ``ContextExpression/key(_:)`` (unknown → false at eval)
public enum WhenClauseParser {
    public static func parse(_ source: String) -> WhenClauseParseResult {
        var lexer = Lexer(source: source)
        let tokens = lexer.tokenize()
        var parser = Parser(tokens: tokens, source: source)
        do {
            let expr = try parser.parseExpression()
            if parser.hasMore {
                parser.diagnostics.append(
                    WhenClauseDiagnostic(message: "Unexpected trailing tokens", offset: parser.currentOffset)
                )
            }
            return WhenClauseParseResult(expression: expr, diagnostics: parser.diagnostics)
        } catch {
            return WhenClauseParseResult(
                expression: .never,
                diagnostics: parser.diagnostics.isEmpty
                    ? [WhenClauseDiagnostic(message: String(describing: error), offset: 0)]
                    : parser.diagnostics
            )
        }
    }
}

// MARK: - Lexer / Parser (private)

private enum TokenKind: Equatable {
    case ident(String)
    case and, or, not
    case lparen, rparen
    case eq, neq
    case string(String)
    case eof
}

private struct Token {
    var kind: TokenKind
    var offset: Int
}

private struct Lexer {
    let source: String
    var index: String.Index
    var offset: Int = 0

    init(source: String) {
        self.source = source
        self.index = source.startIndex
    }

    mutating func tokenize() -> [Token] {
        var tokens: [Token] = []
        while index < source.endIndex {
            skipWhitespace()
            guard index < source.endIndex else { break }
            let start = offset
            let c = source[index]
            if c == "(" { advance(); tokens.append(Token(kind: .lparen, offset: start)); continue }
            if c == ")" { advance(); tokens.append(Token(kind: .rparen, offset: start)); continue }
            if c == "!" { advance(); tokens.append(Token(kind: .not, offset: start)); continue }
            if c == "&", peekNext() == "&" {
                advance(); advance()
                tokens.append(Token(kind: .and, offset: start))
                continue
            }
            if c == "|", peekNext() == "|" {
                advance(); advance()
                tokens.append(Token(kind: .or, offset: start))
                continue
            }
            if c == "=", peekNext() == "=" {
                advance(); advance()
                tokens.append(Token(kind: .eq, offset: start))
                continue
            }
            if c == "!", peekNext() == "=" {
                // already handled ! alone — use !=
            }
            if c == "!", index < source.endIndex {
                let n = source.index(after: index)
                if n < source.endIndex, source[n] == "=" {
                    advance(); advance()
                    tokens.append(Token(kind: .neq, offset: start))
                    continue
                }
            }
            if c == "'" || c == "\"" {
                let quote = c
                advance()
                var s = ""
                while index < source.endIndex, source[index] != quote {
                    s.append(source[index])
                    advance()
                }
                if index < source.endIndex { advance() }
                tokens.append(Token(kind: .string(s), offset: start))
                continue
            }
            if c.isLetter || c == "_" || c == "." {
                var s = ""
                while index < source.endIndex {
                    let ch = source[index]
                    if ch.isLetter || ch.isNumber || ch == "_" || ch == "." || ch == "-" {
                        s.append(ch)
                        advance()
                    } else {
                        break
                    }
                }
                tokens.append(Token(kind: .ident(s), offset: start))
                continue
            }
            // Skip unknown character
            advance()
        }
        tokens.append(Token(kind: .eof, offset: offset))
        return tokens
    }

    private mutating func advance() {
        guard index < source.endIndex else { return }
        index = source.index(after: index)
        offset += 1
    }

    private func peekNext() -> Character? {
        guard index < source.endIndex else { return nil }
        let n = source.index(after: index)
        guard n < source.endIndex else { return nil }
        return source[n]
    }

    private mutating func skipWhitespace() {
        while index < source.endIndex, source[index].isWhitespace {
            advance()
        }
    }
}

private struct Parser {
    var tokens: [Token]
    var i: Int = 0
    var diagnostics: [WhenClauseDiagnostic] = []
    let source: String

    var currentOffset: Int { tokens[min(i, tokens.count - 1)].offset }
    var hasMore: Bool {
        if case .eof = tokens[i].kind { return false }
        return true
    }

    mutating func parseExpression() throws -> ContextExpression {
        try parseOr()
    }

    private mutating func parseOr() throws -> ContextExpression {
        var left = try parseAnd()
        while case .or = tokens[i].kind {
            i += 1
            let right = try parseAnd()
            left = .or([left, right])
        }
        return left
    }

    private mutating func parseAnd() throws -> ContextExpression {
        var left = try parseUnary()
        while case .and = tokens[i].kind {
            i += 1
            let right = try parseUnary()
            left = .and([left, right])
        }
        return left
    }

    private mutating func parseUnary() throws -> ContextExpression {
        if case .not = tokens[i].kind {
            i += 1
            return .not(try parseUnary())
        }
        return try parsePrimary()
    }

    private mutating func parsePrimary() throws -> ContextExpression {
        let tok = tokens[i]
        switch tok.kind {
        case .lparen:
            i += 1
            let e = try parseExpression()
            if case .rparen = tokens[i].kind {
                i += 1
            } else {
                diagnostics.append(WhenClauseDiagnostic(message: "Expected ')'", offset: tok.offset))
            }
            return e
        case .ident(let name):
            i += 1
            // comparison: ident == value
            if case .eq = tokens[i].kind {
                i += 1
                let value = consumeValue()
                return mapComparison(name: name, equals: true, value: value)
            }
            if case .neq = tokens[i].kind {
                i += 1
                let value = consumeValue()
                return .not(mapComparison(name: name, equals: true, value: value))
            }
            return mapIdent(name)
        case .string(let s):
            i += 1
            return .key(s)
        default:
            diagnostics.append(WhenClauseDiagnostic(message: "Unexpected token", offset: tok.offset))
            i += 1
            return .never
        }
    }

    private mutating func consumeValue() -> String {
        switch tokens[i].kind {
        case .ident(let s), .string(let s):
            i += 1
            return s
        default:
            return ""
        }
    }

    private func mapIdent(_ name: String) -> ContextExpression {
        switch name {
        case "true", "always": return .always
        case "false", "never": return .never
        case "editorTextFocus", "editorFocus", "focused": return .focused
        case "editorHasSelection", "hasSelection": return .hasSelection
        case "editorIsOpen", "hasDocument", "resourceSet": return .hasDocument
        case "editorReadonly", "!editorReadonly":
            // editorReadonly alone means not editable when true → map to key
            return name.hasPrefix("!") ? .editable : .key("editorReadonly")
        case "editorEditable", "editable": return .editable
        default:
            return .key(name)
        }
    }

    private func mapComparison(name: String, equals: Bool, value: String) -> ContextExpression {
        _ = equals
        if name == "editorLangId" || name == "resourceLangId" || name == "language" {
            return .language(value)
        }
        if name == "resourceExtname" {
            let lang = value.hasPrefix(".") ? String(value.dropFirst()) : value
            return .language(lang)
        }
        // equality on custom keys: treat as key flag when value is true/false
        if value == "true" { return .key(name) }
        if value == "false" { return .not(.key(name)) }
        return .key("\(name)==\(value)")
    }
}
