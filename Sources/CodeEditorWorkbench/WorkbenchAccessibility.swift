import Foundation

/// Stable accessibility identifiers for workbench chrome (VoiceOver / keyboard).
public enum WorkbenchAccessibilityID {
    public static let root = "workbench.root"
    public static let toolbar = "workbench.toolbar"
    public static let activityBar = "workbench.activityBar"
    public static let navigator = "workbench.navigator"
    public static let editor = "workbench.editor"
    public static let inspector = "workbench.inspector"
    public static let utility = "workbench.utility"
    public static let statusBar = "workbench.statusBar"
    public static let commandPalette = "workbench.commandPalette"
    public static let openQuickly = "workbench.openQuickly"
    public static let toolingBanner = "workbench.toolingBanner"
    public static let contributionFault = "workbench.contributionFault"
}

/// Localized chrome strings (English defaults; key structure for localization).
public enum WorkbenchL10n {
    public static func string(_ key: String, default defaultValue: String) -> String {
        // Bundle lookup can be wired by hosts; default to English fallback.
        Bundle.main.localizedString(forKey: key, value: defaultValue, table: "Workbench")
    }

    public static var navigator: String { string("workbench.navigator", default: "Navigator") }
    public static var inspector: String { string("workbench.inspector", default: "Inspector") }
    public static var utility: String { string("workbench.utility", default: "Debug Area") }
    public static var editor: String { string("workbench.editor", default: "Editor") }
    public static var openQuickly: String { string("workbench.openQuickly", default: "Open Quickly") }
    public static var commandPalette: String { string("workbench.commandPalette", default: "Command Palette") }
    public static var noActiveEditor: String { string("workbench.noActiveEditor", default: "No active editor") }
    public static var openFileHint: String {
        string("workbench.openFileHint", default: "Open a text file to run editor commands.")
    }
    public static var contributionFailed: String {
        string("workbench.contributionFailed", default: "This contribution failed to load.")
    }
    public static var retry: String { string("workbench.retry", default: "Retry") }
    public static var dismiss: String { string("workbench.dismiss", default: "Dismiss") }
    public static var toolingFailed: String {
        string("workbench.toolingFailed", default: "A tooling provider reported a failure.")
    }
}

/// Focus-order priorities for keyboard / VO traversal (lower = earlier).
public enum WorkbenchFocusOrder {
    public static let activityBar = 10
    public static let navigator = 20
    public static let editor = 30
    public static let inspector = 40
    public static let utility = 50
    public static let statusBar = 60
    public static let toolbar = 5
}
