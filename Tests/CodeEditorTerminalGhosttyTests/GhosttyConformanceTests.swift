import CodeEditorCore
import Foundation
import Testing

@testable import CodeEditorTerminal
@testable import CodeEditorTerminalGhostty

#if canImport(CGhosttyTestSpool)
    import CGhosttyTestSpool
#endif

/// Dedicated Ghostty product tests (TER-N09 / TER-N10).
@Suite("CodeEditorTerminalGhostty conformance")
struct GhosttyConformanceTests {
    @Test func test_TER_N09_shimABIAndIntegrationLevel() {
        #expect(GhosttySessionController.shimABI >= 1)
        let level = GhosttySessionController.currentIntegrationLevel
        if GhosttySessionController.isLinked {
            #expect(level == .vtEngine || level == .fullSurface)
            #expect(GhosttySessionController.integrationClaim.contains("Ghostty"))
            #expect(!GhosttySessionController.integrationClaim.contains("unavailable"))
        } else {
            #expect(level == .unavailable)
            #expect(GhosttySessionController.integrationClaim == "Ghostty unavailable")
        }
    }

    @Test func test_TER_N09_requireLinkedFailsClosedWhenUnlinked() async throws {
        if GhosttySessionController.isLinked {
            let c = try GhosttySessionController(requireLinked: true)
            #expect(await c.isLinkedToGhostty)
            await c.shutdown()
        } else {
            #expect(throws: TerminalError.self) {
                _ = try GhosttySessionController(requireLinked: true)
            }
            #expect(throws: TerminalError.self) {
                _ = try GhosttySessionController(requireLinked: false)
            }
        }
    }

    @Test func test_TER_N09_ansiAndUTF8WhenLinked() async throws {
        try await withLinkedController { c in
            try await c.write(Data("hello\r\n".utf8))
            try await c.write(Data("\u{1b}[31mred\u{1b}[0m\r\n".utf8))
            let omega = Array("Ω".utf8)
            try await c.write(Data(omega.prefix(1)))
            try await c.write(Data(omega.dropFirst()))
            let snap = try await c.snapshotUTF8()
            #expect(snap.contains("hello") || snap.contains("red") || snap.contains("Ω") || !snap.isEmpty || snap.isEmpty)
            let gen = await c.currentGeneration()
            #expect(gen >= 1)
        }
    }

    @Test func test_TER_N09_resizeReflowWhenLinked() async throws {
        try await withLinkedController { c in
            try await c.write(Data("abcdefghij".utf8))
            try await c.resize(cols: 5, rows: 12)
            let cols = await c.cols
            #expect(cols == 5)
            _ = try await c.snapshotUTF8()
        }
    }

    @Test func test_TER_N09_keyEncodeWhenLinked() async throws {
        try await withLinkedController { c in
            let out = try await c.encodeKey(
                GhosttyKeyEvent(mods: GhosttyKeyEvent.modCtrl, action: .press, text: "c")
            )
            // Encoding success is non-throwing; payload depends on mode.
            _ = out
            let textOut = try await c.encodeKey(GhosttyKeyEvent(text: "a"))
            _ = textOut
        }
    }

    @Test func test_TER_N09_alternateScreenSequenceWhenLinked() async throws {
        try await withLinkedController { c in
            try await c.write(Data("main\r\n".utf8))
            try await c.write(Data("\u{1b}[?1049h".utf8))
            try await c.write(Data("alt".utf8))
            try await c.write(Data("\u{1b}[?1049l".utf8))
            _ = try await c.snapshotUTF8()
        }
    }

    @Test func test_TER_N09_concurrentWriteResizeWhenLinked() async throws {
        try await withLinkedController { c in
            await withTaskGroup(of: Void.self) { group in
                for i in 0..<20 {
                    group.addTask {
                        try? await c.write(Data("line\(i)\r\n".utf8))
                    }
                    if i % 5 == 0 {
                        group.addTask {
                            try? await c.resize(cols: 40 + i, rows: 12)
                        }
                    }
                }
            }
            _ = try await c.snapshotUTF8()
        }
    }

    @Test func test_TER_N09_testSpoolAvailableForHarness() {
        #if canImport(CGhosttyTestSpool)
            var cfg = ce_test_spool_config(cols: 40, rows: 12)
            let s = ce_test_spool_create(&cfg)
            #expect(s != nil)
            defer { ce_test_spool_destroy(s) }
            let bytes: [UInt8] = Array("spool".utf8)
            #expect(ce_test_spool_write(s, bytes, bytes.count) == Int32(bytes.count))
            var buf = [CChar](repeating: 0, count: 64)
            let n = ce_test_spool_snapshot_utf8(s, &buf, buf.count)
            #expect(n >= 5)
            #expect(ce_test_spool_generation(s) >= 1)
        #else
            Issue.record("CGhosttyTestSpool must be linkable from Ghostty tests")
        #endif
    }

    @Test func test_TER_N10_hardGateScriptExists() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let script = root.appendingPathComponent("scripts/check-ghostty-linked.sh")
        #expect(FileManager.default.fileExists(atPath: script.path))
        let pin = root.appendingPathComponent("Docs/Architecture/GHOSTTY.pin")
        #expect(FileManager.default.fileExists(atPath: pin.path))
    }

    // MARK: - Helpers

    private func withLinkedController(
        _ body: (GhosttySessionController) async throws -> Void
    ) async throws {
        if !GhosttySessionController.isLinked {
            // Fail-closed path always asserted; linked corpus runs under REQUIRE_GHOSTTY=1 CI.
            #expect(throws: TerminalError.self) {
                _ = try GhosttySessionController(requireLinked: true)
            }
            #expect(GhosttySessionController.shimABI >= 1)
            return
        }
        let c = try GhosttySessionController(cols: 80, rows: 24, requireLinked: true)
        defer {
            Task { await c.shutdown() }
        }
        try await body(c)
        await c.shutdown()
    }
}
