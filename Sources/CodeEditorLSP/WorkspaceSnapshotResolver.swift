import CodeEditorCore
import CodeEditorDocuments
import Foundation

/// Resolves document text/version for any URI (open buffer or disk) for cross-file LSP positions.
///
/// LSP-N09: every location/edit must resolve against the **target** document content,
/// never the request document's text when URIs differ. Failure is typed — never empty text.
public protocol WorkspaceSnapshotResolver: Sendable {
    func snapshot(for uri: DocumentURI) async throws -> TextSnapshot
}

/// Immutable text + generation used for position encoding.
public struct TextSnapshot: Sendable, Hashable {
    public var uri: DocumentURI
    public var text: String
    public var version: DocumentVersion?

    public init(uri: DocumentURI, text: String, version: DocumentVersion? = nil) {
        self.uri = uri
        self.text = text
        self.version = version
    }
}

/// Default resolver: open documents from a registry factory, else bounded UTF-8 disk read.
public struct DefaultWorkspaceSnapshotResolver: WorkspaceSnapshotResolver {
    public var maxDiskBytes: UInt64
    /// Returns open-document text for a URI when available (main-actor registry bridge).
    public var openDocumentText: @Sendable (DocumentURI) async -> (String, DocumentVersion?)?

    public init(
        maxDiskBytes: UInt64 = 16 * 1024 * 1024,
        openDocumentText: @escaping @Sendable (DocumentURI) async -> (String, DocumentVersion?)? = { _ in nil }
    ) {
        self.maxDiskBytes = maxDiskBytes
        self.openDocumentText = openDocumentText
    }

    public func snapshot(for uri: DocumentURI) async throws -> TextSnapshot {
        if let open = await openDocumentText(uri) {
            return TextSnapshot(uri: uri, text: open.0, version: open.1)
        }
        guard let url = uri.fileURL else {
            throw LSPError.snapshotUnavailable(
                uri: uri.rawValue,
                reason: "non-file URI with no open document"
            )
        }
        let data: Data
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let limit = Int(min(maxDiskBytes + 1, UInt64(Int.max)))
            data = try handle.read(upToCount: limit) ?? Data()
            if UInt64(data.count) > maxDiskBytes {
                throw LSPError.snapshotUnavailable(
                    uri: uri.rawValue,
                    reason: "file too large for snapshot"
                )
            }
        } catch let error as LSPError {
            throw error
        } catch {
            throw LSPError.snapshotUnavailable(
                uri: uri.rawValue,
                reason: "snapshot read failed: \(error)"
            )
        }
        // Fail closed on non-UTF8 for edit/navigation accuracy (no lossy empty fallback).
        guard let text = String(data: data, encoding: .utf8) else {
            throw LSPError.snapshotUnavailable(
                uri: uri.rawValue,
                reason: "file is not valid UTF-8"
            )
        }
        return TextSnapshot(uri: uri, text: text, version: nil)
    }
}

/// Session-scoped resolver registry (actor-safe).
public actor LSPSnapshotResolverBox {
    private var resolver: any WorkspaceSnapshotResolver

    public init(_ resolver: any WorkspaceSnapshotResolver = DefaultWorkspaceSnapshotResolver()) {
        self.resolver = resolver
    }

    public func set(_ resolver: any WorkspaceSnapshotResolver) {
        self.resolver = resolver
    }

    public func snapshot(for uri: DocumentURI) async throws -> TextSnapshot {
        try await resolver.snapshot(for: uri)
    }
}
