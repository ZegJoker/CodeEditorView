import CodeEditorDAP
import CodeEditorTerminal
import Foundation

/// Bridges DAP `runInTerminal` reverse requests to a real ``TerminalSessionManager`` backend.
public struct TerminalDAPRunInTerminalHandler: DAPRunInTerminalHandler {
    public let manager: TerminalSessionManager

    public init(manager: TerminalSessionManager) {
        self.manager = manager
    }

    public func runInTerminal(args: DAPRunInTerminalArgs) async throws -> DAPRunInTerminalResult {
        guard !args.args.isEmpty else {
            throw DAPError.unsupported("runInTerminal requires args")
        }
        var config = TerminalConfiguration()
        if let cwd = args.cwd {
            config.cwd = URL(fileURLWithPath: cwd)
        }
        if let env = args.env {
            config.environment = env
        }
        // First arg is executable; remaining are shell arguments.
        let executable = args.args[0]
        config.shell = URL(fileURLWithPath: executable)
        config.arguments = Array(args.args.dropFirst())
        let title = args.title ?? "Debug"
        let session = try await manager.create(title: title, configuration: config)
        // Process backends expose no public PID on TerminalSession; use 0 when unavailable.
        // Session id hash as stable stand-in only when process id unknown is not allowed —
        // require the backend to be running.
        guard session.isRunning else {
            throw DAPError.unsupported("terminal session failed to start")
        }
        return DAPRunInTerminalResult(processId: nil, shellProcessId: nil)
    }
}

/// Shared counter for proving terminal reverse-request invocations.
public final class TerminalInvokeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    private var _lastArgs: [String] = []

    public init() {}

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return _count
    }
    public var lastArgs: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _lastArgs
    }
    public func record(_ args: [String]) {
        lock.lock()
        _count += 1
        _lastArgs = args
        lock.unlock()
    }
}

/// Test/mock backend-backed handler that records invocations and returns a real session start.
public struct MockTerminalDAPRunInTerminalHandler: DAPRunInTerminalHandler {
    public let backend: MockTerminalBackend
    public let manager: TerminalSessionManager
    public let counter: TerminalInvokeCounter

    public init(
        backend: MockTerminalBackend, manager: TerminalSessionManager,
        counter: TerminalInvokeCounter = TerminalInvokeCounter()
    ) {
        self.backend = backend
        self.manager = manager
        self.counter = counter
    }

    public static func make() async -> MockTerminalDAPRunInTerminalHandler {
        let backend = MockTerminalBackend()
        let manager = TerminalSessionManager()
        await manager.attach(backend: backend)
        return MockTerminalDAPRunInTerminalHandler(backend: backend, manager: manager)
    }

    public func runInTerminal(args: DAPRunInTerminalArgs) async throws -> DAPRunInTerminalResult {
        guard !args.args.isEmpty else {
            throw DAPError.unsupported("runInTerminal requires args")
        }
        counter.record(args.args)
        var config = TerminalConfiguration()
        if let cwd = args.cwd {
            config.cwd = URL(fileURLWithPath: cwd)
        }
        let session = try await manager.create(title: args.title ?? "Debug", configuration: config)
        // Write command line into the mock terminal so the reverse request is observable.
        let line = args.args.joined(separator: " ") + "\n"
        try await manager.write(line, to: session.id)
        return DAPRunInTerminalResult(processId: 1, shellProcessId: 1)
    }
}
