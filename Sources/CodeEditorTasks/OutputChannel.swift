import CodeEditorCore
import Foundation

public struct OutputLine: Sendable, Hashable {
    public var text: String
    public var isError: Bool
    public var date: Date

    public init(text: String, isError: Bool = false, date: Date = Date()) {
        self.text = text
        self.isError = isError
        self.date = date
    }
}

/// Bounded task/process output channel (TASK-N03/N04/N08).
///
/// Retains at most `maxLines`. Emits **one** truncation marker when the cap is
/// first exceeded (not repeated per later chunk). Producer owns finish exactly once.
public final class OutputChannel: @unchecked Sendable {
    public let id: String
    public let name: String
    public let maxLines: Int
    private let lock = NSLock()
    private var _lines: [OutputLine] = []
    private var didTruncate = false
    private var _droppedLineCount = 0
    private var continuation: AsyncStream<OutputLine>.Continuation?
    private var _finished = false
    private var finishReason: StreamFinishReason?
    public let lines: AsyncStream<OutputLine>

    public init(id: String, name: String, maxLines: Int = 10_000) {
        self.id = id
        self.name = name
        self.maxLines = max(1, maxLines)
        var cont: AsyncStream<OutputLine>.Continuation!
        self.lines = AsyncStream { cont = $0 }
        self.continuation = cont
    }

    public var snapshot: [OutputLine] {
        lock.lock()
        defer { lock.unlock() }
        return _lines
    }

    public var wasTruncated: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didTruncate
    }

    public var droppedLineCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _droppedLineCount
    }

    public var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _finished
    }

    public func append(_ line: OutputLine) {
        lock.lock()
        if _finished {
            lock.unlock()
            return
        }
        _lines.append(line)
        var truncationLine: OutputLine?
        if _lines.count > maxLines {
            let overflow = _lines.count - maxLines
            _droppedLineCount += overflow
            if !didTruncate {
                didTruncate = true
                // Drop oldest content lines, then pin a single truncation marker at front.
                _lines.removeFirst(overflow)
                truncationLine = OutputLine(
                    text: "[output truncated; dropped \(_droppedLineCount) lines]",
                    isError: true
                )
                _lines.insert(truncationLine!, at: 0)
                if _lines.count > maxLines {
                    _lines.removeLast(_lines.count - maxLines)
                }
            } else {
                // Already truncated: preserve marker at [0], drop following oldest content.
                let contentCap = max(0, maxLines - 1)
                let contentCount = max(0, _lines.count - 1)
                if contentCount > contentCap {
                    let drop = contentCount - contentCap
                    _lines.removeSubrange(1..<(1 + drop))
                }
                if !_lines.isEmpty {
                    _lines[0] = OutputLine(
                        text: "[output truncated; dropped \(_droppedLineCount) lines]",
                        isError: true
                    )
                }
            }
        }
        let cont = continuation
        lock.unlock()
        cont?.yield(line)
        if let truncationLine {
            cont?.yield(truncationLine)
        }
    }

    public func append(text: String, isError: Bool = false) {
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            append(OutputLine(text: String(raw), isError: isError))
        }
    }

    public func clear() {
        lock.lock()
        _lines.removeAll()
        didTruncate = false
        _droppedLineCount = 0
        lock.unlock()
    }

    /// Producer owns completion exactly once (TASK-N08). Further appends are ignored.
    public func finish(reason: StreamFinishReason = .completed) {
        lock.lock()
        if _finished {
            lock.unlock()
            return
        }
        _finished = true
        finishReason = reason
        let cont = continuation
        continuation = nil
        lock.unlock()
        cont?.finish()
    }
}

public actor OutputChannelRegistry {
    private var channels: [String: OutputChannel] = [:]

    public init() {}

    public func channel(id: String, name: String) -> OutputChannel {
        if let existing = channels[id] { return existing }
        let ch = OutputChannel(id: id, name: name)
        channels[id] = ch
        return ch
    }

    public func all() -> [OutputChannel] {
        Array(channels.values).sorted { $0.id < $1.id }
    }

    /// Finish every channel (window/service teardown — TASK-N08).
    public func finishAll(reason: StreamFinishReason = .cancelled) {
        for ch in channels.values {
            ch.finish(reason: reason)
        }
    }
}
