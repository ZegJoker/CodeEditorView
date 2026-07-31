import Foundation

public enum CommandError: Error, Sendable, Equatable {
    case unknownCommand(String)
    case disabled(String)
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
            throw CommandError.unknownCommand(id.rawValue)
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
            throw CommandError.unknownCommand(id.rawValue)
        }
        let input = context.evaluationInput
        guard ContextExpressionEvaluator.evaluate(command.enablement, in: input) else {
            throw CommandError.disabled(id.rawValue)
        }
        try Task.checkCancellation()
        if let asyncHandler = command.asyncHandler {
            return try await asyncHandler(context)
        }
        try command.handler(context)
        return .success
    }

    /// Handles a single key press. Returns `true` if a command consumed the event.
    @discardableResult
    public func handleKeyPress(_ press: KeyPress, context: CommandContext) throws -> Bool {
        let input = context.evaluationInput
        scheduleChordReset()

        chordBuffer.append(press)

        if let id = keybindings.resolve(presses: chordBuffer, input: input) {
            chordBuffer.removeAll()
            chordResetTask?.cancel()
            try execute(id, context: context)
            return true
        }

        if keybindings.hasPrefix(presses: chordBuffer, input: input) {
            // Wait for more presses in the chord.
            return true
        }

        // No match — if buffer length > 1, try current press alone.
        if chordBuffer.count > 1 {
            chordBuffer = [press]
            if let id = keybindings.resolve(presses: chordBuffer, input: input) {
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
