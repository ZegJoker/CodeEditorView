import Foundation
import CodeEditorView

/// Host-controlled workbench chrome defaults.
public struct WorkbenchConfiguration: Sendable, Equatable {
    public var showsNavigator: Bool
    public var showsInspector: Bool
    public var showsUtilityArea: Bool
    public var showsStatusBar: Bool
    public var showsActivityBar: Bool
    public var showsToolbar: Bool
    public var editorConfiguration: EditorConfiguration

    public init(
        showsNavigator: Bool = true,
        showsInspector: Bool = false,
        showsUtilityArea: Bool = false,
        showsStatusBar: Bool = true,
        showsActivityBar: Bool = true,
        showsToolbar: Bool = true,
        editorConfiguration: EditorConfiguration = EditorConfiguration()
    ) {
        self.showsNavigator = showsNavigator
        self.showsInspector = showsInspector
        self.showsUtilityArea = showsUtilityArea
        self.showsStatusBar = showsStatusBar
        self.showsActivityBar = showsActivityBar
        self.showsToolbar = showsToolbar
        self.editorConfiguration = editorConfiguration
    }

    public static let `default` = WorkbenchConfiguration()
}

public enum UtilityAreaTab: String, Hashable, Sendable, CaseIterable {
    case output
    case problems
    case terminal
}
