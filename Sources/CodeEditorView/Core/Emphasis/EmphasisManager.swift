import Foundation

/// Manages range emphases; flash removal uses structured concurrency (no Timer/Combine).
@MainActor
public final class EmphasisManager {
    public private(set) var items: [Emphasis] = []
    public var onChange: (() -> Void)?

    private var flashTasks: [UUID: Task<Void, Never>] = [:]

    public init() {}

    public func add(_ emphasis: Emphasis) {
        items.append(emphasis)
        if emphasis.selectInDocument {
            // Consumer (controller) may observe and apply selection.
        }
        if emphasis.flash {
            scheduleFlashRemoval(id: emphasis.id)
        }
        onChange?()
    }

    public func remove(id: UUID) {
        items.removeAll { $0.id == id }
        flashTasks[id]?.cancel()
        flashTasks[id] = nil
        onChange?()
    }

    public func removeAll(in group: String? = nil) {
        if let group {
            let removed = items.filter { $0.group == group }.map(\.id)
            items.removeAll { $0.group == group }
            for id in removed {
                flashTasks[id]?.cancel()
                flashTasks[id] = nil
            }
        } else {
            items.removeAll()
            for task in flashTasks.values { task.cancel() }
            flashTasks.removeAll()
        }
        onChange?()
    }

    public func emphases(overlapping range: NSRange) -> [Emphasis] {
        items.filter { NSIntersectionRange($0.range, range).length > 0 || $0.range.length == 0 && NSLocationInRange($0.range.location, range) }
    }

    private func scheduleFlashRemoval(id: UUID) {
        flashTasks[id]?.cancel()
        flashTasks[id] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.remove(id: id)
        }
    }

}
