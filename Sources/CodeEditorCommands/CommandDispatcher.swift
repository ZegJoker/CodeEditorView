import Foundation

public enum CommandError: Error, Sendable, Equatable {
    case unknownCommand(String)
    case disabled(String)
    case unsupported(String)
    case notFound(String)
    /// Sync execute refused because the command declares a non-immediate execution class (CMD-N05).
    case requiresAsyncExecution(String)
    /// Chord timeout cancelled because focus/scope changed (CMD-N04).
    case chordFocusScopeChanged(String)
}

extension CommandResult {
    /// Map errors to structured results for palette/menus (audit §9.6 — no silent success).
    public static func from(error: CommandError) -> CommandResult {
        switch error {
        case .unknownCommand(let s), .notFound(let s):
            return .failed("notFound:\(s)")
        case .disabled(let s):
            return .failed("disabled:\(s)")
        case .unsupported(let s):
            return .failed("unsupported:\(s)")
        case .requiresAsyncExecution(let s):
            return .failed("requiresAsyncExecution:\(s)")
        case .chordFocusScopeChanged(let s):
            return .failed("chordFocusScopeChanged:\(s)")
        }
    }
}

/// Executes commands and resolves key presses (including multi-step chords).
@MainActor
public final class CommandDispatcher {
    public let commands: CommandRegistry
    public let keybindings: KeybindingRegistry

    /// Partial chord buffer.
    private var chordBuffer: [KeyPress] = []
    private var chordResetTask: Task<Void, Never>?
    /// Exact command pending while waiting for a longer chord (CMD-002).
    private var pendingExactID: CommandID?
    /// Editor client + services captured at chord start for live re-resolution (CMD-N04).
    private var pendingEditor: (any EditorCommandClient)?
    private var pendingServices: CommandServiceLocator?
    private var pendingDependencies: CommandDependencies?
    private var pendingFocusScopeID: String?
    /// Chord idle timeout in nanoseconds (default 1s). On timeout, pending exact binding executes.
    public var chordTimeoutNanoseconds: UInt64 = 1_000_000_000
    /// Optional feedback callback when entering/leaving pending chord state.
    public var onChordStateChange: (([KeyPress]) -> Void)?
    /// Surfaces command failures from chord timeout / non-throwing paths (CMD-N04).
    public var onCommandFailure: ((CommandID, Error) -> Void)?

    public init(
        commands: CommandRegistry = CommandRegistry(),
        keybindings: KeybindingRegistry = KeybindingRegistry()
    ) {
        self.commands = commands
        self.keybindings = keybindings
    }

    /// Whether a multi-key chord is currently pending.
    public var isChordPending: Bool { !chordBuffer.isEmpty }

    /// Current chord prefix buffer (for UI feedback).
    public var currentChordBuffer: [KeyPress] { chordBuffer }

    public func execute(_ id: CommandID, context: CommandContext) throws {
        guard let command = commands.command(id: id) else {
            throw CommandError.notFound(id.rawValue)
        }
        let input = context.evaluationInput
        guard ContextExpressionEvaluator.evaluate(command.enablement, in: input) else {
            throw CommandError.disabled(id.rawValue)
        }
        guard command.executionClass.allowsSynchronousMainActorExecution else {
            throw CommandError.requiresAsyncExecution(id.rawValue)
        }
        try command.handler(context)
    }

    /// Async execution path (preferred for long-running / cancellable commands).
    /// Returns typed results — never silent success for unknown/disabled (CMD-004).
    @discardableResult
    public func executeAsync(_ id: CommandID, context: CommandContext) async throws -> CommandResult {
        guard let command = commands.command(id: id) else {
            return .from(error: .notFound(id.rawValue))
        }
        let input = context.evaluationInput
        guard ContextExpressionEvaluator.evaluate(command.enablement, in: input) else {
            return .from(error: .disabled(id.rawValue))
        }
        try Task.checkCancellation()

        if let asyncHandler = command.asyncHandler {
            return try await asyncHandler(context)
        }

        // Fail closed: non-immediate classes require an async handler (CMD-N05).
        if !command.executionClass.allowsSynchronousMainActorExecution {
            return .failed("requiresAsyncHandler:\(id.rawValue)")
        }

        do {
            try command.handler(context)
            return .success
        } catch let error as CommandError {
            return .from(error: error)
        } catch {
            return .failed(String(describing: error))
        }
    }

    /// Handles a single key press. Returns `true` if a command consumed the event.
    ///
    /// ## Chord state machine (CMD-002 / CMD-N04)
    /// When the current sequence is both an exact binding **and** a strict prefix of a longer
    /// chord (e.g. ⌘K vs ⌘K,⌘C), the dispatcher enters a pending-chord state instead of
    /// executing immediately. Resolution occurs on the next keystroke or after
    /// ``chordTimeoutNanoseconds`` (timeout re-resolves live context and executes the short
    /// binding). Escape clears the buffer without executing.
    @discardableResult
    public func handleKeyPress(_ press: KeyPress, context: CommandContext) throws -> Bool {
        let input = context.evaluationInput

        // Escape cancels a pending chord without executing.
        if press.key == "escape", !chordBuffer.isEmpty {
            clearChordState()
            return true
        }

        scheduleChordReset(context: context)
        chordBuffer.append(press)
        onChordStateChange?(chordBuffer)

        let exactID = keybindings.resolve(presses: chordBuffer, input: input)
        let longerExists = keybindings.hasLongerPrefix(presses: chordBuffer, input: input)

        if let id = exactID, longerExists {
            // Ambiguous: exact match is a prefix of a longer chord — wait.
            capturePending(id: id, context: context)
            return true
        }

        if let id = exactID {
            clearChordState()
            try execute(id, context: context)
            return true
        }

        if keybindings.hasPrefix(presses: chordBuffer, input: input) {
            // Wait for more presses in the chord (no exact match yet).
            capturePending(id: nil, context: context)
            return true
        }

        // No match — if buffer length > 1, try committing pending prefix then reprocess.
        if chordBuffer.count > 1 {
            let prefix = Array(chordBuffer.dropLast())
            if let prefixID = keybindings.resolve(presses: prefix, input: input) {
                clearChordState()
                try execute(prefixID, context: context)
                // Then re-process the current press as a fresh sequence.
                return try handleKeyPressAfterPrefixCommit(press, context: context)
            }
            chordBuffer = [press]
            pendingExactID = nil
            if let id = keybindings.resolve(presses: chordBuffer, input: input) {
                let longer = keybindings.hasLongerPrefix(presses: chordBuffer, input: input)
                if longer {
                    capturePending(id: id, context: context)
                    return true
                }
                clearChordState()
                try execute(id, context: context)
                return true
            }
            if keybindings.hasPrefix(presses: chordBuffer, input: input) {
                capturePending(id: nil, context: context)
                return true
            }
        }

        clearChordState()
        return false
    }

    /// After committing a prefix binding, re-evaluate the latest press alone.
    private func handleKeyPressAfterPrefixCommit(_ press: KeyPress, context: CommandContext) throws -> Bool {
        let input = context.evaluationInput
        scheduleChordReset(context: context)
        chordBuffer = [press]
        onChordStateChange?(chordBuffer)
        if let id = keybindings.resolve(presses: chordBuffer, input: input) {
            if keybindings.hasLongerPrefix(presses: chordBuffer, input: input) {
                capturePending(id: id, context: context)
                return true
            }
            clearChordState()
            try execute(id, context: context)
            return true
        }
        if keybindings.hasPrefix(presses: chordBuffer, input: input) {
            capturePending(id: nil, context: context)
            return true
        }
        clearChordState()
        return false
    }

    public func resetChordBuffer() {
        clearChordState()
    }

    /// Clear pending chord when focus/context changes (CMD-002 / CMD-N04).
    public func clearChordOnContextChange() {
        clearChordState()
    }

    /// Test/host hook: immediately resolve a pending exact chord as if the idle timeout fired.
    ///
    /// Re-resolves live context from the editor client, re-checks focus scope and enablement,
    /// executes through the normal pipeline, and surfaces failures (CMD-N04).
    public func resolvePendingChordTimeout() throws {
        chordResetTask?.cancel()
        chordResetTask = nil
        try finishPendingChordTimeout()
    }

    private func capturePending(id: CommandID?, context: CommandContext) {
        pendingExactID = id
        pendingEditor = context.editor
        pendingServices = context.services
        pendingDependencies = context.dependencies
        pendingFocusScopeID = context.focusScopeID
    }

    private func clearChordState() {
        chordBuffer.removeAll()
        chordResetTask?.cancel()
        chordResetTask = nil
        pendingExactID = nil
        pendingEditor = nil
        pendingServices = nil
        pendingDependencies = nil
        pendingFocusScopeID = nil
        onChordStateChange?([])
    }

    private func scheduleChordReset(context: CommandContext) {
        chordResetTask?.cancel()
        let timeout = chordTimeoutNanoseconds
        // Keep latest editor identity for timeout re-resolution.
        pendingEditor = context.editor
        pendingServices = context.services
        pendingDependencies = context.dependencies
        if pendingFocusScopeID == nil {
            pendingFocusScopeID = context.focusScopeID
        }
        chordResetTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: timeout)
            guard !Task.isCancelled else { return }
            guard let self else { return }
            do {
                try self.finishPendingChordTimeout()
            } catch {
                // Failures already reported via onCommandFailure inside finishPendingChordTimeout.
            }
        }
    }

    /// Shared timeout path for the idle timer and ``resolvePendingChordTimeout``.
    private func finishPendingChordTimeout() throws {
        guard let id = pendingExactID else {
            clearChordState()
            return
        }
        let editor = pendingEditor
        let services = pendingServices
        let dependencies = pendingDependencies
        let expectedScope = pendingFocusScopeID

        // Clear chord UI state before execute to avoid re-entrancy.
        chordBuffer.removeAll()
        chordResetTask?.cancel()
        chordResetTask = nil
        pendingExactID = nil
        pendingEditor = nil
        pendingServices = nil
        pendingDependencies = nil
        pendingFocusScopeID = nil
        onChordStateChange?([])

        guard let editor else {
            return
        }

        let live = CommandContext.make(
            from: editor,
            services: services ?? CommandServiceLocator(),
            dependencies: dependencies ?? CommandDependencies()
        )

        if let expectedScope, live.focusScopeID != expectedScope {
            let error = CommandError.chordFocusScopeChanged(id.rawValue)
            onCommandFailure?(id, error)
            // Cancel without executing — focus/window/workspace no longer owns the chord.
            return
        }

        do {
            try execute(id, context: live)
        } catch {
            onCommandFailure?(id, error)
            throw error
        }
    }
}
