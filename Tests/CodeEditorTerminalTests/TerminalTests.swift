import Foundation
import Testing
@testable import CodeEditorTerminal

@Suite("Terminal")
struct TerminalTests {
    @Test func mockBackendEcho() async throws {
        let backend = MockTerminalBackend()
        let handle = try await backend.start(configuration: TerminalConfiguration())
        final class Box: @unchecked Sendable {
            var got: Data?
        }
        let box = Box()
        let stream = await backend.output
        let collector = Task {
            for await event in stream {
                if case .data(_, let bytes) = event {
                    box.got = bytes
                    break
                }
            }
        }
        try await backend.write(Data("hi".utf8), to: handle.id)
        try await Task.sleep(nanoseconds: 20_000_000)
        collector.cancel()
        #expect(box.got == Data("hi".utf8))
        await backend.terminate(session: handle.id)
    }

    @Test func sessionManagerLifecycle() async throws {
        let backend = MockTerminalBackend()
        let manager = TerminalSessionManager()
        await manager.attach(backend: backend)
        let session = try await manager.create(title: "Test")
        #expect(await manager.allSessions().count == 1)
        #expect(await manager.panelDescriptor(for: session.id)?.title == "Test")
        try await manager.write("x", to: session.id)
        await manager.close(session.id)
        #expect(await manager.allSessions().isEmpty)
    }
}
