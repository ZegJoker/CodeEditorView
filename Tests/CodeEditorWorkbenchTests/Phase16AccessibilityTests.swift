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
}
