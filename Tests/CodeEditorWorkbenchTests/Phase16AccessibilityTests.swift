import Foundation
import Testing
import CodeEditorWorkspace
@testable import CodeEditorWorkbench

@Suite("Phase 16 accessibility")
struct Phase16AccessibilityTests {
    @Test func workbenchAccessibilityIDsAreNonEmpty() {
        #expect(!WorkbenchAccessibilityID.root.isEmpty)
        #expect(!WorkbenchAccessibilityID.toolbar.isEmpty)
        #expect(!WorkbenchAccessibilityID.activityBar.isEmpty)
        #expect(!WorkbenchAccessibilityID.navigator.isEmpty)
        #expect(!WorkbenchAccessibilityID.editor.isEmpty)
        #expect(!WorkbenchAccessibilityID.inspector.isEmpty)
        #expect(!WorkbenchAccessibilityID.statusBar.isEmpty)
        #expect(!WorkbenchAccessibilityID.commandPalette.isEmpty)
    }

    @Test func test_REL_N04_accessibilityHierarchyAndRotorSurfaces() {
        let ids = Set(WorkbenchAccessibilityHierarchy.flatten())
        for required in [
            WorkbenchAccessibilityID.root,
            WorkbenchAccessibilityID.toolbar,
            WorkbenchAccessibilityID.activityBar,
            WorkbenchAccessibilityID.navigator,
            WorkbenchAccessibilityID.editor,
            WorkbenchAccessibilityID.inspector,
            WorkbenchAccessibilityID.utility,
            WorkbenchAccessibilityID.statusBar,
        ] {
            #expect(ids.contains(required), "hierarchy missing \(required)")
        }
        let rotor = Set(WorkbenchAccessibilityHierarchy.rotorSurfaces.map(\.rawValue))
        for surface in ["errors", "symbols", "folds", "breakpoints", "search"] {
            #expect(rotor.contains(surface), "rotor missing \(surface)")
        }
        #expect(WorkbenchFocusOrder.keyboardOrder.count >= 5)
        #expect(WorkbenchAccessibilityHierarchy.focusRestorationDefault == WorkbenchAccessibilityID.editor)
    }

    /// REL-N04 — content-sourced automation (hierarchy/keyboard/rotor/Switch Control).
    /// Rotor hits come from a model snapshot, not seedRotorCatalog hardcode.
    @Test func test_REL_N04_xcuiEquivalentHierarchyKeyboardRotorSwitchControl() throws {
        let source = WorkbenchModelAccessibilityContentSource(
            snapshot: .init(
                errors: [("diag.error.0", "Error at line 1")],
                symbols: [("sym.func.main", "func main")],
                folds: [("fold.region.0", "Folded region")],
                breakpoints: [("bp.line.12", "Breakpoint line 12")],
                search: [("search.hit.0", "Search result")]
            )
        )
        let session = WorkbenchAccessibilitySession(
            preferences: .init(
                reduceMotion: false,
                highContrast: true,
                fullKeyboardAccess: true,
                dynamicTypeSize: 1.2,
                switchControlEnabled: true
            ),
            contentSource: source
        )

        // Hierarchy (VoiceOver tree surface)
        let ids = session.hierarchyIdentifiers()
        #expect(ids.contains(WorkbenchAccessibilityID.navigator))
        #expect(ids.contains(WorkbenchAccessibilityID.editor))
        #expect(ids.contains(WorkbenchAccessibilityID.inspector))
        #expect(ids.contains("diag.error.0"), "content identifiers must appear in hierarchy")
        #expect(session.accessibilityHierarchy().role == "application")

        // Keyboard-only navigation across chrome
        let start = session.focusedID
        var seen = Set<String>([start])
        for _ in 0..<WorkbenchFocusOrder.keyboardOrder.count {
            let next = session.moveFocus(steps: 1)
            seen.insert(next)
        }
        for region in [
            WorkbenchAccessibilityID.navigator,
            WorkbenchAccessibilityID.editor,
            WorkbenchAccessibilityID.inspector,
            WorkbenchAccessibilityID.utility,
        ] {
            #expect(seen.contains(region), "keyboard order never focused \(region)")
        }

        // Rotor actions from live content source (not hardcoded catalog)
        for surface in WorkbenchAccessibilityHierarchy.RotorSurface.allCases {
            let hits = session.rotorQuery(surface)
            #expect(!hits.isEmpty, "rotor surface \(surface) empty without content")
            let focus = session.selectRotorHit(hits[0])
            #expect(focus == WorkbenchAccessibilityID.editor)
        }

        // Empty source yields empty rotor (proves not hardcoded)
        let emptySession = WorkbenchAccessibilitySession(
            preferences: .init(switchControlEnabled: true),
            contentSource: EmptyAccessibilityContentSource()
        )
        #expect(emptySession.rotorQuery(.errors).isEmpty)
        #expect(emptySession.rotorQuery(.symbols).isEmpty)

        // Switch Control scan + select (fail-closed when disabled — see separate test)
        let scan = try session.switchControlScan()
        #expect(scan.count >= 5)
        let selected = try session.switchControlSelect(index: 2)
        #expect(scan.contains(selected))

        // Focus restoration after transient UI
        #expect(session.activate(identifier: WorkbenchAccessibilityID.commandPalette))
        let restored = session.dismissTransientAndRestoreFocus()
        #expect(restored == WorkbenchAccessibilityID.editor)

        // Reduce motion / high contrast / Dynamic Type
        session.apply(preferences: .init(reduceMotion: true, highContrast: true, dynamicTypeSize: 1.5, switchControlEnabled: true))
        _ = session.moveFocus(steps: 2)
        #expect(session.lastMotionUsed == false)
        #expect(session.chromePresentationValid())
    }

    @Test func test_REL_N04_switchControlFailsClosedWhenDisabled() throws {
        let session = WorkbenchAccessibilitySession(
            preferences: .init(switchControlEnabled: false),
            contentSource: EmptyAccessibilityContentSource()
        )
        #expect(session.preferences.switchControlEnabled == false)

        // Must invoke the real production APIs and observe fail-closed errors
        // (not a preference-only stub that never calls switchControlScan/Select).
        var scanError: Error?
        do {
            _ = try session.switchControlScan()
        } catch {
            scanError = error
        }
        #expect(scanError != nil, "switchControlScan must throw when Switch Control is disabled")
        #expect(
            (scanError as? WorkbenchAccessibilityError) == .switchControlDisabled,
            "scan must fail closed with switchControlDisabled"
        )

        var selectError: Error?
        do {
            _ = try session.switchControlSelect(index: 0)
        } catch {
            selectError = error
        }
        #expect(selectError != nil, "switchControlSelect must throw when Switch Control is disabled")
        #expect(
            (selectError as? WorkbenchAccessibilityError) == .switchControlDisabled,
            "select must fail closed with switchControlDisabled"
        )
    }

    @Test func test_REL_N04_noHardcodedRotorCatalogInProduction() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/CodeEditorWorkbench/WorkbenchAccessibilityAutomation.swift")
        let src = try String(contentsOf: url, encoding: .utf8)
        #expect(!src.contains("seedRotorCatalog"), "production must not hardcode rotor catalog")
        #expect(!src.contains("switchControlEnabled || true"), "Switch Control must fail closed")
        #expect(src.contains("WorkbenchAccessibilityContentSource"))
        #expect(src.contains("WorkbenchAccessibilityError") || src.contains("switchControlDisabled"))
        #expect(
            src.contains("throw WorkbenchAccessibilityError.switchControlDisabled")
                || src.contains("case switchControlDisabled"),
            "Switch Control must throw fail-closed error (not preference-only stub)"
        )
        // Probe must walk live AppKit AX (not a hardcoded ID list alone).
        #expect(
            src.contains("accessibilityChildren") || src.contains("AXUIElement") || src.contains("NSAccessibility"),
            "TreeProbe must walk AppKit/AX accessibility tree"
        )
        #expect(
            src.contains("NSHostingView")
                || src.contains("NSHostingController")
                || src.contains("hostWorkbench"),
            "TreeProbe must host live WorkbenchView chrome"
        )
        #expect(
            !src.contains("let viewDeclared: [String] = ["),
            "TreeProbe must not hardcode chrome ID catalog as AX substitute"
        )
    }

    #if canImport(AppKit)
    @Test @MainActor
    func test_REL_N04_appKitTreeProbeReachesPrimaryChrome() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("a11y-ax-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try await Workspace.local(rootDirectories: [root])
        let model = WorkbenchModel(
            workspace: workspace,
            configuration: WorkbenchAccessibilityTreeProbe.probeConfiguration
        )

        let snapshots = WorkbenchAccessibilityTreeProbe.collectLiveAccessibilityTree(model: model)
        #expect(
            !snapshots.isEmpty,
            "AppKit AX walk must return live elements (not empty hardcoded list)"
        )
        let ids = snapshots.map(\.identifier).filter { !$0.isEmpty }
        #expect(
            WorkbenchAccessibilityTreeProbe.assertPrimaryChromeReachable(model: model),
            "primary chrome regions must appear in live AppKit accessibility tree"
        )
        for required in [
            WorkbenchAccessibilityID.root,
            WorkbenchAccessibilityID.navigator,
            WorkbenchAccessibilityID.editor,
            WorkbenchAccessibilityID.inspector,
            WorkbenchAccessibilityID.utility,
            WorkbenchAccessibilityID.statusBar,
        ] {
            #expect(ids.contains(required), "live AX tree missing \(required)")
        }
        // Navigator/utility sub-panels declare identifiers on real SwiftUI surfaces.
        #expect(
            ids.contains(where: { $0.hasPrefix("workbench.navigator.") || $0.hasPrefix("workbench.utility.") }),
            "live AX tree should expose navigator or utility sub-panel identifiers from hosted views"
        )
        // Roles must come from AppKit, not invented catalog-only snapshots.
        #expect(snapshots.contains(where: { !$0.role.isEmpty }), "AX walk must report accessibility roles")
    }
    #endif
}
