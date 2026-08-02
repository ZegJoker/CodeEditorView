import Foundation
import Testing

@testable import CodeEditorTerminal
@testable import CodeEditorTerminalGhostty

@Suite("Phase5 transport and service")
struct Phase5TransportServiceTests {
    @Test func mockTransportOrderedEchoNoDrop() async throws {
        let transport = MockByteTransport()
        let info = try await transport.start(TerminalLaunchRequest())
        #expect(info.processId == 1)
        final class Box: @unchecked Sendable {
            var chunks: [Data] = []
        }
        let box = Box()
        let stream = await transport.events
        let collector = Task {
            for try await event in stream {
                if case .output(let d) = event {
                    box.chunks.append(d)
                    if box.chunks.count >= 3 { break }
                }
            }
        }
        try await transport.write(Data("a".utf8))
        try await transport.write(Data("b".utf8))
        try await transport.write(Data("c".utf8))
        try await Task.sleep(nanoseconds: 30_000_000)
        collector.cancel()
        #expect(box.chunks == [Data("a".utf8), Data("b".utf8), Data("c".utf8)])
        await transport.terminate(.user)
    }

    @Test func overflowTerminatesVisibly() async throws {
        let transport = MockByteTransport()
        _ = try await transport.start(TerminalLaunchRequest())
        await transport.configureOverflow("full")
        do {
            try await transport.write(Data("x".utf8))
            Issue.record("expected overflow throw")
        } catch {
            // expected
        }
    }

    @Test func terminalServiceCreateWriteClose() async throws {
        let service = TerminalService(requireGhosttyLinked: false)
        let transport = MockByteTransport()
        let id = try await service.create(
            metadata: TerminalMetadata(title: "T"),
            transport: transport
        )
        #expect(await service.allSessions().count == 1)
        try await service.write("hi", to: id)
        try await Task.sleep(nanoseconds: 20_000_000)
        let snap = await service.snapshot(for: id)
        #expect(snap?.contains("hi") == true)
        await service.close(id)
        #expect(await service.allSessions().isEmpty)
    }

    @Test func terminalServiceCloseAllOnReplace() async throws {
        let service = TerminalService()
        let id1 = try await service.create(transport: MockByteTransport())
        let id2 = try await service.create(transport: MockByteTransport())
        #expect(await service.allSessions().count == 2)
        await service.closeAll(reason: .replaced)
        #expect(await service.allSessions().isEmpty)
        _ = (id1, id2)
    }

    @Test func requireGhosttyLinkedFailsClosed() async throws {
        let service = TerminalService(
            requireGhosttyLinked: true,
            isGhosttyLinked: { false }
        )
        do {
            _ = try await service.create(transport: MockByteTransport())
            Issue.record("expected fail closed")
        } catch let error as TerminalError {
            guard case .startFailed = error else {
                Issue.record("wrong \(error)")
                return
            }
        }
    }

    @Test func restorationIsConfigOnly() async throws {
        let service = TerminalService()
        var cfg = TerminalConfiguration()
        cfg.cols = 100
        _ = try await service.create(configuration: cfg, transport: MockByteTransport())
        let snaps = await service.restorationSnapshots()
        #expect(snaps.count == 1)
        #expect(snaps[0].cols == 100)
    }
}

@Suite("Phase5 Ghostty controller and a11y")
struct Phase5GhosttyControllerTests {
    @Test func shimABIAndSurfaceLifecycle() async throws {
        #expect(GhosttySessionController.shimABI == 1)
        let c = try GhosttySessionController(cols: 40, rows: 12, requireLinked: false)
        try await c.write(Data("hello 世界\n".utf8))
        let snap = try await c.snapshotUTF8()
        #expect(snap.contains("hello"))
        try await c.resize(cols: 80, rows: 24)
        await c.shutdown()
    }

    @Test func requireLinkedThrowsWhenUnlinked() throws {
        // In default CI, Ghostty is typically unlinked.
        if GhosttySessionController.isLinked {
            // Environment has linked Ghostty — skip fail-closed assertion.
            return
        }
        #expect(throws: TerminalError.self) {
            _ = try GhosttySessionController(requireLinked: true)
        }
    }

    @Test func utf8BoundaryChunksCoalesceInSnapshot() async throws {
        let c = try GhosttySessionController(requireLinked: false)
        // Split multi-byte UTF-8 across writes (ordered feed, no drop).
        let full = Array("Ω".utf8)  // multi-byte
        #expect(full.count > 1)
        try await c.write(Data(full.prefix(1)))
        try await c.write(Data(full.dropFirst()))
        let snap = try await c.snapshotUTF8()
        #expect(snap.utf8.count >= full.count)
        await c.shutdown()
    }

    @Test func accessibilityAdapterFromSnapshot() {
        let a = GhosttyAccessibilityAdapter.from(
            snapshot: "line1\nline2",
            title: "Shell",
            isRunning: true
        )
        #expect(a.accessibilityLabel.contains("Shell"))
        #expect(a.accessibilityValue.contains("line2"))
        #expect(a.cursorLine == 1)
    }

    @Test func securityPolicyOSC52DeniedByDefault() {
        #expect(TerminalSecurityPolicy.restricted.allowsOSC52Write() == false)
        #expect(TerminalSecurityPolicy.restricted.allowsShellIntegrationInjection() == false)
        #expect(TerminalSecurityPolicy.trusted.allowsShellIntegrationInjection() == true)
    }

    @Test func soakCreateCloseControllers() async throws {
        for _ in 0..<20 {
            let c = try GhosttySessionController(requireLinked: false)
            try await c.write(Data("x".utf8))
            await c.shutdown()
        }
    }
}

@Suite("Phase5 DAP runInTerminal")
struct Phase5DAPTerminalTests {
    @Test func runInTerminalCreatesDebuggeeSession() async throws {
        let service = TerminalService()
        let handler = GhosttyRunInTerminalHandler(service: service) {
            MockByteTransport()
        }
        let result = try await handler.runInTerminal(
            args: DAPRunInTerminalArgs(
                kind: "integrated",
                title: "Debug",
                cwd: nil,
                args: ["/bin/sh", "-c", "echo hi"],
                env: nil
            )
        )
        #expect(result.processId != nil)
        let sessions = await service.allSessions()
        #expect(sessions.contains { $0.metadata.kind == .debuggee })
        await service.closeAll()
    }
}

// Import DAP types via TerminalGhostty
import CodeEditorDAP
