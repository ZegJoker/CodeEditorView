import CodeEditorCore
import Foundation

/// Loads and saves document bytes for a URI scheme.
///
/// One authoritative save API (DOC-N02). Providers must declare identity support;
/// there is no silent overwrite bridge.
public protocol DocumentContentProvider: Sendable {
    /// Whether this provider can compare on-disk identities for conflict detection.
    var supportsConflictDetection: Bool { get }

    func load(uri: DocumentURI) async throws -> LoadedDocument

    /// Conflict-aware save. Implementations must honor ``DocumentSaveRequest/conflictPolicy``
    /// and never silently ignore ``DocumentSaveRequest/expectedIdentity``.
    func save(_ request: DocumentSaveRequest) async throws -> DocumentSaveOutcome
}

public enum DocumentProviderError: Error, Sendable, Equatable {
    case unsupportedURI(String)
    case notFound(String)
    case encodingFailed
    case ioFailure(String)
    case tooLarge(UInt64)
    case readOnly
    case conflict(DocumentFileChange)
    case unsupportedConflictDetection
    case saveConflictRequiresHostDecision
}

/// In-memory provider keyed by `inmemory:` URIs (and arbitrary map keys).
public actor InMemoryDocumentProvider: DocumentContentProvider {
    private var storage: [String: (text: String, encoding: DocumentEncoding)] = [:]

    public nonisolated var supportsConflictDetection: Bool { false }

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

    public func save(_ request: DocumentSaveRequest) async throws -> DocumentSaveOutcome {
        // In-memory has no external identity; conflict-aware saves with an expected
        // identity and non-overwrite policy fail closed (DOC-N02).
        if request.expectedIdentity != nil, request.conflictPolicy != .overwrite {
            return .unsupportedConflictDetection
        }
        if request.conflictPolicy == .requireHostDecision, request.expectedIdentity != nil {
            return .unsupportedConflictDetection
        }
        storage[request.target.rawValue] = (request.snapshot.text, request.encoding)
        return .saved(nil)
    }
}

/// Local filesystem provider for `file://` URIs with atomic durable writes.
public struct LocalFileDocumentProvider: DocumentContentProvider {
    public var io: any DocumentIO
    public var policy: DocumentLifecyclePolicy
    public var useCoordinator: Bool

    public var supportsConflictDetection: Bool { true }

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
        // DOC-005 / §7.5–7.6: single-pass stream + identity (no double full-file read).
        let data: Data
        let resolvedIdentity: DocumentFileIdentity
        do {
            (data, resolvedIdentity) = try await io.readContentAndIdentity(
                url: url,
                maxBytes: policy.maxLoadBytes
            )
        } catch let error as DocumentIOError {
            throw mapIO(error)
        } catch {
            throw DocumentProviderError.ioFailure(error.localizedDescription)
        }
        let decoded: DocumentDecodeResult
        do {
            decoded = try DocumentCodec.decode(data)
        } catch let error as DocumentIOError {
            throw mapIO(error)
        } catch {
            throw DocumentProviderError.encodingFailed
        }

        return LoadedDocument(
            text: decoded.text,
            encoding: decoded.encoding,
            lineEnding: LineEnding.detect(in: decoded.text),
            fileIdentity: resolvedIdentity,
            hadBOM: decoded.hadBOM
        )
    }

    public func save(_ request: DocumentSaveRequest) async throws -> DocumentSaveOutcome {
        if self.policy.isReadOnly {
            throw DocumentProviderError.readOnly
        }
        guard let url = request.target.fileURL else {
            throw DocumentProviderError.unsupportedURI(request.target.rawValue)
        }

        // DOC-N02: fail closed when identity is required and missing (unless explicit overwrite).
        if request.expectedIdentity == nil {
            if policy.requireIdentityForSave, request.conflictPolicy != .overwrite {
                throw DocumentProviderError.ioFailure(
                    "save requires expectedIdentity (set SaveConflictPolicy.overwrite to bypass)"
                )
            }
            // Default conflict policy is requireHostDecision — without identity, only overwrite
            // is allowed for a first write / unknown file.
            if request.conflictPolicy == .requireHostDecision,
                await io.fileExists(at: url)
            {
                throw DocumentProviderError.ioFailure(
                    "save of existing file requires expectedIdentity under requireHostDecision"
                )
            }
        }

        let bomPolicy: BOMPolicy = {
            switch self.policy.bomPolicy {
            case .preserve:
                return self.policy.bomPolicy
            case .none, .whenEncodingSupports:
                return self.policy.bomPolicy
            }
        }()
        let data: Data
        do {
            data = try DocumentCodec.encode(
                text: request.snapshot.text,
                encoding: request.encoding,
                lineEndingPolicy: self.policy.lineEndingOnSave,
                bomPolicy: bomPolicy
            )
        } catch let error as DocumentIOError {
            throw mapIO(error)
        } catch {
            throw DocumentProviderError.encodingFailed
        }

        // DOC-N08: identity check under the same coordinated write as replace.
        do {
            let result = try await io.writeAtomicallyComparingIdentity(
                data: data,
                to: url,
                expectedIdentity: request.expectedIdentity,
                conflictPolicy: request.conflictPolicy,
                durability: request.durability
            )
            switch result {
            case .written(let identity):
                return .saved(identity)
            case .conflict(let live, let change):
                return .conflict(live: live, change: change)
            case .cancelled:
                return .cancelled
            }
        } catch let error as DocumentIOError {
            throw mapIO(error)
        } catch {
            throw DocumentProviderError.ioFailure(error.localizedDescription)
        }
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
        case .unsupportedEncoding: return .encodingFailed
        case .corruptRecoveryJournal(let s): return .ioFailure(s)
        case .recoveryQuotaExceeded: return .ioFailure("recovery journal quota exceeded")
        case .identityConflict: return .conflict(.externalModified)
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

    /// Save current snapshot through the authoritative conflict-aware API (DOC-N02).
    ///
    /// Defaults to ``SaveConflictPolicy/requireHostDecision`` with the document's known
    /// ``fileIdentity``. Overwrite requires an explicit policy. Failed or conflicted saves
    /// do **not** move the savepoint (DOC-N01).
    @discardableResult
    public func save(
        using provider: any DocumentContentProvider,
        to uri: DocumentURI? = nil,
        io: (any DocumentIO)? = nil,
        conflictPolicy: SaveConflictPolicy = .requireHostDecision,
        durability: SaveDurability = .durable
    ) async throws -> DocumentSaveOutcome {
        let target = uri ?? self.uri
        if let local = provider as? LocalFileDocumentProvider, local.policy.isReadOnly {
            throw DocumentProviderError.readOnly
        }

        if let fileURL = target.fileURL,
            let io,
            let local = provider as? LocalFileDocumentProvider,
            local.policy.writeRecoveryJournal,
            isDirty
        {
            let journal = RecoveryJournal(
                directory: fileURL.deletingLastPathComponent(),
                maxBytesPerDocument: local.policy.recoveryMaxBytesPerDocument,
                maxBytesGlobal: local.policy.recoveryMaxBytesGlobal
            )
            try await journal.write(
                text: text,
                forPrimary: fileURL,
                io: io,
                documentURI: target.rawValue,
                contentState: contentState,
                baseFileIdentity: fileIdentity,
                encoding: encoding
            )
        }

        let request = DocumentSaveRequest(
            snapshot: snapshot(),
            target: target,
            encoding: encoding,
            expectedIdentity: fileIdentity,
            conflictPolicy: conflictPolicy,
            durability: durability
        )
        let outcome = try await provider.save(request)

        switch outcome {
        case .saved(let identity):
            if let uri {
                setURI(uri)
            }
            if let identity {
                setFileIdentity(identity)
            } else if let fileURL = target.fileURL, let io {
                setFileIdentity(try await io.resourceIdentity(at: fileURL))
            }
            if let fileURL = target.fileURL, let io {
                if let local = provider as? LocalFileDocumentProvider, local.policy.writeRecoveryJournal {
                    let journal = RecoveryJournal(
                        directory: fileURL.deletingLastPathComponent(),
                        maxBytesPerDocument: local.policy.recoveryMaxBytesPerDocument,
                        maxBytesGlobal: local.policy.recoveryMaxBytesGlobal
                    )
                    try await journal.clear(forPrimary: fileURL, io: io)
                }
            }
            markClean()
            return outcome
        case .conflict, .cancelled, .unsupportedConflictDetection:
            // Savepoint must not move on failed/conflicted save (DOC-N01).
            return outcome
        }
    }

    /// Attempt recovery from a versioned recovery record for this document's file URI.
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
