import Foundation
import TextStory

/// Platform-agnostic text document backed by `NSMutableAttributedString`.
///
/// Conforms to TextStory's `TextStoring` so mutations and inverse computation
/// share a single abstraction across layout, selection, and undo.
///
/// Not marked `@MainActor` so it can satisfy TextStory's nonisolated `TextStoring`
/// requirements; call only from the main actor via ``EditorController``.
public final class DocumentStore: @unchecked Sendable, TextStoring {
    public private(set) var storage: NSMutableAttributedString
    public private(set) var lineEnding: LineEnding
    public var defaultAttributes: [NSAttributedString.Key: Any]

    public init(
        string: String = "",
        attributes: [NSAttributedString.Key: Any] = [:]
    ) {
        self.defaultAttributes = attributes
        self.storage = NSMutableAttributedString(string: string, attributes: attributes)
        self.lineEnding = LineEnding.detect(in: string)
    }

    // MARK: - TextStoring

    public var length: Int { storage.length }

    public func substring(from range: NSRange) -> String? {
        let max = range.location + range.length
        guard range.location >= 0, max <= storage.length else { return nil }
        return storage.attributedSubstring(from: range).string
    }

    public func applyMutation(_ mutation: TextMutation) {
        storage.replaceCharacters(in: mutation.range, with: mutation.string)
        if !mutation.string.isEmpty, !defaultAttributes.isEmpty {
            let inserted = NSRange(location: mutation.range.location, length: mutation.string.utf16.count)
            storage.addAttributes(defaultAttributes, range: inserted)
        }
    }

    // MARK: - Convenience

    public var fullString: String { storage.string }

    public func attributedSubstring(from range: NSRange) -> NSAttributedString {
        storage.attributedSubstring(from: range)
    }

    public func setFullText(_ string: String) {
        storage = NSMutableAttributedString(string: string, attributes: defaultAttributes)
        lineEnding = LineEnding.detect(in: string)
    }

    public func setAttributes(_ attributes: [NSAttributedString.Key: Any], range: NSRange) {
        guard range.length > 0, range.location >= 0, range.max <= storage.length else { return }
        // Replace keys (especially foregroundColor) instead of only adding, so language
        // switches cannot leave mixed/stale attribute runs inside a token.
        storage.enumerateAttributes(in: range, options: []) { existing, subrange, _ in
            var merged = existing
            for (key, value) in attributes {
                merged[key] = value
            }
            // Drop bold/italic from previous capture fonts unless a font is provided.
            if attributes[.font] == nil, let font = existing[.font] as? PlatformFont {
                merged[.font] = font
            }
            self.storage.setAttributes(merged, range: subrange)
        }
    }

    /// Resets the whole document to the current typing attributes (clears syntax colors).
    public func resetAttributesToDefaults() {
        let full = NSRange(location: 0, length: storage.length)
        guard full.length > 0 else { return }
        storage.setAttributes(defaultAttributes, range: full)
    }

    /// Builds a forward mutation and its inverse for the given replacement.
    public func makeEdit(in range: NSRange, replacement: String) -> TextEdit {
        let mutation = TextMutation(string: replacement, range: range, limit: length)
        let inverse = inverseMutation(for: mutation)
        return TextEdit(mutation: mutation, inverse: inverse)
    }

    /// Applies a replacement and returns the recorded edit.
    @discardableResult
    public func replaceCharacters(in range: NSRange, with replacement: String) -> TextEdit {
        let edit = makeEdit(in: range, replacement: replacement)
        applyMutation(edit.mutation)
        return edit
    }
}
