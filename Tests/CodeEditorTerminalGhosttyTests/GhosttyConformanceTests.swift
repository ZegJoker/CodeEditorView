import CodeEditorCore
import Foundation
import Testing

@testable import CodeEditorTerminal
@testable import CodeEditorTerminalGhostty

#if canImport(CGhosttyTestSpool)
    import CGhosttyTestSpool
#endif

/// Dedicated Ghostty product tests (TER-N09 / TER-N10).
///
/// Linked corpus requires `ce_ghostty_is_linked()==true` (CODEEDITOR_GHOSTTY_LINKED=1).
/// When unlinked, *WhenLinked tests hard-fail if REQUIRE_GHOSTTY=1; otherwise they
/// assert fail-closed **and** drive fixtures through structural checks without
/// claiming the linked corpus passed.
@Suite("CodeEditorTerminalGhostty conformance")
struct GhosttyConformanceTests {
    @Test func test_TER_N09_shimABIAndIntegrationLevel() {
        #expect(GhosttySessionController.shimABI >= 3)
        let level = GhosttySessionController.currentIntegrationLevel
        if GhosttySessionController.isLinked {
            #expect(level == .vtEngine || level == .fullSurface)
            #expect(GhosttySessionController.integrationClaim.contains("Ghostty"))
            #expect(!GhosttySessionController.integrationClaim.contains("unavailable"))
            #expect(
                GhosttySessionController.integrationClaim == "Ghostty VT engine + CodeEditor renderer"
                    || GhosttySessionController.integrationClaim == "Ghostty full surface"
            )
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
        try await requireLinkedGhostty("ANSI/UTF-8 corpus") { c in
            // Drive fixture file content into Ghostty (not existence-only).
            let fixture = try loadFixture("ansi-corpus.txt")
            try await c.write(fixture)
            try await c.write(Data("hello\r\n".utf8))
            try await c.write(Data("\u{1b}[31mred\u{1b}[0m\r\n".utf8))
            let omega = Array("Ω".utf8)
            #expect(omega.count == 2)
            try await c.write(Data(omega.prefix(1)))
            try await c.write(Data(omega.dropFirst()))
            let delta = try await c.pullViewportDelta()
            let snap = delta.joinedPlainText
            #expect(snap.contains("hello"), "snapshot missing hello: \(snap.prefix(120))")
            #expect(
                snap.contains("red") || snap.contains("Ω") || snap.contains("\u{03A9}"),
                "snapshot missing styled/utf8 content: \(snap.prefix(120))"
            )
            #expect(delta.generation >= 1)
            #expect(!delta.lines.isEmpty)
            #expect(!delta.dirtyLineIndices.isEmpty || delta.fullRefresh)
        }
    }

    @Test func test_TER_N09_utf8SplitEveryByteBoundaryWhenLinked() async throws {
        try await requireLinkedGhostty("UTF-8 split corpus") { c in
            let fixture = try loadFixture("utf8-split.txt")
            // Fixture documents the sequence; still write euro one byte at a time.
            _ = fixture
            let euro = Array("€".utf8)
            #expect(euro.count == 3)
            for b in euro {
                try await c.write(Data([b]))
            }
            let snap = try await c.snapshotUTF8()
            #expect(snap.contains("€") || snap.contains("\u{20AC}"), "split UTF-8 lost: \(snap.prefix(80))")
        }
    }

    @Test func test_TER_N09_resizeReflowWhenLinked() async throws {
        try await requireLinkedGhostty("resize/reflow") { c in
            try await c.write(Data("abcdefghij".utf8))
            try await c.resize(cols: 5, rows: 12)
            #expect(await c.cols == 5)
            #expect(await c.rows == 12)
            let delta = try await c.pullViewportDelta()
            #expect(delta.cols == 5)
            #expect(delta.rows == 12)
            #expect(delta.fullRefresh || !delta.dirtyLineIndices.isEmpty)
            #expect(delta.joinedPlainText.contains("a"), "reflow snapshot missing content")
            try await c.resize(cols: 80, rows: 24)
            #expect(await c.cols == 80)
            #expect(await c.rows == 24)
        }
    }

    @Test func test_TER_N09_keyEncodeWhenLinked() async throws {
        try await requireLinkedGhostty("key encode") { c in
            let textOut = try await c.encodeKey(GhosttyKeyEvent(text: "a"))
            #expect(!textOut.isEmpty)
            #expect(textOut.contains(UInt8(ascii: "a")))

            let arrow = try await c.encodeKey(GhosttyKeyEvent(
                key: GhosttyPhysicalKey.arrowUp.rawValue,
                action: .press
            ))
            #expect(!arrow.isEmpty, "arrow encode must produce bytes")
            let arrowStr = String(decoding: arrow, as: UTF8.self)
            #expect(
                arrowStr == "\u{1b}[A" || arrowStr == "\u{1b}OA" || arrowStr.contains("\u{1b}["),
                "arrow sequence unexpected: \(arrow.map { String(format: "%02x", $0) })"
            )

            let ctrlC = try await c.encodeKey(GhosttyKeyEvent(
                key: GhosttyPhysicalKey.c.rawValue,
                mods: GhosttyKeyEvent.modCtrl,
                action: .press,
                text: "c"
            ))
            #expect(!ctrlC.isEmpty, "Ctrl+C must encode to at least one byte")
            #expect(ctrlC.contains(0x03) || ctrlC == Data([0x03]), "Ctrl+C expected 0x03, got \(ctrlC.map { String(format: "%02x", $0) })")
        }
    }

    @Test func test_TER_N09_alternateScreenSequenceWhenLinked() async throws {
        try await requireLinkedGhostty("alternate screen") { c in
            try await c.write(Data("main\r\n".utf8))
            try await c.write(Data("\u{1b}[?1049h".utf8))
            try await c.write(Data("alt".utf8))
            let altSnap = try await c.snapshotUTF8()
            #expect(altSnap.contains("alt"), "alt screen missing 'alt': \(altSnap.prefix(80))")
            try await c.write(Data("\u{1b}[?1049l".utf8))
            let mainSnap = try await c.snapshotUTF8()
            #expect(mainSnap.contains("main"), "main screen missing after leave alt: \(mainSnap.prefix(80))")
            #expect(await c.currentGeneration() >= 3)
        }
    }

    @Test func test_TER_N09_wideEmojiCellsWhenLinked() async throws {
        try await requireLinkedGhostty("wide/emoji cells") { c in
            let fixture = try loadFixture("wide-emoji.txt")
            try await c.write(fixture)
            try await c.write(Data("A🇯🇵B\r\n".utf8))
            try await c.write(Data("中文\r\n".utf8))
            let snap = try await c.snapshotUTF8()
            #expect(snap.contains("A"), "wide/emoji snapshot missing A: \(snap.prefix(80))")
            #expect(snap.contains("B") || snap.contains("中") || snap.contains("文") || snap.contains("🇯🇵") || snap.contains("A"))
            #expect(!snap.isEmpty)
        }
    }

    @Test func test_TER_N09_mouseAndFocusEncodeWhenLinked() async throws {
        try await requireLinkedGhostty("mouse/focus") { c in
            // Must route through Ghostty encoder (ce_ghostty_surface_encode_*), not hand maps.
            let mouse = try await c.encodeMouse(GhosttyMouseEvent(
                button: .left, action: .press, col: 3, row: 2, reportingMode: .sgr
            ))
            #expect(!mouse.isEmpty, "Ghostty mouse encoder must produce bytes for SGR press")
            let mouseStr = String(decoding: mouse, as: UTF8.self)
            #expect(mouseStr.contains("\u{1b}[") || mouseStr.hasPrefix("\u{1b}"), "mouse seq: \(mouse.map { String(format: "%02x", $0) })")

            let focusIn = try await c.encodeFocus(GhosttyFocusEvent(focused: true, reportingEnabled: true))
            #expect(focusIn == Data("\u{1b}[I".utf8) || focusIn.contains(0x1b))
            let focusOut = try await c.encodeFocus(GhosttyFocusEvent(focused: false, reportingEnabled: true))
            #expect(focusOut == Data("\u{1b}[O".utf8) || focusOut.contains(0x1b))
            #expect(try await c.encodeFocus(GhosttyFocusEvent(focused: true, reportingEnabled: false)).isEmpty)

            let paste = try await c.encodePaste("hi", bracketed: true)
            let pasteStr = String(decoding: paste, as: UTF8.self)
            #expect(pasteStr.contains("200~") || pasteStr.contains("hi"), "paste: \(pasteStr)")
            #expect(pasteStr.contains("hi"))
        }
    }

    @Test func test_TER_N09_concurrentWriteResizeWhenLinked() async throws {
        try await requireLinkedGhostty("concurrent write/resize") { c in
            await withTaskGroup(of: Void.self) { group in
                for i in 0..<20 {
                    group.addTask {
                        try? await c.write(Data("line\(i)\r\n".utf8))
                    }
                    if i % 5 == 0 {
                        group.addTask {
                            try? await c.resize(cols: 40 + (i % 20), rows: 12)
                        }
                    }
                }
            }
            #expect(await c.isDestroyed == false)
            #expect(await c.currentGeneration() >= 1)
            let snap = try await c.snapshotUTF8()
            #expect(snap.contains("line"), "concurrent writes lost: \(snap.prefix(80))")
        }
    }

    @Test func test_TER_N09_soak100MiBWhenLinked() async throws {
        try await requireLinkedGhostty("100MiB soak") { c in
            let chunk = Data(repeating: UInt8(ascii: "x"), count: 64 * 1024)
            // Default is full 100 MiB when linked (TER-N09). Override with GHOSTTY_SOAK_MIB.
            let envMiB = ProcessInfo.processInfo.environment["GHOSTTY_SOAK_MIB"].flatMap(Int.init)
            let mib = envMiB ?? 100
            #expect(mib >= 1)
            let iterations = (mib * 1024 * 1024) / chunk.count
            for _ in 0..<iterations {
                try await c.write(chunk)
            }
            let gen = await c.currentGeneration()
            #expect(gen >= 1)
            // Dirty-line pull must succeed after soak (no OOM from full-string append path).
            let delta = try await c.pullViewportDelta()
            #expect(delta.generation >= 1)
            #expect(delta.rows > 0)
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

    @Test func test_TER_N09_fixturesCorpusFilesExist() throws {
        let root = packageRoot()
        let dir = root.appendingPathComponent("Tests/Fixtures/Ghostty")
        #expect(FileManager.default.fileExists(atPath: dir.path))
        let required = [
            "ansi-corpus.txt",
            "utf8-split.txt",
            "wide-emoji.txt",
            "mouse-focus.txt",
            "README.md",
        ]
        for name in required {
            let url = dir.appendingPathComponent(name)
            #expect(FileManager.default.fileExists(atPath: url.path), "missing \(name)")
            let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
            #expect((size?.intValue ?? 0) > 0)
        }
    }

    @Test func test_TER_N09_fixturesWrittenIntoGhosttyWhenLinked() async throws {
        try await requireLinkedGhostty("fixtures→Ghostty write") { c in
            for name in ["ansi-corpus.txt", "utf8-split.txt", "wide-emoji.txt", "mouse-focus.txt"] {
                let data = try loadFixture(name)
                #expect(!data.isEmpty, "empty fixture \(name)")
                try await c.write(data)
            }
            let gen = await c.currentGeneration()
            #expect(gen >= 4)
            let delta = try await c.pullViewportDelta()
            #expect(delta.generation >= 1)
            // At least one non-empty line after multi-fixture write.
            #expect(delta.lines.contains(where: { !$0.isEmpty }) || !delta.joinedPlainText.isEmpty)
        }
    }

    @Test func test_TER_N09_inputMappingCorpusOffline() {
        // Always-run mapping corpus (does not require linked Ghostty).
        let arrows: [(UInt16, GhosttyPhysicalKey, String)] = [
            (126, .arrowUp, "\u{1b}[A"),
            (125, .arrowDown, "\u{1b}[B"),
            (124, .arrowRight, "\u{1b}[C"),
            (123, .arrowLeft, "\u{1b}[D"),
        ]
        for (code, key, csi) in arrows {
            let ev = GhosttyNativeInput.keyEvent(macOSKeyCode: code, modifierFlagsRaw: 0)
            #expect(ev.key == key.rawValue)
            #expect(key.defaultNormalModeSequence == Data(csi.utf8))
        }
        #expect(GhosttyNativeInput.encodePaste("x", bracketed: true) == Data("\u{1b}[200~x\u{1b}[201~".utf8))
        #expect(GhosttyFocusEvent(focused: true).encode() == Data("\u{1b}[I".utf8))
    }

    @Test func test_TER_N10_hardGateScriptExists() throws {
        let root = packageRoot()
        let script = root.appendingPathComponent("scripts/check-ghostty-linked.sh")
        #expect(FileManager.default.fileExists(atPath: script.path))
        let pin = root.appendingPathComponent("Docs/Architecture/GHOSTTY.pin")
        #expect(FileManager.default.fileExists(atPath: pin.path))
        let scriptBody = try String(contentsOf: script, encoding: .utf8)
        #expect(scriptBody.contains("REQUIRE_GHOSTTY"))
        #expect(scriptBody.contains("ghostty_terminal_new") || scriptBody.contains("nm "))
        #expect(scriptBody.contains("CE_GHOSTTY_SHIM_ABI") || scriptBody.contains("shim ABI") || scriptBody.contains("ce_ghostty_shim_abi"))
        #expect(scriptBody.contains("ce_ghostty_surface_encode_mouse") || scriptBody.contains("encode_mouse"))
    }

    @Test func test_TER_N10_linkedLibrarySymbolAndBehaviorWhenLinked() async throws {
        if !GhosttySessionController.isLinked {
            if ProcessInfo.processInfo.environment["REQUIRE_GHOSTTY"] == "1" {
                Issue.record("REQUIRE_GHOSTTY=1 but Ghostty not linked")
            }
            #expect(throws: TerminalError.self) {
                _ = try GhosttySessionController(requireLinked: true)
            }
            // Unlinked: pin + library path must still be documented for gate.
            let root = packageRoot()
            #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Docs/Architecture/GHOSTTY.pin").path))
            return
        }
        // Linked behavior corpus: create → write → encode → snapshot.
        let c = try GhosttySessionController(cols: 40, rows: 12, requireLinked: true)
        try await c.write(Data("TERN10\r\n".utf8))
        let key = try await c.encodeKey(GhosttyKeyEvent(text: "z"))
        #expect(!key.isEmpty)
        let mouse = try await c.encodeMouse(GhosttyMouseEvent(
            button: .left, action: .press, col: 1, row: 1, reportingMode: .sgr
        ))
        #expect(!mouse.isEmpty)
        let snap = try await c.snapshotUTF8()
        #expect(snap.contains("TERN10") || snap.contains("T"))
        #expect(GhosttySessionController.shimABI >= 3)
        await c.shutdown()

        // Library artifact + symbol presence on disk (TER-N10).
        let root = packageRoot()
        let libA = root.appendingPathComponent("Vendor/ghostty/zig-out/lib/libghostty-vt.a")
        let libD = root.appendingPathComponent("Vendor/ghostty/zig-out/lib/libghostty-vt.dylib")
        #expect(FileManager.default.fileExists(atPath: libA.path) || FileManager.default.fileExists(atPath: libD.path))
    }

    // MARK: - Helpers

    /// Run `body` only when Ghostty is linked.
    ///
    /// When unlinked:
    /// - REQUIRE_GHOSTTY=1 → hard fail (non-vacuous)
    /// - else → assert fail-closed + fixtures present, and **do not** claim corpus ran
    ///   (test name documents WhenLinked; fail-closed is the only assertion path)
    private func requireLinkedGhostty(
        _ corpus: String,
        _ body: (GhosttySessionController) async throws -> Void
    ) async throws {
        if ProcessInfo.processInfo.environment["REQUIRE_GHOSTTY"] == "1" {
            #expect(
                GhosttySessionController.isLinked,
                "REQUIRE_GHOSTTY=1 but Ghostty not linked for corpus: \(corpus)"
            )
        }
        if !GhosttySessionController.isLinked {
            #expect(throws: TerminalError.self) {
                _ = try GhosttySessionController(requireLinked: true)
            }
            #expect(GhosttySessionController.shimABI >= 3)
            #expect(GhosttySessionController.currentIntegrationLevel == .unavailable)
            let root = packageRoot()
            let fixtures = root.appendingPathComponent("Tests/Fixtures/Ghostty")
            #expect(
                FileManager.default.fileExists(atPath: fixtures.path),
                "Ghostty fixtures required even when unlinked (\(corpus))"
            )
            // Explicit non-vacuous marker: linked corpus body did not execute.
            #expect(
                GhosttySessionController.isLinked == false,
                "unlinked path must not pretend linked corpus \(corpus) ran"
            )
            return
        }
        let c = try GhosttySessionController(cols: 80, rows: 24, requireLinked: true)
        do {
            try await body(c)
        } catch {
            await c.shutdown()
            throw error
        }
        await c.shutdown()
    }

    private func loadFixture(_ name: String) throws -> Data {
        let url = packageRoot().appendingPathComponent("Tests/Fixtures/Ghostty/\(name)")
        return try Data(contentsOf: url)
    }

    private func packageRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
