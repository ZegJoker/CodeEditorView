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

public final class OutputChannel: @unchecked Sendable {
    public let id: String
    public let name: String
    private let lock = NSLock()
    private var _lines: [OutputLine] = []
    private var continuation: AsyncStream<OutputLine>.Continuation?
    public let lines: AsyncStream<OutputLine>

    public init(id: String, name: String) {
        self.id = id
        self.name = name
        var cont: AsyncStream<OutputLine>.Continuation!
        self.lines = AsyncStream { cont = $0 }
        self.continuation = cont
    }

    public var snapshot: [OutputLine] {
        lock.lock()
        defer { lock.unlock() }
        return _lines
    }

    public func append(_ line: OutputLine) {
        lock.lock()
        _lines.append(line)
        let cont = continuation
        lock.unlock()
        cont?.yield(line)
    }

    public func append(text: String, isError: Bool = false) {
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            append(OutputLine(text: String(raw), isError: isError))
        }
    }

    public func clear() {
        lock.lock()
        _lines.removeAll()
        lock.unlock()
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
}
