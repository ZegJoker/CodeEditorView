import Foundation

/// Stable identity for a shared text document.
public struct DocumentID: Hashable, Codable, Sendable, RawRepresentable {
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    public init() {
        self.rawValue = UUID()
    }
}

/// Stable identity for an editor presentation session on a document.
public struct EditorSessionID: Hashable, Codable, Sendable, RawRepresentable {
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    public init() {
        self.rawValue = UUID()
    }
}

/// Document location (file URL string, `inmemory:…`, or host-defined scheme).
public struct DocumentURI: Hashable, Codable, Sendable, RawRepresentable, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.rawValue = value
    }

    public init(fileURL url: URL) {
        // Canonical file URI: standardized path, file:// absoluteString.
        let standardized = url.standardizedFileURL
        self.rawValue = standardized.absoluteString
    }

    /// Returns a canonicalized URI for file URLs (standardized path); others unchanged.
    public func canonicalized() -> DocumentURI {
        guard let url = fileURL else { return self }
        return DocumentURI(fileURL: url)
    }

    public static func inMemory(id: DocumentID = DocumentID()) -> DocumentURI {
        DocumentURI(rawValue: "inmemory:\(id.rawValue.uuidString)")
    }

    public var fileURL: URL? {
        guard let url = URL(string: rawValue), url.isFileURL else { return nil }
        return url
    }

    public var isInMemory: Bool {
        rawValue.hasPrefix("inmemory:")
    }
}

/// Text encoding used when loading/saving document bytes.
///
/// Supported set is closed. ``other`` is rejected by ``DocumentCodec`` unless a host
/// supplies a custom codec (DOC-007). Never silently maps to UTF-8.
public enum DocumentEncoding: Sendable, Hashable, Codable {
    case utf8
    case utf16
    case utf16LittleEndian
    case utf16BigEndian
    /// Unsupported / host-defined encoding name. Codec rejects without host codec.
    case other(String)

    /// Foundation encoding for supported cases; `nil` for `.other`.
    public var stringEncodingOrNil: String.Encoding? {
        switch self {
        case .utf8: return .utf8
        case .utf16: return .utf16
        case .utf16LittleEndian: return .utf16LittleEndian
        case .utf16BigEndian: return .utf16BigEndian
        case .other: return nil
        }
    }

    /// Preferred Foundation encoding for supported cases.
    ///
    /// - Important: `.other` is unsupported and traps (DOC-N07). Use ``stringEncodingOrNil``
    ///   or handle ``DocumentIOError/unsupportedEncoding`` via ``DocumentCodec``.
    public var stringEncoding: String.Encoding {
        guard let encoding = stringEncodingOrNil else {
            preconditionFailure(
                "DocumentEncoding.other has no Foundation mapping; use stringEncodingOrNil / DocumentCodec"
            )
        }
        return encoding
    }

    public static func detect(from data: Data) -> DocumentEncoding {
        if data.starts(with: [0xFF, 0xFE]) { return .utf16LittleEndian }
        if data.starts(with: [0xFE, 0xFF]) { return .utf16BigEndian }
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { return .utf8 }
        return .utf8
    }
}
