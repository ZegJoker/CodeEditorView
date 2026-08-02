import CodeEditorCore
import Foundation

/// Pure helpers for accessibility labels/values (testable without AppKit/UIKit).
public enum EditorAccessibility: Sendable {
    /// Maximum characters of **document body** exposed in accessibility value.
    public static let maxValueCharacters = 4_000
    /// Extra budget for line/column summary prefix.
    public static let maxValueOverheadCharacters = 64

    // MARK: - Labels

    /// Builds a short label for the editor control.
    public static func label(
        languageID: String?,
        isEditable: Bool,
        isDirty: Bool
    ) -> String {
        var parts: [String] = ["Code editor"]
        if let languageID, !languageID.isEmpty {
            parts.append(languageID)
        }
        if !isEditable { parts.append("read-only") }
        if isDirty { parts.append("edited") }
        return parts.joined(separator: ", ")
    }

    /// Truncates document text for accessibility value (VoiceOver performance).
    public static func valueText(
        fullText: String,
        selectedRange: NSRange,
        maxCharacters: Int = maxValueCharacters
    ) -> String {
        virtualizedValueText(
            fullText: fullText,
            selectedRange: selectedRange,
            visibleUTF16Range: nil,
            maxCharacters: maxCharacters
        )
    }

    /// Virtualized accessibility value: selection summary + visible/focus window (UI-007).
    /// Length is O(viewport / maxCharacters), not O(document).
    public static func virtualizedValueText(
        fullText: String,
        selectedRange: NSRange,
        visibleUTF16Range: NSRange?,
        maxCharacters: Int = maxValueCharacters
    ) -> String {
        let summary = semanticSummary(
            fullText: fullText,
            selectedRange: selectedRange,
            multiCursorCount: 1,
            languageID: nil,
            isEditable: true,
            isDirty: false,
            largeFileModeActive: false
        )
        let ns = fullText as NSString
        let length = ns.length
        let focus = max(0, min(selectedRange.location, length))

        let window: NSRange
        if let visible = visibleUTF16Range, visible.length > 0, visible.location >= 0 {
            let loc = max(0, min(visible.location, length))
            let len = max(0, min(visible.length, length - loc))
            window = NSRange(location: loc, length: min(len, maxCharacters))
        } else {
            let half = maxCharacters / 2
            let start = max(0, focus - half)
            let end = min(length, start + maxCharacters)
            window = NSRange(location: start, length: end - start)
        }

        var body = ""
        if window.location > 0 { body += "…" }
        if window.length > 0 {
            body += ns.substring(with: window)
        }
        if window.location + window.length < length { body += "…" }
        let prefix = summary.announcement
        let sep = ". "
        let budget = maxValueCharacters + maxValueOverheadCharacters
        if (prefix as NSString).length + (sep as NSString).length + (body as NSString).length <= budget {
            return prefix.isEmpty ? body : prefix + sep + body
        }
        let prefixLen = (prefix as NSString).length + (sep as NSString).length
        let bodyBudget = max(0, budget - prefixLen)
        let trimmedBody: String
        if (body as NSString).length <= bodyBudget {
            trimmedBody = body
        } else {
            trimmedBody = (body as NSString).substring(to: bodyBudget) + "…"
        }
        return prefix.isEmpty ? trimmedBody : prefix + sep + trimmedBody
    }

    /// Summary string for multi-cursor state.
    public static func multiCursorSummary(rangeCount: Int) -> String? {
        multiCursorAnnouncement(rangeCount: rangeCount)
    }

    // MARK: - Semantic accessibility (UI-N10)

    public struct SemanticSummary: Sendable, Equatable {
        public var line: Int
        public var column: Int
        public var selectionLength: Int
        public var multiCursorCount: Int
        public var announcement: String
    }

    /// Line/column/selection summary for VoiceOver and platform AX value prefixes (UI-N10).
    public static func semanticSummary(
        fullText: String,
        selectedRange: NSRange,
        multiCursorCount: Int,
        languageID: String?,
        isEditable: Bool,
        isDirty: Bool,
        largeFileModeActive: Bool
    ) -> SemanticSummary {
        let ns = fullText as NSString
        let length = ns.length
        let focus = max(0, min(selectedRange.location, length))
        var line = 1
        var lineStart = 0
        var i = 0
        while i < focus {
            let ch = ns.character(at: i)
            i += 1
            if ch == 0x0A {
                line += 1
                lineStart = i
            } else if ch == 0x0D {
                if i < length, ns.character(at: i) == 0x0A { i += 1 }
                line += 1
                lineStart = i
            }
        }
        let column = max(1, focus - lineStart + 1)
        var parts: [String] = ["Line \(line), column \(column)"]
        if selectedRange.length > 0 {
            parts.append("\(selectedRange.length) characters selected")
        }
        if multiCursorCount > 1 {
            parts.append("\(multiCursorCount) cursors")
        }
        if let languageID, !languageID.isEmpty {
            parts.append(languageID)
        }
        if !isEditable { parts.append("read-only") }
        if isDirty { parts.append("edited") }
        if largeFileModeActive { parts.append("large file mode") }
        return SemanticSummary(
            line: line,
            column: column,
            selectionLength: max(0, selectedRange.length),
            multiCursorCount: multiCursorCount,
            announcement: parts.joined(separator: ". ")
        )
    }

    public static func multiCursorAnnouncement(rangeCount: Int) -> String? {
        guard rangeCount > 1 else { return nil }
        return "\(rangeCount) cursors"
    }

    public struct RotorItem: Sendable, Equatable, Identifiable {
        public var id: String { label }
        public var label: String
        public var count: Int

        public init(label: String, count: Int) {
            self.label = label
            self.count = count
        }
    }

    /// Rotor / navigation surfaces: diagnostics, folds, changes, breakpoints, symbols, search (UI-N10).
    public static func rotorItems(
        diagnosticsCount: Int,
        foldCount: Int,
        changeCount: Int,
        breakpointCount: Int,
        symbolCount: Int,
        searchMatchCount: Int
    ) -> [RotorItem] {
        var items: [RotorItem] = []
        if diagnosticsCount > 0 {
            items.append(RotorItem(label: "Diagnostics", count: diagnosticsCount))
        }
        if foldCount > 0 {
            items.append(RotorItem(label: "Folds", count: foldCount))
        }
        if changeCount > 0 {
            items.append(RotorItem(label: "Changes", count: changeCount))
        }
        if breakpointCount > 0 {
            items.append(RotorItem(label: "Breakpoints", count: breakpointCount))
        }
        if symbolCount > 0 {
            items.append(RotorItem(label: "Symbols", count: symbolCount))
        }
        if searchMatchCount > 0 {
            items.append(RotorItem(label: "Search matches", count: searchMatchCount))
        }
        return items
    }

    public static func completionAnnouncement(selectedLabel: String, index: Int, total: Int) -> String {
        let human = max(1, index + 1)
        return "\(selectedLabel), \(human) of \(max(total, human))"
    }

    public enum PanelLandmarkRole: String, Sendable, Equatable {
        case editor
        case findPanel
        case completionPanel
        case gutter
        case minimap
        case commandPalette
    }

    public struct PanelLandmark: Sendable, Equatable {
        public var role: PanelLandmarkRole
        public var label: String

        public init(role: PanelLandmarkRole, label: String) {
            self.role = role
            self.label = label
        }
    }

    /// Focus landmarks for editor chrome (UI-N10).
    public static let panelLandmarks: [PanelLandmark] = [
        PanelLandmark(role: .editor, label: "Editor"),
        PanelLandmark(role: .findPanel, label: "Find"),
        PanelLandmark(role: .completionPanel, label: "Code completion"),
        PanelLandmark(role: .gutter, label: "Gutter"),
        PanelLandmark(role: .minimap, label: "Minimap"),
        PanelLandmark(role: .commandPalette, label: "Command palette"),
    ]

    /// When true, hosts should prefer reduced-motion-safe transitions (UI-N10).
    public static let reducedMotionPreferredTransitions = true

    public struct MotionPolicy: Sendable, Equatable {
        public var animateCaretBlink: Bool
        public var animateFoldTransitions: Bool
        public var animateScroll: Bool
    }

    public static func motionPolicy(reduceMotion: Bool) -> MotionPolicy {
        if reduceMotion {
            return MotionPolicy(animateCaretBlink: false, animateFoldTransitions: false, animateScroll: false)
        }
        return MotionPolicy(animateCaretBlink: true, animateFoldTransitions: true, animateScroll: true)
    }
}
