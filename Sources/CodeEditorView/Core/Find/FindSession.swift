import CoreGraphics
import Foundation

/// Mutable find-panel session state owned by ``EditorController``.
@MainActor
public final class FindSession {
    public var isShowing: Bool = false
    public var mode: FindPanelMode = .find
    public var findText: String = ""
    public var replaceText: String = ""
    public var method: FindMethod = .contains
    public var matchCase: Bool = false
    public var wrapAround: Bool = true
    /// True while the find panel UI considers itself focused (drives emphasis visibility).
    public var isPanelFocused: Bool = false

    public var matches: [NSRange] = []
    public var currentMatchIndex: Int?

    /// Which text field should receive keyboard focus when ``fieldFocusToken`` changes.
    public enum FieldFocusTarget: String, Sendable, Equatable {
        case find
        case replace
    }

    /// Bumped when a panel text field should take keyboard focus (⌘F / ⌘R / show panel).
    public var fieldFocusToken: Int = 0
    /// Target field for the latest focus request.
    public var fieldFocusTarget: FieldFocusTarget = .find
    /// When focusing a field, select all existing text so the next keystroke replaces it.
    public var selectFieldTextOnFocus: Bool = false

    /// Backwards-compatible alias for find-field focus token.
    public var findFieldFocusToken: Int {
        get { fieldFocusToken }
        set { fieldFocusToken = newValue }
    }

    /// Backwards-compatible alias for selecting find query on focus.
    public var selectFindQueryOnFocus: Bool {
        get { selectFieldTextOnFocus && fieldFocusTarget == .find }
        set { selectFieldTextOnFocus = newValue }
    }

    public var matchCount: Int { matches.count }
    public var matchesEmpty: Bool { matches.isEmpty }

    public var panelHeight: CGFloat { mode.panelHeight }

    public var currentMatch: NSRange? {
        guard let currentMatchIndex, matches.indices.contains(currentMatchIndex) else {
            return nil
        }
        return matches[currentMatchIndex]
    }

    public init() {}
}
