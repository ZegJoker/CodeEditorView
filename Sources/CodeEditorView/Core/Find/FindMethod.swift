import Foundation

/// How the find panel matches the query against document text.
///
/// Patterns mirror CodeEditSourceEditor's `FindMethod` so behavior stays aligned.
public enum FindMethod: String, CaseIterable, Sendable, Hashable, Codable {
    case contains
    case matchesWord
    case startsWith
    case endsWith
    case regularExpression

    public var displayName: String {
        switch self {
        case .contains: return "Contains"
        case .matchesWord: return "Matches Word"
        case .startsWith: return "Starts With"
        case .endsWith: return "Ends With"
        case .regularExpression: return "Regular Expression"
        }
    }
}
