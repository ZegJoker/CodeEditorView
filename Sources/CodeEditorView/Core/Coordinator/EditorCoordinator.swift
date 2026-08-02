import Foundation

/// Injects custom behavior into the editor without Combine or binding sprawl.
///
/// Coordinators receive lifecycle and edit notifications. Keep a weak reference to
/// ``EditorController`` if needed, and release it in ``destroy()``.
@MainActor
public protocol EditorCoordinator: AnyObject {
    /// Called once when the coordinator is attached to a controller.
    func prepare(controller: EditorController)

    /// Host view appeared / entered window.
    func controllerDidAppear(controller: EditorController)

    /// Host view disappeared / left window.
    func controllerDidDisappear(controller: EditorController)

    /// Document text changed.
    func textDidChange(controller: EditorController)

    /// Selection / multi-cursor positions changed.
    func selectionDidChange(controller: EditorController, cursors: [CursorPosition])

    /// Controller is tearing down or coordinators are replaced — release resources.
    func destroy()
}

@MainActor
extension EditorCoordinator {
    public func controllerDidAppear(controller: EditorController) {}
    public func controllerDidDisappear(controller: EditorController) {}
    public func textDidChange(controller: EditorController) {}
    public func selectionDidChange(controller: EditorController, cursors: [CursorPosition]) {}
    public func destroy() {}
}

/// Weak box so coordinator arrays don't create retain cycles with the controller.
@MainActor
final class WeakCoordinator {
    weak var value: (any EditorCoordinator)?
    init(_ value: any EditorCoordinator) {
        self.value = value
    }
}
