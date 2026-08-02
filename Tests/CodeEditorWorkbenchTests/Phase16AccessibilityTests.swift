import Testing

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

    /// REL-N04 — executable XCUI-equivalent automation (hierarchy/keyboard/rotor/Switch Control).
    @Test func test_REL_N04_xcuiEquivalentHierarchyKeyboardRotorSwitchControl() {
        let session = WorkbenchAccessibilitySession(
            preferences: .init(
                reduceMotion: false,
                highContrast: true,
                fullKeyboardAccess: true,
                dynamicTypeSize: 1.2,
                switchControlEnabled: true
            )
        )

        // Hierarchy (VoiceOver tree surface)
        let ids = session.hierarchyIdentifiers()
        #expect(ids.contains(WorkbenchAccessibilityID.navigator))
        #expect(ids.contains(WorkbenchAccessibilityID.editor))
        #expect(ids.contains(WorkbenchAccessibilityID.inspector))
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

        // Rotor actions
        for surface in WorkbenchAccessibilityHierarchy.RotorSurface.allCases {
            let hits = session.rotorQuery(surface)
            #expect(!hits.isEmpty, "rotor surface \(surface) empty")
            let focus = session.selectRotorHit(hits[0])
            #expect(focus == WorkbenchAccessibilityID.editor)
        }

        // Switch Control scan + select
        let scan = session.switchControlScan()
        #expect(scan.count >= 5)
        let selected = session.switchControlSelect(index: 2)
        #expect(scan.contains(selected))

        // Focus restoration after transient UI
        #expect(session.activate(identifier: WorkbenchAccessibilityID.commandPalette))
        let restored = session.dismissTransientAndRestoreFocus()
        #expect(restored == WorkbenchAccessibilityID.editor)

        // Reduce motion / high contrast / Dynamic Type
        session.apply(preferences: .init(reduceMotion: true, highContrast: true, dynamicTypeSize: 1.5))
        _ = session.moveFocus(steps: 2)
        #expect(session.lastMotionUsed == false)
        #expect(session.chromePresentationValid())
    }
}
