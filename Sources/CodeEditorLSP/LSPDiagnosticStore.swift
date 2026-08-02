import CodeEditorDocuments
import Foundation

/// Version-aware diagnostics keyed by server + URI (LSP-008 / §13.9).
public struct LSPStoredDiagnostic: Sendable, Hashable, Identifiable {
    public var id: String
    public var message: String
    public var severity: Int
    public var line: Int
    public var character: Int
    public var endLine: Int
    public var endCharacter: Int

    public init(
        id: String = UUID().uuidString,
        message: String,
        severity: Int = 1,
        line: Int,
        character: Int,
        endLine: Int? = nil,
        endCharacter: Int? = nil
    ) {
        self.id = id
        self.message = message
        self.severity = severity
        self.line = line
        self.character = character
        self.endLine = endLine ?? line
        self.endCharacter = endCharacter ?? character
    }
}

public actor LSPDiagnosticStore {
    public struct Key: Hashable, Sendable {
        public var serverID: String
        public var uri: DocumentURI
        public init(serverID: String, uri: DocumentURI) {
            self.serverID = serverID
            self.uri = uri
        }
    }

    private struct Entry: Sendable {
        var version: Int?
        var items: [LSPStoredDiagnostic]
    }

    private var table: [Key: Entry] = [:]

    public init() {}

    /// Replace diagnostics for a document from a server. Empty list clears.
    public func publish(
        serverID: String,
        uri: DocumentURI,
        version: Int?,
        items: [LSPStoredDiagnostic]
    ) {
        let key = Key(serverID: serverID, uri: uri)
        if items.isEmpty {
            table[key] = nil
            return
        }
        // Ignore stale versions when both present.
        if let version, let existing = table[key]?.version, version < existing {
            return
        }
        table[key] = Entry(version: version, items: items)
    }

    public func diagnostics(serverID: String, uri: DocumentURI) -> [LSPStoredDiagnostic] {
        table[Key(serverID: serverID, uri: uri)]?.items ?? []
    }

    public func allDiagnostics(uri: DocumentURI) -> [LSPStoredDiagnostic] {
        table.filter { $0.key.uri == uri }.flatMap(\.value.items)
    }

    public func clear(uri: DocumentURI) {
        for key in table.keys where key.uri == uri {
            table[key] = nil
        }
    }

    public func clearServer(_ serverID: String) {
        for key in table.keys where key.serverID == serverID {
            table[key] = nil
        }
    }

    public func clearAll() {
        table.removeAll()
    }
}
