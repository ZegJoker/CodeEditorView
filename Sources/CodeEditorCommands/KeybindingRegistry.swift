import Foundation

/// Resolves key presses to command IDs with layered overrides.
@MainActor
public final class KeybindingRegistry {
    private struct BindingEntry {
        var id: UUID
        var keybinding: Keybinding
        var commandID: CommandID
        var source: KeybindingSource
        var priority: Int
    }

    private var bindings: [BindingEntry] = []

    public init() {}

    @discardableResult
    public func bind(
        _ keybinding: Keybinding,
        to command: CommandID,
        source: KeybindingSource,
        priority: Int = 0
    ) -> any CommandDisposable {
        let id = UUID()
        let entry = BindingEntry(
            id: id,
            keybinding: keybinding,
            commandID: command,
            source: source,
            priority: priority
        )
        bindings.append(entry)
        return RegistrationToken { [weak self] in
            Task { @MainActor in
                self?.bindings.removeAll { $0.id == id }
            }
        }
    }

    @discardableResult
    public func applyOverrides(_ overrides: [KeybindingOverride]) -> any CommandDisposable {
        let tokens = overrides.map {
            bind($0.keybinding, to: $0.commandID, source: $0.source, priority: $0.priority)
        }
        return RegistrationToken {
            for token in tokens {
                token.dispose()
            }
        }
    }

    /// Resolves a full chord sequence to a command ID, or `nil` if no match.
    public func resolve(presses: [KeyPress], input: ContextEvaluationInput) -> CommandID? {
        guard !presses.isEmpty else { return nil }

        let candidates = bindings.filter { entry in
            guard entry.keybinding.chord.count == presses.count else { return false }
            guard entry.keybinding.chord == presses else { return false }
            return ContextExpressionEvaluator.evaluate(entry.keybinding.when, in: input)
        }

        return pickWinner(candidates)?.commandID
    }

    /// Whether any binding starts with the given press prefix (for chord continuation).
    public func hasPrefix(presses: [KeyPress], input: ContextEvaluationInput) -> Bool {
        guard !presses.isEmpty else { return false }
        return bindings.contains { entry in
            guard entry.keybinding.chord.count >= presses.count else { return false }
            guard Array(entry.keybinding.chord.prefix(presses.count)) == presses else { return false }
            return ContextExpressionEvaluator.evaluate(entry.keybinding.when, in: input)
        }
    }

    /// Whether any **longer** binding has `presses` as a strict prefix (chord ambiguity).
    public func hasLongerPrefix(presses: [KeyPress], input: ContextEvaluationInput) -> Bool {
        guard !presses.isEmpty else { return false }
        return bindings.contains { entry in
            guard entry.keybinding.chord.count > presses.count else { return false }
            guard Array(entry.keybinding.chord.prefix(presses.count)) == presses else { return false }
            return ContextExpressionEvaluator.evaluate(entry.keybinding.when, in: input)
        }
    }

    public func allBindings() -> [(commandID: CommandID, keybinding: Keybinding, source: KeybindingSource)] {
        bindings.map { ($0.commandID, $0.keybinding, $0.source) }
    }

    /// Deterministic conflict report for a chord under a context input.
    public struct KeybindingConflict: Sendable, Hashable {
        public var chord: [KeyPress]
        public var winnerCommandID: CommandID
        public var shadowedCommandIDs: [CommandID]
    }

    /// Returns chords that have more than one matching binding in `input`.
    public func conflicts(in input: ContextEvaluationInput) -> [KeybindingConflict] {
        var byChord: [[KeyPress]: [BindingEntry]] = [:]
        for entry in bindings {
            guard ContextExpressionEvaluator.evaluate(entry.keybinding.when, in: input) else { continue }
            byChord[entry.keybinding.chord, default: []].append(entry)
        }
        var result: [KeybindingConflict] = []
        for (chord, entries) in byChord where entries.count > 1 {
            guard let winner = pickWinner(entries) else { continue }
            let shadowed =
                entries
                .map(\.commandID)
                .filter { $0 != winner.commandID }
                .sorted { $0.rawValue < $1.rawValue }
            result.append(
                KeybindingConflict(
                    chord: chord,
                    winnerCommandID: winner.commandID,
                    shadowedCommandIDs: shadowed
                ))
        }
        return result.sorted { a, b in
            let aKey = a.chord.map(\.description).joined()
            let bKey = b.chord.map(\.description).joined()
            return aKey < bKey
        }
    }

    private func pickWinner(_ candidates: [BindingEntry]) -> BindingEntry? {
        candidates.max { a, b in
            if a.source != b.source {
                return a.source < b.source
            }
            if a.priority != b.priority {
                return a.priority < b.priority
            }
            // Stable CommandID tie-break (lower string wins for determinism).
            return a.commandID.rawValue > b.commandID.rawValue
        }
    }
}
