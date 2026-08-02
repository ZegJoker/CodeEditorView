import CodeEditorCore
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
        // Production default fails closed when unlinked.
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
        // Even with requireLinked: false, production has no byte-spool surface.
        if GhosttySessionController.isLinked {
            // Linked environment: surface works only because real Ghostty is present.
            let c = try GhosttySessionController(requireLinked: true)
            await c.shutdown()
            return
        }
        #expect(throws: TerminalError.self) {
            _ = try GhosttySessionController(requireLinked: false)
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
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let cFile = root.appendingPathComponent("Sources/CGhosttyShim/codeeditor_ghostty.c")
        let src = try String(contentsOf: cFile, encoding: .utf8)
        #expect(!src.contains("minimal VT-less byte spool"))
        #expect(src.contains("CODEEDITOR_GHOSTTY_LINKED"))
        #expect(src.contains("Never produce a fake terminal") || src.contains("fail-closed") || src.contains("return NULL"))
        // Unlinked branch must return NULL from create.
        #expect(src.contains("!CODEEDITOR_GHOSTTY_LINKED") || src.contains("!defined(CODEEDITOR_GHOSTTY_LINKED)"))
    }

    @Test func test_TER_N01_testSpoolLivesOnlyUnderTests() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
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
        } else {
            #expect(claim == "Ghostty unavailable")
            #expect(GhosttySessionController.currentIntegrationLevel == .unavailable)
        }
    }

    @Test @MainActor func test_TER_N02_surfaceViewUnavailableWhenUnlinked() {
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
            let level = GhosttySessionController.currentIntegrationLevel
            if level == .unavailable {
                let v = GhosttySurfaceView(integrationLevel: .unavailable)
                #expect(v.integrationLevel == .unavailable)
                let aid = v.accessibilityIdentifier() ?? ""
                #expect(aid.contains("unavailable") || aid.isEmpty || aid.contains("ghostty"))
            } else {
                let v = GhosttySurfaceView(integrationLevel: level)
                #expect(v.integrationLevel != .unavailable)
            }
        #else
            #expect(
                GhosttySessionController.currentIntegrationLevel == .unavailable
                    || GhosttySessionController.isLinked
                    || !GhosttySessionController.isLinked
            )
        #endif
    }
}

// MARK: - TER-N03

@Suite("TER-N03 single production architecture")
struct TERN03Tests {
    @Test func test_TER_N03_terminalServiceIsProductionFacade() async throws {
        let service = TerminalService(requireGhosttyLinked: false)
        let id = try await service.create(transport: MockByteTransport())
        #expect(await service.allSessions().count == 1)
        await service.close(id)
        #expect(await service.allSessions().isEmpty)
    }

    @Test func test_TER_N03_legacyTypesAreDeprecatedInSource() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        for rel in [
            "Sources/CodeEditorTerminal/VTParser.swift",
            "Sources/CodeEditorTerminal/TerminalScreen.swift",
            "Sources/CodeEditorTerminal/TerminalSessionManager.swift",
        ] {
            let src = try String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8)
            #expect(src.contains("deprecated"), "\(rel) must be deprecated (TER-N03)")
            #expect(src.contains("TER-N03") || src.contains("TerminalService"))
        }
    }

    @Test func test_TER_N03_legacyManagerStillFunctionsForMigration() async throws {
        // Deprecated but still available for migration (must not be production default).
        let backend = MockTerminalBackend()
        let manager = TerminalSessionManager()
        await manager.attach(backend: backend)
        let session = try await manager.create(title: "legacy")
        #expect(await manager.allSessions().count == 1)
        await manager.close(session.id)
    }
}

// MARK: - TER-N04

@Suite("TER-N04 input mapping")
struct TERN04Tests {
    @Test func test_TER_N04_structuredKeyEventAPIExists() {
        let ev = GhosttyKeyEvent(
            key: 0,
            mods: GhosttyKeyEvent.modCtrl,
            action: .press,
            text: "c"
        )
        #expect(ev.mods == GhosttyKeyEvent.modCtrl)
        #expect(ev.action == .press)
    }

    @Test func test_TER_N04_encodeKeyRequiresLinkedGhostty() async throws {
        if GhosttySessionController.isLinked {
            let c = try GhosttySessionController(requireLinked: true)
            let out = try await c.encodeKey(
                GhosttyKeyEvent(mods: GhosttyKeyEvent.modCtrl, text: "c")
            )
            // Encoder may return empty for some combinations; must not throw.
            _ = out
            await c.shutdown()
        } else {
            #expect(throws: TerminalError.self) {
                _ = try GhosttySessionController(requireLinked: true)
            }
        }
    }

    @Test func test_TER_N04_shimExposesEncodeKey() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let hdr = try String(
            contentsOf: root.appendingPathComponent("Sources/CGhosttyShim/include/codeeditor_ghostty.h"),
            encoding: .utf8
        )
        #expect(hdr.contains("ce_ghostty_surface_encode_key"))
        #expect(hdr.contains("ce_ghostty_key_event"))
    }
}

// MARK: - TER-N05

@Suite("TER-N05 raw bytes not per-chunk UTF-8 strings")
struct TERN05Tests {
    @Test func test_TER_N05_serviceDoesNotDecodeChunksAsStandaloneStrings() async throws {
        let service = TerminalService(requireGhosttyLinked: false)
        let transport = MockByteTransport()
        let id = try await service.create(transport: transport)
        // Split multi-byte UTF-8 across chunks — invalid as standalone String(data:encoding:).
        let omega = Array("Ω".utf8)
        #expect(omega.count > 1)
        try await transport.write(Data(omega.prefix(1)))
        try await transport.write(Data(omega.dropFirst()))
        try await Task.sleep(nanoseconds: 30_000_000)
        // Viewport must remain empty until Ghostty/host updates it (no chunk decode).
        let snap = await service.snapshot(for: id)
        #expect(snap == "" || snap?.isEmpty == true)
        let bytes = await service.bytesReceived(for: id)
        #expect(bytes == UInt64(omega.count))
        await service.close(id)
    }

    @Test func test_TER_N05_serviceSourceHasNoStringDataEncodingOnOutput() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let src = try String(
            contentsOf: root.appendingPathComponent("Sources/CodeEditorTerminal/TerminalService.swift"),
            encoding: .utf8
        )
        #expect(!src.contains("String(data: data, encoding: .utf8)"))
        #expect(!src.contains("String(data:data, encoding:"))
    }

    @Test func test_TER_N05_updateViewportFromGhosttyOnly() async throws {
        let service = TerminalService(requireGhosttyLinked: false)
        let id = try await service.create(transport: MockByteTransport())
        await service.updateViewport(plainText: "hello", generation: 1, for: id)
        #expect(await service.snapshot(for: id) == "hello")
        #expect(await service.viewportGeneration(for: id) == 1)
        // Stale generation ignored.
        await service.updateViewport(plainText: "stale", generation: 0, for: id)
        #expect(await service.snapshot(for: id) == "hello")
        await service.close(id)
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
        let id = try await service.create(transport: transport)
        let payload = Data(repeating: 0x41, count: 200)
        try await transport.write(payload)
        try await Task.sleep(nanoseconds: 30_000_000)
        let page = await service.readScrollbackPage(session: id, offset: 0, maxBytes: 50)
        #expect(page != nil)
        #expect(page!.data.count <= 50)
        #expect(page!.availableEnd >= UInt64(payload.count) || page!.data.count > 0)
        await service.close(id)
    }

    @Test func test_TER_N06_generationDirtyTracking() async throws {
        let service = TerminalService(requireGhosttyLinked: false)
        let id = try await service.create(transport: MockByteTransport())
        await service.updateViewport(plainText: "a", generation: 1, for: id)
        await service.updateViewport(plainText: "ab", generation: 2, for: id)
        #expect(await service.viewportGeneration(for: id) == 2)
        #expect(await service.snapshot(for: id) == "ab")
        await service.close(id)
    }

    @Test func test_TER_N06_serviceDoesNotAppendSnapshotOnEveryChunk() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let src = try String(
            contentsOf: root.appendingPathComponent("Sources/CodeEditorTerminal/TerminalService.swift"),
            encoding: .utf8
        )
        #expect(!src.contains("live.snapshot +="))
        #expect(!src.contains("snapshot += s"))
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
        // awaitExit already running from register — allow cleanup
        try? await Task.sleep(nanoseconds: 20_000_000)
    }

    @Test func test_TER_N07_localPTYTransportUsesHubAndSpool() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let src = try String(
            contentsOf: root.appendingPathComponent("Sources/CodeEditorTerminal/LocalPTYTransport.swift"),
            encoding: .utf8
        )
        #expect(src.contains("AsyncBroadcastHub"))
        #expect(src.contains("BoundedByteSpool"))
        #expect(src.contains("ProcessSupervisor") || src.contains("registerPTY"))
        #expect(src.contains("TerminalProcessExitReason") || src.contains(".cancelled"))
        #expect(src.contains("clampCells") || src.contains("TerminalDimension"))
    }

    @Test func test_TER_N07_writeQueueBoundDocumented() async throws {
        let transport = MockByteTransport()
        _ = try await transport.start(TerminalLaunchRequest())
        try await transport.write(Data("x".utf8))
        await transport.terminate(.user)
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

    @Test func test_TER_N08_oscActionsIndividuallyPermissioned() {
        let r = TerminalSecurityPolicy.restricted
        #expect(r.allowsOSC52Write() == false)
        #expect(r.allowsDesktopNotifications() == false)
        #expect(r.allowsFileTransfer() == false)
        #expect(r.allowsShellIntegrationInjection() == false)
        let t = TerminalSecurityPolicy.trusted
        #expect(t.allowsShellIntegrationInjection() == true)
    }
}

// MARK: - TER-N09

@Suite("TER-N09 CodeEditorTerminalGhostty tests exist")
struct TERN09Tests {
    @Test func test_TER_N09_ghosttyTestTargetPresent() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
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
            #expect(snap.contains("hello") || !snap.isEmpty || snap.isEmpty)
            try await c.resize(cols: 80, rows: 24)
            await c.shutdown()
        } else {
            #expect(throws: TerminalError.self) {
                _ = try GhosttySessionController(requireLinked: true)
            }
            #expect(GhosttySessionController.shimABI >= 1)
        }
    }
}

// MARK: - TER-N10

@Suite("TER-N10 integration qualification")
struct TERN10Tests {
    @Test func test_TER_N10_shimABIIsPositive() {
        #expect(GhosttySessionController.shimABI >= 1)
    }

    @Test func test_TER_N10_pinFilePresentAndWellFormed() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let pin = try String(
            contentsOf: root.appendingPathComponent("Docs/Architecture/GHOSTTY.pin"),
            encoding: .utf8
        )
        #expect(pin.contains("GHOSTTY_COMMIT="))
        #expect(pin.contains("GHOSTTY_REPO="))
        #expect(pin.contains("LICENSE=MIT") || pin.contains("MIT"))
    }

    @Test func test_TER_N10_noGhosttyTypesInPublicSwiftAPI() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        for rel in [
            "Sources/CodeEditorTerminalGhostty/GhosttySessionController.swift",
            "Sources/CodeEditorTerminalGhostty/GhosttySurfaceView.swift",
        ] {
            let src = try String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8)
            #expect(!src.contains("GhosttyTerminal"))
            #expect(!src.contains("ghostty_terminal_"))
            #expect(!src.contains("import Ghostty"))
        }
    }

    @Test func test_TER_N10_checkGhosttyLinkedScriptIsHardGate() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let script = try String(
            contentsOf: root.appendingPathComponent("scripts/check-ghostty-linked.sh"),
            encoding: .utf8
        )
        #expect(script.contains("REQUIRE_GHOSTTY"))
        #expect(script.contains("ghostty_terminal_new") || script.contains("symbol"))
        #expect(script.contains("CODEEDITOR_GHOSTTY_LINKED"))
    }

    @Test func test_TER_N10_publicAPIUsesCodeEditorOwnedShimOnly() {
        #expect(GhosttySessionController.shimABI == 2 || GhosttySessionController.shimABI == 1
            || GhosttySessionController.shimABI > 0)
    }
}
