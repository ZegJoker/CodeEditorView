import CoreGraphics
import Foundation
import Observation
import CodeEditorCore

/// Per-view find panel state (independent of other sessions on the same document).
public struct EditorFindState: Equatable, Hashable, Sendable, Codable {
    public var findText: String
    public var replaceText: String
    public var isPanelVisible: Bool

    public init(
        findText: String = "",
        replaceText: String = "",
        isPanelVisible: Bool = false
    ) {
        self.findText = findText
        self.replaceText = replaceText
        self.isPanelVisible = isPanelVisible
    }

    public static let empty = EditorFindState()
}

/// Presentation state for one editor view on a shared document.
///
/// Does not own document content or undo. Theme/wrapping live on the controller
/// configuration so this module stays free of View types.
@MainActor
@Observable
public final class EditorSession {
    public let id: EditorSessionID
    public let documentID: DocumentID

    public var selections: [CodeEditorCore.TextRange]
    public var scrollPosition: CGPoint?
    public var findState: EditorFindState

    public init(
        id: EditorSessionID = EditorSessionID(),
        documentID: DocumentID,
        selections: [CodeEditorCore.TextRange] = [CodeEditorCore.TextRange(location: 0, length: 0)],
        scrollPosition: CGPoint? = nil,
        findState: EditorFindState = .empty
    ) {
        self.id = id
        self.documentID = documentID
        self.selections = selections
        self.scrollPosition = scrollPosition
        self.findState = findState
    }

    public var primarySelection: CodeEditorCore.TextRange {
        selections.first ?? CodeEditorCore.TextRange(location: 0, length: 0)
    }

    public var selectedNSRanges: [NSRange] {
        selections.map(\.nsRange)
    }

    public func setSelectedNSRanges(_ ranges: [NSRange]) {
        selections = ranges.map { CodeEditorCore.TextRange($0) }
        if selections.isEmpty {
            selections = [CodeEditorCore.TextRange(location: 0, length: 0)]
        }
    }
}
