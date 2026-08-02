import CodeEditorDAP
import CodeEditorTerminal
import Foundation

/// DAP `runInTerminal` → shared `TerminalService` (audit §14.5 / TER-006).
public actor GhosttyRunInTerminalHandler: DAPRunInTerminalHandler {
    private let service: TerminalService
    private let transportFactory: @Sendable () -> any TerminalByteTransport

    public init(
        service: TerminalService,
        transportFactory: @escaping @Sendable () -> any TerminalByteTransport
    ) {
        self.service = service
        self.transportFactory = transportFactory
    }

    public func runInTerminal(args: DAPRunInTerminalArgs) async throws -> DAPRunInTerminalResult {
        var cfg = TerminalConfiguration()
        if let cwd = args.cwd {
            cfg.cwd = URL(fileURLWithPath: cwd)
        }
        if let env = args.env {
            cfg.environment = env
        }
        if let first = args.args.first {
            cfg.shell = URL(fileURLWithPath: first)
            cfg.arguments = Array(args.args.dropFirst())
        }
        let meta = TerminalMetadata(
            kind: .debuggee,
            title: args.title ?? "Debug Terminal",
            debugSessionID: "dap"
        )
        let transport = transportFactory()
        let id = try await service.create(
            metadata: meta,
            configuration: cfg,
            transport: transport
        )
        let sessions = await service.allSessions()
        let pid32 = sessions.first(where: { $0.id == id })?.processId
        let pid = pid32.map { Int($0) }
        return DAPRunInTerminalResult(processId: pid, shellProcessId: pid)
    }
}
