import Foundation

/// Registry of ``EditorCommand`` values. Registration returns a disposable token.
@MainActor
public final class CommandRegistry {
    private struct Entry {
        var command: EditorCommand
        var tokenID: CommandRegistrationToken.ID
    }

    private var entries: [CommandID: Entry] = [:]

    /// Optional diagnostic sink for replace/reject events (CMD-N01).
    public var onRegistrationDiagnostic: ((CommandRegistrationDiagnostic) -> Void)?

    public init() {}

    /// Registers a command under the given policy (default: ``CommandRegistrationPolicy/rejectDuplicate``).
    @discardableResult
    public func register(
        _ command: EditorCommand,
        policy: CommandRegistrationPolicy = .rejectDuplicate
    ) throws -> CommandRegistrationToken {
        guard CommandID.isValid(command.id.rawValue) else {
            throw CommandIdentityError.invalidID(command.id.rawValue)
        }

        if let existing = entries[command.id] {
            switch policy {
            case .rejectDuplicate:
                onRegistrationDiagnostic?(.rejectedDuplicate(commandID: command.id))
                throw CommandIdentityError.duplicateRegistration(command.id.rawValue)
            case .replaceOwnedRegistration(let expected):
                guard existing.tokenID == expected else {
                    onRegistrationDiagnostic?(
                        .ownershipMismatch(
                            commandID: command.id,
                            expected: expected,
                            actual: existing.tokenID
                        )
                    )
                    throw CommandIdentityError.ownershipMismatch(command.id.rawValue)
                }
                onRegistrationDiagnostic?(
                    .replacedOwnedRegistration(commandID: command.id, previousToken: existing.tokenID)
                )
            }
        }

        let tokenID = UUID()
        entries[command.id] = Entry(command: command, tokenID: tokenID)
        return CommandRegistrationToken(id: tokenID) { [weak self] in
            guard let self else { return }
            if self.entries[command.id]?.tokenID == tokenID {
                self.entries.removeValue(forKey: command.id)
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
