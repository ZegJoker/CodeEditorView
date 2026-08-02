import CodeEditorCore
import Foundation

/// Pure helpers for accessibility labels/values (testable without AppKit/UIKit).
public enum EditorAccessibility: Sendable {
    /// Maximum characters of **document body** exposed in accessibility value.
    public static let maxValueCharacters = 4_000
    /// Extra budget for line/column summary prefix.
    public static let maxValueOverheadCharacters = 64

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
        let ns = fullText as NSString
        let length = ns.length
        var parts: [String] = []

        // Line/column from simple newline scan up to caret (bounded by caret offset).
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
        parts.append("Line \(line), column \(max(1, focus - lineStart + 1))")
        if selectedRange.length > 0 {
            parts.append("\(selectedRange.length) characters selected")
        }

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
        // Keep total UTF-16 length within maxValueCharacters + small overhead.
        let prefix = parts.joined(separator: ". ")
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
        guard rangeCount > 1 else { return nil }
        return "\(rangeCount) cursors"
    }
}
