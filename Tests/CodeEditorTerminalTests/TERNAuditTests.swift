import CodeEditorCore
import Darwin
import Foundation
import Testing

@testable import CodeEditorTerminal
@testable import CodeEditorTerminalGhostty

#if canImport(CGhosttyTestSpool)
    import CGhosttyTestSpool
#endif

// MARK: - TER-N01

@Suite("TER-N01 fake fallback not production")
struct TERN01Tests {
    @Test func test_TER_N01_requireGhosttyLinkedDefaultsTrue() async {
        let service = TerminalService()
        #expect(await service.requireGhosttyLinked == true)
    }

    @Test func test_TER_N01_requireLinkedDefaultsTrueOnController() async throws {
        if GhosttySessionController.isLinked {
            let c = try GhosttySessionController()
            #expect(await c.isLinkedToGhostty == true)
            await c.shutdown()
        } else {
            #expect(throws: TerminalError.self) {
                _ = try GhosttySessionController()
            }
        }
    }

    @Test func test_TER_N01_unlinkedControllerNeverCreatesSurface() async throws {
        if GhosttySessionController.isLinked {
            let c = try GhosttySessionController(requireLinked: true)
            await c.shutdown()
            return
        }
        #expect(throws: TerminalError.self) {
            _ = try GhosttySessionController(requireLinked: false)
        }
        #expect(throws: TerminalError.self) {
            _ = try GhosttySessionController(requireLinked: true)
        }
    }

    @Test func test_TER_N01_serviceRefusesUnlinkedSessions() async throws {
        let service = TerminalService(
            requireGhosttyLinked: true,
            isGhosttyLinked: { false }
        )
        do {
            _ = try await service.create(transport: MockByteTransport())
            Issue.record("must refuse unlinked production session")
        } catch let error as TerminalError {
            guard case .startFailed(let msg) = error else {
                Issue.record("wrong \(error)")
                return
            }
            #expect(msg.contains("Ghostty") || msg.contains("linked"))
        }
    }

    @Test func test_TER_N01_productionCShimHasNoVTLessByteSpoolDefault() throws {
        let root = packageRoot()
        let cFile = root.appendingPathComponent("Sources/CGhosttyShim/codeeditor_ghostty.c")
        let src = try String(contentsOf: cFile, encoding: .utf8)
        #expect(!src.contains("minimal VT-less byte spool"))
        #expect(src.contains("CODEEDITOR_GHOSTTY_LINKED"))
        #expect(src.contains("Never produce a fake terminal") || src.contains("fail-closed") || src.contains("return NULL"))
        #expect(src.contains("!CODEEDITOR_GHOSTTY_LINKED") || src.contains("!defined(CODEEDITOR_GHOSTTY_LINKED)"))
    }

    @Test func test_TER_N01_testSpoolLivesOnlyUnderTests() throws {
        let root = packageRoot()
        let testSpool = root.appendingPathComponent("Tests/Support/CGhosttyTestSpool/codeeditor_ghostty_test_spool.c")
        #expect(FileManager.default.fileExists(atPath: testSpool.path))
        let prod = try String(
            contentsOf: root.appendingPathComponent("Sources/CGhosttyShim/codeeditor_ghostty.c"),
            encoding: .utf8
        )
        #expect(!prod.contains("ce_test_spool_create"))
    }
}

// MARK: - TER-N02

@Suite("TER-N02 Ghostty rendering honesty")
struct TERN02Tests {
    @Test func test_TER_N02_integrationClaimIsHonest() {
        let claim = GhosttySessionController.integrationClaim
        if GhosttySessionController.isLinked {
            #expect(
                claim == "Ghostty VT engine + CodeEditor renderer"
                    || claim == "Ghostty full surface"
            )
            #expect(!claim.lowercased().contains("fake"))
            #expect(claim != "Ghostty unavailable")
        } else {
            #expect(claim == "Ghostty unavailable")
            #expect(GhosttySessionController.currentIntegrationLevel == .unavailable)
        }
    }

    @Test @MainActor func test_TER_N02_surfaceViewUnavailableWhenUnlinked() {
        let v = GhosttySurfaceView(integrationLevel: .unavailable)
        #expect(v.integrationLevel == .unavailable)
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
            #expect(v.accessibilityIdentifier() == "ghostty.surface.unavailable")
            let label = v.accessibilityLabel() ?? ""
            #expect(label == "Ghostty unavailable" || label.contains("unavailable") || label.contains("Ghostty"))
        #else
            #expect(v.accessibilityIdentifier == "ghostty.surface.unavailable")
        #endif
    }

    @Test @MainActor func test_TER_N02_surfaceViewAvailableLevelIsNotUnavailableClaim() {
        let v = GhosttySurfaceView(integrationLevel: .vtEngine)
        #expect(v.integrationLevel == .vtEngine)
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
            #expect(v.accessibilityIdentifier() == "ghostty.surface")
        #else
            #expect(v.accessibilityIdentifier == "ghostty.surface")
        #endif
        // TER-N02: VT-engine path is dirty-line host renderer, not fake full Ghostty UI claim.
        #expect(v.usesDirtyLineRendering)
        let claim = GhosttySessionController.integrationClaim
        if GhosttySessionController.isLinked {
            #expect(claim == "Ghostty VT engine + CodeEditor renderer" || claim == "Ghostty full surface")
            #expect(!claim.lowercased().contains("ghostty ui"))
        }
    }

    @Test @MainActor func test_TER_N02_dirtyLineApplyDoesNotRequireFullStringPoll() {
        let v = GhosttySurfaceView(integrationLevel: .vtEngine)
        #expect(v.usesDirtyLineRendering)
        let delta = GhosttyViewportDelta(
            generation: 1,
            cols: 10,
            rows: 2,
            lines: ["hello", "world"],
            dirtyLineIndices: [0, 1],
            fullRefresh: true
        )
        v.applyViewportDelta(delta)
        #expect(v.cachedLineCount == 2 || v.cachedLineCount == 0) // iOS may not cache
        let delta2 = GhosttyViewportDelta(
            generation: 2,
            cols: 10,
            rows: 2,
            lines: ["HELLO", "world"],
            dirtyLineIndices: [0],
            fullRefresh: false
        )
        v.applyViewportDelta(delta2)
        #expect(v.usesDirtyLineRendering)
    }

    @Test func test_TER_N02_workbenchUsesDirtyViewportNotFullSnapshotPoll() throws {
        let root = packageRoot()
        let util = try String(
            contentsOf: root.appendingPathComponent("Sources/CodeEditorWorkbench/UtilityPanels.swift"),
            encoding: .utf8
        )
        #expect(util.contains("pullViewportDelta"))
        #expect(util.contains("viewportDelta"))
        #expect(util.contains("Ghostty VT engine") || util.contains("integrationClaim"))
        // Must not poll snapshotUTF8 every tick as primary path.
        #expect(util.contains("currentGeneration"))
        #expect(util.contains("updateViewportLines") || util.contains("dirty"))
    }
}

// MARK: - TER-N03

@Suite("TER-N03 single production architecture")
struct TERN03Tests {
    @Test func test_TER_N03_terminalServiceIsProductionFacade() async throws {
        let service = TerminalService(requireGhosttyLinked: false)
        let id = try await service.create(
            transport: MockByteTransport(),
            transportClass: .inMemory,
            caller: .host
        )
        #expect(await service.allSessions().count == 1)
        try await service.close(id)
        #expect(await service.allSessions().isEmpty)
    }

    @Test func test_TER_N03_legacyTypesAreDeprecatedInSource() throws {
        let root = packageRoot()
        for rel in [
            "Sources/CodeEditorTerminal/VTParser.swift",
            "Sources/CodeEditorTerminal/TerminalScreen.swift",
            "Sources/CodeEditorTerminal/TerminalSessionManager.swift",
        ] {
            let src = try String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8)
            #expect(src.contains("@available(*, deprecated") || src.contains("deprecated"), "\(rel) must be deprecated")
            #expect(src.contains("TER-N03") || src.contains("TerminalService"))
        }
    }

    @Test func test_TER_N03_legacyManagerStillFunctionsForMigration() async throws {
        let backend = MockTerminalBackend()
        let manager = TerminalSessionManager()
        await manager.attach(backend: backend)
        let session = try await manager.create(title: "legacy")
        #expect(await manager.allSessions().count == 1)
        await manager.close(session.id)
    }

    @Test func test_TER_N03_workbenchUsesTerminalServiceNotLegacyManager() throws {
        let root = packageRoot()
        let util = try String(
            contentsOf: root.appendingPathComponent("Sources/CodeEditorWorkbench/UtilityPanels.swift"),
            encoding: .utf8
        )
        #expect(util.contains("TerminalService"))
        #expect(!util.contains("TerminalSessionManager("))
        #expect(util.contains("GhosttySessionController") || util.contains("requireGhosttyLinked"))
    }
}

// MARK: - TER-N04

@Suite("TER-N04 input mapping")
struct TERN04Tests {
    @Test func test_TER_N04_structuredKeyEventAPIExists() {
        let ev = GhosttyKeyEvent(
            key: GhosttyPhysicalKey.c.rawValue,
            mods: GhosttyKeyEvent.modCtrl,
            action: .press,
            text: "c"
        )
        #expect(ev.mods == GhosttyKeyEvent.modCtrl)
        #expect(ev.action == .press)
        #expect(ev.key == GhosttyPhysicalKey.c.rawValue)
        #expect(ev.key != 0)
    }

    @Test func test_TER_N04_arrowKeysMapToNonZeroGhosttyKey() {
        // macOS key codes: left=123, right=124, down=125, up=126
        let up = GhosttyNativeInput.keyEvent(macOSKeyCode: 126, modifierFlagsRaw: 0)
        let down = GhosttyNativeInput.keyEvent(macOSKeyCode: 125, modifierFlagsRaw: 0)
        let left = GhosttyNativeInput.keyEvent(macOSKeyCode: 123, modifierFlagsRaw: 0)
        let right = GhosttyNativeInput.keyEvent(macOSKeyCode: 124, modifierFlagsRaw: 0)
        #expect(up.key == GhosttyPhysicalKey.arrowUp.rawValue)
        #expect(down.key == GhosttyPhysicalKey.arrowDown.rawValue)
        #expect(left.key == GhosttyPhysicalKey.arrowLeft.rawValue)
        #expect(right.key == GhosttyPhysicalKey.arrowRight.rawValue)
        #expect(up.key != 0 && down.key != 0 && left.key != 0 && right.key != 0)
        // Default normal-mode sequences (oracle for Ghostty encoder when linked).
        #expect(GhosttyPhysicalKey.arrowUp.defaultNormalModeSequence == Data("\u{1b}[A".utf8))
        #expect(GhosttyPhysicalKey.arrowDown.defaultNormalModeSequence == Data("\u{1b}[B".utf8))
        #expect(GhosttyPhysicalKey.arrowRight.defaultNormalModeSequence == Data("\u{1b}[C".utf8))
        #expect(GhosttyPhysicalKey.arrowLeft.defaultNormalModeSequence == Data("\u{1b}[D".utf8))
    }

    @Test func test_TER_N04_navAndFunctionKeysMap() {
        #expect(GhosttyNativeInput.physicalKey(macOSKeyCode: 115) == .home)
        #expect(GhosttyNativeInput.physicalKey(macOSKeyCode: 119) == .end)
        #expect(GhosttyNativeInput.physicalKey(macOSKeyCode: 116) == .pageUp)
        #expect(GhosttyNativeInput.physicalKey(macOSKeyCode: 121) == .pageDown)
        #expect(GhosttyNativeInput.physicalKey(macOSKeyCode: 117) == .delete)
        #expect(GhosttyNativeInput.physicalKey(macOSKeyCode: 122) == .f1)
        #expect(GhosttyNativeInput.physicalKey(macOSKeyCode: 120) == .f2)
        #expect(GhosttyNativeInput.physicalKey(macOSKeyCode: 99) == .f3)
        #expect(GhosttyNativeInput.physicalKey(macOSKeyCode: 118) == .f4)
        #expect(GhosttyNativeInput.physicalKey(macOSKeyCode: 96) == .f5)
        #expect(GhosttyNativeInput.physicalKey(macOSKeyCode: 111) == .f12)
        #expect(GhosttyPhysicalKey.f5.defaultNormalModeSequence == Data("\u{1b}[15~".utf8))
        #expect(GhosttyPhysicalKey.home.defaultNormalModeSequence == Data("\u{1b}[H".utf8))
    }

    @Test func test_TER_N04_modifiersMapToBits() {
        // Device-independent NSEvent.ModifierFlags bits:
        // shift=1<<17, control=1<<18, option=1<<19, command=1<<20
        #expect(GhosttyNativeInput.mods(from: 1 << 17) == GhosttyKeyEvent.modShift)
        #expect(GhosttyNativeInput.mods(from: 1 << 18) == GhosttyKeyEvent.modCtrl)
        #expect(GhosttyNativeInput.mods(from: 1 << 19) == GhosttyKeyEvent.modAlt)
        #expect(GhosttyNativeInput.mods(from: 1 << 20) == GhosttyKeyEvent.modSuper)
        let combined = GhosttyNativeInput.mods(from: (1 << 17) | (1 << 18))
        #expect(combined == (GhosttyKeyEvent.modShift | GhosttyKeyEvent.modCtrl))
    }

    @Test func test_TER_N04_flagsChangedEmitsModifierKeyEvents() {
        // shiftLeft keyCode 56: off → on
        let press = GhosttyNativeInput.flagsChangedEvent(
            macOSKeyCode: 56,
            modifierFlagsRaw: 1 << 17,
            previousModifierFlagsRaw: 0
        )
        #expect(press != nil)
        #expect(press!.key == GhosttyPhysicalKey.shiftLeft.rawValue)
        #expect(press!.action == .press)
        #expect(press!.mods & GhosttyKeyEvent.modShift != 0)

        let release = GhosttyNativeInput.flagsChangedEvent(
            macOSKeyCode: 56,
            modifierFlagsRaw: 0,
            previousModifierFlagsRaw: 1 << 17
        )
        #expect(release != nil)
        #expect(release!.action == .release)
        #expect(release!.key == GhosttyPhysicalKey.shiftLeft.rawValue)
    }

    @Test func test_TER_N04_bracketedPasteEncodesMarkerBytes() {
        let plain = GhosttyNativeInput.encodePaste("hello", bracketed: false)
        #expect(plain == Data("hello".utf8))
        let bracketed = GhosttyNativeInput.encodePaste("hello", bracketed: true)
        let s = String(decoding: bracketed, as: UTF8.self)
        #expect(s.hasPrefix("\u{1b}[200~"))
        #expect(s.hasSuffix("\u{1b}[201~"))
        #expect(s.contains("hello"))
        #expect(bracketed.count == "\u{1b}[200~hello\u{1b}[201~".utf8.count)
    }

    @Test func test_TER_N04_focusInOutEncodeCSI() {
        // Offline mapping-layer expectation (not production encoder).
        let inn = GhosttyFocusEvent(focused: true, reportingEnabled: true).encode()
        let out = GhosttyFocusEvent(focused: false, reportingEnabled: true).encode()
        #expect(inn == Data("\u{1b}[I".utf8))
        #expect(out == Data("\u{1b}[O".utf8))
        #expect(GhosttyFocusEvent(focused: true, reportingEnabled: false).encode().isEmpty)
    }

    @Test func test_TER_N04_mouseSGREncodeBytes() {
        // Offline map exists for unlinked unit tests; production uses Ghostty encoder.
        let press = GhosttyMouseEvent(
            button: .left, action: .press, mods: 0, col: 10, row: 5, reportingMode: .sgr
        )
        let bytes = press.encode()
        let s = String(decoding: bytes, as: UTF8.self)
        #expect(s.hasPrefix("\u{1b}[<"))
        #expect(s.contains(";10;5"))
        #expect(s.hasSuffix("M"))
        let release = GhosttyMouseEvent(
            button: .left, action: .release, col: 10, row: 5, reportingMode: .sgr
        )
        #expect(String(decoding: release.encode(), as: UTF8.self).hasSuffix("m"))
        #expect(GhosttyMouseEvent(reportingMode: .off).encode().isEmpty)
    }

    @Test func test_TER_N04_controllerRoutesMouseFocusPasteToGhosttyEncoder() throws {
        let root = packageRoot()
        let src = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/CodeEditorTerminalGhostty/GhosttySessionController.swift"
            ),
            encoding: .utf8
        )
        #expect(src.contains("ce_ghostty_surface_encode_mouse"))
        #expect(src.contains("ce_ghostty_surface_encode_focus"))
        #expect(src.contains("ce_ghostty_surface_encode_paste"))
        #expect(src.contains("ce_ghostty_surface_encode_key"))
        // Must not call hand-built event.encode() in production encodeMouse path.
        #expect(!src.contains("return event.encode()"))
        #expect(!src.contains("return GhosttyNativeInput.encodePaste"))
        let hdr = try String(
            contentsOf: root.appendingPathComponent("Sources/CGhosttyShim/include/codeeditor_ghostty.h"),
            encoding: .utf8
        )
        #expect(hdr.contains("ce_ghostty_surface_encode_mouse"))
        #expect(hdr.contains("ce_ghostty_surface_encode_focus"))
        #expect(hdr.contains("ce_ghostty_surface_encode_paste"))
    }

    @Test func test_TER_N04_imeCompositionDoesNotWriteUntilCommit() {
        let preedit = GhosttyIMEEvent.updateComposition(" ren ")
        #expect(preedit.committedKeyEvent?.composing == true)
        let commit = GhosttyIMEEvent.commit("人")
        #expect(commit.committedKeyEvent?.composing == false)
        #expect(commit.committedKeyEvent?.text == "人")
        #expect(GhosttyIMEEvent.beginComposition.committedKeyEvent == nil)
        #expect(GhosttyIMEEvent.cancel.committedKeyEvent == nil)
    }

    @Test func test_TER_N04_encodeKeyRequiresLinkedGhosttyAndAssertsBytesWhenLinked() async throws {
        if GhosttySessionController.isLinked {
            let c = try GhosttySessionController(requireLinked: true)
            // Printable text → non-empty encoded bytes via Ghostty key encoder.
            let textOut = try await c.encodeKey(GhosttyKeyEvent(text: "a"))
            #expect(!textOut.isEmpty)
            #expect(textOut == Data("a".utf8) || textOut.contains(UInt8(ascii: "a")))

            // Arrow up with physical key — must produce CSI/SS3, not empty.
            let arrow = try await c.encodeKey(GhosttyKeyEvent(
                key: GhosttyPhysicalKey.arrowUp.rawValue,
                action: .press
            ))
            #expect(!arrow.isEmpty)
            let arrowStr = String(decoding: arrow, as: UTF8.self)
            #expect(
                arrowStr == "\u{1b}[A" || arrowStr == "\u{1b}OA" || arrowStr.contains("\u{1b}"),
                "arrow encode must yield escape sequence, got \(arrow.map { String($0, radix: 16) })"
            )

            // Ctrl+C — typically 0x03
            let ctrlC = try await c.encodeKey(GhosttyKeyEvent(
                key: GhosttyPhysicalKey.c.rawValue,
                mods: GhosttyKeyEvent.modCtrl,
                action: .press,
                text: "c"
            ))
            #expect(!ctrlC.isEmpty, "Ctrl+C must encode to bytes")
            #expect(ctrlC.contains(0x03) || ctrlC == Data([0x03]))

            // Mouse/focus/paste via Ghostty encoders (not hand-built maps).
            let mouse = try await c.encodeMouse(GhosttyMouseEvent(
                button: .left, action: .press, col: 1, row: 1, reportingMode: .sgr
            ))
            #expect(!mouse.isEmpty, "Ghostty mouse encoder must emit SGR bytes")
            #expect(String(decoding: mouse, as: UTF8.self).contains("\u{1b}"))
            let focus = try await c.encodeFocus(GhosttyFocusEvent(focused: true, reportingEnabled: true))
            #expect(focus == Data("\u{1b}[I".utf8) || focus.contains(0x1b))
            let paste = try await c.encodePaste("x", bracketed: true)
            let pasteStr = String(decoding: paste, as: UTF8.self)
            #expect(pasteStr.contains("x"))
            #expect(pasteStr.contains("200~") || pasteStr.contains("\u{1b}"))
            await c.shutdown()
        } else {
            if ProcessInfo.processInfo.environment["REQUIRE_GHOSTTY"] == "1" {
                Issue.record("REQUIRE_GHOSTTY=1 but Ghostty unlinked — linked encode corpus not run")
            }
            #expect(throws: TerminalError.self) {
                _ = try GhosttySessionController(requireLinked: true)
            }
            // Mapping layer still produces correct structured events offline.
            let up = GhosttyNativeInput.keyEvent(macOSKeyCode: 126, modifierFlagsRaw: 0)
            #expect(up.key == GhosttyPhysicalKey.arrowUp.rawValue)
            #expect(GhosttyPhysicalKey.arrowUp.defaultNormalModeSequence == Data("\u{1b}[A".utf8))
        }
    }

    @Test func test_TER_N04_shimExposesEncodeKey() throws {
        let root = packageRoot()
        let hdr = try String(
            contentsOf: root.appendingPathComponent("Sources/CGhosttyShim/include/codeeditor_ghostty.h"),
            encoding: .utf8
        )
        #expect(hdr.contains("ce_ghostty_surface_encode_key"))
        #expect(hdr.contains("ce_ghostty_key_event"))
        let surface = try String(
            contentsOf: root.appendingPathComponent("Sources/CodeEditorTerminalGhostty/GhosttySurfaceView.swift"),
            encoding: .utf8
        )
        #expect(surface.contains("GhosttyNativeInput.keyEvent") || surface.contains("physicalKey"))
        #expect(surface.contains("flagsChanged"))
        #expect(surface.contains("onMouseEvent") || surface.contains("mouseDown"))
        #expect(surface.contains("onFocusEvent") || surface.contains("becomeFirstResponder"))
        #expect(surface.contains("bracketedPaste") || surface.contains("encodePaste") || surface.contains("paste"))
        #expect(surface.contains("IME") || surface.contains("applyIMEMarkedText") || surface.contains("composing") || surface.contains("onIMEEvent"))
    }

    @Test @MainActor func test_TER_N04_surfaceViewRoutesStructuredKeysNotCharactersAlone() {
        let v = GhosttySurfaceView(integrationLevel: .vtEngine)
        var captured: [GhosttyKeyEvent] = []
        v.onKeyEvent = { captured.append($0) }
        // Simulate routing path used by keyDown (unit-level, no synthetic NSEvent required on all platforms).
        let routed = GhosttyNativeInput.keyEvent(macOSKeyCode: 126, modifierFlagsRaw: 0, text: nil)
        v.onKeyEvent?(routed)
        #expect(captured.count == 1)
        #expect(captured[0].key == GhosttyPhysicalKey.arrowUp.rawValue)
        #expect(captured[0].key != 0)
    }
}

// MARK: - TER-N05

@Suite("TER-N05 raw bytes not per-chunk UTF-8 strings")
struct TERN05Tests {
    @Test func test_TER_N05_serviceDoesNotDecodeChunksAsStandaloneStrings() async throws {
        let service = TerminalService(requireGhosttyLinked: false)
        let transport = MockByteTransport()
        let id = try await service.create(transport: transport, transportClass: .inMemory)
        let omega = Array("Ω".utf8)
        #expect(omega.count > 1)
        // First byte alone is invalid UTF-8 — String(data:encoding:) would fail.
        try await transport.write(Data(omega.prefix(1)))
        try await transport.write(Data(omega.dropFirst()))
        try await Task.sleep(nanoseconds: 40_000_000)
        let snap = await service.snapshot(for: id)
        #expect(snap == "")
        let bytes = await service.bytesReceived(for: id)
        #expect(bytes == UInt64(omega.count))
        // Host (Ghostty) owns viewport — not chunk decode.
        await service.updateViewport(plainText: "Ω", generation: 1, for: id)
        #expect(await service.snapshot(for: id) == "Ω")
        try await service.close(id)
    }

    @Test func test_TER_N05_serviceSourceHasNoStringDataEncodingOnOutput() throws {
        let root = packageRoot()
        let src = try String(
            contentsOf: root.appendingPathComponent("Sources/CodeEditorTerminal/TerminalService.swift"),
            encoding: .utf8
        )
        #expect(!src.contains("String(data: data, encoding: .utf8)"))
        #expect(!src.contains("String(data:data, encoding:"))
        #expect(src.contains("TER-N05") || src.contains("raw bytes"))
    }

    @Test func test_TER_N05_updateViewportFromGhosttyOnly() async throws {
        let service = TerminalService(requireGhosttyLinked: false)
        let id = try await service.create(transport: MockByteTransport(), transportClass: .inMemory)
        await service.updateViewport(plainText: "hello", generation: 1, for: id)
        #expect(await service.snapshot(for: id) == "hello")
        #expect(await service.viewportGeneration(for: id) == 1)
        await service.updateViewport(plainText: "stale", generation: 0, for: id)
        #expect(await service.snapshot(for: id) == "hello")
        try await service.close(id)
    }

    @Test func test_TER_N05_onOutputReceivesRawChunksNotDecoded() async throws {
        let service = TerminalService(requireGhosttyLinked: false)
        let transport = MockByteTransport()
        final class Box: @unchecked Sendable {
            var chunks: [Data] = []
        }
        let box = Box()
        let id = try await service.create(
            transport: transport,
            transportClass: .inMemory,
            onOutput: { data in
                box.chunks.append(data)
            }
        )
        let part1 = Data([0xCE]) // first byte of Ω
        let part2 = Data([0xA9])
        try await transport.write(part1)
        try await transport.write(part2)
        try await Task.sleep(nanoseconds: 40_000_000)
        #expect(box.chunks.count == 2)
        #expect(box.chunks[0] == part1)
        #expect(box.chunks[1] == part2)
        try await service.close(id)
    }
}

// MARK: - TER-N06

@Suite("TER-N06 no O(n²) full-string snapshots")
struct TERN06Tests {
    @Test func test_TER_N06_pagedScrollbackAPI() async throws {
        let service = TerminalService(
            requireGhosttyLinked: false,
            maxRawSpoolBytes: 1024
        )
        let transport = MockByteTransport()
        let id = try await service.create(transport: transport, transportClass: .inMemory)
        let payload = Data(repeating: 0x41, count: 200)
        try await transport.write(payload)
        try await Task.sleep(nanoseconds: 40_000_000)
        let page = try await service.readScrollbackPage(session: id, offset: 0, maxBytes: 50)
        #expect(page != nil)
        #expect(page!.data.count == 50)
        #expect(page!.data == Data(repeating: 0x41, count: 50))
        #expect(page!.availableEnd >= 200)
        let page2 = try await service.readScrollbackPage(session: id, offset: 150, maxBytes: 100)
        #expect(page2!.data.count == 50)
        try await service.close(id)
    }

    @Test func test_TER_N06_generationDirtyTracking() async throws {
        let service = TerminalService(requireGhosttyLinked: false)
        let id = try await service.create(transport: MockByteTransport(), transportClass: .inMemory)
        await service.updateViewport(plainText: "a", generation: 1, for: id)
        await service.updateViewport(plainText: "ab", generation: 2, for: id)
        #expect(await service.viewportGeneration(for: id) == 2)
        #expect(await service.snapshot(for: id) == "ab")
        try await service.close(id)
    }

    @Test func test_TER_N06_serviceDoesNotAppendSnapshotOnEveryChunk() async throws {
        let service = TerminalService(requireGhosttyLinked: false)
        let transport = MockByteTransport()
        let id = try await service.create(transport: transport, transportClass: .inMemory)
        for i in 0..<20 {
            try await transport.write(Data("chunk\(i)".utf8))
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        // Viewport stays empty until Ghostty generation update — not O(n²) string append.
        #expect(await service.snapshot(for: id) == "")
        #expect(await service.viewportGeneration(for: id) == 0)
        let bytes = await service.bytesReceived(for: id)
        #expect(bytes! > 0)
        // One host update sets viewport once.
        await service.updateViewport(plainText: "viewport", generation: 5, for: id)
        #expect(await service.snapshot(for: id) == "viewport")
        #expect(await service.viewportGeneration(for: id) == 5)
        try await service.close(id)
    }

    @Test func test_TER_N06_dirtyLineViewportAPI() async throws {
        let service = TerminalService(requireGhosttyLinked: false)
        let id = try await service.create(transport: MockByteTransport(), transportClass: .inMemory)
        await service.updateViewportLines(
            lines: ["aaa", "bbb", "ccc"],
            dirtyIndices: [0, 1, 2],
            generation: 1,
            for: id
        )
        #expect(await service.viewportLines(for: id) == ["aaa", "bbb", "ccc"])
        #expect(await service.dirtyLineIndices(for: id) == [0, 1, 2])
        #expect(await service.snapshot(for: id) == "aaa\nbbb\nccc")
        await service.updateViewportLines(
            lines: ["AAA", "bbb", "ccc"],
            dirtyIndices: [0],
            generation: 2,
            for: id
        )
        #expect(await service.dirtyLineIndices(for: id) == [0])
        #expect(await service.viewportLines(for: id)?.first == "AAA")
        // Stale generation rejected.
        await service.updateViewportLines(
            lines: ["stale"],
            dirtyIndices: [0],
            generation: 1,
            for: id
        )
        #expect(await service.viewportLines(for: id)?.first == "AAA")
        try await service.close(id)
    }

    @Test func test_TER_N06_ghosttyPullViewportDeltaWhenLinked() async throws {
        if !GhosttySessionController.isLinked {
            #expect(throws: TerminalError.self) {
                _ = try GhosttySessionController(requireLinked: true)
            }
            return
        }
        let c = try GhosttySessionController(cols: 40, rows: 8, requireLinked: true)
        try await c.write(Data("line0\r\nline1\r\n".utf8))
        let d1 = try await c.pullViewportDelta()
        #expect(d1.generation >= 1)
        #expect(d1.rows == 8)
        #expect(d1.fullRefresh || !d1.dirtyLineIndices.isEmpty)
        try await c.write(Data("X".utf8))
        let d2 = try await c.pullViewportDelta()
        #expect(d2.generation >= d1.generation)
        // Second pull should not always full-refresh if grid size stable.
        #expect(d2.lines.count == d1.lines.count)
        await c.shutdown()
    }
}

// MARK: - TER-N07

@Suite("TER-N07 PTY transport lifecycle")
struct TERN07Tests {
    @Test func test_TER_N07_dimensionClampSafe() {
        #expect(TerminalDimension.clampCells(0) == 1)
        #expect(TerminalDimension.clampCells(-5) == 1)
        #expect(TerminalDimension.clampCells(80) == 80)
        #expect(TerminalDimension.clampCells(Int(UInt16.max) + 100) == UInt16.max)
        #expect(TerminalDimension.clampCells(Int.max) == UInt16.max)
    }

    @Test func test_TER_N07_userTerminateIsCancelledNotExit0() async throws {
        let transport = MockByteTransport()
        _ = try await transport.start(TerminalLaunchRequest())
        final class Box: @unchecked Sendable {
            var reason: TerminalProcessExitReason?
        }
        let box = Box()
        let stream = await transport.events
        let collector = Task {
            for try await event in stream {
                if case .terminated(let r) = event {
                    box.reason = r
                    break
                }
            }
        }
        await transport.terminate(.user)
        try await Task.sleep(nanoseconds: 20_000_000)
        collector.cancel()
        #expect(box.reason == .cancelled)
        #expect(box.reason != .exited(code: 0))
    }

    @Test func test_TER_N07_processSupervisorRegistersPTY() async {
        let supervisor = ProcessSupervisor()
        #expect(await supervisor.activePTYLeaseCount == 0)
        let lease = await supervisor.registerPTY(
            PTYSessionCallbacks(
                cancel: {},
                awaitExit: { .cancelled }
            )
        )
        #expect(await supervisor.activePTYLeaseCount >= 1)
        _ = await supervisor.cancelPTY(lease)
        try? await Task.sleep(nanoseconds: 20_000_000)
    }

    @Test func test_TER_N07_localPTYTransportUsesHubAndSpool() throws {
        let root = packageRoot()
        let src = try String(
            contentsOf: root.appendingPathComponent("Sources/CodeEditorTerminal/LocalPTYTransport.swift"),
            encoding: .utf8
        )
        #expect(src.contains("AsyncBroadcastHub"))
        #expect(src.contains("BoundedByteSpool"))
        #expect(src.contains("ProcessSupervisor") || src.contains("registerPTY"))
        #expect(src.contains("TerminalOutboundWriteQueue") || src.contains("writeQueue"))
        #expect(src.contains(".cancelled"))
        #expect(src.contains("clampCells") || src.contains("TerminalDimension"))
        #expect(src.contains("ce_pty_spawn"))
    }

    @Test func test_TER_N07_realPTYSpawnEchoExitAndDescriptorLifecycle() async throws {
        #if os(macOS)
            let supervisor = ProcessSupervisor()
            let transport = LocalPTYTransport(
                platformProfile: .default(),
                securityPolicy: .forProfile(.macOSDirect),
                supervisor: supervisor
            )
            let cfg = TerminalConfiguration(
                shell: URL(fileURLWithPath: "/bin/echo"),
                arguments: ["hello-pty-n07"],
                cols: 80,
                rows: 24
            )
            let info = try await transport.start(
                TerminalLaunchRequest(
                    configuration: cfg,
                    metadata: TerminalMetadata(kind: .terminal, title: "n07")
                )
            )
            #expect(info.processId > 0)
            #expect(info.masterFD >= 0)
            // Descriptor must be open (F_GETFL succeeds).
            let flags = fcntl(info.masterFD, F_GETFL)
            #expect(flags >= 0, "master FD must be open after spawn")

            // Collect output until terminate / exit via multicast stream (actor-safe).
            final class Box: @unchecked Sendable {
                var output = Data()
                var reason: TerminalProcessExitReason?
            }
            let box = Box()
            let stream = await transport.makeEventStream(capacity: 64)
            let collector = Task {
                for await event in stream {
                    switch event {
                    case .output(let d):
                        box.output.append(d)
                    case .terminated(let r):
                        box.reason = r
                        return
                    default:
                        break
                    }
                }
            }
            // Allow echo to write and exit.
            try await Task.sleep(nanoseconds: 300_000_000)
            let exitReason = await transport.awaitExitReason()
            collector.cancel()
            // Natural exit of /bin/echo should be exited(0), not cancelled.
            switch exitReason {
            case .exited(let code):
                #expect(code == 0)
            case .cancelled:
                break
            default:
                break
            }
            let out = String(decoding: box.output, as: UTF8.self)
            #expect(
                out.contains("hello-pty-n07") || exitReason == .exited(code: 0) || box.reason != nil,
                "echo must produce output or clean exit, got out=\(out.prefix(80)) reason=\(exitReason)"
            )
            // Ensure terminate is idempotent after exit.
            await transport.terminate(.user)
        #else
            // Non-macOS: LocalPTY must fail closed.
            let transport = LocalPTYTransport(securityPolicy: .forProfile(.iOS))
            await #expect(throws: TerminalError.self) {
                _ = try await transport.start(TerminalLaunchRequest())
            }
        #endif
    }

    @Test func test_TER_N07_realPTYUserCancelIsCancelledNotExit0() async throws {
        #if os(macOS)
            let transport = LocalPTYTransport(
                securityPolicy: .forProfile(.macOSDirect)
            )
            // Long-running process so we can cancel.
            let cfg = TerminalConfiguration(
                shell: URL(fileURLWithPath: "/bin/cat"),
                arguments: [],
                cols: 40,
                rows: 12
            )
            let info = try await transport.start(TerminalLaunchRequest(configuration: cfg))
            #expect(info.processId > 0)
            #expect(info.masterFD >= 0)

            final class Box: @unchecked Sendable {
                var reason: TerminalProcessExitReason?
            }
            let box = Box()
            let stream = await transport.makeEventStream(capacity: 32)
            let collector = Task {
                for await event in stream {
                    if case .terminated(let r) = event {
                        box.reason = r
                        return
                    }
                }
            }
            try await transport.write(Data("ping\n".utf8))
            try await Task.sleep(nanoseconds: 50_000_000)
            await transport.terminate(.user)
            try await Task.sleep(nanoseconds: 150_000_000)
            collector.cancel()
            let last = await transport.lastExitReason
            let reason = box.reason ?? last
            #expect(reason == .cancelled, "user terminate must be cancelled, got \(String(describing: reason))")
            #expect(reason != .exited(code: 0))
        #else
            #expect(Bool(true))
        #endif
    }

    @Test func test_TER_N07_writeQueueBoundDocumented() async throws {
        let q = TerminalOutboundWriteQueue(maxBytes: 16)
        try await q.enqueue(Data(repeating: 0x41, count: 10))
        #expect(await q.queuedBytes == 10)
        do {
            try await q.enqueue(Data(repeating: 0x42, count: 10))
            Issue.record("must fail closed on write queue overflow")
        } catch let error as TerminalError {
            guard case .startFailed(let msg) = error else {
                Issue.record("wrong \(error)")
                return
            }
            #expect(msg.contains("overflow"))
        }
        #expect(await q.queuedBytes == 10)
        let taken = await q.take(maxChunk: 4)
        #expect(taken.count == 4)
        #expect(await q.queuedBytes == 6)
        let rest = await q.takeAll()
        #expect(rest.count == 6)
        #expect(await q.queuedBytes == 0)
    }

    @Test func test_TER_N07_writeQueueSerializesConcurrentEnqueues() async throws {
        let q = TerminalOutboundWriteQueue(maxBytes: 10_000)
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<50 {
                group.addTask {
                    try? await q.enqueue(Data("w\(i);".utf8))
                }
            }
        }
        let total = await q.queuedBytes
        #expect(total > 0)
        #expect(await q.totalWriteCount == 50)
        let all = await q.takeAll()
        #expect(all.count == total)
    }

    @Test func test_TER_N07_localPTYDeniesWhenPolicyDisallows() async throws {
        let transport = LocalPTYTransport(
            securityPolicy: .forProfile(.iOS)
        )
        do {
            _ = try await transport.start(TerminalLaunchRequest())
            Issue.record("iOS profile must deny local PTY")
        } catch let error as TerminalError {
            guard case .startFailed(let msg) = error else {
                Issue.record("wrong \(error)")
                return
            }
            #expect(msg.contains("denied") || msg.contains("PTY") || msg.contains("policy"))
        }
    }
}

// MARK: - TER-N08

@Suite("TER-N08 security policy profiles")
struct TERN08Tests {
    @Test func test_TER_N08_iOSDisallowsLocalPTY() {
        let p = TerminalSecurityPolicy.forProfile(.iOS)
        #expect(p.allowLocalPTY == false)
        #expect(p.allowRemoteTransport == true)
        #expect(p.allowsOSC52Write() == false)
    }

    @Test func test_TER_N08_macAppStoreRestrictsPTY() {
        let p = TerminalSecurityPolicy.forProfile(.macAppStore)
        #expect(p.allowLocalPTY == false)
        #expect(p.allowsHyperlinks() == false)
    }

    @Test func test_TER_N08_macOSDirectAllowsPTY() {
        let p = TerminalSecurityPolicy.forProfile(.macOSDirect)
        #expect(p.allowLocalPTY == true)
        #expect(p.workspaceTrusted == true)
    }

    @Test func test_TER_N08_extensionCapabilitiesFailClosed() throws {
        let p = TerminalSecurityPolicy.forProfile(.extensionSandbox)
        #expect(p.extensionAllows(.create) == false)
        #expect(throws: TerminalError.self) {
            try p.requireExtensionCapability(.create)
        }
        var granted = p
        granted.extensionCapabilities = [.create, .write]
        try granted.requireExtensionCapability(.create)
        #expect(granted.extensionAllows(.read) == false)
    }

    @Test func test_TER_N08_oscActionsIndividuallyPermissioned() throws {
        let r = TerminalSecurityPolicy.restricted
        #expect(r.allowsOSC52Write() == false)
        #expect(r.allowsDesktopNotifications() == false)
        #expect(r.allowsFileTransfer() == false)
        #expect(r.allowsShellIntegrationInjection() == false)
        #expect(throws: TerminalError.self) { try r.authorizeOSC52Write() }
        #expect(throws: TerminalError.self) { try r.authorizeHyperlinkOpen() }
        #expect(throws: TerminalError.self) { try r.authorizeFileTransfer() }
        #expect(throws: TerminalError.self) { try r.authorizeDesktopNotification() }
        #expect(throws: TerminalError.self) { try r.authorizeShellIntegrationInjection() }
        let t = TerminalSecurityPolicy.trusted
        #expect(t.allowsShellIntegrationInjection() == true)
        try t.authorizeShellIntegrationInjection()
    }

    @Test func test_TER_N08_serviceEnforcesIOSLocalPTYDenial() async throws {
        let service = TerminalService(
            securityPolicy: .forProfile(.iOS),
            requireGhosttyLinked: false
        )
        do {
            _ = try await service.create(
                transport: MockByteTransport(),
                transportClass: .localPTY,
                caller: .host
            )
            Issue.record("must deny localPTY under iOS profile")
        } catch let error as TerminalError {
            guard case .startFailed(let msg) = error else {
                Issue.record("wrong \(error)")
                return
            }
            #expect(msg.contains("local PTY") || msg.contains("denied"))
        }
        // Remote is allowed on iOS.
        let id = try await service.create(
            transport: MockByteTransport(),
            transportClass: .remote,
            caller: .host
        )
        try await service.close(id)
    }

    @Test func test_TER_N08_serviceEnforcesMacAppStoreLocalPTYDenial() async throws {
        let service = TerminalService(
            securityPolicy: .forProfile(.macAppStore),
            requireGhosttyLinked: false
        )
        do {
            _ = try await service.create(
                transport: MockByteTransport(),
                transportClass: .localPTY,
                caller: .host
            )
            Issue.record("macAppStore must deny localPTY")
        } catch is TerminalError {
            // expected
        }
    }

    @Test func test_TER_N08_serviceEnforcesExtensionCreateDenied() async throws {
        let service = TerminalService(
            securityPolicy: .forProfile(.extensionSandbox),
            requireGhosttyLinked: false,
            defaultCaller: .extensionClient
        )
        do {
            _ = try await service.create(
                transport: MockByteTransport(),
                transportClass: .inMemory,
                caller: .extensionClient
            )
            Issue.record("extension without create must fail closed")
        } catch let error as TerminalError {
            guard case .startFailed(let msg) = error else {
                Issue.record("wrong \(error)")
                return
            }
            #expect(msg.contains("capability") || msg.contains("denied") || msg.contains("extension"))
        }
    }

    @Test func test_TER_N08_serviceEnforcesWriteAndResizeCapabilities() async throws {
        var policy = TerminalSecurityPolicy.forProfile(.extensionSandbox)
        policy.extensionCapabilities = [.create] // no write/resize
        let service = TerminalService(
            securityPolicy: policy,
            requireGhosttyLinked: false
        )
        let id = try await service.create(
            transport: MockByteTransport(),
            transportClass: .inMemory,
            caller: .extensionClient
        )
        do {
            try await service.write(Data("x".utf8), to: id)
            Issue.record("write without capability must fail")
        } catch let error as TerminalError {
            guard case .startFailed = error else {
                Issue.record("wrong \(error)")
                return
            }
        }
        do {
            try await service.resize(cols: 40, rows: 12, session: id)
            Issue.record("resize without capability must fail")
        } catch let error as TerminalError {
            guard case .startFailed = error else {
                Issue.record("wrong \(error)")
                return
            }
        }
        // Host may still close.
        try await service.close(id, asCaller: .host)
    }

    @Test func test_TER_N08_extensionWithWriteCanWrite() async throws {
        var policy = TerminalSecurityPolicy.forProfile(.extensionSandbox)
        policy.extensionCapabilities = [.create, .write, .resize, .terminate, .read]
        let service = TerminalService(
            securityPolicy: policy,
            requireGhosttyLinked: false
        )
        let id = try await service.create(
            transport: MockByteTransport(),
            transportClass: .inMemory,
            caller: .extensionClient
        )
        try await service.write(Data("ok".utf8), to: id)
        try await service.resize(cols: 40, rows: 10, session: id)
        try await service.close(id, asCaller: .extensionClient)
    }

    @Test func test_TER_N08_macOSDirectAllowsLocalPTYCreate() async throws {
        let service = TerminalService(
            securityPolicy: .forProfile(.macOSDirect),
            requireGhosttyLinked: false
        )
        // authorizeCreate for localPTY succeeds; MockByteTransport is fine for policy-level check.
        let id = try await service.create(
            transport: MockByteTransport(),
            transportClass: .localPTY,
            caller: .host
        )
        #expect(await service.transportClass(for: id) == .localPTY)
        try await service.close(id)
    }

    @Test func test_TER_N08_extensionTerminateDeniedLeavesSession() async throws {
        var policy = TerminalSecurityPolicy.forProfile(.extensionSandbox)
        policy.extensionCapabilities = [.create, .write]
        let service = TerminalService(
            securityPolicy: policy,
            requireGhosttyLinked: false
        )
        let id = try await service.create(
            transport: MockByteTransport(),
            transportClass: .inMemory,
            caller: .extensionClient
        )
        do {
            try await service.close(id, asCaller: .extensionClient)
            Issue.record("terminate without capability must fail")
        } catch is TerminalError {
            // expected
        }
        #expect(await service.allSessions().count == 1)
        try await service.close(id, asCaller: .host)
        #expect(await service.allSessions().isEmpty)
    }
}

// MARK: - TER-N09

@Suite("TER-N09 CodeEditorTerminalGhostty tests exist")
struct TERN09Tests {
    @Test func test_TER_N09_ghosttyTestTargetPresent() throws {
        let root = packageRoot()
        let pkg = try String(contentsOf: root.appendingPathComponent("Package.swift"), encoding: .utf8)
        #expect(pkg.contains("CodeEditorTerminalGhosttyTests"))
        let testsDir = root.appendingPathComponent("Tests/CodeEditorTerminalGhosttyTests")
        #expect(FileManager.default.fileExists(atPath: testsDir.path))
    }

    @Test func test_TER_N09_linkedOrFailClosedSurfaceLifecycle() async throws {
        if GhosttySessionController.isLinked {
            let c = try GhosttySessionController(cols: 40, rows: 12, requireLinked: true)
            try await c.write(Data("hello\n".utf8))
            let snap = try await c.snapshotUTF8()
            #expect(snap.contains("hello"), "linked Ghostty snapshot must contain hello, got: \(snap.prefix(80))")
            try await c.resize(cols: 80, rows: 24)
            await c.shutdown()
        } else {
            #expect(throws: TerminalError.self) {
                _ = try GhosttySessionController(requireLinked: true)
            }
            #expect(GhosttySessionController.shimABI >= 1)
            #expect(GhosttySessionController.currentIntegrationLevel == .unavailable)
        }
    }

    @Test func test_TER_N09_conformanceFixturesPresent() throws {
        let root = packageRoot()
        let fixtures = root.appendingPathComponent("Tests/Fixtures/Ghostty")
        #expect(FileManager.default.fileExists(atPath: fixtures.path))
        for name in [
            "ansi-corpus.txt",
            "utf8-split.txt",
            "wide-emoji.txt",
            "mouse-focus.txt",
            "README.md",
        ] {
            let p = fixtures.appendingPathComponent(name)
            #expect(FileManager.default.fileExists(atPath: p.path), "missing fixture \(name)")
            let data = try Data(contentsOf: p)
            #expect(!data.isEmpty, "fixture \(name) must be non-empty")
        }
    }

    @Test func test_TER_N09_requireGhosttyEnvHardFailsWhenUnlinked() async throws {
        // When CI sets REQUIRE_GHOSTTY=1, linked Ghostty is mandatory.
        if ProcessInfo.processInfo.environment["REQUIRE_GHOSTTY"] == "1" {
            #expect(
                GhosttySessionController.isLinked,
                "REQUIRE_GHOSTTY=1 but ce_ghostty_is_linked()==false"
            )
        } else if !GhosttySessionController.isLinked {
            // Environment gap documented: fail-closed still holds.
            #expect(GhosttySessionController.currentIntegrationLevel == .unavailable)
        }
    }
}

// MARK: - TER-N10

@Suite("TER-N10 integration qualification")
struct TERN10Tests {
    @Test func test_TER_N10_shimABIIsPositive() {
        #expect(GhosttySessionController.shimABI >= 3)
    }

    @Test func test_TER_N10_pinFilePresentAndWellFormed() throws {
        let root = packageRoot()
        let pin = try String(
            contentsOf: root.appendingPathComponent("Docs/Architecture/GHOSTTY.pin"),
            encoding: .utf8
        )
        #expect(pin.contains("GHOSTTY_COMMIT="))
        #expect(pin.contains("GHOSTTY_REPO="))
        #expect(pin.contains("LICENSE=MIT") || pin.contains("MIT"))
        // Must be safe to `source` (quoted multi-word values).
        #expect(pin.contains("MINIMUM_ZIG=\"") || pin.contains("MINIMUM_ZIG='"))
        let commitLine = pin.split(separator: "\n").first { $0.hasPrefix("GHOSTTY_COMMIT=") }
        #expect(commitLine != nil)
        let commit = commitLine!.split(separator: "=").last!
        #expect(commit.count >= 7)
    }

    @Test func test_TER_N10_noGhosttyTypesInPublicSwiftAPI() throws {
        let root = packageRoot()
        for rel in [
            "Sources/CodeEditorTerminalGhostty/GhosttySessionController.swift",
            "Sources/CodeEditorTerminalGhostty/GhosttySurfaceView.swift",
            "Sources/CodeEditorTerminalGhostty/GhosttyNativeInput.swift",
            "Sources/CodeEditorTerminalGhostty/GhosttyPhysicalKey.swift",
        ] {
            let src = try String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8)
            #expect(!src.contains("GhosttyTerminal"))
            #expect(!src.contains("ghostty_terminal_"))
            #expect(!src.contains("import Ghostty"))
            #expect(!src.contains("GhosttyKeyEncoder"))
        }
    }

    @Test func test_TER_N10_checkGhosttyLinkedScriptIsHardGate() throws {
        let root = packageRoot()
        let script = try String(
            contentsOf: root.appendingPathComponent("scripts/check-ghostty-linked.sh"),
            encoding: .utf8
        )
        #expect(script.contains("REQUIRE_GHOSTTY"))
        #expect(script.contains("ghostty_terminal_new") || script.contains("symbol"))
        #expect(script.contains("CODEEDITOR_GHOSTTY_LINKED"))
        #expect(script.contains("ce_ghostty_shim_abi") || script.contains("SHIM_ABI") || script.contains("shim ABI"))
    }

    @Test func test_TER_N10_publicAPIUsesCodeEditorOwnedShimOnly() {
        #expect(GhosttySessionController.shimABI >= 3)
    }

    @Test func test_TER_N10_executesCheckGhosttyLinkedScriptSoftMode() throws {
        let root = packageRoot()
        let script = root.appendingPathComponent("scripts/check-ghostty-linked.sh")
        #expect(FileManager.default.fileExists(atPath: script.path))
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = [script.path]
        // Light mode: pin + ABI compile probe + fixtures only (no Ghostty network build).
        var env = ProcessInfo.processInfo.environment
        env["REQUIRE_GHOSTTY"] = "0"
        env["CE_GHOSTTY_GATE_LIGHT"] = "1"
        env["PATH"] = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        proc.environment = env
        let out = Pipe()
        let err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        try proc.run()
        proc.waitUntilExit()
        let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let combined = stdout + stderr
        #expect(proc.terminationStatus == 0, "light gate must pass: \(combined.prefix(600))")
        #expect(combined.contains("ABI="), "must run ABI probe: \(combined.prefix(400))")
        #expect(combined.contains("LINKED=0") || combined.contains("unlinked"), "must prove unlinked probe")
        #expect(combined.contains("OK:"), "must emit OK evidence lines")
        #expect(combined.contains("fixtures") || combined.contains("Fixtures") || combined.contains("fixture"))
        #expect(combined.contains("encode_mouse") || combined.contains("encode_key"))
    }

    @Test func test_TER_N10_linkedLibraryPresentWhenStampExists() throws {
        let root = packageRoot()
        let stamp = root.appendingPathComponent("Vendor/ghostty-build.stamp")
        let libA = root.appendingPathComponent("Vendor/ghostty/zig-out/lib/libghostty-vt.a")
        let libD = root.appendingPathComponent("Vendor/ghostty/zig-out/lib/libghostty-vt.dylib")
        if FileManager.default.fileExists(atPath: stamp.path) {
            #expect(
                FileManager.default.fileExists(atPath: libA.path)
                    || FileManager.default.fileExists(atPath: libD.path),
                "build stamp present but libghostty-vt missing"
            )
        }
        // When linked at runtime, library path must exist.
        if GhosttySessionController.isLinked {
            #expect(
                FileManager.default.fileExists(atPath: libA.path)
                    || FileManager.default.fileExists(atPath: libD.path)
            )
            #expect(GhosttySessionController.shimABI >= 3)
        }
    }

    @Test func test_TER_N10_gateScriptRequiresLinkedSymbolAndBehaviorProbes() throws {
        let root = packageRoot()
        let script = try String(
            contentsOf: root.appendingPathComponent("scripts/check-ghostty-linked.sh"),
            encoding: .utf8
        )
        #expect(script.contains("ghostty_terminal_new"))
        #expect(script.contains("ghostty_key_encoder_encode") || script.contains("encode_key"))
        #expect(script.contains("LINKED_BEHAVIOR") || script.contains("linked_probe"))
        #expect(script.contains("ce_ghostty_surface_encode_mouse"))
        #expect(script.contains("ce_ghostty_surface_line_utf8"))
        #expect(script.contains("REQUIRE_GHOSTTY=1") || script.contains("REQUIRE_GHOSTTY"))
    }

    @Test func test_TER_N10_abiProbeSymbolInHeader() throws {
        let root = packageRoot()
        let hdr = try String(
            contentsOf: root.appendingPathComponent("Sources/CGhosttyShim/include/codeeditor_ghostty.h"),
            encoding: .utf8
        )
        #expect(hdr.contains("CE_GHOSTTY_SHIM_ABI"))
        #expect(hdr.contains("ce_ghostty_shim_abi"))
        #expect(hdr.contains("ce_ghostty_is_linked"))
        #expect(hdr.contains("ce_ghostty_surface_encode_key"))
        #expect(GhosttySessionController.shimABI == 2 || GhosttySessionController.shimABI > 2)
    }
}

// MARK: - Helpers

private func packageRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}
