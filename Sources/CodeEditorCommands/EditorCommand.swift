import CodeEditorCore
import CodeEditorDocuments
import Foundation

/// Restricted editor surface for command handlers (no view controller types).
@MainActor
public protocol EditorCommandClient: AnyObject {
    var isEditable: Bool { get }
    var isFocused: Bool { get }
    var selections: [CodeEditorCore.TextRange] { get }
    var snapshot: DocumentSnapshot { get }
    var documentID: DocumentID? { get }
    var sessionID: EditorSessionID? { get }
    var languageID: String? { get }
    var contextFlags: [String: Bool] { get }

    func perform(_ action: EditorCommandAction) throws
}

/// Built-in editor operations mapped by the View layer onto ``EditorController``.
public enum EditorCommandAction: Sendable, Equatable {
    case undo
    case redo
    case indent
    case outdent
    case toggleLineComment
    case toggleBlockComment
    case moveLines(up: Bool)
    case selectAll
    case deleteBackward
    case deleteForward
    case insertNewline
    case insertTab
    case insertBacktab
    case showFind
    case showReplace
    case findNext
    case findPrevious
    case replaceCurrent
    case replaceAll
    case showCompletions
    case hideCompletions
    case applyCompletion
    case moveCompletion(delta: Int)
    case jumpToDefinition
    case foldToggle
    case foldAll
    case unfoldAll
    case collapseCursors
    case cancel
}

/// Host/extension service bag (type-erased values keyed by string).
/// Prefer ``CommandDependencies`` for new code.
@MainActor
public final class CommandServiceLocator {
    private var storage: [String: Any] = [:]

    public init() {}

    public func set<T>(_ value: T, forKey key: String) {
        storage[key] = value
    }

    public func value<T>(forKey key: String, as type: T.Type = T.self) -> T? {
        storage[key] as? T
    }
}

/// Typed dependency bag for command handlers (additive to string locator).
@MainActor
public final class CommandDependencies {
    public var documentRegistry: DocumentRegistry?
    public var onUndoGroup: (() -> Void)?

    public init(documentRegistry: DocumentRegistry? = nil) {
        self.documentRegistry = documentRegistry
    }
}

/// Outcome of an async command execution.
public enum CommandResult: Sendable, Equatable {
    case success
    case cancelled
    case failed(String)
}

/// Declares how a command may execute (CMD-N05).
///
/// Long-running and asynchronous work must not run through the synchronous
/// MainActor ``CommandDispatcher/execute`` path.
public enum CommandExecutionClass: Sendable, Equatable, Codable, Hashable {
    /// Short MainActor UI mutation; may use the synchronous handler.
    case immediateUI
    /// Must use ``CommandDispatcher/executeAsync`` and an async handler.
    case asynchronous
    /// Workspace-scoped transactional work; async only.
    case transactionalWorkspace
    /// Cancellable long-running work; async only — never block MainActor sync execute.
    case longRunningCancellable

    /// Whether the class may run on the synchronous MainActor execute path.
    public var allowsSynchronousMainActorExecution: Bool {
        switch self {
        case .immediateUI:
            return true
        case .asynchronous, .transactionalWorkspace, .longRunningCancellable:
            return false
        }
    }
}

/// Immutable context passed to command handlers.
@MainActor
public struct CommandContext {
    public let documentID: DocumentID?
    public let sessionID: EditorSessionID?
    public let documentSnapshot: DocumentSnapshot?
    public let selections: [CodeEditorCore.TextRange]
    public let languageID: String?
    public let isEditable: Bool
    public let isFocused: Bool
    public let services: CommandServiceLocator
    public let dependencies: CommandDependencies
    public let editor: any EditorCommandClient

    public init(
        documentID: DocumentID?,
        sessionID: EditorSessionID?,
        documentSnapshot: DocumentSnapshot?,
        selections: [CodeEditorCore.TextRange],
        languageID: String?,
        isEditable: Bool,
        isFocused: Bool,
        services: CommandServiceLocator = CommandServiceLocator(),
        dependencies: CommandDependencies = CommandDependencies(),
        editor: any EditorCommandClient
    ) {
        self.documentID = documentID
        self.sessionID = sessionID
        self.documentSnapshot = documentSnapshot
        self.selections = selections
        self.languageID = languageID
        self.isEditable = isEditable
        self.isFocused = isFocused
        self.services = services
        self.dependencies = dependencies
        self.editor = editor
    }

    public var evaluationInput: ContextEvaluationInput {
        let hasSelection = selections.contains { $0.length > 0 }
        return ContextEvaluationInput(
            isEditable: isEditable,
            isFocused: isFocused,
            hasSelection: hasSelection,
            hasDocument: documentSnapshot != nil,
            languageID: languageID,
            flags: editor.contextFlags
        )
    }

    /// Stable focus-scope identity for chord ownership (CMD-N04).
    public var focusScopeID: String {
        if let sessionID {
            return "session:\(sessionID.rawValue.uuidString)"
        }
        if let documentID {
            return "document:\(documentID.rawValue.uuidString)"
        }
        return "editor:\(ObjectIdentifier(editor))"
    }

    public static func make(
        from editor: any EditorCommandClient,
        services: CommandServiceLocator = CommandServiceLocator(),
        dependencies: CommandDependencies = CommandDependencies()
    ) -> CommandContext {
        CommandContext(
            documentID: editor.documentID,
            sessionID: editor.sessionID,
            documentSnapshot: editor.snapshot,
            selections: editor.selections,
            languageID: editor.languageID,
            isEditable: editor.isEditable,
            isFocused: editor.isFocused,
            services: services,
            dependencies: dependencies,
            editor: editor
        )
    }
}

/// A registered editor command.
@MainActor
public struct EditorCommand {
    public let id: CommandID
    public let title: String
    public let category: CommandCategory?
    public let defaultKeybindings: [Keybinding]
    public let enablement: ContextExpression
    public let placement: CommandPlacement
    /// Execution class — long-running work must not use sync MainActor execute (CMD-N05).
    public let executionClass: CommandExecutionClass
    /// Synchronous MainActor handler (built-ins never suspend).
    public let handler: (CommandContext) throws -> Void
    /// Optional async handler; when set, preferred by ``CommandDispatcher/executeAsync``.
    public let asyncHandler: ((CommandContext) async throws -> CommandResult)?

    public init(
        id: CommandID,
        title: String,
        category: CommandCategory? = nil,
        defaultKeybindings: [Keybinding] = [],
        enablement: ContextExpression = .always,
        placement: CommandPlacement = .default,
        executionClass: CommandExecutionClass = .immediateUI,
        handler: @escaping (CommandContext) throws -> Void
    ) {
        self.id = id
        self.title = title
        self.category = category
        self.defaultKeybindings = defaultKeybindings
        self.enablement = enablement
        self.placement = placement
        self.executionClass = executionClass
        self.handler = handler
        self.asyncHandler = nil
    }

    public init(
        id: CommandID,
        title: String,
        category: CommandCategory? = nil,
        defaultKeybindings: [Keybinding] = [],
        enablement: ContextExpression = .always,
        placement: CommandPlacement = .default,
        executionClass: CommandExecutionClass = .asynchronous,
        asyncHandler: @escaping (CommandContext) async throws -> CommandResult
    ) {
        self.id = id
        self.title = title
        self.category = category
        self.defaultKeybindings = defaultKeybindings
        self.enablement = enablement
        self.placement = placement
        self.executionClass = executionClass
        self.handler = { _ in }
        self.asyncHandler = asyncHandler
    }

    /// Convenience: command that performs a single ``EditorCommandAction``.
    public static func action(
        id: CommandID,
        title: String,
        category: CommandCategory? = nil,
        defaultKeybindings: [Keybinding] = [],
        enablement: ContextExpression = .always,
        placement: CommandPlacement = .default,
        executionClass: CommandExecutionClass = .immediateUI,
        action: EditorCommandAction
    ) -> EditorCommand {
        EditorCommand(
            id: id,
            title: title,
            category: category,
            defaultKeybindings: defaultKeybindings,
            enablement: enablement,
            placement: placement,
            executionClass: executionClass
        ) { context in
            try context.editor.perform(action)
        }
    }
}
