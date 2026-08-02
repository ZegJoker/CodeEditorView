import CodeEditorCore
import CodeEditorDocuments
import CoreGraphics
import Foundation
import Observation

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
    /// Reference-counted document leases (WSP-006).
    public let documentLeases: DocumentLeaseRegistry

    public private(set) var panes: [EditorPaneID: EditorPane]
    public private(set) var sessions: [EditorSessionID: EditorSession]
    public private(set) var activePaneID: EditorPaneID?
    public private(set) var focusHistory: [EditorPaneID]
    public let navigationHistory: NavigationHistory
    public let settings: WorkspaceSettings
    public var trust: WorkspaceTrustState
    /// Dirty-close policy and host delegate (WSP-001).
    public let closeCoordinator: WorkspaceCloseCoordinator
    /// Bumped on structural UI-affecting changes so SwiftUI hosts can depend on a single token.
    public private(set) var revision: UInt64 = 0

    public init(
        id: WorkspaceID = WorkspaceID(),
        fileSystem: any WorkspaceFileSystem,
        documentProvider: any DocumentContentProvider = LocalFileDocumentProvider(),
        documents: DocumentRegistry = DocumentRegistry(),
        settings: WorkspaceSettings = .default,
        trust: WorkspaceTrustState = .default,
        dirtyTabClosePolicy: DirtyTabClosePolicy = .prompt
    ) {
        self.id = id
        self.fileSystem = fileSystem
        self.fileTree = WorkspaceFileTree(fileSystem: fileSystem)
        self.documentProvider = documentProvider
        self.documents = documents
        self.settings = settings
        self.trust = trust
        self.closeCoordinator = WorkspaceCloseCoordinator(defaultPolicy: dirtyTabClosePolicy)
        self.documentLeases = DocumentLeaseRegistry()
        self.sessions = [:]
        self.navigationHistory = NavigationHistory()
        self.focusHistory = []

        let pane = EditorPane()
        self.panes = [pane.id: pane]
        self.layout = EditorLayoutStore(singlePane: pane.id)
        self.activePaneID = pane.id
        self.focusHistory = [pane.id]

        self.documentLeases.onFinalRelease = { [weak self] documentID in
            self?.documents.remove(id: documentID)
        }
    }

    /// Immutable cross-isolation snapshot of workspace content state.
    public func snapshot() async -> WorkspaceSnapshot {
        var docVersions: [DocumentURI: DocumentVersion] = [:]
        var docIDs: [DocumentID] = []
        for doc in documents.documents {
            docIDs.append(doc.id)
            docVersions[doc.uri] = doc.version
        }
        return WorkspaceSnapshot(
            workspaceID: id,
            revision: revision,
            roots: await fileSystem.roots,
            openDocumentIDs: docIDs,
            documentVersions: docVersions,
            activePaneID: activePaneID,
            trust: trust
        )
    }

    /// Convenience for local disk roots.
    public static func local(
        rootDirectories: [URL],
        settings: WorkspaceSettings = .default
    ) async throws -> Workspace {
        let fs = try await LocalWorkspaceFileSystem(
            rootDirectories: rootDirectories, settings: settings)
        let workspace = Workspace(
            fileSystem: fs, documentProvider: LocalFileDocumentProvider(), settings: settings)
        await workspace.fileTree.refreshRoots()
        return workspace
    }

    // MARK: - Trust

    /// Whether a process-adjacent capability is allowed under current trust.
    public func allows(_ capability: WorkspaceTrustCapability) -> Bool {
        trust.allows(capability)
    }

    // MARK: - Roots

    public func addRoot(directoryURL: URL) async throws -> WorkspaceRoot {
        let root = try await fileSystem.addRoot(directoryURL: directoryURL)
        await fileTree.refreshRoots()
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
    public func openInActivePane(
        uri: DocumentURI, preview: Bool = false
    ) async throws -> (document: TextDocument, session: EditorSession, tab: EditorTab) {
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
            let session = sessions[existingTab.sessionID]
        {
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
        // Lease for the new tab (tab id is stable across preview promotion).
        documentLeases.acquire(documentID: doc.id, owner: .tab(opened.tab.id))
        if let replaced = opened.replacedPreview {
            _ = documentLeases.release(
                documentID: replaced.documentID,
                owner: .tab(replaced.id)
            )
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

    /// Synchronous close used only when the tab's document is clean or still has other leases.
    /// Prefer ``requestCloseTab(_:in:)`` for UI and commands (WSP-001).
    public func closeTab(_ tabID: EditorTabID, in paneID: EditorPaneID) {
        guard let pane = panes[paneID],
            let tab = pane.tabs.first(where: { $0.id == tabID })
        else { return }
        let remainingLeases = documentLeases.count(for: tab.documentID)
        // Estimate after release of this tab's lease.
        let wouldRemain = max(0, remainingLeases - 1)
        if let doc = documents.document(id: tab.documentID), doc.isDirty, wouldRemain <= 0 {
            // Fail closed: never drop the last dirty lease without an async decision.
            return
        }
        forceCloseTab(tabID, in: paneID)
    }

    /// Asynchronous close with save/discard/cancel for dirty documents (WSP-001).
    @discardableResult
    public func requestCloseTab(
        _ tabID: EditorTabID,
        in paneID: EditorPaneID,
        policy: DirtyTabClosePolicy? = nil
    ) async -> CloseTransactionResult {
        guard let pane = panes[paneID],
            let tab = pane.tabs.first(where: { $0.id == tabID })
        else { return .closed }

        let leaseCount = documentLeases.count(for: tab.documentID)
        let remainingAfterRelease = max(0, leaseCount - 1)
        guard remainingAfterRelease <= 0 else {
            // Other leases still hold the document — close view only.
            forceCloseTab(tabID, in: paneID)
            return .closed
        }

        guard let doc = documents.document(id: tab.documentID), doc.isDirty else {
            forceCloseTab(tabID, in: paneID)
            // Final lease release unregisters via onFinalRelease.
            return .closed
        }

        let candidate = CloseCandidate(
            documentID: doc.id,
            uri: doc.uri,
            isDirty: true,
            remainingTabCount: remainingAfterRelease
        )
        let decisions = await closeCoordinator.resolveDecisions(
            candidates: [candidate],
            policy: policy
        )
        let decision = decisions[doc.id] ?? .cancel
        switch decision {
        case .cancel:
            return .cancelled
        case .discard:
            forceCloseTab(tabID, in: paneID)
            return .closed
        case .save:
            do {
                // DOC-N02: all save paths use the conflict-aware DocumentSaveRequest API.
                let outcome = try await documentProvider.save(
                    DocumentSaveRequest(
                        snapshot: doc.snapshot(),
                        target: doc.uri,
                        encoding: doc.encoding,
                        expectedIdentity: doc.fileIdentity,
                        conflictPolicy: .requireHostDecision,
                        durability: .durable
                    )
                )
                switch outcome {
                case .saved(let identity):
                    if let identity {
                        doc.setFileIdentity(identity)
                    }
                    doc.markClean()
                    forceCloseTab(tabID, in: paneID)
                    return .closed
                case .conflict:
                    return .saveFailed(doc.id, "conflict")
                case .cancelled:
                    return .cancelled
                case .unsupportedConflictDetection:
                    return .saveFailed(doc.id, "unsupportedConflictDetection")
                }
            } catch {
                return .saveFailed(doc.id, String(describing: error))
            }
        }
    }

    private func tabCount(for documentID: DocumentID) -> Int {
        panes.values.reduce(0) { partial, pane in
            partial + pane.tabs.filter { $0.documentID == documentID }.count
        }
    }

    private func forceCloseTab(_ tabID: EditorTabID, in paneID: EditorPaneID) {
        guard let pane = panes[paneID],
            let tab = pane.tabs.first(where: { $0.id == tabID })
        else { return }
        if let removed = pane.close(tab: tabID) {
            _ = documentLeases.release(documentID: tab.documentID, owner: .tab(tabID))
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

    /// Synchronous bulk close — only closes clean / multi-lease tabs (WSP-001).
    /// Prefer ``requestCloseOtherTabs(keeping:in:)``.
    public func closeOtherTabs(keeping tabID: EditorTabID, in paneID: EditorPaneID) {
        guard let pane = panes[paneID] else { return }
        let toClose = pane.tabs.map(\.id).filter { $0 != tabID }
        for id in toClose {
            closeTab(id, in: paneID)
        }
    }

    public func requestCloseOtherTabs(
        keeping tabID: EditorTabID, in paneID: EditorPaneID
    ) async -> CloseTransactionResult {
        guard let pane = panes[paneID] else { return .closed }
        let toClose = pane.tabs.map(\.id).filter { $0 != tabID }
        for id in toClose {
            let result = await requestCloseTab(id, in: paneID)
            if result == .cancelled || result != .closed {
                if case .saveFailed = result { return result }
                if result == .cancelled { return .cancelled }
            }
        }
        return .closed
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

    public func requestCloseTabsToTheRight(
        of tabID: EditorTabID, in paneID: EditorPaneID
    ) async -> CloseTransactionResult {
        guard let pane = panes[paneID],
            let idx = pane.tabs.firstIndex(where: { $0.id == tabID })
        else { return .closed }
        let toClose = pane.tabs.suffix(from: idx + 1).map(\.id)
        for id in toClose {
            let result = await requestCloseTab(id, in: paneID)
            if result == .cancelled { return .cancelled }
            if case .saveFailed = result { return result }
        }
        return .closed
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
        guard let active = activePaneID, let source = panes[active] else { return nil }
        let newPane = EditorPane()
        panes[newPane.id] = newPane
        layout.split(pane: active, axis: axis, newPane: newPane.id, fraction: fraction)
        // Clone the active tab into the new pane (Xcode-like), not an empty editor.
        if let tab = source.selectedTab,
            let session = sessions[tab.sessionID],
            let doc = documents.document(id: tab.documentID)
        {
            let cloned = EditorSession(documentID: doc.id)
            cloned.selections = session.selections
            cloned.scrollPosition = session.scrollPosition
            sessions[cloned.id] = cloned
            let opened = newPane.open(
                sessionID: cloned.id,
                documentID: doc.id,
                documentURI: doc.uri,
                preview: false
            )
            documentLeases.acquire(documentID: doc.id, owner: .tab(opened.tab.id))
        }
        setActivePane(newPane.id)
        noteRevision()
        return newPane.id
    }

    /// Deletes a workspace item from disk and updates the file tree.
    public func deleteItem(_ id: WorkspaceItemID) async throws {
        try await fileSystem.delete(item: id)
        fileTree.apply(.removed(id))
        // Close tabs for deleted file if open (async path for dirty).
        if let uri = await fileSystem.uri(for: id) {
            for (paneID, pane) in panes {
                for tab in pane.tabs where tab.documentURI == uri {
                    _ = await requestCloseTab(tab.id, in: paneID, policy: .discard)
                }
            }
        }
        noteRevision()
    }

    /// Renames a workspace item within its parent directory.
    @discardableResult
    public func renameItem(_ id: WorkspaceItemID, to newName: String) async throws -> WorkspaceItem {
        let parent = WorkspaceItemID(rootID: id.rootID, path: id.parentPath ?? "")
        let oldURI = await fileSystem.uri(for: id)
        let moved = try await fileSystem.move(item: id, to: parent, newName: newName)
        fileTree.apply(.renamed(from: id, to: moved))
        // Retarget open documents that pointed at the old URI.
        if let oldURI,
            let doc = documents.document(uri: oldURI)
        {
            doc.setURI(moved.uri)
            documents.reindexURI(for: doc)
            updateTabURIs(documentID: doc.id, uri: moved.uri)
        }
        noteRevision()
        return moved
    }

    /// Moves a tab within a pane (drag-reorder).
    public func moveTab(from: Int, to: Int, in paneID: EditorPaneID) {
        panes[paneID]?.moveTab(from: from, to: to)
        noteRevision()
    }

    /// Updates stored split fractions (user drag or restoration). Bumps ``revision``.
    public func setSplitFractions(_ id: EditorSplitID, fractions: [Double]) {
        layout.setFractions(split: id, fractions: fractions)
        noteRevision()
    }

    /// Synchronous pane close — fails closed if any dirty last-lease tabs remain.
    /// Prefer ``requestClosePane(_:)`` for UI / window teardown (WSP-001 / §10.2).
    public func closePane(_ id: EditorPaneID) {
        guard panes.count > 1 else { return }
        if let pane = panes[id] {
            for tab in pane.tabs {
                closeTab(tab.id, in: id)
            }
            // If dirty tabs remain, refuse to remove the pane.
            if !pane.tabs.isEmpty { return }
        }
        removeEmptyPane(id)
    }

    /// Asynchronous pane close through the close coordinator (WSP-001).
    @discardableResult
    public func requestClosePane(
        _ id: EditorPaneID,
        policy: DirtyTabClosePolicy? = nil
    ) async -> CloseTransactionResult {
        guard panes.count > 1 else { return .closed }
        guard let pane = panes[id] else { return .closed }
        let tabIDs = pane.tabs.map(\.id)
        for tabID in tabIDs {
            let result = await requestCloseTab(tabID, in: id, policy: policy)
            if result == .cancelled { return .cancelled }
            if case .saveFailed = result { return result }
        }
        // Only remove pane if all tabs closed.
        if let pane = panes[id], !pane.tabs.isEmpty {
            return .cancelled
        }
        removeEmptyPane(id)
        return .closed
    }

    /// Close every dirty document across all panes (window close / workspace replace).
    @discardableResult
    public func requestCloseAllTabs(
        policy: DirtyTabClosePolicy? = nil
    ) async -> CloseTransactionResult {
        for (paneID, pane) in panes {
            for tab in pane.tabs {
                let result = await requestCloseTab(tab.id, in: paneID, policy: policy)
                if result == .cancelled { return .cancelled }
                if case .saveFailed = result { return result }
            }
        }
        return .closed
    }

    private func removeEmptyPane(_ id: EditorPaneID) {
        panes[id] = nil
        layout.close(pane: id)
        focusHistory.removeAll { $0 == id }
        if activePaneID == id {
            activePaneID = layout.allPaneIDs().first ?? panes.keys.first
            if let activePaneID {
                setActivePane(activePaneID)
            }
        }
        for paneID in layout.allPaneIDs() where panes[paneID] == nil {
            panes[paneID] = EditorPane(id: paneID)
        }
        noteRevision()
    }

    /// Create a file under `parent` (empty path = workspace root item).
    @discardableResult
    public func createFile(
        in parent: WorkspaceItemID, name: String, contents: Data = Data()
    ) async throws -> WorkspaceItem {
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
            roots: [],  // filled by async capture when needed
            layout: layout.root,
            panes: restoredPanes,
            activePaneID: activePaneID,
            focusHistory: focusHistory,
            navigation: navigationHistory.entries(),
            navigationIndex: navigationHistory.entries().isEmpty ? -1 : navigationHistory.entries().count - 1
        )
    }

    /// Capture restoration state including live filesystem roots.
    public func captureRestorationStateAsync() async -> WorkspaceRestorationState {
        var state = captureRestorationState()
        state.roots = await fileSystem.roots
        return state
    }

    public static func restore(
        from state: WorkspaceRestorationState,
        fileSystem: any WorkspaceFileSystem,
        documentProvider: any DocumentContentProvider = LocalFileDocumentProvider()
    ) async throws -> Workspace {
        let migrated = try WorkspaceRestoration.migrate(state)
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
                let rebuilt = EditorTab(
                    id: tab.id,
                    sessionID: session.id,
                    documentID: doc.id,
                    documentURI: tab.documentURI,
                    isPreview: tab.isPreview,
                    isPinned: tab.isPinned
                )
                rebuiltTabs.append(rebuilt)
                workspace.documentLeases.acquire(documentID: doc.id, owner: .tab(tab.id))
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
