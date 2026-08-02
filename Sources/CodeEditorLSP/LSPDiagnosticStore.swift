import CodeEditorCore
import CodeEditorDocuments
import Foundation

/// Version-aware diagnostics keyed by server + URI (LSP-N12).
public struct LSPStoredDiagnostic: Sendable, Hashable, Identifiable {
    public var id: String
    public var message: String
    public var severity: Int
    public var line: Int
    public var character: Int
    public var endLine: Int
    public var endCharacter: Int
    public var source: String?

    public init(
        id: String = UUID().uuidString,
        message: String,
        severity: Int = 1,
        line: Int,
        character: Int,
        endLine: Int? = nil,
        endCharacter: Int? = nil,
        source: String? = nil
    ) {
        self.id = id
        self.message = message
        self.severity = severity
        self.line = line
        self.character = character
        self.endLine = endLine ?? line
        self.endCharacter = endCharacter ?? character
        self.source = source
    }
}

/// Versioned diagnostic publication with server generation and sequence (LSP-N12).
public struct LSPDiagnosticPublication: Sendable, Hashable {
    public var uri: DocumentURI
    public var serverID: String
    public var source: String
    public var serverGeneration: UInt64
    public var documentVersion: Int?
    public var sequence: UInt64
    public var items: [LSPStoredDiagnostic]

    public init(
        uri: DocumentURI,
        serverID: String,
        source: String? = nil,
        serverGeneration: UInt64,
        documentVersion: Int?,
        sequence: UInt64,
        items: [LSPStoredDiagnostic]
    ) {
        self.uri = uri
        self.serverID = serverID
        self.source = source ?? serverID
        self.serverGeneration = serverGeneration
        self.documentVersion = documentVersion
        self.sequence = sequence
        self.items = items
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
        var serverGeneration: UInt64
        var sequence: UInt64
        var items: [LSPStoredDiagnostic]
        var source: String
    }

    private var table: [Key: Entry] = [:]
    private var serverGenerations: [String: UInt64] = [:]
    private var nextSequence: UInt64 = 1
    private let hub = AsyncBroadcastHub<LSPDiagnosticPublication>(maxHistory: 64)
    private let maxItemsPerDocument: Int

    public init(maxItemsPerDocument: Int = 2_000) {
        self.maxItemsPerDocument = max(1, maxItemsPerDocument)
    }

    public func serverGeneration(for serverID: String) -> UInt64 {
        serverGenerations[serverID] ?? 1
    }

    /// Advance server generation (restart / clear) so stale diagnostics drop.
    @discardableResult
    public func bumpServerGeneration(_ serverID: String) -> UInt64 {
        let next = (serverGenerations[serverID] ?? 1) + 1
        serverGenerations[serverID] = next
        // Drop entries from older generations.
        for key in table.keys where key.serverID == serverID {
            if let entry = table[key], entry.serverGeneration < next {
                table[key] = nil
            }
        }
        return next
    }

    /// Replace diagnostics for a document from a server. Empty list clears.
    public func publish(
        serverID: String,
        uri: DocumentURI,
        version: Int?,
        items: [LSPStoredDiagnostic]
    ) async {
        let gen = serverGenerations[serverID] ?? 1
        serverGenerations[serverID] = gen
        await publish(
            serverID: serverID,
            serverGeneration: gen,
            uri: uri,
            version: version,
            items: items
        )
    }

    public func publish(
        serverID: String,
        serverGeneration: UInt64,
        uri: DocumentURI,
        version: Int?,
        items: [LSPStoredDiagnostic],
        source: String? = nil
    ) async {
        let currentGen = serverGenerations[serverID] ?? serverGeneration
        if serverGeneration < currentGen {
            return
        }
        if serverGeneration > currentGen {
            serverGenerations[serverID] = serverGeneration
        }
        let key = Key(serverID: serverID, uri: uri)
        if items.isEmpty {
            table[key] = nil
            let seq = nextSequence
            nextSequence &+= 1
            let pub = LSPDiagnosticPublication(
                uri: uri,
                serverID: serverID,
                source: source,
                serverGeneration: serverGeneration,
                documentVersion: version,
                sequence: seq,
                items: []
            )
            await hub.publish(pub)
            return
        }
        // Ignore stale document versions when both present.
        if let version, let existing = table[key], existing.serverGeneration == serverGeneration,
            let existingVersion = existing.version, version < existingVersion
        {
            return
        }
        let bounded = Array(items.prefix(maxItemsPerDocument))
        let seq = nextSequence
        nextSequence &+= 1
        let src = source ?? serverID
        table[key] = Entry(
            version: version,
            serverGeneration: serverGeneration,
            sequence: seq,
            items: bounded,
            source: src
        )
        let pub = LSPDiagnosticPublication(
            uri: uri,
            serverID: serverID,
            source: src,
            serverGeneration: serverGeneration,
            documentVersion: version,
            sequence: seq,
            items: bounded
        )
        await hub.publish(pub)
    }

    public func latestPublication(serverID: String, uri: DocumentURI) -> LSPDiagnosticPublication? {
        guard let entry = table[Key(serverID: serverID, uri: uri)] else { return nil }
        return LSPDiagnosticPublication(
            uri: uri,
            serverID: serverID,
            source: entry.source,
            serverGeneration: entry.serverGeneration,
            documentVersion: entry.version,
            sequence: entry.sequence,
            items: entry.items
        )
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
        _ = bumpServerGeneration(serverID)
    }

    public func clearAll() {
        table.removeAll()
    }

    /// Bounded multi-subscriber diagnostics stream (LSP-N12).
    public func events(
        policy: AsyncBroadcastHub<LSPDiagnosticPublication>.OverflowPolicy = .dropOldest(
            capacity: 64,
            emitGap: true
        )
    ) async -> AsyncStream<StreamItem<AsyncBroadcastHub<LSPDiagnosticPublication>.Envelope>> {
        await hub.subscribe(policy: policy, replay: .last(8))
    }
}
