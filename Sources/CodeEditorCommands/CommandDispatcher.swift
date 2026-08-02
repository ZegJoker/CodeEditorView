import Foundation

public enum CommandError: Error, Sendable, Equatable {
    case unknownCommand(String)
    case disabled(String)
    case unsupported(String)
    case notFound(String)
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
    private var pendingContext: CommandContext?
    /// Chord idle timeout in nanoseconds (default 1s). On timeout, pending exact binding executes.
    public var chordTimeoutNanoseconds: UInt64 = 1_000_000_000
    /// Optional feedback callback when entering/leaving pending chord state.
    public var onChordStateChange: (([KeyPress]) -> Void)?

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
    /// ## Chord state machine (CMD-002)
    /// When the current sequence is both an exact binding **and** a strict prefix of a longer
    /// chord (e.g. ⌘K vs ⌘K,⌘C), the dispatcher enters a pending-chord state instead of
    /// executing immediately. Resolution occurs on the next keystroke or after
    /// ``chordTimeoutNanoseconds`` (timeout executes the short binding). Escape clears
    /// the buffer without executing.
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
            pendingExactID = id
            pendingContext = context
            return true
        }

        if let id = exactID {
            clearChordState()
            try execute(id, context: context)
            return true
        }

        if keybindings.hasPrefix(presses: chordBuffer, input: input) {
            // Wait for more presses in the chord (no exact match yet).
            pendingExactID = nil
            pendingContext = context
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
                    pendingExactID = id
                    pendingContext = context
                    return true
                }
                clearChordState()
                try execute(id, context: context)
                return true
            }
            if keybindings.hasPrefix(presses: chordBuffer, input: input) {
                pendingContext = context
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
                pendingExactID = id
                pendingContext = context
                return true
            }
            clearChordState()
            try execute(id, context: context)
            return true
        }
        if keybindings.hasPrefix(presses: chordBuffer, input: input) {
            pendingContext = context
            return true
        }
        clearChordState()
        return false
    }

    public func resetChordBuffer() {
        clearChordState()
    }

    /// Clear pending chord when focus/context changes (CMD-002).
    public func clearChordOnContextChange() {
        clearChordState()
    }

    /// Test/host hook: immediately resolve a pending exact chord as if the idle timeout fired.
    public func resolvePendingChordTimeout() throws {
        chordResetTask?.cancel()
        chordResetTask = nil
        if let id = pendingExactID, let ctx = pendingContext {
            pendingExactID = nil
            pendingContext = nil
            chordBuffer.removeAll()
            onChordStateChange?([])
            try execute(id, context: ctx)
        } else {
            clearChordState()
        }
    }

    private func clearChordState() {
        chordBuffer.removeAll()
        chordResetTask?.cancel()
        chordResetTask = nil
        pendingExactID = nil
        pendingContext = nil
        onChordStateChange?([])
    }

    private func scheduleChordReset(context: CommandContext) {
        chordResetTask?.cancel()
        let timeout = chordTimeoutNanoseconds
        pendingContext = context
        chordResetTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: timeout)
            guard !Task.isCancelled else { return }
            guard let self else { return }
            // Timeout: execute pending exact short binding if present (CMD-002 policy).
            if let id = self.pendingExactID, let ctx = self.pendingContext {
                self.chordBuffer.removeAll()
                self.pendingExactID = nil
                self.pendingContext = nil
                self.chordResetTask = nil
                self.onChordStateChange?([])
                try? self.execute(id, context: ctx)
            } else {
                self.clearChordState()
            }
        }
    }
}
