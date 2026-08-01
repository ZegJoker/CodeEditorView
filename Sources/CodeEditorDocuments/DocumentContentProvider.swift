import Foundation
import CodeEditorCore

/// Host decision when a conflict-safe save detects external modification (DOC-004).
public enum SaveConflictPolicy: Sendable, Hashable, Codable {
    case overwrite
    case cancel
    /// Host should open save-as UI; this layer throws ``DocumentProviderError/conflict``.
    case requireHostDecision
}

/// Result of a conflict-aware save.
public enum SaveResult: Sendable, Equatable {
    case saved(DocumentFileIdentity?)
    case conflict(live: DocumentFileIdentity?, change: DocumentFileChange)
    case cancelled
}

/// Loads and saves document bytes for a URI scheme.
public protocol DocumentContentProvider: Sendable {
    func load(uri: DocumentURI) async throws -> LoadedDocument
    func save(
        _ snapshot: DocumentSnapshot,
        to uri: DocumentURI,
        encoding: DocumentEncoding
    ) async throws

    /// Conflict-safe save with expected identity (DOC-004). Default bridges to `save`.
    func save(
        _ snapshot: DocumentSnapshot,
        to uri: DocumentURI,
        encoding: DocumentEncoding,
        expectedIdentity: DocumentFileIdentity?,
        policy: SaveConflictPolicy
    ) async throws -> SaveResult
}

public extension DocumentContentProvider {
    func save(
        _ snapshot: DocumentSnapshot,
        to uri: DocumentURI,
        encoding: DocumentEncoding,
        expectedIdentity: DocumentFileIdentity?,
        policy: SaveConflictPolicy
    ) async throws -> SaveResult {
        _ = expectedIdentity
        _ = policy
        try await save(snapshot, to: uri, encoding: encoding)
        return .saved(nil)
    }
}

public enum DocumentProviderError: Error, Sendable, Equatable {
    case unsupportedURI(String)
    case notFound(String)
    case encodingFailed
    case ioFailure(String)
    case tooLarge(UInt64)
    case readOnly
    case conflict(DocumentFileChange)
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

/// Local filesystem provider for `file://` URIs with atomic Durable writes.
public struct LocalFileDocumentProvider: DocumentContentProvider {
    public var io: any DocumentIO
    public var policy: DocumentLifecyclePolicy
    public var useCoordinator: Bool

    public init(
        io: (any DocumentIO)? = nil,
        policy: DocumentLifecyclePolicy = .default,
        useCoordinator: Bool = true
    ) {
        if let io {
            self.io = io
        } else {
            self.io = useCoordinator ? CoordinatedDocumentIO() : LocalDocumentIO()
        }
        self.policy = policy
        self.useCoordinator = useCoordinator
    }

    public func load(uri: DocumentURI) async throws -> LoadedDocument {
        guard let url = uri.fileURL else {
            throw DocumentProviderError.unsupportedURI(uri.rawValue)
        }
        // DOC: enforce size from metadata before full allocation when possible.
        if let identity = try? await io.resourceIdentity(at: url),
           identity.size > policy.maxLoadBytes
        {
            throw DocumentProviderError.tooLarge(identity.size)
        }
        let data: Data
        do {
            data = try await io.read(url: url, maxBytes: policy.maxLoadBytes)
        } catch let error as DocumentIOError {
            throw mapIO(error)
        } catch {
            throw DocumentProviderError.ioFailure(error.localizedDescription)
        }
        if UInt64(data.count) > policy.maxLoadBytes {
            throw DocumentProviderError.tooLarge(UInt64(data.count))
        }
        let decoded: (text: String, encoding: DocumentEncoding, bom: Bool)
        do {
            decoded = try DocumentCodec.decode(data)
        } catch {
            throw DocumentProviderError.encodingFailed
        }
        // Single-pass identity from the bytes we already read.
        let values = try? url.resourceValues(forKeys: [
            .contentModificationDateKey,
            .fileResourceIdentifierKey,
        ])
        let resolvedIdentity = DocumentFileIdentity(
            contentHash: DocumentFileIdentity.hash(of: data),
            size: UInt64(data.count),
            modificationTime: values?.contentModificationDate?.timeIntervalSince1970,
            fileResourceIdentifier: values?.fileResourceIdentifier as? Data
        )

        return LoadedDocument(
            text: decoded.text,
            encoding: decoded.encoding,
            lineEnding: LineEnding.detect(in: decoded.text),
            fileIdentity: resolvedIdentity,
            hadBOM: decoded.bom
        )
    }

    public func save(
        _ snapshot: DocumentSnapshot,
        to uri: DocumentURI,
        encoding: DocumentEncoding
    ) async throws {
        _ = try await save(
            snapshot,
            to: uri,
            encoding: encoding,
            expectedIdentity: nil,
            policy: .overwrite
        )
    }

    public func save(
        _ snapshot: DocumentSnapshot,
        to uri: DocumentURI,
        encoding: DocumentEncoding,
        expectedIdentity: DocumentFileIdentity?,
        policy conflictPolicy: SaveConflictPolicy
    ) async throws -> SaveResult {
        if self.policy.isReadOnly {
            throw DocumentProviderError.readOnly
        }
        guard let url = uri.fileURL else {
            throw DocumentProviderError.unsupportedURI(uri.rawValue)
        }

        // DOC-004: compare-and-swap against expected identity before replacement.
        if let expectedIdentity {
            let change = try await detectChange(at: uri, known: expectedIdentity)
            switch change {
            case .unchanged:
                break
            case .deleted, .externalModified, .moved:
                switch conflictPolicy {
                case .cancel:
                    return .cancelled
                case .requireHostDecision:
                    let live = try? await io.resourceIdentity(at: url)
                    return .conflict(live: live, change: change)
                case .overwrite:
                    break
                }
            }
            // Revalidate immediately before write to shrink the TOCTOU window.
            let again = try await detectChange(at: uri, known: expectedIdentity)
            if again != .unchanged, conflictPolicy != .overwrite {
                let live = try? await io.resourceIdentity(at: url)
                if conflictPolicy == .cancel { return .cancelled }
                return .conflict(live: live, change: again)
            }
        }

        let data: Data
        do {
            data = try DocumentCodec.encode(
                text: snapshot.text,
                encoding: encoding,
                lineEndingPolicy: self.policy.lineEndingOnSave,
                bomPolicy: self.policy.bomPolicy
            )
        } catch {
            throw DocumentProviderError.encodingFailed
        }
        do {
            try await io.writeAtomically(data: data, to: url)
        } catch let error as DocumentIOError {
            throw mapIO(error)
        } catch {
            throw DocumentProviderError.ioFailure(error.localizedDescription)
        }
        let identity = try? await io.resourceIdentity(at: url)
        return .saved(identity)
    }

    /// Detect whether the on-disk file changed relative to `known`.
    public func detectChange(
        at uri: DocumentURI,
        known: DocumentFileIdentity?
    ) async throws -> DocumentFileChange {
        guard let url = uri.fileURL else {
            throw DocumentProviderError.unsupportedURI(uri.rawValue)
        }
        guard await io.fileExists(at: url) else {
            return .deleted
        }
        guard let known else { return .externalModified }
        guard let live = try await io.resourceIdentity(at: url) else {
            return .deleted
        }
        if live.contentHash == known.contentHash {
            // Same content at this path — treat as unchanged (identifier may churn after replace).
            return .unchanged
        }
        // Content changed at the same path → external modify. "Moved" is reserved for
        // callers that observe a rename while tracking the resource identifier elsewhere.
        return .externalModified
    }

    private func mapIO(_ error: DocumentIOError) -> DocumentProviderError {
        switch error {
        case .notFound(let s): return .notFound(s)
        case .ioFailure(let s): return .ioFailure(s)
        case .tooLarge(let n): return .tooLarge(n)
        case .injectedFault(let p): return .ioFailure("injected fault: \(p.rawValue)")
        case .readOnly: return .readOnly
        case .encodingFailed: return .encodingFailed
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
        if let ending = loaded.lineEnding {
            store.setPreferredLineEnding(ending)
        }
        setFileIdentity(loaded.fileIdentity)
        setHadBOM(loaded.hadBOM)
        _ = try replaceFullContent(
            loaded.text,
            origin: .programmatic,
            clearUndo: true,
            markDirty: false
        )
        markClean()
    }

    /// Save current snapshot through a provider and mark clean on success.
    /// Writes a recovery journal when dirty before the durable save (when policy allows).
    public func save(
        using provider: any DocumentContentProvider,
        to uri: DocumentURI? = nil,
        io: (any DocumentIO)? = nil
    ) async throws {
        let target = uri ?? self.uri
        if let local = provider as? LocalFileDocumentProvider, local.policy.isReadOnly {
            throw DocumentProviderError.readOnly
        }

        if let fileURL = target.fileURL,
           let io,
           let local = provider as? LocalFileDocumentProvider,
           local.policy.writeRecoveryJournal,
           isDirty {
            let journal = RecoveryJournal(directory: fileURL.deletingLastPathComponent())
            try await journal.write(text: text, forPrimary: fileURL, io: io)
        }

        try await provider.save(snapshot(), to: target, encoding: encoding)
        if let uri {
            setURI(uri)
        }

        if let fileURL = target.fileURL, let io {
            setFileIdentity(try await io.resourceIdentity(at: fileURL))
            if let local = provider as? LocalFileDocumentProvider, local.policy.writeRecoveryJournal {
                let journal = RecoveryJournal(directory: fileURL.deletingLastPathComponent())
                try await journal.clear(forPrimary: fileURL, io: io)
            }
        }

        markClean()
    }

    /// Attempt recovery from a sidecar journal for this document's file URI.
    @discardableResult
    public func recoverFromJournalIfNeeded(io: any DocumentIO) async throws -> Bool {
        guard let fileURL = uri.fileURL else { return false }
        let journal = RecoveryJournal(directory: fileURL.deletingLastPathComponent())
        guard let text = try await journal.read(forPrimary: fileURL, io: io) else {
            return false
        }
        _ = try replaceFullContent(text, origin: .programmatic, clearUndo: true, markDirty: true)
        return true
    }
}
