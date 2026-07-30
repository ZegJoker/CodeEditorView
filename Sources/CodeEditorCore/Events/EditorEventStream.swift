import Foundation

/// Fan-out broadcaster for editor events using `AsyncStream` (no Combine).
@MainActor
public final class EditorEventStream {
    private var continuations: [UUID: AsyncStream<EditorEvent>.Continuation] = [:]
    private var textContinuations: [UUID: AsyncStream<String>.Continuation] = [:]
    private var selectionContinuations: [UUID: AsyncStream<[NSRange]>.Continuation] = [:]

    public init() {}

    public func makeEventStream() -> AsyncStream<EditorEvent> {
        AsyncStream { continuation in
            let id = UUID()
            self.continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in
                    self?.continuations[id] = nil
                }
            }
        }
    }

    public func makeTextStream() -> AsyncStream<String> {
        AsyncStream { continuation in
            let id = UUID()
            self.textContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in
                    self?.textContinuations[id] = nil
                }
            }
        }
    }

    public func makeSelectionStream() -> AsyncStream<[NSRange]> {
        AsyncStream { continuation in
            let id = UUID()
            self.selectionContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in
                    self?.selectionContinuations[id] = nil
                }
            }
        }
    }

    public func yield(_ event: EditorEvent) {
        for continuation in continuations.values {
            continuation.yield(event)
        }
    }

    public func yieldText(_ text: String) {
        for continuation in textContinuations.values {
            continuation.yield(text)
        }
    }

    public func yieldSelection(_ ranges: [NSRange]) {
        for continuation in selectionContinuations.values {
            continuation.yield(ranges)
        }
    }

}
