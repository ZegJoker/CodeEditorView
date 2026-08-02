import CodeEditorTerminal
import Foundation

/// Accessibility projection over Ghostty snapshots — no second terminal model (TER-007 / §21.11).
public struct GhosttyAccessibilityAdapter: Sendable {
    public var screenText: String
    public var cursorLine: Int
    public var cursorColumn: Int
    public var title: String
    public var isRunning: Bool

    public init(
        screenText: String = "",
        cursorLine: Int = 0,
        cursorColumn: Int = 0,
        title: String = "Terminal",
        isRunning: Bool = false
    ) {
        self.screenText = screenText
        self.cursorLine = cursorLine
        self.cursorColumn = cursorColumn
        self.title = title
        self.isRunning = isRunning
    }

    public static func from(snapshot: String, title: String, isRunning: Bool) -> GhosttyAccessibilityAdapter {
        let lines = snapshot.split(separator: "\n", omittingEmptySubsequences: false)
        let line = max(0, lines.count - 1)
        let col = lines.last.map(\.count) ?? 0
        return GhosttyAccessibilityAdapter(
            screenText: snapshot,
            cursorLine: line,
            cursorColumn: col,
            title: title,
            isRunning: isRunning
        )
    }

    public var accessibilityLabel: String {
        "\(title)\(isRunning ? ", running" : ", exited")"
    }

    public var accessibilityValue: String {
        screenText
    }
}
