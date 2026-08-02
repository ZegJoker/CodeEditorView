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
        let candidates = registry.allCommands().filter { command in
            guard !command.placement.paletteHidden else { return false }
            return ContextExpressionEvaluator.evaluate(command.enablement, in: input)
        }
        if q.isEmpty {
            return candidates.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        }
        return
            candidates
            .compactMap { command -> (EditorCommand, Int)? in
                let score = rank(command: command, query: q)
                return score >= 0 ? (command, score) : nil
            }
            .sorted { a, b in
                if a.1 != b.1 { return a.1 > b.1 }
                return a.0.title.localizedCaseInsensitiveCompare(b.0.title) == .orderedAscending
            }
            .map(\.0)
    }

    /// Higher is better; -1 means no match.
    private func rank(command: EditorCommand, query: String) -> Int {
        let title = command.title.lowercased()
        let id = command.id.rawValue.lowercased()
        if title == query { return 100 }
        if title.hasPrefix(query) { return 80 }
        if id.hasPrefix(query) { return 70 }
        if title.contains(query) { return 50 }
        if id.contains(query) { return 40 }
        if let category = command.category?.rawValue.lowercased(), category.contains(query) {
            return 20
        }
        // crude fuzzy: all query chars in order
        if fuzzyMatch(query, in: title) { return 10 }
        return -1
    }

    private func fuzzyMatch(_ query: String, in text: String) -> Bool {
        var ti = text.startIndex
        for qc in query {
            var found = false
            while ti < text.endIndex {
                if text[ti] == qc {
                    ti = text.index(after: ti)
                    found = true
                    break
                }
                ti = text.index(after: ti)
            }
            if !found { return false }
        }
        return true
    }
}
