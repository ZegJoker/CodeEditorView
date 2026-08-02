import CodeEditorCore
import CodeEditorDocuments
import Foundation

/// Host synchronization policy (LSP-N04).
public enum LSPSyncPolicy: Sendable, Hashable, Codable {
    /// Use incremental when server supports it and versions are continuous; else full.
    case preferIncremental
    /// Always send full-text changes (reliability / large batches).
    case forceFull
    /// Never send changes (None sync).
    case none
}

public struct LSPSyncOptions: Sendable, Hashable {
    /// Debounce for change notifications (0 = immediate).
    public var changeDebounceNanoseconds: UInt64
    public var syncPolicy: LSPSyncPolicy
    /// Legacy alias — maps to ``syncPolicy``.
    public var preferIncremental: Bool {
        get { syncPolicy == .preferIncremental }
        set { syncPolicy = newValue ? .preferIncremental : .forceFull }
    }

    public init(
        changeDebounceNanoseconds: UInt64 = 50_000_000,
        syncPolicy: LSPSyncPolicy = .preferIncremental
    ) {
        self.changeDebounceNanoseconds = changeDebounceNanoseconds
        self.syncPolicy = syncPolicy
    }

    public init(changeDebounceNanoseconds: UInt64 = 50_000_000, preferIncremental: Bool) {
        self.changeDebounceNanoseconds = changeDebounceNanoseconds
        self.syncPolicy = preferIncremental ? .preferIncremental : .forceFull
    }

    public static let `default` = LSPSyncOptions()
}

/// Open phase for a document on a language server (LSP-N07).
public enum LSPDocumentOpenPhase: String, Sendable, Hashable, Codable {
    case closed
    case opening
    case open
    case closing
    case failed
    case resyncing
}

/// One actor per `(session, document)` owns open/change/save/close ordering (LSP-N06).
public actor LSPDocumentLane {
    public let uri: DocumentURI
    private let session: LanguageServerSession
    private let options: LSPSyncOptions
    public private(set) var phase: LSPDocumentOpenPhase = .closed
    public private(set) var lastSentVersion: DocumentVersion?
    public private(set) var lastSentText: String?
    private var languageID: String = "plaintext"
    private var pendingDebounce: Task<Void, Never>?
    private var pendingSnapshot: DocumentSnapshot?
    private var lastEventSequence: UInt64 = 0

    public init(uri: DocumentURI, session: LanguageServerSession, options: LSPSyncOptions) {
        self.uri = uri
        self.session = session
        self.options = options
    }

    public func open(languageID: String, version: DocumentVersion, text: String) async throws {
        guard phase == .closed || phase == .failed else {
            if phase == .open { return }
            throw LSPError.invalidSynchronize("open in phase \(phase)")
        }
        self.languageID = languageID
        phase = .opening
        do {
            try await session.sendDidOpen(
                uri: uri,
                languageID: languageID,
                version: version,
                text: text
            )
            lastSentVersion = version
            lastSentText = text
            phase = .open
        } catch {
            phase = .failed
            throw error
        }
    }

    public func synchronize(
        from old: DocumentSnapshot,
        applying transaction: AppliedEditTransaction,
        to new: DocumentSnapshot
    ) async throws {
        guard phase == .open || phase == .resyncing else {
            throw LSPError.documentNotOpen(uri: uri.rawValue)
        }
        // Version continuity: old must match last sent (or first sync after open).
        if let last = lastSentVersion, old.version != last {
            try await fullResync(version: new.version, text: new.text)
            return
        }
        if transaction.oldVersion != old.version || transaction.newVersion != new.version {
            throw LSPError.invalidSynchronize(
                "transaction versions do not match snapshots"
            )
        }
        cancelDebounce()
        try await sendChange(from: old, applying: transaction, to: new)
    }

    public func scheduleDebouncedFullText(_ snapshot: DocumentSnapshot) {
        guard phase == .open || phase == .resyncing else { return }
        pendingSnapshot = snapshot
        cancelDebounce()
        let delay = options.changeDebounceNanoseconds
        pendingDebounce = Task {
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay)
            }
            guard !Task.isCancelled else { return }
            await self.flushPendingFullText()
        }
    }

    public func flushPendingFullText() async {
        guard let snap = pendingSnapshot else { return }
        pendingSnapshot = nil
        cancelDebounce()
        guard phase == .open || phase == .resyncing else { return }
        do {
            try await session.sendDidChangeFull(
                uri: uri,
                version: snap.version,
                text: snap.text
            )
            lastSentVersion = snap.version
            lastSentText = snap.text
        } catch {
            lastSentText = nil
        }
    }

    /// Save barrier: flush pending change first (LSP-N06).
    ///
    /// When `text` is provided and differs from the last sent content, send a full
    /// `didChange` **before** `didSave` even if debounce has not yet scheduled.
    public func save(text: String?) async throws {
        await flushPendingFullText()
        guard phase == .open else {
            throw LSPError.documentNotOpen(uri: uri.rawValue)
        }
        if let text, text != lastSentText {
            let next = (lastSentVersion ?? .zero).advanced()
            try await session.sendDidChangeFull(uri: uri, version: next, text: text)
            lastSentVersion = next
            lastSentText = text
        }
        try await session.sendDidSave(uri: uri, text: text)
    }

    /// Close barrier: cancel debounce, optional flush, close, terminate lane (LSP-N06).
    public func close(flush: Bool = false) async throws {
        cancelDebounce()
        if flush {
            await flushPendingFullText()
        }
        pendingSnapshot = nil
        phase = .closing
        do {
            try await session.sendDidClose(uri: uri)
            phase = .closed
            lastSentVersion = nil
            lastSentText = nil
        } catch {
            phase = .failed
            throw error
        }
    }

    public func fullResync(version: DocumentVersion, text: String) async throws {
        cancelDebounce()
        pendingSnapshot = nil
        phase = .resyncing
        do {
            // Close + reopen when already open for true resync; else full change.
            if lastSentVersion != nil {
                try? await session.sendDidClose(uri: uri)
                try await session.sendDidOpen(
                    uri: uri,
                    languageID: languageID,
                    version: version,
                    text: text
                )
            } else {
                try await session.sendDidChangeFull(uri: uri, version: version, text: text)
            }
            lastSentVersion = version
            lastSentText = text
            phase = .open
        } catch {
            phase = .failed
            throw error
        }
    }

    public func noteEventSequence(_ sequence: UInt64) -> Bool {
        if lastEventSequence == 0 {
            lastEventSequence = sequence
            return true
        }
        if sequence > lastEventSequence + 1 {
            lastEventSequence = sequence
            return false  // gap
        }
        lastEventSequence = max(lastEventSequence, sequence)
        return true
    }

    public func markGap() {
        cancelDebounce()
        pendingSnapshot = nil
    }

    private func cancelDebounce() {
        pendingDebounce?.cancel()
        pendingDebounce = nil
    }

    private func sendChange(
        from old: DocumentSnapshot,
        applying transaction: AppliedEditTransaction,
        to new: DocumentSnapshot
    ) async throws {
        let caps = await session.capabilities
        let kind = caps.textDocumentSyncKind
        let useIncremental: Bool
        switch options.syncPolicy {
        case .none:
            return
        case .forceFull:
            useIncremental = false
        case .preferIncremental:
            useIncremental = kind == .incremental && caps.incrementalSync
        }

        if useIncremental {
            var contentChanges: [[String: Any]] = []
            for change in transaction.transaction.changes {
                let start = LSPConvert.lineCharacter(
                    utf16Offset: change.replacedRange.location,
                    in: old.text
                )
                let end = LSPConvert.lineCharacter(
                    utf16Offset: change.replacedRange.endUTF16Offset,
                    in: old.text
                )
                contentChanges.append([
                    "range": [
                        "start": ["line": start.line, "character": start.character],
                        "end": ["line": end.line, "character": end.character],
                    ],
                    "text": change.replacement,
                ] as [String: Any])
            }
            if contentChanges.isEmpty {
                try await session.sendDidChangeFull(uri: uri, version: new.version, text: new.text)
            } else {
                try await session.sendDidChangeRaw(
                    uri: uri,
                    version: new.version,
                    contentChanges: contentChanges,
                    fullText: new.text
                )
            }
        } else {
            try await session.sendDidChangeFull(uri: uri, version: new.version, text: new.text)
        }
        lastSentVersion = new.version
        lastSentText = new.text
    }
}

/// Keeps a language server in sync with ``TextDocument`` open/change/close.
public actor LSPDocumentSynchronizer {
    private let session: LanguageServerSession
    private let options: LSPSyncOptions
    private var lanes: [DocumentURI: LSPDocumentLane] = [:]
    private var observationTasks: [DocumentURI: Task<Void, Never>] = [:]

    public init(session: LanguageServerSession, options: LSPSyncOptions = .default) {
        self.session = session
        self.options = options
    }

    private func lane(for uri: DocumentURI) -> LSPDocumentLane {
        if let existing = lanes[uri] { return existing }
        let created = LSPDocumentLane(uri: uri, session: session, options: options)
        lanes[uri] = created
        return created
    }

    /// Open and observe a document. Safe to call multiple times for the same URI.
    public func open(document: TextDocument, languageID: String) async {
        let snapshot = await MainActor.run { document.snapshot() }
        let uri = await MainActor.run { document.uri }
        let text = snapshot.text
        let docLane = lane(for: uri)
        do {
            try await docLane.open(languageID: languageID, version: snapshot.version, text: text)
        } catch {
            return
        }

        observationTasks[uri]?.cancel()
        let stream = await MainActor.run { document.makeEventStream() }
        observationTasks[uri] = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                await self.handle(event: event, document: document, languageID: languageID, uri: uri)
            }
        }
    }

    public func close(uri: DocumentURI) async {
        observationTasks[uri]?.cancel()
        observationTasks[uri] = nil
        if let docLane = lanes[uri] {
            try? await docLane.close(flush: false)
        }
        lanes[uri] = nil
    }

    public func noteSaved(uri: DocumentURI, text: String?) async {
        guard let docLane = lanes[uri] else {
            try? await session.sendDidSave(uri: uri, text: text)
            return
        }
        try? await docLane.save(text: text)
    }

    /// Safe synchronize API (LSP-N03): base snapshot + applied transaction + new snapshot.
    public func synchronize(
        document: TextDocument,
        from old: DocumentSnapshot,
        applying transaction: AppliedEditTransaction,
        to new: DocumentSnapshot
    ) async throws {
        let uri = await MainActor.run { document.uri }
        try await lane(for: uri).synchronize(from: old, applying: transaction, to: new)
    }

    /// Full resync after stream gap / version discontinuity (LSP-N05).
    public func handleSequenceGap(document: TextDocument, languageID: String) async throws {
        let uri = await MainActor.run { document.uri }
        let snap = await MainActor.run { document.snapshot() }
        let docLane = lane(for: uri)
        await docLane.markGap()
        // Ensure language id is known for reopen.
        try await docLane.fullResync(version: snap.version, text: snap.text)
        _ = languageID
    }

    public func documentPhase(uri: DocumentURI) async -> LSPDocumentOpenPhase {
        if let docLane = lanes[uri] {
            return await docLane.phase
        }
        return .closed
    }

    // MARK: - Private

    private func handle(
        event: TextDocumentEvent,
        document: TextDocument,
        languageID: String,
        uri: DocumentURI
    ) async {
        let docLane = lane(for: uri)
        switch event {
        case .didApply(let applied, let sequence):
            let continuous = await docLane.noteEventSequence(sequence)
            if !continuous {
                try? await handleSequenceGap(document: document, languageID: languageID)
                return
            }
            // Debounce coalescing uses full text unless we have a single continuous transaction
            // with no pending debounce (LSP-N04).
            if options.changeDebounceNanoseconds == 0 {
                let newSnap = await MainActor.run { document.snapshot() }
                let oldSnap = DocumentSnapshot(
                    version: applied.oldVersion,
                    text: await docLane.lastSentText ?? newSnap.text
                )
                // Prefer full text from live document for correctness after apply.
                try? await docLane.synchronize(
                    from: DocumentSnapshot(version: applied.oldVersion, text: oldSnap.text),
                    applying: applied,
                    to: newSnap
                )
            } else {
                let snap = await MainActor.run { document.snapshot() }
                await docLane.scheduleDebouncedFullText(snap)
            }
        case .externalContentReplace(let snap, let sequence):
            _ = await docLane.noteEventSequence(sequence)
            try? await docLane.fullResync(version: snap.version, text: snap.text)
        case .uriDidChange(let newURI, _):
            observationTasks[uri]?.cancel()
            observationTasks[uri] = nil
            try? await docLane.close(flush: false)
            lanes[uri] = nil
            await open(document: document, languageID: languageID)
            _ = newURI
        case .streamGap(_, _, let sequence):
            _ = await docLane.noteEventSequence(sequence)
            await docLane.markGap()
            try? await handleSequenceGap(document: document, languageID: languageID)
        case .willApply, .dirtyStateDidChange:
            break
        }
    }
}
