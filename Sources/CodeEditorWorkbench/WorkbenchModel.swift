import Foundation
import CoreGraphics
import Observation
import CodeEditorCore
import CodeEditorCommands
import CodeEditorDocuments
import CodeEditorWorkspace
import CodeEditorView

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
#endif

@MainActor
@Observable
public final class WorkbenchModel {
    public let workspace: Workspace
    public var commandDispatcher: CommandDispatcher
    public var configuration: WorkbenchConfiguration
    public let documentViewRegistry: DocumentViewRegistry
    public let contributionRegistry: WorkbenchContributionRegistry
    public let editorClientRegistry: WorkbenchEditorClientRegistry
    public let openQuickly: OpenQuicklyModel
    public let commandPalette: CommandPaletteModel
    public let windowRegistry: WorkbenchWindowRegistry
    public let toolingSurfaces: WorkbenchToolingSurfaceRegistry

    /// Explicit lifecycle phase for the primary session owner.
    public private(set) var lifecyclePhase: WorkbenchLifecyclePhase = .creating
    /// Keyboard / command focus target.
    public var focusedTarget: WorkbenchFocusTarget = .editor

    public var isNavigatorVisible: Bool
    public var isInspectorVisible: Bool
    public var isUtilityVisible: Bool
    public var isCommandPalettePresented: Bool = false {
        didSet {
            if isCommandPalettePresented {
                focusedTarget = .commandPalette
            } else if focusedTarget == .commandPalette {
                focusedTarget = .editor
            }
        }
    }
    public var isOpenQuicklyPresented: Bool = false {
        didSet {
            if isOpenQuicklyPresented {
                focusedTarget = .openQuickly
            } else if focusedTarget == .openQuickly {
                focusedTarget = .editor
            }
        }
    }
    /// Selected utility contribution id (filters utility body).
    public var activeUtilityID: String?
    /// Selected navigator contribution id (multi-mode project / find / scm).
    public var activeNavigatorID: String?
    /// Resizable utility area height.
    public var utilityHeight: CGFloat
    public var statusMessage: String = ""
    /// Selected navigator item (file or folder). Used for New File / New Folder targets.
    public var selectedNavigatorItem: WorkspaceItemID?
    /// Alert text when file-tree mutations fail.
    public var navigatorError: String?
    /// Dismissed tooling surface banners.
    public var dismissedToolingBannerIDs: Set<String> = []

    /// Legacy alias used by older hosts; maps to contribution id when possible.
    public var utilitySelectedTab: UtilityAreaTab {
        get {
            switch activeUtilityID {
            case "workbench.utility.problems": return .problems
            case "workbench.utility.terminal": return .terminal
            default: return .output
            }
        }
        set {
            switch newValue {
            case .problems: activeUtilityID = "workbench.utility.problems"
            case .terminal: activeUtilityID = "workbench.utility.terminal"
            case .output: activeUtilityID = "workbench.utility.output"
            }
        }
    }

    private var contributionTokens: [any CommandDisposable] = []
    private var builtInCommandToken: (any CommandDisposable)?
    /// Serializes async opens so the latest request wins (avoids selection lag races).
    private var openGeneration: UInt64 = 0

    /// Registers a contribution and retains its token for the workbench lifetime (CMD-001).
    @discardableResult
    public func retainContribution(_ contribution: any WorkbenchContribution) -> any CommandDisposable {
        let token = contributionRegistry.register(contribution)
        contributionTokens.append(token)
        return token
    }

    public init(
        workspace: Workspace,
        configuration: WorkbenchConfiguration = .default,
        commandDispatcher: CommandDispatcher? = nil
    ) {
        self.workspace = workspace
        self.configuration = configuration
        self.commandDispatcher = commandDispatcher ?? CommandDispatcher()
        self.documentViewRegistry = DocumentViewRegistry()
        self.contributionRegistry = WorkbenchContributionRegistry()
        self.editorClientRegistry = WorkbenchEditorClientRegistry()
        self.openQuickly = OpenQuicklyModel()
        self.commandPalette = CommandPaletteModel()
        self.windowRegistry = WorkbenchWindowRegistry()
        self.toolingSurfaces = WorkbenchToolingSurfaceRegistry()
        self.isNavigatorVisible = configuration.showsNavigator
        self.isInspectorVisible = configuration.showsInspector
        self.isUtilityVisible = configuration.showsUtilityArea
        self.utilityHeight = configuration.utilityAreaHeight

        // Default document providers
        documentViewRegistry.register(PDFDocumentViewProvider())
        documentViewRegistry.register(ImageDocumentViewProvider())
        documentViewRegistry.register(TextDocumentViewProvider())

        // Built-in contributions
        contributionTokens.append(
            contributionRegistry.register(FileTreeNavigatorContribution())
        )
        contributionTokens.append(
            contributionRegistry.register(StatusBarContribution())
        )
        // Real utility panels (WB-001) — not ContentUnavailable placeholders.
        contributionTokens.append(
            contributionRegistry.register(WorkbenchOutputPanelContribution())
        )
        contributionTokens.append(
            contributionRegistry.register(WorkbenchProblemsPanelContribution())
        )
        contributionTokens.append(
            contributionRegistry.register(WorkbenchTerminalPanelContribution())
        )

        activeNavigatorID = "workbench.navigator.files"
        activeUtilityID = "workbench.utility.problems"

        // Primary window for multi-window hosts.
        _ = windowRegistry.create(
            title: "Main",
            from: captureWindowState(title: "Main")
        )

        // Catalog of editor commands for the palette (executed via active client).
        builtInCommandToken = EditorController.installBuiltInCommandCatalog(into: self.commandDispatcher)
        lifecyclePhase = .active
    }

    // MARK: - Lifecycle

    public func enterBackground() {
        guard lifecyclePhase == .active else { return }
        lifecyclePhase = .background
    }

    public func enterForeground() {
        if lifecyclePhase == .background || lifecyclePhase == .restoring {
            lifecyclePhase = .active
        }
    }

    public func beginTearDown() {
        lifecyclePhase = .tearingDown
        for token in contributionTokens { token.dispose() }
        contributionTokens.removeAll()
        builtInCommandToken?.dispose()
        builtInCommandToken = nil
    }

    // MARK: - Focus

    public func focus(_ target: WorkbenchFocusTarget) {
        focusedTarget = target
        switch target {
        case .navigator:
            if !isNavigatorVisible { isNavigatorVisible = true }
        case .inspector:
            if !isInspectorVisible { isInspectorVisible = true }
        case .utility:
            if !isUtilityVisible { isUtilityVisible = true }
        case .commandPalette:
            isCommandPalettePresented = true
        case .openQuickly:
            presentOpenQuickly()
        case .editor, .toolbar:
            break
        }
        syncFocusedWindowChrome()
    }

    public func cycleFocusForward() {
        let order: [WorkbenchFocusTarget] = [.navigator, .editor, .inspector, .utility]
        let idx = order.firstIndex(of: focusedTarget) ?? 0
        focus(order[(idx + 1) % order.count])
    }

    /// Whether a command should be enabled given current focus/selection.
    public func isCommandEnabled(_ id: CommandID) -> Bool {
        let raw = id.rawValue
        if raw.hasPrefix("codeeditor.edit.") || raw.hasPrefix("editor.") {
            return makeCommandContext() != nil && focusedTarget == .editor
        }
        if raw.contains("openQuickly") || raw.contains("open.quickly") {
            return lifecyclePhase == .active
        }
        if raw.contains("palette") {
            return lifecyclePhase == .active
        }
        return lifecyclePhase == .active || lifecyclePhase == .background
    }

    public func validatedPaletteCommands() -> [EditorCommand] {
        commandDispatcher.commands.allCommands().filter { isCommandEnabled($0.id) }
    }

    // MARK: - Contribution selection

    public func selectNavigator(id: String) {
        activeNavigatorID = id
        if !isNavigatorVisible {
            withAnimationIfAvailable {
                isNavigatorVisible = true
            }
        }
    }

    public func selectUtility(id: String) {
        activeUtilityID = id
        if !isUtilityVisible {
            withAnimationIfAvailable {
                isUtilityVisible = true
            }
        }
    }

    public func ensureActiveNavigator() {
        let navs = contributionRegistry.contributions(for: .navigator)
        if activeNavigatorID == nil || contributionRegistry.contribution(id: activeNavigatorID ?? "") == nil {
            activeNavigatorID = navs.first?.id
        }
    }

    public func ensureActiveUtility() {
        let utils = contributionRegistry.contributions(for: .utility)
        if activeUtilityID == nil || contributionRegistry.contribution(id: activeUtilityID ?? "") == nil {
            activeUtilityID = utils.first?.id
        }
    }

    // MARK: - Navigation history

    public var canNavigateBack: Bool { workspace.navigationHistory.canGoBack }
    public var canNavigateForward: Bool { workspace.navigationHistory.canGoForward }

    public func navigateBack() {
        guard let entry = workspace.navigateBack() else { return }
        openURI(entry.documentURI, preview: false)
    }

    public func navigateForward() {
        guard let entry = workspace.navigateForward() else { return }
        openURI(entry.documentURI, preview: false)
    }

    // MARK: - Commands / open

    public func makeCommandContext() -> CommandContext? {
        guard let client = editorClientRegistry.activeClient(workspace: workspace) else {
            return nil
        }
        return CommandContext.make(from: client)
    }

    public func presentCommandPalette() {
        focus(.commandPalette)
        isCommandPalettePresented = true
    }

    public func presentOpenQuickly() {
        openQuickly.resetPresentation()
        isOpenQuicklyPresented = true
        focusedTarget = .openQuickly
        Task { await openQuickly.recompute(workspace: workspace) }
    }

    // MARK: - Multi-window

    @discardableResult
    public func createWindow(title: String = "Workbench") -> WorkbenchWindowState {
        windowRegistry.create(title: title, from: captureWindowState(title: title))
    }

    public func focusWindow(_ id: WorkbenchWindowID) {
        windowRegistry.focus(id)
        if let state = windowRegistry.windows[id] {
            applyWindowState(state)
        }
    }

    public func closeWindow(_ id: WorkbenchWindowID) {
        windowRegistry.close(id)
        if let focused = windowRegistry.focused() {
            applyWindowState(focused)
        }
    }

    public func captureWindowState(title: String = "Workbench") -> WorkbenchWindowState {
        WorkbenchWindowState(
            title: title,
            isNavigatorVisible: isNavigatorVisible,
            isInspectorVisible: isInspectorVisible,
            isUtilityVisible: isUtilityVisible,
            activeNavigatorID: activeNavigatorID,
            activeUtilityID: activeUtilityID,
            utilityHeight: Double(utilityHeight),
            focusedTarget: focusedTarget,
            statusMessage: statusMessage
        )
    }

    public func applyWindowState(_ state: WorkbenchWindowState) {
        isNavigatorVisible = state.isNavigatorVisible
        isInspectorVisible = state.isInspectorVisible
        isUtilityVisible = state.isUtilityVisible
        activeNavigatorID = state.activeNavigatorID
        activeUtilityID = state.activeUtilityID
        utilityHeight = CGFloat(state.utilityHeight)
        focusedTarget = state.focusedTarget
        statusMessage = state.statusMessage
    }

    private func syncFocusedWindowChrome() {
        guard var state = windowRegistry.focused() else { return }
        state.isNavigatorVisible = isNavigatorVisible
        state.isInspectorVisible = isInspectorVisible
        state.isUtilityVisible = isUtilityVisible
        state.activeNavigatorID = activeNavigatorID
        state.activeUtilityID = activeUtilityID
        state.utilityHeight = Double(utilityHeight)
        state.focusedTarget = focusedTarget
        state.statusMessage = statusMessage
        windowRegistry.update(state)
    }

    // MARK: - Restoration

    public func captureRestorationState() -> WorkbenchRestorationState {
        syncFocusedWindowChrome()
        let (windows, focused) = windowRegistry.capture()
        return WorkbenchRestorationState(
            lifecyclePhase: lifecyclePhase == .tearingDown ? .active : lifecyclePhase,
            windows: windows.isEmpty ? [captureWindowState()] : windows,
            focusedWindowID: focused,
            workspace: workspace.captureRestorationState(),
            registeredContributionIDs: contributionRegistry.allDescriptors().map(\.id),
            toolingSurfaces: toolingSurfaces.snapshots()
        )
    }

    public func encodeRestoration() throws -> Data {
        try WorkbenchRestoration.encode(captureRestorationState())
    }

    public func applyRestoration(_ state: WorkbenchRestorationState) {
        lifecyclePhase = .restoring
        let migrated = WorkbenchRestoration.migrate(state)
        windowRegistry.applyRestoration(migrated)
        if let focused = windowRegistry.focused() {
            applyWindowState(focused)
        }
        toolingSurfaces.apply(snapshots: migrated.toolingSurfaces)
        lifecyclePhase = .active
    }

    // MARK: - Tooling surfaces

    public func visibleToolingFailures() -> [WorkbenchToolingSurface] {
        toolingSurfaces.failed().filter { !dismissedToolingBannerIDs.contains($0.id) }
    }

    public func dismissToolingBanner(id: String) {
        dismissedToolingBannerIDs.insert(id)
    }

    public func retryTooling(id: String) {
        toolingSurfaces.retry(id: id)
    }

    public func openURI(_ uri: DocumentURI, preview: Bool = true) {
        openURI(uri, preview: preview, selection: nil)
    }

    /// Opens a URI and optionally selects a range (e.g. Find in Files jump).
    public func openURI(
        _ uri: DocumentURI,
        preview: Bool = true,
        selection: CodeEditorCore.TextRange?
    ) {
        openGeneration &+= 1
        let generation = openGeneration
        Task {
            do {
                let opened = try await workspace.openInActivePane(uri: uri, preview: preview)
                if let selection {
                    opened.session.selections = [selection]
                    // Hint scroll toward the match (points are approximate until layout).
                    opened.session.scrollPosition = CGPoint(x: 0, y: Double(max(selection.location / 40, 0)))
                }
                guard generation == openGeneration else { return }
                statusMessage = uri.fileURL?.lastPathComponent ?? uri.rawValue
            } catch {
                guard generation == openGeneration else { return }
                statusMessage = "Open failed: \(error.localizedDescription)"
            }
        }
    }

    public func createFile(named name: String, in parent: WorkspaceItemID? = nil, open: Bool = true) {
        Task {
            do {
                let parentID = try await resolveCreateParent(parent)
                let item = try await workspace.createFile(in: parentID, name: name)
                selectedNavigatorItem = item.id
                if open {
                    openURI(item.uri, preview: false)
                }
                statusMessage = "Created \(name)"
            } catch {
                navigatorError = error.localizedDescription
                statusMessage = "Create file failed: \(error.localizedDescription)"
            }
        }
    }

    public func createFolder(named name: String, in parent: WorkspaceItemID? = nil) {
        Task {
            do {
                let parentID = try await resolveCreateParent(parent)
                let item = try await workspace.createDirectory(in: parentID, name: name)
                selectedNavigatorItem = item.id
                statusMessage = "Created folder \(name)"
            } catch {
                navigatorError = error.localizedDescription
                statusMessage = "Create folder failed: \(error.localizedDescription)"
            }
        }
    }

    public func renameItem(_ id: WorkspaceItemID, to newName: String) {
        Task {
            do {
                let item = try await workspace.renameItem(id, to: newName)
                selectedNavigatorItem = item.id
                statusMessage = "Renamed to \(item.name)"
            } catch {
                navigatorError = error.localizedDescription
                statusMessage = "Rename failed: \(error.localizedDescription)"
            }
        }
    }

    public func deleteItem(_ id: WorkspaceItemID) {
        Task {
            do {
                try await workspace.deleteItem(id)
                if selectedNavigatorItem == id {
                    selectedNavigatorItem = nil
                }
                statusMessage = "Deleted"
            } catch {
                navigatorError = error.localizedDescription
                statusMessage = "Delete failed: \(error.localizedDescription)"
            }
        }
    }

    public func revealInFinder(_ id: WorkspaceItemID) {
        guard let uri = workspace.fileSystem.uri(for: id),
              let url = uri.fileURL
        else {
            navigatorError = "Cannot reveal item"
            return
        }
        #if os(macOS)
        NSWorkspace.shared.activateFileViewerSelecting([url])
        #endif
    }

    private func resolveCreateParent(_ parent: WorkspaceItemID?) async throws -> WorkspaceItemID {
        if let parent {
            return try await directoryParent(for: parent)
        }
        if let selected = selectedNavigatorItem {
            return try await directoryParent(for: selected)
        }
        if let root = workspace.fileTree.roots.first {
            return WorkspaceItemID(rootID: root.id, path: "")
        }
        throw WorkspaceFileSystemError.rootNotFound
    }

    private func directoryParent(for item: WorkspaceItemID) async throws -> WorkspaceItemID {
        if item.path.isEmpty {
            return item
        }
        if let uri = workspace.fileSystem.uri(for: item),
           let meta = workspace.fileSystem.item(for: uri) {
            return meta.isDirectory
                ? item
                : WorkspaceItemID(rootID: item.rootID, path: item.parentPath ?? "")
        }
        if !item.name.isEmpty, !(item.name as NSString).pathExtension.isEmpty {
            return WorkspaceItemID(rootID: item.rootID, path: item.parentPath ?? "")
        }
        return item
    }

    public var activeDocument: TextDocument? {
        _ = workspace.revision
        guard let paneID = workspace.activePaneID,
              let tab = workspace.panes[paneID]?.selectedTab
        else { return nil }
        return workspace.documents.document(id: tab.documentID)
    }

    public var activeSession: EditorSession? {
        _ = workspace.revision
        guard let paneID = workspace.activePaneID,
              let tab = workspace.panes[paneID]?.selectedTab
        else { return nil }
        return workspace.sessions[tab.sessionID]
    }

    private func withAnimationIfAvailable(_ body: () -> Void) {
        body()
    }
}
