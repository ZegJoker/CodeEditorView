import Foundation

public struct DocumentationPackageSuggestion: Sendable, Hashable, Codable, Identifiable {
    public var id: String
    public var title: String
    public var languages: [String]
    public var sourcePath: String?
    public var downloadURL: String?
    public var downloadDigest: String?

    public init(
        id: String,
        title: String,
        languages: [String] = [],
        sourcePath: String? = nil,
        downloadURL: String? = nil,
        downloadDigest: String? = nil
    ) {
        self.id = id
        self.title = title
        self.languages = languages
        self.sourcePath = sourcePath
        self.downloadURL = downloadURL
        self.downloadDigest = downloadDigest
    }
}

public struct DocumentationIndexEntry: Sendable, Hashable, Codable, Identifiable {
    public var id: String
    public var title: String
    public var uri: String
    public var snippet: String
    public var packageID: String

    public init(id: String, title: String, uri: String, snippet: String, packageID: String) {
        self.id = id
        self.title = title
        self.uri = uri
        self.snippet = snippet
        self.packageID = packageID
    }
}

public struct DocumentationIndexProgress: Sendable, Hashable, Codable {
    public var packageID: String
    public var fraction: Double
    public var message: String?

    public init(packageID: String, fraction: Double, message: String? = nil) {
        self.packageID = packageID
        self.fraction = fraction
        self.message = message
    }
}

/// Stream events while building a documentation index (no synthetic host filler entries).
public enum DocumentationBuildEvent: Sendable, Hashable, Codable {
    case progress(DocumentationIndexProgress)
    case entry(DocumentationIndexEntry)
    case completed
}

public protocol DocumentationIndexProvider: Sendable {
    func suggestPackages(context: LanguageServerResolveContext) async throws -> [DocumentationPackageSuggestion]
    func buildIndex(
        package: DocumentationPackageSuggestion,
        context: LanguageServerResolveContext
    ) -> AsyncThrowingStream<DocumentationBuildEvent, Error>
    func invalidate(packageID: String?) async
}

public extension DocumentationIndexProvider {
    func invalidate(packageID: String?) async {}
}

public struct DocumentationPackageContribution: Sendable, Hashable, Codable, Identifiable {
    public var id: String
    public var title: String
    public var languages: [String]
    public var sourcePath: String?
    public var extensionID: ExtensionID?

    public init(
        id: String,
        title: String? = nil,
        languages: [String] = [],
        sourcePath: String? = nil,
        extensionID: ExtensionID? = nil
    ) {
        self.id = id
        self.title = title ?? id
        self.languages = languages
        self.sourcePath = sourcePath
        self.extensionID = extensionID
    }

    public func asSuggestion() -> DocumentationPackageSuggestion {
        DocumentationPackageSuggestion(
            id: id,
            title: title,
            languages: languages,
            sourcePath: sourcePath
        )
    }
}

public enum DocumentationIndexError: Error, Sendable, Equatable {
    case quotaExceeded
    case pathDenied(String)
    case cancelled
    case notFound(String)
}
