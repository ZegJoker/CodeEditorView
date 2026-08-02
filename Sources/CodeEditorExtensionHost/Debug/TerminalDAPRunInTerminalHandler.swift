import CodeEditorDAP
import CodeEditorTerminal
import Foundation

/// Bridges DAP `runInTerminal` reverse requests to the stable ``TerminalService`` facade (DAP-N08).
///
/// Production path is TerminalService-only; Ghostty-backed sessions are created via
/// host-injected transport factories (no legacy session-manager coupling).
public struct TerminalDAPRunInTerminalHandler: DAPRunInTerminalHandler {
    public let service: TerminalService
    public let transportFactory: @Sendable () -> any TerminalByteTransport

    public init(
        service: TerminalService,
        transportFactory: @escaping @Sendable () -> any TerminalByteTransport
    ) {
        self.service = service
        self.transportFactory = transportFactory
    }

    public func runInTerminal(args: DAPRunInTerminalArgs) async throws -> DAPRunInTerminalResult {
        guard !args.args.isEmpty else {
            throw DAPError.unsupported("runInTerminal requires args")
        }
        let policy = await service.securityPolicy
        if !policy.workspaceTrusted {
            throw DAPError.unsupported("runInTerminal denied: workspace untrusted")
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
        let meta = TerminalMetadata(
            kind: .debuggee,
            title: args.title ?? "Debug",
            debugSessionID: "dap"
        )
        let transport = transportFactory()
        let id = try await service.create(
            metadata: meta,
            configuration: config,
            transport: transport
        )
        let sessions = await service.allSessions()
        let pid32 = sessions.first(where: { $0.id == id })?.processId
        let pid = pid32.map { Int($0) }
        guard sessions.contains(where: { $0.id == id && $0.isRunning }) else {
            throw DAPError.unsupported("terminal session failed to start")
        }
        return DAPRunInTerminalResult(processId: pid, shellProcessId: pid)
    }
}
