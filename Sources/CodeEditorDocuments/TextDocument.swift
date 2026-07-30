import Foundation
import TextStory
import CodeEditorCore

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

    /// Content buffer (plain text + optional attributes for standalone paint).
    /// Shared multi-session hosts should treat attributes as non-authoritative;
    /// session-local presentation stores hold theme-specific styling.
    public let store: DocumentStore
    /// Document-scoped undo/redo.
    public let undo: UndoCoordinator

    public var version: DocumentVersion { store.version }
    public var lineEnding: LineEnding { store.lineEnding }
    public var text: String { store.fullString }
    public var length: Int { store.length }

    private var continuations: [UUID: AsyncStream<TextDocumentEvent>.Continuation] = [:]
    /// Generation of the last apply started by this process path (for self-filtering hosts).
    public private(set) var lastAppliedTransactionID: UUID?

    public init(
        id: DocumentID = DocumentID(),
        uri: DocumentURI? = nil,
        text: String = "",
        encoding: DocumentEncoding = .utf8,
        isDirty: Bool = false
    ) {
        self.id = id
        self.uri = uri ?? .inMemory(id: id)
        self.encoding = encoding
        self.isDirty = isDirty
        self.store = DocumentStore(string: text)
        self.undo = UndoCoordinator()
    }

    public convenience init(string: String) {
        self.init(text: string)
    }

    // MARK: - Snapshot / events

    public func snapshot() -> DocumentSnapshot {
        store.snapshot()
    }

    public func makeEventStream() -> AsyncStream<TextDocumentEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            self.continuations[id] = continuation
            continuation.onTermination = { @Sendable [weak self] _ in
                Task { @MainActor in
                    self?.continuations[id] = nil
                }
            }
        }
    }

    private func yield(_ event: TextDocumentEvent) {
        for continuation in continuations.values {
            continuation.yield(event)
        }
    }

    // MARK: - Mutating content

    /// Applies a versioned transaction, registers undo, marks dirty, and notifies observers.
    @discardableResult
    public func apply(
        _ transaction: EditTransaction,
        sortHighToLow: Bool = true,
        registerUndo: Bool = true
    ) throws -> AppliedEditTransaction {
        let pre = store.snapshot()
        yield(.willApply(transaction, pre))

        let applied = try store.apply(transaction, sortHighToLow: sortHighToLow)
        lastAppliedTransactionID = applied.transaction.id

        if registerUndo {
            if applied.textEdits.count > 1 {
                undo.beginGrouping()
            }
            for edit in applied.textEdits {
                undo.register(edit: edit)
            }
            if applied.textEdits.count > 1 {
                undo.endGrouping()
            }
        }

        setDirty(true)
        yield(.didApply(applied))
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
        // Use store path that preserves single version bump via setFullText for attribute reset,
        // but still emit transaction events.
        let pre = store.snapshot()
        yield(.willApply(transaction, pre))
        let oldVersion = store.version
        store.setFullText(string)
        let newVersion = store.version
        let applied = AppliedEditTransaction(
            transaction: transaction,
            oldVersion: oldVersion,
            newVersion: newVersion,
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
        }
        yield(.didApply(applied))
        return applied
    }

    /// Undoes the last document-scoped group (emits ``TextDocumentEvent/didApply``).
    public func performUndo() {
        undo.undoGroup { [weak self] edits in
            guard let self, !edits.isEmpty else { return }
            let changes = edits.map {
                TextChange(range: $0.inverse.range, replacement: $0.inverse.string)
            }
            let transaction = EditTransaction(changes: changes, origin: .undo)
            _ = try? self.apply(transaction, sortHighToLow: false, registerUndo: false)
        }
    }

    /// Redoes the last undone group (emits ``TextDocumentEvent/didApply``).
    public func performRedo() {
        undo.redoGroup { [weak self] edits in
            guard let self, !edits.isEmpty else { return }
            let changes = edits.map {
                TextChange(range: $0.mutation.range, replacement: $0.mutation.string)
            }
            let transaction = EditTransaction(changes: changes, origin: .redo)
            _ = try? self.apply(transaction, sortHighToLow: false, registerUndo: false)
        }
    }

    // MARK: - Dirty / URI / external

    public func markClean() {
        setDirty(false)
    }

    public func markDirty() {
        setDirty(true)
    }

    public func setURI(_ newURI: DocumentURI) {
        guard uri != newURI else { return }
        uri = newURI
        yield(.uriDidChange(newURI))
    }

    public func setEncoding(_ newEncoding: DocumentEncoding) {
        encoding = newEncoding
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
        setDirty(false)
        yield(.externalContentReplace(snapshot()))
        return true
    }

    private func setDirty(_ value: Bool) {
        guard isDirty != value else { return }
        isDirty = value
        yield(.dirtyStateDidChange(value))
    }
}
