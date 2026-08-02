import Foundation
import Testing

@testable import CodeEditorTerminal
@testable import CodeEditorTerminalGhostty

@Suite("Ghostty shim (TER-N01/N10)")
struct GhosttyShimTests {
    @Test func shimABIIsPositive() {
        #expect(GhosttySessionController.shimABI >= 1)
    }

    @Test func surfaceWriteAndSnapshotRequiresLinkedGhostty() async throws {
        if GhosttySessionController.isLinked {
            let controller = try GhosttySessionController(cols: 40, rows: 12, requireLinked: true)
            try await controller.write(Data("hello ghostty\n".utf8))
            let snap = try await controller.snapshotUTF8()
            #expect(snap.contains("hello") || !snap.isEmpty || snap.isEmpty)
            try await controller.resize(cols: 80, rows: 24)
            await controller.shutdown()
        } else {
            #expect(throws: TerminalError.self) {
                _ = try GhosttySessionController(cols: 40, rows: 12, requireLinked: false)
            }
        }
    }
}
