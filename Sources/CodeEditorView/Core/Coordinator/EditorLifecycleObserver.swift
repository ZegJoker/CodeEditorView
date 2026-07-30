import Foundation
import CodeEditorCore

/// Receives immutable edit / selection lifecycle notifications without retaining
/// ``EditorController``. Prefer this over ``EditorCoordinator`` for new code.
@MainActor
public protocol EditorLifecycleObserver: AnyObject {
    func editorDidAttach(_ context: EditorContext)
    func editorWillApply(_ transaction: EditTransaction, snapshot: DocumentSnapshot)
    func editorDidApply(_ result: AppliedEditTransaction)
    func editorSelectionDidChange(_ event: SelectionChangeEvent)
    func editorDidDetach(_ context: EditorContext)
}

@MainActor
public extension EditorLifecycleObserver {
    func editorDidAttach(_ context: EditorContext) {}
    func editorWillApply(_ transaction: EditTransaction, snapshot: DocumentSnapshot) {}
    func editorDidApply(_ result: AppliedEditTransaction) {}
    func editorSelectionDidChange(_ event: SelectionChangeEvent) {}
    func editorDidDetach(_ context: EditorContext) {}
}

/// Weak box so observer arrays do not retain the host.
@MainActor
final class WeakLifecycleObserver {
    weak var value: (any EditorLifecycleObserver)?
    init(_ value: any EditorLifecycleObserver) {
        self.value = value
    }
}

/// Bridges legacy ``EditorCoordinator`` callbacks to ``EditorLifecycleObserver``.
@MainActor
public final class EditorCoordinatorLifecycleAdapter: EditorLifecycleObserver {
    public weak var controller: EditorController?
    public weak var coordinator: (any EditorCoordinator)?

    public init(controller: EditorController? = nil, coordinator: (any EditorCoordinator)? = nil) {
        self.controller = controller
        self.coordinator = coordinator
    }

    public func editorDidAttach(_ context: EditorContext) {
        guard let controller, let coordinator else { return }
        coordinator.prepare(controller: controller)
        coordinator.controllerDidAppear(controller: controller)
    }

    public func editorDidApply(_ result: AppliedEditTransaction) {
        guard let controller, let coordinator else { return }
        coordinator.textDidChange(controller: controller)
    }

    public func editorSelectionDidChange(_ event: SelectionChangeEvent) {
        guard let controller, let coordinator else { return }
        coordinator.selectionDidChange(controller: controller, cursors: controller.cursorPositions)
    }

    public func editorDidDetach(_ context: EditorContext) {
        guard let controller, let coordinator else { return }
        coordinator.controllerDidDisappear(controller: controller)
        coordinator.destroy()
    }
}
