import Foundation
import CoreGraphics
import Observation
import CodeEditorCore
import CodeEditorCommands
import CodeEditorDocuments
import CodeEditorWorkspace
import CodeEditorView

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

    public var isNavigatorVisible: Bool
    public var isInspectorVisible: Bool
    public var isUtilityVisible: Bool
    public var isCommandPalettePresented: Bool = false
    public var isOpenQuicklyPresented: Bool = false
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
        // Breadcrumbs are rendered per-pane in WorkbenchPaneView (not a global accessory).
        // Placeholder utility panes so the debug area looks Xcode-like before hosts wire real UI.
        contributionTokens.append(contributionRegistry.register(UtilityPlaceholderContribution(
            id: "workbench.utility.output",
            title: "Output",
            systemImage: "list.bullet.rectangle",
            priority: 10,
            emptyDescription: "Task and build output appears here."
        )))
        contributionTokens.append(contributionRegistry.register(UtilityPlaceholderContribution(
            id: "workbench.utility.problems",
            title: "Problems",
            systemImage: "exclamationmark.triangle",
            priority: 20,
            emptyDescription: "Diagnostics and problem matchers appear here."
        )))
        contributionTokens.append(contributionRegistry.register(UtilityPlaceholderContribution(
            id: "workbench.utility.terminal",
            title: "Terminal",
            systemImage: "terminal",
            priority: 30,
            emptyDescription: "Host-owned terminal sessions appear here."
        )))

        activeNavigatorID = "workbench.navigator.files"
        activeUtilityID = "workbench.utility.problems"

        // Catalog of editor commands for the palette (executed via active client).
        builtInCommandToken = EditorController.installBuiltInCommandCatalog(into: self.commandDispatcher)
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
        isCommandPalettePresented = true
    }

    public func presentOpenQuickly() {
        isOpenQuicklyPresented = true
        Task { await openQuickly.recompute(workspace: workspace) }
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
