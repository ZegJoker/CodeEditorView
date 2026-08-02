import Foundation

/// Cursor blink driven by structured concurrency (`Task` + `Clock`), not `Timer` or Combine.
///
/// Call from the main actor (UI hosts). Uses `Task` + `ContinuousClock` instead of `Timer`/Combine.
package final class CursorBlinkController: @unchecked Sendable {
    public private(set) var isVisible: Bool = true
    public var onChange: (@MainActor (Bool) -> Void)?

    private var task: Task<Void, Never>?
    private var interval: Duration = .milliseconds(500)

    public init() {}

    @MainActor
    public func start(interval: Duration = .milliseconds(500)) {
        self.interval = interval
        stop()
        isVisible = true
        onChange?(true)
        // Reduced-motion-safe: keep caret solidly visible (UI-N10).
        if !EditorAccessibility.currentMotionPolicy.animateCaretBlink {
            return
        }
        task = Task { @MainActor [weak self] in
            let clock = ContinuousClock()
            while !Task.isCancelled {
                try? await clock.sleep(for: interval)
                guard let self, !Task.isCancelled else { return }
                // Re-check system preference each tick so changes apply live.
                if !EditorAccessibility.currentMotionPolicy.animateCaretBlink {
                    self.isVisible = true
                    self.onChange?(true)
                    return
                }
                self.isVisible.toggle()
                self.onChange?(self.isVisible)
            }
        }
    }

    @MainActor
    public func reset() {
        isVisible = true
        onChange?(true)
        start(interval: interval)
    }

    @MainActor
    public func stop() {
        task?.cancel()
        task = nil
        isVisible = false
        onChange?(false)
    }

    deinit {
        task?.cancel()
    }
}
