import CodeEditorCore
import Foundation
import TextStory

/// Shared text content with document-scoped undo, dirty state, and versioned events.
///
/// Multiple ``EditorSession`` / view controllers may observe the same instance.
/// Presentation (selection, theme, syntax attributes) must stay outside this type.
@MainActor
public final class TextDocument {
    public let id: DocumentID
    public private(set) var uri: DocumentURI
    public private(set) var isDirty: Bool
    public private(set) var encoding: DocumentEncoding
    /// Last known on-disk identity (hash/mtime) after load/save.
    public private(set) var fileIdentity: DocumentFileIdentity?
    /// Whether the last load observed a BOM.
    public private(set) var hadBOM: Bool = false
    /// Content-state savepoint for dirty tracking (DOC-N01).
    public private(set) var savepoint: DocumentSavepoint?
    public var lifecyclePolicy: DocumentLifecyclePolicy

    /// Content buffer (plain text + optional attributes for standalone paint).
    /// Shared multi-session hosts should treat attributes as non-authoritative;
    /// session-local presentation stores hold theme-specific styling.
    public let store: DocumentStore
    /// Document-scoped undo/redo.
    public let undo: UndoCoordinator

    public var version: DocumentVersion { store.version }
    public var contentState: DocumentContentStateID { store.contentState }
    public var lineEnding: LineEnding { store.lineEnding }
    public var text: String { store.fullString }
    public var length: Int { store.length }
    public var isReadOnly: Bool { lifecyclePolicy.isReadOnly }

    private var continuations: [UUID: AsyncStream<TextDocumentEvent>.Continuation] = [:]
    /// Drops from bounded document event streams (DOC-N06).
    public private(set) var droppedEventCount: Int = 0
    /// Monotonic event sequence (DOC-N06).
    public private(set) var eventSequence: UInt64 = 0
    /// Generation of the last apply started by this process path (for self-filtering hosts).
    public private(set) var lastAppliedTransactionID: UUID?

    public init(
        id: DocumentID = DocumentID(),
        uri: DocumentURI? = nil,
        text: String = "",
        encoding: DocumentEncoding = .utf8,
        isDirty: Bool = false,
        lifecyclePolicy: DocumentLifecyclePolicy = .default
    ) {
        self.id = id
        self.uri = uri ?? .inMemory(id: id)
        self.encoding = encoding
        self.isDirty = isDirty
        self.lifecyclePolicy = lifecyclePolicy
        self.store = DocumentStore(string: text)
        self.undo = UndoCoordinator()
        if !isDirty {
            self.savepoint = DocumentSavepoint(
                contentState: store.contentState,
                fileIdentity: nil,
                encoding: encoding,
                lineEnding: store.lineEnding
            )
        } else {
            self.savepoint = nil
        }
    }

    public convenience init(string: String) {
        self.init(text: string)
    }

    // MARK: - Snapshot / events

    public func snapshot() -> DocumentSnapshot {
        store.snapshot()
    }

    /// Document event stream with validated bounded buffer (DOC-N06). Default keeps newest 32 events.
    public func makeEventStream(
        policy: EventBufferPolicy = .default
    ) -> AsyncStream<TextDocumentEvent> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(policy.capacity)) { continuation in
            self.continuations[id] = continuation
            continuation.onTermination = { @Sendable [weak self] _ in
                Task { @MainActor in
                    self?.continuations[id] = nil
                }
            }
        }
    }

    /// Convenience that validates `bufferSize` (DOC-N06). Throws when `bufferSize <= 0`.
    public func makeEventStream(bufferSize: Int) throws -> AsyncStream<TextDocumentEvent> {
        try makeEventStream(policy: EventBufferPolicy(capacity: bufferSize))
    }

    private func nextSequence() -> UInt64 {
        eventSequence &+= 1
        return eventSequence
    }

    private func yield(_ event: TextDocumentEvent) {
        for continuation in continuations.values {
            if case .dropped = continuation.yield(event) {
                droppedEventCount += 1
                let gap = TextDocumentEvent.streamGap(
                    droppedCount: 1,
                    lastSequence: event.sequence,
                    sequence: nextSequence()
                )
                // Best-effort gap marker; may itself drop under extreme backpressure.
                _ = continuation.yield(gap)
            }
        }
    }

    // MARK: - Mutating content

    /// Applies a versioned transaction, registers undo, marks dirty, and notifies observers.
    @discardableResult
    public func apply(
        _ transaction: EditTransaction,
        sortHighToLow: Bool = true,
        registerUndo: Bool = true,
        expectedVersion: DocumentVersion? = nil,
        restoreContentState: DocumentContentStateID? = nil
    ) throws -> AppliedEditTransaction {
        if lifecyclePolicy.isReadOnly {
            throw DocumentProviderError.readOnly
        }
        let pre = store.snapshot()
        let seqWill = nextSequence()
        yield(.willApply(transaction, pre, sequence: seqWill))

        let applied = try store.apply(
            transaction,
            sortHighToLow: sortHighToLow,
            expectedVersion: expectedVersion,
            restoreContentState: restoreContentState
        )
        lastAppliedTransactionID = applied.transaction.id

        if registerUndo {
            undo.register(applied: applied)
        }

        recomputeDirtyFromContentState()
        let seqDid = nextSequence()
        yield(.didApply(applied, sequence: seqDid))
        return applied
    }

    /// Replaces full content (one version bump). Clears undo when `clearUndo` is true.
    @discardableResult
    public func replaceFullContent(
        _ string: String,
        origin: EditOrigin = .programmatic,
        clearUndo: Bool = true,
        markDirty: Bool = true
    ) throws -> AppliedEditTransaction {
        let range = NSRange(location: 0, length: store.length)
        let transaction = EditTransaction.single(
            range: range,
            replacement: string,
            origin: origin
        )
        if clearUndo {
            undo.clear()
        }
        let pre = store.snapshot()
        let seqWill = nextSequence()
        yield(.willApply(transaction, pre, sequence: seqWill))
        let oldVersion = store.version
        let beforeState = store.contentState
        store.setFullText(string)
        let newVersion = store.version
        let afterState = store.contentState
        let applied = AppliedEditTransaction(
            transaction: transaction,
            oldVersion: oldVersion,
            newVersion: newVersion,
            beforeState: beforeState,
            afterState: afterState,
            inverse: EditTransaction.single(
                range: NSRange(location: 0, length: (string as NSString).length),
                replacement: pre.text,
                origin: origin
            ),
            textEdits: []
        )
        lastAppliedTransactionID = transaction.id
        if markDirty {
            setDirty(true)
        } else {
            recomputeDirtyFromContentState()
        }
        let seqDid = nextSequence()
        yield(.didApply(applied, sequence: seqDid))
        return applied
    }

    /// Undoes the last document-scoped group (emits ``TextDocumentEvent/didApply``).
    ///
    /// Throws if the undo application fails; the undo stack is left unchanged (DOC-002 / DOC-N04).
    public func performUndo() throws {
        try undo.undoGroup { [weak self] group in
            guard let self else { return }
            guard !group.edits.isEmpty else { return }
            let changes = group.edits.map {
                TextChange(range: $0.inverse.range, replacement: $0.inverse.string)
            }
            let transaction = EditTransaction(changes: changes, origin: .undo)
            _ = try self.apply(
                transaction,
                sortHighToLow: false,
                registerUndo: false,
                restoreContentState: group.beforeState
            )
        }
    }

    /// Redoes the last undone group (emits ``TextDocumentEvent/didApply``).
    ///
    /// Throws if the redo application fails; the redo stack is left unchanged (DOC-002 / DOC-N04).
    public func performRedo() throws {
        try undo.redoGroup { [weak self] group in
            guard let self else { return }
            guard !group.edits.isEmpty else { return }
            let changes = group.edits.map {
                TextChange(range: $0.mutation.range, replacement: $0.mutation.string)
            }
            let transaction = EditTransaction(changes: changes, origin: .redo)
            _ = try self.apply(
                transaction,
                sortHighToLow: false,
                registerUndo: false,
                restoreContentState: group.afterState
            )
        }
    }

    // MARK: - Dirty / URI / external

    public func markClean() {
        savepoint = DocumentSavepoint(
            contentState: store.contentState,
            fileIdentity: fileIdentity,
            encoding: encoding,
            lineEnding: store.lineEnding
        )
        setDirty(false)
    }

    public func markDirty() {
        setDirty(true)
    }

    /// Dirty iff content state differs from last clean/save (DOC-N01).
    public func recomputeDirtyFromContentState() {
        if let savepoint {
            setDirty(store.contentState != savepoint.contentState)
        } else {
            setDirty(true)
        }
    }

    public func setURI(_ newURI: DocumentURI) {
        guard uri != newURI else { return }
        uri = newURI
        yield(.uriDidChange(newURI, sequence: nextSequence()))
    }

    public func setEncoding(_ newEncoding: DocumentEncoding) {
        encoding = newEncoding
    }

    public func setFileIdentity(_ identity: DocumentFileIdentity?) {
        fileIdentity = identity
    }

    public func setHadBOM(_ value: Bool) {
        hadBOM = value
    }

    /// Apply external content according to policy.
    @discardableResult
    public func applyExternalContent(
        _ text: String,
        policy: DocumentExternalChangePolicy,
        encoding: DocumentEncoding? = nil
    ) throws -> Bool {
        switch policy {
        case .ignore:
            return false
        case .reloadIfClean:
            guard !isDirty else { return false }
        case .alwaysReload:
            break
        }
        if let encoding {
            self.encoding = encoding
        }
        _ = try replaceFullContent(text, origin: .programmatic, clearUndo: true, markDirty: false)
        markClean()
        yield(.externalContentReplace(snapshot(), sequence: nextSequence()))
        return true
    }

    private func setDirty(_ value: Bool) {
        guard isDirty != value else { return }
        isDirty = value
        yield(.dirtyStateDidChange(value, sequence: nextSequence()))
    }
}
