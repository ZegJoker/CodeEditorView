import CoreGraphics
import Foundation
import Observation

/// Observable mirror of ``FindSession`` for SwiftUI panel chrome (no Combine).
@MainActor
@Observable
public final class FindPanelBridge {
    public weak var controller: EditorController?

    public var isShowing: Bool = false
    public var mode: FindPanelMode = .find
    public var findText: String = ""
    public var replaceText: String = ""
    public var method: FindMethod = .contains
    public var matchCase: Bool = false
    public var wrapAround: Bool = true
    public var matchCount: Int = 0
    public var currentMatchIndex: Int?
    public var panelHeight: CGFloat = FindPanelMode.find.panelHeight
    public var fieldFocusToken: Int = 0
    public var fieldFocusTarget: FindSession.FieldFocusTarget = .find
    public var selectFieldTextOnFocus: Bool = false

    public init() {}

    public func syncFromController() {
        guard let session = controller?.findSession else { return }
        isShowing = session.isShowing
        mode = session.mode
        findText = session.findText
        replaceText = session.replaceText
        method = session.method
        matchCase = session.matchCase
        wrapAround = session.wrapAround
        matchCount = session.matchCount
        currentMatchIndex = session.currentMatchIndex
        panelHeight = session.panelHeight
        fieldFocusToken = session.fieldFocusToken
        fieldFocusTarget = session.fieldFocusTarget
        selectFieldTextOnFocus = session.selectFieldTextOnFocus
    }

    public func setFindText(_ text: String) {
        controller?.setFindQuery(text)
        syncFromController()
    }

    public func setReplaceText(_ text: String) {
        controller?.setReplaceText(text)
        syncFromController()
    }

    public func setMode(_ mode: FindPanelMode) {
        controller?.setFindPanelMode(mode)
        syncFromController()
    }

    public func setMethod(_ method: FindMethod) {
        controller?.setFindMethod(method)
        syncFromController()
    }

    public func setMatchCase(_ value: Bool) {
        controller?.setMatchCase(value)
        syncFromController()
    }

    public func setWrapAround(_ value: Bool) {
        controller?.setWrapAround(value)
        syncFromController()
    }

    public func findNext() {
        controller?.findNext()
        syncFromController()
    }

    public func findPrevious() {
        controller?.findPrevious()
        syncFromController()
    }

    public func replace() {
        controller?.replaceCurrentMatch()
        syncFromController()
    }

    public func replaceAll() {
        controller?.replaceAllMatches()
        syncFromController()
    }

    public func dismiss() {
        controller?.hideFindPanel()
        syncFromController()
    }

    public func setFocused(_ focused: Bool) {
        controller?.setFindPanelFocused(focused)
        syncFromController()
    }
}
