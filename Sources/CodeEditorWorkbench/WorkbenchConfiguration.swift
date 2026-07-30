import Foundation
import CoreGraphics
import CodeEditorView

/// How the project navigator is presented relative to the editor.
public enum WorkbenchNavigatorStyle: String, Sendable, Equatable, Hashable, CaseIterable {
    /// Continuous left column (Xcode default).
    case docked
    /// Inset floating material card.
    case floating
}

/// Host-controlled workbench chrome defaults.
public struct WorkbenchConfiguration: Sendable, Equatable {
    public var showsNavigator: Bool
    public var showsInspector: Bool
    public var showsUtilityArea: Bool
    public var showsStatusBar: Bool
    public var showsActivityBar: Bool
    public var showsToolbar: Bool
    public var navigatorStyle: WorkbenchNavigatorStyle
    /// Initial utility area height (resizable at runtime on the model).
    public var utilityAreaHeight: CGFloat
    public var editorConfiguration: EditorConfiguration

    public init(
        showsNavigator: Bool = true,
        showsInspector: Bool = false,
        showsUtilityArea: Bool = false,
        showsStatusBar: Bool = true,
        showsActivityBar: Bool = true,
        showsToolbar: Bool = true,
        navigatorStyle: WorkbenchNavigatorStyle = .docked,
        utilityAreaHeight: CGFloat = 180,
        editorConfiguration: EditorConfiguration = EditorConfiguration()
    ) {
        self.showsNavigator = showsNavigator
        self.showsInspector = showsInspector
        self.showsUtilityArea = showsUtilityArea
        self.showsStatusBar = showsStatusBar
        self.showsActivityBar = showsActivityBar
        self.showsToolbar = showsToolbar
        self.navigatorStyle = navigatorStyle
        self.utilityAreaHeight = utilityAreaHeight
        self.editorConfiguration = editorConfiguration
    }

    /// Configuration with source-oriented editor defaults (no soft wrap — Xcode-like).
    public static var xcodeLike: WorkbenchConfiguration {
        var editor = EditorConfiguration()
        editor.wrapLines = false
        return WorkbenchConfiguration(editorConfiguration: editor)
    }

    public static let `default` = WorkbenchConfiguration()
}

/// Legacy utility tab labels (hosts should prefer contribution ids).
public enum UtilityAreaTab: String, Hashable, Sendable, CaseIterable {
    case output
    case problems
    case terminal
}
