import Foundation

/// Thresholds that activate explicit large-file behavior (UI-N09).
public struct LargeFilePolicy: Sendable, Equatable {
    /// UTF-16 unit count that forces large-file mode.
    public var byteThreshold: Int
    /// Line count that forces large-file mode.
    public var lineThreshold: Int
    /// Max undo groups retained while in large-file mode.
    public var maxUndoGroups: Int

    public init(byteThreshold: Int = 2_000_000, lineThreshold: Int = 50_000, maxUndoGroups: Int = 64) {
        self.byteThreshold = max(1, byteThreshold)
        self.lineThreshold = max(1, lineThreshold)
        self.maxUndoGroups = max(1, maxUndoGroups)
    }

    public static let `default` = LargeFilePolicy()
}

/// Explicit large-file mode — never silent degradation (UI-N09).
public struct LargeFileMode: Sendable, Equatable {
    public var isActive: Bool
    public var syntaxHighlightingEnabled: Bool
    public var minimapEnabled: Bool
    public var foldingEnabled: Bool
    public var semanticTokensEnabled: Bool
    public var diagnosticsEnabled: Bool
    public var boundedUndo: Bool
    public var maxUndoGroups: Int
    public var enteredViaMemoryPressure: Bool
    public var limitationsDescription: String

    public static let inactive = LargeFileMode(
        isActive: false,
        syntaxHighlightingEnabled: true,
        minimapEnabled: true,
        foldingEnabled: true,
        semanticTokensEnabled: true,
        diagnosticsEnabled: true,
        boundedUndo: false,
        maxUndoGroups: Int.max,
        enteredViaMemoryPressure: false,
        limitationsDescription: ""
    )

    public init(
        isActive: Bool,
        syntaxHighlightingEnabled: Bool,
        minimapEnabled: Bool,
        foldingEnabled: Bool,
        semanticTokensEnabled: Bool,
        diagnosticsEnabled: Bool,
        boundedUndo: Bool,
        maxUndoGroups: Int,
        enteredViaMemoryPressure: Bool,
        limitationsDescription: String
    ) {
        self.isActive = isActive
        self.syntaxHighlightingEnabled = syntaxHighlightingEnabled
        self.minimapEnabled = minimapEnabled
        self.foldingEnabled = foldingEnabled
        self.semanticTokensEnabled = semanticTokensEnabled
        self.diagnosticsEnabled = diagnosticsEnabled
        self.boundedUndo = boundedUndo
        self.maxUndoGroups = maxUndoGroups
        self.enteredViaMemoryPressure = enteredViaMemoryPressure
        self.limitationsDescription = limitationsDescription
    }

    public static func evaluate(
        utf16Length: Int,
        lineCount: Int,
        policy: LargeFilePolicy = .default
    ) -> LargeFileMode {
        let overBytes = utf16Length >= policy.byteThreshold
        let overLines = lineCount >= policy.lineThreshold
        guard overBytes || overLines else { return .inactive }
        var reasons: [String] = []
        if overBytes {
            reasons.append("document exceeds \(policy.byteThreshold) UTF-16 units")
        }
        if overLines {
            reasons.append("document exceeds \(policy.lineThreshold) lines")
        }
        let limits =
            "Large file mode: syntax highlighting, minimap, folding, semantic tokens, and diagnostics disabled; undo bounded to \(policy.maxUndoGroups) groups. "
            + reasons.joined(separator: "; ") + "."
        return LargeFileMode(
            isActive: true,
            syntaxHighlightingEnabled: false,
            minimapEnabled: false,
            foldingEnabled: false,
            semanticTokensEnabled: false,
            diagnosticsEnabled: false,
            boundedUndo: true,
            maxUndoGroups: policy.maxUndoGroups,
            enteredViaMemoryPressure: false,
            limitationsDescription: limits
        )
    }

    public func applyingMemoryPressure(_ pressure: Bool, policy: LargeFilePolicy = .default) -> LargeFileMode {
        guard pressure else { return self }
        if isActive {
            var copy = self
            copy.enteredViaMemoryPressure = true
            if !copy.limitationsDescription.contains("memory pressure") {
                copy.limitationsDescription += " Escalated under memory pressure."
            }
            return copy
        }
        var mode = LargeFileMode.evaluate(
            utf16Length: policy.byteThreshold,
            lineCount: policy.lineThreshold,
            policy: policy
        )
        mode.enteredViaMemoryPressure = true
        mode.limitationsDescription =
            "Large file mode (memory pressure): heavy features disabled; undo bounded to \(policy.maxUndoGroups) groups."
        return mode
    }
}
