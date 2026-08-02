import Foundation

/// Complete JSON value model for LSP results (LSP-N11).
///
/// Supports object, array, string, number, boolean, and null. Valid scalar results
/// are preserved rather than discarded or wrapped only as objects.
public enum JSONValue: Sendable, Hashable, Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    public var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    public var numberValue: Double? {
        if case .number(let n) = self { return n }
        return nil
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }

    /// Foundation-compatible JSON object (for JSONSerialization).
    public var jsonObject: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .number(let n):
            if n.rounded() == n, n >= Double(Int.min), n <= Double(Int.max) {
                return Int(n)
            }
            return n
        case .string(let s): return s
        case .array(let a): return a.map(\.jsonObject)
        case .object(let o): return o.mapValues(\.jsonObject)
        }
    }

    public init(jsonObject raw: Any) throws {
        switch raw {
        case is NSNull:
            self = .null
        case let b as Bool:
            self = .bool(b)
        case let n as NSNumber:
            // Distinguish Bool bridged as NSNumber.
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                self = .bool(n.boolValue)
            } else {
                self = .number(n.doubleValue)
            }
        case let s as String:
            self = .string(s)
        case let a as [Any]:
            self = .array(try a.map { try JSONValue(jsonObject: $0) })
        case let o as [String: Any]:
            var dict: [String: JSONValue] = [:]
            for (k, v) in o {
                dict[k] = try JSONValue(jsonObject: v)
            }
            self = .object(dict)
        default:
            throw LSPError.decode("unsupported JSON value \(type(of: raw))")
        }
    }

    public init(data: Data) throws {
        let obj = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        try self.init(jsonObject: obj)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? c.decode(Int.self) {
            self = .number(Double(i))
        } else if let d = try? c.decode(Double.self) {
            self = .number(d)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let a = try? c.decode([JSONValue].self) {
            self = .array(a)
        } else if let o = try? c.decode([String: JSONValue].self) {
            self = .object(o)
        } else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "JSONValue")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n):
            if n.rounded() == n, n >= Double(Int.min), n <= Double(Int.max) {
                try c.encode(Int(n))
            } else {
                try c.encode(n)
            }
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

/// Unchecked Sendable JSON object bag for actor boundaries.
public struct LSPJSONObject: @unchecked Sendable {
    public let dictionary: [String: Any]

    public init(_ dictionary: [String: Any]) {
        self.dictionary = dictionary
    }

    public subscript(key: String) -> Any? {
        dictionary[key]
    }

    public func jsonValue() throws -> JSONValue {
        try JSONValue(jsonObject: dictionary)
    }
}

/// Unchecked Sendable JSON value (object, array, scalar, or null) for actor boundaries.
public struct LSPAnyJSON: @unchecked Sendable {
    public let value: Any?

    public init(_ value: Any?) {
        self.value = value
    }

    public static let null = LSPAnyJSON(nil)

    public func jsonValue() throws -> JSONValue {
        guard let value else { return .null }
        return try JSONValue(jsonObject: value)
    }

    public init(_ json: JSONValue) {
        self.value = json.isNull ? nil : json.jsonObject
    }
}
