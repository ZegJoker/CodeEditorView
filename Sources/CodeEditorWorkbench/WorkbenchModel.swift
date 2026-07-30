import Foundation
import Observation
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
    public var utilitySelectedTab: UtilityAreaTab = .output
    public var statusMessage: String = ""

    private var contributionTokens: [any CommandDisposable] = []

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
    }

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
        Task {
            do {
                _ = try await workspace.openInActivePane(uri: uri, preview: preview)
                statusMessage = uri.fileURL?.lastPathComponent ?? uri.rawValue
            } catch {
                statusMessage = "Open failed: \(error.localizedDescription)"
            }
        }
    }

    public var activeDocument: TextDocument? {
        guard let paneID = workspace.activePaneID,
              let tab = workspace.panes[paneID]?.selectedTab
        else { return nil }
        return workspace.documents.document(id: tab.documentID)
    }
}
