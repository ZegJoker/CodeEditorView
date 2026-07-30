import Foundation
import CodeEditorCore

/// Loads and saves document bytes for a URI scheme.
public protocol DocumentContentProvider: Sendable {
    func load(uri: DocumentURI) async throws -> LoadedDocument
    func save(
        _ snapshot: DocumentSnapshot,
        to uri: DocumentURI,
        encoding: DocumentEncoding
    ) async throws
}

public enum DocumentProviderError: Error, Sendable, Equatable {
    case unsupportedURI(String)
    case notFound(String)
    case encodingFailed
    case ioFailure(String)
}

/// In-memory provider keyed by `inmemory:` URIs (and arbitrary map keys).
public actor InMemoryDocumentProvider: DocumentContentProvider {
    private var storage: [String: (text: String, encoding: DocumentEncoding)] = [:]

    public init() {}

    public func store(uri: DocumentURI, text: String, encoding: DocumentEncoding = .utf8) {
        storage[uri.rawValue] = (text, encoding)
    }

    public func load(uri: DocumentURI) async throws -> LoadedDocument {
        guard let entry = storage[uri.rawValue] else {
            if uri.isInMemory {
                return LoadedDocument(text: "", encoding: .utf8)
            }
            throw DocumentProviderError.notFound(uri.rawValue)
        }
        return LoadedDocument(text: entry.text, encoding: entry.encoding)
    }

    public func save(
        _ snapshot: DocumentSnapshot,
        to uri: DocumentURI,
        encoding: DocumentEncoding
    ) async throws {
        storage[uri.rawValue] = (snapshot.text, encoding)
    }
}

/// Local filesystem provider for `file://` URIs.
public struct LocalFileDocumentProvider: DocumentContentProvider {
    public init() {}

    public func load(uri: DocumentURI) async throws -> LoadedDocument {
        guard let url = uri.fileURL else {
            throw DocumentProviderError.unsupportedURI(uri.rawValue)
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw DocumentProviderError.ioFailure(error.localizedDescription)
        }
        let encoding = DocumentEncoding.detect(from: data)
        guard let text = String(data: data, encoding: encoding.stringEncoding)
                ?? String(data: data, encoding: .utf8)
        else {
            throw DocumentProviderError.encodingFailed
        }
        return LoadedDocument(
            text: text,
            encoding: encoding,
            lineEnding: LineEnding.detect(in: text)
        )
    }

    public func save(
        _ snapshot: DocumentSnapshot,
        to uri: DocumentURI,
        encoding: DocumentEncoding
    ) async throws {
        guard let url = uri.fileURL else {
            throw DocumentProviderError.unsupportedURI(uri.rawValue)
        }
        guard let data = snapshot.text.data(using: encoding.stringEncoding) else {
            throw DocumentProviderError.encodingFailed
        }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw DocumentProviderError.ioFailure(error.localizedDescription)
        }
    }
}

extension TextDocument {
    /// Load content from a provider into this document (replaces content, marks clean).
    public func load(
        from provider: any DocumentContentProvider,
        uri: DocumentURI? = nil
    ) async throws {
        let target = uri ?? self.uri
        let loaded = try await provider.load(uri: target)
        if let uri {
            setURI(uri)
        }
        setEncoding(loaded.encoding)
        _ = try replaceFullContent(
            loaded.text,
            origin: .programmatic,
            clearUndo: true,
            markDirty: false
        )
        markClean()
    }

    /// Save current snapshot through a provider and mark clean on success.
    public func save(using provider: any DocumentContentProvider, to uri: DocumentURI? = nil) async throws {
        let target = uri ?? self.uri
        try await provider.save(snapshot(), to: target, encoding: encoding)
        if let uri {
            setURI(uri)
        }
        markClean()
    }
}
