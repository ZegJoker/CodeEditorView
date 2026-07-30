import Foundation
import CodeEditorCore
import CodeEditorDocuments

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
        pendingChangeTasks[uri]?.cancel()
        let delay = options.changeDebounceNanoseconds
        pendingChangeTasks[uri] = Task {
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay)
            }
            guard !Task.isCancelled else { return }
            await self.flushChange(document: document, uri: uri, applied: applied)
        }
    }

    private func flushChange(
        document: TextDocument,
        uri: DocumentURI,
        applied: AppliedEditTransaction
    ) async {
        let snapshot = await MainActor.run { document.snapshot() }
        let fullText = snapshot.text
        let caps = await session.capabilities
        let preText = lastSyncedText[uri] ?? fullText

        let contentChanges: [[String: Any]]
        if options.preferIncremental && caps.incrementalSync {
            contentChanges = applied.transaction.changes.map { change in
                let range = change.replacedRange
                let start = LSPConvert.lineCharacter(utf16Offset: range.location, in: preText)
                let end = LSPConvert.lineCharacter(
                    utf16Offset: range.location + range.length,
                    in: preText
                )
                return [
                    "range": [
                        "start": ["line": start.line, "character": start.character],
                        "end": ["line": end.line, "character": end.character],
                    ] as [String: Any],
                    "text": change.replacement,
                ] as [String: Any]
            }
        } else {
            contentChanges = [["text": fullText]]
        }

        do {
            try await session.didChangeRaw(
                uri: uri,
                version: snapshot.version,
                contentChanges: contentChanges,
                fullText: fullText
            )
            lastSyncedText[uri] = fullText
        } catch {
            // Session may have crashed; leave document untouched.
        }
    }
}
