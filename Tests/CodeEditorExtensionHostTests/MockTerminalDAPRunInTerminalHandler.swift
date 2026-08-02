import CodeEditorDAP
import CodeEditorTerminal
import Foundation

/// Shared counter for proving terminal reverse-request invocations (test support only).
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

/// Test-only `runInTerminal` handler backed by ``TerminalService`` + ``MockByteTransport`` (DAP-N08).
public struct MockTerminalDAPRunInTerminalHandler: DAPRunInTerminalHandler {
    public let service: TerminalService
    public let counter: TerminalInvokeCounter

    public init(
        service: TerminalService,
        counter: TerminalInvokeCounter = TerminalInvokeCounter()
    ) {
        self.service = service
        self.counter = counter
    }

    public static func make() async -> MockTerminalDAPRunInTerminalHandler {
        let service = TerminalService(securityPolicy: .trusted, requireGhosttyLinked: false)
        return MockTerminalDAPRunInTerminalHandler(service: service)
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
        if let env = args.env {
            config.environment = env
        }
        config.shell = URL(fileURLWithPath: args.args[0])
        config.arguments = Array(args.args.dropFirst())
        let meta = TerminalMetadata(
            kind: .debuggee,
            title: args.title ?? "Debug",
            debugSessionID: "test-dap"
        )
        let id = try await service.create(
            metadata: meta,
            configuration: config,
            transport: MockByteTransport()
        )
        // Write command line so reverse request is observable on the mock transport path.
        let line = args.args.joined(separator: " ") + "\n"
        try await service.write(line, to: id)
        let sessions = await service.allSessions()
        let pid = sessions.first(where: { $0.id == id })?.processId.map { Int($0) }
        return DAPRunInTerminalResult(processId: pid ?? 1, shellProcessId: pid ?? 1)
    }
}
