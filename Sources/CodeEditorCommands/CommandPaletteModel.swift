import Foundation
import Observation

/// Filters registered commands for a command-palette UI.
@MainActor
@Observable
public final class CommandPaletteModel {
    public var query: String = ""

    public init(query: String = "") {
        self.query = query
    }

    public func filteredCommands(
        from registry: CommandRegistry,
        context: CommandContext
    ) -> [EditorCommand] {
        let input = context.evaluationInput
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return registry.allCommands().filter { command in
            guard !command.placement.paletteHidden else { return false }
            guard ContextExpressionEvaluator.evaluate(command.enablement, in: input) else {
                return false
            }
            if q.isEmpty { return true }
            if command.title.lowercased().contains(q) { return true }
            if command.id.rawValue.lowercased().contains(q) { return true }
            if let category = command.category?.rawValue.lowercased(), category.contains(q) {
                return true
            }
            return false
        }
    }
}
