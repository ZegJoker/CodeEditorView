import CoreGraphics
import Foundation
import Observation
import CodeEditorCore
import CodeEditorDocuments

/// Headless multi-root workspace: files, open documents, panes/tabs, layout, history.
@MainActor
@Observable
public final class Workspace {
    public let id: WorkspaceID
    public let fileSystem: any WorkspaceFileSystem
    public let fileTree: WorkspaceFileTree
    public let documents: DocumentRegistry
    public let documentProvider: any DocumentContentProvider
    public let layout: EditorLayoutStore

    public private(set) var panes: [EditorPaneID: EditorPane]
    public private(set) var sessions: [EditorSessionID: EditorSession]
    public private(set) var activePaneID: EditorPaneID?
    public private(set) var focusHistory: [EditorPaneID]
    public let navigationHistory: NavigationHistory
    public let settings: WorkspaceSettings
    /// Bumped on structural UI-affecting changes so SwiftUI hosts can depend on a single token.
    public private(set) var revision: UInt64 = 0

    public init(
        id: WorkspaceID = WorkspaceID(),
        fileSystem: any WorkspaceFileSystem,
        documentProvider: any DocumentContentProvider = LocalFileDocumentProvider(),
        documents: DocumentRegistry = DocumentRegistry(),
        settings: WorkspaceSettings = .default
    ) {
        self.id = id
        self.fileSystem = fileSystem
        self.fileTree = WorkspaceFileTree(fileSystem: fileSystem)
        self.documentProvider = documentProvider
        self.documents = documents
        self.settings = settings
        self.sessions = [:]
        self.navigationHistory = NavigationHistory()
        self.focusHistory = []

        let pane = EditorPane()
        self.panes = [pane.id: pane]
        self.layout = EditorLayoutStore(singlePane: pane.id)
        self.activePaneID = pane.id
        self.focusHistory = [pane.id]
    }

    /// Convenience for local disk roots.
    public static func local(
        rootDirectories: [URL],
        settings: WorkspaceSettings = .default
    ) async throws -> Workspace {
        let fs = try LocalWorkspaceFileSystem(rootDirectories: rootDirectories, settings: settings)
        return Workspace(fileSystem: fs, documentProvider: LocalFileDocumentProvider(), settings: settings)
    }

    // MARK: - Roots

    public func addRoot(directoryURL: URL) async throws -> WorkspaceRoot {
        let root = try await fileSystem.addRoot(directoryURL: directoryURL)
        fileTree.refreshRoots()
        fileTree.apply(.rootAdded(root))
        noteRevision()
        return root
    }

    public func removeRoot(_ id: WorkspaceRootID) async throws {
        try await fileSystem.removeRoot(id: id)
        fileTree.apply(.rootRemoved(id))
        noteRevision()
    }

    // MARK: - Documents / tabs

    @discardableResult
    public func openDocument(uri: DocumentURI) async throws -> TextDocument {
        if let existing = documents.document(uri: uri) {
            return existing
        }
        let doc = TextDocument(uri: uri, text: "")
        try await doc.load(from: documentProvider, uri: uri)
        documents.register(doc)
        noteRevision()
        return doc
    }

    @discardableResult
    public func openInActivePane(uri: DocumentURI, preview: Bool = false) async throws -> (document: TextDocument, session: EditorSession, tab: EditorTab) {
        let paneID = activePaneID ?? ensureActivePane()
        return try await open(uri: uri, in: paneID, preview: preview)
    }

    @discardableResult
    public func open(
        uri: DocumentURI,
        in paneID: EditorPaneID,
        preview: Bool = false
    ) async throws -> (document: TextDocument, session: EditorSession, tab: EditorTab) {
        guard let pane = panes[paneID] else {
            throw WorkspaceError.paneNotFound
        }
        let doc = try await openDocument(uri: uri)
        // Reuse session if tab already exists for document.
        if let existingTab = pane.tabs.first(where: { $0.documentID == doc.id }),
           let session = sessions[existingTab.sessionID] {
            pane.select(tab: existingTab.id)
            // Permanent open / double-click must keep the tab (promote preview).
            if !preview {
                pane.promotePreviewIfNeeded(tab: existingTab.id)
            }
            setActivePane(paneID)
            pushNavigation(document: doc, session: session)
            noteRevision()
            let tab = pane.tabs.first(where: { $0.documentID == doc.id }) ?? existingTab
            return (doc, session, tab)
        }

        let session = EditorSession(documentID: doc.id)
        sessions[session.id] = session
        let opened = pane.open(
            sessionID: session.id,
            documentID: doc.id,
            documentURI: doc.uri,
            preview: preview
        )
        // Dispose session owned only by the replaced preview tab.
        if let replaced = opened.replacedPreview {
            let stillUsed = panes.values.contains { p in
                p.tabs.contains { $0.sessionID == replaced.sessionID }
            }
            if !stillUsed {
                sessions[replaced.sessionID] = nil
            }
        }
        setActivePane(paneID)
        pushNavigation(document: doc, session: session)
        noteRevision()
        return (doc, session, opened.tab)
    }

    public func closeTab(_ tabID: EditorTabID, in paneID: EditorPaneID) {
        guard let pane = panes[paneID] else { return }
        if let removed = pane.close(tab: tabID) {
            // Drop session if unused by other panes.
            let stillUsed = panes.values.contains { p in
                p.tabs.contains { $0.sessionID == removed.sessionID }
            }
            if !stillUsed {
                sessions[removed.sessionID] = nil
            }
            noteRevision()
        }
    }

    public func selectTab(_ tabID: EditorTabID, in paneID: EditorPaneID) {
        panes[paneID]?.select(tab: tabID)
        setActivePane(paneID)
    }

    /// Promotes a preview tab to a permanent tab (VS Code / Xcode: double-click tab to keep open).
    /// Does not set pin; use ``pinTab(_:in:)`` for an explicit pin.
    public func keepTabOpen(_ tabID: EditorTabID, in paneID: EditorPaneID) {
        panes[paneID]?.promotePreviewIfNeeded(tab: tabID)
        noteRevision()
    }

    public func pinTab(_ tabID: EditorTabID, in paneID: EditorPaneID) {
        panes[paneID]?.pin(tab: tabID)
        noteRevision()
    }

    public func closeOtherTabs(keeping tabID: EditorTabID, in paneID: EditorPaneID) {
        guard let pane = panes[paneID] else { return }
        let toClose = pane.tabs.map(\.id).filter { $0 != tabID }
        for id in toClose {
            closeTab(id, in: paneID)
        }
    }

    public func closeTabsToTheRight(of tabID: EditorTabID, in paneID: EditorPaneID) {
        guard let pane = panes[paneID],
              let idx = pane.tabs.firstIndex(where: { $0.id == tabID })
        else { return }
        let toClose = pane.tabs.suffix(from: idx + 1).map(\.id)
        for id in toClose {
            closeTab(id, in: paneID)
        }
    }

    public func promotePreviewTabs(for documentID: DocumentID) {
        for pane in panes.values {
            if let tab = pane.tabs.first(where: { $0.documentID == documentID }) {
                pane.promotePreviewIfNeeded(tab: tab.id)
            }
        }
        noteRevision()
    }

    public func updateTabURIs(documentID: DocumentID, uri: DocumentURI) {
        for pane in panes.values {
            pane.updateURI(documentID: documentID, uri: uri)
        }
        noteRevision()
    }

    // MARK: - Layout / focus

    public func setActivePane(_ id: EditorPaneID) {
        guard panes[id] != nil else { return }
        activePaneID = id
        focusHistory.removeAll { $0 == id }
        focusHistory.insert(id, at: 0)
        noteRevision()
    }

    @discardableResult
    public func splitActivePane(axis: EditorSplitAxis, fraction: Double = 0.5) -> EditorPaneID? {
        guard let active = activePaneID else { return nil }
        let newPane = EditorPane()
        panes[newPane.id] = newPane
        layout.split(pane: active, axis: axis, newPane: newPane.id, fraction: fraction)
        setActivePane(newPane.id)
        return newPane.id
    }

    public func closePane(_ id: EditorPaneID) {
        guard panes.count > 1 else { return }
        // Close tabs first
        if let pane = panes[id] {
            for tab in pane.tabs {
                closeTab(tab.id, in: id)
            }
        }
        panes[id] = nil
        layout.close(pane: id)
        focusHistory.removeAll { $0 == id }
        if activePaneID == id {
            activePaneID = layout.allPaneIDs().first ?? panes.keys.first
            if let activePaneID {
                setActivePane(activePaneID)
            }
        }
        // Ensure every layout pane id has a pane object.
        for paneID in layout.allPaneIDs() where panes[paneID] == nil {
            panes[paneID] = EditorPane(id: paneID)
        }
        noteRevision()
    }

    /// Create a file under `parent` (empty path = workspace root item).
    @discardableResult
    public func createFile(in parent: WorkspaceItemID, name: String, contents: Data = Data()) async throws -> WorkspaceItem {
        let item = try await fileSystem.createFile(in: parent, name: name, contents: contents)
        fileTree.apply(.added(item))
        fileTree.invalidate(parent)
        _ = try await fileTree.children(of: parent)
        noteRevision()
        return item
    }

    /// Create a directory under `parent`.
    @discardableResult
    public func createDirectory(in parent: WorkspaceItemID, name: String) async throws -> WorkspaceItem {
        let item = try await fileSystem.createDirectory(in: parent, name: name)
        fileTree.apply(.added(item))
        fileTree.invalidate(parent)
        _ = try await fileTree.children(of: parent)
        noteRevision()
        return item
    }

    private func noteRevision() {
        revision &+= 1
    }

    // MARK: - Navigation

    public func navigateBack() -> NavigationEntry? {
        navigationHistory.back()
    }

    public func navigateForward() -> NavigationEntry? {
        navigationHistory.forward()
    }

    private func pushNavigation(document: TextDocument, session: EditorSession) {
        navigationHistory.push(
            NavigationEntry(
                documentURI: document.uri,
                documentID: document.id,
                sessionID: session.id,
                selection: session.primarySelection,
                scrollY: session.scrollPosition.map { Double($0.y) }
            )
        )
    }

    private func ensureActivePane() -> EditorPaneID {
        if let activePaneID, panes[activePaneID] != nil { return activePaneID }
        let pane = EditorPane()
        panes[pane.id] = pane
        layout.replaceRoot(.pane(pane.id))
        setActivePane(pane.id)
        return pane.id
    }

    // MARK: - Restoration

    public func captureRestorationState() -> WorkspaceRestorationState {
        let restoredPanes: [RestoredPane] = panes.values.map { pane in
            RestoredPane(
                id: pane.id,
                tabs: pane.tabs.map { tab in
                    let session = sessions[tab.sessionID]
                    return RestoredTab(
                        id: tab.id,
                        documentURI: tab.documentURI,
                        isPreview: tab.isPreview,
                        isPinned: tab.isPinned,
                        selection: session?.primarySelection,
                        scrollY: session?.scrollPosition.map { Double($0.y) }
                    )
                },
                selectedTabID: pane.selectedTabID,
                previewTabID: pane.previewTabID
            )
        }
        return WorkspaceRestorationState(
            workspaceID: id,
            roots: fileSystem.roots,
            layout: layout.root,
            panes: restoredPanes,
            activePaneID: activePaneID,
            focusHistory: focusHistory,
            navigation: navigationHistory.entries(),
            navigationIndex: navigationHistory.entries().isEmpty ? -1 : navigationHistory.entries().count - 1
        )
    }

    public static func restore(
        from state: WorkspaceRestorationState,
        fileSystem: any WorkspaceFileSystem,
        documentProvider: any DocumentContentProvider = LocalFileDocumentProvider()
    ) async throws -> Workspace {
        let migrated = WorkspaceRestoration.migrate(state)
        let workspace = Workspace(
            id: migrated.workspaceID,
            fileSystem: fileSystem,
            documentProvider: documentProvider
        )
        // Replace default pane/layout with restored structure.
        workspace.panes.removeAll()
        workspace.layout.replaceRoot(migrated.layout)

        for restoredPane in migrated.panes {
            let pane = EditorPane(id: restoredPane.id)
            var rebuiltTabs: [EditorTab] = []
            for tab in restoredPane.tabs {
                let doc = try await workspace.openDocument(uri: tab.documentURI)
                let session = EditorSession(documentID: doc.id)
                if let selection = tab.selection {
                    session.selections = [selection]
                }
                if let scrollY = tab.scrollY {
                    session.scrollPosition = CGPoint(x: 0, y: scrollY)
                }
                workspace.sessions[session.id] = session
                rebuiltTabs.append(
                    EditorTab(
                        id: tab.id,
                        sessionID: session.id,
                        documentID: doc.id,
                        documentURI: tab.documentURI,
                        isPreview: tab.isPreview,
                        isPinned: tab.isPinned
                    )
                )
            }
            pane.restore(
                tabs: rebuiltTabs,
                selectedTabID: restoredPane.selectedTabID,
                previewTabID: restoredPane.previewTabID
            )
            workspace.panes[pane.id] = pane
        }

        // Ensure layout pane IDs exist.
        for paneID in workspace.layout.allPaneIDs() where workspace.panes[paneID] == nil {
            workspace.panes[paneID] = EditorPane(id: paneID)
        }

        if let active = migrated.activePaneID, workspace.panes[active] != nil {
            workspace.setActivePane(active)
        } else if let first = workspace.layout.allPaneIDs().first {
            workspace.setActivePane(first)
        }
        workspace.focusHistory = migrated.focusHistory.filter { workspace.panes[$0] != nil }
        workspace.navigationHistory.setEntries(migrated.navigation, index: migrated.navigationIndex)
        return workspace
    }
}

public enum WorkspaceError: Error, Sendable, Equatable {
    case paneNotFound
    case tabNotFound
}
