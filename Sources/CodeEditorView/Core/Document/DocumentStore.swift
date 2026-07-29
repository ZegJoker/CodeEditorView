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
        guard let clamped = Self.clampedRange(range, documentLength: storage.length),
              clamped.length > 0
        else {
            // Empty-but-valid range (e.g. caret at end) → empty string; invalid → nil.
            if range.length == 0, range.location >= 0, range.location <= storage.length {
                return ""
            }
            return nil
        }
        // Use NSString — never hit NSAttributedString's throwing range API for plain text.
        return (storage.string as NSString).substring(with: clamped)
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
        // Never call Foundation's throwing `attributedSubstring(from:)` with an untrusted
        // range — out-of-bounds raises NSException and kills the process during draw
        // (seen after Enter on blank lines with fold/annotation/minimap enabled).
        let empty = NSAttributedString(string: "", attributes: defaultAttributes)
        guard let clamped = Self.clampedRange(range, documentLength: storage.length) else {
            return empty
        }
        if clamped.length == 0 {
            return empty
        }
        // Copy via NSString + attribute enumeration so we never pass a bad range into
        // NSAttributedString's range API even if storage mutates mid-flight.
        let ns = storage.string as NSString
        guard NSMaxRange(clamped) <= ns.length else { return empty }
        let plain = ns.substring(with: clamped)
        let result = NSMutableAttributedString(string: plain, attributes: defaultAttributes)
        storage.enumerateAttributes(in: clamped, options: []) { attrs, subrange, _ in
            let localLoc = subrange.location - clamped.location
            let localLen = subrange.length
            guard localLoc >= 0, localLen > 0, localLoc + localLen <= result.length else { return }
            result.addAttributes(attrs, range: NSRange(location: localLoc, length: localLen))
        }
        return result
    }

    /// Clamp `range` to `[0, documentLength)`. Returns `nil` if the range is unusable.
    private static func clampedRange(_ range: NSRange, documentLength docLen: Int) -> NSRange? {
        guard docLen >= 0 else { return nil }
        guard range.location >= 0, range.location <= docLen else { return nil }
        let maxLen = docLen - range.location
        // `range.length` can be negative / NSNotFound-sized; keep it non-negative.
        let rawLen = range.length
        let len = rawLen < 0 ? 0 : min(rawLen, maxLen)
        return NSRange(location: range.location, length: len)
    }

    public func setFullText(_ string: String) {
        storage = NSMutableAttributedString(string: string, attributes: defaultAttributes)
        lineEnding = LineEnding.detect(in: string)
    }

    public func setAttributes(_ attributes: [NSAttributedString.Key: Any], range: NSRange) {
        guard let clamped = Self.clampedRange(range, documentLength: storage.length),
              clamped.length > 0
        else { return }
        let range = clamped
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
