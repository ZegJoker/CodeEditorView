import Foundation
import CodeEditorExtensionAPI

/// Runtime context passed to ``CodeEditorExtension/activate(in:)``.
public final class ExtensionContext: ExtensionAuthorContext, @unchecked Sendable {
    public let extensionID: ExtensionID
    public let grantedPermissions: Set<ExtensionPermission>
    public let log: ExtensionLog

    public private(set) var commands: CommandContributionRegistrar?
    public private(set) var keybindings: KeybindingContributionRegistrar?
    public private(set) var languages: LanguageContributionRegistrar?
    public private(set) var languageServices: LanguageServiceContributionRegistrar?
    public private(set) var panels: PanelContributionRegistrar?
    public private(set) var themes: ThemeContributionRegistrar?
    public private(set) var snippets: SnippetContributionRegistrar?
    public private(set) var iconThemes: IconThemeContributionRegistrar?
    public private(set) var storage: ExtensionStorage?

    private let lock = NSLock()
    private var disposables: [any ExtensionDisposable] = []
    private var tasks: [Task<Void, Never>] = []

    public init(
        extensionID: ExtensionID,
        grantedPermissions: Set<ExtensionPermission>,
        log: ExtensionLog
    ) {
        self.extensionID = extensionID
        self.grantedPermissions = grantedPermissions
        self.log = log
    }

    // MARK: - Wiring (runtime)

    public func install(commands: CommandContributionRegistrar?) {
        self.commands = commands
    }

    public func install(keybindings: KeybindingContributionRegistrar?) {
        self.keybindings = keybindings
    }

    public func install(languages: LanguageContributionRegistrar?) {
        self.languages = languages
    }

    public func install(languageServices: LanguageServiceContributionRegistrar?) {
        self.languageServices = languageServices
    }

    public func install(panels: PanelContributionRegistrar?) {
        self.panels = panels
    }

    public func install(themes: ThemeContributionRegistrar?) {
        self.themes = themes
    }

    public func install(snippets: SnippetContributionRegistrar?) {
        self.snippets = snippets
    }

    public func install(iconThemes: IconThemeContributionRegistrar?) {
        self.iconThemes = iconThemes
    }

    public func install(storage: ExtensionStorage?) {
        self.storage = storage
    }

    // MARK: - Permissions / tracking

    public func requirePermission(_ permission: ExtensionPermission) throws {
        guard grantedPermissions.contains(permission) else {
            throw ExtensionError.permissionDenied(permission)
        }
    }

    public func hasPermission(_ permission: ExtensionPermission) -> Bool {
        grantedPermissions.contains(permission)
    }

    public func track(_ disposable: any ExtensionDisposable) {
        lock.lock()
        disposables.append(disposable)
        lock.unlock()
    }

    public func addTask(_ task: Task<Void, Never>) {
        lock.lock()
        tasks.append(task)
        lock.unlock()
    }

    public func info(_ message: String) {
        log.append(extensionID: extensionID, level: .info, message: message)
    }

    public func warning(_ message: String) {
        log.append(extensionID: extensionID, level: .warning, message: message)
    }

    public func error(_ message: String) {
        log.append(extensionID: extensionID, level: .error, message: message)
    }

    /// Cancel tasks and dispose contributions (LIFO). Called by the runtime on deactivate/failure.
    public func teardown() {
        lock.lock()
        let taskList = tasks
        tasks.removeAll()
        let tokens = disposables
        disposables.removeAll()
        lock.unlock()

        for task in taskList {
            task.cancel()
        }
        for token in tokens.reversed() {
            token.dispose()
        }
    }
}

