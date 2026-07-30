import Foundation

/// Serializable enablement / when-clause tree for commands and keybindings.
public indirect enum ContextExpression: Sendable, Codable, Hashable, Equatable {
    case always
    case never
    case editable
    case focused
    case hasSelection
    case hasDocument
    case language(String)
    case key(String)
    case not(ContextExpression)
    case and([ContextExpression])
    case or([ContextExpression])
}

/// Input snapshot used to evaluate ``ContextExpression``.
public struct ContextEvaluationInput: Sendable, Hashable {
    public var isEditable: Bool
    public var isFocused: Bool
    public var hasSelection: Bool
    public var hasDocument: Bool
    public var languageID: String?
    public var flags: [String: Bool]

    public init(
        isEditable: Bool = true,
        isFocused: Bool = true,
        hasSelection: Bool = false,
        hasDocument: Bool = true,
        languageID: String? = nil,
        flags: [String: Bool] = [:]
    ) {
        self.isEditable = isEditable
        self.isFocused = isFocused
        self.hasSelection = hasSelection
        self.hasDocument = hasDocument
        self.languageID = languageID
        self.flags = flags
    }
}

public enum ContextExpressionEvaluator {
    public static func evaluate(_ expression: ContextExpression, in input: ContextEvaluationInput) -> Bool {
        switch expression {
        case .always:
            return true
        case .never:
            return false
        case .editable:
            return input.isEditable
        case .focused:
            return input.isFocused
        case .hasSelection:
            return input.hasSelection
        case .hasDocument:
            return input.hasDocument
        case .language(let id):
            return input.languageID == id
        case .key(let name):
            return input.flags[name] == true
        case .not(let inner):
            return !evaluate(inner, in: input)
        case .and(let parts):
            return parts.allSatisfy { evaluate($0, in: input) }
        case .or(let parts):
            return parts.contains { evaluate($0, in: input) }
        }
    }
}
