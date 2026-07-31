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

/// Unchecked Sendable JSON value (object, array, scalar, or null) for actor boundaries.
public struct LSPAnyJSON: @unchecked Sendable {
    public let value: Any?

    public init(_ value: Any?) {
        self.value = value
    }

    public static let null = LSPAnyJSON(nil)
}
