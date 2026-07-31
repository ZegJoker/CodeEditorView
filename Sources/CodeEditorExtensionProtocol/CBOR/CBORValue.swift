import Foundation

/// Minimal deterministic CBOR value model (RFC 8949 major types 0–5, 7 for null/bool).
public enum CBORValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case unsigned(UInt64)
    case negative(Int64) // stored as actual negative or -1...; encoded as major type 1
    case bytes(Data)
    case text(String)
    case array([CBORValue])
    case map([(key: CBORValue, value: CBORValue)])

    public static func == (lhs: CBORValue, rhs: CBORValue) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): return true
        case (.bool(let a), .bool(let b)): return a == b
        case (.unsigned(let a), .unsigned(let b)): return a == b
        case (.negative(let a), .negative(let b)): return a == b
        case (.bytes(let a), .bytes(let b)): return a == b
        case (.text(let a), .text(let b)): return a == b
        case (.array(let a), .array(let b)): return a == b
        case (.map(let a), .map(let b)):
            guard a.count == b.count else { return false }
            for i in a.indices {
                if a[i].key != b[i].key || a[i].value != b[i].value { return false }
            }
            return true
        default: return false
        }
    }

    public static func int(_ value: Int) -> CBORValue {
        if value >= 0 { return .unsigned(UInt64(value)) }
        return .negative(Int64(value))
    }

    public static func string(_ s: String) -> CBORValue { .text(s) }

    public var stringValue: String? {
        if case .text(let s) = self { return s }
        return nil
    }

    public var intValue: Int? {
        switch self {
        case .unsigned(let u) where u <= UInt64(Int.max): return Int(u)
        case .negative(let n): return Int(n)
        default: return nil
        }
    }

    public var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    public var dataValue: Data? {
        if case .bytes(let d) = self { return d }
        return nil
    }

    public var arrayValue: [CBORValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    /// String-keyed map helper.
    public var stringMap: [String: CBORValue]? {
        guard case .map(let pairs) = self else { return nil }
        var out: [String: CBORValue] = [:]
        for (k, v) in pairs {
            guard case .text(let key) = k else { return nil }
            out[key] = v
        }
        return out
    }

    public static func stringMap(_ dict: [String: CBORValue]) -> CBORValue {
        let pairs = dict.keys.sorted().map { (CBORValue.text($0), dict[$0]!) }
        return .map(pairs)
    }
}

public enum CBORError: Error, Sendable, Equatable {
    case truncated
    case unsupportedMajor(UInt8)
    case indefiniteNotSupported
    case invalidUTF8
    case extraData
    case typeMismatch(String)
}
