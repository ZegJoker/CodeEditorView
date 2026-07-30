import Foundation

/// Unchecked Sendable JSON object bag for actor boundaries.
public struct LSPJSONObject: @unchecked Sendable {
    public let dictionary: [String: Any]

    public init(_ dictionary: [String: Any]) {
        self.dictionary = dictionary
    }

    public subscript(key: String) -> Any? {
        dictionary[key]
    }
}
