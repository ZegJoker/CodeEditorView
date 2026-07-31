import Foundation
import CodeEditorCore

/// Pure helpers for accessibility labels/values (testable without AppKit/UIKit).
public enum EditorAccessibility: Sendable {
    /// Maximum characters exposed in accessibility value for large documents.
    public static let maxValueCharacters = 4_000

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
        let ns = fullText as NSString
        let length = ns.length
        if length <= maxCharacters {
            return fullText
        }
        // Prefer a window around the primary selection/caret.
        let focus = max(0, min(selectedRange.location, length))
        let half = maxCharacters / 2
        let start = max(0, focus - half)
        let end = min(length, start + maxCharacters)
        let slice = ns.substring(with: NSRange(location: start, length: end - start))
        var result = ""
        if start > 0 { result += "…" }
        result += slice
        if end < length { result += "…" }
        return result
    }

    /// Summary string for multi-cursor state.
    public static func multiCursorSummary(rangeCount: Int) -> String? {
        guard rangeCount > 1 else { return nil }
        return "\(rangeCount) cursors"
    }
}
