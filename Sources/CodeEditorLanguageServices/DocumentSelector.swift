import CodeEditorDocuments
import Foundation

/// Selects documents by language, URI scheme, and simple path patterns.
public struct DocumentSelector: Sendable, Hashable, Codable {
    /// Empty set matches any language.
    public var languageIDs: Set<String>
    /// Empty list matches any scheme. Values like `"file"`, `"inmemory"`.
    public var schemePatterns: [String]
    /// Simple matchers: exact extension `*.swift`, suffix `/Foo.swift`, or contains substring.
    public var pathGlobs: [String]

    public init(
        languageIDs: Set<String> = [],
        schemePatterns: [String] = [],
        pathGlobs: [String] = []
    ) {
        self.languageIDs = Set(languageIDs.map { $0.lowercased() })
        self.schemePatterns = schemePatterns.map { $0.lowercased() }
        self.pathGlobs = pathGlobs
    }

    public static let any = DocumentSelector()

    public static func languages(_ ids: String...) -> DocumentSelector {
        DocumentSelector(languageIDs: Set(ids))
    }

    public func matches(languageID: String?, uri: DocumentURI?) -> Bool {
        if !languageIDs.isEmpty {
            guard let languageID, languageIDs.contains(languageID.lowercased()) else {
                return false
            }
        }
        if !schemePatterns.isEmpty {
            let scheme = scheme(of: uri)?.lowercased() ?? ""
            guard schemePatterns.contains(scheme) else { return false }
        }
        if !pathGlobs.isEmpty {
            let path = pathString(of: uri) ?? ""
            guard pathGlobs.contains(where: { globMatches($0, path: path) }) else {
                return false
            }
        }
        return true
    }

    private func scheme(of uri: DocumentURI?) -> String? {
        guard let raw = uri?.rawValue else { return nil }
        if let r = raw.range(of: ":") {
            return String(raw[..<r.lowerBound])
        }
        return nil
    }

    private func pathString(of uri: DocumentURI?) -> String? {
        guard let uri else { return nil }
        if let url = uri.fileURL { return url.path }
        return uri.rawValue
    }

    private func globMatches(_ pattern: String, path: String) -> Bool {
        if pattern.hasPrefix("*.") {
            let ext = String(pattern.dropFirst(2)).lowercased()
            return (path as NSString).pathExtension.lowercased() == ext
        }
        if pattern.hasPrefix("*") && pattern.hasSuffix("*") && pattern.count > 2 {
            let mid = String(pattern.dropFirst().dropLast())
            return path.localizedCaseInsensitiveContains(mid)
        }
        if pattern.hasPrefix("*") {
            return path.lowercased().hasSuffix(String(pattern.dropFirst()).lowercased())
        }
        if pattern.hasSuffix("*") {
            return path.lowercased().hasPrefix(String(pattern.dropLast()).lowercased())
        }
        return path.localizedCaseInsensitiveContains(pattern)
    }
}

public struct LanguageServiceContext: Sendable, Hashable {
    public var languageID: String?
    public var uri: DocumentURI?
    public var workspaceRootURIs: [DocumentURI]
    public var flags: [String: String]

    public init(
        languageID: String? = nil,
        uri: DocumentURI? = nil,
        workspaceRootURIs: [DocumentURI] = [],
        flags: [String: String] = [:]
    ) {
        self.languageID = languageID
        self.uri = uri
        self.workspaceRootURIs = workspaceRootURIs
        self.flags = flags
    }
}

public struct ProviderID: Hashable, Codable, Sendable, RawRepresentable, ExpressibleByStringLiteral {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
}
