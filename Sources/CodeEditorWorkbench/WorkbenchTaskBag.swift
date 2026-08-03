import Foundation

/// Owns unstructured `Task` work for a workbench lifecycle scope (WB-N05).
///
/// Scopes: window, pane, tab, panel, contribution, or the primary ``WorkbenchModel``.
/// Call ``cancelAll()`` on deactivation / tear-down; critical shutdown should await
/// cancellation before releasing shared resources.
///
/// Thread-safe so panel `deinit` and non-MainActor I/O completion can cancel without hopping.
public final class WorkbenchTaskBag: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [UUID: Task<Void, Never>] = [:]
    /// Monotonic count of all tasks ever stored (observability / tests).
    public private(set) var totalStored: UInt64 = 0
    /// Logical scope label for diagnostics (window/pane/panel/contribution).
    public let scope: String

    public init(scope: String = "workbench") {
        self.scope = scope
    }

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return tasks.count
    }

    /// Store a fire-and-forget task. Returns its bag id.
    @discardableResult
    public func store(_ task: Task<Void, Never>) -> UUID {
        let id = UUID()
        lock.lock()
        tasks[id] = task
        totalStored &+= 1
        lock.unlock()
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

    /// Convenience: launch and retain an unstructured detached-from-caller task.
    @discardableResult
    public func detached(_ body: @escaping @Sendable () async -> Void) -> UUID {
        store(
            Task {
                await body()
            }
        )
    }

    public func cancel(_ id: UUID) {
        lock.lock()
        let task = tasks.removeValue(forKey: id)
        lock.unlock()
        task?.cancel()
    }

    public func cancelAll() {
        lock.lock()
        let snapshot = tasks
        tasks.removeAll()
        lock.unlock()
        for (_, task) in snapshot {
            task.cancel()
        }
    }
}
