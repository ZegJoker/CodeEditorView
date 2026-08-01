import Foundation
import Testing

@testable import CodeEditorTerminal
@testable import CodeEditorTerminalGhostty

@Suite("Ghostty shim (TER-001)")
struct GhosttyShimTests {
    @Test func shimABIIsPositive() {
        #expect(GhosttySessionController.shimABI == 1)
    }

    @Test func surfaceWriteAndSnapshot() async throws {
        let controller = GhosttySessionController(cols: 40, rows: 12)
        try await controller.write(Data("hello ghostty\n".utf8))
        let snap = try await controller.snapshotUTF8()
        #expect(snap.contains("hello ghostty"))
        try await controller.resize(cols: 80, rows: 24)
    }
}
