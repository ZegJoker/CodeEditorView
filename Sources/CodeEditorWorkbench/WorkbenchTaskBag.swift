import Foundation

/// Owns unstructured `Task` work for a workbench lifecycle scope (WB-N05).
///
/// Scopes: window, pane, tab, panel, contribution, or the primary ``WorkbenchModel``.
/// Call ``cancelAll()`` on deactivation / tear-down; critical shutdown should await
/// cancellation before releasing shared resources.
@MainActor
public final class WorkbenchTaskBag {
    private var tasks: [UUID: Task<Void, Never>] = [:]
    /// Monotonic count of all tasks ever stored (observability / tests).
    public private(set) var totalStored: UInt64 = 0

    public init() {}

    public var count: Int { tasks.count }

    /// Store a fire-and-forget task. Returns its bag id.
    @discardableResult
    public func store(_ task: Task<Void, Never>) -> UUID {
        let id = UUID()
        tasks[id] = task
        totalStored &+= 1
        return id
    }

    /// Convenience: launch and retain a MainActor task.
    @discardableResult
    public func task(_ body: @escaping @MainActor () async -> Void) -> UUID {
        store(
            Task { @MainActor in
                await body()
            }
        )
    }

    public func cancel(_ id: UUID) {
        if let task = tasks.removeValue(forKey: id) {
            task.cancel()
        }
    }

    public func cancelAll() {
        let snapshot = tasks
        tasks.removeAll()
        for (_, task) in snapshot {
            task.cancel()
        }
    }
}
