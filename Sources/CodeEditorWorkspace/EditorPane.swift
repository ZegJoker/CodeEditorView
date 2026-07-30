import Foundation
import Observation
import CodeEditorDocuments

public struct EditorTab: Hashable, Codable, Sendable {
    public let id: EditorTabID
    public let sessionID: EditorSessionID
    public let documentID: DocumentID
    public var documentURI: DocumentURI
    public var isPreview: Bool
    public var isPinned: Bool

    public init(
        id: EditorTabID = EditorTabID(),
        sessionID: EditorSessionID,
        documentID: DocumentID,
        documentURI: DocumentURI,
        isPreview: Bool = false,
        isPinned: Bool = false
    ) {
        self.id = id
        self.sessionID = sessionID
        self.documentID = documentID
        self.documentURI = documentURI
        self.isPreview = isPreview
        self.isPinned = isPinned
    }
}

/// One editor pane: ordered tabs, selection, optional preview tab.
@MainActor
@Observable
public final class EditorPane {
    public let id: EditorPaneID
    public private(set) var tabs: [EditorTab]
    public private(set) var selectedTabID: EditorTabID?
    public private(set) var previewTabID: EditorTabID?

    public init(id: EditorPaneID = EditorPaneID(), tabs: [EditorTab] = [], selectedTabID: EditorTabID? = nil) {
        self.id = id
        self.tabs = tabs
        self.selectedTabID = selectedTabID ?? tabs.first?.id
        self.previewTabID = tabs.first(where: \.isPreview)?.id
    }

    public var selectedTab: EditorTab? {
        guard let selectedTabID else { return nil }
        return tabs.first { $0.id == selectedTabID }
    }

    /// Result of opening a tab, including any preview tab that was replaced.
    public struct OpenResult: Sendable {
        public let tab: EditorTab
        /// Previous preview tab removed to make room (caller should dispose session).
        public let replacedPreview: EditorTab?

        public init(tab: EditorTab, replacedPreview: EditorTab? = nil) {
            self.tab = tab
            self.replacedPreview = replacedPreview
        }
    }

    /// Opens a tab. Preview policy: at most one unpinned preview; new preview replaces it.
    /// When reusing an existing tab with `preview == false`, promotes that tab to permanent.
    @discardableResult
    public func open(
        sessionID: EditorSessionID,
        documentID: DocumentID,
        documentURI: DocumentURI,
        preview: Bool
    ) -> OpenResult {
        // Reuse existing tab for same document.
        if let existing = tabs.first(where: { $0.documentID == documentID }) {
            selectedTabID = existing.id
            if !preview {
                promotePreviewIfNeeded(tab: existing.id)
            }
            // Re-read after possible promote.
            let current = tabs.first(where: { $0.id == existing.id }) ?? existing
            return OpenResult(tab: current, replacedPreview: nil)
        }

        var replaced: EditorTab?
        if preview {
            if let previewID = previewTabID,
               let idx = tabs.firstIndex(where: { $0.id == previewID }),
               !tabs[idx].isPinned {
                replaced = tabs.remove(at: idx)
                if selectedTabID == previewID {
                    selectedTabID = tabs.last?.id
                }
                previewTabID = nil
            }
        }

        let tab = EditorTab(
            sessionID: sessionID,
            documentID: documentID,
            documentURI: documentURI,
            isPreview: preview,
            isPinned: false
        )
        tabs.append(tab)
        selectedTabID = tab.id
        if preview {
            previewTabID = tab.id
        }
        return OpenResult(tab: tab, replacedPreview: replaced)
    }

    public func select(tab id: EditorTabID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        selectedTabID = id
    }

    @discardableResult
    public func close(tab id: EditorTabID) -> EditorTab? {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return nil }
        let removed = tabs.remove(at: idx)
        if previewTabID == id { previewTabID = nil }
        if selectedTabID == id {
            selectedTabID = tabs.indices.contains(idx)
                ? tabs[idx].id
                : tabs.last?.id
        }
        return removed
    }

    public func pin(tab id: EditorTabID) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[idx].isPinned = true
        tabs[idx].isPreview = false
        if previewTabID == id { previewTabID = nil }
    }

    /// Converts preview tab to permanent (e.g. after edit).
    public func promotePreviewIfNeeded(tab id: EditorTabID) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }), tabs[idx].isPreview else { return }
        tabs[idx].isPreview = false
        if previewTabID == id { previewTabID = nil }
    }

    public func moveTab(from: Int, to: Int) {
        guard tabs.indices.contains(from), to >= 0, to <= tabs.count else { return }
        let tab = tabs.remove(at: from)
        let dest = min(to, tabs.count)
        tabs.insert(tab, at: dest)
    }

    public func updateURI(documentID: DocumentID, uri: DocumentURI) {
        for i in tabs.indices where tabs[i].documentID == documentID {
            tabs[i].documentURI = uri
        }
    }

    /// Restores tab list from serialized state (preserves IDs).
    public func restore(
        tabs restored: [EditorTab],
        selectedTabID: EditorTabID?,
        previewTabID: EditorTabID?
    ) {
        self.tabs = restored
        self.selectedTabID = selectedTabID ?? restored.first?.id
        self.previewTabID = previewTabID ?? restored.first(where: \.isPreview)?.id
    }
}
