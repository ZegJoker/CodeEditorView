import Foundation

public enum CommandError: Error, Sendable, Equatable {
    case unknownCommand(String)
    case disabled(String)
    case unsupported(String)
    case notFound(String)
}

public extension CommandResult {
    /// Map errors to structured results for palette/menus (audit §9.6 — no silent success).
    static func from(error: CommandError) -> CommandResult {
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
    /// Chord idle timeout in nanoseconds (default 1s).
    public var chordTimeoutNanoseconds: UInt64 = 1_000_000_000

    public init(
        commands: CommandRegistry = CommandRegistry(),
        keybindings: KeybindingRegistry = KeybindingRegistry()
    ) {
        self.commands = commands
        self.keybindings = keybindings
    }

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
    /// ``chordTimeoutNanoseconds``. Escape clears the buffer without executing.
    @discardableResult
    public func handleKeyPress(_ press: KeyPress, context: CommandContext) throws -> Bool {
        let input = context.evaluationInput

        // Escape cancels a pending chord.
        if press.key == "escape", !chordBuffer.isEmpty {
            chordBuffer.removeAll()
            chordResetTask?.cancel()
            return true
        }

        scheduleChordReset()
        chordBuffer.append(press)

        let exactID = keybindings.resolve(presses: chordBuffer, input: input)
        let longerExists = keybindings.hasLongerPrefix(presses: chordBuffer, input: input)

        if let id = exactID, longerExists {
            // Ambiguous: exact match is a prefix of a longer chord — wait.
            return true
        }

        if let id = exactID {
            chordBuffer.removeAll()
            chordResetTask?.cancel()
            try execute(id, context: context)
            return true
        }

        if keybindings.hasPrefix(presses: chordBuffer, input: input) {
            // Wait for more presses in the chord.
            return true
        }

        // No match — if buffer length > 1, try current press alone (after failing longer chord).
        if chordBuffer.count > 1 {
            // If we had a pending exact match for the prefix, execute it first.
            let prefix = Array(chordBuffer.dropLast())
            if let prefixID = keybindings.resolve(presses: prefix, input: input) {
                chordBuffer = [press]
                chordResetTask?.cancel()
                try execute(prefixID, context: context)
                // Then re-process the current press as a fresh sequence.
                return try handleKeyPressAfterPrefixCommit(press, context: context)
            }
            chordBuffer = [press]
            if let id = keybindings.resolve(presses: chordBuffer, input: input) {
                let longer = keybindings.hasLongerPrefix(presses: chordBuffer, input: input)
                if longer {
                    return true
                }
                chordBuffer.removeAll()
                chordResetTask?.cancel()
                try execute(id, context: context)
                return true
            }
            if keybindings.hasPrefix(presses: chordBuffer, input: input) {
                return true
            }
        }

        chordBuffer.removeAll()
        chordResetTask?.cancel()
        return false
    }

    /// After committing a prefix binding, re-evaluate the latest press alone.
    private func handleKeyPressAfterPrefixCommit(_ press: KeyPress, context: CommandContext) throws -> Bool {
        let input = context.evaluationInput
        scheduleChordReset()
        chordBuffer = [press]
        if let id = keybindings.resolve(presses: chordBuffer, input: input) {
            if keybindings.hasLongerPrefix(presses: chordBuffer, input: input) {
                return true
            }
            chordBuffer.removeAll()
            chordResetTask?.cancel()
            try execute(id, context: context)
            return true
        }
        if keybindings.hasPrefix(presses: chordBuffer, input: input) {
            return true
        }
        chordBuffer.removeAll()
        chordResetTask?.cancel()
        return false
    }

    public func resetChordBuffer() {
        chordBuffer.removeAll()
        chordResetTask?.cancel()
    }

    private func scheduleChordReset() {
        chordResetTask?.cancel()
        let timeout = chordTimeoutNanoseconds
        chordResetTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: timeout)
            guard !Task.isCancelled else { return }
            self?.chordBuffer.removeAll()
        }
    }
}
