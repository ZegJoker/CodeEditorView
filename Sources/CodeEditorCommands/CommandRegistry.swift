import Foundation

/// Registry of ``EditorCommand`` values. Registration returns a disposable token.
@MainActor
public final class CommandRegistry {
    private struct Entry {
        var command: EditorCommand
        var tokenID: UUID
    }

    private var entries: [CommandID: Entry] = [:]

    public init() {}

    @discardableResult
    public func register(_ command: EditorCommand) -> any CommandDisposable {
        let tokenID = UUID()
        entries[command.id] = Entry(command: command, tokenID: tokenID)
        return RegistrationToken { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if self.entries[command.id]?.tokenID == tokenID {
                    self.entries.removeValue(forKey: command.id)
                }
            }
        }
    }

    public func unregister(id: CommandID) {
        entries.removeValue(forKey: id)
    }

    public func command(id: CommandID) -> EditorCommand? {
        entries[id]?.command
    }

    public func allCommands() -> [EditorCommand] {
        entries.values.map(\.command).sorted { $0.id.rawValue < $1.id.rawValue }
    }

    public func enabledCommands(in context: CommandContext) -> [EditorCommand] {
        let input = context.evaluationInput
        return allCommands().filter {
            ContextExpressionEvaluator.evaluate($0.enablement, in: input)
        }
    }
}
