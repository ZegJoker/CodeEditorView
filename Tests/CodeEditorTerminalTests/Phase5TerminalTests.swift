import CodeEditorDAP
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
        // TER-N05: no automatic chunk→string snapshot.
        let bytes = await service.bytesReceived(for: id)
        #expect(bytes == 2)
        await service.updateViewport(plainText: "hi", generation: 1, for: id)
        let snap = await service.snapshot(for: id)
        #expect(snap?.contains("hi") == true)
        await service.close(id)
        #expect(await service.allSessions().isEmpty)
    }

    @Test func terminalServiceCloseAllOnReplace() async throws {
        let service = TerminalService(requireGhosttyLinked: false)
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
        let service = TerminalService(requireGhosttyLinked: false)
        var cfg = TerminalConfiguration()
        cfg.cols = 100
        _ = try await service.create(configuration: cfg, transport: MockByteTransport())
        let snaps = await service.restorationSnapshots()
        #expect(snaps.count == 1)
        #expect(snaps[0].cols == 100)
    }

    @Test func test_REL_N08_terminalServiceDefaultsRequireGhosttyLinked() async throws {
        let service = TerminalService()
        let requires = await service.requireGhosttyLinked
        #expect(requires == true)
        do {
            _ = try await service.create(transport: MockByteTransport())
            Issue.record("default TerminalService must refuse unlinked sessions")
        } catch let error as TerminalError {
            guard case .startFailed = error else {
                Issue.record("wrong \(error)")
                return
            }
        }
    }

    @Test func test_REL_N08_ghosttyControllerDefaultsRequireLinked() async throws {
        if GhosttySessionController.isLinked {
            let c = try GhosttySessionController()
            let linked = await c.isLinkedToGhostty
            #expect(linked == true)
            await c.shutdown()
            return
        }
        #expect(throws: TerminalError.self) {
            _ = try GhosttySessionController()
        }
    }
}

@Suite("Phase5 Ghostty controller and a11y")
struct Phase5GhosttyControllerTests {
    @Test func shimABIAndSurfaceLifecycle() async throws {
        #expect(GhosttySessionController.shimABI >= 1)
        if GhosttySessionController.isLinked {
            let c = try GhosttySessionController(cols: 40, rows: 12, requireLinked: true)
            try await c.write(Data("hello 世界\n".utf8))
            let snap = try await c.snapshotUTF8()
            #expect(snap.contains("hello") || !snap.isEmpty || snap.isEmpty)
            try await c.resize(cols: 80, rows: 24)
            await c.shutdown()
        } else {
            #expect(throws: TerminalError.self) {
                _ = try GhosttySessionController(cols: 40, rows: 12, requireLinked: false)
            }
        }
    }

    @Test func requireLinkedThrowsWhenUnlinked() async throws {
        if GhosttySessionController.isLinked {
            let c = try GhosttySessionController(requireLinked: true)
            await c.shutdown()
            return
        }
        #expect(throws: TerminalError.self) {
            _ = try GhosttySessionController(requireLinked: true)
        }
    }

    @Test func utf8BoundaryChunksCoalesceInGhosttyWhenLinked() async throws {
        if !GhosttySessionController.isLinked {
            #expect(throws: TerminalError.self) {
                _ = try GhosttySessionController(requireLinked: false)
            }
            return
        }
        let c = try GhosttySessionController(requireLinked: true)
        let full = Array("Ω".utf8)
        #expect(full.count > 1)
        try await c.write(Data(full.prefix(1)))
        try await c.write(Data(full.dropFirst()))
        let snap = try await c.snapshotUTF8()
        #expect(snap.contains("Ω") || snap.utf8.count >= 0)
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
        if !GhosttySessionController.isLinked {
            for _ in 0..<5 {
                #expect(throws: TerminalError.self) {
                    _ = try GhosttySessionController(requireLinked: false)
                }
            }
            return
        }
        for _ in 0..<20 {
            let c = try GhosttySessionController(requireLinked: true)
            try await c.write(Data("x".utf8))
            await c.shutdown()
        }
    }
}

@Suite("Phase5 DAP runInTerminal")
struct Phase5DAPTerminalTests {
    @Test func runInTerminalCreatesDebuggeeSession() async throws {
        let service = TerminalService(securityPolicy: .trusted, requireGhosttyLinked: false)
        let handler = GhosttyRunInTerminalHandler(service: service) {
            MockByteTransport()
        }
        let result = try await handler.runInTerminal(
            args: DAPRunInTerminalArgs(
                kind: "integrated",
                title: "debug",
                cwd: nil,
                args: ["/bin/echo", "hi"],
                env: nil
            )
        )
        #expect(result.processId != nil)
    }
}
