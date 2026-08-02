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
}
