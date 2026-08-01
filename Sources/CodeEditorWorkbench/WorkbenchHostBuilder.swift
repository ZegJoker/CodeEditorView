import CodeEditorCommands
import CodeEditorDocuments
import CodeEditorView
import CodeEditorWorkspace
import Foundation

/// Fluent host configuration builder — hosts need not assemble Workbench internals manually.
@MainActor
public final class WorkbenchHostBuilder {
    private var workspace: Workspace?
    private var configuration: WorkbenchConfiguration = .default
    private var commandDispatcher: CommandDispatcher?
    private var contributions: [any WorkbenchContribution] = []
    private var documentProviders: [any DocumentViewProvider] = []
    private var tooling: [WorkbenchToolingSurface] = []
    private var restoration: WorkbenchRestorationState?
    private var indexService: (any WorkspaceIndexService)?

    public init() {}

    @discardableResult
    public func workspace(_ workspace: Workspace) -> Self {
        self.workspace = workspace
        return self
    }

    @discardableResult
    public func configuration(_ configuration: WorkbenchConfiguration) -> Self {
        self.configuration = configuration
        return self
    }

    @discardableResult
    public func commandDispatcher(_ dispatcher: CommandDispatcher) -> Self {
        self.commandDispatcher = dispatcher
        return self
    }

    @discardableResult
    public func addContribution(_ contribution: any WorkbenchContribution) -> Self {
        contributions.append(contribution)
        return self
    }

    @discardableResult
    public func addDocumentProvider(_ provider: any DocumentViewProvider) -> Self {
        documentProviders.append(provider)
        return self
    }

    @discardableResult
    public func addToolingSurface(_ surface: WorkbenchToolingSurface) -> Self {
        tooling.append(surface)
        return self
    }

    @discardableResult
    public func restoration(_ state: WorkbenchRestorationState) -> Self {
        self.restoration = state
        return self
    }

    @discardableResult
    public func indexService(_ service: any WorkspaceIndexService) -> Self {
        self.indexService = service
        return self
    }

    public func build() throws -> WorkbenchModel {
        guard let workspace else {
            throw WorkbenchHostBuilderError.missingWorkspace
        }
        let model = WorkbenchModel(
            workspace: workspace,
            configuration: configuration,
            commandDispatcher: commandDispatcher
        )
        if let indexService {
            model.openQuickly.indexService = indexService
        }
        for provider in documentProviders {
            model.documentViewRegistry.register(provider)
        }
        // CMD-001: retain registration tokens for host lifetime; discarding them
        // would immediately unregister each contribution via RegistrationToken.deinit.
        for contribution in contributions {
            model.retainContribution(contribution)
        }
        for surface in tooling {
            model.toolingSurfaces.upsert(surface)
        }
        if let restoration {
            model.applyRestoration(restoration)
        }
        return model
    }
}

public enum WorkbenchHostBuilderError: Error, Sendable, Equatable {
    case missingWorkspace
}
