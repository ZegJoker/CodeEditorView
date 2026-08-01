import CodeEditorCore
import CodeEditorDocuments
import Foundation

public struct LSPSyncOptions: Sendable, Hashable {
    /// Debounce for change notifications (0 = immediate).
    public var changeDebounceNanoseconds: UInt64
    public var preferIncremental: Bool

    public init(changeDebounceNanoseconds: UInt64 = 50_000_000, preferIncremental: Bool = true) {
        self.changeDebounceNanoseconds = changeDebounceNanoseconds
        self.preferIncremental = preferIncremental
    }

    public static let `default` = LSPSyncOptions()
}

/// Keeps a language server in sync with ``TextDocument`` open/change/close.
public actor LSPDocumentSynchronizer {
    private let session: LanguageServerSession
    private let options: LSPSyncOptions
    private var observationTasks: [DocumentURI: Task<Void, Never>] = [:]
    private var pendingChangeTasks: [DocumentURI: Task<Void, Never>] = [:]
    /// Pre-edit text retained for incremental range mapping.
    private var lastSyncedText: [DocumentURI: String] = [:]

    public init(session: LanguageServerSession, options: LSPSyncOptions = .default) {
        self.session = session
        self.options = options
    }

    /// Open and observe a document. Safe to call multiple times for the same URI.
    public func open(document: TextDocument, languageID: String) async {
        let snapshot = await MainActor.run { document.snapshot() }
        let uri = await MainActor.run { document.uri }
        let text = snapshot.text
        do {
            try await session.didOpen(
                uri: uri,
                languageID: languageID,
                version: snapshot.version,
                text: text
            )
            lastSyncedText[uri] = text
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
        pendingChangeTasks[uri]?.cancel()
        pendingChangeTasks[uri] = nil
        lastSyncedText[uri] = nil
        try? await session.didClose(uri: uri)
    }

    public func noteSaved(uri: DocumentURI, text: String?) async {
        try? await session.didSave(uri: uri, text: text)
    }

    // MARK: - Private

    private func handle(
        event: TextDocumentEvent,
        document: TextDocument,
        languageID: String,
        uri: DocumentURI
    ) async {
        switch event {
        case .didApply(let applied):
            await scheduleChange(document: document, uri: uri, applied: applied)
        case .externalContentReplace(let snap):
            lastSyncedText[uri] = snap.text
            try? await session.didChangeRaw(
                uri: uri,
                version: snap.version,
                contentChanges: [["text": snap.text]],
                fullText: snap.text
            )
        case .uriDidChange(let newURI):
            // Close old, reopen as new.
            let oldURI = uri
            observationTasks[oldURI]?.cancel()
            observationTasks[oldURI] = nil
            try? await session.didClose(uri: oldURI)
            lastSyncedText[oldURI] = nil
            await open(document: document, languageID: languageID)
            _ = newURI
        case .willApply, .dirtyStateDidChange:
            break
        }
    }

    private func scheduleChange(
        document: TextDocument,
        uri: DocumentURI,
        applied: AppliedEditTransaction
    ) async {
        // LSP-001: debouncing must not cancel semantic edits while keeping only the newest
        // delta against a stale base. After any coalesced burst, send one full-text
        // replacement with the latest document version (simplest correct debounce).
        pendingChangeTasks[uri]?.cancel()
        let delay = options.changeDebounceNanoseconds
        pendingChangeTasks[uri] = Task {
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay)
            }
            guard !Task.isCancelled else { return }
            await self.flushChangeFullText(document: document, uri: uri)
        }
        // Keep applied referenced so call sites stay valid; incremental path retired for debounce.
        _ = applied
    }

    /// Full-text didChange after debounce — always matches the live document (LSP-001).
    private func flushChangeFullText(
        document: TextDocument,
        uri: DocumentURI
    ) async {
        let snapshot = await MainActor.run { document.snapshot() }
        let fullText = snapshot.text
        let contentChanges: [[String: Any]] = [["text": fullText]]

        do {
            try await session.didChangeRaw(
                uri: uri,
                version: snapshot.version,
                contentChanges: contentChanges,
                fullText: fullText
            )
            lastSyncedText[uri] = fullText
        } catch {
            // Transport failure: leave lastSyncedText so the next successful sync can
            // still force a full resync (do not pretend the server has newer text).
            lastSyncedText[uri] = nil
        }
    }
}
