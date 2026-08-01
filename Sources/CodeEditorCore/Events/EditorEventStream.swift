import Foundation

/// Fan-out broadcaster for editor events using bounded `AsyncStream` policies (DOC-009 / §7.11).
///
/// | Stream | Policy |
/// |---|---|
/// | Events | bounded (newest) + drop counter |
/// | Text snapshots | `bufferingNewest(1)` |
/// | Selection | `bufferingNewest(1)` |
@MainActor
public final class EditorEventStream {
    public static let defaultEventBuffer = 64

    private var continuations: [UUID: AsyncStream<EditorEvent>.Continuation] = [:]
    private var textContinuations: [UUID: AsyncStream<String>.Continuation] = [:]
    private var selectionContinuations: [UUID: AsyncStream<[NSRange]>.Continuation] = [:]

    /// Number of event yields dropped due to full buffers (telemetry).
    public private(set) var droppedEventCount: Int = 0

    public init() {}

    public func makeEventStream(
        bufferSize: Int = EditorEventStream.defaultEventBuffer
    ) -> AsyncStream<EditorEvent> {
        let policy: AsyncStream<EditorEvent>.Continuation.BufferingPolicy =
            bufferSize <= 0
            ? .unbounded
            : .bufferingNewest(bufferSize)
        return AsyncStream(bufferingPolicy: policy) { continuation in
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
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
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
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
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
            let result = continuation.yield(event)
            if case .dropped = result {
                droppedEventCount += 1
            }
        }
    }

    public func yieldText(_ text: String) {
        for continuation in textContinuations.values {
            _ = continuation.yield(text)
        }
    }

    public func yieldSelection(_ ranges: [NSRange]) {
        for continuation in selectionContinuations.values {
            _ = continuation.yield(ranges)
        }
    }
}
